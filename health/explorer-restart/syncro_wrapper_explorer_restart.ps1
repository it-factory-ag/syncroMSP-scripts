<#
>>> THIS IS THE SCRIPT TO COPY INTO THE SYNCROMSP WEB INTERFACE <<<
Paste this whole file into Syncro under Scripting -> Scripts. No Required File
attachment needed.

Restarts explorer.exe in every user session of a terminal server without
logging anyone off. Raises Rmm-Alert only if a session is left without
explorer.exe.

This is a thin wrapper: it pulls the current Restart-ExplorerSessions.ps1 from
this repo and runs it, so future fixes in the repo take effect without editing
this wrapper again. Restart-ExplorerSessions.ps1 is the source of truth for the
logic.
#>

# No param() block on purpose: Syncro injects Script Variables as plain assignments at the
# top of the script, which would push param() off the first line and break it. Optional
# Syncro variables with these exact names override the defaults below:
#   Users (comma-separated user names, empty = all sessions),
#   WaitSeconds (how long to wait for Winlogon to restart the shell)
if (-not $Users)       { $Users       = "" }
if (-not $WaitSeconds) { $WaitSeconds = 20 }

Import-Module $env:SyncroModule

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url       = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/health/explorer-restart/Restart-ExplorerSessions.ps1?nocache=$([Guid]::NewGuid())"
$localCopy = Join-Path $env:TEMP "Restart-ExplorerSessions.ps1"

try {
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Add("Cache-Control", "no-cache, no-store")
    $webClient.Headers.Add("Pragma", "no-cache")
    $webClient.DownloadFile($url, $localCopy)
    & $localCopy -Users $Users -WaitSeconds $WaitSeconds
    exit $LASTEXITCODE
}
catch {
    Write-Host "ERROR: Wrapper failed to download/run Restart-ExplorerSessions.ps1: $($_.Exception.Message)"
    exit 1
}
