<#
Local test runner for Restart-SyncroLiveAgent.ps1 outside of Syncro. Sets
$env:SyncroModule to Mock-SyncroModule.psm1 (same folder) and calls the
script, so Rmm-Alert doesn't error out. The restart itself is real.

Usage (elevated PowerShell, from this folder):
  powershell.exe -ExecutionPolicy Bypass -File .\Test-Local.ps1 -Force 1
  # wait ~4 minutes, then run again without -Force to see the result
#>

param(
    [int]$HandleThreshold = 50000,
    [int]$Force = 0
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:SyncroModule = Join-Path $scriptDir "Mock-SyncroModule.psm1"

if (-not (Test-Path $env:SyncroModule)) {
    Write-Host "ERROR: Mock-SyncroModule.psm1 not found at $($env:SyncroModule)" -ForegroundColor Red
    exit 1
}

& (Join-Path $scriptDir "Restart-SyncroLiveAgent.ps1") -HandleThreshold $HandleThreshold -Force $Force
