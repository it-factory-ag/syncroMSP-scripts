<#
Backs up user data to an external drive ahead of a PC replacement/migration.

Run this directly from SyncroMSP against the old machine with the external
drive already plugged in. Pass the drive letter as -TargetDrive (e.g. "E:").

Skips Windows system/service profiles automatically (queries
Win32_UserProfile -Filter "Special = False" rather than just listing
C:\Users, so Default, Public, systemprofile, LocalService etc. are excluded
without a maintained exclude list). Assumes standard, non-redirected folder
locations under each profile (English folder names) - if a folder was moved
or OneDrive-redirected elsewhere, it won't be picked up.

Destination mirrors each source path relative to its drive root, e.g.
C:\Users\jdoe\Desktop -> <TargetDrive>\UserDataBackup\Users\jdoe\Desktop
so extra paths outside C:\Users (added to $AdditionalPaths below) land at
the matching location instead of colliding with the per-user folders.

This is a one-off data transfer ahead of a machine swap, not a recurring
backup - re-running against the same target drive overwrites/merges into
the same UserDataBackup folder rather than creating a new timestamped one.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$TargetDrive
)

# --- Configuration: edit these to change what gets backed up ---------------

# Folders backed up per real local user profile (relative to C:\Users\<user>)
$FoldersToBackup = "Desktop", "Documents", "Downloads", "Pictures", "Music", "Videos"

# Extra absolute paths to back up as-is, outside any user profile (optional)
$AdditionalPaths = @()

# Where backups land on the external drive
$BackupRoot = Join-Path "$($TargetDrive.TrimEnd('\'))\" "UserDataBackup"

# -----------------------------------------------------------------------------

Import-Module $env:SyncroModule

if (-not (Test-Path "$($TargetDrive.TrimEnd('\'))\")) {
    $msg = "Target drive '$TargetDrive' not found. Plug in the external drive and pass its drive letter, e.g. -TargetDrive E:"
    Write-Host "ERROR: $msg"
    Rmm-Alert -Category "Backup-UserData" -Body $msg
    exit 1
}

$LogFile = Join-Path $BackupRoot "robocopy.log"
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

function Backup-Path {
    param([string]$Source)

    if (-not (Test-Path $Source)) { return $false }

    $relativePath = $Source -replace '^[A-Za-z]:\\', ''
    $destination  = Join-Path $BackupRoot $relativePath
    robocopy $Source $destination /E /R:1 /W:1 /XJ /NFL /NDL /LOG+:$LogFile | Out-Null

    if ($LASTEXITCODE -ge 8) {
        Write-Host "ERROR: robocopy failed for $Source (exit code $LASTEXITCODE) - see $LogFile"
        return $null
    }

    Write-Host "OK: $Source -> $destination"
    return $true
}

$Profiles = Get-CimInstance Win32_UserProfile -Filter "Special = False" |
    Where-Object { $_.LocalPath -and (Test-Path $_.LocalPath) }

if (-not $Profiles -and -not $AdditionalPaths) {
    $msg = "No local user profiles found and no additional paths configured - nothing to back up."
    Write-Host "ERROR: $msg"
    Rmm-Alert -Category "Backup-UserData" -Body $msg
    exit 1
}

$HadErrors = $false
$CopiedAny = $false

foreach ($p in $Profiles) {
    foreach ($folder in $FoldersToBackup) {
        $result = Backup-Path (Join-Path $p.LocalPath $folder)
        if ($result -eq $true) { $CopiedAny = $true }
        elseif ($result -eq $null) { $HadErrors = $true }
    }
}

foreach ($path in $AdditionalPaths) {
    $result = Backup-Path $path
    if ($result -eq $true) { $CopiedAny = $true }
    elseif ($result -eq $null) { $HadErrors = $true }
}

if (-not $CopiedAny) {
    $msg = "No user data folders were found across any local profile or additional path - nothing was backed up."
    Write-Host "ERROR: $msg"
    Rmm-Alert -Category "Backup-UserData" -Body $msg
    exit 1
}

if ($HadErrors) {
    $msg = "User data backup to $BackupRoot completed with errors - see $LogFile for details."
    Write-Host "ERROR: $msg"
    Rmm-Alert -Category "Backup-UserData" -Body $msg
    exit 1
}

Write-Host "Backup completed successfully to $BackupRoot"
exit 0
