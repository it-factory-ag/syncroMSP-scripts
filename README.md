# SyncroMSP Scripts

PowerShell scripts deployed as SyncroMSP RMM scripts. All scripts use `Import-Module $env:SyncroModule` for the SyncroMSP API.

---

## Overview

| Script | What it does |
|---|---|
| `health/device_health.ps1` | Collects health information: BIOS, VM, TPM, Secure Boot, Sure Start, Windows Update, BitLocker |
| `secure-boot/patch_secure_boot.ps1` | Triggers Windows Secure Boot cert update via registry + scheduled task |
| `secure-boot/deactivate_sure_start.ps1` | Disables HP Sure Start via BCU (HP-only) |
| `hardware/get_bios_info.ps1` | Diagnostic: prints detailed system, BIOS, Secure Boot, TPM, and event log info |
| `drivers/HPIA_update.ps1` | Downloads and runs HP Image Assistant to install all updates |
| `maintenance/schedule_reboot.ps1` | Notifies the logged-in user and schedules a forced reboot in 6 hours |

---

## Scripts

### `secure-boot/patch_secure_boot.ps1`

Applies a registry fix and triggers the built-in `Secure-Boot-Update` scheduled task to patch Secure Boot.

---

### `secure-boot/deactivate_sure_start.ps1`

Disables HP Sure Start (`SureStart Production Mode`) via HP BCU. Exits 0 with a message on non-HP hardware. Returns code 6 if Sure Start is hardware-locked — requires manual BIOS setup (F10 at boot) in that case.

---

### `hardware/get_bios_info.ps1`

Collects system, BIOS, CPU, RAM, disk, and network information and prints it to the script output.

---

## Deployment

1. In SyncroMSP, go to **Admin → Custom Asset Fields** and create the fields listed above for each script you deploy.
2. Upload the script under **Scripting → Scripts**.
3. Assign to a policy or run manually against assets as needed.

### GitHub wrapper pattern

To avoid re-uploading scripts to SyncroMSP on every change, keep a thin wrapper in SyncroMSP that pulls and executes the latest version from this repo at runtime:

```powershell
# To avoid re-uploading scripts to SyncroMSP on every change, keep a thin wrapper in SyncroMSP that pulls and executes the latest version of the script
# https://community.syncromsp.com/t/take-command-master-scripting-with-github/18746
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/hardware/get_bios_info.ps1"
Invoke-Expression (New-Object Net.WebClient).DownloadString($url)
```

See the [SyncroMSP community post](https://community.syncromsp.com/t/take-command-master-scripting-with-github/18746) for details.
