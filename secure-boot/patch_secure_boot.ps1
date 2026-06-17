Import-Module $env:SyncroModule -DisableNameChecking

# Set registry flag telling Windows to enroll the 2023 Secure Boot certs on next task run
$regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Secureboot'
Set-ItemProperty -Path $regPath -Name 'AvailableUpdates' -Value 0x5944 -Type DWord -Force
Write-Host "Registry flag set (AvailableUpdates = 0x5944)"

# Trigger the built-in Windows Secure Boot cert update task
$taskName = '\Microsoft\Windows\PI\Secure-Boot-Update'
try {
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Write-Host "Scheduled task '$taskName' triggered - reboot may be required to complete enrollment"
} catch {
    Write-Host "ERROR: Failed to start scheduled task: $($_.Exception.Message)"
    exit 1
}
