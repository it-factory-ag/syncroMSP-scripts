Import-Module $env:SyncroModule

# Set BIOS admin password here if one is configured, otherwise leave empty
$biosPassword = ""

$manufacturer = (Get-WmiObject Win32_ComputerSystem).Manufacturer
if ($manufacturer -notmatch "HP|Hewlett") {
    Write-Host "Not an HP machine - Sure Start not applicable"
    exit 0
}

try {
    $interface = Get-WmiObject -Namespace root\HP\InstrumentedBIOS -Class HP_BIOSSettingInterface -ErrorAction Stop
} catch {
    Write-Host "ERROR: HP BIOS WMI interface not available: $($_.Exception.Message)"
    exit 1
}

# Find the Sure Start setting - naming varies by HP model/BIOS version
# e.g. "Sure Start Secure Boot Keys Protection" or "SureStart Production Mode"
$setting = Get-WmiObject -Namespace root\HP\InstrumentedBIOS -Class HP_BIOSSetting |
    Where-Object { $_.Name -like "*Sure*Start*" -or $_.Name -like "*SureStart*" } |
    Select-Object -First 1

if (-not $setting) {
    Write-Host "No Sure Start setting found on this model - nothing to do"
    exit 0
}

Write-Host "Available Sure Start settings on this model:"
Get-WmiObject -Namespace root\HP\InstrumentedBIOS -Class HP_BIOSSetting |
    Where-Object { $_.Name -like "*Sure*" -or $_.Name -like "*SureStart*" } |
    ForEach-Object { Write-Host "  $($_.Name) = $($_.Value)" }

Write-Host "Found setting: '$($setting.Name)' = '$($setting.Value)'"

$passwordParam = if ($biosPassword) { "<utf-16/>$biosPassword" } else { "<utf-16/>" }
$result = $interface.SetBIOSSetting($setting.Name, "Disable", $passwordParam)

switch ($result.Return) {
    0 { Write-Host "OK: '$($setting.Name)' disabled - reboot required for change to take effect" }
    4 {
        Write-Host "ERROR: BIOS admin password required (code 4)"
        Write-Host "       Set the `$biosPassword variable in the script to the BIOS admin password"
        exit 1
    }
    6 {
        Write-Host "ERROR: Setting is read-only / protected by Sure Start (code 6)"
        Write-Host "       This model requires a BIOS admin password to change Sure Start settings."
        Write-Host "       Set the `$biosPassword variable in the script to the BIOS admin password."
        Write-Host "       If no password is set, this must be changed manually in the BIOS setup (F10 at boot)."
        exit 1
    }
    default {
        Write-Host "ERROR: SetBIOSSetting returned code $($result.Return)"
        exit 1
    }
}
