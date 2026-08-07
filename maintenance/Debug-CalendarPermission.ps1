<#
Read-only diagnostic for "user has Owner on a shared mailbox's Calendar folder
(Get-MailboxFolderPermission) but Outlook still throws 'You don't have
permission to create an entry in this folder', while OWA works fine for the
same user".

Background (Zohodesk ticket 56952000034481001, "SiZi Klein" calendar):
Server-side ACL already shows Owner, so the block is not a missing
permission - it's either (a) a client-side Outlook permission cache that
hasn't picked up a permission change yet, or (b) the "Owner" entry was
actually created by an Outlook delegate assignment (Account Settings ->
Delegate Access) rather than by an admin, which behaves differently for
calendar item creation than a plain folder ACL grant. This script gathers
the evidence needed to tell those apart:
  - Get-MailboxPermission (unfiltered, mailbox-level Full Access)
  - Get-MailboxFolderPermission on the target folder, including
    SharingPermissionFlags (present only on true Outlook delegate grants)
    and IsValid
  - Search-AdminAuditLog for who/when set that folder permission

Makes no changes. Prints everything for manual review.

Deployed as a SyncroMSP script asset-scoped to the Exchange server itself
(not a client endpoint) - see syncro_wrapper_debug_calendar_permission.ps1.

Run as: the logged-in user, not SYSTEM (set this in Syncro's "Run As" option
when executing the script). Exchange cmdlets aren't loaded by default in a
plain PowerShell host, so this script bootstraps them itself via
RemoteExchange.ps1 - the same bootstrap the EMS shortcut runs, present on
every on-prem Exchange 2013+ install. That bootstrap internally opens a
WinRM session to the local server by hostname, and running as SYSTEM makes
that a same-machine NTLM authentication attempt, which Windows blocks by
default (the "NTLM loopback" protection) - it hangs for the full 10-minute
Connect-ExchangeServer retry window and then fails outright. Running as an
interactive logged-in domain admin uses Kerberos instead, which isn't
subject to that restriction, and also means the identity actually holds an
Exchange RBAC role (SYSTEM's computer account normally holds none, which
would fail Search-AdminAuditLog in [4/4] even if the connection itself
succeeded). The account running this must be a member of an Exchange RBAC
role group (e.g. Organization Management, or at least View-Only
Organization Management for Search-AdminAuditLog).

Purely read-only diagnostic with no side effects to dry-run, so this was not
worth building a Mock-SyncroModule/Test-Local.ps1 harness for (see
syncro-new-script skill) - the first real Syncro run against the Exchange
server is the test. Read the run log for that.

Params come through Syncro's UI (generated from the param() block below).
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$MailboxIdentity,

    [Parameter(Mandatory = $true)]
    [string]$DelegateIdentity,

    [string]$FolderName = "Calendar",

    [int]$AuditLogDays = 90
)

Import-Module $env:SyncroModule

# The Syncro agent launches a plain PowerShell host, not the Exchange
# Management Shell, so Exchange cmdlets aren't loaded yet. RemoteExchange.ps1
# is the same bootstrap the EMS shortcut itself runs; it lives in every
# on-prem Exchange install (2013+).
if (-not (Get-Command Get-Mailbox -ErrorAction SilentlyContinue)) {
    Write-Host "Exchange cmdlets not loaded - bootstrapping via RemoteExchange.ps1..."
    $bootstrap = Join-Path $env:ExchangeInstallPath "bin\RemoteExchange.ps1"
    if (-not (Test-Path $bootstrap)) {
        Rmm-Alert -Category "Calendar Permission Debug" -Body "RemoteExchange.ps1 not found at '$bootstrap' - this script must run on an on-prem Exchange server (`$env:ExchangeInstallPath not set or wrong). Aborting."
        exit 1
    }
    try {
        . $bootstrap
        Connect-ExchangeServer -auto -ErrorAction Stop
    } catch {
        Rmm-Alert -Category "Calendar Permission Debug" -Body "Failed to load Exchange cmdlets via RemoteExchange.ps1: $($_.Exception.Message). Check that the SYSTEM account has an Exchange RBAC role assignment."
        exit 1
    }
}

Write-Host "=== Calendar Permission Debug ==="
Write-Host "Mailbox: $MailboxIdentity  |  Delegate/User: $DelegateIdentity  |  Folder: $FolderName  |  $(Get-Date)"

# --- [1/4] Mailbox sanity check ---
Write-Host ""
Write-Host "[1/4] Mailbox lookup..."
try {
    $mbx = Get-Mailbox -Identity $MailboxIdentity -ErrorAction Stop
    Write-Host "  Found: $($mbx.DisplayName) <$($mbx.PrimarySmtpAddress)> - Type: $($mbx.RecipientTypeDetails)"
} catch {
    Rmm-Alert -Category "Calendar Permission Debug" -Body "Could not find mailbox '$MailboxIdentity': $($_.Exception.Message)"
    exit 1
}

$folderIdentity = "${MailboxIdentity}:\$FolderName"

# Get-MailboxPermission/-MailboxFolderPermission return the resolved
# DisplayName in their User field (e.g. "Christa Stocker"), not whatever
# identity form was passed in (e.g. "christa.stocker" or an email address) -
# a plain "-like *$DelegateIdentity*" match against that field silently
# misses every real match unless the two happen to be spelled the same.
# Resolve the delegate up front and match against every known identity form.
$delegateMatchTerms = @($DelegateIdentity)
try {
    $delegateRecipient = Get-Recipient -Identity $DelegateIdentity -ErrorAction Stop
    $delegateMatchTerms += @($delegateRecipient.DisplayName, $delegateRecipient.Alias, $delegateRecipient.Name, $delegateRecipient.PrimarySmtpAddress.ToString()) | Where-Object { $_ }
    Write-Host "Resolved delegate '$DelegateIdentity' to: $($delegateRecipient.DisplayName) <$($delegateRecipient.PrimarySmtpAddress)>"
} catch {
    Write-Host "WARNING: Could not resolve '$DelegateIdentity' via Get-Recipient ($($_.Exception.Message)) - matching against the raw identity string only, which may miss entries listed under a display name."
}
function Test-IsDelegateEntry {
    param($UserField)
    if (-not $UserField) { return $false }
    $text = $UserField.ToString()
    foreach ($term in $delegateMatchTerms) {
        if ($text -like "*$term*") { return $true }
    }
    return $false
}

# --- [2/4] Mailbox-level permissions (unfiltered) ---
Write-Host ""
Write-Host "[2/4] Get-MailboxPermission (unfiltered)..."
$mbxPerms = Get-MailboxPermission -Identity $MailboxIdentity
$mbxPerms | ForEach-Object {
    Write-Host "  User: $($_.User)  AccessRights: $($_.AccessRights -join ',')  IsInherited: $($_.IsInherited)  Deny: $($_.Deny)"
}
$delegateMbxPerm = $mbxPerms | Where-Object { Test-IsDelegateEntry $_.User }
if ($delegateMbxPerm) {
    Write-Host "  NOTE: '$DelegateIdentity' HAS mailbox-level permission(s) above."
} else {
    Write-Host "  NOTE: '$DelegateIdentity' has NO direct or group-based mailbox-level permission (expected if only folder-level access was granted)."
}

# --- [3/4] Folder-level permissions on the target folder ---
Write-Host ""
Write-Host "[3/4] Get-MailboxFolderPermission on '$folderIdentity'..."
try {
    $folderPerms = Get-MailboxFolderPermission -Identity $folderIdentity -ErrorAction Stop
    $folderPerms | ForEach-Object {
        $flags = if ($_.SharingPermissionFlags) { $_.SharingPermissionFlags -join ',' } else { "(none)" }
        Write-Host "  User: $($_.User)  AccessRights: $($_.AccessRights -join ',')  SharingPermissionFlags: $flags  IsValid: $($_.IsValid)"
    }
    $delegateFolderPerm = $folderPerms | Where-Object { Test-IsDelegateEntry $_.User } | Select-Object -First 1
    if ($delegateFolderPerm) {
        if ($delegateFolderPerm.SharingPermissionFlags -and $delegateFolderPerm.SharingPermissionFlags -contains "Delegate") {
            Write-Host "  CONFIRMED: '$DelegateIdentity' entry has SharingPermissionFlags=Delegate -> this was set via Outlook delegate access (Account Settings -> Delegate Access), NOT an admin ACL grant."
            Write-Host "  Delegate assignments carry their own 'deliver meeting requests to delegate only' / free-busy behavior in Outlook that a plain folder ACL doesn't - this commonly causes 'Owner on the ACL but Outlook still blocks item creation' symptoms until the delegate record itself is fixed or re-created (e.g. via the mailbox owner's Outlook, or MFCMAPI on the mailbox's PR_DELEGATES property)."
        } else {
            Write-Host "  '$DelegateIdentity' entry has NO Delegate flag -> plain folder ACL grant, not an Outlook delegate assignment. A stale Outlook permission cache is more likely; try a full Outlook restart (Exit, verify OUTLOOK.EXE gone in Task Manager, relaunch) before further investigation."
        }
        if (-not $delegateFolderPerm.IsValid) {
            Write-Host "  WARNING: IsValid = False on this entry - the permission record itself may be corrupted."
        }
    } else {
        Write-Host "  NOTE: No folder permission entry found for '$DelegateIdentity' on '$folderIdentity'."
    }
} catch {
    Rmm-Alert -Category "Calendar Permission Debug" -Body "Could not read folder permissions on '$folderIdentity': $($_.Exception.Message)"
}

# --- [4/4] Admin audit log: who/when changed this folder's permissions ---
Write-Host ""
Write-Host "[4/4] Search-AdminAuditLog for folder permission changes on '$MailboxIdentity' (last $AuditLogDays days)..."
try {
    $auditEntries = Search-AdminAuditLog -Cmdlets Add-MailboxFolderPermission, Set-MailboxFolderPermission, Remove-MailboxFolderPermission `
        -ObjectIds "*$MailboxIdentity*" -StartDate (Get-Date).AddDays(-$AuditLogDays) -ErrorAction Stop
    if ($auditEntries) {
        $auditEntries | Sort-Object RunDate | ForEach-Object {
            $params = ($_.CmdletParameters | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '
            Write-Host "  [$($_.RunDate)] $($_.Caller) ran $($_.CmdletName) - $params"
        }
    } else {
        Write-Host "  No matching audit log entries found. Either admin audit logging is disabled/not retaining $AuditLogDays days, or this permission was never set via an EMS cmdlet (consistent with an Outlook-side delegate assignment - see [3/4])."
    }
} catch {
    Rmm-Alert -Category "Calendar Permission Debug" -Body "Could not query admin audit log: $($_.Exception.Message) (requires View-Only Organization Management or higher role; verify with Get-AdminAuditLogConfig -> AdminAuditLogEnabled)"
}

Write-Host ""
Write-Host "=== Done ==="
Write-Host "No changes made. Review [3/4] first: a 'Delegate' SharingPermissionFlags entry points at an Outlook-side delegate record as the real cause, not a server ACL problem."

exit 0
