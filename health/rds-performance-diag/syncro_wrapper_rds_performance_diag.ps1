<#
>>> THIS IS THE SCRIPT TO COPY INTO THE SYNCROMSP WEB INTERFACE <<<
Paste this whole file into Syncro under Scripting -> Scripts. No Required File
attachment needed.

Read-only performance diagnostic for a Remote Desktop Session Host (terminal
server): sessions, memory/handle leaks, disk latency, printers, file server
latency, event logs. Stores a snapshot per run and prints the trend.

This is a thin wrapper: it pulls the current Debug-RdsPerformance.ps1 from this
repo and runs it, so future fixes in the repo take effect without editing this
wrapper again. Debug-RdsPerformance.ps1 is the source of truth for the logic.
#>

# No param() block on purpose: Syncro injects Script Variables as plain assignments at the
# top of the script, which would push param() off the first line and break it. Optional
# Syncro variables with these exact names override the defaults below:
#   SampleSeconds (CPU/disk sampling window), EventDays (event log look-back)
if (-not $SampleSeconds) { $SampleSeconds = 15 }
if (-not $EventDays)     { $EventDays     = 7 }

Import-Module $env:SyncroModule

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url       = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/health/rds-performance-diag/Debug-RdsPerformance.ps1?nocache=$([Guid]::NewGuid())"
$localCopy = Join-Path $env:TEMP "Debug-RdsPerformance.ps1"

try {
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Add("Cache-Control", "no-cache, no-store")
    $webClient.Headers.Add("Pragma", "no-cache")
    $webClient.DownloadFile($url, $localCopy)
    & $localCopy -SampleSeconds $SampleSeconds -EventDays $EventDays
    exit $LASTEXITCODE
}
catch {
    Write-Host "ERROR: Wrapper failed to download/run Debug-RdsPerformance.ps1: $($_.Exception.Message)"
    exit 1
}
