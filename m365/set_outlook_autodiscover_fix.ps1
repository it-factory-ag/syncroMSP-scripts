# Kein param()-Block mit Absicht: Syncro schreibt Script Variables als einfache Zuweisungen
# an den Anfang des Scripts, dann steht param() nicht mehr zuoberst und bricht.
# Optionale Syncro-Variable (Dropdown) "Action":
#   Apply  = Autodiscover-Fix setzen (ExcludeExplicitO365Endpoint = 1, AlwaysUseMSOAuthForAutoDiscover = 0)
#   Remove = beide Werte entfernen, Outlook-Standard gilt wieder
if (-not $Action) { $Action = "Apply" }

Import-Module $env:SyncroModule

if ($Action -notin @("Apply", "Remove")) {
    Write-Host "FEHLER: Ungültige Action '$Action' (erlaubt: Apply, Remove)"
    exit 1
}

# Outlook Autodiscover-Fix für den angemeldeten User (HKCU):
#   HKCU\Software\Microsoft\Office\16.0\Outlook\AutoDiscover\ExcludeExplicitO365Endpoint = 1
#     Outlook fragt nicht zuerst direkt den Microsoft-365-Endpoint ab, sondern
#     macht den normalen Autodiscover-Ablauf (z.B. für On-Prem-/Hosted-Exchange).
#   HKCU\Software\Microsoft\Exchange\AlwaysUseMSOAuthForAutoDiscover = 0
#
# Muss als angemeldeter User laufen (Syncro: Run As "Logged in User"), als SYSTEM
# würde das Script nur die Registry von SYSTEM ändern. Wirkt nach Outlook-Neustart.
# Kein lokaler Mock-Test: zwei einzelne, sofort umkehrbare Registry-Werte.

if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
    Write-Host "FEHLER: Script läuft als SYSTEM. In Syncro Run As 'Logged in User' wählen."
    exit 1
}

$values = @(
    @{ Key = "HKCU:\Software\Microsoft\Office\16.0\Outlook\AutoDiscover"; Name = "ExcludeExplicitO365Endpoint"; Value = 1 },
    @{ Key = "HKCU:\Software\Microsoft\Exchange"; Name = "AlwaysUseMSOAuthForAutoDiscover"; Value = 0 }
)

Write-Host "=== Outlook Autodiscover-Fix: $Action (User: $env:USERNAME) ==="

try {
    foreach ($v in $values) {
        if ($Action -eq "Apply") {
            if (-not (Test-Path $v.Key)) {
                New-Item -Path $v.Key -Force | Out-Null
            }
            New-ItemProperty -Path $v.Key -Name $v.Name -Value $v.Value -PropertyType DWord -Force | Out-Null

            $current = (Get-ItemProperty -Path $v.Key -Name $v.Name -ErrorAction Stop).($v.Name)
            if ($current -ne $v.Value) { throw "$($v.Name) ist nach dem Setzen $current statt $($v.Value)" }
            Write-Host "Gesetzt: $($v.Key)\$($v.Name) = $($v.Value)"
        }
        else {
            if (Test-Path $v.Key) {
                Remove-ItemProperty -Path $v.Key -Name $v.Name -ErrorAction SilentlyContinue
            }
            if ($null -ne (Get-ItemProperty -Path $v.Key -Name $v.Name -ErrorAction SilentlyContinue)) {
                throw "$($v.Name) konnte nicht entfernt werden"
            }
            Write-Host "Entfernt: $($v.Key)\$($v.Name)"
        }
    }
}
catch {
    Write-Host "FEHLER: $($_.Exception.Message)"
    Rmm-Alert -Category "Outlook Autodiscover" -Body "Outlook Autodiscover-Fix ($Action) für $env:USERNAME fehlgeschlagen: $($_.Exception.Message)"
    exit 1
}

Write-Host ""
Write-Host "Outlook neu starten, damit die Änderung greift."
exit 0
