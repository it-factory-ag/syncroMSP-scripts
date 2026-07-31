<#
Immediately disables OpenSSH-Server debug access opened by Enable-SSHDebug.ps1,
without waiting for the automatic timeout. Restores sshd's original startup
type (captured by Enable-SSHDebug.ps1 in state.json), disables the OpenSSH
firewall rule again, and removes the one-time auto-disable scheduled task.

Safe to run even if no debug session is currently active (falls back to
"Disabled" as the original startup type, and no-ops on a missing service or
task).

Note: Enable-SSHDebug.ps1 embeds a copy of this same logic as a here-string
and deploys it to C:\ProgramData\ITFactory\SSHDebug\Disable-SSHDebug.ps1 so
the scheduled task can call it later without depending on Syncro/network
reachability at that time. Keep the two in sync if you change either.
#>

Import-Module $env:SyncroModule

$stateDir         = "C:\ProgramData\ITFactory\SSHDebug"
$stateFile        = Join-Path $stateDir "state.json"
$taskName         = "ITFactory-SSHDebug-AutoDisable"
$firewallRuleName = "OpenSSH-Server-In-TCP"

try {
    $originalStartType = "Disabled"
    if (Test-Path $stateFile) {
        try { $originalStartType = (Get-Content $stateFile -Raw | ConvertFrom-Json).OriginalStartType } catch {}
    }

    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($service) {
        Stop-Service -Name sshd -Force -ErrorAction SilentlyContinue
        Set-Service -Name sshd -StartupType $originalStartType -ErrorAction SilentlyContinue
    }

    Set-NetFirewallRule -Name $firewallRuleName -Enabled False -ErrorAction SilentlyContinue

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $stateFile -ErrorAction SilentlyContinue

    $msg = "OpenSSH-Debug-Zugriff auf $env:COMPUTERNAME wurde deaktiviert (sshd StartType zurueckgesetzt auf '$originalStartType')."
    Write-Host $msg
    Rmm-Alert -Category "SSH Debug Access" -Body $msg
    exit 0
}
catch {
    $msg = "Deaktivieren von OpenSSH-Debug fehlgeschlagen: $($_.Exception.Message)"
    Write-Host "ERROR: $msg"
    Rmm-Alert -Category "SSH Debug Access" -Body $msg
    exit 1
}
