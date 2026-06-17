Import-Module $env:SyncroModule -DisableNameChecking
$customAssetField = "Virtual Machine"  # This field will need to be created in Admin --> Custom Asset Fields

$cs = Get-WmiObject -Class Win32_ComputerSystem
$bios = Get-WmiObject -Class Win32_BIOS

$manufacturer = $cs.Manufacturer
$model = $cs.Model
$biosVersion = $bios.SMBIOSBIOSVersion

$hypervisor = $null

if ($manufacturer -match "VMware") {
    $hypervisor = "VMware"
} elseif ($manufacturer -match "Microsoft" -and $model -match "Virtual Machine") {
    $hypervisor = "Hyper-V"
} elseif ($manufacturer -match "innotek|Oracle" -or $model -match "VirtualBox") {
    $hypervisor = "VirtualBox"
} elseif ($manufacturer -match "QEMU" -or $biosVersion -match "QEMU") {
    $hypervisor = "QEMU/KVM"
} elseif ($model -match "HVM domU" -or $biosVersion -match "Xen") {
    $hypervisor = "Xen"
} elseif ($manufacturer -match "Parallels" -or $model -match "Parallels") {
    $hypervisor = "Parallels"
}

if ($null -ne $hypervisor) {
    Set-Asset-Field -Name $customAssetField -Value $hypervisor
    Write-Host "Virtual device detected: $hypervisor (Manufacturer: $manufacturer, Model: $model)"
} else {
    Set-Asset-Field -Name $customAssetField -Value "No"
    Write-Host "Physical device (Manufacturer: $manufacturer, Model: $model)"
}

exit 0
