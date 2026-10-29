#Requires -Version 7.0
param(
    [string]$EngineDirectory,
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'WallpaperEngineRdpFix'),
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,45}$')][string]$TaskPrefix = 'WallpaperEngineRdpFix'
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows is required.' }
. (Join-Path $PSScriptRoot 'src\Core.ps1')
$sid = Get-CurrentSid
$sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
if (-not $EngineDirectory) {
    $roots = @(Get-Process wallpaper32,wallpaper64 -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId -and $_.Path } |
        ForEach-Object { Split-Path $_.Path } | Sort-Object -Unique)
    if ($roots.Count -eq 1) { $EngineDirectory = $roots[0] }
    elseif ($roots.Count -gt 1) { throw 'Multiple engine directories found. Specify -EngineDirectory.' }
    else { $EngineDirectory = Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\common\wallpaper_engine' }
}
$EngineDirectory = (Resolve-Path -LiteralPath $EngineDirectory).Path
if (-not @((Get-AllowedEnginePaths $EngineDirectory) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count) {
    throw 'The directory must contain wallpaper32.exe or wallpaper64.exe.'
}
$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory)
if ($InstallDirectory -like '*"*') { throw 'Installation path must not contain a double quote.' }
$names = @("$TaskPrefix-Remote-$sid", "$TaskPrefix-Local-$sid")
foreach ($name in $names) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { throw "Already installed: $name. Uninstall the existing tasks first." }
}
if (Test-Path -LiteralPath $InstallDirectory) {
    $oldConfig = Join-Path $InstallDirectory 'config.json'
    if (-not (Test-Path -LiteralPath $oldConfig)) {
        if (@(Get-ChildItem -LiteralPath $InstallDirectory -Force).Count) { throw 'Destination is not an empty installation directory.' }
    } else {
        $old = Get-Content -LiteralPath $oldConfig -Raw | ConvertFrom-Json
        if ($old.UserSid -ne $sid -or $old.TaskPrefix -ne $TaskPrefix) { throw 'Destination belongs to another user or task prefix.' }
    }
}
$csc = @('Framework64','Framework') | ForEach-Object { Join-Path $env:windir "Microsoft.NET\$_\v4.0.30319\csc.exe" } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw 'The Windows .NET Framework C# compiler was not found. No tasks were installed.' }
$pwsh = (Get-Process -Id $PID).Path
New-Item -ItemType Directory -Path (Join-Path $InstallDirectory 'src') -Force | Out-Null
foreach ($file in @('Core.ps1','Runtime.ps1','Launcher.cs')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "src\$file") -Destination (Join-Path $InstallDirectory "src\$file") -Force
}
foreach ($file in @('Status.ps1','Uninstall.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $InstallDirectory $file) -Force
}
# 只编译本仓库附带的可读源码；不下载二进制、不调整安全策略。
& $csc /nologo /target:winexe ('/out:' + (Join-Path $InstallDirectory 'Launcher.exe')) (Join-Path $InstallDirectory 'src\Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed. No tasks were installed.' }
$pwsh | Set-Content -LiteralPath (Join-Path $InstallDirectory 'powershell-path.txt') -Encoding utf8
[ordered]@{ Version='0.1.0'; UserSid=$sid; EngineDirectory=$EngineDirectory; TaskPrefix=$TaskPrefix; TaskNames=$names; Installed=(Get-Date -Format o) } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallDirectory 'config.json') -Encoding utf8
$scheduler = New-Object -ComObject Schedule.Service
$scheduler.Connect()
$folder = $scheduler.GetFolder('\')
$created = @()
try {
    for ($i=0; $i -lt 2; $i++) {
        $mode = @('Remote','Local')[$i]
        $definition = New-FixTaskDefinition $scheduler $sid $InstallDirectory $mode
        $registered = $folder.RegisterTaskDefinition($names[$i], $definition, 2, $sid, $null, 3, $null)
        $created += $names[$i]
        $registered.Xml | Set-Content -LiteralPath (Join-Path $InstallDirectory "$mode-task.xml") -Encoding utf8
    }
} catch {
    foreach ($name in $created) { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
    throw
}
Write-Output "Installed for this Windows user: $InstallDirectory"
Write-Output 'Reconnect RDP to apply. Return to the physical console to restore. No reboot is required.'
Write-Output 'Keep Wallpaper Engine normal auto-start enabled; this tool does not change that setting.'
