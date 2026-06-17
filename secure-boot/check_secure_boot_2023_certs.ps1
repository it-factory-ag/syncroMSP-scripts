Import-Module $env:SyncroModule

# Custom asset fields (must be created in Admin --> Custom Asset Fields)
$fieldSecureBoot = "Secure Boot Enabled"
$fieldKEK2023    = "Secure Boot KEK 2023"
$fieldDB2023     = "Secure Boot DB 2023"

# Parses an EFI Signature Database variable and returns all X.509 certificates found in it.
function Get-EfiDbCerts {
    param([string]$VarName)

    try {
        $efiVar = Get-SecureBootUEFI $VarName -ErrorAction Stop
        $bytes = $efiVar.Bytes
    } catch {
        Write-Host "WARNING: Could not read EFI variable '$VarName': $($_.Exception.Message)"
        return @()
    }

    # EFI GUID for X.509 certificate signature type
    $x509Guid = [System.Guid]::new("a5c059a1-94e4-4aa7-87b5-ab155c2bf072")

    $certs  = [System.Collections.Generic.List[object]]::new()
    $offset = 0

    while ($offset + 28 -le $bytes.Length) {
        $listStart = $offset

        # Read EFI_SIGNATURE_LIST header (28 bytes total)
        $sigTypeGuid = [System.Guid]::new([byte[]]$bytes[$offset..($offset + 15)]); $offset += 16
        $listSize    = [BitConverter]::ToUInt32($bytes, $offset); $offset += 4
        $headerSize  = [BitConverter]::ToUInt32($bytes, $offset); $offset += 4
        $sigSize     = [BitConverter]::ToUInt32($bytes, $offset); $offset += 4

        if ($listSize -lt 28 -or ($listStart + $listSize) -gt $bytes.Length) { break }

        $offset += $headerSize  # skip optional SignatureHeader

        if ($sigTypeGuid -eq $x509Guid -and $sigSize -gt 16) {
            $numSigs = [Math]::Floor(($listSize - 28 - $headerSize) / $sigSize)

            for ($s = 0; $s -lt $numSigs; $s++) {
                # Each EFI_SIGNATURE_DATA = 16-byte owner GUID + certificate bytes
                $certOffset = $offset + ($s * $sigSize) + 16
                $certSize   = $sigSize - 16
                if ($certOffset + $certSize -gt $bytes.Length) { break }

                $certBytes = [byte[]]$bytes[$certOffset..($certOffset + $certSize - 1)]
                try {
                    $certs.Add([System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes))
                } catch {}
            }
        }

        $offset = $listStart + $listSize
    }

    return $certs.ToArray()
}

# Known 2023 certificate thumbprints (confirmed from live systems)
# KEK: Microsoft Corporation KEK CA 2023 - thumbprint not yet confirmed, matched by subject
# DB:  Windows UEFI CA 2023              - 45A0FA32604773C82433C3B7D59E7466B3AC0C67
#      Microsoft UEFI CA 2023            - B5EEB4A6706048073F0ED296E7F580A790B59EAA
#      Microsoft Option ROM UEFI CA 2023 - 3FB39E2B8BD183BF9E4594E72183CA60AFCD4277
$knownDb2023Thumbprints = @(
    "45A0FA32604773C82433C3B7D59E7466B3AC0C67",  # Windows UEFI CA 2023
    "B5EEB4A6706048073F0ED296E7F580A790B59EAA",  # Microsoft UEFI CA 2023
    "3FB39E2B8BD183BF9E4594E72183CA60AFCD4277"   # Microsoft Option ROM UEFI CA 2023
)

function Test-Has2023Cert {
    param(
        [System.Security.Cryptography.X509Certificates.X509Certificate2[]]$Certs,
        [string[]]$KnownThumbprints = @()
    )
    # Match by known thumbprint first, fall back to subject name containing "2023"
    foreach ($cert in $Certs) {
        if ($KnownThumbprints -contains $cert.Thumbprint) { return $true }
        if ($cert.Subject -match "2023") { return $true }
    }
    return $false
}

# --- Check 1: Secure Boot status ---

try {
    $secureBootEnabled = Confirm-SecureBootUEFI
} catch [System.PlatformNotSupportedException] {
    Write-Host "INFO: Legacy BIOS system - Secure Boot is not supported on this hardware"
    Set-Asset-Field -Name $fieldSecureBoot -Value "Not supported (Legacy BIOS)"
    exit 0
} catch {
    Write-Host "WARNING: Could not determine Secure Boot status: $($_.Exception.Message)"
    Set-Asset-Field -Name $fieldSecureBoot -Value "Unknown"
    exit 0
}

if (-not $secureBootEnabled) {
    Write-Host "Secure Boot is DISABLED in UEFI firmware"
    Set-Asset-Field -Name $fieldSecureBoot -Value "Disabled"
    Set-Asset-Field -Name $fieldKEK2023 -Value "N/A"
    Set-Asset-Field -Name $fieldDB2023  -Value "N/A"
    exit 0
}

Set-Asset-Field -Name $fieldSecureBoot -Value "Enabled"
Write-Host "OK: Secure Boot is enabled"

# --- Check 2: KEK contains a 2023 certificate ---

$kekCerts   = Get-EfiDbCerts -VarName "KEK"
$kekHas2023 = Test-Has2023Cert -Certs $kekCerts  # KEK 2023 thumbprint not yet confirmed - subject match only

Write-Host ""
Write-Host "KEK certificates found ($($kekCerts.Count)):"
foreach ($cert in $kekCerts) {
    Write-Host "  Subject:  $($cert.Subject)"
    Write-Host "  Issuer:   $($cert.Issuer)"
    Write-Host "  Expires:  $($cert.NotAfter)"
    Write-Host "  Thumbprint: $($cert.Thumbprint)"
    Write-Host ""
}

if ($kekHas2023) {
    Set-Asset-Field -Name $fieldKEK2023 -Value "Yes"
    Write-Host "OK: KEK contains a 2023 certificate"
} else {
    Set-Asset-Field -Name $fieldKEK2023 -Value "No"
    Write-Host "ALERT: KEK does NOT contain a 2023 certificate - expires June 2026"
}

# --- Check 3: DB contains a 2023 certificate ---

$dbCerts   = Get-EfiDbCerts -VarName "db"
$dbHas2023 = Test-Has2023Cert -Certs $dbCerts -KnownThumbprints $knownDb2023Thumbprints

Write-Host ""
Write-Host "DB certificates found ($($dbCerts.Count)):"
foreach ($cert in $dbCerts) {
    Write-Host "  Subject:  $($cert.Subject)"
    Write-Host "  Issuer:   $($cert.Issuer)"
    Write-Host "  Expires:  $($cert.NotAfter)"
    Write-Host "  Thumbprint: $($cert.Thumbprint)"
    Write-Host ""
}

if ($dbHas2023) {
    Set-Asset-Field -Name $fieldDB2023 -Value "Yes"
    Write-Host "OK: DB contains a 2023 certificate"
} else {
    Set-Asset-Field -Name $fieldDB2023 -Value "No"
    Write-Host "ALERT: DB does NOT contain a 2023 certificate - expires October 2026"
}

exit 0
