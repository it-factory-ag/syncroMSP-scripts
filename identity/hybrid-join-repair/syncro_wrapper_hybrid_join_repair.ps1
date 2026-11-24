<#
>>> THIS IS THE SCRIPT TO COPY INTO THE SYNCROMSP WEB INTERFACE <<<
Paste this whole file into Syncro under Scripting -> Scripts. No Required File
attachment needed.

Checks Microsoft Entra hybrid join on a domain-joined device and, with Action = Repair,
removes the local autoWorkplaceJoin = 0 blocker and starts the Automatic-Device-Join task.
Raises Rmm-Alert only if the repair fails or a GPO sets the blocker.

This is a thin wrapper: it pulls the current Repair-HybridJoin.ps1 from this repo and
runs it, so future fixes in the repo take effect without editing this wrapper again.
Repair-HybridJoin.ps1 is the source of truth for the logic.
#>

# No param() block on purpose: Syncro injects Script Variables as plain assignments at the
# top of the script, which would push param() off the first line and break it. Optional
# Syncro variable with this exact name overrides the default below:
#   Action (dropdown: Check, Repair)
if (-not $Action) { $Action = "Check" }

Import-Module $env:SyncroModule

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url       = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/identity/hybrid-join-repair/Repair-HybridJoin.ps1?nocache=$([Guid]::NewGuid())"
$localCopy = Join-Path $env:TEMP "Repair-HybridJoin.ps1"

try {
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Add("Cache-Control", "no-cache, no-store")
    $webClient.Headers.Add("Pragma", "no-cache")
    $webClient.DownloadFile($url, $localCopy)
    & $localCopy -Action $Action
    exit $LASTEXITCODE
}
catch {
    Write-Host "ERROR: Wrapper failed to download/run Repair-HybridJoin.ps1: $($_.Exception.Message)"
    exit 1
}
