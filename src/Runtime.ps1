param([ValidateSet('Remote','Local','Sync')][string]$Mode = 'Sync')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
$root = Split-Path $PSScriptRoot
$mutex = [Threading.Mutex]::new($false, ('Local\WallpaperEngineRdpFix.' + (Get-CurrentSid)))
$locked = $false
try {
    try { $locked = $mutex.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another wallpaper transition is still running.' }
    Invoke-SessionAction $root $Mode | Out-Null
} catch {
    try { Write-FixEvent $root 'Error' ([Diagnostics.Process]::GetCurrentProcess().SessionId) $_.Exception.Message } catch { }
    Write-Error $_
    exit 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
