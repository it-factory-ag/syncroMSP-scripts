Import-Module $env:SyncroModule -DisableNameChecking

# https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html
$hpiaUrl    = 'https://hpia.hpcloud.hp.com/downloads/hpia/hp-hpia-5.3.6.exe'
$workDir    = 'C:\_admin\HPIA'
$installer  = "$workDir\hpia.exe"
$extractDir = "$workDir\inst"
$softpaqDir = "$workDir\SWSETUP"

# Clean up any previous run and recreate dirs
Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $workDir, $extractDir, $softpaqDir | Out-Null

Write-Host "Downloading HP Image Assistant..."
(New-Object System.Net.WebClient).DownloadFile($hpiaUrl, $installer)

Write-Host "Extracting..."
Start-Process -Wait -FilePath $installer -ArgumentList "/s /e /f `"$extractDir`""

$hpia = "$extractDir\HPImageAssistant.exe"
if (-not (Test-Path $hpia)) {
    Write-Host "ERROR: HPImageAssistant.exe not found after extraction"
    exit 1
}

Write-Host "Running HP Image Assistant (install all updates)..."
$proc = Start-Process -Wait -PassThru -FilePath $hpia -ArgumentList "/Operation:Analyze /Category:All /Selection:All /Action:Install /SoftpaqDownloadFolder:`"$softpaqDir`" /Silent /AutoCleanup"
Write-Host "HPIA exit code: $($proc.ExitCode)"

Write-Host "Cleaning up..."
Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
