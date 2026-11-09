<#
Local test runner for Restart-ExplorerSessions.ps1 outside of Syncro. Sets
$env:SyncroModule to Mock-SyncroModule.psm1 (same folder) and calls the
script, so Rmm-Alert doesn't error out. The restart itself is real.

Usage (elevated PowerShell as SYSTEM, e.g. psexec -s, from this folder):
  powershell.exe -ExecutionPolicy Bypass -File .\Test-Local.ps1 -Users testuser
#>

param(
    [string]$Users = "",
    [int]$WaitSeconds = 20
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:SyncroModule = Join-Path $scriptDir "Mock-SyncroModule.psm1"

if (-not (Test-Path $env:SyncroModule)) {
    Write-Host "ERROR: Mock-SyncroModule.psm1 not found at $($env:SyncroModule)" -ForegroundColor Red
    exit 1
}

& (Join-Path $scriptDir "Restart-ExplorerSessions.ps1") -Users $Users -WaitSeconds $WaitSeconds
