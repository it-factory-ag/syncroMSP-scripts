<#
>>> THIS IS THE SCRIPT TO COPY INTO THE SYNCROMSP WEB INTERFACE <<<
Paste this whole file into Syncro under Scripting -> Scripts. No Required File
attachment needed - the driver zip is downloaded directly from HP at runtime.

Sets up a second queue for the same "HP E78630z Andelfingen" network printer
(IP 192.168.40.32) at customer HUX - the "Briefpapier" (letterhead) queue,
sharing the same port as the plain-paper queue set up by
wrapper_hux_E78630z_andelfingen.ps1. Both queues default to monochrome.

Run this AFTER wrapper_hux_E78630z_andelfingen.ps1 has been run at least
once, so the shared port already exists (this script also creates it if
missing, so order doesn't strictly matter - but running the plain-paper one
first matches how the printer is normally provisioned).

Note: the actual "first page from the letterhead tray, remaining pages from
the normal tray" behavior is an HP-driver-specific setting, not something
Setup-Printer.ps1 sets. After this queue is created, configure it once
manually: printer Properties -> Printing Preferences -> Paper/Quality tab ->
enable "Use different paper" / "First Page", set First Page source to the
letterhead tray and Other Pages source to the normal tray.

This is a thin wrapper: it pulls the current Setup-Printer.ps1 from this repo
and runs it with this printer's name/IP, so future fixes in the repo take
effect without editing this wrapper again. Setup-Printer.ps1 is the source of
truth for the driver install logic - keep this wrapper in sync if its
parameters change.
#>

Import-Module $env:SyncroModule

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$PrinterName = "HP E78630z Andelfingen - Briefpapier"
$PrinterIP   = "192.168.40.32"
$PortName    = "IP_$PrinterIP"

$url       = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/printers/Setup-Printer.ps1?nocache=$([Guid]::NewGuid())"
$localCopy = Join-Path $env:TEMP "Setup-Printer.ps1"

try {
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Add("Cache-Control", "no-cache, no-store")
    $webClient.Headers.Add("Pragma", "no-cache")
    $webClient.DownloadFile($url, $localCopy)
    & $localCopy -PrinterName $PrinterName -PrinterIP $PrinterIP -PortName $PortName -ColorMode Monochrome
    exit $LASTEXITCODE
}
catch {
    Write-Host "ERROR: Wrapper failed to download/run Setup-Printer.ps1: $($_.Exception.Message)"
    exit 1
}
