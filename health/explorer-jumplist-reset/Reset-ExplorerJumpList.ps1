<#
Resets the Explorer jump list of every user whose list has grown too large.

Why: %APPDATA%\Microsoft\Windows\Recent\AutomaticDestinations\
5f7b5f1e01b83767.automaticDestinations-ms holds every folder the user opened.
Explorer builds "Frequent folders" in Quick access and the taskbar jump list
from it and is never trimmed. On HBL-SRV02 it reached 1.4-2.7 MB per user;
Explorer read it in ~20'000 small reads each time Quick access opened (Process
Monitor), which took 4-7 s. After deleting it Quick access opened fast again.
(5f7b5f1e01b83767 = Explorer's AppID per forensics sources, not documented by
Microsoft; the measurement is what counts.)

How (per user profile, optionally limited with -Users):
  1. Logs the size of the jump list (trend in reset.log).
  2. Below -ThresholdKB: nothing else.
  3. Above it: if the user has a session, kills explorer.exe in that session
     first (Explorer keeps the list in memory and would write it back), then
     copies the file to .bak and deletes it. Windows starts a new, empty list.
     Explorer comes back via Winlogon or, in disconnected sessions, is started
     as the user (WTSQueryUserToken + CreateProcessAsUser, not as SYSTEM).
     Users without a session: file is reset directly.
  4. A failed reset or a session left without explorer.exe raises Rmm-Alert
     (category "Explorer Jump List") and exits 1.

Effect for the user: taskbar gone for a few seconds, open Explorer windows
close, other programs keep running. Pinned Quick access folders stay (they
live in f01b4d95cf55d32a...). "Frequent folders" and the history on the
taskbar jump list of Explorer start empty and fill up again.

Files: C:\ProgramData\ITFactory\ExplorerJumpList\reset.log (last 1000 lines).
Schedule nightly (e.g. 01:30). Run as: SYSTEM. Also runs from a SYSTEM remote
shell without the Syncro module (no Rmm-Alert then).

Called via syncro_wrapper_explorer_jumplist_reset.ps1; this file is never
pasted into Syncro, so it may use a param() block.
#>

param(
    [int]$ThresholdKB = 1024,
    [string]$Users = "",
    [int]$WaitSeconds = 20
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

if ($env:SyncroModule) { Import-Module $env:SyncroModule -DisableNameChecking }

$dataDir = Join-Path $env:ProgramData "ITFactory\ExplorerJumpList"
$logPath = Join-Path $dataDir "reset.log"
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

function Write-Log([string]$Message) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Write-Host $line
    Add-Content -Path $logPath -Value $line
}

if (-not ('ItfUserLauncher' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class ItfUserLauncher {
    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSQueryUserToken(int sessionId, out IntPtr token);
    [DllImport("userenv.dll", SetLastError = true)]
    static extern bool CreateEnvironmentBlock(out IntPtr env, IntPtr token, bool inherit);
    [DllImport("userenv.dll", SetLastError = true)]
    static extern bool DestroyEnvironmentBlock(IntPtr env);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessAsUserW(IntPtr token, string app, StringBuilder cmdLine, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    // Starts cmdLine as the user logged on to sessionId, with that user's environment.
    // Needs SeTcbPrivilege (SYSTEM has it). Returns the process id.
    public static int Start(int sessionId, string cmdLine) {
        IntPtr token, env;
        if (!WTSQueryUserToken(sessionId, out token)) throw new Win32Exception();
        try {
            if (!CreateEnvironmentBlock(out env, token, false)) throw new Win32Exception();
            try {
                var si = new STARTUPINFO();
                si.cb = Marshal.SizeOf(si);
                si.lpDesktop = "winsta0\\default";
                PROCESS_INFORMATION pi;
                // 0x00000400 = CREATE_UNICODE_ENVIRONMENT
                if (!CreateProcessAsUserW(token, null, new StringBuilder(cmdLine), IntPtr.Zero, IntPtr.Zero, false, 0x00000400, env, null, ref si, out pi)) throw new Win32Exception();
                CloseHandle(pi.hThread);
                CloseHandle(pi.hProcess);
                return pi.dwProcessId;
            }
            finally { DestroyEnvironmentBlock(env); }
        }
        finally { CloseHandle(token); }
    }
}
'@
}

function Get-SessionExplorers([int]$SessionId) {
    @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$SessionId")
}

function Wait-Explorer([int]$SessionId, $OldIds, [int]$Seconds) {
    for ($i = 0; $i -lt $Seconds; $i += 2) {
        Start-Sleep -Seconds 2
        $new = @(Get-SessionExplorers $SessionId | Where-Object { $OldIds -notcontains $_.ProcessId })
        if ($new.Count) { return $new[0] }
    }
    return $null
}
$jumpList   = "AppData\Roaming\Microsoft\Windows\Recent\AutomaticDestinations\5f7b5f1e01b83767.automaticDestinations-ms"
$userFilter = @($Users -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# Sessions with an explorer.exe, keyed by the owner's SID.
$sessionsBySid = @{}
Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId<>0" | Group-Object SessionId | ForEach-Object {
    $sid = (Invoke-CimMethod -InputObject $_.Group[0] -MethodName GetOwnerSid).Sid
    if (-not $sid) { return }
    if (-not $sessionsBySid.ContainsKey($sid)) { $sessionsBySid[$sid] = @() }
    $sessionsBySid[$sid] += [int]$_.Name
}

$profiles = Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.SID -match '^S-1-5-21-[\d-]+$' } | ForEach-Object {
    $name = try { ((New-Object Security.Principal.SecurityIdentifier $_.SID).Translate([Security.Principal.NTAccount]).Value -split '\\')[-1] } catch { Split-Path $_.LocalPath -Leaf }
    [pscustomobject]@{ Name = $name; Sid = $_.SID; File = Join-Path $_.LocalPath $jumpList }
} | Where-Object { Test-Path -LiteralPath $_.File } | Sort-Object Name

if ($userFilter.Count) { $profiles = @($profiles | Where-Object { $userFilter -contains $_.Name }) }
Write-Log "Checking $(@($profiles).Count) profile(s), threshold $ThresholdKB KB"

$failed = @()
foreach ($p in $profiles) {
    $kb = [math]::Round((Get-Item -LiteralPath $p.File).Length / 1KB)
    if ($kb -lt $ThresholdKB) { Write-Log "     $($p.Name): $kb KB"; continue }

    $sessionIds = if ($sessionsBySid.ContainsKey($p.Sid)) { @($sessionsBySid[$p.Sid]) } else { @() }
    $oldIds = @()
    try {
        foreach ($sid in $sessionIds) {
            $procs = Get-SessionExplorers $sid
            $oldIds += @($procs | ForEach-Object { $_.ProcessId })
            $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        }
        # Right after the kill, before Winlogon restarts Explorer.
        Copy-Item -LiteralPath $p.File -Destination "$($p.File).bak" -Force -ErrorAction Stop
        for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath $p.File); $i++) {
            Remove-Item -LiteralPath $p.File -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 250
        }
        $how = if (Test-Path -LiteralPath $p.File) { $failed += $p.Name; "FAIL file still there" } else { "reset" }

        foreach ($sid in $sessionIds) {
            $new = Wait-Explorer $sid $oldIds $WaitSeconds
            if (-not $new) {
                [ItfUserLauncher]::Start($sid, "$env:WINDIR\explorer.exe") | Out-Null
                $new = Wait-Explorer $sid $oldIds 15
            }
            if (-not $new) { $failed += "$($p.Name) (session $sid without explorer.exe)"; $how += ", session $sid WITHOUT explorer.exe" }
        }
        $where = if ($sessionIds.Count) { "session $($sessionIds -join ',')" } else { "not logged on" }
        Write-Log "RESET $($p.Name): $kb KB, $where, $how (backup: .bak)"
    } catch {
        Write-Log "FAIL $($p.Name): $kb KB, $($_.Exception.Message)"
        $failed += $p.Name
    }
}

# Keep the log bounded.
$lines = @(Get-Content $logPath)
if ($lines.Count -gt 1000) { $lines | Select-Object -Last 1000 | Set-Content $logPath }

if ($failed.Count) {
    if (Get-Command Rmm-Alert -ErrorAction SilentlyContinue) {
        Rmm-Alert -Category "Explorer Jump List" -Body "Explorer jump list reset on $env:COMPUTERNAME failed for: $($failed -join ', '). Check $logPath."
    }
    exit 1
}
exit 0
