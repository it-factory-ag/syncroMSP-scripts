Import-Module $env:SyncroModule -DisableNameChecking

# Get the latest BCU softpaq URL from: https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HP_BCU.html
$bcuUrl = 'https://ftp.hp.com/pub/softpaq/sp143501-144000/sp143621.exe'

# Set BIOS admin password here if one is configured, otherwise leave empty
$biosPassword = ""

$manufacturer = (Get-WmiObject Win32_ComputerSystem).Manufacturer
if ($manufacturer -notmatch "HP|Hewlett") {
    Write-Host "Not an HP machine - Sure Start not applicable"
    exit 0
}

$workDir    = 'C:\_admin\BCU'
$installer  = "$workDir\bcu.exe"
$extractDir = "$workDir\inst"

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

# Sure Start setting name varies by HP model/BIOS version
# e.g. "Sure Start Secure Boot Keys Protection" or "SureStart Production Mode"
$settingName = "SureStart Production Mode"

Write-Host "Current value:"
& $bcu.FullName /getvalue:"$settingName" 2>&1 | Write-Host

Write-Host "Attempting to disable $settingName..."
$args = if ($biosPassword) {
    "/setvalue:`"$settingName`",`"Disable`" /password:`"$biosPassword`""
} else {
    "/setvalue:`"$settingName`",`"Disable`""
}
$result = & $bcu.FullName $args.Split(' ') 2>&1
$result | Write-Host

switch ($LASTEXITCODE) {
    0 { Write-Host "OK: '$settingName' disabled - reboot required for change to take effect" }
    1 {
        Write-Host "ERROR: BIOS admin password required (BCU code 1)"
        Write-Host "       Set the `$biosPassword variable in the script to the BIOS admin password"
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
    6 {
        Write-Host "ERROR: Setting is read-only / protected by Sure Start (BCU code 6)"
        Write-Host "       Must be changed manually in BIOS setup (F10 at boot)"
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
    default {
        Write-Host "ERROR: BCU returned code $LASTEXITCODE"
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
}

Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
