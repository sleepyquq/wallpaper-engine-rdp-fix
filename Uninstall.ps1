#Requires -Version 7.0
param([string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'WallpaperEngineRdpFix'))
$ErrorActionPreference = 'Stop'
$configFile = Join-Path $InstallDirectory 'config.json'
if (-not (Test-Path -LiteralPath $configFile)) { Write-Output 'Not installed in this directory.'; exit 0 }
. (Join-Path $PSScriptRoot 'src\Core.ps1')
$config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
$sid = Get-CurrentSid
if ($config.UserSid -ne $sid) { throw 'This installation belongs to a different Windows user.' }
$expected = @("$($config.TaskPrefix)-Remote-$sid", "$($config.TaskPrefix)-Local-$sid")
if (($config.TaskNames -join '|') -cne ($expected -join '|')) { throw 'Invalid task names in configuration; no tasks changed.' }
foreach ($name in $expected) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Disable-ScheduledTask -TaskName $name | Out-Null }
}
$restoreError = $null
try {
    # 没有本工具的恢复标记时，不操作壁纸。远程卸载不会强行恢复动态内容。
    if (@(Get-ChildItem -LiteralPath $InstallDirectory -Filter 'state-*.json').Count) {
        # 复用 Runtime 的互斥锁，避免与正在结束的会话任务争用恢复标记。
        $p = Start-Process -FilePath (Join-Path $InstallDirectory 'Launcher.exe') -ArgumentList 'Local' -PassThru
        if (-not $p.WaitForExit(30000)) { throw 'Restore action did not complete in time; marker retained.' }
        if ($p.ExitCode -ne 0) { throw 'Restore action failed; see local events.jsonl.' }
    }
} catch { $restoreError = $_.Exception.Message }
foreach ($name in $expected) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $name -Confirm:$false }
}
Write-Output 'Both scheduled tasks removed. Installation files and local logs retained; no background process remains.'
if ($restoreError) { throw "Tasks removed, but wallpaper restoration failed: $restoreError" }
if (@(Get-ChildItem -LiteralPath $InstallDirectory -Filter 'state-*.json').Count) {
    Write-Output 'A restore marker remains (for example after uninstalling over RDP). Resume playback manually in Wallpaper Engine on the local console.'
}
