<#
>>> THIS IS THE SCRIPT TO COPY INTO THE SYNCROMSP WEB INTERFACE <<<
Paste this whole file into Syncro under Scripting -> Scripts. No Required File
attachment needed.

Diagnoses TCP port exhaustion caused by Bitdefender GravityZone (EPSecurityService).
-Mode Install registers a one-time boot task that collects data locally (the
Syncro agent itself is cut off once ports are exhausted); -Mode Upload attaches
the resulting ZIP to the asset later.

This is a thin wrapper: it pulls the current Debug-BitdefenderPortLeak.ps1 from
this repo and runs it, so future fixes in the repo take effect without editing
this wrapper again. Debug-BitdefenderPortLeak.ps1 is the source of truth for the
logic.
#>

param(
    [string]$Mode          = "Install",
    [int]$MonitorMinutes   = 15,
    [int]$IntervalSeconds  = 10,
    [int]$Capture          = 1,
    [int]$Reboot           = 0,
    [string]$Targets       = "34.120.68.241,34.54.215.149"
)

Import-Module $env:SyncroModule

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url       = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/bitdefender-diag/Debug-BitdefenderPortLeak.ps1?nocache=$([Guid]::NewGuid())"
$localCopy = Join-Path $env:TEMP "Debug-BitdefenderPortLeak.ps1"

try {
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Add("Cache-Control", "no-cache, no-store")
    $webClient.Headers.Add("Pragma", "no-cache")
    $webClient.DownloadFile($url, $localCopy)
    & $localCopy -Mode $Mode -MonitorMinutes $MonitorMinutes -IntervalSeconds $IntervalSeconds -Capture $Capture -Reboot $Reboot -Targets $Targets
    exit $LASTEXITCODE
}
catch {
    Write-Host "ERROR: Wrapper failed to download/run Debug-BitdefenderPortLeak.ps1: $($_.Exception.Message)"
    exit 1
}
