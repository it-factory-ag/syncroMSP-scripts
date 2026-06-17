# schedule_reboot.ps1
# Shows the logged-in user a dialog asking to restart now or in 6 hours.
# Schedules a forced reboot either way — user cannot skip it entirely.
# Runs as SYSTEM via SyncroMSP; uses a scheduled task to show the dialog
# in the user's interactive session.

Import-Module $env:SyncroModule -DisableNameChecking

$hoursUntilReboot  = 6
$secondsLater      = $hoursUntilReboot * 3600
$secondsNow        = 60   # grace period when user chooses "now"

# Cancel any previously scheduled shutdown
shutdown /a 2>$null

$loggedInUser = (Get-WmiObject Win32_ComputerSystem).UserName

if (-not $loggedInUser) {
    Write-Host "No user logged in - scheduling reboot in $hoursUntilReboot hours without prompt"
    shutdown /r /t $secondsLater /c "This computer will restart in $hoursUntilReboot hours for maintenance." /f
    exit 0
}

Write-Host "Logged-in user: $loggedInUser"

# Script that runs in the user's session and shows the dialog
$dialogScript = @"
Add-Type -AssemblyName System.Windows.Forms
`$result = [System.Windows.Forms.MessageBox]::Show(
    "Your computer needs to restart for security maintenance.``n``nClick YES to restart in 1 minute.``nClick NO to restart in $hoursUntilReboot hours.``n``nPlease save your work either way.",
    "Restart Required",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning,
    [System.Windows.Forms.MessageBoxDefaultButton]::Button2
)
if (`$result -eq [System.Windows.Forms.DialogResult]::Yes) {
    shutdown /r /t $secondsNow /c "Restarting in 1 minute for maintenance. Please save your work." /f
} else {
    shutdown /r /t $secondsLater /c "This computer will restart in $hoursUntilReboot hours for maintenance. Please save your work." /f
}
"@

$scriptPath = "C:\Windows\Temp\reboot_prompt.ps1"
$dialogScript | Out-File -FilePath $scriptPath -Encoding UTF8 -Force

$taskName = "SyncroRebootPrompt"
$action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
$trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10)
$principal = New-ScheduledTaskPrincipal -UserId $loggedInUser -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -DeleteExpiredTaskAfter (New-TimeSpan -Minutes 10)

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Reboot prompt scheduled for $loggedInUser — reboot will be forced in $hoursUntilReboot hours regardless of choice"
