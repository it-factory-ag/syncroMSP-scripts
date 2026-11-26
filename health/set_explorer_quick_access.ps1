# No param() block on purpose: Syncro injects Script Variables as plain assignments at the
# top of the script, which would push param() off the first line and break it.
# Optional Syncro variable (dropdown) "Action":
#   Apply  = Explorer opens "This PC", no recent files / frequent folders in Quick access
#   Remove = remove the values again, Windows default applies (Quick access with recent files)
if (-not $Action) { $Action = "Apply" }

# Also runs from a SYSTEM remote shell without the Syncro module (then without Rmm-Alert).
if ($env:SyncroModule) { Import-Module $env:SyncroModule -DisableNameChecking }

if ($Action -notin @("Apply", "Remove")) {
    Write-Host "ERROR: invalid Action '$Action' (allowed: Apply, Remove)"
    exit 1
}

# Why: Quick access lists the 20 most recent files and frequent folders, mostly on file
# server shares. Each time Explorer or an Open/Save dialog (Office, Foxit) shows it, Windows
# checks every entry and loads icons/thumbnails over the network. On terminal servers with
# a busy or slow file server this makes Explorer take seconds to open (HBL-SRV02).
# Pinned Quick access folders stay; only the automatic lists are hidden.
#
# Per-user settings (HKCU), set for every user profile on the device plus the Default
# profile (new users). Loaded hives (logged-on users) are written directly, others are
# mounted from NTUSER.DAT. Same as GPO User Configuration > Preferences > Registry:
#   Explorer\Advanced\LaunchTo   = 1 (This PC instead of Quick access)
#   Explorer\ShowRecent          = 0 (no recent files)
#   Explorer\ShowFrequent        = 0 (no frequent folders)
# New Explorer windows pick it up; an already open Explorer may only show it after an
# Explorer restart or the next logon.
#
# Runs as SYSTEM. Rmm-Alert (category "Explorer Quick Access") only if a profile fails.

$settings = @(
    @{ Key = "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "LaunchTo";     Value = 1 }
    @{ Key = "Software\Microsoft\Windows\CurrentVersion\Explorer";          Name = "ShowRecent";   Value = 0 }
    @{ Key = "Software\Microsoft\Windows\CurrentVersion\Explorer";          Name = "ShowFrequent"; Value = 0 }
)

function Set-HiveValues([string]$Root) {
    foreach ($s in $settings) {
        $path = "Registry::$Root\$($s.Key)"
        if ($Action -eq "Apply") {
            # No New-Item -Force on an existing key: that would recreate it empty.
            if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
            New-ItemProperty -Path $path -Name $s.Name -Value $s.Value -PropertyType DWord -Force | Out-Null
        } elseif (Test-Path $path) {
            Remove-ItemProperty -Path $path -Name $s.Name -ErrorAction SilentlyContinue
        }
    }
}

# Real user profiles (S-1-5-21-..., no .bak duplicates) plus the Default profile.
$profiles = @(Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" |
    Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } | ForEach-Object {
        $sid  = $_.PSChildName
        $name = try { (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount]).Value } catch { $sid }
        [pscustomobject]@{ Name = $name; Sid = $sid; Path = (Get-ItemProperty $_.PSPath).ProfileImagePath }
    })
$profiles += [pscustomobject]@{ Name = "Default profile (new users)"; Sid = "Default"; Path = "$env:SystemDrive\Users\Default" }

Write-Host "=== Explorer Quick access: $Action on $($profiles.Count) profile(s) ==="

$failed = @()
foreach ($p in $profiles) {
    $loaded = $p.Sid -ne "Default" -and (Test-Path "Registry::HKEY_USERS\$($p.Sid)")
    $mount  = "HKEY_USERS\ITF_QA_$($p.Sid)"
    try {
        if ($loaded) {
            Set-HiveValues "HKEY_USERS\$($p.Sid)"
            Write-Host "OK   $($p.Name) (logged on)"
        } else {
            $ntuser = Join-Path $p.Path "NTUSER.DAT"
            if (-not (Test-Path $ntuser)) { Write-Host "SKIP $($p.Name): no $ntuser"; continue }
            & reg.exe load $mount $ntuser 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "reg load $ntuser failed (exit $LASTEXITCODE)" }
            try {
                Set-HiveValues $mount
                Write-Host "OK   $($p.Name) (offline hive)"
            } finally {
                # Open .NET registry handles block the unload.
                [GC]::Collect(); [GC]::WaitForPendingFinalizers()
                & reg.exe unload $mount 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { Write-Host "WARNING: could not unload $mount (exit $LASTEXITCODE)" }
            }
        }
    } catch {
        Write-Host "FAIL $($p.Name): $($_.Exception.Message)"
        $failed += $p.Name
    }
}

if ($failed.Count) {
    if (Get-Command Rmm-Alert -ErrorAction SilentlyContinue) {
        Rmm-Alert -Category "Explorer Quick Access" -Body "Explorer Quick access ($Action) failed on $env:COMPUTERNAME for: $($failed -join ', ')"
    }
    exit 1
}
exit 0
