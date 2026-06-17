# schedule_reboot.ps1
# Downloads reboot_dialog.ps1 and shows it to the logged-in user via a
# scheduled task (required because SyncroMSP runs as SYSTEM).
# The dialog has a 5-minute countdown. If the user clicks "In 5 Min. neu starten"
# (or the countdown expires), it writes a flag file. A SYSTEM watcher task fires
# at +5.5 minutes and issues the actual shutdown. "In 6 Stunden" closes the dialog
# and lets the 6h SYSTEM fallback run.

Import-Module $env:SyncroModule -DisableNameChecking

$dialogUrl    = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/reboot_dialog.ps1"
$scriptPath   = "C:\Windows\Temp\reboot_dialog.ps1"
$flagPath     = "C:\Windows\Temp\syncro_reboot_soon.flag"
$hoursMax     = 6
$secondsMax   = $hoursMax * 3600

# Cancel any previously scheduled shutdown
shutdown /a 2>$null

$loggedInUser = (Get-WmiObject Win32_ComputerSystem).UserName

if (-not $loggedInUser) {
    Write-Host "No user logged in - scheduling forced reboot in $hoursMax hours"
    shutdown /r /t $secondsMax /c "Dieser Computer wird in $hoursMax Stunden fuer Wartung neu gestartet." /f
    exit 0
}

Write-Host "Logged-in user: $loggedInUser"

# Download the dialog script
Write-Host "Downloading reboot dialog..."
(New-Object System.Net.WebClient).DownloadFile($dialogUrl, $scriptPath)

# Clear any leftover flag from a previous run
Remove-Item $flagPath -Force -ErrorAction SilentlyContinue

# Schedule forced reboot as fallback (covers "In 6 Stunden" and ignored dialogs)
shutdown /r /t $secondsMax /c "Dieser Computer wird in $hoursMax Stunden fuer Wartung neu gestartet. Bitte speichern Sie Ihre Arbeit." /f
Write-Host "Fallback forced reboot scheduled in $hoursMax hours"

# Show the dialog in the user's interactive session via scheduled task
$taskName  = "SyncroRebootPrompt"
$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10)
$trigger.EndBoundary = $null
$principal = New-ScheduledTaskPrincipal -UserId $loggedInUser -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Reboot dialog shown to $loggedInUser"

# SYSTEM watcher task: fires at +330s (5.5 min), checks flag file, reboots if set.
# This is how the "In 5 Min." button actually triggers the reboot - the user session
# can't call shutdown.exe (LUA privilege bug), so it writes a flag and SYSTEM does it.
$watchCmd = "if (Test-Path '$flagPath') { shutdown /r /t 0 /f }"
$watchArg = "-WindowStyle Hidden -NonInteractive -Command `"$watchCmd`""
$watchAction    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $watchArg
$watchTrigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(330)
$watchTrigger.EndBoundary = $null
$watchPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$watchSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

Unregister-ScheduledTask -TaskName "SyncroRebootWatcher" -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName "SyncroRebootWatcher" -Action $watchAction -Trigger $watchTrigger -Principal $watchPrincipal -Settings $watchSettings -Force | Out-Null
Write-Host "Reboot watcher task scheduled (fires in ~5.5 minutes)"
