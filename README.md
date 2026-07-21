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
| `maintenance/vsgn_printer_setup_d11_32.ps1` | VSGN — sets up the "D11-32 MFP Container MFP M430f" network printer (HP LaserJet Enterprise MFP M430, IP 192.168.0.32) via native PowerShell printing cmdlets |

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

One-time setup logic and source of truth (run indirectly via the SyncroMSP wrapper below — do not upload this file itself to Syncro). Sets up a file-level access statistic for a shared folder: which file, how often, last accessed — no usernames in the export, no per-person monitoring.

Sets the `Object Access -> Audit File System` = Success audit policy itself, locally (`auditpol` + the `SCENoApplyLegacyAuditPolicy` registry value), so no manual GPO edit is required. Caveat: if a GPO already explicitly manages this subcategory on the target server's OU, the next Group Policy background refresh will silently overwrite it back — the script re-checks and prints the result right after setting it so that's immediately visible; if that happens, the durable fix is the GPO itself (`Object Access -> Audit File System` = Success + `Audit: Force audit policy subcategory settings...` = Enabled, applied to the **Domain Controllers OU** / `Default Domain Controllers Policy` if the target server is a DC).

```powershell
.\Setup-FileAccessAudit.ps1 -TargetPath "C:\_Daten\Daten\07 IT\AVOR-Exelprogramme"
```

This:
1. Sets the `File System` audit subcategory to Success (referenced by GUID, not name, since `auditpol` rejects the English name on non-English Windows), then prints the result for verification
2. Sets the SACL recursively on `-TargetPath` (`Get-Acl`/`Set-Acl` with a `FileSystemAuditRule` — `icacls /setaudit` has no documented flag syntax and consistently failed as "invalid parameter")
3. Grows the Security event log (default 1 GB) — daily collection avoids losing events to log rotation between weekly reports
4. Writes `Collect-FileAccess.ps1` (parses event ID 4663 daily, filters out computer/service accounts like `SRV$` or `SYSTEM` so AV/backup/indexer scans aren't counted as accesses, skips directory-level events so folder browsing / this setup script's own recursive SACL sweep isn't counted either, appends to a cumulative CSV) and `Report-FileAccess.ps1` (aggregates the last 7 days) to `-ScriptDir` (default `C:\_admin\FileAccessAudit\Scripts`)
5. Registers two scheduled tasks (SYSTEM): daily collection and a weekly report

Note: `raw.githubusercontent.com` sits behind a CDN and caches responses briefly (~5 min) — the wrapper below adds a cache-busting query string, but if you suspect you're seeing stale content, `curl` the raw URL yourself to check what's actually being served before relying on it.

**`maintenance/file-access-audit/syncro_wrapper_avor_exelprogramme.ps1` — this is the file to copy into the SyncroMSP web interface.** It's a thin wrapper: downloads the current `Setup-FileAccessAudit.ps1` from this repo and runs it with `-TargetPath` hardcoded to the AVOR-Exelprogramme share on `srv`. Follows the standard SyncroMSP script conventions (`Import-Module $env:SyncroModule`, `Rmm-Alert` on failure, `exit 0`/`exit 1`). Paste its contents into Syncro under **Scripting → Scripts** and run once against the `srv` asset — the daily/weekly scheduled tasks it creates then run independently of Syncro from that point on. Since it always fetches the current version at runtime, no manual sync with `Setup-FileAccessAudit.ps1` is needed.

Output: cumulative raw CSV and dated weekly report CSVs under `-ReportDir` (default `C:\_admin\FileAccessAudit\Reports`).

---

### `maintenance/vsgn_printer_setup_d11_32.ps1`

Sets up the "D11-32 MFP Container MFP M430f" HP LaserJet Enterprise MFP M430 network printer (port `IP_192.168.0.32`) at customer VSGN. Replaces an older cscript/`prnmngr.vbs` + `install.exe` batch approach that had a bug: `cd /temp` at the end is not a valid way to switch to `C:\temp` (should be `cd /d C:\temp`), so cleanup ran from inside `C:\temp\upd` instead and silently left temp files behind.

Assumes the driver package (`upd.zip`, from [HP's M430 series driver page](https://support.hp.com/us-en/drivers/hp-laserjet-enterprise-mfp-m430-series/29252393)) is already staged at `C:\temp\upd.zip` via the SyncroMSP script's file attachment before the script runs — no download step needed. The `.inf` file is located automatically inside the extracted package (searched recursively, driver name parsed out of the `.inf`'s model section), so it isn't tied to one exact package layout.

Removes any existing printer/port with the same name first (idempotent), extracts the driver, installs it via `Add-PrinterDriver` (falling back to staging it with `pnputil /add-driver` first if that fails), then creates the port and printer via `Add-PrinterPort`/`Add-Printer`. Cleans up the extracted files and the zip afterward.

Uses the GitHub wrapper pattern: **`maintenance/syncro_wrapper_vsgn_printer_d11_32.ps1` is the file to copy into SyncroMSP.** It downloads and runs the current `vsgn_printer_setup_d11_32.ps1` from this repo, so fixes pushed here take effect without editing the wrapper again. The Required File (`upd.zip` → `C:\temp\upd.zip`) still needs to be attached to the wrapper script itself in Syncro.

---

### `maintenance/remove_apps/`

Removes unwanted Win32 and AppX/Store apps from Windows endpoints. Uses the GitHub wrapper pattern — only a thin wrapper script lives in SyncroMSP; the logic and app lists are maintained in this repo.

**Structure:**
```
maintenance/remove_apps/
  core.ps1                        ← removal engine (downloaded at runtime)
  syncro_wrapper_<name>.ps1       ← SyncroMSP wrapper per app list (upload this)
  applists/
    <name>.ps1                    ← app list: $AppxPackages and $Win32Apps arrays
```

**Adding a new app list:**
1. Create `maintenance/remove_apps/applists/<name>.ps1` with `$AppxPackages` and `$Win32Apps` arrays
2. Copy an existing wrapper (e.g. `syncro_wrapper_vsgn_image_cleanup.ps1`), rename it to `syncro_wrapper_<name>.ps1`, and set `$AppList = '<name>'`
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