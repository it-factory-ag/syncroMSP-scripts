Import-Module $env:SyncroModule -DisableNameChecking

# Get the latest BCU softpaq URL from: https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HP_BCU.html
$bcuUrl  = 'https://ftp.hp.com/pub/softpaq/sp148501-149000/sp148977.exe'
$workDir = 'C:\_admin\BCU'
$installer = "$workDir\bcu.exe"
$extractDir = "$workDir\inst"

$manufacturer = (Get-WmiObject Win32_ComputerSystem).Manufacturer
if ($manufacturer -notmatch "HP|Hewlett") {
    Write-Host "Not an HP machine - not applicable"
    exit 0
}

Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $workDir, $extractDir | Out-Null

Write-Host "Downloading HP BCU..."
(New-Object System.Net.WebClient).DownloadFile($bcuUrl, $installer)

Write-Host "Extracting..."
Start-Process -Wait -FilePath $installer -ArgumentList "/s /e /f `"$extractDir`""

$bcu = Get-ChildItem $extractDir -Filter "BiosConfigUtility64.exe" -Recurse | Select-Object -First 1
if (-not $bcu) {
    Write-Host "ERROR: BiosConfigUtility64.exe not found after extraction"
    exit 1
}

Write-Host "BCU found at: $($bcu.FullName)"

# First: dump all Sure Start related settings so we can see what BCU reports
Write-Host ""
Write-Host "=== Current Sure Start settings (via BCU) ==="
& $bcu.FullName /getvalue:"SureStart Production Mode" 2>&1 | Write-Host

# Try to disable Sure Start without a password
Write-Host ""
Write-Host "=== Attempting to disable SureStart Production Mode ==="
$result = & $bcu.FullName /setvalue:"SureStart Production Mode","Disable" 2>&1
$result | Write-Host
Write-Host "BCU exit code: $LASTEXITCODE"

Write-Host "Cleaning up..."
Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
