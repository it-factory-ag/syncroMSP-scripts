# SyncroMSP Scripts

PowerShell scripts deployed as SyncroMSP RMM scripts. All scripts use `Import-Module $env:SyncroModule` for the SyncroMSP API.

---

## Overview

| Script | What it does |
|---|---|
| `health/device_health.ps1` | Collects health information: BIOS, OS version/build, VM, TPM, Secure Boot, Sure Start, Windows Update, BitLocker, Antivirus |
| `secure-boot/patch_secure_boot.ps1` | Triggers Windows Secure Boot cert update via registry + scheduled task |
| `secure-boot/deactivate_sure_start.ps1` | Disables HP Sure Start via BCU (HP-only) |
| `hardware/get_bios_info.ps1` | Diagnostic: prints detailed system, BIOS, Secure Boot, TPM, and event log info |
| `drivers/HPIA_update.ps1` | Downloads and runs HP Image Assistant to install all updates |
| `maintenance/schedule_reboot.ps1` | Notifies the logged-in user and schedules a forced reboot in 6 hours |
| `maintenance/office_licence_cache_cleanup.ps1` | Clears all Office/M365 identity and license caches (run as logged-in user; reboot required after) |
| `maintenance/teams_cache_cleanup.ps1` | Clears classic + new Teams local cache (run as logged-in user; re-login required after) |
| `maintenance/vpn_first_logon_profile_fix.ps1` | Sets local policy to fix failed first domain login over VPN: always wait for network at logon + disable GPO slow-link detection, then gpupdate + reboots the device |
| `maintenance/remove_apps/` | Removes unwanted Win32 and AppX apps based on a per-customer app list |
| `maintenance/file-access-audit/Setup-FileAccessAudit.ps1` | One-time setup on a file server: sets SACL, grows the Security log, deploys a daily collector + weekly report script, registers scheduled tasks — file-level access statistics, no per-user monitoring |

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

### `maintenance/vpn_first_logon_profile_fix.ps1`

Fixes a failed first-time domain login over VPN, where Windows leaves an empty profile folder and login fails with `ERROR_GROUP_NOT_IN_CORRECT_STATE` ("The group or resource is not in the correct state to perform the requested operation"). Root cause is a Group Policy slow-link-detection race condition during profile creation over a high-latency VPN link — see [wiki article](https://wiki.prod.itfactory.ch/doc/erstanmeldung-domanenaccount-via-vpn-schlagt-fehl-FymRUwXiLV). Sets the two policy values locally on the device (equivalent to the domain GPO fix, but scoped to this machine instead of an OU):

- `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Winlogon\SyncForegroundPolicy` = 1 ("Always wait for the network at computer startup and logon")
- `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\GroupPolicyMinTransferRate` = 0 ("Configure Group Policy slow link detection")

Runs `gpupdate /force` and then reboots the device 60 seconds later — these settings only take effect at boot.

---

### `maintenance/file-access-audit/Setup-FileAccessAudit.ps1`

One-time setup, run as Administrator (or via SyncroMSP as SYSTEM — see wrapper below) on the file server itself. Sets up a file-level access statistic for a shared folder: which file, how often, last accessed — no usernames in the export, no per-person monitoring.

Prerequisite (set separately via GPO, this script only prints the current setting for manual verification — apply to the **Domain Controllers OU** / `Default Domain Controllers Policy` if the target server is a DC): `Object Access -> Audit File System` = Success, and `Audit: Force audit policy subcategory settings...` = Enabled.

```powershell
.\Setup-FileAccessAudit.ps1 -TargetPath "C:\_Daten\Daten\07 IT\AVOR-Exelprogramme"
```

This:
1. Prints the current `File System` audit subcategory setting (referenced by GUID, not name, since `auditpol` rejects the English name on non-English Windows) — check the output for `Success` yourself
2. Sets the SACL recursively on `-TargetPath` (`icacls /setaudit`)
3. Grows the Security event log (default 1 GB) — daily collection avoids losing events to log rotation between weekly reports
4. Writes `Collect-FileAccess.ps1` (parses event ID 4663 daily, appends to a cumulative CSV) and `Report-FileAccess.ps1` (aggregates the last 7 days) to `-ScriptDir` (default `C:\_admin\FileAccessAudit\Scripts`)
5. Registers two scheduled tasks (SYSTEM): daily collection and a weekly report

**GitHub wrapper (manual run):** `maintenance/file-access-audit/Run-Setup-FromGitHub.ps1` downloads the latest `Setup-FileAccessAudit.ps1` from this repo and runs it with the given parameters, so you don't need to copy the full script onto the server by hand:

```powershell
.\Run-Setup-FromGitHub.ps1 -TargetPath "C:\_Daten\Daten\07 IT\AVOR-Exelprogramme"
```

**SyncroMSP wrapper:** `maintenance/file-access-audit/syncro_setup_avor_exelprogramme.ps1` is a customer-specific wrapper (`TargetPath` hardcoded to the AVOR-Exelprogramme share on `srv`) that follows the standard SyncroMSP script conventions (`Import-Module $env:SyncroModule`, `Rmm-Alert` on failure, `exit 0`/`exit 1`). Upload it under **Scripting → Scripts** and run once against the `srv` asset — the daily/weekly scheduled tasks it creates then run independently of Syncro from that point on.

Output: cumulative raw CSV and dated weekly report CSVs under `-ReportDir` (default `C:\_admin\FileAccessAudit\Reports`).

---

### `maintenance/remove_apps/`

Removes unwanted Win32 and AppX/Store apps from Windows endpoints. Uses the GitHub wrapper pattern — only a thin wrapper script lives in SyncroMSP; the logic and app lists are maintained in this repo.

**Structure:**
```
maintenance/remove_apps/
  core.ps1                        ← removal engine (downloaded at runtime)
  <name>.ps1                      ← SyncroMSP wrapper per app list (upload this)
  applists/
    <name>.ps1                    ← app list: $AppxPackages and $Win32Apps arrays
```

**Adding a new app list:**
1. Create `maintenance/remove_apps/applists/<name>.ps1` with `$AppxPackages` and `$Win32Apps` arrays
2. Copy an existing wrapper (e.g. `vsgn_image_cleanup.ps1`), rename it, and set `$AppList = '<name>'`
3. Push to `main` — existing wrappers in SyncroMSP pick up list changes immediately, no re-upload needed
4. Upload the new wrapper to SyncroMSP under **Scripting → Scripts**

**App lists:**

| File | Customer / use case |
|---|---|
| `applists/vsgn_image_cleanup.ps1` | VSGN — removes apps from old image |

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


# Todos
- Health Script
-- Health script: runs only once a day
- Script: set Firefox bookmark, change browser language
-- bookmarks must be placed in folders
-- Bookmark bar
--- Folder: Suchen, 1/2 Klasse, 3/4 Klasse, 5/6 Klasse
--- Link: Schabi 