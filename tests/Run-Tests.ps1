#Requires -Version 7.0
param([switch]$Integration)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Run these tests with PowerShell 7 on Windows.' }
$repo = Split-Path $PSScriptRoot
. (Join-Path $repo 'src\Core.ps1')
$originalGetRunningEngines = ${function:Get-RunningEngines}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('we-rdp-fix-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$script:passed = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:passed++ }
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $thrown=$false; try { & $Action | Out-Null } catch { $thrown=$true }
    Assert $thrown $Message
}
try {
    # 所有 PowerShell 源文件必须可解析。
    foreach ($file in Get-ChildItem -LiteralPath $repo -Filter '*.ps1' -Recurse) {
        $tokens=$null; $errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        Assert ($errors.Count -eq 0) ("Parse failure: " + $file.Name)
    }
    foreach ($row in @(
        @('Remote',2,0,'Stop'), @('Remote',0,0,'Skip'), @('Local',2,0,'Skip'),
        @('Local',0,0,'Resume'), @('Sync',2,0,'Stop'), @('Sync',0,0,'Resume'),
        @('Remote',2,4,'Skip'), @('Local',0,4,'Skip'), @('Sync',1,0,'Skip')
    )) {
        Assert ((Get-SessionAction $row[0] $row[1] $row[2]) -eq $row[3]) ('Session guard: '+($row -join ','))
    }
    $engineDir=Join-Path $temp 'engine with spaces'
    New-Item -ItemType Directory -Path $engineDir | Out-Null
    $p32=Join-Path $engineDir 'wallpaper32.exe'; $p64=Join-Path $engineDir 'wallpaper64.exe'
    [IO.File]::WriteAllText($p32,'fixture; never execute'); [IO.File]::WriteAllText($p64,'fixture; never execute')
    Assert ($null -eq (Select-RunningEngine @())) 'Empty process list must not start anything.'
    Assert ((Select-RunningEngine @([pscustomobject]@{Path=$p64})) -eq $p64) 'Select running 64-bit engine.'
    Assert-Throws { Select-RunningEngine @(@{Path=$p32},@{Path=$p64}) } 'Multiple main processes must be rejected.'

    # 检验真实筛选函数：排除其他目录、其他会话和编辑器。
    $script:processFixtures=@(
        [pscustomobject]@{Id=1;SessionId=7;Path=$p32},
        [pscustomobject]@{Id=2;SessionId=7;Path=$p64},
        [pscustomobject]@{Id=3;SessionId=8;Path=$p32},
        [pscustomobject]@{Id=4;SessionId=7;Path=(Join-Path $temp 'other\wallpaper32.exe')},
        [pscustomobject]@{Id=5;SessionId=7;Path=(Join-Path $engineDir 'wallpaperui.exe')}
    )
    function Get-Process { param($Name,$ErrorAction) $script:processFixtures }
    $filtered=@(& $originalGetRunningEngines $engineDir 7)
    Assert (($filtered.Id -join ',') -eq '1,2') 'Only exact 32/64-bit paths in the current session may be controlled.'
    Remove-Item Function:\Get-Process

    $runtime=Join-Path $temp 'runtime'; New-Item -ItemType Directory -Path $runtime | Out-Null
    @{UserSid='fixture-user';EngineDirectory=$engineDir} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtime 'config.json')
    $script:session=[pscustomobject]@{Id=7;Protocol=2;State=0}
    $script:engines=@([pscustomobject]@{Id=1;Path=$p32})
    $script:calls=[Collections.Generic.List[string]]::new()
    $script:controlError=$false
    function Get-CurrentSid { 'fixture-user' }
    function Get-RdpSessionInfo { $script:session }
    function Get-RunningEngines { param($EngineDirectory,$SessionId) $script:engines }
    function Invoke-EngineControl {
        param($Executable,$Command)
        if($script:controlError){throw 'Simulated control failure'}
        $script:calls.Add(([IO.Path]::GetFileName($Executable)+':'+$Command))
    }
    function Start-EngineForRestore { param($Executable,$EngineDirectory,$SessionId) $script:calls.Add('start'); return $Executable }
    $marker=Join-Path $runtime 'state-7.json'
    Assert ((Invoke-SessionAction $runtime Remote) -eq 'StoppedUnloaded') 'Remote stop action.'
    Assert (Test-Path -LiteralPath $marker) 'Stop must preserve a restore marker.'
    Assert ($script:calls[0] -eq 'wallpaper32.exe:stop') 'Stop must use official stop, not pause or process termination.'
    Assert ((Invoke-SessionAction $runtime Local) -eq 'Skipped') 'Remote unlock must not restore wallpapers.'
    Assert ($script:calls.Count -eq 1) 'Wrong-session action must not issue commands.'
    $script:session.Protocol=0
    $script:engines=@([pscustomobject]@{Id=2;Path=$p64})
    Assert ((Invoke-SessionAction $runtime Local) -eq 'ResumedLoaded') 'Local restore after a 32-to-64-bit switch.'
    Assert ($script:calls[-1] -eq 'wallpaper64.exe:play') 'Restore must target the running architecture.'
    Assert (-not (Test-Path -LiteralPath $marker)) 'Successful play consumes the marker.'
    Assert ((Invoke-SessionAction $runtime Local) -eq 'NoRestoreNeeded') 'Do not resume content without our marker.'
    $script:session.Protocol=2; $script:engines=@()
    Assert ((Invoke-SessionAction $runtime Remote) -eq 'NotRunning') 'Do not launch a user-closed engine on RDP.'
    Assert (-not (Test-Path -LiteralPath $marker)) 'No running engine means no new marker.'
    $script:engines=@([pscustomobject]@{Id=2;Path=$p64}); $script:controlError=$true
    Assert-Throws { Invoke-SessionAction $runtime Remote } 'Control failure must be visible.'
    Assert (Test-Path -LiteralPath $marker) 'Failed command must retain recovery intent.'
    $script:controlError=$false; $script:session.Protocol=0
    $script:engines=@()
    Assert ((Invoke-SessionAction $runtime Local) -eq 'ResumedLoaded') 'Restore when the controller is no longer running.'
    Assert ($script:calls.Contains('start')) 'Missing controller must be restarted only for a pending restore.'
    @{Executable=(Join-Path $temp 'untrusted.exe');Session=7} | ConvertTo-Json | Set-Content -LiteralPath $marker
    Assert-Throws { Invoke-SessionAction $runtime Local } 'Reject a marker pointing outside the engine directory.'

    # 编译与实际执行无窗口启动器：只运行自建 fixture，不操作真实壁纸。
    $launchRoot=Join-Path $temp 'launcher'; New-Item -ItemType Directory -Path (Join-Path $launchRoot 'src') | Out-Null
    $csc=@('Framework64','Framework')|ForEach-Object{Join-Path $env:windir "Microsoft.NET\$_\v4.0.30319\csc.exe"}|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1
    & $csc /nologo /target:winexe ('/out:'+(Join-Path $launchRoot 'Launcher.exe')) (Join-Path $repo 'src\Launcher.cs')
    Assert ($LASTEXITCODE -eq 0) 'GUI launcher compilation.'
    $bytes=[IO.File]::ReadAllBytes((Join-Path $launchRoot 'Launcher.exe'))
    $pe=[BitConverter]::ToInt32($bytes,0x3c)
    Assert ([BitConverter]::ToUInt16($bytes,$pe+92) -eq 2) 'Launcher PE subsystem must be Windows GUI, not console.'
    $pwsh=(Get-Process -Id $PID).Path
    $pwsh|Set-Content -LiteralPath (Join-Path $launchRoot 'powershell-path.txt') -Encoding utf8
    'param($Mode); [IO.File]::WriteAllText((Join-Path (Split-Path $PSScriptRoot) "result.txt"),$Mode); exit 23' |
        Set-Content -LiteralPath (Join-Path $launchRoot 'src\Runtime.ps1') -Encoding utf8
    $p=Start-Process -FilePath (Join-Path $launchRoot 'Launcher.exe') -ArgumentList 'Remote' -PassThru -Wait
    Assert ($p.ExitCode -eq 23) 'Launcher must propagate the child exit code.'
    Assert ((Get-Content -LiteralPath (Join-Path $launchRoot 'result.txt') -Raw) -eq 'Remote') 'Launcher must pass the exact allowed mode.'
    $p=Start-Process -FilePath (Join-Path $launchRoot 'Launcher.exe') -ArgumentList 'Unexpected' -PassThru -Wait
    Assert ($p.ExitCode -eq 64) 'Launcher must reject unexpected arguments.'

    if ($Integration) {
        # 独立任务名和假的引擎目录；不碰使用者已经安装的任务，也不控制真实壁纸。
        $install=Join-Path $temp 'installed'; $prefix='WeRdpFixTest'+$PID
        & $pwsh -NoProfile -File (Join-Path $repo 'Install.ps1') -EngineDirectory $engineDir -InstallDirectory $install -TaskPrefix $prefix
        Assert ($LASTEXITCODE -eq 0) 'Isolated installation must succeed.'
        $cfg=Get-Content -LiteralPath (Join-Path $install 'config.json') -Raw|ConvertFrom-Json
        foreach($name in $cfg.TaskNames){
            $task=Get-ScheduledTask -TaskName $name
            Assert ($task.Principal.RunLevel.ToString() -eq 'Limited') 'Tasks must not require elevation.'
            Assert ($task.Principal.LogonType.ToString() -eq 'Interactive') 'Tasks must use an interactive token, not stored credentials.'
            Assert ($task.Actions.Execute -eq (Join-Path $install 'Launcher.exe')) 'Task must start the GUI launcher.'
            $changes=@($task.Triggers|Where-Object {$_.CimClass.CimClassName -eq 'MSFT_TaskSessionStateChangeTrigger'}|ForEach-Object{$_.StateChange})
            $expected=if($name -match '-Remote-'){'3'}else{'1,8'}
            Assert (($changes -join ',') -eq $expected) 'Task must use the expected session triggers.'
        }
        & $pwsh -NoProfile -File (Join-Path $repo 'Install.ps1') -EngineDirectory $engineDir -InstallDirectory $install -TaskPrefix $prefix 2>$null
        Assert ($LASTEXITCODE -ne 0) 'Installation must refuse to replace existing tasks.'
        & $pwsh -NoProfile -File (Join-Path $repo 'Uninstall.ps1') -InstallDirectory $install
        Assert ($LASTEXITCODE -eq 0) 'Isolated uninstall must succeed.'
        foreach($name in $cfg.TaskNames){ Assert ($null -eq (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) 'Test task must be removed.' }
    }
    Write-Output "PASS: $script:passed assertions. No real Wallpaper Engine process was controlled."
} finally {
    if($Integration -and $prefix){
        # 即使断言失败，也只清理本测试创建的两个确切任务。
        $realSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        foreach($mode in @('Remote','Local')){
            $name="$prefix-$mode-$realSid"
            if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName $name -Confirm:$false}
        }
    }
    # 测试临时目录由本次运行创建，先校验归属，再清理。
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    $resolved=[IO.Path]::GetFullPath($temp)
    if($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and ([IO.Path]::GetFileName($resolved) -like 'we-rdp-fix-tests-*')){
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
