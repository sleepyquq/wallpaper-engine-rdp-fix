#Requires -Version 7.0
param([string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'WallpaperEngineRdpFix'))
$ErrorActionPreference = 'Stop'
$configFile = Join-Path $InstallDirectory 'config.json'
if (-not (Test-Path -LiteralPath $configFile)) { Write-Output 'Not installed in this directory.'; exit 0 }
. (Join-Path $PSScriptRoot 'src\Core.ps1')
$config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
if ($config.UserSid -ne (Get-CurrentSid)) { throw 'This installation belongs to a different user.' }
$session = Get-RdpSessionInfo
[pscustomobject]@{
    Version=$config.Version
    SessionType=if($session.Protocol -eq 2){'RDP'}elseif($session.Protocol -eq 0){'Console'}else{'Other'}
    Active=($session.State -eq 0)
    Engines=@(Get-RunningEngines $config.EngineDirectory $session.Id | ForEach-Object { [IO.Path]::GetFileName($_.Path) })
    RestorePending=(Test-Path -LiteralPath (Join-Path $InstallDirectory "state-$($session.Id).json"))
    Tasks=@(foreach($name in $config.TaskNames){
        $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        [pscustomobject]@{Mode=if($name -match '-Remote-'){'Remote'}else{'Local'};Exists=($null -ne $task);Enabled=if($task){$task.Settings.Enabled}else{$false}}
    })
} | ConvertTo-Json -Depth 4
