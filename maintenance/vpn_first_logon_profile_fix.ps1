Import-Module $env:SyncroModule

# Sets the two local policy values that fix a failed first-time domain login
# over VPN: Windows creates an empty profile folder and login fails with
#   "Windows cannot log you on because your profile cannot be loaded...
#    DETAIL - The group or resource is not in the correct state to perform
#    the requested operation." (ERROR_GROUP_NOT_IN_CORRECT_STATE)
#
# Root cause: Group Policy slow-link detection race condition during first
# profile creation + domain join over a VPN with elevated latency - see:
# https://wiki.prod.itfactory.ch/doc/erstanmeldung-domanenaccount-via-vpn-schlagt-fehl-FymRUwXiLV
#
# Sets locally (equivalent to the domain GPO, scoped to this device instead
# of an OU) both settings from:
#   Computer Configuration > Administrative Templates > System > Logon
#     "Always wait for the network at computer startup and logon" -> Enabled
#   Computer Configuration > Administrative Templates > System > Group Policy
#     "Configure Group Policy slow link detection" -> Enabled, 0 Kbps
#
# Runs gpupdate /force and reboots the device afterwards - Fast Logon
# Optimization only applies at boot, so a running gpupdate alone is not enough.

Write-Host "=== VPN First-Logon GPO Fix ==="

$winlogonKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Winlogon"
$gpSystemKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"

if (-not (Test-Path $winlogonKey)) {
    New-Item -Path $winlogonKey -Force | Out-Null
}
New-ItemProperty -Path $winlogonKey -Name "SyncForegroundPolicy" -Value 1 -PropertyType DWord -Force | Out-Null
Write-Host "Set 'Always wait for the network at computer startup and logon' = Enabled"

if (-not (Test-Path $gpSystemKey)) {
    New-Item -Path $gpSystemKey -Force | Out-Null
}
New-ItemProperty -Path $gpSystemKey -Name "GroupPolicyMinTransferRate" -Value 0 -PropertyType DWord -Force | Out-Null
Write-Host "Set 'Configure Group Policy slow link detection' = Enabled, 0 Kbps"

Write-Host ""
Write-Host "Refreshing Group Policy..."
gpupdate /force | Out-Null

Write-Host ""
Write-Host "=== Done ==="
Write-Host "Rebooting in 60 seconds - these settings only take effect at boot."
shutdown /r /t 60 /c "Applying VPN login fix - device will restart in 60 seconds." /f

exit 0
