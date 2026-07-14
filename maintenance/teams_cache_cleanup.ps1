Import-Module $env:SyncroModule

# Clears local Teams caches (classic + new Teams) that can pin a device to a
# stale tenant/account resolution, e.g. after a UPN rename or a conflicting
# guest invite in another tenant. No documents or chat history are stored
# locally beyond cache/token data - Teams re-syncs everything after re-login.
#
# Run as: logged-in user (not SYSTEM) in SyncroMSP
# After this script: sign back into Teams.

Write-Host "=== Teams Cache Cleanup ==="

# --- Force-close Teams ---
# SyncroMSP runs non-interactively, so processes are killed without prompting.
$teamsProcs = Get-Process -Name "Teams","ms-teams" -ErrorAction SilentlyContinue
if ($teamsProcs) {
    Write-Host "Force-closing running Teams processes:"
    $teamsProcs | Select-Object Name, Id | Format-Table
    $teamsProcs | Stop-Process -Force
    Start-Sleep -Seconds 2
} else {
    Write-Host "No Teams processes running."
}

# --- [1/2] Classic Teams cache ---
Write-Host ""
Write-Host "[1/2] Classic Teams cache..."
$classicPath = "$env:APPDATA\Microsoft\Teams"
if (Test-Path $classicPath) {
    Remove-Item "$classicPath" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  Removed: $classicPath"
} else {
    Write-Host "  Not present, skipped."
}

# --- [2/2] New Teams cache ---
Write-Host ""
Write-Host "[2/2] New Teams (MSTeams) cache..."
$newTeamsPaths = @(
    "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache",
    "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalState"
)
foreach ($p in $newTeamsPaths) {
    if (Test-Path $p) {
        Remove-Item "$p\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  Cleared: $p"
    } else {
        Write-Host "  Not present: $p"
    }
}

Write-Host ""
Write-Host "=== Done ==="
Write-Host "Sign back into Teams to re-sync."

exit 0
