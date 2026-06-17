Import-Module $env:SyncroModule -DisableNameChecking

function Write-Section($title) {
    Write-Host ""
    Write-Host "=== $title ==="
}

# --- System & BIOS ---
Write-Section "System & BIOS"
$cs   = Get-WmiObject Win32_ComputerSystem
$bios = Get-WmiObject Win32_BIOS
Write-Host "Manufacturer:    $($cs.Manufacturer)"
Write-Host "Model:           $($cs.Model)"
Write-Host "BIOS Version:    $($bios.SMBIOSBIOSVersion)"
Write-Host "BIOS Date:       $([Management.ManagementDateTimeConverter]::ToDateTime($bios.ReleaseDate).ToString('yyyy-MM-dd'))"
Write-Host "BIOS Serial:     $($bios.SerialNumber)"

# --- Secure Boot ---
Write-Section "Secure Boot"
try {
    $sb = Confirm-SecureBootUEFI
    Write-Host "Secure Boot:     $($sb)"
} catch [System.PlatformNotSupportedException] {
    Write-Host "Secure Boot:     Not supported (Legacy BIOS)"
} catch {
    Write-Host "Secure Boot:     Unknown - $($_.Exception.Message)"
}

# --- Secure Boot 2023 cert enrollment status ---
Write-Section "Secure Boot 2023 Cert Enrollment"
$servicing = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing' -ErrorAction SilentlyContinue
$updates   = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Secureboot' -ErrorAction SilentlyContinue
Write-Host "UEFICA2023Status:      $($servicing.UEFICA2023Status)"
Write-Host "AvailableUpdates:      $($updates.AvailableUpdates) (0x5944 = full update pending, 0x4000 = done)"
Write-Host "WindowsUEFICA2023:     $($servicing.WindowsUEFICA2023Capable) (0=not in DB, 1=in DB, 2=booting from 2023 chain)"

# --- Secure Boot KEK certs ---
Write-Section "KEK Certificates"
try {
    $kekVar = Get-SecureBootUEFI KEK -ErrorAction Stop
    $x509Guid = [System.Guid]::new("a5c059a1-94e4-4aa7-87b5-ab155c2bf072")
    $bytes = $kekVar.Bytes; $offset = 0
    while ($offset + 28 -le $bytes.Length) {
        $listStart = $offset
        $sigTypeGuid = [System.Guid]::new([byte[]]$bytes[$offset..($offset+15)]); $offset += 16
        $listSize    = [BitConverter]::ToUInt32($bytes, $offset); $offset += 4
        $headerSize  = [BitConverter]::ToUInt32($bytes, $offset); $offset += 4
        $sigSize     = [BitConverter]::ToUInt32($bytes, $offset); $offset += 4
        if ($listSize -lt 28 -or ($listStart + $listSize) -gt $bytes.Length) { break }
        $offset += $headerSize
        if ($sigTypeGuid -eq $x509Guid -and $sigSize -gt 16) {
            $numSigs = [Math]::Floor(($listSize - 28 - $headerSize) / $sigSize)
            for ($s = 0; $s -lt $numSigs; $s++) {
                $certOffset = $offset + ($s * $sigSize) + 16
                $certSize   = $sigSize - 16
                if ($certOffset + $certSize -gt $bytes.Length) { break }
                try {
                    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([byte[]]$bytes[$certOffset..($certOffset+$certSize-1)])
                    Write-Host "  Subject:    $($cert.Subject)"
                    Write-Host "  Thumbprint: $($cert.Thumbprint)"
                    Write-Host "  Expires:    $($cert.NotAfter.ToString('yyyy-MM-dd'))"
                    Write-Host ""
                } catch {}
            }
        }
        $offset = $listStart + $listSize
    }
} catch { Write-Host "  Could not read KEK: $($_.Exception.Message)" }

# --- Secure Boot DB certs ---
Write-Section "DB Certificates"
try {
    $dbVar = Get-SecureBootUEFI db -ErrorAction Stop
    $x509Guid = [System.Guid]::new("a5c059a1-94e4-4aa7-87b5-ab155c2bf072")
    $bytes = $dbVar.Bytes; $offset = 0
    while ($offset + 28 -le $bytes.Length) {
        $listStart = $offset
        $sigTypeGuid = [System.Guid]::new([byte[]]$bytes[$offset..($offset+15)]); $offset += 16
        $listSize    = [BitConverter]::ToUInt32($bytes, $offset); $offset += 4
        $headerSize  = [BitConverter]::ToUInt32($bytes, $offset); $offset += 4
        $sigSize     = [BitConverter]::ToUInt32($bytes, $offset); $offset += 4
        if ($listSize -lt 28 -or ($listStart + $listSize) -gt $bytes.Length) { break }
        $offset += $headerSize
        if ($sigTypeGuid -eq $x509Guid -and $sigSize -gt 16) {
            $numSigs = [Math]::Floor(($listSize - 28 - $headerSize) / $sigSize)
            for ($s = 0; $s -lt $numSigs; $s++) {
                $certOffset = $offset + ($s * $sigSize) + 16
                $certSize   = $sigSize - 16
                if ($certOffset + $certSize -gt $bytes.Length) { break }
                try {
                    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([byte[]]$bytes[$certOffset..($certOffset+$certSize-1)])
                    Write-Host "  Subject:    $($cert.Subject)"
                    Write-Host "  Thumbprint: $($cert.Thumbprint)"
                    Write-Host "  Expires:    $($cert.NotAfter.ToString('yyyy-MM-dd'))"
                    Write-Host ""
                } catch {}
            }
        }
        $offset = $listStart + $listSize
    }
} catch { Write-Host "  Could not read DB: $($_.Exception.Message)" }

# --- HP Sure Start ---
$isHP = $cs.Manufacturer -match "HP|Hewlett"
if ($isHP) {
    Write-Section "HP Sure Start / BIOS Settings"
    try {
        $hpSettings = Get-WmiObject -Namespace root\HP\InstrumentedBIOS -Class HP_BIOSSetting -ErrorAction Stop
        $relevant = $hpSettings | Where-Object { $_.Name -match "Sure.?Start|Secure.Boot|TPM|UEFI" }
        foreach ($s in $relevant) {
            Write-Host "  $($s.Name) = $($s.Value)"
        }
    } catch {
        Write-Host "  HP BIOS WMI not available: $($_.Exception.Message)"
    }
}

# --- TPM ---
Write-Section "TPM"
try {
    $tpm = Get-WmiObject -Namespace root\CIMv2\Security\MicrosoftTpm -Class Win32_Tpm -ErrorAction Stop
    Write-Host "TPM Present:     $($tpm.IsEnabled_InitialValue)"
    Write-Host "TPM Activated:   $($tpm.IsActivated_InitialValue)"
    Write-Host "Spec Version:    $($tpm.SpecVersion)"
} catch {
    Write-Host "TPM info not available: $($_.Exception.Message)"
}

# --- SecureBoot Update Event Log ---
Write-Section "Recent SecureBoot-Update Events (last 10)"
try {
    $events = Get-WinEvent -LogName "Microsoft-Windows-SecureBoot-Update/Operational" -MaxEvents 10 -ErrorAction Stop
    foreach ($e in $events) {
        Write-Host "  [$($e.TimeCreated.ToString('yyyy-MM-dd HH:mm'))] ID $($e.Id): $($e.Message -replace '\s+', ' ')"
    }
} catch {
    Write-Host "  No SecureBoot-Update events found or log not accessible"
}

Write-Host ""
Write-Host "=== Done ==="
