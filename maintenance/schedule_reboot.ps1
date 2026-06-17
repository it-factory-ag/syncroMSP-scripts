# schedule_reboot.ps1
# Schedules a forced reboot in 6 hours and notifies the logged-in user.
# Any previously scheduled shutdown is cancelled and replaced.

Import-Module $env:SyncroModule -DisableNameChecking

$hoursUntilReboot = 6
$secondsUntilReboot = $hoursUntilReboot * 3600

$userMessage = @"
Your computer will automatically restart in $hoursUntilReboot hours for maintenance (security updates).

Please save your work before then.
"@

$shutdownMessage = "This computer will restart in $hoursUntilReboot hours for maintenance (security updates). Please save your work."

# Cancel any previously scheduled shutdown
shutdown /a 2>$null

# Notify the logged-in user immediately with a popup
$loggedInUser = (Get-WmiObject Win32_ComputerSystem).UserName
if ($loggedInUser) {
    msg * $userMessage
    Write-Host "Notification sent to: $loggedInUser"
} else {
    Write-Host "No user currently logged in - skipping popup notification"
}

# Schedule the forced reboot
shutdown /r /t $secondsUntilReboot /c $shutdownMessage /f
Write-Host "Reboot scheduled in $hoursUntilReboot hours"
