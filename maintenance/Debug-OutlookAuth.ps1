<#
Read-only diagnostic for "Outlook (Exchange/M365 or hosted Exchange) doesn't
fetch mail and doesn't prompt for a password" - a stale/broken auth token or a
corrupted local data file are the usual causes, but before running
office_licence_cache_cleanup.ps1 (which force-closes Office/Teams/OneDrive and
needs a reboot) this collects evidence of where the chain is actually stuck:
device join state, cached token ages, Credential Manager entries, Outlook
profile accounts, OST/PST file health, network reachability to the M365
auth/mail endpoints, the default account of the currently loaded profile, the
AutoDiscover registry state, and recent related event log errors.

Makes no changes. Prints everything to the script output for manual review.

Run as: logged-in user (not SYSTEM) - needs the user's HKCU hive and
LOCALAPPDATA to see the right identity/token cache.
#>

Import-Module $env:SyncroModule

Write-Host "=== Outlook Auth Debug ==="
Write-Host "User: $env:USERNAME  |  Computer: $env:COMPUTERNAME  |  $(Get-Date)"

# --- [1/9] Outlook process / version ---
Write-Host ""
Write-Host "[1/9] Outlook process..."
$outlookProc = Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue | Select-Object -First 1
if ($outlookProc) {
    $respondingText = if ($outlookProc.Responding) { "YES" } else { "NO - hung/not responding to its message loop" }
    Write-Host "  Running: PID $($outlookProc.Id), started $($outlookProc.StartTime)"
    Write-Host "  Responding: $respondingText"
    Write-Host "  Version: $($outlookProc.Path | Get-Item | ForEach-Object { $_.VersionInfo.ProductVersion })"
} else {
    Write-Host "  Not running."
}

# --- [2/9] Azure AD device/user join state ---
Write-Host ""
Write-Host "[2/9] dsregcmd /status (device join + token state)..."
$dsreg = dsregcmd /status 2>$null
$relevantLines = $dsreg | Select-String -Pattern "AzureAdJoined|WorkplaceJoined|DomainJoined|AzureAdPrt|AzureAdPrtUpdateTime|AzureAdPrtExpiryTime|WamDefaultSet|WamDefaultAuthority"
$relevantLines | ForEach-Object { Write-Host "  $($_.ToString().Trim())" }

# --- [3/9] Broker/token cache freshness ---
Write-Host ""
Write-Host "[3/9] Broker/token cache folders (last write time = last refresh attempt)..."
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

# --- [4/9] Credential Manager entries ---
Write-Host ""
Write-Host "[4/9] Relevant Credential Manager entries..."
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

# --- [5/9] Outlook profile accounts (registry) ---
Write-Host ""
Write-Host "[5/9] Outlook profile accounts..."
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

# --- [6/9] OST/PST data file inventory ---
# Size 0 or a LastWriteTime far in the past while Outlook is running are the
# classic signs of a stuck/corrupted local data file (see 0x8004010f-style errors
# in the event log section below).
Write-Host ""
Write-Host "[6/9] OST/PST data file inventory..."
$outlookDataPath = "$env:LOCALAPPDATA\Microsoft\Outlook"
if (Test-Path $outlookDataPath) {
    $dataFiles = Get-ChildItem -Path $outlookDataPath -Filter "*.ost" -File -ErrorAction SilentlyContinue
    $dataFiles += Get-ChildItem -Path $outlookDataPath -Filter "*.pst" -File -ErrorAction SilentlyContinue
    if ($dataFiles) {
        $now = Get-Date
        $dataFiles | Sort-Object LastWriteTime -Descending | ForEach-Object {
            $ageMin = [Math]::Round((New-TimeSpan -Start $_.LastWriteTime -End $now).TotalMinutes)
            $sizeMB = [Math]::Round($_.Length / 1MB, 1)
            $flag = if ($_.Length -eq 0) { " [EMPTY - 0 bytes]" } elseif ($ageMin -gt 60 -and $outlookProc) { " [STALE - not written in $ageMin min while Outlook is running]" } else { "" }
            Write-Host "  $($_.Name) - ${sizeMB} MB, last written $($_.LastWriteTime) ($ageMin min ago)$flag"
        }
    } else {
        Write-Host "  No .ost/.pst files found in $outlookDataPath"
    }
} else {
    Write-Host "  $outlookDataPath -> not present"
}

# --- [7/9] Network reachability to M365 auth/mail endpoints ---
Write-Host ""
Write-Host "[7/9] Network reachability..."
$endpoints = @("login.microsoftonline.com", "outlook.office365.com", "outlook.office.com", "autodiscover-s.outlook.com")
foreach ($ep in $endpoints) {
    $test = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
    Write-Host "  $ep`:443 -> $(if ($test.TcpTestSucceeded) { 'OK' } else { 'FAILED' })"
}

# --- [8/9] Default account/store of the currently loaded profile (via COM) ---
# Only attaches to an Outlook instance that is already running (GetActiveObject does
# not launch a new one), so this stays read-only and only covers the profile that is
# actually loaded right now - not every profile listed in [5/9].
Write-Host ""
Write-Host "[8/9] Default account/store (currently loaded profile only, via COM)..."
if ($outlookProc) {
    try {
        $ol = [Runtime.InteropServices.Marshal]::GetActiveObject("Outlook.Application")
        $ns = $ol.GetNamespace("MAPI")
        $defaultStore = $ns.DefaultStore
        Write-Host "  Default store: $($defaultStore.DisplayName)"
        foreach ($acct in $ns.Accounts) {
            $isDefault = $false
            try { $isDefault = $acct.DeliveryStore.StoreID -eq $defaultStore.StoreID } catch {}
            $marker = if ($isDefault) { " [DEFAULT]" } else { "" }
            Write-Host "  Account: $($acct.DisplayName) <$($acct.SmtpAddress)> - DeliveryStore: $($acct.DeliveryStore.DisplayName)$marker"
        }
    } catch {
        Write-Host "  Could not attach to running Outlook via COM: $($_.Exception.Message)"
    }
} else {
    Write-Host "  Outlook not running - skipped (would require launching Outlook, this script is read-only)."
}

# --- [9/9] AutoDiscover registry settings and cache ---
Write-Host ""
Write-Host "[9/9] AutoDiscover registry settings..."
$autoDiscoverKey = "HKCU:\Software\Microsoft\Office\16.0\Outlook\AutoDiscover"
if (Test-Path $autoDiscoverKey) {
    Write-Host "  ${autoDiscoverKey}:"
    $props = Get-ItemProperty -Path $autoDiscoverKey -ErrorAction SilentlyContinue
    $values = @()
    if ($props) { $values = @($props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }) }
    if ($values.Count -gt 0) {
        $values | ForEach-Object { Write-Host "    $($_.Name) = $($_.Value)" }
    } else {
        Write-Host "    (no explicit values - Outlook uses defaults)"
    }

    $cacheEntries = Get-ChildItem -Path $autoDiscoverKey -ErrorAction SilentlyContinue
    if ($cacheEntries) {
        Write-Host "  Cached AutoDiscover subkeys (per-account redirect/response cache):"
        $cacheEntries | ForEach-Object {
            Write-Host "    $($_.PSChildName)"
        }
    }
} else {
    Write-Host "  $autoDiscoverKey -> not present (no AutoDiscover overrides, no cache yet)"
}

$autoDiscoverPolicyKeys = @(
    "HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\outlook\autodiscover",
    "HKCU:\Software\Policies\Microsoft\office\16.0\outlook\autodiscover"
)
foreach ($polKey in $autoDiscoverPolicyKeys) {
    if (Test-Path $polKey) {
        Write-Host "  GPO override at ${polKey}:"
        Get-ItemProperty -Path $polKey -ErrorAction SilentlyContinue |
            ForEach-Object { $_.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } } |
            ForEach-Object { Write-Host "    $($_.Name) = $($_.Value)" }
    }
}

# --- Recent related event log errors (last 24h) ---
Write-Host ""
Write-Host "Recent related event log errors (last 24h)..."
Write-Host "  Note: these are NOT filtered per account/profile - Outlook's own event log messages"
Write-Host "  don't reliably expose which mailbox/account triggered them. Full message is printed"
Write-Host "  below so you can check it yourself; do not assume it belongs to a specific account."
$since = (Get-Date).AddHours(-24)
try {
    $events = Get-WinEvent -FilterHashtable @{ LogName = "Application"; Level = 2, 3; StartTime = $since } -ErrorAction Stop |
        Where-Object { $_.ProviderName -match "Outlook|AAD|WAM|Identity|Broker" }
    if ($events) {
        $events | Select-Object -First 10 | ForEach-Object {
            $fullMessage = ($_.Message -replace "`r`n", " " -replace "`n", " ").Trim()
            if ($fullMessage.Length -gt 300) { $fullMessage = $fullMessage.Substring(0, 300) + "..." }
            Write-Host "  [$($_.TimeCreated)] $($_.ProviderName): $fullMessage"
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
