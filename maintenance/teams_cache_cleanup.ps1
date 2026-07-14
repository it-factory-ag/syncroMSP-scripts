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

# --- [1/3] Classic Teams cache ---
Write-Host ""
Write-Host "[1/3] Classic Teams cache..."
$classicPath = "$env:APPDATA\Microsoft\Teams"
if (Test-Path $classicPath) {
    Remove-Item "$classicPath" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  Removed: $classicPath"
} else {
    Write-Host "  Not present, skipped."
}

# --- [2/3] New Teams cache ---
Write-Host ""
Write-Host "[2/3] New Teams (MSTeams) cache..."
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

# --- [3/3] Shared WAM/broker identity cache ---
# Teams (and Office, Edge) resolve the tenant via the OS-wide Web Account
# Manager broker. A stale tenant resolution can survive even after the
# Teams-specific caches above are cleared, because it lives here instead.
Write-Host ""
Write-Host "[3/3] Shared WAM/broker identity cache..."
$brokerPaths = @(
    "$env:LOCALAPPDATA\Microsoft\IdentityCache",
    "$env:LOCALAPPDATA\Microsoft\OneAuth",
    "$env:LOCALAPPDATA\Microsoft\TokenBroker",
    "$env:LOCALAPPDATA\Packages\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy"
)
foreach ($p in $brokerPaths) {
    if (Test-Path $p) {
        Remove-Item "$p\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  Cleared: $p"
    } else {
        Write-Host "  Not present: $p"
    }
}

$credPatterns = @("TokenBroker", "AzureAD", "MicrosoftAccount", "WorkplaceJoin")
$credList = cmdkey /list
foreach ($pattern in $credPatterns) {
    $credMatches = $credList | Select-String -Pattern "Target: .*$pattern.*"
    foreach ($m in $credMatches) {
        $target = ($m.ToString() -replace "Target:\s*", "").Trim()
        Write-Host "  Removing credential: $target"
        cmdkey /delete:$target 2>$null | Out-Null
    }
}

Write-Host ""
Write-Host "=== Done ==="
Write-Host "Sign back into Teams to re-sync."
Write-Host "If the issue persists, also check Settings > Accounts > Access work or school for a stale account entry."

exit 0
