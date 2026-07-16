<#
Thin wrapper: pulls the latest Setup-FileAccessAudit.ps1 from GitHub and runs it locally.
Run this on the file server as Administrator instead of copying the full script by hand.

Usage:
  .\Run-Setup-FromGitHub.ps1 -TargetPath "D:\Freigaben\07 IT\AVOR-Exelprogramme"
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

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url        = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/file-access-audit/Setup-FileAccessAudit.ps1"
$localCopy  = Join-Path $env:TEMP "Setup-FileAccessAudit.ps1"

(New-Object Net.WebClient).DownloadFile($url, $localCopy)

& $localCopy `
    -TargetPath $TargetPath `
    -ScriptDir $ScriptDir `
    -ReportDir $ReportDir `
    -SecurityLogSizeMB $SecurityLogSizeMB `
    -CollectTime $CollectTime `
    -ReportDay $ReportDay `
    -ReportTime $ReportTime
