<#
>>> THIS IS THE SCRIPT TO COPY INTO THE SYNCROMSP WEB INTERFACE <<<
Paste this whole file into Syncro under Scripting -> Scripts. Also add a
Required File on the script: Destination File Name = C:\temp\upd.zip,
File = the uploaded HP M430 driver package (upd.zip).

This is a thin wrapper: it pulls the current vsgn_printer_setup_d11_32.ps1 from
this repo and executes it locally, so future fixes in the repo take effect
without editing this wrapper again. That script is the source of truth - keep
this wrapper in sync if its required files/paths change.
#>

Import-Module $env:SyncroModule

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url       = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/vsgn_printer_setup_d11_32.ps1?nocache=$([Guid]::NewGuid())"
$localCopy = Join-Path $env:TEMP "vsgn_printer_setup_d11_32.ps1"

try {
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Add("Cache-Control", "no-cache, no-store")
    $webClient.Headers.Add("Pragma", "no-cache")
    $webClient.DownloadFile($url, $localCopy)
    & $localCopy
    exit $LASTEXITCODE
}
catch {
    Rmm-Alert -Category "VSGN Printer Setup" -Body "Wrapper failed to download/run vsgn_printer_setup_d11_32.ps1: $($_.Exception.Message)"
    exit 1
}
