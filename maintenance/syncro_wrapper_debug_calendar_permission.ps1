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
#>

$MailboxIdentity  = "siziklein"
$DelegateIdentity = "christa.stocker"
$FolderName       = "Calendar"
$AuditLogDays     = 90

Import-Module $env:SyncroModule

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url       = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/Debug-CalendarPermission.ps1?nocache=$([Guid]::NewGuid())"
$localCopy = Join-Path $env:TEMP "Debug-CalendarPermission.ps1"

try {
    $webClient = New-Object Net.WebClient
    $webClient.Headers.Add("Cache-Control", "no-cache, no-store")
    $webClient.Headers.Add("Pragma", "no-cache")
    $webClient.DownloadFile($url, $localCopy)
    & $localCopy -MailboxIdentity $MailboxIdentity -DelegateIdentity $DelegateIdentity -FolderName $FolderName -AuditLogDays $AuditLogDays
    exit $LASTEXITCODE
}
catch {
    Write-Host "ERROR: Wrapper failed to download/run Debug-CalendarPermission.ps1: $($_.Exception.Message)"
    exit 1
}
