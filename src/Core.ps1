# 核心状态机：仅在活动 RDP 会话停止壁纸，仅在本机会话恢复。
function Get-CurrentSid {
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-RdpSessionInfo {
    if (-not ('WeRdpFix.SessionInfo' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace WeRdpFix {
    public static class SessionInfo {
        [DllImport("wtsapi32.dll", SetLastError=true)]
        static extern bool WTSQuerySessionInformation(IntPtr server, int session, int info, out IntPtr buffer, out int bytes);
        [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr buffer);
        public static int Read(int session, int info) {
            IntPtr p; int bytes;
            if (!WTSQuerySessionInformation(IntPtr.Zero, session, info, out p, out bytes))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try { return info == 16 ? (int)Marshal.ReadInt16(p) : Marshal.ReadInt32(p); }
            finally { WTSFreeMemory(p); }
        }
    }
}
'@
    }
    $id = [Diagnostics.Process]::GetCurrentProcess().SessionId
    [pscustomobject]@{
        Id = $id
        Protocol = [WeRdpFix.SessionInfo]::Read($id, 16) # 0=本机，2=RDP。
        State = [WeRdpFix.SessionInfo]::Read($id, 8) # 0=活动会话。
    }
}

function Get-SessionAction {
    param([string]$Mode, [int]$Protocol, [int]$State)
    if ($State -ne 0) { return 'Skip' }
    if ($Mode -in @('Remote','Sync') -and $Protocol -eq 2) { return 'Stop' }
    if ($Mode -in @('Local','Sync') -and $Protocol -eq 0) { return 'Resume' }
    return 'Skip'
}

function Get-AllowedEnginePaths {
    param([string]$EngineDirectory)
    @('wallpaper32.exe','wallpaper64.exe') | ForEach-Object {
        [IO.Path]::GetFullPath((Join-Path $EngineDirectory $_))
    }
}

function Get-RunningEngines {
    param([string]$EngineDirectory, [int]$SessionId)
    $allowed = @(Get-AllowedEnginePaths $EngineDirectory)
    @(Get-Process -Name wallpaper32,wallpaper64 -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $SessionId -and $_.Path -in $allowed } |
        ForEach-Object { [pscustomobject]@{ Id=$_.Id; Path=$_.Path } })
}

function Select-RunningEngine {
    param([object[]]$Engines)
    if ($Engines.Count -gt 1) { throw 'Multiple Wallpaper Engine main processes found in this session. Close the extra instance and retry.' }
    if ($Engines.Count -eq 1) { return $Engines[0].Path }
    return $null
}

function Invoke-EngineControl {
    param([string]$Executable, [ValidateSet('stop','play')][string]$Command)
    $p = Start-Process -FilePath $Executable -ArgumentList @('-control',$Command) -WorkingDirectory (Split-Path $Executable) -WindowStyle Hidden -PassThru
    if (-not $p.WaitForExit(8000)) { throw "Wallpaper Engine '$Command' command timed out." }
    if ($p.ExitCode -ne 0) { throw "Wallpaper Engine '$Command' failed (exit $($p.ExitCode))." }
}

function Start-EngineForRestore {
    param([string]$Executable, [string]$EngineDirectory, [int]$SessionId)
    # 正常恢复无需重启。只有控制进程已退出时才按原安全启动方式重新启动。
    Start-Process -FilePath $Executable -ArgumentList @('-safe','-silent') -WorkingDirectory $EngineDirectory -WindowStyle Hidden | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        Start-Sleep -Milliseconds 500
        $running = @(Get-RunningEngines $EngineDirectory $SessionId)
    } while (-not $running.Count -and [DateTime]::UtcNow -lt $deadline)
    $path = Select-RunningEngine $running
    if (-not $path) { throw 'Wallpaper Engine did not start; restore marker was retained.' }
    return $path
}

function Write-FixEvent {
    param([string]$Root, [string]$Action, [int]$SessionId, [string]$Detail)
    # 不记录账号、SID、IP 或凭据；日志留在本机，不上传。
    [ordered]@{ Time=(Get-Date -Format o); Action=$Action; Session=$SessionId; Detail=$Detail } |
        ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $Root 'events.jsonl') -Encoding utf8
}

function Invoke-SessionAction {
    param([string]$Root, [ValidateSet('Remote','Local','Sync')][string]$Mode)
    $config = Get-Content -LiteralPath (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
    if ($config.UserSid -ne (Get-CurrentSid)) { throw 'This installation belongs to a different Windows user.' }
    $session = Get-RdpSessionInfo
    $action = Get-SessionAction $Mode $session.Protocol $session.State
    if ($action -eq 'Skip') {
        Write-FixEvent $Root 'Skipped' $session.Id 'Session type/state does not match this action.'
        return 'Skipped'
    }
    $stateFile = Join-Path $Root "state-$($session.Id).json"
    $engine = Select-RunningEngine @(Get-RunningEngines $config.EngineDirectory $session.Id)
    if ($action -eq 'Stop') {
        if (-not $engine) {
            Write-FixEvent $Root 'NotRunning' $session.Id 'No running engine; no new restore marker.'
            return 'NotRunning'
        }
        # Stop 卸载内容；不是 Pause，也不终止主进程。
        [ordered]@{ Executable=$engine; Session=$session.Id; Time=(Get-Date -Format o) } |
            ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding utf8
        Invoke-EngineControl $engine 'stop'
        Write-FixEvent $Root 'StoppedUnloaded' $session.Id ([IO.Path]::GetFileName($engine))
        return 'StoppedUnloaded'
    }
    if (-not (Test-Path -LiteralPath $stateFile)) {
        Write-FixEvent $Root 'NoRestoreNeeded' $session.Id 'No content stopped by this tool.'
        return 'NoRestoreNeeded'
    }
    $saved = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    if ($saved.Session -ne $session.Id -or $saved.Executable -notin @(Get-AllowedEnginePaths $config.EngineDirectory)) {
        throw 'Invalid restore marker; no executable was started.'
    }
    if (-not $engine) {
        $engine = Start-EngineForRestore $saved.Executable $config.EngineDirectory $session.Id
    }
    # 允许用户在停止期间从 32 位切换到同目录的 64 位主程序，反之亦然。
    Invoke-EngineControl $engine 'play'
    Remove-Item -LiteralPath $stateFile
    Write-FixEvent $Root 'ResumedLoaded' $session.Id ([IO.Path]::GetFileName($engine))
    return 'ResumedLoaded'
}

function New-FixTaskDefinition {
    param($Scheduler, [string]$Sid, [string]$Root, [ValidateSet('Remote','Local')][string]$Mode)
    $task = $Scheduler.NewTask(0)
    $task.RegistrationInfo.Description = if ($Mode -eq 'Remote') {
        'Wallpaper Engine RDP Fix: unload live wallpapers on RDP connect using official Stop.'
    } else { 'Wallpaper Engine RDP Fix: reload stopped wallpapers only on the local console.' }
    $task.Principal.UserId = $Sid
    $task.Principal.LogonType = 3 # InteractiveToken：不保存密码。
    $task.Principal.RunLevel = 0 # 普通权限，不以 SYSTEM 运行。
    $task.Settings.Enabled = $true
    $task.Settings.DisallowStartIfOnBatteries = $false
    $task.Settings.StopIfGoingOnBatteries = $false
    $task.Settings.ExecutionTimeLimit = 'PT1M'
    $task.Settings.MultipleInstances = 2
    $changes = if ($Mode -eq 'Remote') { @(3) } else { @(1,8) }
    foreach ($change in $changes) {
        $t = $task.Triggers.Create(11)
        $t.UserId = $Sid
        $t.StateChange = $change
        $t.Enabled = $true
    }
    $logon = $task.Triggers.Create(9)
    $logon.UserId = $Sid
    $logon.Delay = 'PT5S'
    $a = $task.Actions.Create(0)
    $a.Path = Join-Path $Root 'Launcher.exe'
    $a.Arguments = $Mode
    $a.WorkingDirectory = $Root
    return $task
}
