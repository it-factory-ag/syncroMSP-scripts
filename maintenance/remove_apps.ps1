Import-Module $env:SyncroModule -DisableNameChecking

# AppX / Windows Store packages to remove.
# Use the package family name (without version suffix).
# Add image-specific AppX packages in the marked section below.
$AppxPackages = @(
    'Microsoft.GamingApp'
    'Microsoft.XboxApp'
    'Microsoft.XboxGameOverlay'
    'Microsoft.XboxGamingOverlay'
    'Microsoft.XboxIdentityProvider'
    'Microsoft.XboxSpeechToTextOverlay'
    'Microsoft.Xbox.TCUI'
)

# Win32 / MSI apps to remove, matched by display name.
# Use the exact name shown in Windows Settings > Apps > Installed apps.
$Win32Apps = @(
    # --- Clear removals ---
    'Brave' # keep?
    'Mozilla Thunderbird (x64 en-US)' # remove
    'Mozilla Thunderbird (x86 en-US)' # remove
    'Dropbox'
    'Dropbox Update Helper'
    'pCloud Drive'
    'GIMP 2.10.38'
    'GIMP 3.2.2'
    'Brother CanvasWorkspace'
    'CodeTwo QR Code Desktop Reader & Generator'
    'Advanced IP Scanner 2.5.1'
    'TightReceiverPro 1.2.1'
    'WebWeaver® Desktop 6'
    'TeamViewer'                  # remote support tool — keep if IT uses it
    'UltraVNC'                    # remote access — keep if needed alongside TeamViewer
    'KeePass Password Safe 2.57'  # password manager — not in keep list
    # '7-Zip 26.00 (x64)'           # archive tool — not in keep list
    'Logitech Presentation'        # only needed with Logitech presenter hardware
)

$removed = 0
$failed  = 0
$skipped = 0

# --- AppX removal ---
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
