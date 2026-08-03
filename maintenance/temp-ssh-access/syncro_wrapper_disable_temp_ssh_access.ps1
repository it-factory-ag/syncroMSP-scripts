<#
>>> THIS IS THE SCRIPT TO COPY INTO THE SYNCROMSP WEB INTERFACE <<<
Paste this whole file into Syncro under Scripting -> Scripts. No Required File
attachment needed.

Immediately disables the temporary OpenSSH Server access opened by
Enable-TempSSHAccess.ps1, without waiting for the automatic timeout. Safe
to run even if no session is currently active.

This is a thin wrapper: it pulls the current Disable-TempSSHAccess.ps1 from
this repo and runs it, so future fixes in the repo take effect without
editing this wrapper again. Disable-TempSSHAccess.ps1 is the source of truth
for the logic.
#>

Import-Module $env:SyncroModule

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url       = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/temp-ssh-access/Disable-TempSSHAccess.ps1?nocache=$([Guid]::NewGuid())"
$localCopy = Join-Path $env:TEMP "Disable-TempSSHAccess.ps1"

try {
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Add("Cache-Control", "no-cache, no-store")
    $webClient.Headers.Add("Pragma", "no-cache")
    $webClient.DownloadFile($url, $localCopy)
    & $localCopy
    exit $LASTEXITCODE
}
catch {
    Write-Host "ERROR: Wrapper failed to download/run Disable-TempSSHAccess.ps1: $($_.Exception.Message)"
    exit 1
}
