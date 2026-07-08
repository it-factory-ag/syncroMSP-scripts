Import-Module $env:SyncroModule

# Clears all Office/M365 identity and license caches after a UPN or primary
# email change. Only removes auth/license cache data — no documents or personal
# files. All caches rebuild automatically on next login after restart.
#
# Run as: logged-in user (not SYSTEM) in SyncroMSP
# After this script: reboot required, then re-sign in to Office with the new address.

Write-Host "=== Office/M365 Identity Cache Cleanup ==="

# --- Force-close Office and Teams ---
# SyncroMSP runs non-interactively, so processes are killed without prompting.
$officeProcs = Get-Process -Name "OUTLOOK","WINWORD","EXCEL","POWERPNT","Teams","ms-teams","OneDrive" -ErrorAction SilentlyContinue
if ($officeProcs) {
    Write-Host "Force-closing running Office/Teams processes:"
    $officeProcs | Select-Object Name, Id | Format-Table
    $officeProcs | Stop-Process -Force
    Start-Sleep -Seconds 2
} else {
    Write-Host "No Office/Teams processes running."
}

# --- [1/6] Credential Manager ---
Write-Host ""
Write-Host "[1/6] Credential Manager entries..."
$patterns = @("MicrosoftAccount", "OfficeHome", "WindowsLive", "TokenBroker", "MicrosoftOffice16")
$credList = cmdkey /list
foreach ($pattern in $patterns) {
    $credMatches = $credList | Select-String -Pattern "Target: .*$pattern.*"
    foreach ($m in $credMatches) {
        $target = ($m.ToString() -replace "Target:\s*", "").Trim()
        Write-Host "  Removing: $target"
        cmdkey /delete:$target 2>$null | Out-Null
    }
}

# --- [2/6] OneAuth cache ---
Write-Host ""
Write-Host "[2/6] OneAuth cache..."
$oneAuth = "$env:LOCALAPPDATA\Microsoft\OneAuth"
if (Test-Path $oneAuth) {
    Remove-Item "$oneAuth\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  Cleared: $oneAuth"
} else {
    Write-Host "  Not present, skipped."
}

# --- [3/6] Office licensing cache ---
Write-Host ""
Write-Host "[3/6] Office licensing cache..."
$licensePaths = @(
    "$env:LOCALAPPDATA\Microsoft\Office\Licenses",
    "$env:LOCALAPPDATA\Microsoft\Office\16.0\Licensing"
)
foreach ($p in $licensePaths) {
    if (Test-Path $p) {
        Remove-Item "$p\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  Cleared: $p"
    } else {
        Write-Host "  Not present: $p"
    }
}

# --- [4/6] AAD Broker Plugin cache ---
Write-Host ""
Write-Host "[4/6] AAD Broker Plugin cache..."
$brokerPath = "$env:LOCALAPPDATA\Packages\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy"
if (Test-Path $brokerPath) {
    Remove-Item "$brokerPath\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  Cleared: $brokerPath"
} else {
    Write-Host "  Not present, skipped."
}

# --- [5/6] IdentityCache and TokenBroker ---
Write-Host ""
Write-Host "[5/6] IdentityCache / TokenBroker..."
$otherPaths = @(
    "$env:LOCALAPPDATA\Microsoft\IdentityCache",
    "$env:LOCALAPPDATA\Microsoft\Office\TokenBroker"
)
foreach ($p in $otherPaths) {
    if (Test-Path $p) {
        Remove-Item "$p\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  Cleared: $p"
    } else {
        Write-Host "  Not present: $p"
    }
}

# --- [6/6] Office identity registry ---
Write-Host ""
Write-Host "[6/6] Office identity registry..."
$regPath = "HKCU:\Software\Microsoft\Office\16.0\Common\Identity\Identities"
if (Test-Path $regPath) {
    Remove-Item $regPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  Removed: $regPath"
} else {
    Write-Host "  Not present, skipped."
}

Write-Host ""
Write-Host "=== Done ==="
Write-Host "REBOOT REQUIRED. After restart, open Office and sign in with the correct address."

exit 0
