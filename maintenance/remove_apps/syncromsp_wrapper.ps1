# Upload this script to SyncroMSP. Change $Customer to match the filename
# under maintenance/remove_apps/customers/ (without .ps1 extension).
$Customer = 'vsgn'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = 'https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/remove_apps'
Invoke-Expression (New-Object Net.WebClient).DownloadString("$base/customers/$Customer.ps1")
Invoke-Expression (New-Object Net.WebClient).DownloadString("$base/core.ps1")
