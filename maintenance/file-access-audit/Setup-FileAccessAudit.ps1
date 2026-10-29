<#
One-time setup for file access statistics on a shared folder on a file server.
Run on the server as Administrator (not intended as a SyncroMSP endpoint script).

Sets the Advanced Audit Policy "Object Access -> Audit File System" = Success locally via
auditpol/registry (no GPO edit needed). Caveat: if a GPO already explicitly manages this
subcategory on this server's OU, the next Group Policy background refresh will silently
overwrite this local setting again - the script re-checks after setting it so that's
immediately visible, but the durable fix in that case is the GPO itself.

What this script does:
  1. Sets "File System" audit subcategory = Success (auditpol + SCENoApplyLegacyAuditPolicy
     registry value), then prints the resulting setting for verification
  2. Sets the SACL recursively on $TargetPath (Get-Acl/Set-Acl with a FileSystemAuditRule)
  3. Grows the Security event log (default 1 GB)
  4. Writes Collect-FileAccess.ps1 (filters out computer/service accounts like "SRV$" or
     SYSTEM, so AV/backup/indexer scans don't get counted as file accesses; also skips
     directory-level events so folder browsing / this setup script's own recursive SACL
     sweep isn't counted either) and Report-FileAccess.ps1 to $ScriptDir
  5. Registers the scheduled tasks for daily collection and the weekly report
  6. Optional (-SeafileUploadLink): the weekly report script additionally uploads each
     report CSV to a Seafile upload link (e.g. https://cloud-storage.itfactory.ch/u/d/<token>/).
     Upload results/errors are logged to FileAccess_Upload.log in $ReportDir.
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
    [string]$ReportTime = "06:00",

    # Seafile upload link (".../u/d/<token>/"). Empty = no upload, reports stay local only.
    # Pass it in at runtime (e.g. Syncro script variable) - never commit the token, this repo is public.
    [string]$SeafileUploadLink = ""
)
# Script version = git blob hash of this file (same as `git hash-object <file>`), no git needed.
# Matches the repo only when the file runs unmodified, i.e. as downloaded by the wrapper.
# Look it up in the repo with: git log --oneline --find-object=<hash>
$scriptVersion = & {
    try {
        $bytes  = [IO.File]::ReadAllBytes($PSCommandPath)
        $prefix = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
        $sha1   = [Security.Cryptography.SHA1]::Create()
        $sha1.TransformBlock($prefix, 0, $prefix.Length, $null, 0) | Out-Null
        $sha1.TransformFinalBlock($bytes, 0, $bytes.Length) | Out-Null
        (($sha1.Hash | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 7)
    } catch { "unknown" }
}
Write-Host "Version: $scriptVersion"


$ErrorActionPreference = "Stop"

if ($SeafileUploadLink -and $SeafileUploadLink -notmatch '^https://[^/]+/u/d/[0-9a-f]+/?$') {
    throw "SeafileUploadLink '$SeafileUploadLink' is not a Seafile upload link (expected https://<server>/u/d/<token>/)."
}

if (-not (Test-Path $TargetPath)) {
    throw "TargetPath '$TargetPath' does not exist. Provide the real local path on the server (not the client drive letter)."
}

# 1. Enable the audit policy locally (no GPO edit needed)
# Subcategory referenced by GUID, not name - "File System" is only the English display
# name and auditpol rejects it with ERROR_INVALID_PARAMETER on non-English Windows.
$fileSystemSubcategoryGuid = "{0CCE921D-69AE-11D9-BED3-505054503030}"

# "Audit: Force audit policy subcategory settings (Windows Vista or later) to override audit
# policy category settings" - without this, legacy category-level audit policy can override
# the advanced subcategory setting below and it silently stays "No Auditing".
New-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Lsa" -Name "SCENoApplyLegacyAuditPolicy" -PropertyType DWord -Value 1 -Force | Out-Null

auditpol /set /subcategory:"$fileSystemSubcategoryGuid" /success:enable | Out-Null

Write-Host "Audit setting for the File System subcategory after applying it locally (re-verify 'Success' is shown - a GPO on this server's OU could override this back to 'No Auditing' on the next policy refresh):"
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
# InheritanceFlags other than "None" are only valid on directories - applying a rule with
# ContainerInherit/ObjectInherit to a plain file throws "Es können keine Flags gesetzt
# werden" (inheritanceFlags). Directories and files each need their own rule object.
$dirAuditRule = New-Object System.Security.AccessControl.FileSystemAuditRule(
    $everyoneSid, "ReadAndExecute", "ContainerInherit, ObjectInherit", "None", "Success"
)
$fileAuditRule = New-Object System.Security.AccessControl.FileSystemAuditRule(
    $everyoneSid, "ReadAndExecute", "None", "None", "Success"
)

$rootAcl = Get-Acl -Path $TargetPath
$rootAcl.SetAuditRule($dirAuditRule)
Set-Acl -Path $TargetPath -AclObject $rootAcl

$children = Get-ChildItem -Path $TargetPath -Recurse -Force
Write-Host "Applying audit rule to $($children.Count) existing files/folders ..."
$i = 0
foreach ($child in $children) {
    $rule = if ($child.PSIsContainer) { $dirAuditRule } else { $fileAuditRule }
    $acl = Get-Acl -Path $child.FullName
    $acl.SetAuditRule($rule)
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

`$rawRows = foreach (`$e in `$events) {
    `$xml  = [xml]`$e.ToXml()
    `$data = @{}
    `$xml.Event.EventData.Data | ForEach-Object { `$data[`$_.Name] = `$_.'#text' }
    `$obj  = `$data['ObjectName']
    `$user = `$data['SubjectUserName']

    # Exclude computer/service accounts (AV scans, backup jobs, Search Indexer, etc. run
    # under SYSTEM and are audited as the local machine's own computer account, e.g. "SRV$")
    # - only count events triggered by an actual person, without storing who in the CSV.
    `$isSystemAccount = `$user -like '*$' -or `$user -in @('SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE')

    # Directory-level 4663 events (folder opened/browsed, or the recursive Get-Acl/Set-Acl
    # sweep this setup script itself performs) aren't a file access - only count leaf files.
    `$isFile = Test-Path -LiteralPath `$obj -PathType Leaf

    if (`$obj -like "`$targetPath\*" -and `$obj -notlike '*~`$*' -and `$obj -notlike '*.tmp' -and -not `$isSystemAccount -and `$isFile) {
        [PSCustomObject]@{ File = `$obj; Timestamp = `$e.TimeCreated }
    }
}

# A single file open typically fires 10-20+ raw 4663 events within the same second or two
# (Explorer icon/thumbnail probes, the app's own open sequence, antivirus real-time scan) -
# collapse same-file events within the same minute down to one row so AccessCount reflects
# actual accesses, not raw event volume.
`$deduped = `$rawRows | Group-Object File, { `$_.Timestamp.ToString('yyyy-MM-dd HH:mm') } | ForEach-Object {
    `$_.Group | Sort-Object Timestamp | Select-Object -First 1
}

# Format Timestamp as an explicit, unambiguous string before writing - Export-Csv otherwise
# serializes DateTime using the current session's culture (e.g. German dd.MM.yyyy), which
# then fails to parse back with a bare [datetime] cast if a later read happens under a
# different culture (e.g. the scheduled task running as SYSTEM vs. an interactive session).
`$rows = `$deduped | Select-Object File, @{ Name = 'Timestamp'; Expression = { `$_.Timestamp.ToString('yyyy-MM-dd HH:mm:ss') } }

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
# Parse with the exact invariant format Collect-FileAccess.ps1 writes - a bare [datetime]
# cast depends on the current session's culture and fails to parse the stored string if
# that differs from whatever culture wrote it (e.g. SYSTEM vs. an interactive session).
`$tsFormat = 'yyyy-MM-dd HH:mm:ss'

`$data = Import-Csv `$masterCsv -Delimiter ';' | Where-Object { [datetime]::ParseExact(`$_.Timestamp, `$tsFormat, `$null) -ge (Get-Date).AddDays(-7) }

`$data | Group-Object File | ForEach-Object {
    [PSCustomObject]@{
        File         = `$_.Name
        AccessCount  = `$_.Count
        LastAccessed = (`$_.Group | Sort-Object { [datetime]::ParseExact(`$_.Timestamp, `$tsFormat, `$null) } -Descending | Select-Object -First 1).Timestamp
    }
} | Sort-Object AccessCount -Descending |
  Export-Csv -Path `$reportOut -NoTypeInformation -Encoding UTF8 -Delimiter ';'
"@

if ($SeafileUploadLink) {
    # Single-quoted here-string: no backtick escaping needed, values are injected via the header.
    $reportScriptContent += @"

`$uploadLink = '$SeafileUploadLink'
`$logFile    = Join-Path '$ReportDir' 'FileAccess_Upload.log'
"@
    $reportScriptContent += @'

# Upload the report to the Seafile upload link. Prefixed with the computer name so reports
# from several servers can share one upload link.
$uploadName = "$($env:COMPUTERNAME)_$(Split-Path $reportOut -Leaf)"
# No accesses in the last 7 days: depending on the PowerShell version Export-Csv writes
# either no file or an empty one for an empty pipeline - nothing worth uploading either way.
if (-not (Test-Path $reportOut) -or (Get-Item $reportOut).Length -eq 0) {
    "$(Get-Date -Format 's') SKIP  $uploadName : no accesses in the last 7 days, no report written" | Add-Content -Path $logFile
    exit 0
}
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $null = $uploadLink -match '^(https://[^/]+)/u/d/([0-9a-f]+)/?$'
    $server = $Matches[1]
    $token  = $Matches[2]

    # The fileserver only accepts parent_dir if it exactly equals the upload link's shared
    # folder path (isParentMatched), and the anonymous API doesn't return that path - the
    # upload page itself embeds it in its pageOptions as `path: "..."` (Django escapejs).
    $webClient = New-Object Net.WebClient
    $webClient.Encoding = [Text.Encoding]::UTF8
    $page = $webClient.DownloadString("$server/u/d/$token/")
    if ($page -cnotmatch '\spath: "([^"]*)"') {
        throw "Could not read the target folder from the upload link page (link expired, deleted or password-protected?)."
    }
    $parentDir = [regex]::Unescape($Matches[1])

    $fileServerUrl = (Invoke-RestMethod -Uri "$server/api/v2.1/upload-links/$token/upload/" -UseBasicParsing).upload_link + '?ret-json=1'

    # Multipart body built by hand: Invoke-RestMethod -Form is PowerShell 6+ only, and .NET
    # Framework's MultipartFormDataContent writes unquoted names (name=file) plus a filename*
    # parameter, which Seafile's fileserver mime parser rejects with "400 Bad request.".
    $boundary = [Guid]::NewGuid().ToString('N')
    $utf8     = New-Object Text.UTF8Encoding($false)
    $head = "--$boundary`r`n" +
            "Content-Disposition: form-data; name=`"parent_dir`"`r`n`r`n" +
            "$parentDir`r`n" +
            "--$boundary`r`n" +
            "Content-Disposition: form-data; name=`"file`"; filename=`"$uploadName`"`r`n" +
            "Content-Type: application/octet-stream`r`n`r`n"
    $tail = "`r`n--$boundary--`r`n"
    $stream = New-Object IO.MemoryStream
    foreach ($chunk in @($utf8.GetBytes($head), [IO.File]::ReadAllBytes($reportOut), $utf8.GetBytes($tail))) {
        $stream.Write($chunk, 0, $chunk.Length)
    }

    Add-Type -AssemblyName System.Net.Http
    $client  = New-Object System.Net.Http.HttpClient
    $content = New-Object System.Net.Http.ByteArrayContent(, $stream.ToArray())
    $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("multipart/form-data; boundary=$boundary")
    $response = $client.PostAsync($fileServerUrl, $content).Result
    $body     = $response.Content.ReadAsStringAsync().Result
    if (-not $response.IsSuccessStatusCode) {
        throw "HTTP $([int]$response.StatusCode): $body"
    }
    "$(Get-Date -Format 's') OK    $uploadName -> $parentDir" | Add-Content -Path $logFile
}
catch {
    "$(Get-Date -Format 's') ERROR $uploadName : $($_.Exception.Message)" | Add-Content -Path $logFile
    exit 1
}
'@
}
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
if ($SeafileUploadLink) {
    Write-Host "Weekly reports will also be uploaded to Seafile (log: $(Join-Path $ReportDir 'FileAccess_Upload.log'))." -ForegroundColor Green
}
Write-Host "Setup complete. Raw data: $masterCsv | Weekly reports: $ReportDir" -ForegroundColor Green
