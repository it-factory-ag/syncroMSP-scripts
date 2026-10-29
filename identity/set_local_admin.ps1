# No param() block on purpose: Syncro injects Script Variables as plain assignments
# at the top of the script, so param() would no longer be first and break.
# Syncro variable (type runtime, required) "UserPrincipalName": e.g. firstname.lastname@customer.ch
# Optional Syncro variable (Dropdown) "Action":
#   Add    = add the Entra user to the local Administrators group
#   Remove = remove the Entra user from the local Administrators group
if (-not $Action) { $Action = "Add" }

Import-Module $env:SyncroModule

if ($Action -notin @("Add", "Remove")) {
    Write-Host "ERROR: Invalid Action '$Action' (allowed: Add, Remove)"
    exit 1
}
if ($UserPrincipalName -notmatch '^[^@\s\\]+@[^@\s\\]+\.[^@\s\\]+$') {
    Write-Host "ERROR: UserPrincipalName '$UserPrincipalName' is missing or not a valid UPN"
    exit 1
}

# Makes an Entra user local admin on this one device (or reverts it).
#
# Background: Without Intune (Entra ID Free) the only central option is the
# tenant-wide role "Microsoft Entra Joined Device Local Administrator". For a
# single user on their own device, the local group is left, account format AzureAD\<UPN>.
# Guide: https://wiki.prod.itfactory.ch/doc/anleitung-gerate-auf-entra-join-umstellen-mShrrN2FDn
#
# net localgroup instead of Add-LocalGroupMember: the LocalAccounts cmdlets fail
# as soon as the group contains an unresolvable Entra account.
# Group name resolved from the well-known SID, so it works on German and English Windows.
# Runs as SYSTEM. Takes effect at the user's next sign-in.

Write-Host "=== Local admin: $Action AzureAD\$UserPrincipalName ==="

$dsreg = & dsregcmd /status | Out-String
if ($dsreg -notmatch 'AzureAdJoined\s*:\s*YES') {
    Write-Host "ERROR: Device is not Entra-joined (dsregcmd: AzureAdJoined != YES), AzureAD\ accounts don't work here"
    exit 1
}

$group = (New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[1]
$account = "AzureAD\$UserPrincipalName"
$flag = if ($Action -eq "Add") { "/add" } else { "/delete" }

$out = & net localgroup "$group" "$account" $flag 2>&1 | Out-String
$code = $LASTEXITCODE

# 1378 = already a member, 1377 = not a member: target state already reached
if ($code -eq 0) {
    Write-Host "OK: $account $(if ($Action -eq 'Add') { 'is now a member of' } else { 'removed from' }) '$group'"
}
elseif ($out -match '\b1378\b' -and $Action -eq "Add") {
    Write-Host "OK: $account is already a member of '$group'"
}
elseif ($out -match '\b1377\b' -and $Action -eq "Remove") {
    Write-Host "OK: $account was not a member of '$group'"
}
else {
    $hint = if ($out -match '\b1332\b') { " Account not resolvable: check the UPN or let the user sign in to the device once." } else { "" }
    Write-Host "ERROR (net exit $code): $($out.Trim())$hint"
    Rmm-Alert -Category "Local Admin" -Body "$Action $account in '$group' failed (net exit $code): $($out.Trim())$hint"
    exit 1
}

Write-Host ""
Write-Host "Current members of '$group':"
& net localgroup "$group"
Write-Host "Takes effect at the user's next sign-in."
exit 0
