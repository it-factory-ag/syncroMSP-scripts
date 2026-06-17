Import-Module $env:SyncroModule

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

$result = $interface.SetBIOSSetting($setting.Name, "Disable", "<utf-16/>")
if ($result.Return -eq 0) {
    Write-Host "OK: '$($setting.Name)' disabled"
} else {
    Write-Host "ERROR: SetBIOSSetting returned code $($result.Return)"
    Write-Host "       Code 4 usually means a BIOS admin password is set - provide it as the third parameter"
    exit 1
}
