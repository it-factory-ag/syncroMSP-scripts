<#
>>> THIS IS THE SCRIPT TO COPY INTO THE SYNCROMSP WEB INTERFACE <<<
Paste this whole file into Syncro under Scripting -> Scripts. No Required File
attachment needed.

Resets the Explorer jump list (5f7b5f1e01b83767.automaticDestinations-ms) of
every user whose list is larger than ThresholdKB; an oversized list makes Quick
access take seconds to open. Restarts Explorer only in the affected sessions.
Raises Rmm-Alert only if a reset fails.

This is a thin wrapper: it pulls the current Reset-ExplorerJumpList.ps1 from
this repo and runs it, so future fixes in the repo take effect without editing
this wrapper again. Reset-ExplorerJumpList.ps1 is the source of truth for the
logic.
#>

# No param() block on purpose: Syncro injects Script Variables as plain assignments at the
# top of the script, which would push param() off the first line and break it. Optional
# Syncro variables with these exact names override the defaults below:
#   ThresholdKB (reset above this size, default 1024), Users (comma-separated user
#   names, empty = all), WaitSeconds (how long to wait for Winlogon to restart Explorer)
if (-not $ThresholdKB) { $ThresholdKB = 1024 }
if (-not $Users)       { $Users       = "" }
if (-not $WaitSeconds) { $WaitSeconds = 20 }

Import-Module $env:SyncroModule

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url       = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/health/explorer-jumplist-reset/Reset-ExplorerJumpList.ps1?nocache=$([Guid]::NewGuid())"
$localCopy = Join-Path $env:TEMP "Reset-ExplorerJumpList.ps1"

try {
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Add("Cache-Control", "no-cache, no-store")
    $webClient.Headers.Add("Pragma", "no-cache")
    $webClient.DownloadFile($url, $localCopy)
    & $localCopy -ThresholdKB $ThresholdKB -Users $Users -WaitSeconds $WaitSeconds
    exit $LASTEXITCODE
}
catch {
    Write-Host "ERROR: Wrapper failed to download/run Reset-ExplorerJumpList.ps1: $($_.Exception.Message)"
    exit 1
}
