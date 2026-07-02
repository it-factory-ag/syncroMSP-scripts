Import-Module $env:SyncroModule -DisableNameChecking

if (-not $AppxPackages)     { $AppxPackages     = @() }
if (-not $Win32Apps)        { $Win32Apps        = @() }
if (-not $PreKillProcesses) { $PreKillProcesses = @() }
if (-not $ForceDeletePaths) { $ForceDeletePaths = @() }

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
        $entries = @(Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
                     Where-Object { $_.DisplayName -like $AppName })
        if ($entries.Count -eq 0) {
            Write-Host "Not installed (Win32): $AppName"
            $skipped++
            continue
        }

        $appRemoved = $false
        foreach ($entry in $entries) {
            # Use QuietUninstallString if available — it's specifically meant for silent uninstall
            $uninstallCmd = if ($entry.QuietUninstallString) { $entry.QuietUninstallString } else { $entry.UninstallString }
            if ($uninstallCmd -match 'msiexec') {
                $uninstallCmd = $uninstallCmd -replace '/I', '/X'
                if ($uninstallCmd -notmatch '/quiet') { $uninstallCmd += ' /quiet /norestart' }
            } elseif ($uninstallCmd -match '\.exe' -and $uninstallCmd -notmatch '/S|/silent|/quiet|/VERYSILENT') {
                # /quiet   = WiX Burn bootstrappers
                # /S       = NSIS
                # /VERYSILENT /NORESTART = Inno Setup
                $uninstallCmd += ' /quiet /S /VERYSILENT /NORESTART'
            }

            try {
                $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $uninstallCmd" -PassThru -ErrorAction Stop
                if ($proc.WaitForExit(120000)) {
                    Write-Host "Removed Win32: $AppName ($uninstallCmd)"
                    $appRemoved = $true
                } else {
                    $proc.Kill()
                    Write-Host "TIMEOUT removing Win32: $AppName (killed after 120s)"
                    $failed++
                }
            } catch {
                Write-Host "FAILED Win32 $AppName`: $($_.Exception.Message)"
                $failed++
            }
        }
        if ($appRemoved) { $removed++ }
    }
}

# --- Force delete paths ---
if ($ForceDeletePaths.Count -gt 0) {
    Write-Host "=== Force Delete Paths ==="
    foreach ($path in $ForceDeletePaths) {
        if (Test-Path $path) {
            # Kill any process whose executable lives inside this directory
            Get-Process -ErrorAction SilentlyContinue | Where-Object {
                try { $_.MainModule.FileName -like "$path\*" } catch { $false }
            } | ForEach-Object {
                Write-Host "Killing process: $($_.Name) ($($_.MainModule.FileName))"
                $_ | Stop-Process -Force -ErrorAction SilentlyContinue
            }
            Start-Sleep -Seconds 2
            try {
                Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
                Write-Host "Deleted: $path"
                $removed++
            } catch {
                Write-Host "FAILED deleting $path`: $($_.Exception.Message)"
                $failed++
            }
        } else {
            Write-Host "Not found: $path"
            $skipped++
        }
    }
}

# --- Clean up broken shortcuts ---
Write-Host "=== Shortcut Cleanup ==="
$shortcutDirs = @(
    'C:\ProgramData\Microsoft\Windows\Start Menu\Programs'
    'C:\Users\Public\Desktop'
) + (Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
     ForEach-Object {
         "$($_.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs"
         "$($_.FullName)\Desktop"
     })

$shell = New-Object -ComObject WScript.Shell
$cleanedShortcuts = 0
foreach ($dir in $shortcutDirs) {
    if (-not (Test-Path $dir)) { continue }
    Get-ChildItem -Path $dir -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $target = $shell.CreateShortcut($_.FullName).TargetPath
            if ($target -and -not (Test-Path $target)) {
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                Write-Host "Removed broken shortcut: $($_.Name) -> $target"
                $cleanedShortcuts++
            }
        } catch {}
    }
}
if ($cleanedShortcuts -eq 0) { Write-Host "No broken shortcuts found." }

# --- Summary ---
Write-Host "=== Summary ==="
Write-Host "Removed: $removed | Skipped (not found): $skipped | Failed: $failed"

if ($failed -gt 0) {
    Rmm-Alert -Category "App Removal" -Body "$failed app(s) failed to remove. Check script output."
    exit 1
}

exit 0
