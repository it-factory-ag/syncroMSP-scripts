# device_health.ps1
# Combined read-only health and inventory collection script.
# Runs all sections regardless of failures and never exits 1.
# Schedule this script to run regularly to keep asset fields up to date.
# Note: the Antivirus section can raise an Rmm-Alert (category
# "av_out_of_date") if definitions are stale or real-time protection is
# disabled — currently commented out until enabled.
#
# Custom asset fields required (Admin --> Custom Asset Fields):
#
#   Field                     Type    Values
#   ─────────────────────────────────────────────────────────────────────────
#   Virtual Machine           Text    VMware, Hyper-V, VirtualBox, QEMU/KVM,
#                                     Xen, Parallels, No
#   Secure Boot Enabled       Text    Enabled, Disabled,
#                                     Not supported (Legacy BIOS), Unknown
#   Secure Boot KEK 2023      Text    Yes, No, N/A
#   Secure Boot DB 2023       Text    Yes, No, N/A
#   Last succesful WUConnection Text  yyyy-MM-dd HH:mm:ss, or Never
#   Bitlocker_active          Text    Yes, No
#   Bitlocker_Key_C           Text    Recovery key
#   Bitlocker_Key_D           Text    Recovery key
#   Bitlocker_Key_E           Text    Recovery key
#   OS Version                Text    e.g. "Microsoft Windows 11 Pro 64-bit"
#   OS Build                  Text    e.g. "23H2, Build 22631.3737"
#   AV Name                   Text    Antivirus product display name
#   AV Definition Status      Text    Up to date, Out of date, Unknown
#   AV Realtime Status        Text    Enabled, Disabled, Unknown

Import-Module $env:SyncroModule -DisableNameChecking

function Write-Section($title) {
    Write-Host ""
    Write-Host "=== $title ==="
}

# Parses an EFI Signature Database variable and returns all X.509 certificates found in it.
function Get-EfiDbCerts {
    param([string]$VarName)
    try {
        $efiVar = Get-SecureBootUEFI $VarName -ErrorAction Stop
        $bytes  = $efiVar.Bytes
    } catch {
        Write-Host "  WARNING: Could not read EFI variable '$VarName': $($_.Exception.Message)"
        return @()
    }
    $x509Guid = [System.Guid]::new("a5c059a1-94e4-4aa7-87b5-ab155c2bf072")
    $certs = [System.Collections.Generic.List[object]]::new()
    $offset = 0
    while ($offset + 28 -le $bytes.Length) {
        $listStart    = $offset
        $sigTypeGuid  = [System.Guid]::new([byte[]]$bytes[$offset..($offset+15)]); $offset += 16
        $listSize     = [BitConverter]::ToUInt32($bytes, $offset); $offset += 4
        $headerSize   = [BitConverter]::ToUInt32($bytes, $offset); $offset += 4
        $sigSize      = [BitConverter]::ToUInt32($bytes, $offset); $offset += 4
        if ($listSize -lt 28 -or ($listStart + $listSize) -gt $bytes.Length) { break }
        $offset += $headerSize
        if ($sigTypeGuid -eq $x509Guid -and $sigSize -gt 16) {
            $numSigs = [Math]::Floor(($listSize - 28 - $headerSize) / $sigSize)
            for ($s = 0; $s -lt $numSigs; $s++) {
                $certOffset = $offset + ($s * $sigSize) + 16
                $certSize   = $sigSize - 16
                if ($certOffset + $certSize -gt $bytes.Length) { break }
                try { $certs.Add([System.Security.Cryptography.X509Certificates.X509Certificate2]::new([byte[]]$bytes[$certOffset..($certOffset+$certSize-1)])) } catch {}
            }
        }
        $offset = $listStart + $listSize
    }
    return $certs.ToArray()
}

function Test-Has2023Cert {
    param(
        [System.Security.Cryptography.X509Certificates.X509Certificate2[]]$Certs,
        [string[]]$KnownThumbprints = @()
    )
    foreach ($cert in $Certs) {
        if ($KnownThumbprints -contains $cert.Thumbprint) { return $true }
        if ($cert.Subject -match "2023") { return $true }
    }
    return $false
}

$knownDb2023Thumbprints = @(
    "45A0FA32604773C82433C3B7D59E7466B3AC0C67",  # Windows UEFI CA 2023
    "B5EEB4A6706048073F0ED296E7F580A790B59EAA",  # Microsoft UEFI CA 2023
    "3FB39E2B8BD183BF9E4594E72183CA60AFCD4277"   # Microsoft Option ROM UEFI CA 2023
)

# ─── System & BIOS ────────────────────────────────────────────────────────────

Write-Section "System & BIOS"
$cs   = Get-WmiObject Win32_ComputerSystem
$bios = Get-WmiObject Win32_BIOS
Write-Host "Manufacturer:  $($cs.Manufacturer)"
Write-Host "Model:         $($cs.Model)"
Write-Host "Serial:        $($bios.SerialNumber)"
Write-Host "BIOS Version:  $($bios.SMBIOSBIOSVersion)"
Write-Host "BIOS Date:     $([Management.ManagementDateTimeConverter]::ToDateTime($bios.ReleaseDate).ToString('yyyy-MM-dd'))"

# ─── OS Version ───────────────────────────────────────────────────────────────

Write-Section "OS Version"
$osInfo    = Get-WmiObject Win32_OperatingSystem
$osName    = $osInfo.Caption
$osBit     = $osInfo.OSArchitecture
$osVersion = "$osName $osBit"
Set-Asset-Field -Name "OS Version" -Value $osVersion
Write-Host "OS Version:    $osVersion"

$osReg     = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\'
$osBuild   = "$($osReg.DisplayVersion), Build $($osReg.CurrentBuildNumber).$($osReg.UBR)"
Set-Asset-Field -Name "OS Build" -Value $osBuild
Write-Host "OS Build:      $osBuild"

# ─── Virtual Machine ──────────────────────────────────────────────────────────

Write-Section "Virtual Machine"
$manufacturer = $cs.Manufacturer
$model        = $cs.Model
$biosVersion  = $bios.SMBIOSBIOSVersion
$hypervisor   = $null

if     ($manufacturer -match "VMware")                                   { $hypervisor = "VMware" }
elseif ($manufacturer -match "Microsoft" -and $model -match "Virtual")   { $hypervisor = "Hyper-V" }
elseif ($manufacturer -match "innotek|Oracle" -or $model -match "VirtualBox") { $hypervisor = "VirtualBox" }
elseif ($manufacturer -match "QEMU" -or $biosVersion -match "QEMU")      { $hypervisor = "QEMU/KVM" }
elseif ($model -match "HVM domU" -or $biosVersion -match "Xen")          { $hypervisor = "Xen" }
elseif ($manufacturer -match "Parallels" -or $model -match "Parallels")  { $hypervisor = "Parallels" }

if ($hypervisor) {
    Set-Asset-Field -Name "Virtual Machine" -Value $hypervisor
    Write-Host "Virtual device: $hypervisor"
} else {
    Set-Asset-Field -Name "Virtual Machine" -Value "No"
    Write-Host "Physical device"
}

# ─── TPM ──────────────────────────────────────────────────────────────────────

Write-Section "TPM"
try {
    $tpm = Get-WmiObject -Namespace root\CIMv2\Security\MicrosoftTpm -Class Win32_Tpm -ErrorAction Stop
    Write-Host "Present:       $($tpm.IsEnabled_InitialValue)"
    Write-Host "Activated:     $($tpm.IsActivated_InitialValue)"
    Write-Host "Spec Version:  $($tpm.SpecVersion)"
} catch {
    Write-Host "TPM info not available: $($_.Exception.Message)"
}

# ─── Secure Boot ──────────────────────────────────────────────────────────────

Write-Section "Secure Boot"
try {
    $secureBootEnabled = Confirm-SecureBootUEFI
} catch [System.PlatformNotSupportedException] {
    Write-Host "Not supported (Legacy BIOS)"
    Set-Asset-Field -Name "Secure Boot Enabled" -Value "Not supported (Legacy BIOS)"
    Set-Asset-Field -Name "Secure Boot KEK 2023" -Value "N/A"
    Set-Asset-Field -Name "Secure Boot DB 2023"  -Value "N/A"
    $secureBootEnabled = $null
} catch {
    Write-Host "Unknown: $($_.Exception.Message)"
    Set-Asset-Field -Name "Secure Boot Enabled" -Value "Unknown"
    $secureBootEnabled = $null
}

if ($null -ne $secureBootEnabled) {
    if ($secureBootEnabled) {
        Write-Host "Secure Boot: Enabled"
        Set-Asset-Field -Name "Secure Boot Enabled" -Value "Enabled"

        $kekCerts   = Get-EfiDbCerts -VarName "KEK"
        $kekHas2023 = Test-Has2023Cert -Certs $kekCerts
        Write-Host "KEK certificates ($($kekCerts.Count)):"
        foreach ($cert in $kekCerts) {
            Write-Host "  $($cert.Subject) | Expires: $($cert.NotAfter.ToString('yyyy-MM-dd')) | $($cert.Thumbprint)"
        }
        Set-Asset-Field -Name "Secure Boot KEK 2023" -Value $(if ($kekHas2023) { "Yes" } else { "No" })
        Write-Host "KEK 2023: $(if ($kekHas2023) { 'Yes' } else { 'No - expires June 2026' })"

        $dbCerts   = Get-EfiDbCerts -VarName "db"
        $dbHas2023 = Test-Has2023Cert -Certs $dbCerts -KnownThumbprints $knownDb2023Thumbprints
        Write-Host "DB certificates ($($dbCerts.Count)):"
        foreach ($cert in $dbCerts) {
            Write-Host "  $($cert.Subject) | Expires: $($cert.NotAfter.ToString('yyyy-MM-dd')) | $($cert.Thumbprint)"
        }
        Set-Asset-Field -Name "Secure Boot DB 2023" -Value $(if ($dbHas2023) { "Yes" } else { "No" })
        Write-Host "DB 2023: $(if ($dbHas2023) { 'Yes' } else { 'No - expires October 2026' })"
    } else {
        Write-Host "Secure Boot: Disabled"
        Set-Asset-Field -Name "Secure Boot Enabled" -Value "Disabled"
        Set-Asset-Field -Name "Secure Boot KEK 2023" -Value "N/A"
        Set-Asset-Field -Name "Secure Boot DB 2023"  -Value "N/A"
    }
}

# ─── HP Sure Start ────────────────────────────────────────────────────────────

if ($cs.Manufacturer -match "HP|Hewlett") {
    Write-Section "HP Sure Start"
    try {
        Get-WmiObject -Namespace root\HP\InstrumentedBIOS -Class HP_BIOSSetting -ErrorAction Stop |
            Where-Object { $_.Name -match "Sure.?Start|SureStart" } |
            ForEach-Object { Write-Host "  $($_.Name) = $($_.Value)" }
    } catch {
        Write-Host "  HP BIOS WMI not available: $($_.Exception.Message)"
    }
}

# ─── Windows Update ───────────────────────────────────────────────────────────

Write-Section "Windows Update"
try {
    $lastSearch = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results.LastSearchSuccessDate
    if ($null -eq $lastSearch) {
        Write-Host "Never successfully searched"
        Set-Asset-Field -Name "Last succesful WUConnection" -Value "Never"
    } else {
        $formatted  = $lastSearch.ToString("yyyy-MM-dd HH:mm:ss")
        $daysSince  = ((Get-Date) - $lastSearch).Days
        Set-Asset-Field -Name "Last succesful WUConnection" -Value $formatted
        Write-Host "Last successful search: $formatted ($daysSince days ago)"
    }
} catch {
    Write-Host "Could not read Windows Update status: $($_.Exception.Message)"
}

# ─── BitLocker ────────────────────────────────────────────────────────────────

Write-Section "BitLocker"
$blStatus = (Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue).ProtectionStatus
Set-Asset-Field -Name "Bitlocker_active" -Value $(if ($blStatus -eq "On") { "Yes" } else { "No" })
Write-Host "C: Protection: $blStatus"

foreach ($drive in @('C', 'D', 'E')) {
    $vol = Get-BitLockerVolume -MountPoint "${drive}:" -ErrorAction SilentlyContinue
    if ($vol) {
        $key = ($vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1).RecoveryPassword
        Set-Asset-Field -Name "Bitlocker_Key_$drive" -Value $key
        Write-Host "${drive}: Key: $(if ($key) { $key } else { 'None' })"
    }
}

# ─── Antivirus ────────────────────────────────────────────────────────────────

Write-Section "Antivirus"
try {
    $avProducts = @(Get-WmiObject -Namespace root\SecurityCenter2 -Class AntiVirusProduct -ErrorAction Stop)

    # Windows Defender commonly stays registered (in passive mode) alongside
    # real third-party AVs, so exclude it whenever another product is present.
    $relevant = @($avProducts | Where-Object { $_.displayName -notmatch 'Windows Defender' })
    if ($relevant.Count -eq 0) { $relevant = $avProducts }

    if ($relevant.Count -eq 0) {
        Write-Host "No antivirus product registered with Security Center"
        Set-Asset-Field -Name "AV Name" -Value "None"
        Set-Asset-Field -Name "AV Definition Status" -Value "Unknown"
        Set-Asset-Field -Name "AV Realtime Status" -Value "Unknown"
        # Rmm-Alert -Category "av_out_of_date" -Body "No antivirus product registered with Security Center"
    } else {
        # productState codes below are the known/observed values for Windows
        # Security Center; anything else falls through to "Unknown".
        $results = foreach ($p in $relevant) {
            $code = ($p.productState -split ', ')[0]
            switch ($code) {
                "262144" { $def = "Up to date";  $rt = "Disabled" }
                "262160" { $def = "Out of date"; $rt = "Disabled" }
                "266240" { $def = "Up to date";  $rt = "Enabled" }
                "266256" { $def = "Out of date"; $rt = "Enabled" }
                "393216" { $def = "Up to date";  $rt = "Disabled" }
                "393232" { $def = "Out of date"; $rt = "Disabled" }
                "393488" { $def = "Out of date"; $rt = "Disabled" }
                "397312" { $def = "Up to date";  $rt = "Enabled" }
                "397328" { $def = "Out of date"; $rt = "Enabled" }
                "397584" { $def = "Out of date"; $rt = "Enabled" }
                "331776" { $def = "Up to date";  $rt = "Enabled" }
                default  { $def = "Unknown";      $rt = "Unknown" }
            }
            Write-Host "Product:             $($p.displayName)"
            Write-Host "Definition Status:   $def"
            Write-Host "Realtime Status:     $rt"
            Write-Host "Product State code:  $($p.productState)"
            [PSCustomObject]@{ Name = $p.displayName; Definition = $def; Realtime = $rt }
        }

        # Report the worst-case status across all products so a single stale
        # or disabled AV isn't masked by a healthy one.
        $avName    = ($results.Name -join '; ')
        $defStatus = if ($results.Definition -contains "Out of date") { "Out of date" }
                     elseif ($results.Definition -contains "Unknown") { "Unknown" }
                     else { "Up to date" }
        $rtStatus  = if ($results.Realtime -contains "Disabled") { "Disabled" }
                     elseif ($results.Realtime -contains "Unknown") { "Unknown" }
                     else { "Enabled" }

        Set-Asset-Field -Name "AV Name" -Value $avName
        Set-Asset-Field -Name "AV Definition Status" -Value $defStatus
        Set-Asset-Field -Name "AV Realtime Status" -Value $rtStatus

        if ($defStatus -ne "Up to date" -or $rtStatus -ne "Enabled") {
            # Rmm-Alert -Category "av_out_of_date" -Body "AV is out of date or real-time protection is disabled ($avName): definitions=$defStatus, realtime=$rtStatus)"
        }
    }
} catch {
    Write-Host "Could not read antivirus status: $($_.Exception.Message)"
    Set-Asset-Field -Name "AV Name" -Value "Unknown"
    Set-Asset-Field -Name "AV Definition Status" -Value "Unknown"
    Set-Asset-Field -Name "AV Realtime Status" -Value "Unknown"
}

Write-Host ""
Write-Host "=== Done ==="
