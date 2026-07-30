<#
Read-only diagnostic for "Outlook (Exchange/M365) doesn't fetch mail and
doesn't prompt for a password" - a stale/broken auth token is the usual
cause, but before running office_licence_cache_cleanup.ps1 (which force-closes
Office/Teams/OneDrive and needs a reboot) this collects evidence of where
the auth chain is actually stuck: device join state, cached token ages,
Credential Manager entries, Outlook profile accounts, network reachability
to the M365 auth/mail endpoints, and recent related event log errors.

Makes no changes. Prints everything to the script output for manual review.

Run as: logged-in user (not SYSTEM) - needs the user's HKCU hive and
LOCALAPPDATA to see the right identity/token cache.
#>

Import-Module $env:SyncroModule

Write-Host "=== Outlook Auth Debug ==="
Write-Host "User: $env:USERNAME  |  Computer: $env:COMPUTERNAME  |  $(Get-Date)"

# --- [1/6] Outlook process / version ---
Write-Host ""
Write-Host "[1/6] Outlook process..."
$outlookProc = Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue
if ($outlookProc) {
    Write-Host "  Running: PID $($outlookProc.Id), started $($outlookProc.StartTime)"
    Write-Host "  Version: $($outlookProc.Path | Get-Item | ForEach-Object { $_.VersionInfo.ProductVersion })"
} else {
    Write-Host "  Not running."
}

# --- [2/6] Azure AD device/user join state ---
Write-Host ""
Write-Host "[2/6] dsregcmd /status (device join + token state)..."
$dsreg = dsregcmd /status 2>$null
$relevantLines = $dsreg | Select-String -Pattern "AzureAdJoined|WorkplaceJoined|DomainJoined|AzureAdPrt|AzureAdPrtUpdateTime|AzureAdPrtExpiryTime|WamDefaultSet|WamDefaultAuthority"
$relevantLines | ForEach-Object { Write-Host "  $($_.ToString().Trim())" }

# --- [3/6] Broker/token cache freshness ---
Write-Host ""
Write-Host "[3/6] Broker/token cache folders (last write time = last refresh attempt)..."
$cachePaths = @(
    "$env:LOCALAPPDATA\Microsoft\IdentityCache",
    "$env:LOCALAPPDATA\Microsoft\OneAuth",
    "$env:LOCALAPPDATA\Microsoft\Office\TokenBroker",
    "$env:LOCALAPPDATA\Packages\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy\LocalState"
)
foreach ($p in $cachePaths) {
    if (Test-Path $p) {
        $newest = Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newest) {
            Write-Host "  $p -> newest file: $($newest.Name), last written $($newest.LastWriteTime)"
        } else {
            Write-Host "  $p -> present but empty"
        }
    } else {
        Write-Host "  $p -> not present"
    }
}

# --- [4/6] Credential Manager entries ---
Write-Host ""
Write-Host "[4/6] Relevant Credential Manager entries..."
$credPatterns = @("TokenBroker", "AzureAD", "MicrosoftAccount", "MicrosoftOffice16", "WorkplaceJoin", "OUTLOOK")
$credList = cmdkey /list
$foundAny = $false
foreach ($pattern in $credPatterns) {
    $credList | Select-String -Pattern "Target: .*$pattern.*" | ForEach-Object {
        Write-Host "  $($_.ToString().Trim())"
        $foundAny = $true
    }
}
if (-not $foundAny) { Write-Host "  None found matching known patterns." }

# --- [5/6] Outlook profile accounts (registry) ---
Write-Host ""
Write-Host "[5/6] Outlook profile accounts..."
$profileRoot = "HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles"
if (Test-Path $profileRoot) {
    Get-ChildItem $profileRoot -ErrorAction SilentlyContinue | ForEach-Object {
        $profileName = $_.PSChildName
        $accountsPath = Join-Path $_.PSPath "9375CFF0413111d3B88A00104B2A6676"
        if (Test-Path $accountsPath) {
            Get-ChildItem $accountsPath -ErrorAction SilentlyContinue | ForEach-Object {
                $acct = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                Write-Host "  Profile '$profileName': $($acct.'Account Name') <$($acct.'Email')> - type $($acct.'Account Type')"
            }
        }
    }
} else {
    Write-Host "  No Outlook profile registry key found."
}

# --- [6/6] Network reachability to M365 auth/mail endpoints ---
Write-Host ""
Write-Host "[6/6] Network reachability..."
$endpoints = @("login.microsoftonline.com", "outlook.office365.com", "outlook.office.com", "autodiscover-s.outlook.com")
foreach ($ep in $endpoints) {
    $test = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
    Write-Host "  $ep`:443 -> $(if ($test.TcpTestSucceeded) { 'OK' } else { 'FAILED' })"
}

# --- Recent related event log errors (last 24h) ---
Write-Host ""
Write-Host "Recent related event log errors (last 24h)..."
$since = (Get-Date).AddHours(-24)
try {
    $events = Get-WinEvent -FilterHashtable @{ LogName = "Application"; Level = 2, 3; StartTime = $since } -ErrorAction Stop |
        Where-Object { $_.ProviderName -match "Outlook|AAD|WAM|Identity|Broker" }
    if ($events) {
        $events | Select-Object -First 10 | ForEach-Object {
            Write-Host "  [$($_.TimeCreated)] $($_.ProviderName): $($_.Message -split "`n" | Select-Object -First 1)"
        }
    } else {
        Write-Host "  None found."
    }
} catch {
    Write-Host "  Could not read event log: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "=== Done ==="
Write-Host "No changes made. Review above for a stuck/expired token (stale AzureAdPrtUpdateTime, failed network checks) vs. a connectivity/firewall issue."

exit 0
