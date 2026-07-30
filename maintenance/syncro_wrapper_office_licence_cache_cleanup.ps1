<#
>>> THIS IS THE SCRIPT TO COPY INTO THE SYNCROMSP WEB INTERFACE <<<
Paste this whole file into Syncro under Scripting -> Scripts. No Required File
attachment needed.

Clears Office/M365 identity and license caches (stale auth/token state,
e.g. Outlook not fetching mail without prompting for a password, or after a
UPN/primary email change). Run as the logged-in user (not SYSTEM). Reboot
required afterward, then re-sign in to Office.

This is a thin wrapper: it pulls the current office_licence_cache_cleanup.ps1
from this repo and runs it, so future fixes in the repo take effect without
editing this wrapper again. office_licence_cache_cleanup.ps1 is the source of
truth for the cleanup logic.
#>

Import-Module $env:SyncroModule

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url       = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/office_licence_cache_cleanup.ps1?nocache=$([Guid]::NewGuid())"
$localCopy = Join-Path $env:TEMP "office_licence_cache_cleanup.ps1"

try {
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Add("Cache-Control", "no-cache, no-store")
    $webClient.Headers.Add("Pragma", "no-cache")
    $webClient.DownloadFile($url, $localCopy)
    & $localCopy
    exit $LASTEXITCODE
}
catch {
    Write-Host "ERROR: Wrapper failed to download/run office_licence_cache_cleanup.ps1: $($_.Exception.Message)"
    exit 1
}
