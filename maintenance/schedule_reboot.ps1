# schedule_reboot.ps1
# Shows the logged-in user a dialog asking to restart now or in 6 hours.
# Schedules a forced reboot either way - user cannot skip it entirely.
# Runs as SYSTEM via SyncroMSP; uses a scheduled task to show the dialog
# in the user's interactive session.

Import-Module $env:SyncroModule -DisableNameChecking

$hoursUntilReboot = 6
$secondsLater     = $hoursUntilReboot * 3600
$secondsNow       = 60

# Cancel any previously scheduled shutdown
shutdown /a 2>$null

$loggedInUser = (Get-WmiObject Win32_ComputerSystem).UserName

if (-not $loggedInUser) {
    Write-Host "No user logged in - scheduling reboot in $hoursUntilReboot hours without prompt"
    shutdown /r /t $secondsLater /c "Dieser Computer wird in $hoursUntilReboot Stunden fuer Wartung neu gestartet." /f
    exit 0
}

Write-Host "Logged-in user: $loggedInUser"

# Build the dialog script line by line to avoid here-string parsing issues with Invoke-Expression
$msg = "Ihr Computer muss fuer Sicherheitswartungen neu gestartet werden.`n`nJA: Neustart in 1 Minute.`nNEIN: Neustart in $hoursUntilReboot Stunden.`n`nBitte speichern Sie Ihre Arbeit."
$scriptLines = @(
    'Add-Type -AssemblyName System.Windows.Forms',
    ('$result = [System.Windows.Forms.MessageBox]::Show(' +
        '"' + $msg + '",' +
        '"Neustart erforderlich",' +
        '[System.Windows.Forms.MessageBoxButtons]::YesNo,' +
        '[System.Windows.Forms.MessageBoxIcon]::Warning,' +
        '[System.Windows.Forms.MessageBoxDefaultButton]::Button2)'),
    ('if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {'),
    ('    shutdown /r /t ' + $secondsNow + ' /c "Neustart in 1 Minute fuer Wartung. Bitte speichern Sie Ihre Arbeit." /f'),
    ('} else {'),
    ('    shutdown /r /t ' + $secondsLater + ' /c "Dieser Computer wird in ' + $hoursUntilReboot + ' Stunden fuer Wartung neu gestartet. Bitte speichern Sie Ihre Arbeit." /f'),
    ('}')
)

$scriptPath = "C:\Windows\Temp\reboot_prompt.ps1"
$scriptLines | Set-Content -Path $scriptPath -Encoding UTF8 -Force

$taskName  = "SyncroRebootPrompt"
$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10)
$trigger.EndBoundary = $null
$principal = New-ScheduledTaskPrincipal -UserId $loggedInUser -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Reboot prompt sent to $loggedInUser - forced reboot in $hoursUntilReboot hours regardless of choice"
