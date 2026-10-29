<#
Immediately disables the temporary OpenSSH Server access opened by
Enable-TempSSHAccess.ps1, without waiting for the automatic timeout.
Restores sshd's original startup type (captured by Enable-TempSSHAccess.ps1
in state.json), disables the OpenSSH firewall rule again, removes any SSH
public key(s) Enable-TempSSHAccess.ps1 added to
C:\ProgramData\ssh\administrators_authorized_keys (pre-existing keys in that
file are left alone), and removes the one-time auto-disable scheduled task.

Safe to run even if no session is currently active (falls back to
"Disabled" as the original startup type, and no-ops on a missing service or
task).

Note: Enable-TempSSHAccess.ps1 embeds a copy of this same logic as a
here-string and deploys it to
C:\ProgramData\ITFactory\TempSSHAccess\Disable-TempSSHAccess.ps1 so the
scheduled task can call it later without depending on Syncro/network
reachability at that time. Keep the two in sync if you change either.
#>

# Script version = git blob hash of this file (same as `git hash-object <file>`), no git needed.
# Matches the repo only when the file runs unmodified, i.e. as downloaded by the wrapper.
# Look it up in the repo with: git log --oneline --find-object=<hash>
$scriptVersion = & {
    try {
        $bytes  = [IO.File]::ReadAllBytes($PSCommandPath)
        $prefix = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
        $sha1   = [Security.Cryptography.SHA1]::Create()
        $sha1.TransformBlock($prefix, 0, $prefix.Length, $null, 0) | Out-Null
        $sha1.TransformFinalBlock($bytes, 0, $bytes.Length) | Out-Null
        (($sha1.Hash | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 7)
    } catch { "unknown" }
}
Write-Host "Version: $scriptVersion"

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

    Write-Host "Temporaerer SSH-Zugriff auf $env:COMPUTERNAME wurde deaktiviert (sshd StartType zurueckgesetzt auf '$originalStartType')."
    exit 0
}
catch {
    $msg = "Deaktivieren des temporaeren SSH-Zugriffs fehlgeschlagen: $($_.Exception.Message)"
    Write-Host "ERROR: $msg"
    Rmm-Alert -Category "Temp SSH Access" -Body $msg
    exit 1
}
