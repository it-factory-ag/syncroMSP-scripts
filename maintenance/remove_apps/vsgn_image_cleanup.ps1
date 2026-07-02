# Upload this script to SyncroMSP. Change $AppList to match the filename
# under maintenance/remove_apps/customers/ (without .ps1 extension).
$AppList = 'vsgn_image_cleanup'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = 'https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/remove_apps'
Invoke-Expression (New-Object Net.WebClient).DownloadString("$base/applists/$AppList.ps1")
Invoke-Expression (New-Object Net.WebClient).DownloadString("$base/core.ps1")
