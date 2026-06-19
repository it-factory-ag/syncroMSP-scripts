# schedule_reboot.ps1
# Downloads reboot_dialog.ps1 and shows it to the logged-in user via a
# scheduled task (required because SyncroMSP runs as SYSTEM).
#
# The dialog offers three outcomes:
#   - 30-min countdown expires -> reboot now
#   - "In 5 Minuten"          -> reboot in 5 min from click
#   - "In 6 Stunden"          -> reboot in 6h from click
#
# The user session cannot call shutdown.exe (Windows LUA privilege bug).
# Instead, the dialog writes a target restart timestamp to a flag file.
# A SYSTEM watcher task polls every minute and issues the actual shutdown
# once the target time is reached.

Import-Module $env:SyncroModule -DisableNameChecking

$dialogUrl      = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/reboot_dialog.ps1"
$scriptPath     = "C:\Windows\Temp\reboot_dialog.ps1"
$flagPath       = "C:\Windows\Temp\syncro_reboot_time.flag"
$watcherPath    = "C:\Windows\Temp\syncro_reboot_watcher.ps1"

# Cancel any previously scheduled shutdown
shutdown /a 2>$null

$loggedInUser = (Get-WmiObject Win32_ComputerSystem).UserName
Write-Host "WMI Win32_ComputerSystem.UserName: '$loggedInUser'"

# Fallback: query via explorer.exe owner (more reliable with Windows Hello / biometric login)
if (-not $loggedInUser) {
    $explorerOwner = Get-WmiObject Win32_Process -Filter "Name='explorer.exe'" |
        ForEach-Object { $_.GetOwner() } |
        Where-Object { $_.User } |
        Select-Object -First 1
    if ($explorerOwner) {
        $loggedInUser = "$($explorerOwner.Domain)\$($explorerOwner.User)"
        Write-Host "Fallback via explorer.exe owner: '$loggedInUser'"
    }
}

if (-not $loggedInUser) {
    Write-Host "No user logged in - rebooting immediately"
    shutdown /r /t 0 /f
    exit 0
}

Write-Host "Logged-in user: $loggedInUser"

# Download the dialog script and save with UTF-8 BOM so PowerShell reads umlauts correctly
Write-Host "Downloading reboot dialog..."
$dialogBytes = (New-Object System.Net.WebClient).DownloadData($dialogUrl)
$bom = [System.Text.Encoding]::UTF8.GetPreamble()
[System.IO.File]::WriteAllBytes($scriptPath, ($bom + $dialogBytes))

# Clear any leftover flag from a previous run
Remove-Item $flagPath -Force -ErrorAction SilentlyContinue

# Write the SYSTEM watcher script to a temp file (avoids complex inline escaping)
$watcherLines = @(
    '$flagPath = "C:\Windows\Temp\syncro_reboot_time.flag"',
    'if (Test-Path $flagPath) {',
    '    $target = [datetime](Get-Content $flagPath -Raw).Trim()',
    '    if ((Get-Date) -ge $target) {',
    '        shutdown /r /t 0 /f',
    '        Remove-Item $flagPath -Force -ErrorAction SilentlyContinue',
    '        Unregister-ScheduledTask -TaskName SyncroRebootWatcher -Confirm:$false -ErrorAction SilentlyContinue',
    '    }',
    '}'
)
Set-Content -Path $watcherPath -Value $watcherLines -Encoding ASCII

# SYSTEM watcher task: runs every minute for 7 hours, fires the reboot when the
# target time written by the dialog is reached.
$watchAction    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$watcherPath`""
$watchTrigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3) -RepetitionInterval (New-TimeSpan -Minutes 3) -RepetitionDuration (New-TimeSpan -Hours 7)
$watchTrigger.EndBoundary = $null
$watchPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$watchSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1)

Unregister-ScheduledTask -TaskName "SyncroRebootWatcher" -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName "SyncroRebootWatcher" -Action $watchAction -Trigger $watchTrigger -Principal $watchPrincipal -Settings $watchSettings -Force | Out-Null
Write-Host "Reboot watcher task scheduled (polls every 3 minutes for 7 hours)"

# Show the dialog in the user's interactive session via scheduled task
$taskName   = "SyncroRebootPrompt"
$dialogLog  = "C:\Windows\Temp\reboot_dialog.log"
Remove-Item $dialogLog -Force -ErrorAction SilentlyContinue
$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -Command `"Start-Transcript -Path '$dialogLog' -Force; `$ErrorActionPreference = 'Continue'; Write-Host ('LanguageMode: ' + `$ExecutionContext.SessionState.LanguageMode); & '$scriptPath'; Stop-Transcript`""
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10)
$trigger.EndBoundary = $null
$principal = New-ScheduledTaskPrincipal -UserId $loggedInUser -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 7)

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Reboot dialog task registered for $loggedInUser - fires in ~10 seconds"

Start-Sleep -Seconds 15
$taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
if ($taskInfo) {
    Write-Host "Task last run time  : $($taskInfo.LastRunTime)"
    Write-Host "Task last run result: $($taskInfo.LastTaskResult) (0 = success)"
    Write-Host "Task next run time  : $($taskInfo.NextRunTime)"
} else {
    Write-Host "WARNING: Could not retrieve task info for '$taskName'"
}

if (Test-Path $dialogLog) {
    Write-Host "--- Dialog script log ---"
    Get-Content $dialogLog | ForEach-Object { Write-Host $_ }
} else {
    Write-Host "No dialog log found - process may have been blocked before it could start"
}

$recentEvents = Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -like "*$taskName*" } |
    Select-Object -First 5
if ($recentEvents) {
    Write-Host "--- Task Scheduler events ---"
    foreach ($e in $recentEvents) {
        Write-Host "$($e.TimeCreated)  [$($e.Id)]  $($e.Message -replace '\s+',' ')"
    }
} else {
    Write-Host "No Task Scheduler events found for '$taskName'"
}

exit 0
