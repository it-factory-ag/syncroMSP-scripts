# schedule_reboot.ps1
# Downloads reboot_dialog.ps1 and shows it to the logged-in user via a
# scheduled task (required because SyncroMSP runs as SYSTEM).
# The dialog has a 30-minute countdown and postpone options up to 8 hours.
# A forced reboot is scheduled regardless so the user cannot skip it entirely.

Import-Module $env:SyncroModule -DisableNameChecking

$dialogUrl    = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/reboot_dialog.ps1"
$scriptPath   = "C:\Windows\Temp\reboot_dialog.ps1"
$hoursMax     = 8
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

# Schedule forced reboot as fallback (in case user postpones to max and dialog closes)
shutdown /r /t $secondsMax /c "Dieser Computer wird in $hoursMax Stunden fuer Wartung neu gestartet. Bitte speichern Sie Ihre Arbeit." /f
Write-Host "Fallback forced reboot scheduled in $hoursMax hours"

# Show the dialog in the user's interactive session via scheduled task
$taskName  = "SyncroRebootPrompt"
$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10)
$trigger.EndBoundary = $null
$principal = New-ScheduledTaskPrincipal -UserId $loggedInUser -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Reboot dialog shown to $loggedInUser"
