Import-Module $env:SyncroModule -DisableNameChecking
$customAssetField = "Last succesful WUConnection"  # This field will need to be created in Admin --> Custom Asset Fields


$lastSearch = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results.LastSearchSuccessDate

if ($null -eq $lastSearch) {
    Write-Host "ALERT: Windows Update has never successfully searched for updates"
    exit 1
}



$daysSince = ((Get-Date) - $lastSearch).Days

$lastSearchFormatted = $lastSearch.ToString("yyyy-MM-dd HH:mm:ss")

if ($daysSince -gt 20) {
    Write-Host "ALERT: Last successful Windows Update check was $daysSince days ago ($lastSearchFormatted)"
    exit 1
}
Set-Asset-Field -Name $customAssetField -Value $lastSearchFormatted
Write-Host "OK: Last successful Windows Update check was $daysSince days ago"
exit 0
