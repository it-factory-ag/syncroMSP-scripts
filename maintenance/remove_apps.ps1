Import-Module $env:SyncroModule -DisableNameChecking

# SyncroMSP script variable: CustomerConfigUrl
# Set to the GitHub raw URL of the customer config file, e.g.:
# https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/customers/vsgn.ps1
if (-not $CustomerConfigUrl) {
    Write-Host "ERROR: CustomerConfigUrl script variable is not set."
    exit 1
}

Write-Host "Loading config: $CustomerConfigUrl"
try {
    $config = (New-Object System.Net.WebClient).DownloadString($CustomerConfigUrl)
    Invoke-Expression $config
} catch {
    Write-Host "ERROR: Failed to load customer config: $($_.Exception.Message)"
    exit 1
}

if (-not $AppxPackages) { $AppxPackages = @() }
if (-not $Win32Apps)    { $Win32Apps    = @() }

$removed = 0
$failed  = 0
$skipped = 0

# --- AppX removal ---
if ($AppxPackages.Count -gt 0) {
    Write-Host "=== AppX Package Removal ==="
    foreach ($App in $AppxPackages) {
        $pkg = Get-AppxPackage -AllUsers -Name $App -ErrorAction SilentlyContinue
        if ($pkg) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                Write-Host "Removed AppX: $App"
                $removed++
            } catch {
                Write-Host "FAILED AppX $App`: $($_.Exception.Message)"
                $failed++
            }
        } else {
            Write-Host "Not installed (AppX): $App"
            $skipped++
        }

        $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq $App }
        if ($prov) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop
                Write-Host "Removed provisioned: $App"
            } catch {
                Write-Host "FAILED provisioned $App`: $($_.Exception.Message)"
            }
        }
    }
}

# --- Win32 / MSI removal ---
if ($Win32Apps.Count -gt 0) {
    Write-Host "=== Win32 / MSI App Removal ==="
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($AppName in $Win32Apps) {
        $entry = Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -eq $AppName }
        if ($entry) {
            try {
                $uninstallCmd = $entry.UninstallString
                if ($uninstallCmd -match 'msiexec') {
                    $uninstallCmd = $uninstallCmd -replace '/I', '/X'
                    if ($uninstallCmd -notmatch '/quiet') { $uninstallCmd += ' /quiet /norestart' }
                }
                Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $uninstallCmd" -Wait -ErrorAction Stop
                Write-Host "Removed Win32: $AppName"
                $removed++
            } catch {
                Write-Host "FAILED Win32 $AppName`: $($_.Exception.Message)"
                $failed++
            }
        } else {
            Write-Host "Not installed (Win32): $AppName"
            $skipped++
        }
    }
}

# --- Summary ---
Write-Host "=== Summary ==="
Write-Host "Removed: $removed | Skipped (not found): $skipped | Failed: $failed"

if ($failed -gt 0) {
    Rmm-Alert -Category "App Removal" -Body "$failed app(s) failed to remove. Check script output."
    exit 1
}

exit 0
