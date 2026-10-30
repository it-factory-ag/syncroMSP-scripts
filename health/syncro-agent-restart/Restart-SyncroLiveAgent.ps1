<#
Restarts SyncroLive.Agent.Runner when its handle count passes a threshold.

Why: SyncroLive.Agent.Runner 1.0.76.16392 leaks handles (~1'600 per hour on
HBL-SRV02, 150'000 after 3.5 days, other reports up to 1.1 million). Updating
the main Syncro agent does not update SyncroLive. Until Syncro fixes it, a
restart of the process resets the count.

How:
  1. Reports the result of the previous restart (result.json written by the
     scheduled task) and raises Rmm-Alert if it failed. The task itself can't
     alert: the Syncro module isn't available there.
  2. Reads the handle count of SyncroLive.Agent.Runner. Below -HandleThreshold
     it only logs the value and exits 0.
  3. Above it (or with -Force 1) it registers a one-time scheduled task
     "ITFactory-SyncroLiveRestart" (SYSTEM, starts in 1 minute) and exits.
     The restart runs decoupled so this Syncro run always reports back, no
     matter which Syncro process happens to run scripts.
  4. The task kills SyncroLive.Agent.Runner and waits up to 3 minutes for a new
     process. If none comes, it restarts the service whose binary is
     SyncroLive.Service.Runner.exe (found by path, not by guessing the service
     name) and waits again. It writes result.json, appends to restart.log and
     unregisters itself.

Files: C:\ProgramData\ITFactory\SyncroLiveRestart\ (restart.log keeps the last
500 lines, one line per run with the handle count).

Schedule daily (e.g. 03:00). Rmm-Alert only on failure (category
"SyncroLive Restart"); exit 1 then, otherwise exit 0. Not applicable (no
SyncroLive process) exits 0 with a message.

Run as: SYSTEM.
Local test: .\Test-Local.ps1 -Force 1 (uses Mock-SyncroModule.psm1). It really
kills the process: mocked is only Rmm-Alert, because killing and respawning is
exactly what needs testing.

Called via syncro_wrapper_syncro_live_restart.ps1; this file is never pasted
into Syncro, so it may use a param() block.
#>

param(
    [int]$HandleThreshold = 50000,
    [int]$Force = 0
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

if ($env:SyncroModule) { Import-Module $env:SyncroModule -DisableNameChecking }

$processName = "SyncroLive.Agent.Runner"
$taskName    = "ITFactory-SyncroLiveRestart"
$dataDir     = Join-Path $env:ProgramData "ITFactory\SyncroLiveRestart"
$logPath     = Join-Path $dataDir "restart.log"
$resultPath  = Join-Path $dataDir "result.json"
$taskScript  = Join-Path $dataDir "task.ps1"
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

function Write-Log([string]$Message) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [check] $Message"
    Write-Host $line
    Add-Content -Path $logPath -Value $line
}

$exitCode = 0

# --- 1. Result of the previous restart ---
if (Test-Path $resultPath) {
    try {
        $prev = Get-Content $resultPath -Raw | ConvertFrom-Json
        Write-Host "Previous restart ($($prev.Time)): $($prev.Status) - $($prev.Details)"
        if ($prev.Status -ne "OK") {
            Rmm-Alert -Category "SyncroLive Restart" -Body "Restart of $processName on $env:COMPUTERNAME failed at $($prev.Time): $($prev.Details). Check $logPath; Syncro remote access may be down."
            $exitCode = 1
        }
    } catch {
        Write-Host "WARNING: could not read $resultPath : $($_.Exception.Message)"
    }
    Remove-Item $resultPath -Force -ErrorAction SilentlyContinue
}

# --- 2. Pending task from an earlier run ---
$pending = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($pending) {
    $age = if (Test-Path $taskScript) { ((Get-Date) - (Get-Item $taskScript).LastWriteTime).TotalMinutes } else { 0 }
    if ($age -lt 30) {
        Write-Log "Restart task from an earlier run is still pending ($([math]::Round($age)) min old). Nothing to do."
        exit $exitCode
    }
    # The task removes itself when done; one older than 30 min never finished.
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Rmm-Alert -Category "SyncroLive Restart" -Body "Restart task on $env:COMPUTERNAME was still registered after $([math]::Round($age)) min and has been removed. Check $logPath."
    $exitCode = 1
}

# --- 3. Current handle count ---
$procs = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) {
    Write-Log "$processName is not running. Not applicable (no SyncroLive on this device) or currently restarting."
    exit $exitCode
}
# Win32_Process instead of MainModule: reading modules of a process with other bitness can fail.
$version = try { (Get-Item (Get-CimInstance Win32_Process -Filter "ProcessId=$($procs[0].Id)").ExecutablePath -ErrorAction Stop).VersionInfo.FileVersion } catch { "unknown" }
$maxHandles = ($procs | Measure-Object HandleCount -Maximum).Maximum
$details = ($procs | ForEach-Object {
    $ageH = try { [math]::Round(((Get-Date) - $_.StartTime).TotalHours, 1) } catch { "?" }
    "PID $($_.Id) handles $($_.HandleCount) age ${ageH}h"
}) -join "; "
Write-Log "$processName $version : $details (threshold $HandleThreshold)"

if ($maxHandles -lt $HandleThreshold -and $Force -ne 1) {
    # Keep the log bounded.
    $lines = @(Get-Content $logPath)
    if ($lines.Count -gt 500) { $lines | Select-Object -Last 500 | Set-Content $logPath }
    Write-Host "Below threshold, no restart."
    exit $exitCode
}

# --- 4. Schedule the decoupled restart ---
$task = @'
$processName = "SyncroLive.Agent.Runner"
$taskName    = "ITFactory-SyncroLiveRestart"
$dataDir     = Join-Path $env:ProgramData "ITFactory\SyncroLiveRestart"
$logPath     = Join-Path $dataDir "restart.log"
$resultPath  = Join-Path $dataDir "result.json"
function Write-Log([string]$Message) { Add-Content -Path $logPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [task]  $Message" }
function Wait-NewProcess($OldIds, [int]$Seconds) {
    for ($i = 0; $i -lt $Seconds; $i += 10) {
        Start-Sleep -Seconds 10
        $new = @(Get-Process -Name $processName -ErrorAction SilentlyContinue | Where-Object { $OldIds -notcontains $_.Id })
        if ($new.Count) { return $new[0] }
    }
    return $null
}

$status = "FAILED"; $details = ""
try {
    $old = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
    $oldIds = @($old | ForEach-Object { $_.Id })
    Write-Log "Killing $processName ($(($old | ForEach-Object { "PID $($_.Id) handles $($_.HandleCount)" }) -join '; '))"
    $old | Stop-Process -Force -ErrorAction Stop

    $new = Wait-NewProcess $oldIds 180
    if ($new) {
        $status = "OK"; $details = "respawned on its own: PID $($new.Id), handles $($new.HandleCount)"
    } else {
        $svc = Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'SyncroLive\.Service\.Runner' } | Select-Object -First 1
        if (-not $svc) {
            $details = "no respawn after 180 s and no service with SyncroLive.Service.Runner.exe found"
        } else {
            Write-Log "No respawn after 180 s, restarting service '$($svc.Name)'"
            Restart-Service -Name $svc.Name -Force -ErrorAction Stop
            $new = Wait-NewProcess $oldIds 180
            if ($new) { $status = "OK"; $details = "respawned after restarting service '$($svc.Name)': PID $($new.Id), handles $($new.HandleCount)" }
            else      { $details = "service '$($svc.Name)' restarted, but $processName did not come back within 180 s" }
        }
    }
} catch {
    $details = "error: $($_.Exception.Message)"
} finally {
    Write-Log "$status - $details"
    [pscustomobject]@{ Time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Status = $status; Details = $details } |
        ConvertTo-Json | Set-Content -Path $resultPath -Encoding UTF8
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}
'@

try {
    Set-Content -Path $taskScript -Value $task -Encoding UTF8
    $startAt  = (Get-Date).AddMinutes(1)
    $action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$taskScript`""
    $trigger  = New-ScheduledTaskTrigger -Once -At $startAt
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -User "SYSTEM" -RunLevel Highest -Force -ErrorAction Stop | Out-Null
    $reason = if ($Force -eq 1) { "forced (-Force 1)" } else { "$maxHandles handles >= threshold $HandleThreshold" }
    Write-Log "Restart scheduled for $($startAt.ToString('HH:mm:ss')): $reason. The next run reports the result."
} catch {
    Write-Log "FAILED to schedule restart: $($_.Exception.Message)"
    Rmm-Alert -Category "SyncroLive Restart" -Body "Could not schedule the restart of $processName on $env:COMPUTERNAME ($maxHandles handles): $($_.Exception.Message)"
    $exitCode = 1
}

exit $exitCode
