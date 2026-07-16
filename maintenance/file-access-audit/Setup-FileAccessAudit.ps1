<#
One-time setup for file access statistics on a shared folder on a file server.
Run on the server as Administrator (not intended as a SyncroMSP endpoint script).

Prerequisite: the Advanced Audit Policy "Object Access -> Audit File System" (Success)
and "Audit: Force audit policy subcategory settings..." (Enabled) must be applied via GPO
to the server's OU (Domain Controller). This script only checks that, it does not set it.

What this script does:
  1. Prints the current "File System" audit subcategory setting for manual verification (auditpol)
  2. Sets the SACL recursively on $TargetPath (Get-Acl/Set-Acl with a FileSystemAuditRule)
  3. Grows the Security event log (default 1 GB)
  4. Writes Collect-FileAccess.ps1 and Report-FileAccess.ps1 to $ScriptDir
  5. Registers the scheduled tasks for daily collection and the weekly report
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetPath,

    [string]$ScriptDir = "C:\_admin\FileAccessAudit\Scripts",
    [string]$ReportDir = "C:\_admin\FileAccessAudit\Reports",
    [int]$SecurityLogSizeMB = 1024,
    [string]$CollectTime = "23:55",
    [string]$ReportDay = "Monday",
    [string]$ReportTime = "06:00"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $TargetPath)) {
    throw "TargetPath '$TargetPath' does not exist. Provide the real local path on the server (not the client drive letter)."
}

# 1. Check audit policy
# Subcategory referenced by GUID, not name - "File System" is only the English display
# name and auditpol rejects it with ERROR_INVALID_PARAMETER on non-English Windows.
$fileSystemSubcategoryGuid = "{0CCE921D-69AE-11D9-BED3-505054503030}"
Write-Host "Current audit setting for the File System subcategory (verify 'Success' is enabled):"
auditpol /get /subcategory:"$fileSystemSubcategoryGuid"

# 2. Set the SACL recursively
# icacls /setaudit has no documented flag syntax on current Microsoft docs and rejected
# every combination tried as "invalid parameter" - using the documented FileSystemAuditRule
# API instead (matches Microsoft/AWS reference examples for setting file audit SACLs).
Write-Host "Setting SACL recursively on '$TargetPath' ..."
# "Everyone" is the English well-known account name - .NET's SID lookup for that literal
# string fails on non-English Windows ("identity references could not be translated").
# Use the locale-independent well-known SID (S-1-1-0) instead.
$everyoneSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-1-0")
$auditRule = New-Object System.Security.AccessControl.FileSystemAuditRule(
    $everyoneSid, "ReadAndExecute", "ContainerInherit, ObjectInherit", "None", "Success"
)

$rootAcl = Get-Acl -Path $TargetPath
$rootAcl.SetAuditRule($auditRule)
Set-Acl -Path $TargetPath -AclObject $rootAcl

$children = Get-ChildItem -Path $TargetPath -Recurse -Force
Write-Host "Applying audit rule to $($children.Count) existing files/folders ..."
$i = 0
foreach ($child in $children) {
    $acl = Get-Acl -Path $child.FullName
    $acl.SetAuditRule($auditRule)
    Set-Acl -Path $child.FullName -AclObject $acl
    $i++
    if ($i % 200 -eq 0) {
        Write-Host "  ... $i / $($children.Count) done"
    }
}
Write-Host "SACL applied to all $i existing files/folders."

# 3. Grow the Security log
Write-Host "Setting Security log size to $SecurityLogSizeMB MB ..."
wevtutil sl Security "/ms:$($SecurityLogSizeMB * 1MB)"

# 4. Write the scripts
New-Item -ItemType Directory -Path $ScriptDir -Force | Out-Null
New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null

$masterCsv = Join-Path $ReportDir "FileAccess_RawData.csv"
$stateFile = Join-Path $ReportDir "FileAccess_LastRun.txt"

$collectScriptPath = Join-Path $ScriptDir "Collect-FileAccess.ps1"
$collectScriptContent = @"
`$targetPath = '$TargetPath'
`$masterCsv  = '$masterCsv'
`$stateFile  = '$stateFile'

`$since = if (Test-Path `$stateFile) { Get-Content `$stateFile | Get-Date } else { (Get-Date).AddDays(-1) }
`$now   = Get-Date

`$events = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4663; StartTime = `$since } -ErrorAction SilentlyContinue

`$rows = foreach (`$e in `$events) {
    `$xml  = [xml]`$e.ToXml()
    `$data = @{}
    `$xml.Event.EventData.Data | ForEach-Object { `$data[`$_.Name] = `$_.'#text' }
    `$obj = `$data['ObjectName']

    if (`$obj -like "`$targetPath\*" -and `$obj -notlike '*~`$*' -and `$obj -notlike '*.tmp') {
        [PSCustomObject]@{ File = `$obj; Timestamp = `$e.TimeCreated }
    }
}

if (`$rows) {
    `$rows | Export-Csv -Path `$masterCsv -NoTypeInformation -Encoding UTF8 -Delimiter ';' -Append
}

`$now | Out-File `$stateFile
"@
Set-Content -Path $collectScriptPath -Value $collectScriptContent -Encoding UTF8

$reportScriptPath = Join-Path $ScriptDir "Report-FileAccess.ps1"
$reportScriptContent = @"
`$masterCsv = '$masterCsv'
`$reportOut = Join-Path '$ReportDir' "WeeklyReport_`$(Get-Date -Format 'yyyy-MM-dd').csv"

`$data = Import-Csv `$masterCsv -Delimiter ';' | Where-Object { [datetime]`$_.Timestamp -ge (Get-Date).AddDays(-7) }

`$data | Group-Object File | ForEach-Object {
    [PSCustomObject]@{
        File         = `$_.Name
        AccessCount  = `$_.Count
        LastAccessed = (`$_.Group | Sort-Object { [datetime]`$_.Timestamp } -Descending | Select-Object -First 1).Timestamp
    }
} | Sort-Object AccessCount -Descending |
  Export-Csv -Path `$reportOut -NoTypeInformation -Encoding UTF8 -Delimiter ';'
"@
Set-Content -Path $reportScriptPath -Value $reportScriptContent -Encoding UTF8

Write-Host "Scripts created: $collectScriptPath, $reportScriptPath" -ForegroundColor Green

# 5. Register scheduled tasks
$collectAction  = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$collectScriptPath`""
$collectTrigger = New-ScheduledTaskTrigger -Daily -At $CollectTime
Register-ScheduledTask -TaskName "FileAccessAudit - Daily Collection" -Action $collectAction -Trigger $collectTrigger -User "SYSTEM" -RunLevel Highest -Force | Out-Null

$reportAction  = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$reportScriptPath`""
$reportTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $ReportDay -At $ReportTime
Register-ScheduledTask -TaskName "FileAccessAudit - Weekly Report" -Action $reportAction -Trigger $reportTrigger -User "SYSTEM" -RunLevel Highest -Force | Out-Null

Write-Host "Scheduled tasks registered: 'FileAccessAudit - Daily Collection' (daily at $CollectTime), 'FileAccessAudit - Weekly Report' ($ReportDay at $ReportTime)." -ForegroundColor Green
Write-Host "Setup complete. Raw data: $masterCsv | Weekly reports: $ReportDir" -ForegroundColor Green
