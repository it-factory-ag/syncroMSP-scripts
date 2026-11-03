<#
Sets up a network printer using the HP Universal Print Driver (PCL6), downloaded
directly from HP at runtime. Not intended as a direct SyncroMSP endpoint script -
run indirectly via a thin per-printer syncro_wrapper_*.ps1 (see
syncro_wrapper_vsgn_d11_32.ps1 for an example), which is what actually gets pasted
into Syncro. This script is the source of truth - keep wrappers in sync if its
parameters change.

Originally written for a single VSGN printer, generalized so the same driver
logic can be reused for other printers/customers without duplicating it per
wrapper.

Downloads the driver zip from ftp.hp.com (Akamai-hosted, stable static file -
unlike the JS-rendered support.hp.com driver pages, which can't be scripted
against). Bump -DriverUrl's default when HP releases a newer UPD version.

Stages every .inf in the package via pnputil (trusting the HP signing
certificate first - unattended pnputil otherwise rejects it with "the
publisher of an Authenticode-signed catalog has not yet been established as
trusted", since that trust is normally granted via an interactive
click-through dialog that can't appear when running as SYSTEM). Windows
republishes each staged .inf under C:\Windows\INF\oemXX.inf - Add-PrinterDriver
has to be pointed at that published copy, not the original extracted file, or
it fails with a generic "parameter is incorrect" (HRESULT 0x80070057). Driver
names are parsed out of the .inf's model section (skipping the [Manufacturer]
section, which has the same "name = target, arch" shape but isn't a model
entry) since the exact name varies per driver package and isn't worth
hardcoding.

Only installs while the printer answers on TCP 9100: the HP UPD reads the
device configuration at install time, and a queue installed while the printer
is unreachable ends up monochrome-only. If it doesn't answer, the script
installs nothing, copies itself to C:\ProgramData\ITFactory\PrinterSetup\ and
registers the scheduled task "ITFactory-PrinterSetup-<queue>" (SYSTEM, every
hour). The task re-runs this script with -Deferred 1: still unreachable
-> exits silently; reachable -> installs and unregisters itself. After 3
failed installs on a reachable printer it gives up (see <queue>.log in that
folder). The Syncro run exits 0 in that case, the queue is just pending.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$PrinterName,

    [Parameter(Mandatory = $true)]
    [string]$PrinterIP,

    [string]$PortName = "IP_$PrinterIP",

    [string]$DriverUrl = "https://ftp.hp.com/pub/softlib/software13/printers/UPD/upd-pcl6-win11-x64-8.2.0.26819.zip",

    [string]$DriverZipPath = "C:\temp\hp_upd_pcl6.zip",

    [string]$ExtractDir = "C:\temp\hp_upd_pcl6",

    [ValidateSet("Color", "Monochrome")]
    [string]$ColorMode = "Color",

    # Set by the scheduled task only: stay silent while the printer is unreachable.
    [int]$Deferred = 0
)
# Script version = git blob hash of this file (same as `git hash-object <file>`), no git needed.
# Matches the repo only when the file runs unmodified, i.e. as downloaded by the wrapper.
# Look it up in the repo with: git log --oneline --find-object=<hash>
$scriptVersion = & {
    try {
        $bytes  = [IO.File]::ReadAllBytes($PSCommandPath)
        $prefix = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
        $sha1   = [Security.Cryptography.SHA1]::Create()
        $sha1.TransformBlock($prefix, 0, $prefix.Length, $null, 0) | Out-Null
        $sha1.TransformFinalBlock($bytes, 0, $bytes.Length) | Out-Null
        (($sha1.Hash | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 7)
    } catch { "unknown" }
}
Write-Host "Version: $scriptVersion"


function Get-InfDriverCandidates {
    param([string]$InfPath)

    $lines = Get-Content -Path $InfPath
    $strings = @{}
    $inStrings = $false
    foreach ($line in $lines) {
        $trimmed = ($line -replace ';.*$', '').Trim()
        if ($trimmed -match '^\[Strings\]$') { $inStrings = $true; continue }
        if ($trimmed -match '^\[.+\]$') { $inStrings = $false; continue }
        if ($inStrings -and $trimmed -match '^"?([^"=]+?)"?\s*=\s*"(.*)"\s*$') {
            $strings[$Matches[1].Trim()] = $Matches[2]
        }
    }

    # The [Manufacturer] section maps a manufacturer display string to a model
    # section name (also "name = target, arch1, arch2" shaped) - skip it, or
    # its entries get misread as driver model names (e.g. "HP Inc.").
    $candidates = New-Object System.Collections.Generic.List[string]
    $inManufacturer = $false
    foreach ($line in $lines) {
        $trimmed = ($line -replace ';.*$', '').Trim()
        if ($trimmed -match '^\[Manufacturer\]$') { $inManufacturer = $true; continue }
        if ($trimmed -match '^\[.+\]$') { $inManufacturer = $false; continue }
        if ($inManufacturer) { continue }
        if ($trimmed -match '^(?:"(?<name>[^"]+)"|%(?<ph>[^%]+)%)\s*=\s*[\w\.\-]+\s*,\s*\S+') {
            if ($Matches['name']) {
                $candidates.Add($Matches['name']) | Out-Null
            } elseif ($strings.ContainsKey($Matches['ph'])) {
                $candidates.Add($strings[$Matches['ph']]) | Out-Null
            }
        }
    }
    return $candidates | Select-Object -Unique
}

function Get-PnpUtilPublishedInfPath {
    param([string[]]$PnpUtilOutput)

    foreach ($line in $PnpUtilOutput) {
        if ($line -match '(?:Published Name|Ver.ffentlichter Name)\s*:\s*(oem\d+\.inf)') {
            return Join-Path $env:WINDIR "INF\$($Matches[1])"
        }
    }
    return $null
}

$safeName   = $PrinterName -replace '[^\w\-]', '_'
$taskName   = "ITFactory-PrinterSetup-$safeName"
$dataDir    = Join-Path $env:ProgramData "ITFactory\PrinterSetup"
$taskScript = Join-Path $dataDir "Setup-Printer.ps1"
$logPath    = Join-Path $dataDir "$safeName.log"
$failPath   = Join-Path $dataDir "$safeName.failures"
$maxDeferredFailures = 3

function Write-Log([string]$Message) {
    Write-Host $Message
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    Add-Content -Path $logPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
}

# The Syncro module is only loaded when called from a wrapper, not in the scheduled task.
function Send-Alert([string]$Body) {
    if (Get-Command Rmm-Alert -ErrorAction SilentlyContinue) {
        Rmm-Alert -Category "Printer Setup" -Body $Body
    }
}

function Test-PrinterReachable([string]$Address, [int]$Port = 9100, [int]$TimeoutMs = 3000) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($connect)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Register-DeferredSetup {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    # The wrapper's copy lives in the SYSTEM temp dir; keep a stable copy for the task.
    if ($PSCommandPath -ne $taskScript) {
        Copy-Item -Path $PSCommandPath -Destination $taskScript -Force
    }
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$taskScript`" -PrinterName `"$PrinterName`" -PrinterIP `"$PrinterIP`" -PortName `"$PortName`" -DriverUrl `"$DriverUrl`" -ColorMode $ColorMode -Deferred 1"
    $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments
    # No -RepetitionDuration: repeats indefinitely (Windows 10 / Server 2016 and later).
    $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours(1) -RepetitionInterval (New-TimeSpan -Hours 1)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    Remove-Item -Path $failPath -Force -ErrorAction SilentlyContinue
}

if (-not (Test-PrinterReachable $PrinterIP)) {
    if ($Deferred -eq 1) { exit 0 }
    try {
        Register-DeferredSetup
        Write-Log "Printer '$PrinterName' ($PrinterIP) does not answer on TCP 9100. Nothing installed; scheduled task '$taskName' installs it once the printer is reachable (checks every hour)."
        exit 0
    } catch {
        Write-Log "ERROR: Printer '$PrinterName' ($PrinterIP) is unreachable and the deferred setup task could not be registered: $($_.Exception.Message)"
        Send-Alert "Printer '$PrinterName' ($PrinterIP) is unreachable and the deferred setup task could not be registered on $env:COMPUTERNAME : $($_.Exception.Message)"
        exit 1
    }
}

# A queue's task and a Syncro run (or two queues' tasks) can fire at the same
# time; they share the driver zip/extract paths, so install one at a time.
$mutex = New-Object Threading.Mutex($false, "Global\ITFactory-PrinterSetup")
$hasMutex = $false
try { $hasMutex = $mutex.WaitOne([TimeSpan]::FromMinutes(30)) } catch [Threading.AbandonedMutexException] { $hasMutex = $true }

$exitCode = 0
try {
    Write-Host "=== Printer Setup: $PrinterName ==="

    Write-Host "Downloading driver package from $DriverUrl..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -Path (Split-Path $DriverZipPath) -ItemType Directory -Force | Out-Null
    (New-Object Net.WebClient).DownloadFile($DriverUrl, $DriverZipPath)

    # Match on name only - not port - so a second queue sharing this port
    # (e.g. a "letterhead" queue for the same physical printer/IP) doesn't
    # get deleted by this run. A printer must be removed before its port can
    # be removed; Remove-PrinterPort below silently no-ops if another queue
    # is still using the port.
    Write-Host "Removing existing printer '$PrinterName' if present..."
    Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue | Remove-Printer -ErrorAction SilentlyContinue
    Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue | Remove-PrinterPort -ErrorAction SilentlyContinue

    if (Test-Path $ExtractDir) {
        Remove-Item -Path $ExtractDir -Recurse -Force
    }
    Write-Host "Extracting driver package..."
    Expand-Archive -Path $DriverZipPath -DestinationPath $ExtractDir -Force

    $infFiles = Get-ChildItem -Path $ExtractDir -Filter "*.inf" -Recurse
    if (-not $infFiles) {
        throw "No .inf file found inside '$DriverZipPath'."
    }
    Write-Host "Found $($infFiles.Count) .inf file(s):"
    $infFiles | ForEach-Object { Write-Host "  $($_.FullName)" }

    # Trust the certificate the driver catalogs are signed with. Unattended
    # pnputil rejects them otherwise ("the publisher of an Authenticode-signed
    # catalog has not yet been established as trusted") - interactively, that
    # trust is granted via the "trust software from HP Inc.?" click-through
    # dialog, which can't appear when running as SYSTEM.
    $catFiles = Get-ChildItem -Path $ExtractDir -Filter "*.cat" -Recurse
    $trustedPublisherStore = New-Object Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
    $trustedPublisherStore.Open("ReadWrite")
    foreach ($cat in $catFiles) {
        $signature = Get-AuthenticodeSignature -FilePath $cat.FullName
        if ($signature.SignerCertificate -and ($trustedPublisherStore.Certificates.Find("FindByThumbprint", $signature.SignerCertificate.Thumbprint, $false).Count -eq 0)) {
            Write-Host "Trusting driver signing certificate: $($signature.SignerCertificate.Subject)"
            $trustedPublisherStore.Add($signature.SignerCertificate)
        }
    }
    $trustedPublisherStore.Close()

    # Stage every .inf via pnputil first. Windows copies each into the driver
    # store under C:\Windows\INF\oemXX.inf ("Published Name" in the output) -
    # Add-PrinterDriver has to be pointed at that published copy, not at the
    # original extracted file, or it fails with a generic
    # "parameter is incorrect" (HRESULT 0x80070057) instead of a clear error.
    $publishedInfPathByFile = @{}
    foreach ($inf in $infFiles) {
        Write-Host "Staging driver via pnputil: $($inf.FullName)"
        $pnputilOutput = & pnputil.exe /add-driver "$($inf.FullName)" /install 2>&1
        $pnputilOutput | ForEach-Object { Write-Host "  $_" }
        $publishedInfPath = Get-PnpUtilPublishedInfPath -PnpUtilOutput $pnputilOutput
        if ($publishedInfPath) {
            $publishedInfPathByFile[$inf.FullName] = $publishedInfPath
        } else {
            Write-Host "  Could not determine the published INF path for $($inf.Name) - skipping it for Add-PrinterDriver."
        }
    }

    $installedDriverName = $null
    foreach ($inf in $infFiles) {
        if (-not $publishedInfPathByFile.ContainsKey($inf.FullName)) { continue }
        $publishedInfPath = $publishedInfPathByFile[$inf.FullName]
        $candidates = Get-InfDriverCandidates -InfPath $inf.FullName
        Write-Host "$($inf.Name): candidate driver name(s) found: $($candidates -join ' | ')"
        foreach ($driverName in $candidates) {
            try {
                Add-PrinterDriver -Name $driverName -InfPath $publishedInfPath -ErrorAction Stop
                $installedDriverName = $driverName
                break
            } catch {
                Write-Host "  Add-PrinterDriver failed for '$driverName' ($publishedInfPath): $($_.Exception.Message)"
                continue
            }
        }
        if ($installedDriverName) { break }
    }

    if (-not $installedDriverName) {
        throw "Could not install any printer driver found in '$DriverZipPath' - checked $($infFiles.Count) .inf file(s)."
    }
    Write-Host "Installed printer driver: $installedDriverName"

    if (Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue) {
        Write-Host "Port $PortName already exists - reusing it (e.g. a second queue sharing this printer's port)."
    } else {
        Write-Host "Creating printer port $PortName ($PrinterIP)..."
        Add-PrinterPort -Name $PortName -PrinterHostAddress $PrinterIP
    }

    Write-Host "Creating printer $PrinterName..."
    Add-Printer -Name $PrinterName -DriverName $installedDriverName -PortName $PortName

    if (-not (Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue)) {
        throw "Printer '$PrinterName' was not found after Add-Printer."
    }

    Write-Host "Setting default color mode to $ColorMode..."
    try {
        Set-PrintConfiguration -PrinterName $PrinterName -ColorMode $ColorMode -ErrorAction Stop
    } catch {
        # HP UPD queries the physical device before applying this. The
        # reachability check above makes that unlikely to fail, but the
        # printer can still drop off between check and here. Don't fail the
        # whole run over it.
        Write-Log "WARNING: Could not set color mode to ${ColorMode}: $($_.Exception.Message)"
        Send-Alert "Printer '$PrinterName' ($PrinterIP) was set up, but ColorMode '$ColorMode' could not be applied. Re-run the setup script once the printer is online."
    }

    Write-Host "Cleaning up temp files..."
    Remove-Item -Path $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $DriverZipPath -Force -ErrorAction SilentlyContinue

    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -Path $failPath -Force -ErrorAction SilentlyContinue
        Write-Log "Printer '$PrinterName' set up; deferred setup task '$taskName' removed."
    }

    Write-Host "=== Done ==="
}
catch {
    Write-Log "ERROR: Failed to set up printer '$PrinterName': $($_.Exception.Message)"
    $exitCode = 1
    if ($Deferred -eq 1) {
        $failures = 1 + [int](Get-Content -Path $failPath -ErrorAction SilentlyContinue)
        if ($failures -ge $maxDeferredFailures) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Remove-Item -Path $failPath -Force -ErrorAction SilentlyContinue
            Write-Log "Giving up after $failures failed attempts; task '$taskName' removed. Re-run the Syncro script to retry."
        } else {
            Set-Content -Path $failPath -Value $failures
        }
    }
}
finally {
    if ($hasMutex) { $mutex.ReleaseMutex() }
}
exit $exitCode
