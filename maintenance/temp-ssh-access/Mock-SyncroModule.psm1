<#
Local test stand-in for the real SyncroModule that SyncroMSP's agent normally
injects via $env:SyncroModule before running a script. Lets you run
Enable-TempSSHAccess.ps1 / Disable-TempSSHAccess.ps1 directly on a device
without going through Syncro, by faking the handful of cmdlets they call.

Usage (elevated PowerShell):
  $env:SyncroModule = "C:\path\to\Mock-SyncroModule.psm1"
  powershell.exe -ExecutionPolicy Bypass -File .\Enable-TempSSHAccess.ps1

Not used by SyncroMSP itself - local dev/test aid only.
#>

function Rmm-Alert {
    param(
        [string]$Category,
        [string]$Body
    )
    Write-Host "[MOCK Rmm-Alert] Category='$Category' Body='$Body'" -ForegroundColor Yellow
}

function Set-Asset-Field {
    param(
        [string]$Name,
        [string]$Value
    )
    Write-Host "[MOCK Set-Asset-Field] $Name = $Value" -ForegroundColor Yellow
}

Export-ModuleMember -Function Rmm-Alert, Set-Asset-Field
