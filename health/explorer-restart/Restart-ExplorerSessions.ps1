<#
Restarts explorer.exe in every user session of a terminal server (RDS), without
logging anyone off.

Why: on HBL-SRV02 the sessions get slower over the days (Explorer, Office file
dialogs, Foxit). A manual Explorer restart made it bearable again, users do not
want to log off. Shell extensions (ownCloud overlays, AV hooks, ...) live inside
explorer.exe, a restart resets them.

How (per session with an explorer.exe, session 0 skipped):
  1. Kills all explorer.exe processes of the session (shell plus separate
     folder window processes). Open Explorer windows close, nothing else does.
  2. Waits up to -WaitSeconds for Winlogon to restart the shell on its own
     (AutoRestartShell).
  3. If none comes, starts explorer.exe itself as the session's user
     (WTSQueryUserToken + CreateProcessAsUser, needs SYSTEM) and waits again.
     Not with the SYSTEM token: the shell would then run as SYSTEM.
  4. A session left without explorer.exe (no taskbar for the user) raises
     Rmm-Alert (category "Explorer Restart") and exits 1.

-Users: comma-separated user names (sAMAccountName, no domain) to restrict the
restart to; empty = all sessions.

Files: C:\ProgramData\ITFactory\ExplorerRestart\restart.log (last 500 lines).

Schedule nightly (e.g. 03:30, after the backup). Run as: SYSTEM.
Local test: .\Test-Local.ps1 (uses Mock-SyncroModule.psm1). It really restarts
Explorer in all sessions; use -Users <name> to limit it.

Called via syncro_wrapper_explorer_restart.ps1; this file is never pasted into
Syncro, so it may use a param() block.
#>

param(
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

$dataDir = Join-Path $env:ProgramData "ITFactory\ExplorerRestart"
$logPath = Join-Path $dataDir "restart.log"
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

$userFilter = @($Users -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# One entry per session: user from the owner of its explorer.exe processes.
$sessions = Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId<>0" |
    Group-Object SessionId | ForEach-Object {
        $owner = Invoke-CimMethod -InputObject $_.Group[0] -MethodName GetOwner
        [pscustomobject]@{
            SessionId = [int]$_.Name
            User      = $owner.User
            Domain    = $owner.Domain
            Procs     = $_.Group
        }
    } | Sort-Object SessionId

if ($userFilter.Count) { $sessions = @($sessions | Where-Object { $userFilter -contains $_.User }) }

$filterText = if ($userFilter.Count) { "users $($userFilter -join ', ')" } else { "all users" }
if (-not $sessions) {
    Write-Log "No session with explorer.exe found ($filterText). Nothing to do."
    exit 0
}
Write-Log "Restarting Explorer in $(@($sessions).Count) session(s) ($filterText)"

$failed = @()
foreach ($s in $sessions) {
    $label  = "session $($s.SessionId) $($s.Domain)\$($s.User)"
    $oldIds = @($s.Procs | ForEach-Object { $_.ProcessId })
    $before = ($s.Procs | ForEach-Object {
        $p = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
        if ($p) { "PID $($p.Id) $([math]::Round($p.WorkingSet64 / 1MB)) MB $($p.HandleCount) handles" }
    }) -join "; "
    try {
        $oldIds | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
        $new = Wait-Explorer $s.SessionId $oldIds $WaitSeconds
        $how = "restarted by Winlogon"
        if (-not $new) {
            [ItfUserLauncher]::Start($s.SessionId, "$env:WINDIR\explorer.exe") | Out-Null
            $new = Wait-Explorer $s.SessionId $oldIds 15
            $how = "started by this script (Winlogon did not restart it within $WaitSeconds s)"
        }
        if ($new) {
            Write-Log "OK   $label : killed [$before], new PID $($new.ProcessId) $how"
        } else {
            Write-Log "FAIL $label : killed [$before], no explorer.exe running afterwards"
            $failed += $label
        }
    } catch {
        Write-Log "FAIL $label : $($_.Exception.Message)"
        $failed += $label
    }
}

# Keep the log bounded.
$lines = @(Get-Content $logPath)
if ($lines.Count -gt 500) { $lines | Select-Object -Last 500 | Set-Content $logPath }

if ($failed.Count) {
    Rmm-Alert -Category "Explorer Restart" -Body "Explorer restart on $env:COMPUTERNAME left $($failed.Count) session(s) without explorer.exe (no taskbar): $($failed -join ', '). Check $logPath."
    exit 1
}
exit 0
