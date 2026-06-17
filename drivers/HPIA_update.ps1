Import-Module $env:SyncroModule -DisableNameChecking

# https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html
$hpiaUrl    = 'https://hpia.hpcloud.hp.com/downloads/hpia/hp-hpia-5.3.6.exe'
$workDir    = 'C:\_admin\HPIA'
$installer  = "$workDir\hpia.exe"
$extractDir = "$workDir\inst"
$softpaqDir = "$workDir\SWSETUP"
$reportDir  = "$workDir\report"

# Clean up any previous run and recreate dirs
Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $workDir, $extractDir, $softpaqDir, $reportDir | Out-Null

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
$proc = Start-Process -Wait -PassThru -FilePath $hpia -ArgumentList "/Operation:Analyze /Category:All /Selection:All /Action:Install /SoftpaqDownloadFolder:`"$softpaqDir`" /ReportFolder:`"$reportDir`" /Silent /AutoCleanup"
Write-Host "HPIA exit code: $($proc.ExitCode)"

# HPIA exit codes: 0=nothing to do, 1=installed ok, 2=install failed, 3=not HP platform, 4=download failed, 4096=no applicable softpaqs found
$report = Get-ChildItem $reportDir -Filter "*.html" | Select-Object -First 1
if ($report) {
    Write-Host "Report: $($report.FullName)"
}
$xml = Get-ChildItem $reportDir -Filter "*.xml" | Select-Object -First 1
if ($xml) {
    [xml]$doc = Get-Content $xml.FullName
    $sys = $doc.HPIA.SystemInfo.System
    Write-Host "Model:        $($sys.ProductName)"
    Write-Host "BIOS:         $($sys.BIOSVersion) ($($sys.BIOSDate))"
    Write-Host "Health:       $($doc.HPIA.OverallHealth) / Security: $($doc.HPIA.OverallSecurity)"

    $doc.HPIA.Recommendations.ChildNodes | ForEach-Object {
        $category = $_.Name
        $_.Recommendation | ForEach-Object {
            Write-Host "  [$category] $($_.TargetComponent): $($_.TargetVersion) -> $($_.ReferenceVersion) ($($_.Comments))"
        }
    }
}

Write-Host "Cleaning up..."
Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
