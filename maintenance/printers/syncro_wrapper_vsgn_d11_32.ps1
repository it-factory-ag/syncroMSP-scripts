<#
>>> THIS IS THE SCRIPT TO COPY INTO THE SYNCROMSP WEB INTERFACE <<<
Paste this whole file into Syncro under Scripting -> Scripts. No Required File
attachment needed - the driver zip is downloaded directly from HP at runtime.

Sets up the "D11-32 Container MFP M430f" network printer (HP LaserJet
Enterprise MFP M430 series, IP 192.168.0.32) at customer VSGN.

This is a thin wrapper: it pulls the current Setup-Printer.ps1 from this repo
and runs it with this printer's name/IP, so future fixes in the repo take
effect without editing this wrapper again. Setup-Printer.ps1 is the source of
truth for the driver install logic - keep this wrapper in sync if its
parameters change.
#>

Import-Module $env:SyncroModule

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$PrinterName = "D11-32 Container MFP M430f"
$PrinterIP   = "192.168.0.32"

$url       = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/printers/Setup-Printer.ps1?nocache=$([Guid]::NewGuid())"
$localCopy = Join-Path $env:TEMP "Setup-Printer.ps1"

try {
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Add("Cache-Control", "no-cache, no-store")
    $webClient.Headers.Add("Pragma", "no-cache")
    $webClient.DownloadFile($url, $localCopy)
    & $localCopy -PrinterName $PrinterName -PrinterIP $PrinterIP
    exit $LASTEXITCODE
}
catch {
    Write-Host "ERROR: Wrapper failed to download/run Setup-Printer.ps1: $($_.Exception.Message)"
    exit 1
}
