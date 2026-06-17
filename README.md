# SyncroMSP Scripts

PowerShell scripts deployed as SyncroMSP RMM scripts. All scripts use `Import-Module $env:SyncroModule` for the SyncroMSP API.

---

## Scripts

### `secure-boot/check_secure_boot_2023_certs.ps1`

Checks whether Secure Boot is enabled and whether the UEFI key databases contain the 2023 replacement certificates Microsoft issued before the old 2011 certs expire.

**Custom asset fields required:**
| Field | Values |
|---|---|
| `Secure Boot Enabled` | `Enabled`, `Disabled`, `Not supported (Legacy BIOS)`, `Unknown` |
| `Secure Boot KEK 2023` | `Yes`, `No`, `N/A` |
| `Secure Boot DB 2023` | `Yes`, `No`, `N/A` |

**Alert conditions:**
- Secure Boot enabled, but KEK does not contain a 2023 cert → old KEK expires June 2026
- Secure Boot enabled, but DB does not contain a 2023 cert → old DB certs expire October 2026

**Notes:**
- Legacy BIOS systems exit 0 with `Not supported (Legacy BIOS)` — not an issue.
- When Secure Boot is disabled, KEK 2023 and DB 2023 are set to `N/A`.

---

### `secure-boot/patch_secure_boot.ps1`

Applies a registry fix and triggers the built-in `Secure-Boot-Update` scheduled task to patch Secure Boot.

---

### `secure-boot/deactivate_sure_start.ps1`

Disables HP Sure Start via the HP WMI BIOS interface. Exits 0 with a message on non-HP hardware.

---

### `hardware/get_bios_info.ps1`

Collects system, BIOS, CPU, RAM, disk, and network information and prints it to the script output.

---

### `hardware/detect_virtual_device.ps1`

Detects whether the device is a virtual machine by inspecting WMI manufacturer, model, and BIOS version strings.

**Custom asset fields required:**
| Field | Values |
|---|---|
| `Virtual Machine` | `VMware`, `Hyper-V`, `VirtualBox`, `QEMU/KVM`, `Xen`, `Parallels`, `No` |

**Detected hypervisors:** VMware, Hyper-V, VirtualBox, QEMU/KVM, Xen, Parallels.

---

### `bitlocker/get_bitlocker_keys.ps1`

Reads BitLocker recovery keys for C:, D:, and E: drives and writes them to custom asset fields.

**Custom asset fields required:** `Bitlocker_active` (Yes/No), `Bitlocker_Key_C`, `Bitlocker_Key_D`, `Bitlocker_Key_E` (Text Fields on the Syncro Device asset type).

---

### `windows-update/update_last_successful_WUConnection.ps1`

Checks when Windows Update last successfully searched for updates. Alerts if never run or if more than 20 days ago.

**Custom asset fields required:**
| Field | Values |
|---|---|
| `Last succesful WUConnection` | Timestamp (`yyyy-MM-dd HH:mm:ss`) |

**Alert conditions (exit 1):**
- Windows Update has never successfully searched
- Last successful search was more than 20 days ago

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
$url = "https://raw.githubusercontent.com/it-factory-ag/ifa-helper-scripts/main/syncroMSP/get_bios_info.ps1"
Invoke-Expression (New.Object Net.WebClient).DownloadString($url)
```

See the [SyncroMSP community post](https://community.syncromsp.com/t/take-command-master-scripting-with-github/18746) for details.
