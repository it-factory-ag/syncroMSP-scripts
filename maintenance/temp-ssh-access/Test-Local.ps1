<#
Local test runner for Enable-TempSSHAccess.ps1 / Disable-TempSSHAccess.ps1
outside of Syncro. Sets $env:SyncroModule to Mock-SyncroModule.psm1 (same
folder) and calls the requested script, so Rmm-Alert / Set-Asset-Field don't
error out.

Usage (elevated PowerShell, from this folder):
  powershell.exe -ExecutionPolicy Bypass -File .\Test-Local.ps1 -Action Enable
  powershell.exe -ExecutionPolicy Bypass -File .\Test-Local.ps1 -Action Enable -DurationMinutes 15
  powershell.exe -ExecutionPolicy Bypass -File .\Test-Local.ps1 -Action Enable -SshPublicKey "ssh-ed25519 AAAA... me@mac"
  powershell.exe -ExecutionPolicy Bypass -File .\Test-Local.ps1 -Action Disable
#>

param(
    [ValidateSet("Enable", "Disable")]
    [string]$Action = "Enable",

    [int]$DurationMinutes = 60,
    [string]$SshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIumFsX1CZcewsvRx2Pov6HDki+BkL9WF+IxelBzE+Cz aaron.akeret@macbook-16-aaak.local"
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:SyncroModule = Join-Path $scriptDir "Mock-SyncroModule.psm1"

if (-not (Test-Path $env:SyncroModule)) {
    Write-Host "ERROR: Mock-SyncroModule.psm1 nicht gefunden unter $($env:SyncroModule)" -ForegroundColor Red
    exit 1
}

if ($Action -eq "Enable") {
    & (Join-Path $scriptDir "Enable-TempSSHAccess.ps1") -DurationMinutes $DurationMinutes -SshPublicKey $SshPublicKey
} else {
    & (Join-Path $scriptDir "Disable-TempSSHAccess.ps1")
}
