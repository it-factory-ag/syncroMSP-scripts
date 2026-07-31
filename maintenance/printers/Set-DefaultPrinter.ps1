<#
Sets the given printer (-PrinterName, exact name as shown in Get-Printer /
"Devices and Printers") as the default printer for the currently logged-in
user. Not intended as a direct SyncroMSP endpoint script - run indirectly via
a thin per-printer syncro_wrapper_set_default_*.ps1 pasted directly into
Syncro (not checked into this repo), which downloads and runs this script
with -PrinterName. This script is the source of truth - keep any such
wrappers in sync if its parameters change.

Must run in the logged-in user's session (Syncro: run as "Logged in user"),
since the default printer is a per-user setting - running as SYSTEM sets it
for the SYSTEM account's session, not the interactive user's.

Uses Win32_Printer's SetDefaultPrinter() CIM method rather than the
WScript.Network COM object, since the latter silently no-ops when there's no
interactive desktop session context (e.g. some non-interactive Syncro
execution modes).
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$PrinterName
)

Import-Module $env:SyncroModule

try {
    Write-Host "=== Set Default Printer: $PrinterName ==="

    $escapedName = $PrinterName -replace "'", "''"
    $printer = Get-CimInstance -ClassName Win32_Printer -Filter "Name='$escapedName'" -ErrorAction Stop

    if (-not $printer) {
        throw "Printer '$PrinterName' was not found. Is it installed on this device?"
    }

    $result = Invoke-CimMethod -InputObject $printer -MethodName SetDefaultPrinter
    if ($result.ReturnValue -ne 0) {
        throw "SetDefaultPrinter failed with return code $($result.ReturnValue)."
    }

    Write-Host "'$PrinterName' is now the default printer."
    Write-Host "=== Done ==="
    exit 0
}
catch {
    Write-Host "ERROR: Failed to set default printer '$PrinterName': $($_.Exception.Message)"
    Rmm-Alert -Category "Set Default Printer" -Body "Failed to set '$PrinterName' as default printer: $($_.Exception.Message)"
    exit 1
}
