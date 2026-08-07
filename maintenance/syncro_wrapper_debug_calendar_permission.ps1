<#
>>> THIS IS THE SCRIPT TO COPY INTO THE SYNCROMSP WEB INTERFACE <<<
Paste this whole file into Syncro under Scripting -> Scripts, scoped to the
Exchange server asset. No Required File attachment needed.

Read-only diagnostic for calendar-permission mismatches (server ACL shows
Owner, Outlook still blocks item creation) on a shared/room mailbox.
One-off for Zohodesk ticket 56952000034481001 ("SiZi Klein" calendar) - values
below are hardcoded rather than exposed as Syncro parameters since this isn't
meant to be reused for other mailboxes; edit them directly here if it is.

This is a thin wrapper: it pulls the current Debug-CalendarPermission.ps1
from this repo and runs it, so future fixes in the repo take effect without
editing this wrapper again. Debug-CalendarPermission.ps1 is the source of
truth for the logic.

IMPORTANT: run this with Syncro's "Run As" set to the logged-in user, NOT
System. As SYSTEM, the Exchange cmdlet bootstrap inside the real script
opens a WinRM session to the server's own hostname, which Windows blocks by
default as an NTLM loopback attempt (hangs 10 min, then fails) - and even if
it connected, SYSTEM's computer account normally holds no Exchange RBAC
role. The logged-in account must itself be a member of an Exchange RBAC
role group (e.g. Organization Management) for the script to work.

$Remediate below is off by default (diagnostic-only run). Flip to $true and
re-paste into Syncro once [3/4]'s diagnosis points at a plain (non-Delegate)
folder ACE and client-side caching has already been ruled out - it removes
and re-adds that exact permission to force Exchange to rewrite it cleanly.
#>

$MailboxIdentity  = "siziklein"
$DelegateIdentity = "christa.stocker"
$FolderName       = "Calendar"
$AuditLogDays     = 90
$Remediate        = $false

Import-Module $env:SyncroModule

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url       = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/Debug-CalendarPermission.ps1?nocache=$([Guid]::NewGuid())"
$localCopy = Join-Path $env:TEMP "Debug-CalendarPermission.ps1"

try {
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Add("Cache-Control", "no-cache, no-store")
    $webClient.Headers.Add("Pragma", "no-cache")
    $webClient.DownloadFile($url, $localCopy)
    $remediateArg = @{}
    if ($Remediate) { $remediateArg["Remediate"] = $true }
    & $localCopy -MailboxIdentity $MailboxIdentity -DelegateIdentity $DelegateIdentity -FolderName $FolderName -AuditLogDays $AuditLogDays @remediateArg
    exit $LASTEXITCODE
}
catch {
    Write-Host "ERROR: Wrapper failed to download/run Debug-CalendarPermission.ps1: $($_.Exception.Message)"
    exit 1
}
