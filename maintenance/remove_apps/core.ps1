Import-Module $env:SyncroModule -DisableNameChecking

if (-not $AppxPackages)     { $AppxPackages     = @() }
if (-not $Win32Apps)        { $Win32Apps        = @() }
if (-not $PreKillProcesses) { $PreKillProcesses = @() }

if ($PreKillProcesses.Count -gt 0) {
    Write-Host "=== Pre-kill Processes ==="
    foreach ($proc in $PreKillProcesses) {
        Stop-Process -Name $proc -Force -ErrorAction SilentlyContinue
        Write-Host "Killed: $proc"
    }
}

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
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($AppName in $Win32Apps) {
        $entries = Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
                   Where-Object { $_.DisplayName -eq $AppName }
        # Prefer MSI-based uninstaller when multiple entries exist — it supports silent flags reliably
        $entry = $entries | Where-Object { $_.UninstallString -match 'msiexec' } | Select-Object -First 1
        if (-not $entry) { $entry = $entries | Select-Object -First 1 }
        if ($entry) {
            try {
                $uninstallCmd = $entry.UninstallString
                if ($uninstallCmd -match 'msiexec') {
                    $uninstallCmd = $uninstallCmd -replace '/I', '/X'
                    if ($uninstallCmd -notmatch '/quiet') { $uninstallCmd += ' /quiet /norestart' }
                } elseif ($uninstallCmd -match '\.exe') {
                    # NSIS installers use /S, Inno Setup uses /VERYSILENT — try both
                    if ($uninstallCmd -notmatch '/S|/silent|/quiet|/VERYSILENT') {
                        $uninstallCmd += ' /S /VERYSILENT /NORESTART'
                    }
                }
                $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $uninstallCmd" -PassThru -ErrorAction Stop
                if ($proc.WaitForExit(120000)) {
                    Write-Host "Removed Win32: $AppName"
                    $removed++
                } else {
                    $proc.Kill()
                    Write-Host "TIMEOUT removing Win32: $AppName (killed after 120s)"
                    $failed++
                }
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
