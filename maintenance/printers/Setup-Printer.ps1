<#
Sets up a network printer using the HP Universal Print Driver (PCL6), downloaded
directly from HP at runtime. Not intended as a direct SyncroMSP endpoint script -
run indirectly via a thin per-printer syncro_wrapper_*.ps1 (see
syncro_wrapper_vsgn_d11_32.ps1 for an example), which is what actually gets pasted
into Syncro. This script is the source of truth - keep wrappers in sync if its
parameters change.

Originally written for a single VSGN printer, generalized so the same driver
logic can be reused for other printers/customers without duplicating it per
wrapper.

Downloads the driver zip from ftp.hp.com (Akamai-hosted, stable static file -
unlike the JS-rendered support.hp.com driver pages, which can't be scripted
against). Bump -DriverUrl's default when HP releases a newer UPD version.

Stages every .inf in the package via pnputil (trusting the HP signing
certificate first - unattended pnputil otherwise rejects it with "the
publisher of an Authenticode-signed catalog has not yet been established as
trusted", since that trust is normally granted via an interactive
click-through dialog that can't appear when running as SYSTEM). Windows
republishes each staged .inf under C:\Windows\INF\oemXX.inf - Add-PrinterDriver
has to be pointed at that published copy, not the original extracted file, or
it fails with a generic "parameter is incorrect" (HRESULT 0x80070057). Driver
names are parsed out of the .inf's model section (skipping the [Manufacturer]
section, which has the same "name = target, arch" shape but isn't a model
entry) since the exact name varies per driver package and isn't worth
hardcoding.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$PrinterName,

    [Parameter(Mandatory = $true)]
    [string]$PrinterIP,

    [string]$PortName = "IP_$PrinterIP",

    [string]$DriverUrl = "https://ftp.hp.com/pub/softlib/software13/printers/UPD/upd-pcl6-win11-x64-8.2.0.26819.zip",

    [string]$DriverZipPath = "C:\temp\hp_upd_pcl6.zip",

    [string]$ExtractDir = "C:\temp\hp_upd_pcl6"
)

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
    Write-Host "=== Printer Setup: $PrinterName ==="

    Write-Host "Downloading driver package from $DriverUrl..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -Path (Split-Path $DriverZipPath) -ItemType Directory -Force | Out-Null
    (New-Object Net.WebClient).DownloadFile($DriverUrl, $DriverZipPath)

    # Match on port (IP), not just name, so a printer left over under a
    # previous/renamed -PrinterName on this same IP still gets cleaned up -
    # a printer must be removed before its port can be removed.
    Write-Host "Removing existing printer(s) on '$PrinterName' or port '$PortName' if present..."
    Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $PrinterName -or $_.PortName -eq $PortName } | Remove-Printer -ErrorAction SilentlyContinue
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
