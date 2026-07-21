<#
VSGN - sets up the "D11-32 MFP Container MFP M430f" network printer (HP LaserJet
Enterprise MFP M430 series, IP 192.168.0.32).

Replaces the old cscript/prnmngr.vbs + install.exe batch approach with native
PowerShell printing cmdlets. That old script had two bugs: `cd /temp` at the end
is not a valid way to switch to C:\temp (should be `cd /d C:\temp`), so cleanup
ran from inside C:\temp\upd instead and silently failed to remove the temp files;
and `install.exe` was invoked with hardcoded switches with no error handling, so a
failed extraction or driver mismatch went unnoticed.

Assumes upd.zip (HP driver package, from
https://support.hp.com/us-en/drivers/hp-laserjet-enterprise-mfp-m430-series/29252393)
is already staged at C:\temp\upd.zip via the SyncroMSP script file attachment
before this script runs. The driver's .inf is located automatically inside the
package, so this keeps working across different driver package layouts without
needing the exact .inf filename or driver name hardcoded.
#>

Import-Module $env:SyncroModule

$PrinterName = "D11-32 MFP Container MFP M430f"
$PrinterIP   = "192.168.0.32"
$PortName    = "IP_$PrinterIP"
$ZipPath     = "C:\temp\upd.zip"
$ExtractDir  = "C:\temp\upd"

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

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $trimmed = ($line -replace ';.*$', '').Trim()
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

try {
    if (-not (Test-Path $ZipPath)) {
        throw "Driver package not found at '$ZipPath' - expected it to be staged there via the SyncroMSP script file attachment."
    }

    Write-Host "=== VSGN Printer Setup: $PrinterName ==="

    Write-Host "Removing existing printer/port if present..."
    Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue | Remove-Printer -ErrorAction SilentlyContinue
    Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue | Remove-PrinterPort -ErrorAction SilentlyContinue

    if (Test-Path $ExtractDir) {
        Remove-Item -Path $ExtractDir -Recurse -Force
    }
    Write-Host "Extracting driver package..."
    Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir -Force

    $infFiles = Get-ChildItem -Path $ExtractDir -Filter "*.inf" -Recurse
    if (-not $infFiles) {
        throw "No .inf file found inside '$ZipPath'."
    }

    $installedDriverName = $null
    foreach ($inf in $infFiles) {
        $candidates = Get-InfDriverCandidates -InfPath $inf.FullName
        foreach ($driverName in $candidates) {
            try {
                Add-PrinterDriver -Name $driverName -InfPath $inf.FullName -ErrorAction Stop
                $installedDriverName = $driverName
                break
            } catch {
                continue
            }
        }
        if ($installedDriverName) { break }
    }

    if (-not $installedDriverName) {
        Write-Host "Direct driver install failed for all candidates, staging via pnputil and retrying..."
        foreach ($inf in $infFiles) {
            pnputil /add-driver "$($inf.FullName)" /install | Out-Null
            $candidates = Get-InfDriverCandidates -InfPath $inf.FullName
            foreach ($driverName in $candidates) {
                try {
                    Add-PrinterDriver -Name $driverName -InfPath $inf.FullName -ErrorAction Stop
                    $installedDriverName = $driverName
                    break
                } catch {
                    continue
                }
            }
            if ($installedDriverName) { break }
        }
    }

    if (-not $installedDriverName) {
        throw "Could not install any printer driver found in '$ZipPath' - checked $($infFiles.Count) .inf file(s)."
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
    Remove-Item -Path $ZipPath -Force -ErrorAction SilentlyContinue

    Write-Host "=== Done ==="
    exit 0
}
catch {
    Rmm-Alert -Category "VSGN Printer Setup" -Body "Failed to set up printer '$PrinterName': $($_.Exception.Message)"
    exit 1
}
