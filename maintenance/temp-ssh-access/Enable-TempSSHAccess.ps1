<#
Temporarily enables the OpenSSH Server for a remote support/debug session,
then automatically disables it again after -DurationMinutes (default 60) via
a one-time Windows Scheduled Task - so access closes itself even if nobody
remembers to run Disable-TempSSHAccess.ps1, and even if the Syncro
connection drops mid-session.

Installs the OpenSSH.Server Windows capability if missing (left installed
afterwards - re-downloading it every session is wasteful and harmless to
leave present), starts sshd, sets it to Manual startup, and makes sure the
"OpenSSH-Server-In-TCP" firewall rule is enabled. That rule is not scoped to
a network profile by Windows (it applies on Domain/Private/Public alike), so
switching the connection profile to "Private" is not required for SSH itself
to work and this script does not touch it.

Original sshd startup type is captured once per session (in state.json) so
Disable-TempSSHAccess.ps1 can restore it exactly rather than assuming a
default. Re-running this script while a session is already active just
extends the timer (re-registers the scheduled task) without touching the
saved state.

Deploys a local copy of Disable-TempSSHAccess.ps1 to
C:\ProgramData\ITFactory\TempSSHAccess\Disable-TempSSHAccess.ps1 for the
scheduled task to call - keep that embedded copy (below) in sync with the
real maintenance/temp-ssh-access/Disable-TempSSHAccess.ps1 in this repo if
you change one.

To disable immediately instead of waiting for the timer, run
Disable-TempSSHAccess.ps1 from Syncro.

Optional -SshPublicKey enables key-based login in addition to the existing
password login (which is left untouched). The key is written to
C:\ProgramData\ssh\administrators_authorized_keys - the special path Windows
OpenSSH requires for logins by members of the local Administrators group
(the usual ~\.ssh\authorized_keys is ignored for admin accounts) - with its
ACL locked down to SYSTEM + Administrators only, since sshd refuses the file
with "bad ownership or modes" otherwise. Only the key(s) this script added
are tracked (in state.json) and removed again on disable; any pre-existing
keys in that file are left alone.

Custom asset field (optional, Admin --> Custom Asset Fields):
  Temp SSH Access Expires   Text   yyyy-MM-dd HH:mm:ss
#>

param(
    [int]$DurationMinutes = 60,
    [string]$SshPublicKey = ""
)

Import-Module $env:SyncroModule

$ErrorActionPreference = "Stop"

$stateDir           = "C:\ProgramData\ITFactory\TempSSHAccess"
$stateFile          = Join-Path $stateDir "state.json"
$localDisableScript = Join-Path $stateDir "Disable-TempSSHAccess.ps1"
$taskName           = "ITFactory-TempSSHAccess-AutoDisable"
$firewallRuleName   = "OpenSSH-Server-In-TCP"
$capabilityName     = "OpenSSH.Server~~~~0.0.1.0"

try {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

    # --- Install OpenSSH Server capability if missing ---
    $capability = Get-WindowsCapability -Online -Name $capabilityName
    if ($capability.State -ne "Installed") {
        Write-Host "Installiere OpenSSH-Server-Feature..."
        Add-WindowsCapability -Online -Name $capabilityName | Out-Null
    }

    $service = Get-Service -Name sshd

    # --- Capture original state only on first enable of a session ---
    if (-not (Test-Path $stateFile)) {
        $state = [ordered]@{
            OriginalStartType = $service.StartType.ToString()
            EnabledAt         = (Get-Date).ToString("s")
            AddedKeys         = @()
        }
        Write-Host "Ausgangszustand gesichert: sshd StartType war '$($state.OriginalStartType)'."
    } else {
        Write-Host "Temporaere SSH-Session bereits aktiv - Timer wird verlaengert."
        $state = Get-Content $stateFile -Raw | ConvertFrom-Json
    }

    # --- Start sshd ---
    Set-Service -Name sshd -StartupType Manual
    if ($service.Status -ne "Running") {
        Start-Service -Name sshd
    }

    # --- Ensure the firewall rule is enabled ---
    $rule = Get-NetFirewallRule -Name $firewallRuleName -ErrorAction SilentlyContinue
    if ($rule) {
        Set-NetFirewallRule -Name $firewallRuleName -Enabled True
    } else {
        New-NetFirewallRule -Name $firewallRuleName -DisplayName "OpenSSH SSH Server (sshd)" `
            -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow | Out-Null
    }

    # --- Deploy SSH public key for key-based login (optional, password login stays untouched) ---
    if ($SshPublicKey) {
        $keyLine      = $SshPublicKey.Trim()
        $sshDir       = "C:\ProgramData\ssh"
        $authKeysFile = Join-Path $sshDir "administrators_authorized_keys"

        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        if (-not (Test-Path $authKeysFile)) {
            New-Item -ItemType File -Path $authKeysFile -Force | Out-Null
        }

        $existingLines = @(Get-Content -Path $authKeysFile -ErrorAction SilentlyContinue)
        if ($existingLines -notcontains $keyLine) {
            Add-Content -Path $authKeysFile -Value $keyLine
            $state.AddedKeys = @($state.AddedKeys) + $keyLine
            Write-Host "SSH-Public-Key hinzugefuegt."
        } else {
            Write-Host "SSH-Public-Key bereits vorhanden."
        }

        # administrators_authorized_keys must be locked down to SYSTEM + Administrators
        # only, or sshd refuses it with "bad ownership or modes".
        icacls $authKeysFile /inheritance:r | Out-Null
        icacls $authKeysFile /grant "SYSTEM:F" | Out-Null
        icacls $authKeysFile /grant "Administrators:F" | Out-Null
    }

    $state | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8

    # --- Deploy the local copy of the disable logic the scheduled task will call ---
    # Keep this in sync with maintenance/temp-ssh-access/Disable-TempSSHAccess.ps1 in the repo.
    @'
<# Auto-generated by Enable-TempSSHAccess.ps1 - do not edit here, edit maintenance/temp-ssh-access/Disable-TempSSHAccess.ps1 in the repo instead and re-run Enable-TempSSHAccess.ps1 to redeploy. #>
Import-Module $env:SyncroModule

$stateDir         = "C:\ProgramData\ITFactory\TempSSHAccess"
$stateFile        = Join-Path $stateDir "state.json"
$taskName         = "ITFactory-TempSSHAccess-AutoDisable"
$firewallRuleName = "OpenSSH-Server-In-TCP"
$authKeysFile     = "C:\ProgramData\ssh\administrators_authorized_keys"

try {
    $originalStartType = "Disabled"
    $addedKeys = @()
    if (Test-Path $stateFile) {
        try {
            $savedState = Get-Content $stateFile -Raw | ConvertFrom-Json
            $originalStartType = $savedState.OriginalStartType
            $addedKeys = @($savedState.AddedKeys)
        } catch {}
    }

    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($service) {
        Stop-Service -Name sshd -Force -ErrorAction SilentlyContinue
        Set-Service -Name sshd -StartupType $originalStartType -ErrorAction SilentlyContinue
    }

    Set-NetFirewallRule -Name $firewallRuleName -Enabled False -ErrorAction SilentlyContinue

    if ($addedKeys.Count -gt 0 -and (Test-Path $authKeysFile)) {
        $remainingLines = @(Get-Content $authKeysFile | Where-Object { $addedKeys -notcontains $_ })
        if ($remainingLines.Count -gt 0) {
            Set-Content -Path $authKeysFile -Value $remainingLines -Encoding UTF8
        } else {
            Remove-Item $authKeysFile -ErrorAction SilentlyContinue
        }
    }

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $stateFile -ErrorAction SilentlyContinue

    Write-Host "Temporaerer SSH-Zugriff auf $env:COMPUTERNAME wurde automatisch deaktiviert (sshd StartType zurueckgesetzt auf '$originalStartType')."
}
catch {
    $msg = "Automatisches Deaktivieren des temporaeren SSH-Zugriffs auf $env:COMPUTERNAME fehlgeschlagen: $($_.Exception.Message)"
    Write-Host "ERROR: $msg"
    Rmm-Alert -Category "Temp SSH Access" -Body $msg
}
'@ | Set-Content -Path $localDisableScript -Encoding UTF8

    # --- (Re-)register the one-time auto-disable task ---
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$localDisableScript`""
    $expiresAt = (Get-Date).AddMinutes($DurationMinutes)
    $trigger   = New-ScheduledTaskTrigger -Once -At $expiresAt
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null

    try { Set-Asset-Field -Name "Temp SSH Access Expires" -Value $expiresAt.ToString("yyyy-MM-dd HH:mm:ss") } catch {}

    $ips = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch "Loopback" }).IPAddress -join ", "

    Write-Host "Temporaerer SSH-Zugriff auf $env:COMPUTERNAME aktiviert bis $($expiresAt.ToString('yyyy-MM-dd HH:mm:ss')). IP(s): $ips"
    Write-Host "Verbindung: ssh <user>@<ip>"

    exit 0
}
catch {
    $msg = "Aktivieren des temporaeren SSH-Zugriffs fehlgeschlagen: $($_.Exception.Message)"
    Write-Host "ERROR: $msg"
    Rmm-Alert -Category "Temp SSH Access" -Body $msg
    exit 1
}
