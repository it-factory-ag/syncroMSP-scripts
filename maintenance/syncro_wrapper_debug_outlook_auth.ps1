<#
>>> THIS IS THE SCRIPT TO COPY INTO THE SYNCROMSP WEB INTERFACE <<<
Paste this whole file into Syncro under Scripting -> Scripts. No Required File
attachment needed.

Read-only diagnostic for Outlook (Exchange/M365) not fetching mail without
prompting for a password. Makes no changes - run as the logged-in user
(not SYSTEM), review the output.

This is a thin wrapper: it pulls the current Debug-OutlookAuth.ps1 from this
repo and runs it, so future fixes in the repo take effect without editing
this wrapper again. Debug-OutlookAuth.ps1 is the source of truth for the
diagnostic logic.
#>

Import-Module $env:SyncroModule

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url       = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/Debug-OutlookAuth.ps1?nocache=$([Guid]::NewGuid())"
$localCopy = Join-Path $env:TEMP "Debug-OutlookAuth.ps1"

try {
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Add("Cache-Control", "no-cache, no-store")
    $webClient.Headers.Add("Pragma", "no-cache")
    $webClient.DownloadFile($url, $localCopy)
    & $localCopy
    exit $LASTEXITCODE
}
catch {
    Write-Host "ERROR: Wrapper failed to download/run Debug-OutlookAuth.ps1: $($_.Exception.Message)"
    exit 1
}
