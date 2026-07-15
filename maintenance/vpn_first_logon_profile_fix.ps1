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

# Diagnostics for the separate "wrong password when offline" symptom seen after
# the first VPN login succeeds. That is a cached-credentials issue, not related
# to the two settings above - see:
# https://wiki.prod.itfactory.ch/doc/erstanmeldung-domanenaccount-via-vpn-schlagt-fehl-FymRUwXiLV
Write-Host ""
Write-Host "=== Offline Logon Diagnostics ==="

$winlogonPolicyKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$cachedLogonsCount = (Get-ItemProperty -Path $winlogonPolicyKey -Name "CachedLogonsCount" -ErrorAction SilentlyContinue).CachedLogonsCount
if ($null -eq $cachedLogonsCount) {
    Write-Host "CachedLogonsCount: not set (Windows default = 10, offline logon should work)"
} elseif ($cachedLogonsCount -eq 0) {
    Write-Host "CachedLogonsCount: 0 -> offline domain logon is DISABLED on this device. This is the likely cause."
} else {
    Write-Host "CachedLogonsCount: $cachedLogonsCount (offline logon allowed)"
}

$subStatusMap = @{
    "0xc000006a" = "Wrong password (bad cached credential or stale cache entry)"
    "0xc0000064" = "User does not exist"
    "0xc0000234" = "Account locked out"
    "0xc0000072" = "Account disabled"
    "0xc0000071" = "Password expired"
    "0xc0000073" = "No logon servers available for this account (cached creds invalid/missing)"
    "0xc000005e" = "No logon servers currently available"
}

Write-Host ""
Write-Host "Recent failed logons (Security log, Event ID 4625, last 20):"
$failedLogons = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625 } -MaxEvents 20 -ErrorAction SilentlyContinue
if (-not $failedLogons) {
    Write-Host "No Event ID 4625 entries found."
} else {
    foreach ($logonEvent in $failedLogons) {
        $xml = [xml]$logonEvent.ToXml()
        $data = $xml.Event.EventData.Data
        $user = ($data | Where-Object { $_.Name -eq 'TargetUserName' }).'#text'
        $status = ($data | Where-Object { $_.Name -eq 'Status' }).'#text'
        $subStatus = ($data | Where-Object { $_.Name -eq 'SubStatus' }).'#text'
        $subStatusText = $subStatusMap[$subStatus]
        if (-not $subStatusText) { $subStatusText = "unknown" }
        Write-Host "$($logonEvent.TimeCreated)  User=$user  Status=$status  SubStatus=$subStatus ($subStatusText)"
    }
}

Write-Host ""
Write-Host "=== Done ==="
Write-Host "Rebooting in 60 seconds - these settings only take effect at boot."
shutdown /r /t 60 /c "Applying VPN login fix - device will restart in 60 seconds." /f

exit 0
