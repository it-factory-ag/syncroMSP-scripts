<#
VSGN - sets up the "D11-32 MFP Container MFP M430f" network printer (HP LaserJet
Enterprise MFP M430 series, IP 192.168.0.32) using the HP Universal Print Driver
(PCL6), downloaded directly from HP at runtime.

Replaces the old cscript/prnmngr.vbs + install.exe batch approach with native
PowerShell printing cmdlets. That old script had two bugs: `cd /temp` at the end
is not a valid way to switch to C:\temp (should be `cd /d C:\temp`), so cleanup
ran from inside C:\temp\upd instead and silently failed to remove the temp files;
and `install.exe` was invoked with hardcoded switches with no error handling, so a
failed extraction or driver mismatch went unnoticed.

Downloads the driver zip from ftp.hp.com (Akamai-hosted, stable static file -
unlike the JS-rendered support.hp.com driver pages, which can't be scripted
against) instead of relying on a SyncroMSP script file attachment, so no
per-script file upload/maintenance is needed in Syncro. The driver's .inf is
located automatically inside the package, so this keeps working across
different driver package layouts without needing the exact .inf filename or
driver name hardcoded. Bump $DriverUrl below when HP releases a newer UPD
version.
#>

Import-Module $env:SyncroModule

$PrinterName   = "D11-32 MFP Container MFP M430f"
$PrinterIP     = "192.168.0.32"
$PortName      = "IP_$PrinterIP"
$DriverUrl     = "https://ftp.hp.com/pub/softlib/software13/printers/UPD/upd-pcl6-win11-x64-8.2.0.26819.zip"
$DriverZipPath = "C:\temp\hp_upd_pcl6.zip"
$ExtractDir    = "C:\temp\hp_upd_pcl6"

function Get-InfDriverCandidates {
    param([string]$InfPath)

    $lines = Get-Content -Path $InfPath
    $strings = @{}
    $inStrings = $false
    foreach ($line in $lines) {
        $trimmed = ($line -replace ';.*$', '').Trim()
        if ($trimmed -match '^\[Strings\]$') { $inStrings = $true; continue }
        if ($trimmed -match '^\[.+\]$') { $inStrings = $false; continue }
        if ($inStrings -and $trimmed -match '^"?([^"=]+?)"?\s*=\s*"(.*)"\s*$') {
            $strings[$Matches[1].Trim()] = $Matches[2]
        }
    }

    # The [Manufacturer] section maps a manufacturer display string to a model
    # section name (also "name = target, arch1, arch2" shaped) - skip it, or
    # its entries get misread as driver model names (e.g. "HP Inc.").
    $candidates = New-Object System.Collections.Generic.List[string]
    $inManufacturer = $false
    foreach ($line in $lines) {
        $trimmed = ($line -replace ';.*$', '').Trim()
        if ($trimmed -match '^\[Manufacturer\]$') { $inManufacturer = $true; continue }
        if ($trimmed -match '^\[.+\]$') { $inManufacturer = $false; continue }
        if ($inManufacturer) { continue }
        if ($trimmed -match '^(?:"(?<name>[^"]+)"|%(?<ph>[^%]+)%)\s*=\s*[\w\.\-]+\s*,\s*\S+') {
            if ($Matches['name']) {
                $candidates.Add($Matches['name']) | Out-Null
            } elseif ($strings.ContainsKey($Matches['ph'])) {
                $candidates.Add($strings[$Matches['ph']]) | Out-Null
            }
        }
    }
    return $candidates | Select-Object -Unique
}

function Get-PnpUtilPublishedInfPath {
    param([string[]]$PnpUtilOutput)

    foreach ($line in $PnpUtilOutput) {
        if ($line -match '(?:Published Name|Ver.ffentlichter Name)\s*:\s*(oem\d+\.inf)') {
            return Join-Path $env:WINDIR "INF\$($Matches[1])"
        }
    }
    return $null
}

try {
    Write-Host "=== VSGN Printer Setup: $PrinterName ==="

    Write-Host "Downloading driver package from $DriverUrl..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -Path (Split-Path $DriverZipPath) -ItemType Directory -Force | Out-Null
    (New-Object Net.WebClient).DownloadFile($DriverUrl, $DriverZipPath)

    Write-Host "Removing existing printer/port if present..."
    Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue | Remove-Printer -ErrorAction SilentlyContinue
    Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue | Remove-PrinterPort -ErrorAction SilentlyContinue

    if (Test-Path $ExtractDir) {
        Remove-Item -Path $ExtractDir -Recurse -Force
    }
    Write-Host "Extracting driver package..."
    Expand-Archive -Path $DriverZipPath -DestinationPath $ExtractDir -Force

    $infFiles = Get-ChildItem -Path $ExtractDir -Filter "*.inf" -Recurse
    if (-not $infFiles) {
        throw "No .inf file found inside '$DriverZipPath'."
    }
    Write-Host "Found $($infFiles.Count) .inf file(s):"
    $infFiles | ForEach-Object { Write-Host "  $($_.FullName)" }

    # Trust the certificate the driver catalogs are signed with. Unattended
    # pnputil rejects them otherwise ("the publisher of an Authenticode-signed
    # catalog has not yet been established as trusted") - interactively, that
    # trust is granted via the "trust software from HP Inc.?" click-through
    # dialog, which can't appear when running as SYSTEM.
    $catFiles = Get-ChildItem -Path $ExtractDir -Filter "*.cat" -Recurse
    $trustedPublisherStore = New-Object Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
    $trustedPublisherStore.Open("ReadWrite")
    foreach ($cat in $catFiles) {
        $signature = Get-AuthenticodeSignature -FilePath $cat.FullName
        if ($signature.SignerCertificate -and ($trustedPublisherStore.Certificates.Find("FindByThumbprint", $signature.SignerCertificate.Thumbprint, $false).Count -eq 0)) {
            Write-Host "Trusting driver signing certificate: $($signature.SignerCertificate.Subject)"
            $trustedPublisherStore.Add($signature.SignerCertificate)
        }
    }
    $trustedPublisherStore.Close()

    # Stage every .inf via pnputil first. Windows copies each into the driver
    # store under C:\Windows\INF\oemXX.inf ("Published Name" in the output) -
    # Add-PrinterDriver has to be pointed at that published copy, not at the
    # original extracted file, or it fails with a generic
    # "parameter is incorrect" (HRESULT 0x80070057) instead of a clear error.
    $publishedInfPathByFile = @{}
    foreach ($inf in $infFiles) {
        Write-Host "Staging driver via pnputil: $($inf.FullName)"
        $pnputilOutput = & pnputil.exe /add-driver "$($inf.FullName)" /install 2>&1
        $pnputilOutput | ForEach-Object { Write-Host "  $_" }
        $publishedInfPath = Get-PnpUtilPublishedInfPath -PnpUtilOutput $pnputilOutput
        if ($publishedInfPath) {
            $publishedInfPathByFile[$inf.FullName] = $publishedInfPath
        } else {
            Write-Host "  Could not determine the published INF path for $($inf.Name) - skipping it for Add-PrinterDriver."
        }
    }

    $installedDriverName = $null
    foreach ($inf in $infFiles) {
        if (-not $publishedInfPathByFile.ContainsKey($inf.FullName)) { continue }
        $publishedInfPath = $publishedInfPathByFile[$inf.FullName]
        $candidates = Get-InfDriverCandidates -InfPath $inf.FullName
        Write-Host "$($inf.Name): candidate driver name(s) found: $($candidates -join ' | ')"
        foreach ($driverName in $candidates) {
            try {
                Add-PrinterDriver -Name $driverName -InfPath $publishedInfPath -ErrorAction Stop
                $installedDriverName = $driverName
                break
            } catch {
                Write-Host "  Add-PrinterDriver failed for '$driverName' ($publishedInfPath): $($_.Exception.Message)"
                continue
            }
        }
        if ($installedDriverName) { break }
    }

    if (-not $installedDriverName) {
        throw "Could not install any printer driver found in '$DriverZipPath' - checked $($infFiles.Count) .inf file(s)."
    }
    Write-Host "Installed printer driver: $installedDriverName"

    Write-Host "Creating printer port $PortName ($PrinterIP)..."
    Add-PrinterPort -Name $PortName -PrinterHostAddress $PrinterIP

    Write-Host "Creating printer $PrinterName..."
    Add-Printer -Name $PrinterName -DriverName $installedDriverName -PortName $PortName

    if (-not (Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue)) {
        throw "Printer '$PrinterName' was not found after Add-Printer."
    }

    Write-Host "Cleaning up temp files..."
    Remove-Item -Path $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $DriverZipPath -Force -ErrorAction SilentlyContinue

    Write-Host "=== Done ==="
    exit 0
}
catch {
    Write-Host "ERROR: Failed to set up printer '$PrinterName': $($_.Exception.Message)"
    exit 1
}
