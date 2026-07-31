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
| `maintenance/Debug-OutlookAuth.ps1` | Read-only diagnostic for Outlook not fetching mail without prompting for a password: device join state, cached token ages, Credential Manager entries, profile accounts, endpoint reachability, recent related event log errors (run as logged-in user); `maintenance/syncro_wrapper_debug_outlook_auth.ps1` is the thin wrapper to paste into SyncroMSP |
| `maintenance/office_licence_cache_cleanup.ps1` | Clears all Office/M365 identity and license caches (run as logged-in user; reboot required after); `maintenance/syncro_wrapper_office_licence_cache_cleanup.ps1` is the thin wrapper to paste into SyncroMSP |
| `maintenance/teams_cache_cleanup.ps1` | Clears classic + new Teams local cache (run as logged-in user; re-login required after) |
| `maintenance/vpn_first_logon_profile_fix.ps1` | Sets local policy to fix failed first domain login over VPN: always wait for network at logon + disable GPO slow-link detection, then gpupdate + reboots the device |
| `maintenance/remove_apps/` | Removes unwanted Win32 and AppX apps based on a per-customer app list |
| `maintenance/file-access-audit/Setup-FileAccessAudit.ps1` | One-time setup on a file server: sets SACL, grows the Security log, deploys a daily collector + weekly report script, registers scheduled tasks — file-level access statistics, no per-user monitoring |
| `maintenance/printers/Setup-Printer.ps1` | Generic HP Universal Print Driver (PCL6) network printer setup, parameterized by printer name/IP; per-printer `syncro_wrapper_*.ps1` files call it (e.g. `syncro_wrapper_vsgn_d11_32.ps1` for VSGN's "D11-32 Container MFP M430f", IP 192.168.0.32) |
| `maintenance/printers/Set-DefaultPrinter.ps1` | Generic engine, sets a printer as default for the logged-in user (`-PrinterName`); per-printer `syncro_wrapper_set_default_*.ps1` kept in Syncro only (not in this repo); must run as the logged-in user, not SYSTEM |
| `maintenance/Backup-UserData.ps1` | Backs up Desktop/Documents/Downloads/Pictures/Music/Videos for every real local user profile to an external drive ahead of a PC replacement; takes `-TargetDrive` (e.g. `E:`) |
| `maintenance/ssh-debug/Enable-SSHDebug.ps1` | Temporarily enables OpenSSH Server for a remote debug session (installs the capability if missing, starts `sshd`, opens the firewall rule); auto-disables itself again after `-DurationMinutes` (default 60) via a one-time Scheduled Task; `maintenance/ssh-debug/Disable-SSHDebug.ps1` disables it immediately instead of waiting |
| `maintenance/ssh-debug/Disable-SSHDebug.ps1` | Immediately reverts `Enable-SSHDebug.ps1` (stops `sshd`, restores its original startup type, closes the firewall rule, removes the auto-disable task); safe to run even if no session is active |

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

### `maintenance/printers/Setup-Printer.ps1`

Generic engine that sets up a network printer using the HP Universal Print Driver (PCL6). Not a direct SyncroMSP endpoint script — run indirectly via a thin per-printer `syncro_wrapper_*.ps1` (see below), which is what actually gets pasted into Syncro. Takes `-PrinterName` and `-PrinterIP` (plus optional `-PortName`/`-DriverUrl`), so the same driver-install logic is shared across printers/customers instead of duplicated per wrapper.

Downloads the driver directly from `ftp.hp.com` at runtime (`-DriverUrl`'s default — bump it when HP releases a newer UPD version). No SyncroMSP file attachment needed: `ftp.hp.com` is HP's stable static file host, unlike the JS-rendered `support.hp.com` driver pages which can't be scripted against.

Stages every `.inf` in the package via `pnputil`, first trusting the HP signing certificate (unattended `pnputil` otherwise rejects it with "the publisher of an Authenticode-signed catalog has not yet been established as trusted" — that trust is normally granted via an interactive click-through dialog that can't appear when running as SYSTEM). Windows republishes each staged `.inf` under `C:\Windows\INF\oemXX.inf`; `Add-PrinterDriver` has to be pointed at that published copy, not the original extracted file, or it fails with a generic "parameter is incorrect" (HRESULT `0x80070057`). Driver names are parsed out of the `.inf`'s model section (skipping the `[Manufacturer]` section, which has the same "name = target, arch" shape but isn't a model entry) since the exact name varies per driver package.

Removes any existing printer/port with the same name first (idempotent), then creates the port and printer via `Add-PrinterPort`/`Add-Printer`. Cleans up the extracted files and the zip afterward.

**Per-printer wrappers** (e.g. `syncro_wrapper_vsgn_d11_32.ps1` — sets up the "D11-32 Container MFP M430f" at customer VSGN, IP `192.168.0.32`) are the files to copy into SyncroMSP. Each is a few lines: it downloads and runs the current `Setup-Printer.ps1` from this repo with that printer's fixed `-PrinterName`/`-PrinterIP`, so fixes to the shared driver logic take effect everywhere without editing wrappers again. No Required File attachment is needed. To add another printer, copy an existing wrapper and change the name/IP.

---

### `maintenance/printers/Set-DefaultPrinter.ps1`

Generic engine that sets the given printer (`-PrinterName`) as the default for the logged-in user. Not a direct SyncroMSP endpoint script — run indirectly via a thin `syncro_wrapper_set_default_*.ps1` pasted directly into Syncro (not checked into this repo; kept in Syncro only, per printer/customer).

Sets the printer as default via `Win32_Printer`'s `SetDefaultPrinter()` CIM method rather than the `WScript.Network` COM object, which silently no-ops outside an interactive desktop session context. **Must run as the logged-in user** (Syncro: run as "Logged in user"), since the default printer is a per-user setting — running as SYSTEM sets it for the SYSTEM account's session, not the interactive user's.

---

### `maintenance/Backup-UserData.ps1`

Run directly against the old machine in SyncroMSP (not via the wrapper pattern - the drive letter is a runtime parameter, so there's nothing to hardcode). Plug in the external drive first, then run with `-TargetDrive` set to its drive letter, e.g. `E:`.

Finds real local user profiles via `Get-CimInstance Win32_UserProfile -Filter "Special = False"` rather than listing `C:\Users`, so system/service profiles (Default, Public, systemprofile, LocalService, etc.) are excluded automatically without a maintained exclude list. For each profile, copies `Desktop`, `Documents`, `Downloads`, `Pictures`, `Music`, `Videos` (whichever exist, configurable via `$FoldersToBackup` at the top of the script) via `robocopy /E /XJ` to `<TargetDrive>\UserDataBackup\<mirrored source path>`, logging to `robocopy.log` in that backup folder. The destination mirrors each source path relative to its drive root (e.g. `C:\Users\jdoe\Desktop` -> `...\UserDataBackup\Users\jdoe\Desktop`), so extra absolute paths outside `C:\Users` can be added via `$AdditionalPaths` at the top without colliding with the per-user folders. This is a one-off data transfer, not a recurring backup - no timestamp subfolder, re-running against the same drive merges into the same `UserDataBackup` folder. Assumes standard, non-redirected folder locations (English folder names) - a folder moved elsewhere or OneDrive-redirected won't be picked up.

---

### `maintenance/ssh-debug/Enable-SSHDebug.ps1` / `maintenance/ssh-debug/Disable-SSHDebug.ps1`

Opens a temporary OpenSSH remote-debug window on a Windows endpoint (native `ssh`, no extra tooling), then closes it again on its own so access doesn't linger.

`Enable-SSHDebug.ps1` (run directly against the target asset, optionally with `-DurationMinutes 90` etc., default 60):
1. Installs the `OpenSSH.Server` Windows capability if missing (left installed afterwards — harmless, avoids re-downloading it every session).
2. Captures `sshd`'s current startup type into `C:\ProgramData\ITFactory\SSHDebug\state.json` **only on first enable of a session**, so `Disable-SSHDebug.ps1` can restore the exact original value instead of assuming a default. Re-running `Enable-SSHDebug.ps1` while a session is already active just extends the timer without touching that saved state.
3. Sets `sshd` to `Manual` startup and starts it, and makes sure the `OpenSSH-Server-In-TCP` firewall rule is enabled.
4. Deploys a local copy of the disable logic to `C:\ProgramData\ITFactory\SSHDebug\Disable-SSHDebug.ps1` and registers a one-time Scheduled Task (`ITFactory-SSHDebug-AutoDisable`, runs as SYSTEM) that calls it after `-DurationMinutes` — this runs entirely locally, so the auto-revert still fires even if the Syncro connection drops or the machine briefly sleeps (`-StartWhenAvailable`).
5. Optionally writes the expiry timestamp to the `SSH Debug Expires` custom asset field (create it first under **Admin → Custom Asset Fields**, type Text) and raises an `Rmm-Alert` (category `SSH Debug Access`) so the temporary access is visible/audited in Syncro.

Runs entirely invisible to the logged-in user: like all SyncroMSP scripts this executes as SYSTEM in session 0 (no window, no toast), and the scheduled auto-disable task runs `-WindowStyle Hidden` and is registered as a hidden task. `Rmm-Alert` is admin-facing only (SyncroMSP dashboard), never shown on the endpoint.

The Windows-created `OpenSSH-Server-In-TCP` firewall rule is not scoped to a network profile (it applies on Domain/Private/Public alike) — switching the connection profile to "Private" is **not** required for SSH itself to work, so this script doesn't touch it. Power/sleep settings are likewise left untouched; disable sleep manually during a session if the device might go idle.

**`maintenance/ssh-debug/Disable-SSHDebug.ps1`** reverts everything immediately (stops `sshd`, restores its original startup type, disables the firewall rule again, removes the scheduled task) — run it from Syncro to end a session early instead of waiting for the timer. Safe to run even with no session active. Its logic is duplicated as an embedded here-string inside `Enable-SSHDebug.ps1` (needed so the scheduled task can revert locally without depending on Syncro/network reachability at fire time) — keep both in sync if you change the revert logic.

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