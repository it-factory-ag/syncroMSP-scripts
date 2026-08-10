<#
Read-only diagnostic for "user has Owner on a shared mailbox's Calendar folder
(Get-MailboxFolderPermission) but Outlook still throws 'You don't have
permission to create an entry in this folder', while OWA works fine for the
same user".

Background (Zohodesk ticket 56952000034481001, "SiZi Klein" calendar):
Server-side ACL already shows Owner, so the block is not a missing
permission. Ruled out so far:
  - Outlook delegate assignment (Account Settings -> Delegate Access) as the
    source of the "Owner" entry - would show SharingPermissionFlags=Delegate
    on Get-MailboxFolderPermission; it doesn't, this is a plain ACL grant.
  - A stale client-side Outlook permission cache - reproduced on a brand new
    client with a freshly created profile, so it isn't specific to one
    machine's cache.
  - A stale/incorrectly-written ACE fixed by forcing Exchange to rewrite it
    (remove + re-add via -Remediate) - tried against this exact ticket's
    mailbox/delegate and did NOT fix it, so whatever's wrong survives a
    clean rewrite of the "visible" ACE.
Also ruled out, going further than folder ACL: granting the delegate
mailbox-level FullAccess (bypasses all per-folder ACL checks entirely) did
NOT fix it either, and a second user with their own independent Owner ACE
hit the identical error - so this is not permission- or identity-specific
at all anymore. Confirmed instead: adding the mailbox as a full additional
account in Outlook crashes Outlook itself, reliably, with an access
violation (0xc0000005) inside EMSMDB32.DLL - Outlook's on-prem Exchange MAPI
provider. EMSMDB32.DLL isn't used by OWA/EWS at all, which is consistent
with OWA working throughout. This points at store/folder-level corruption
that Outlook's MAPI provider chokes on hard (crash) or reports misleadingly
(the original "no permission" dialog may be the same underlying fault
surfacing through different, better-guarded code paths for a narrower
operation).

Remaining escalation order:
  1. Broader mailbox/folder corruption, beyond the FolderACL corruption type
     already checked (and found clean) - [6/6] below runs
     New-MailboxRepairRequest -DetectOnly across ProvisionedFolder,
     SearchFolder, MissingSpecialFolders, ReplState, RestrictionFolder,
     FolderView, and AggregateCounts (the ones plausible for a
     load-time/open-time crash), via -CheckCorruption.
  2. A stale/duplicate entry sitting in the folder's raw MAPI ACL table
     *outside* what Get-/Remove-MailboxFolderPermission can see or touch at
     all - a documented Exchange pattern, see
     https://blog.icewolf.ch/archive/2022/12/30/how-to-delete-mapi-permission-if-remove-mailboxfolderpermission-does-not/
     - requires MFCMAPI (Other Tables -> ACL Table on the folder) to find
     and remove directly; a cmdlet-level remove+re-add (already tried, see
     above) does not reach these. Tried on this ticket's mailbox with no
     Outlook crash reproduced there (different code path - opening the
     folder as a shared calendar vs. adding the whole mailbox as an
     account), so still open.
  3. A duplicate/orphaned Calendar-type folder - if a second folder with
     FolderType Calendar exists in the mailbox (e.g. left over from a
     restore/migration), Outlook's MAPI client can resolve the *default*
     calendar via a different, hidden pointer than the one
     Get-MailboxFolderPermission/OWA operate on, so the permission being
     checked and fixed isn't the one Outlook is actually opening. [5/6]
     below checks for this via Get-MailboxFolderStatistics - already run
     once and came back clean (only one Calendar folder), kept in the
     script since it's cheap and worth re-checking after any repair.

This script gathers the evidence:
  - Get-MailboxPermission (unfiltered, mailbox-level Full Access)
  - Get-MailboxFolderPermission on the target folder, including
    SharingPermissionFlags (present only on true Outlook delegate grants)
    and IsValid
  - Search-AdminAuditLog for who/when set that folder permission
  - Get-MailboxFolderStatistics -FolderScope Calendar, to catch a duplicate
    Calendar-type folder
  - With -CheckCorruption: New-MailboxRepairRequest -DetectOnly across
    several corruption types plausible for a mailbox-open-time crash

Read-only by default; prints everything for manual review. -Remediate is the
one opt-in action this script can take (see below) - everything else makes
no changes.

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
would fail Search-AdminAuditLog in [4/6] even if the connection itself
succeeded). The account running this must be a member of an Exchange RBAC
role group (e.g. Organization Management, or at least View-Only
Organization Management for Search-AdminAuditLog).

-Remediate is the one non-read-only path: if the delegate's existing folder
permission entry is a plain (non-Delegate, valid) ACE, it removes and
re-adds that exact same AccessRights entry - a small, well-understood,
instantly-repeatable action (worst case the entry is briefly gone and
recreated within the same script run) that forces Exchange to rewrite the
ACE cleanly. If a stale/duplicate entry sits outside what
Get-/Remove-MailboxFolderPermission can see, this will not fix it - MFCMAPI
against the raw ACL table is the next escalation (see link above). Because
of this one side effect, this was still not worth a Mock-SyncroModule/
Test-Local.ps1 harness (see syncro-new-script skill): removing and re-adding
a folder permission is trivially reversible and safe to verify on the first
real Syncro run.

-CheckCorruption is the other opt-in path: it only ever runs
New-MailboxRepairRequest with -DetectOnly, so it never modifies the mailbox
- it just reports CorruptionsDetected per corruption type and prints the
exact command to run manually (without -DetectOnly) if something turns up,
since actually repairing store-level corruption is judgment-call territory,
not something to fire blindly from an RMM script. Each corruption type is
submitted as its own repair request and the script polls
Get-MailboxRepairRequest until it reports Succeeded/Failed before moving on
to the next (FolderView and AggregateCounts must run alone per Microsoft's
docs; the rest are batched together) - this can take several minutes total,
which is fine for an on-demand diagnostic run but means don't enable it by
default for routine use.

Params come through Syncro's UI (generated from the param() block below).
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$MailboxIdentity,

    [Parameter(Mandatory = $true)]
    [string]$DelegateIdentity,

    [string]$FolderName = "Calendar",

    [int]$AuditLogDays = 90,

    # Remove + re-add the delegate's existing folder permission to force
    # Exchange to rewrite the ACL entry cleanly. Only acts on a plain,
    # already-valid, non-Delegate entry found in [3/6] - never creates a
    # permission that wasn't already there.
    [switch]$Remediate,

    # Run New-MailboxRepairRequest -DetectOnly across several corruption
    # types plausible for a mailbox/folder open-time crash. Detect-only,
    # never repairs automatically - see header comment.
    [switch]$CheckCorruption
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

# --- [1/6] Mailbox sanity check ---
Write-Host ""
Write-Host "[1/6] Mailbox lookup..."
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
# Dots/underscores -> spaces first, since that alone turns a "firstname.lastname"
# style identity into something that already matches a "Firstname Lastname"
# DisplayName - this works even when Get-Recipient can't resolve the identity
# at all (e.g. it doesn't match Alias/UPN/SamAccountName exactly).
$normalizedIdentity = ($DelegateIdentity -replace '[._]', ' ').Trim()
$delegateMatchTerms = @($DelegateIdentity, $normalizedIdentity) | Select-Object -Unique
try {
    $delegateRecipient = Get-Recipient -Identity $DelegateIdentity -ErrorAction Stop
    $delegateMatchTerms += @($delegateRecipient.DisplayName, $delegateRecipient.Alias, $delegateRecipient.Name, $delegateRecipient.PrimarySmtpAddress.ToString()) | Where-Object { $_ }
    Write-Host "Resolved delegate '$DelegateIdentity' to: $($delegateRecipient.DisplayName) <$($delegateRecipient.PrimarySmtpAddress)>"
} catch {
    Write-Host "WARNING: Could not resolve '$DelegateIdentity' via Get-Recipient ($($_.Exception.Message)) - trying a DisplayName search instead."
    $tokens = @($normalizedIdentity -split '\s+' | Where-Object { $_ })
    if ($tokens.Count -gt 0) {
        $filter = ($tokens | ForEach-Object { "DisplayName -like '*$_*'" }) -join ' -and '
        $candidates = @(Get-Recipient -Filter $filter -ErrorAction SilentlyContinue)
        if ($candidates.Count -eq 1) {
            $delegateRecipient = $candidates[0]
            $delegateMatchTerms += @($delegateRecipient.DisplayName, $delegateRecipient.Alias, $delegateRecipient.Name, $delegateRecipient.PrimarySmtpAddress.ToString()) | Where-Object { $_ }
            Write-Host "Resolved delegate '$DelegateIdentity' via DisplayName search to: $($delegateRecipient.DisplayName) <$($delegateRecipient.PrimarySmtpAddress)>"
        } elseif ($candidates.Count -gt 1) {
            Write-Host "WARNING: Multiple recipients matched a DisplayName search for '$DelegateIdentity': $(($candidates | ForEach-Object { $_.DisplayName }) -join ', ') - not auto-resolving further; matching against '$DelegateIdentity' / '$normalizedIdentity' only."
        } else {
            Write-Host "WARNING: DisplayName search for '$DelegateIdentity' found no recipient either - matching against '$DelegateIdentity' / '$normalizedIdentity' only, which may still miss entries listed under an unrelated identity form."
        }
    }
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

# --- [2/6] Mailbox-level permissions (unfiltered) ---
Write-Host ""
Write-Host "[2/6] Get-MailboxPermission (unfiltered)..."
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

# --- [3/6] Folder-level permissions on the target folder ---
Write-Host ""
Write-Host "[3/6] Get-MailboxFolderPermission on '$folderIdentity'..."
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
            Write-Host "  '$DelegateIdentity' entry has NO Delegate flag -> plain folder ACL grant, not an Outlook delegate assignment."
            Write-Host "  If a stale client-side Outlook cache has already been ruled out (e.g. reproduced on a fresh client/profile), the leading suspect is a server-side desync between this clean ACE and a stale/duplicate entry in the folder's raw MAPI ACL table, which Outlook (MAPI) evaluates but Get-MailboxFolderPermission does not show. Re-run with -Remediate to force Exchange to rewrite this ACE (remove + re-add same rights); if that doesn't fix it, escalate to MFCMAPI directly on the folder's ACL Table."

            if ($Remediate) {
                Write-Host ""
                Write-Host "[3/6] -Remediate: removing and re-adding '$($delegateFolderPerm.User)' ($($delegateFolderPerm.AccessRights -join ',')) on '$folderIdentity'..."
                try {
                    $rightsToRestore = $delegateFolderPerm.AccessRights
                    Remove-MailboxFolderPermission -Identity $folderIdentity -User $delegateFolderPerm.User -Confirm:$false -ErrorAction Stop
                    Add-MailboxFolderPermission -Identity $folderIdentity -User $delegateFolderPerm.User -AccessRights $rightsToRestore -ErrorAction Stop
                    $recheck = Get-MailboxFolderPermission -Identity $folderIdentity | Where-Object { Test-IsDelegateEntry $_.User } | Select-Object -First 1
                    Write-Host "  Done. Re-checked entry: User: $($recheck.User)  AccessRights: $($recheck.AccessRights -join ',')  IsValid: $($recheck.IsValid)"
                    Write-Host "  Have the user fully restart Outlook (Exit, verify OUTLOOK.EXE gone in Task Manager, relaunch) and retest before concluding this did or didn't help."
                } catch {
                    Rmm-Alert -Category "Calendar Permission Debug" -Body "-Remediate failed to remove/re-add folder permission for '$($delegateFolderPerm.User)' on '$folderIdentity': $($_.Exception.Message)"
                }
            }
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

# --- [4/6] Admin audit log: who/when changed this folder's permissions ---
Write-Host ""
Write-Host "[4/6] Search-AdminAuditLog for folder permission changes on '$MailboxIdentity' (last $AuditLogDays days)..."
try {
    $auditEntries = Search-AdminAuditLog -Cmdlets Add-MailboxFolderPermission, Set-MailboxFolderPermission, Remove-MailboxFolderPermission `
        -ObjectIds "*$MailboxIdentity*" -StartDate (Get-Date).AddDays(-$AuditLogDays) -ErrorAction Stop
    if ($auditEntries) {
        $auditEntries | Sort-Object RunDate | ForEach-Object {
            $params = ($_.CmdletParameters | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '
            Write-Host "  [$($_.RunDate)] $($_.Caller) ran $($_.CmdletName) - $params"
        }
    } else {
        Write-Host "  No matching audit log entries found. Either admin audit logging is disabled/not retaining $AuditLogDays days, or this permission was never set via an EMS cmdlet (consistent with an Outlook-side delegate assignment - see [3/6])."
    }
} catch {
    Rmm-Alert -Category "Calendar Permission Debug" -Body "Could not query admin audit log: $($_.Exception.Message) (requires View-Only Organization Management or higher role; verify with Get-AdminAuditLogConfig -> AdminAuditLogEnabled)"
}

# --- [5/6] Duplicate/orphaned Calendar-type folders ---
# Outlook's MAPI client resolves the *default* calendar via a hidden pointer
# on the mailbox root, not by folder name/path - if a second folder of
# FolderType Calendar exists (e.g. left behind by a restore/migration),
# Outlook can be rendering a completely different folder than the one [3/6]
# just checked and (optionally) remediated, which would explain why fixing
# that folder's permission didn't change anything in Outlook.
Write-Host ""
Write-Host "[5/6] Checking for duplicate Calendar-type folders (Get-MailboxFolderStatistics -FolderScope Calendar)..."
try {
    $calendarFolders = Get-MailboxFolderStatistics -Identity $MailboxIdentity -FolderScope Calendar -ErrorAction Stop
    $calendarFolders | ForEach-Object {
        Write-Host "  FolderPath: $($_.FolderPath)  FolderType: $($_.FolderType)  ItemsInFolder: $($_.ItemsInFolder)  FolderId: $($_.FolderId)"
    }
    $topLevelCalendars = @($calendarFolders | Where-Object { $_.FolderType -eq 'Calendar' })
    if ($topLevelCalendars.Count -gt 1) {
        Write-Host "  WARNING: $($topLevelCalendars.Count) folders of FolderType 'Calendar' found. Compare their FolderPath above against '$folderIdentity' - if Outlook is actually opening a different, orphaned Calendar folder, [3/6]'s check (and -Remediate) was against the wrong folder. That other folder's own permissions would need to be checked/fixed separately, or the duplicate merged/removed."
    } else {
        Write-Host "  Only one Calendar-type folder found - not a duplicate-folder issue."
    }
} catch {
    Rmm-Alert -Category "Calendar Permission Debug" -Body "Could not check for duplicate calendar folders on '$MailboxIdentity': $($_.Exception.Message)"
}

# --- [6/6] Broader mailbox/folder corruption scan (New-MailboxRepairRequest -DetectOnly) ---
# FolderACL corruption was already checked separately (outside this script,
# via New-MailboxRepairRequest -CorruptionType FolderACL) and came back
# clean. Outlook crashing in EMSMDB32.DLL when opening this mailbox as a
# full additional account points at broader store/folder corruption, so this
# runs the other corruption types plausible for an open-time crash. Always
# -DetectOnly - never repairs automatically, since store-level repair is a
# judgment call, not something to fire blindly.
Write-Host ""
if ($CheckCorruption) {
    Write-Host "[6/6] Broader mailbox corruption scan (New-MailboxRepairRequest -DetectOnly)..."
    function Wait-MailboxRepairRequest {
        param([string]$Mailbox, [int]$TimeoutSeconds = 300)
        $elapsed = 0
        do {
            Start-Sleep -Seconds 5
            $elapsed += 5
            $req = Get-MailboxRepairRequest -Mailbox $Mailbox
        } while ($req.JobState -notin @('Succeeded', 'Failed') -and $elapsed -lt $TimeoutSeconds)
        return $req
    }
    $corruptionBatches = @(
        @{ Label = "ProvisionedFolder, SearchFolder, MissingSpecialFolders, ReplState, RestrictionFolder"; Types = @('ProvisionedFolder', 'SearchFolder', 'MissingSpecialFolders', 'ReplState', 'RestrictionFolder') },
        @{ Label = "FolderView"; Types = @('FolderView') },
        @{ Label = "AggregateCounts"; Types = @('AggregateCounts') }
    )
    $anyCorruptionFound = $false
    foreach ($batch in $corruptionBatches) {
        Write-Host "  Running detect-only scan: $($batch.Label)..."
        try {
            New-MailboxRepairRequest -Mailbox $MailboxIdentity -CorruptionType $batch.Types -DetectOnly -ErrorAction Stop | Out-Null
            $result = Wait-MailboxRepairRequest -Mailbox $MailboxIdentity
            if ($result.JobState -ne 'Succeeded') {
                Write-Host "    WARNING: job did not reach Succeeded within timeout (JobState: $($result.JobState)) - check manually with Get-MailboxRepairRequest -Mailbox $MailboxIdentity"
                continue
            }
            Write-Host "    CorruptionsDetected: $($result.CorruptionsDetected)  Tasks: $($result.Tasks -join ',')"
            if ($result.CorruptionsDetected -gt 0) {
                $anyCorruptionFound = $true
                Write-Host "    CORRUPTION FOUND ($($batch.Label)). To repair: New-MailboxRepairRequest -Mailbox $MailboxIdentity -CorruptionType $($batch.Types -join ',')  (omit -DetectOnly)"
            }
        } catch {
            Rmm-Alert -Category "Calendar Permission Debug" -Body "-CheckCorruption scan '$($batch.Label)' failed on '$MailboxIdentity': $($_.Exception.Message)"
        }
    }
    if (-not $anyCorruptionFound) {
        Write-Host "  No corruption detected across ProvisionedFolder/SearchFolder/MissingSpecialFolders/ReplState/RestrictionFolder/FolderView/AggregateCounts (FolderACL already checked separately, also clean)."
    }
} else {
    Write-Host "[6/6] Skipped (pass -CheckCorruption to run a broader New-MailboxRepairRequest -DetectOnly scan - takes several minutes)."
}

Write-Host ""
Write-Host "=== Done ==="
if ($Remediate) {
    Write-Host "Ran with -Remediate: see [3/6] above for the remove/re-add result. Retest in Outlook after a full restart. If the problem persists, check [5/6]/[6/6], then escalate to MFCMAPI on the folder's raw ACL Table (see header comment)."
} else {
    Write-Host "No changes made. Review [3/6]: a 'Delegate' SharingPermissionFlags entry points at an Outlook-side delegate record; a plain entry with client-cache already ruled out points at a server-side MAPI ACL desync - re-run with -Remediate to attempt the standard fix. If -Remediate doesn't help, check [5/6]/[6/6], then escalate to MFCMAPI."
}

exit 0
