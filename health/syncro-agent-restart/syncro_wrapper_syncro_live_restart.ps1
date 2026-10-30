<#
>>> THIS IS THE SCRIPT TO COPY INTO THE SYNCROMSP WEB INTERFACE <<<
Paste this whole file into Syncro under Scripting -> Scripts. No Required File
attachment needed.

Restarts SyncroLive.Agent.Runner (handle leak in SyncroLive 1.0.76) once its
handle count passes a threshold, via a decoupled one-time scheduled task.
Raises Rmm-Alert only if the restart fails.

This is a thin wrapper: it pulls the current Restart-SyncroLiveAgent.ps1 from
this repo and runs it, so future fixes in the repo take effect without editing
this wrapper again. Restart-SyncroLiveAgent.ps1 is the source of truth for the
logic.
#>

# No param() block on purpose: Syncro injects Script Variables as plain assignments at the
# top of the script, which would push param() off the first line and break it. Optional
# Syncro variables with these exact names override the defaults below:
#   HandleThreshold (restart above this many handles), Force (1 = restart regardless)
if (-not $HandleThreshold) { $HandleThreshold = 50000 }
if (-not $Force)           { $Force           = 0 }

Import-Module $env:SyncroModule

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url       = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/health/syncro-agent-restart/Restart-SyncroLiveAgent.ps1?nocache=$([Guid]::NewGuid())"
$localCopy = Join-Path $env:TEMP "Restart-SyncroLiveAgent.ps1"

try {
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Add("Cache-Control", "no-cache, no-store")
    $webClient.Headers.Add("Pragma", "no-cache")
    $webClient.DownloadFile($url, $localCopy)
    & $localCopy -HandleThreshold $HandleThreshold -Force $Force
    exit $LASTEXITCODE
}
catch {
    Write-Host "ERROR: Wrapper failed to download/run Restart-SyncroLiveAgent.ps1: $($_.Exception.Message)"
    exit 1
}
