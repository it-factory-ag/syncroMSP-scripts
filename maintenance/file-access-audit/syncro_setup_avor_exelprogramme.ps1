<#
SyncroMSP wrapper: one-time setup of file access statistics for the AVOR-Exelprogramme
share (P:\07 IT\AVOR-Exelprogramme, real local path on srv: C:\_Daten\Daten\07 IT\AVOR-Exelprogramme).

Upload under Scripting -> Scripts and run once against the "srv" asset (Domain Controller).
Pulls the current Setup-FileAccessAudit.ps1 from this repo and executes it locally.
#>

Import-Module $env:SyncroModule

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$TargetPath = "C:\_Daten\Daten\07 IT\AVOR-Exelprogramme"
# Cache-busting query string: raw.githubusercontent.com sits behind a CDN, and a stale
# edge/proxy cache has been observed serving an old version of the script without it.
$url        = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/file-access-audit/Setup-FileAccessAudit.ps1?nocache=$([Guid]::NewGuid())"
$localCopy  = Join-Path $env:TEMP "Setup-FileAccessAudit.ps1"

try {
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Add("Cache-Control", "no-cache, no-store")
    $webClient.Headers.Add("Pragma", "no-cache")
    $webClient.DownloadFile($url, $localCopy)
    & $localCopy -TargetPath $TargetPath
    Write-Host "File access audit setup completed for '$TargetPath'."
    exit 0
}
catch {
    Rmm-Alert -Category "File Access Audit Setup" -Body "Setup failed for '$TargetPath': $($_.Exception.Message)"
    exit 1
}
