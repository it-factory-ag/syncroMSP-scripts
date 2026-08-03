<#
>>> THIS IS THE SCRIPT TO COPY INTO THE SYNCROMSP WEB INTERFACE <<<
Paste this whole file into Syncro under Scripting -> Scripts. No Required File
attachment needed.

Temporarily enables OpenSSH Server for a remote support/debug session,
auto-disabling itself again after -DurationMinutes (default 60). Optional
-SshPublicKey deploys that key for password-less login.

This is a thin wrapper: it pulls the current Enable-TempSSHAccess.ps1 from
this repo and runs it, so future fixes in the repo take effect without
editing this wrapper again. Enable-TempSSHAccess.ps1 is the source of truth
for the logic.
#>

param(
    [int]$DurationMinutes = 60,
    [string]$SshPublicKey = ""
)

Import-Module $env:SyncroModule

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url       = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/temp-ssh-access/Enable-TempSSHAccess.ps1?nocache=$([Guid]::NewGuid())"
$localCopy = Join-Path $env:TEMP "Enable-TempSSHAccess.ps1"

try {
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Add("Cache-Control", "no-cache, no-store")
    $webClient.Headers.Add("Pragma", "no-cache")
    $webClient.DownloadFile($url, $localCopy)
    & $localCopy -DurationMinutes $DurationMinutes -SshPublicKey $SshPublicKey
    exit $LASTEXITCODE
}
catch {
    Write-Host "ERROR: Wrapper failed to download/run Enable-TempSSHAccess.ps1: $($_.Exception.Message)"
    exit 1
}
