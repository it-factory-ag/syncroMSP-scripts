# Kein param()-Block mit Absicht: Syncro schreibt Script Variables als einfache Zuweisungen
# an den Anfang des Scripts, dann steht param() nicht mehr zuoberst und bricht.
# Optionale Syncro-Variable (Dropdown) "Action":
#   Disable = Windows Hello for Business abschalten (keine PIN-/MFA-Einrichtung nach dem Login)
#   Enable  = Richtlinie entfernen, Windows-Standard gilt wieder (bei Entra-Join: aktiv)
if (-not $Action) { $Action = "Disable" }

Import-Module $env:SyncroModule

if ($Action -notin @("Disable", "Enable")) {
    Write-Host "FEHLER: Ungültige Action '$Action' (erlaubt: Disable, Enable)"
    exit 1
}

# Steuert Windows Hello for Business (WHfB) per lokaler Richtlinie auf diesem Gerät.
#
# Hintergrund: Auf Entra-joined Geräten ist WHfB standardmässig aktiv. Nach dem
# Login verlangt Windows eine PIN und die Registrierung einer MFA-Methode, auch
# wenn MFA im Tenant aus ist. Der Dialog lässt sich nicht überspringen. Ohne
# Intune-Lizenz (Entra ID Free) gibt es keine zentrale Richtlinie, daher pro Gerät:
#   Computerkonfiguration > Administrative Vorlagen > Windows-Komponenten >
#     Windows Hello for Business > "Windows Hello for Business verwenden"
#   = HKLM\SOFTWARE\Policies\Microsoft\PassportForWork\Enabled (DWORD)
# Quelle: https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/configure
# Anleitung: https://wiki.prod.itfactory.ch/doc/anleitung-gerate-auf-entra-join-umstellen-mShrrN2FDn
#
# Läuft als SYSTEM. Wirkt ab der nächsten Anmeldung: Ein User, der bereits im
# Einrichtungsdialog hängt, muss sich abmelden (Ctrl+Alt+Del > Abmelden) und neu anmelden.
# Kein lokaler Mock-Test: ein einzelner, sofort umkehrbarer Registry-Wert.

$key = "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork"

Write-Host "=== Windows Hello for Business: $Action ==="

try {
    if ($Action -eq "Disable") {
        if (-not (Test-Path $key)) {
            New-Item -Path $key -Force | Out-Null
        }
        New-ItemProperty -Path $key -Name "Enabled" -Value 0 -PropertyType DWord -Force | Out-Null

        $value = (Get-ItemProperty -Path $key -Name "Enabled" -ErrorAction Stop).Enabled
        if ($value -ne 0) { throw "Enabled ist nach dem Setzen $value statt 0" }
        Write-Host "Gesetzt: $key\Enabled = 0 (WHfB deaktiviert)"
    }
    else {
        if (Test-Path $key) {
            Remove-ItemProperty -Path $key -Name "Enabled" -ErrorAction SilentlyContinue
        }
        if ($null -ne (Get-ItemProperty -Path $key -Name "Enabled" -ErrorAction SilentlyContinue)) {
            throw "Enabled konnte nicht entfernt werden"
        }
        Write-Host "Entfernt: $key\Enabled (Windows-Standard gilt wieder)"
    }
}
catch {
    Write-Host "FEHLER: $($_.Exception.Message)"
    Rmm-Alert -Category "Windows Hello for Business" -Body "Setzen der WHfB-Richtlinie ($Action) fehlgeschlagen: $($_.Exception.Message)"
    exit 1
}

Write-Host ""
Write-Host "Wirkt ab der nächsten Anmeldung. Angemeldete User ab- und wieder anmelden."
exit 0
