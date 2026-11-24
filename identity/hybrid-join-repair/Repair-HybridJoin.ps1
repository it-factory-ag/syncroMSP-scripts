<#
Checks (and with -Action Repair fixes) Microsoft Entra hybrid join on a domain-joined
Windows device. Hybrid join is the prerequisite for Intune auto-enrollment via GPO.

Repairs the cause seen in the field: local policy
HKLM\SOFTWARE\Policies\Microsoft\Windows\WorkplaceJoin autoWorkplaceJoin = 0, which blocks
hybrid join and keeps the scheduled task \Microsoft\Windows\Workplace Join\Automatic-Device-Join
disabled. Repair removes the value, refreshes computer policy to detect a GPO that would set it
again, then enables and starts the task.

Guide (German): https://wiki.prod.itfactory.ch/doc/anleitung-windows-pc-nachtraglich-in-hybrid-join-und-intune-bringen-EdQhX8b8Ie

-Action Check   read-only (default)
-Action Repair  apply the fix if the device is not hybrid joined

Runs as SYSTEM. No local mock: Check is read-only, Repair changes one registry value and one
built-in scheduled task, both trivially reversible, so the first run on a single device is the test.

Exit codes: 0 = joined, repair started, or not applicable (not domain-joined)
            1 = Check found the device not joined, repair failed, or a GPO sets the blocker
#>
param(
    [ValidateSet('Check', 'Repair')]
    [string]$Action = 'Check'
)

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

$policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WorkplaceJoin'
$taskPath  = '\Microsoft\Windows\Workplace Join\'
$taskName  = 'Automatic-Device-Join'

function Get-JoinState {
    $out = & dsregcmd /status | Out-String
    [pscustomobject]@{
        DomainJoined  = $out -match 'DomainJoined\s*:\s*YES'
        AzureAdJoined = $out -match 'AzureAdJoined\s*:\s*YES'
    }
}

function Get-JoinBlocker {
    (Get-ItemProperty $policyKey -ErrorAction SilentlyContinue).autoWorkplaceJoin
}

function Test-IntuneEnrolled {
    # PushLaunch exists once the device has an MDM enrollment
    [bool](Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -TaskName PushLaunch -ErrorAction SilentlyContinue)
}

$state   = Get-JoinState
$blocker = Get-JoinBlocker
$task    = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue

Write-Host "=== Hybrid join ($Action) on $env:COMPUTERNAME ==="
Write-Host "DomainJoined:      $(if ($state.DomainJoined) { 'YES' } else { 'NO' })"
Write-Host "AzureAdJoined:     $(if ($state.AzureAdJoined) { 'YES' } else { 'NO' })"
Write-Host "Intune enrolled:   $(if (Test-IntuneEnrolled) { 'YES' } else { 'NO' })"
Write-Host "autoWorkplaceJoin: $(if ($null -eq $blocker) { '(not set)' } else { $blocker })"
Write-Host "Join task:         $(if ($task) { $task.State } else { 'missing' })"

if (-not $state.DomainJoined) {
    Write-Host "Not domain-joined: hybrid join does not apply to this device."
    exit 0
}

if ($state.AzureAdJoined) {
    if (Test-IntuneEnrolled) {
        Write-Host "OK: hybrid joined and enrolled in Intune."
    }
    else {
        Write-Host "OK: hybrid joined, not enrolled in Intune yet. Enrollment follows via the MDM auto-enrollment GPO at the next user sign-in or within a few hours. If it never does: check that GPO and the user's Intune license."
    }
    exit 0
}

if ($Action -eq 'Check') {
    Write-Host "NOT hybrid joined. Run again with Action = Repair."
    exit 1
}

try {
    if ($null -ne $blocker) {
        Remove-ItemProperty $policyKey -Name autoWorkplaceJoin -ErrorAction Stop
        Write-Host "Removed autoWorkplaceJoin = $blocker."

        # A GPO would write the value back on the next refresh; force one now to find out
        & gpupdate /target:computer /force | Out-Null
        $again = Get-JoinBlocker
        if ($null -ne $again -and $again -eq 0) {
            $msg = "$($env:COMPUTERNAME): autoWorkplaceJoin = 0 is set by a GPO (back after gpupdate). Fix the GPO (gpresult /scope computer, search for WorkplaceJoin); the local repair cannot stick."
            Rmm-Alert -Category 'Hybrid Join' -Body $msg
            Write-Host "ERROR: $msg"
            exit 1
        }
    }

    if (-not $task) { throw "Scheduled task $taskPath$taskName is missing." }
    Enable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop
    Write-Host "Enabled and started $taskName."
}
catch {
    $msg = "$($env:COMPUTERNAME): hybrid join repair failed: $($_.Exception.Message)"
    Rmm-Alert -Category 'Hybrid Join' -Body $msg
    Write-Host "ERROR: $msg"
    exit 1
}

Start-Sleep -Seconds 60
if ((Get-JoinState).AzureAdJoined) {
    Write-Host "OK: AzureAdJoined = YES. Intune enrollment follows via the MDM auto-enrollment GPO at the next user sign-in."
}
else {
    Write-Host "Join started, not completed yet. Usually the device object reaches Entra only with the next Entra Connect sync (about 30 min). Run Check again in an hour; if still NO, restart the device and let the user sign in, then read 'Diagnostic Data' in dsregcmd /status."
}
exit 0
