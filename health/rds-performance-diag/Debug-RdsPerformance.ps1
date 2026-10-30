<#
Read-only performance diagnostic for a Windows Remote Desktop Session Host
(terminal server) that "gets slower over the week": Office, Explorer, PDF
reader and line-of-business apps feel sluggish while the browser does not.

Collects in one run:
  - System: OS, uptime, CPU/RAM, VM, power plan, Office C2R version
  - CPU, memory, pagefile and disk latency sampled over -SampleSeconds
  - RDS sessions (active/disconnected, idle, disconnected since) with per-session
    process count, private memory, handles and GDI/USER objects
  - Top processes by CPU, private memory, handles and GDI/USER objects (leak
    candidates; GDI/USER exhaustion makes one session sluggish while a fresh
    logon is fast again)
  - Printing: total/redirected printers, drivers, spooler size
  - User profiles: temp/.bak profiles, FSLogix
  - Network: DNS servers, latency to file servers (from users' mapped drives
    and SMB connections) and domain controllers
  - AV / Windows Search state, event log counts for the last -EventDays
  - Findings: heuristic WARN/INFO list

Every run also stores a JSON snapshot of the key metrics under
C:\ProgramData\ITFactory\RdsPerfDiag\ and prints the history of the last runs.
Schedule it daily (e.g. Mon-Fri 10:00) for 1-2 weeks: if available memory,
handles, pool or session/printer counts climb with uptime, that is the
"slower towards the end of the week" pattern. The full report of each run is
saved next to the snapshot as report_<COMPUTERNAME>_<timestamp>.txt and attached
to the Syncro asset via Upload-File (-Upload 0 disables it): Syncro truncates
script output at roughly 10'000 characters, so the details are only complete
in that file. The output starts with the findings and history for that reason.

Makes no changes besides writing those files. Never raises Rmm-Alert and always
exits 0: it's a diagnostic whose output a human reads.

Run as: SYSTEM (needs all sessions, all processes and the loaded user hives).
Manual run (elevated): .\Debug-RdsPerformance.ps1 -SampleSeconds 10
No Syncro mock needed: the script calls no Syncro functions.

Called via syncro_wrapper_rds_performance_diag.ps1; this file is never pasted
into Syncro, so it may use a param() block.
#>

param(
    [int]$SampleSeconds = 15,
    [int]$EventDays = 7,
    [int]$Upload = 1
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

# Import only when launched by Syncro, so a manual run doesn't fail on an empty path.
if ($env:SyncroModule) { Import-Module $env:SyncroModule -DisableNameChecking }

$ErrorActionPreference = "Continue"
if ($SampleSeconds -lt 3) { $SampleSeconds = 3 }

$dataDir    = Join-Path $env:ProgramData "ITFactory\RdsPerfDiag"
$timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$reportPath = Join-Path $dataDir "report_$($env:COMPUTERNAME)_$timestamp.txt"
$keepRuns  = 60
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding([string]$Severity, [string]$Text) {
    $findings.Add([pscustomobject]@{ Severity = $Severity; Finding = $Text })
}
function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host "=== $Title ==="
}
function Write-Table($Data) {
    if (-not $Data) { Write-Host "  (none)"; return }
    ($Data | Format-Table -AutoSize | Out-String -Width 220).TrimEnd() | Write-Host
}
function Test-PrivateIp([string]$Ip) {
    return $Ip -match '^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'
}
function Get-Median($Values) {
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    if ($sorted.Count % 2) { return $sorted[[int][math]::Floor($sorted.Count / 2)] }
    return [math]::Round(($sorted[$sorted.Count / 2 - 1] + $sorted[$sorted.Count / 2]) / 2, 1)
}
function Measure-TcpConnect([string]$Address, [int]$Port, [int]$TimeoutMs = 2000) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $task = $client.ConnectAsync($Address, $Port)
        if (-not $task.Wait($TimeoutMs)) { return $null }
        $sw.Stop()
        return [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    }
    catch { return $null }
    finally { $client.Dispose() }
}

# WTS API instead of parsing quser: quser output is localized (German headers/states).
if (-not ('ItfWtsHelper' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ItfWtsHelper {
    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSEnumerateSessionsW(IntPtr hServer, int reserved, int version, out IntPtr ppSessionInfo, out int pCount);
    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSQuerySessionInformationW(IntPtr hServer, int sessionId, int infoClass, out IntPtr ppBuffer, out int pBytesReturned);
    [DllImport("wtsapi32.dll")]
    static extern void WTSFreeMemory(IntPtr pMemory);

    [StructLayout(LayoutKind.Sequential)]
    struct WTS_SESSION_INFO { public int SessionId; public IntPtr pWinStationName; public int State; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WTSINFO {
        public int State; public int SessionId;
        public int IncomingBytes; public int OutgoingBytes; public int IncomingFrames; public int OutgoingFrames;
        public int IncomingCompressedBytes; public int OutgoingCompressedBytes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string WinStationName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)] public string Domain;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 21)] public string UserName;
        public long ConnectTime; public long DisconnectTime; public long LastInputTime; public long LogonTime; public long CurrentTime;
    }

    public static List<WTSINFO> GetSessions() {
        var result = new List<WTSINFO>();
        IntPtr pInfo; int count;
        if (!WTSEnumerateSessionsW(IntPtr.Zero, 0, 1, out pInfo, out count)) return result;
        try {
            int size = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
            for (int i = 0; i < count; i++) {
                var si = (WTS_SESSION_INFO)Marshal.PtrToStructure(new IntPtr(pInfo.ToInt64() + i * size), typeof(WTS_SESSION_INFO));
                IntPtr buf; int bytes;
                // 24 = WTSSessionInfo
                if (WTSQuerySessionInformationW(IntPtr.Zero, si.SessionId, 24, out buf, out bytes)) {
                    try { result.Add((WTSINFO)Marshal.PtrToStructure(buf, typeof(WTSINFO))); }
                    finally { WTSFreeMemory(buf); }
                }
            }
        }
        finally { WTSFreeMemory(pInfo); }
        return result;
    }
}
'@
}

# GDI and USER objects per process. Each has a per-process quota (default 10'000) and a
# per-session limit (65'536); running out makes windows, menus and redraws fail or crawl
# in that session only. Not visible in handle counts.
if (-not ('ItfGuiHelper' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ItfGuiHelper {
    [DllImport("kernel32.dll")]
    static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);
    [DllImport("user32.dll")]
    static extern int GetGuiResources(IntPtr hProcess, int flags);

    // Returns { GDI, USER }, or { -1, -1 } if the process can't be opened.
    public static int[] Get(int pid) {
        // 0x1000 = PROCESS_QUERY_LIMITED_INFORMATION
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) return new int[] { -1, -1 };
        try { return new int[] { GetGuiResources(h, 0), GetGuiResources(h, 1) }; }
        finally { CloseHandle(h); }
    }
}
'@
}

$header = @(
    "=== RDS Performance Diagnostic ==="
    "Version: $scriptVersion  |  Computer: $env:COMPUTERNAME  |  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss (dddd)')  |  Sample: ${SampleSeconds}s  |  Events: last $EventDays days"
)

# The detail sections are captured (Write-Host = information stream 6) and printed after
# the findings and history: Syncro truncates long script output, so the summary goes first.
# Dot-sourced so variables set inside stay available for the summary.
$detailOutput = . {

# --- [1/12] System ---
Write-Section "[1/12] System"
$os    = Get-CimInstance Win32_OperatingSystem
$cs    = Get-CimInstance Win32_ComputerSystem
$cores = [int]$cs.NumberOfLogicalProcessors
$totalRamMB = [math]::Round($os.TotalVisibleMemorySize / 1KB)
$uptime = (Get-Date) - $os.LastBootUpTime
$cpuName = (@(Get-CimInstance Win32_Processor)[0].Name -replace '\s+', ' ').Trim()
Write-Host "  OS:          $($os.Caption) (Build $($os.BuildNumber))"
Write-Host "  Hardware:    $($cs.Manufacturer) $($cs.Model)"
Write-Host "  CPU:         $cpuName - $cores logical processors, $($cs.NumberOfProcessors) socket(s)"
# Proxmox/KVM generic CPU models (kvm64, qemu64, x86-64-vX) hide host CPU features from the guest.
if ($cpuName -match 'QEMU|Common KVM|kvm64|qemu64') {
    Add-Finding "WARN" "VM CPU model is generic ('$cpuName'). In Proxmox set CPU type 'host' (or the matching host model) so Windows gets all CPU features."
}
Write-Host "  RAM:         $totalRamMB MB"
Write-Host "  Last boot:   $($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm (dddd)'))  |  uptime $([math]::Round($uptime.TotalDays, 1)) days"

try {
    $rds = Get-CimInstance -Namespace root/cimv2/TerminalServices -ClassName Win32_TerminalServiceSetting -ErrorAction Stop
    if ($rds.TerminalServerMode -ne 1) {
        Write-Host "  NOTE: RD Session Host role not detected (TerminalServerMode=$($rds.TerminalServerMode)). Continuing anyway."
    } else {
        Write-Host "  RDS:         RD Session Host (application server mode)"
    }
} catch { Write-Host "  RDS:         could not read Win32_TerminalServiceSetting" }

$powerScheme = (powercfg /getactivescheme) -join " "
$powerName = switch -Regex ($powerScheme) {
    '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' { "High performance"; break }
    '381b4222-f694-41f0-9685-ffb7d4fd5a56' { "Balanced"; break }
    'a1841308-3541-4fab-bc81-f71556f20b4a' { "Power saver"; break }
    'e9a42b02-d5df-448d-aa00-03f14749eb61' { "Ultimate performance"; break }
    default { "Other: $powerScheme" }
}
Write-Host "  Power plan:  $powerName"
if ($powerName -notmatch 'High performance|Ultimate') {
    Add-Finding "WARN" "Power plan is '$powerName'. On an RDS host 'High performance' avoids CPU clock-down latency (also check the hypervisor/BIOS power profile)."
}

$c2r = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -ErrorAction SilentlyContinue
if ($c2r) {
    Write-Host "  Office C2R:  $($c2r.VersionToReport) $($c2r.Platform), channel $($c2r.CDNBaseUrl -replace '.*/',''), SharedComputerLicensing=$($c2r.SharedComputerLicensing)"
} else {
    Write-Host "  Office C2R:  not found (MSI Office or no Office)"
}

# Syncro agent version (its runner showed a handle leak on HBL-SRV02). Win32_Process instead of
# Get-Process.Path: reading modules of a process with other bitness can fail.
foreach ($sp in Get-CimInstance Win32_Process -Filter "Name LIKE 'Syncro%'" -ErrorAction SilentlyContinue | Sort-Object Name -Unique) {
    $ver = try { (Get-Item $sp.ExecutablePath -ErrorAction Stop).VersionInfo.FileVersion } catch { "unknown" }
    Write-Host "  Syncro:      $($sp.Name) $ver"
}

if ($uptime.TotalDays -gt 6) {
    Add-Finding "INFO" "Uptime is $([math]::Round($uptime.TotalDays, 1)) days. Compare the snapshot history below: if memory/handles/pool degrade with uptime, a leak is likely (weekly reboot = workaround, not fix)."
}

# --- [2/12] CPU, memory, disk sampling ---
Write-Section "[2/12] Sampling CPU / memory / disk for ${SampleSeconds}s"
$procs0 = Get-Process
$cpu0 = @{}
foreach ($p in $procs0) { if ($p.TotalProcessorTime) { $cpu0[$p.Id] = $p.TotalProcessorTime.TotalSeconds } }
$disk0 = @(Get-CimInstance Win32_PerfRawData_PerfDisk_LogicalDisk | Where-Object { $_.Name -match '^[A-Z]:$' })
$sw = [Diagnostics.Stopwatch]::StartNew()

$cpuSamples = @(); $queueSamples = @(); $pagesSamples = @(); $diskQueue = @{}
for ($i = 0; $i -lt $SampleSeconds; $i++) {
    $cpuSamples   += (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
    $queueSamples += (Get-CimInstance Win32_PerfFormattedData_PerfOS_System).ProcessorQueueLength
    $pagesSamples += (Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory).PagesPersec
    foreach ($d in Get-CimInstance Win32_PerfFormattedData_PerfDisk_LogicalDisk | Where-Object { $_.Name -match '^[A-Z]:$' }) {
        if (-not $diskQueue.ContainsKey($d.Name)) { $diskQueue[$d.Name] = @() }
        $diskQueue[$d.Name] += $d.CurrentDiskQueueLength
    }
    Start-Sleep -Seconds 1
}

$elapsed = $sw.Elapsed.TotalSeconds
$procs1 = Get-Process
$disk1 = @(Get-CimInstance Win32_PerfRawData_PerfDisk_LogicalDisk | Where-Object { $_.Name -match '^[A-Z]:$' })

$cpuAvg   = [math]::Round(($cpuSamples   | Measure-Object -Average).Average, 1)
$cpuMax   = ($cpuSamples | Measure-Object -Maximum).Maximum
$queueAvg = [math]::Round(($queueSamples | Measure-Object -Average).Average, 1)
$pagesAvg = [math]::Round(($pagesSamples | Measure-Object -Average).Average)
Write-Host "  CPU total:        avg $cpuAvg %  |  max $cpuMax %"
Write-Host "  Processor queue:  avg $queueAvg (threshold ~2 per core = $(2 * $cores))"
Write-Host "  Pages/sec:        avg $pagesAvg (includes file cache reads, only meaningful together with low available memory)"
if ($cpuAvg -gt 80) { Add-Finding "WARN" "CPU average $cpuAvg % during sampling." }
if ($queueAvg -gt 2 * $cores) { Add-Finding "WARN" "Processor queue avg $queueAvg > 2 x $cores cores: CPU-bound or too few vCPUs." }

# --- [3/12] Memory ---
Write-Section "[3/12] Memory"
$mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
$availMB     = [int]$mem.AvailableMBytes
$commitPct   = [int]$mem.PercentCommittedBytesInUse
$pagedMB     = [math]::Round($mem.PoolPagedBytes / 1MB)
$nonPagedMB  = [math]::Round($mem.PoolNonpagedBytes / 1MB)
Write-Host "  Available:        $availMB MB of $totalRamMB MB ($([math]::Round(100 * $availMB / $totalRamMB)) %)"
Write-Host "  Commit:           $([math]::Round($mem.CommittedBytes / 1GB, 1)) GB of $([math]::Round($mem.CommitLimit / 1GB, 1)) GB ($commitPct %)"
Write-Host "  Paged pool:       $pagedMB MB"
Write-Host "  Non-paged pool:   $nonPagedMB MB"
foreach ($pf in Get-CimInstance Win32_PageFileUsage) {
    Write-Host "  Pagefile:         $($pf.Name) allocated $($pf.AllocatedBaseSize) MB, in use $($pf.CurrentUsage) MB, peak $($pf.PeakUsage) MB"
}
if ($availMB -lt 0.1 * $totalRamMB) { Add-Finding "WARN" "Only $availMB MB RAM available (<10 %). Sessions are swapping." }
if ($commitPct -gt 85) { Add-Finding "WARN" "Commit charge at $commitPct %. Close to the commit limit: add RAM/pagefile or find the leaking process." }
if ($nonPagedMB -gt 1024) { Add-Finding "WARN" "Non-paged pool $nonPagedMB MB (heuristic >1 GB): typical for a driver leak (AV, filter driver, NIC). Compare history." }
if ($pagedMB -gt 4096) { Add-Finding "WARN" "Paged pool $pagedMB MB (heuristic >4 GB): often registry/profile hive or handle leak. Compare history." }

# --- [4/12] Disks ---
Write-Section "[4/12] Disks (latency measured over the sampling window)"
$diskRows = @()
$logical = @{}
foreach ($ld in Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3") { $logical[$ld.DeviceID] = $ld }
foreach ($d1 in $disk1) {
    $d0 = $disk0 | Where-Object { $_.Name -eq $d1.Name } | Select-Object -First 1
    if (-not $d0) { continue }
    $freq = [double]$d1.Frequency_PerfTime
    $rBase = [double]$d1.AvgDisksecPerRead_Base - [double]$d0.AvgDisksecPerRead_Base
    $wBase = [double]$d1.AvgDisksecPerWrite_Base - [double]$d0.AvgDisksecPerWrite_Base
    $readMs  = if ($rBase -gt 0) { [math]::Round(1000 * (([double]$d1.AvgDisksecPerRead - [double]$d0.AvgDisksecPerRead) / $freq) / $rBase, 1) } else { 0 }
    $writeMs = if ($wBase -gt 0) { [math]::Round(1000 * (([double]$d1.AvgDisksecPerWrite - [double]$d0.AvgDisksecPerWrite) / $freq) / $wBase, 1) } else { 0 }
    $ld = $logical[$d1.Name]
    $freePct = if ($ld -and $ld.Size) { [math]::Round(100 * $ld.FreeSpace / $ld.Size) } else { $null }
    $q = $diskQueue[$d1.Name]
    $diskRows += [pscustomobject]@{
        Drive     = $d1.Name
        SizeGB    = if ($ld) { [math]::Round($ld.Size / 1GB) } else { $null }
        FreePct   = $freePct
        ReadMs    = $readMs
        WriteMs   = $writeMs
        Reads     = [int]$rBase
        Writes    = [int]$wBase
        QueueAvg  = if ($q) { [math]::Round(($q | Measure-Object -Average).Average, 1) } else { $null }
    }
    if ($readMs -gt 25 -or $writeMs -gt 25) { Add-Finding "WARN" "Disk $($d1.Name) latency read $readMs ms / write $writeMs ms (>25 ms). Storage is a bottleneck (check host/SAN, AV scanning)." }
    if ($null -ne $freePct -and $freePct -lt 10) { Add-Finding "WARN" "Disk $($d1.Name) only $freePct % free." }
}
Write-Table $diskRows
$cDisk = $diskRows | Where-Object { $_.Drive -eq "C:" } | Select-Object -First 1

# --- [5/12] Sessions ---
Write-Section "[5/12] RDS sessions"
$stateNames = @{ 0 = "Active"; 1 = "Connected"; 2 = "ConnectQuery"; 3 = "Shadow"; 4 = "Disconnected"; 5 = "Idle"; 6 = "Listen"; 7 = "Reset"; 8 = "Down"; 9 = "Init" }
$byProcSession = $procs1 | Group-Object SessionId -AsHashTable -AsString
$gui = @{}
foreach ($p in $procs1) { $gui[$p.Id] = [ItfGuiHelper]::Get($p.Id) }
function Get-GuiSum($Procs, [int]$Index) {
    $sum = 0
    foreach ($p in $Procs) { $v = $gui[$p.Id][$Index]; if ($v -gt 0) { $sum += $v } }
    return $sum
}
$sessionUser = @{}
$sessionRows = @()
try {
    $now = Get-Date
    foreach ($s in [ItfWtsHelper]::GetSessions()) {
        if (-not $s.UserName) { continue }
        $sessionUser["$($s.SessionId)"] = $s.UserName
        $sp = $byProcSession["$($s.SessionId)"]
        $idleMin = $null
        if ($s.State -eq 0 -and $s.LastInputTime -gt 0 -and $s.CurrentTime -gt 0) {
            $idleMin = [math]::Round(($s.CurrentTime - $s.LastInputTime) / 600000000)
        }
        $sessionRows += [pscustomobject]@{
            Id           = $s.SessionId
            User         = $s.UserName
            State        = $stateNames[$s.State]
            LogonTime    = if ($s.LogonTime -gt 0) { [DateTime]::FromFileTime($s.LogonTime).ToString("ddd dd.MM HH:mm") } else { "" }
            IdleMin      = $idleMin
            DiscSince    = if ($s.State -eq 4 -and $s.DisconnectTime -gt 0) { [DateTime]::FromFileTime($s.DisconnectTime).ToString("ddd dd.MM HH:mm") } else { "" }
            DiscHours    = if ($s.State -eq 4 -and $s.DisconnectTime -gt 0) { [math]::Round(($now - [DateTime]::FromFileTime($s.DisconnectTime)).TotalHours, 1) } else { $null }
            Procs        = if ($sp) { $sp.Count } else { 0 }
            PrivateMB    = if ($sp) { [math]::Round(($sp | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB) } else { 0 }
            Handles      = if ($sp) { ($sp | Measure-Object HandleCount -Sum).Sum } else { 0 }
            Gdi          = Get-GuiSum $sp 0
            UserObj      = Get-GuiSum $sp 1
        }
    }
} catch {
    Write-Host "  ERROR reading sessions via WTS API: $($_.Exception.Message)"
}
$activeSessions = @($sessionRows | Where-Object { $_.State -eq "Active" }).Count
$discSessions   = @($sessionRows | Where-Object { $_.State -eq "Disconnected" })
Write-Host "  Sessions with user: $($sessionRows.Count)  |  active: $activeSessions  |  disconnected: $($discSessions.Count)"
Write-Table ($sessionRows | Sort-Object PrivateMB -Descending)
$staleDisc = @($discSessions | Where-Object { $_.DiscHours -gt 8 })
foreach ($s in $sessionRows | Where-Object { $_.Gdi -gt 40000 -or $_.UserObj -gt 40000 }) {
    Add-Finding "WARN" "Session $($s.Id) ($($s.User)) uses $($s.Gdi) GDI / $($s.UserObj) USER objects (session limit 65'536 each): the session gets sluggish before it fails. Find the process in the GDI/USER top list."
}
if ($staleDisc.Count -gt 0) {
    Add-Finding "WARN" "$($staleDisc.Count) session(s) disconnected for >8 h ($(($staleDisc.User) -join ', ')). They keep processes, memory and file locks. Set an RDS limit 'End a disconnected session' (GPO: Session Time Limits)."
}

# --- [6/12] Processes ---
Write-Section "[6/12] Processes (CPU over sampling window, memory, handles)"
$procRows = foreach ($p in $procs1) {
    $cpuPct = $null
    if ($cpu0.ContainsKey($p.Id) -and $p.TotalProcessorTime) {
        $cpuPct = [math]::Round(100 * ($p.TotalProcessorTime.TotalSeconds - $cpu0[$p.Id]) / $elapsed / $cores, 1)
    }
    $ageH = $null
    try { if ($p.StartTime) { $ageH = [math]::Round(((Get-Date) - $p.StartTime).TotalHours) } } catch {}
    [pscustomobject]@{
        Name      = $p.ProcessName
        PID       = $p.Id
        Session   = $p.SessionId
        User      = $sessionUser["$($p.SessionId)"]
        CpuPct    = $cpuPct
        PrivateMB = [math]::Round($p.PrivateMemorySize64 / 1MB)
        Handles   = $p.HandleCount
        Threads   = $p.Threads.Count
        Gdi       = if ($gui[$p.Id][0] -ge 0) { $gui[$p.Id][0] } else { $null }
        UserObj   = if ($gui[$p.Id][1] -ge 0) { $gui[$p.Id][1] } else { $null }
        AgeHours  = $ageH
    }
}
$totalHandles = ($procRows | Measure-Object Handles -Sum).Sum
$totalThreads = ($procRows | Measure-Object Threads -Sum).Sum
$totalGdi     = ($procRows | Measure-Object Gdi -Sum).Sum
$totalUserObj = ($procRows | Measure-Object UserObj -Sum).Sum
$syncroLiveH  = ($procRows | Where-Object { $_.Name -eq "SyncroLive.Agent.Runner" } | Measure-Object Handles -Maximum).Maximum
Write-Host "  Processes: $($procRows.Count)  |  handles: $totalHandles  |  threads: $totalThreads  |  GDI: $totalGdi  |  USER: $totalUserObj"
Write-Host ""
Write-Host "  Top 10 by CPU (% of all cores):"
Write-Table ($procRows | Where-Object { $_.PID -ne 0 } | Sort-Object CpuPct -Descending | Select-Object -First 10)
Write-Host ""
Write-Host "  Top 10 by private memory:"
Write-Table ($procRows | Sort-Object PrivateMB -Descending | Select-Object -First 10)
Write-Host ""
Write-Host "  Top 10 by handles:"
Write-Table ($procRows | Sort-Object Handles -Descending | Select-Object -First 10)
Write-Host ""
Write-Host "  Top 10 by GDI + USER objects (per-process quota 10'000 each):"
Write-Table ($procRows | Sort-Object { $_.Gdi + $_.UserObj } -Descending | Select-Object -First 10)

Write-Host ""
Write-Host "  Memory per process name (all sessions, top 15):"
Write-Table ($procRows | Group-Object Name | ForEach-Object {
    [pscustomobject]@{
        Name      = $_.Name
        Count     = $_.Count
        PrivateMB = ($_.Group | Measure-Object PrivateMB -Sum).Sum
        Handles   = ($_.Group | Measure-Object Handles -Sum).Sum
        CpuPct    = [math]::Round(($_.Group | Measure-Object CpuPct -Sum).Sum, 1)
    }
} | Sort-Object PrivateMB -Descending | Select-Object -First 15)

foreach ($p in $procRows | Where-Object { $_.Handles -gt 20000 -and $_.PID -ne 4 }) {
    Add-Finding "WARN" "$($p.Name) (PID $($p.PID), session $($p.Session), age $($p.AgeHours) h) holds $($p.Handles) handles: leak candidate."
}
foreach ($p in $procRows | Where-Object { $_.Gdi -ge 8000 -or $_.UserObj -ge 8000 }) {
    Add-Finding "WARN" "$($p.Name) (PID $($p.PID), $($p.User), age $($p.AgeHours) h) uses $($p.Gdi) GDI / $($p.UserObj) USER objects, near the per-process quota of 10'000: it will stop drawing windows/menus. Restart that app."
}
$explorer = @($procRows | Where-Object { $_.Name -eq "explorer" })
if ($explorer.Count -gt 0) {
    $exMaxH = ($explorer | Measure-Object Handles -Maximum).Maximum
    $exMaxM = ($explorer | Measure-Object PrivateMB -Maximum).Maximum
    Write-Host ""
    Write-Host "  explorer.exe: $($explorer.Count) instances, max handles $exMaxH, max private $exMaxM MB"
    if ($exMaxH -gt 10000) { Add-Finding "WARN" "An explorer.exe holds $exMaxH handles (normal: a few thousand). Shell extension or network path leak; check which session." }
}

# --- [7/12] Explorer extensions / Office add-ins ---
Write-Section "[7/12] Explorer extensions and Office add-ins (session-side suspects)"
# Third-party DLLs actually loaded into explorer.exe (shell extensions, overlay handlers,
# preview handlers). Reading modules of a 64-bit explorer needs a 64-bit PowerShell.
if ([Environment]::Is64BitProcess) {
    $moduleUse = @{}
    foreach ($ex in Get-Process -Name explorer -ErrorAction SilentlyContinue) {
        try {
            foreach ($m in $ex.Modules) {
                $company = "$($m.FileVersionInfo.CompanyName)".Trim()
                if ($company -match 'Microsoft') { continue }
                $key = $m.FileName.ToLower()
                if (-not $moduleUse.ContainsKey($key)) {
                    $moduleUse[$key] = [pscustomobject]@{
                        Module   = $m.ModuleName
                        Company  = $company
                        Version  = $m.FileVersionInfo.FileVersion
                        Sessions = 0
                        Path     = $m.FileName
                    }
                }
                $moduleUse[$key].Sessions++
            }
        } catch {
            Write-Host "  Could not read modules of explorer PID $($ex.Id): $($_.Exception.Message)"
        }
    }
    Write-Host "  Non-Microsoft DLLs loaded in explorer.exe ($($moduleUse.Count)), Sessions = number of explorer instances:"
    Write-Table ($moduleUse.Values | Sort-Object Company, Module)
} else {
    Write-Host "  Skipped explorer module scan: PowerShell runs as 32-bit process."
}

# Icon overlay handlers: Windows only uses the first 15 (sorted by name), extras are ignored
# but still registered; each one is called for every file icon Explorer draws.
$overlayKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers"
$overlays = @(Get-ChildItem $overlayKey -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PSChildName)
Write-Host ""
Write-Host "  Icon overlay handlers: $($overlays.Count) (Windows uses the first 15): $(($overlays | ForEach-Object { $_.Trim() }) -join ', ')"

# Office COM add-ins: machine-wide (64-bit, WOW6432Node for 32-bit Office, Click-to-Run
# virtual registry) and per user from the loaded hives.
# LoadBehavior: 3 = load at startup, 2 = off, 9 = load on demand, 16 = first run only;
# a user value overrides the machine value.
$addinRows = @()
$c2rRoot = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\REGISTRY\MACHINE\Software"
foreach ($app in "Outlook", "Word", "Excel") {
    $machineRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Office\$app\Addins",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\$app\Addins",
        "$c2rRoot\Microsoft\Office\$app\Addins",
        "$c2rRoot\Wow6432Node\Microsoft\Office\$app\Addins"
    )
    foreach ($root in $machineRoots) {
        foreach ($a in Get-ChildItem $root -ErrorAction SilentlyContinue) {
            $props = Get-ItemProperty $a.PSPath -ErrorAction SilentlyContinue
            $addinRows += [pscustomobject]@{ App = $app; ProgId = $a.PSChildName; Name = $props.FriendlyName; Scope = "Machine"; LoadBehavior = $props.LoadBehavior }
        }
    }
    foreach ($hive in Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' }) {
        $user = try { (New-Object System.Security.Principal.SecurityIdentifier($hive.PSChildName)).Translate([System.Security.Principal.NTAccount]).Value -replace '^.*\\', '' } catch { $hive.PSChildName }
        foreach ($a in Get-ChildItem "Registry::$($hive.Name)\Software\Microsoft\Office\$app\Addins" -ErrorAction SilentlyContinue) {
            $props = Get-ItemProperty $a.PSPath -ErrorAction SilentlyContinue
            $addinRows += [pscustomobject]@{ App = $app; ProgId = $a.PSChildName; Name = $props.FriendlyName; Scope = $user; LoadBehavior = $props.LoadBehavior }
        }
    }
}
Write-Host ""
Write-Host "  Office COM add-ins (LoadBehavior 3 = loads at startup, 2 = off; user overrides machine):"
Write-Table ($addinRows | Group-Object App, ProgId | ForEach-Object {
    $g = $_.Group
    $machine = $g | Where-Object { $_.Scope -eq "Machine" } | Select-Object -First 1
    $users = @($g | Where-Object { $_.Scope -ne "Machine" })
    [pscustomobject]@{
        App          = $g[0].App
        ProgId       = $g[0].ProgId
        Name         = ($g | Where-Object Name | Select-Object -First 1).Name
        Machine      = if ($machine) { $machine.LoadBehavior } else { "" }
        UsersOn      = @($users | Where-Object { $_.LoadBehavior -eq 3 }).Count
        UsersOff     = @($users | Where-Object { $_.LoadBehavior -ne 3 }).Count
        UserValues   = ($users | ForEach-Object { "$($_.Scope)=$($_.LoadBehavior)" }) -join ' '
    }
} | Sort-Object App, ProgId)

# --- [8/12] Printing ---
Write-Section "[8/12] Printing"
$printers = @(Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue)
# RDP-redirected printers use TSxxx ports.
$redirected = @($printers | Where-Object { $_.PortName -like "TS*" })
$drivers = @(Get-CimInstance Win32_PrinterDriver -ErrorAction SilentlyContinue)
$spooler = $procRows | Where-Object { $_.Name -eq "spoolsv" } | Select-Object -First 1
Write-Host "  Printers: $($printers.Count)  |  redirected (TS ports): $($redirected.Count)  |  drivers: $($drivers.Count)"
if ($spooler) { Write-Host "  spoolsv.exe: private $($spooler.PrivateMB) MB, handles $($spooler.Handles), age $($spooler.AgeHours) h" }
Write-Host "  Printer drivers:"
Write-Table ($drivers | ForEach-Object { [pscustomobject]@{ Driver = ($_.Name -split ',')[0] } } | Sort-Object Driver -Unique)
if ($redirected.Count -gt [math]::Max(20, 3 * [math]::Max(1, $activeSessions + $discSessions.Count))) {
    Add-Finding "WARN" "$($redirected.Count) redirected printers for $($sessionRows.Count) sessions. Office/Foxit enumerate printers on open/print; consider disabling client printer redirection or limiting it to the default printer."
}
if ($spooler -and ($spooler.Handles -gt 10000 -or $spooler.PrivateMB -gt 1024)) {
    Add-Finding "WARN" "Spooler is large ($($spooler.PrivateMB) MB, $($spooler.Handles) handles). Slow spooler slows Office/PDF app start; check drivers, restart spooler as a test."
}
if ($drivers.Count -gt 40) { Add-Finding "INFO" "$($drivers.Count) printer drivers installed. Many vendor (non-universal) drivers on RDS are a known source of spooler problems." }

# --- [9/12] Profiles ---
Write-Section "[9/12] User profiles"
$profiles = @(Get-CimInstance Win32_UserProfile -Filter "Special=False" -ErrorAction SilentlyContinue)
$tempProfiles = @($profiles | Where-Object { $_.LocalPath -match '\\TEMP' })
$bakProfiles = @(Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "*.bak" })
Write-Host "  Local profiles: $($profiles.Count)  |  loaded: $(@($profiles | Where-Object Loaded).Count)  |  temp: $($tempProfiles.Count)  |  .bak in ProfileList: $($bakProfiles.Count)"
foreach ($bak in $bakProfiles) {
    $sid = $bak.PSChildName -replace '\.bak$', ''
    $account = try { (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { "unresolved" }
    Write-Host "    .bak: $account ($sid) -> $((Get-ItemProperty $bak.PSPath -ErrorAction SilentlyContinue).ProfileImagePath)"
}
foreach ($t in $tempProfiles) { Write-Host "    temp: $($t.LocalPath) ($($t.SID))" }
$fslogix = Get-Service -Name frxsvc -ErrorAction SilentlyContinue
Write-Host "  FSLogix: $(if ($fslogix) { "installed, service $($fslogix.Status)" } else { 'not installed' })"
$upd = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\ClusterSettings" -ErrorAction SilentlyContinue
if ($upd -and $upd.UvhdEnabled) { Write-Host "  User Profile Disks: enabled ($($upd.UvhdShareUrl))" }
if ($tempProfiles.Count -gt 0 -or $bakProfiles.Count -gt 0) {
    Add-Finding "WARN" "Temp profiles ($($tempProfiles.Count)) or .bak ProfileList entries ($($bakProfiles.Count)) found: broken profiles."
}

# --- [10/12] Network / file servers ---
Write-Section "[10/12] Network, file servers, domain controllers"
foreach ($nic in Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq "Up") {
    Write-Host "  NIC: $($nic.Name) - $($nic.InterfaceDescription) - $($nic.LinkSpeed)"
}
$publicDns = @()
foreach ($dns in Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses }) {
    Write-Host "  DNS ($($dns.InterfaceAlias)): $($dns.ServerAddresses -join ', ')"
    $publicDns += @($dns.ServerAddresses | Where-Object { -not (Test-PrivateIp $_) })
}
if ($publicDns.Count -gt 0) {
    Add-Finding "WARN" "Public DNS server(s) on a NIC ($(($publicDns | Sort-Object -Unique) -join ', ')). In a domain this causes slow/failed lookups of DCs and file servers; use only internal DNS."
}

$localShares = @(Get-SmbShare -Special $false -ErrorAction SilentlyContinue)
if ($localShares.Count -gt 0) {
    Write-Host "  Shares hosted on THIS server: $(($localShares.Name) -join ', ')"
}

# File servers: users' mapped drives from loaded hives plus current SMB connections.
# Get-SmbConnection as SYSTEM may not list other users' connections, so the hives are the main source.
$servers = @{}
foreach ($hive in Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' }) {
    foreach ($drive in Get-ChildItem "Registry::$($hive.Name)\Network" -ErrorAction SilentlyContinue) {
        $remote = (Get-ItemProperty $drive.PSPath -ErrorAction SilentlyContinue).RemotePath
        if ($remote -match '^\\\\([^\\]+)\\') { $servers[$Matches[1].ToLower()] = "mapped drive" }
    }
}
foreach ($c in Get-SmbConnection -ErrorAction SilentlyContinue) {
    if ($c.ServerName -and -not $servers.ContainsKey($c.ServerName.ToLower())) { $servers[$c.ServerName.ToLower()] = "SMB connection" }
}
$dcs = @()
if ($cs.PartOfDomain) {
    try {
        $dcs = @(Resolve-DnsName "_ldap._tcp.dc._msdcs.$($cs.Domain)" -Type SRV -ErrorAction Stop | Where-Object { $_.Type -eq "SRV" } | Select-Object -ExpandProperty NameTarget -Unique)
    } catch { Write-Host "  ERROR: DC SRV lookup for $($cs.Domain) failed: $($_.Exception.Message)" }
}

$latencyRows = @()
$targets = @()
foreach ($k in $servers.Keys) { $targets += [pscustomobject]@{ Host = $k; Role = $servers[$k]; Port = 445 } }
foreach ($dc in $dcs) { $targets += [pscustomobject]@{ Host = $dc; Role = "domain controller"; Port = 389 } }
foreach ($t in $targets) {
    $dnsMs = $null; $ip = $null
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ip = [System.Net.Dns]::GetHostAddresses($t.Host) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        $dnsMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    } catch {}
    $tcp = @()
    if ($ip) {
        # First connect is discarded: it includes .NET/socket warm-up, not network latency.
        Measure-TcpConnect $ip.IPAddressToString $t.Port | Out-Null
        for ($i = 0; $i -lt 5; $i++) { $tcp += Measure-TcpConnect $ip.IPAddressToString $t.Port }
    }
    $ok = @($tcp | Where-Object { $null -ne $_ })
    $median = Get-Median $ok
    $latencyRows += [pscustomobject]@{
        Host = $t.Host; Role = $t.Role; IP = if ($ip) { $ip.IPAddressToString } else { "unresolved" }
        DnsMs = $dnsMs; Port = $t.Port; TcpMedianMs = $median
        TcpMinMaxMs = if ($ok.Count) { "$(($ok | Measure-Object -Minimum).Minimum)/$(($ok | Measure-Object -Maximum).Maximum)" } else { "" }
        TcpOk = "$($ok.Count)/5"
    }
    if (-not $ip) { Add-Finding "WARN" "$($t.Role) '$($t.Host)' does not resolve. Dead mapped drive / stale DNS: Explorer and Office dialogs wait for timeouts." }
    elseif ($ok.Count -lt 5) { Add-Finding "WARN" "$($t.Role) '$($t.Host)' port $($t.Port) not reachable in $(5 - $ok.Count)/5 attempts. Explorer and Office dialogs hang on unreachable paths." }
    elseif ($median -gt 5) { Add-Finding "WARN" "$($t.Role) '$($t.Host)' TCP connect median $median ms (LAN should be <1-2 ms)." }
    if ($dnsMs -gt 200) { Add-Finding "WARN" "DNS lookup of '$($t.Host)' took $dnsMs ms." }
}
Write-Table $latencyRows

# --- [11/12] AV / search ---
Write-Section "[11/12] Antivirus, Windows Search"
$avServices = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Bitdefender|Sophos|ESET|Kaspersky|Trend Micro|SentinelOne|CrowdStrike|Symantec|McAfee|Trellix|G DATA|Avast|AVG|Panda|WithSecure|F-Secure' } | Where-Object Status -eq "Running")
if ($avServices.Count) { Write-Host "  Third-party AV services running: $(($avServices.DisplayName | Sort-Object -Unique) -join ', ')" }
else { Write-Host "  Third-party AV services: none detected" }
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    Write-Host "  Defender: mode $($mp.AMRunningMode), real-time $($mp.RealTimeProtectionEnabled)"
    if ($avServices.Count -and $mp.AMRunningMode -eq "Normal" -and $mp.RealTimeProtectionEnabled) {
        Add-Finding "WARN" "Defender real-time protection is active alongside a third-party AV. On Windows Server Defender does not switch to passive mode automatically: every file is scanned twice."
    }
} catch { Write-Host "  Defender: not available" }
$search = Get-Service -Name WSearch -ErrorAction SilentlyContinue
Write-Host "  Windows Search: $(if ($search) { "$($search.Status) ($($search.StartType))" } else { 'not installed' })"
if (-not $search -or $search.Status -ne "Running") {
    Add-Finding "INFO" "Windows Search is not running: Outlook and Explorer search fall back to slow non-indexed search."
}

# --- [12/12] Event logs ---
Write-Section "[12/12] Event logs (last $EventDays days)"
$since = (Get-Date).AddDays(-$EventDays)
function Get-Events([hashtable]$Filter) {
    $Filter["StartTime"] = $since
    return @(Get-WinEvent -FilterHashtable $Filter -MaxEvents 5000 -ErrorAction SilentlyContinue)
}
$evResource = Get-Events @{ LogName = "System"; ProviderName = "Microsoft-Windows-Resource-Exhaustion-Detector"; Id = 2004 }
$evProfile  = Get-Events @{ LogName = "Application"; ProviderName = "Microsoft-Windows-User Profiles Service"; Id = 1530 }
$evDisk     = @(Get-Events @{ LogName = "System"; Id = 129, 153, 7, 51 } | Where-Object { $_.ProviderName -match '^disk$|stor|scsi|nvme|ahci|iaStor|mpio|LSI' })   # 153 is also Kernel-Boot (VBS state), 7/51 also other providers
$evHang     = Get-Events @{ LogName = "Application"; ProviderName = "Application Hang"; Id = 1002 }
$evCrash    = Get-Events @{ LogName = "Application"; ProviderName = "Application Error"; Id = 1000 }
$evService  = Get-Events @{ LogName = "System"; ProviderName = "Service Control Manager"; Id = 7031, 7034 }
$evShutdown = Get-Events @{ LogName = "System"; Id = 6008 }
$evPrint    = Get-Events @{ LogName = "Microsoft-Windows-PrintService/Admin"; Level = 2 }

Write-Table @(
    [pscustomobject]@{ Event = "Resource exhaustion (2004, low virtual memory)"; Count = $evResource.Count }
    [pscustomobject]@{ Event = "User profile registry handle leak (1530)";      Count = $evProfile.Count }
    [pscustomobject]@{ Event = "Disk/storage timeouts or retries (129/153/7/51)"; Count = $evDisk.Count }
    [pscustomobject]@{ Event = "Application hangs (1002)";                       Count = $evHang.Count }
    [pscustomobject]@{ Event = "Application crashes (1000)";                     Count = $evCrash.Count }
    [pscustomobject]@{ Event = "Service crashes (7031/7034)";                    Count = $evService.Count }
    [pscustomobject]@{ Event = "Unexpected shutdowns (6008)";                    Count = $evShutdown.Count }
    [pscustomobject]@{ Event = "PrintService errors";                            Count = $evPrint.Count }
)
if ($evDisk.Count) {
    Write-Host ""
    Write-Host "  Disk/storage events (newest 10):"
    Write-Table ($evDisk | Select-Object -First 10 | ForEach-Object {
        $msg = (("$($_.Message)" -split "`r?`n")[0] -replace '\s+', ' ').Trim()
        if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) }
        [pscustomobject]@{
            Time     = $_.TimeCreated.ToString("ddd dd.MM HH:mm")
            Provider = $_.ProviderName
            Id       = $_.Id
            Message  = $msg
        }
    })
}
if ($evHang.Count) {
    Write-Host ""
    Write-Host "  Hangs per application:"
    Write-Table ($evHang | Group-Object { $_.Properties[0].Value } | Sort-Object Count -Descending | Select-Object -First 10 Count, Name)
}
if ($evCrash.Count) {
    Write-Host ""
    Write-Host "  Crashes per application / faulting module:"
    Write-Table ($evCrash | Group-Object { "$($_.Properties[0].Value) / $($_.Properties[3].Value)" } | Sort-Object Count -Descending | Select-Object -First 10 Count, Name)
}
if ($evService.Count) {
    Write-Host ""
    Write-Host "  Crashed services:"
    Write-Table ($evService | Group-Object { $_.Properties[0].Value } | Sort-Object Count -Descending | Select-Object -First 10 Count, Name)
}
if ($evResource.Count) { Add-Finding "WARN" "$($evResource.Count) resource exhaustion events (2004): the server ran out of commit memory. The event text names the top consumers." }
if ($evProfile.Count)  { Add-Finding "WARN" "$($evProfile.Count) events 1530 (profile hive still in use at logoff): registry leaks that grow paged pool over days; the event names the process holding the handles." }
if ($evDisk.Count)     { Add-Finding "WARN" "$($evDisk.Count) disk/storage timeout events: check storage/host." }
if ($evHang.Count -gt 20) { Add-Finding "WARN" "$($evHang.Count) application hangs in $EventDays days, see event log section." }

} 6>&1

# --- Snapshot ---
$snapshot = [pscustomobject]@{
    Time            = (Get-Date).ToString("yyyy-MM-dd HH:mm")
    UptimeDays      = [math]::Round($uptime.TotalDays, 1)
    CpuAvg          = $cpuAvg
    AvailMB         = $availMB
    CommitPct       = $commitPct
    PagedMB         = $pagedMB
    NonPagedMB      = $nonPagedMB
    Handles         = $totalHandles
    GdiTotal        = $totalGdi
    UserObjTotal    = $totalUserObj
    SyncroLiveH     = $syncroLiveH
    Procs           = $procRows.Count
    SessAct         = $activeSessions
    SessDisc        = $discSessions.Count
    Printers        = $printers.Count
    RedirPrn        = $redirected.Count
    SpoolHandles    = if ($spooler) { $spooler.Handles } else { $null }
    ExplMaxHandles  = if ($explorer.Count) { ($explorer | Measure-Object Handles -Maximum).Maximum } else { $null }
    CReadMs         = if ($cDisk) { $cDisk.ReadMs } else { $null }
    CWriteMs        = if ($cDisk) { $cDisk.WriteMs } else { $null }
    Sessions        = @($sessionRows | ForEach-Object {
        [pscustomobject]@{ User = $_.User; Logon = $_.LogonTime; Handles = $_.Handles; Gdi = $_.Gdi; UserObj = $_.UserObj; PrivateMB = $_.PrivateMB }
    })
}
$history = @()
$snapshotError = $null
try {
    $snapshot | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $dataDir "snapshot_$timestamp.json") -Encoding UTF8
    $history = @(Get-ChildItem $dataDir -Filter "snapshot_*.json" | Sort-Object Name | Select-Object -Last 10 | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
} catch {
    $snapshotError = $_.Exception.Message
}

# One row per current session user, one column per run (last 6 runs with session data).
# A session that gets slow while its numbers climb points to the app to restart.
function Get-SessionTrend($History) {
    $runs = @($History | Where-Object { $_.PSObject.Properties['Sessions'] } | Select-Object -Last 6)
    if ($runs.Count -eq 0) { return $null }
    foreach ($s in $runs[-1].Sessions | Sort-Object Handles -Descending) {
        $row = [ordered]@{ User = $s.User }
        $prevLogon = $null
        foreach ($r in $runs) {
            $x = @($r.Sessions | Where-Object { $_.User -eq $s.User })[0]
            $col = $r.Time.Substring(5)
            if (-not $x) { $row[$col] = "-"; $prevLogon = $null; continue }
            $mark = if ($prevLogon -and $x.Logon -ne $prevLogon) { "*" } else { "" }
            $row[$col] = "$mark$([math]::Round($x.Handles / 1000, 1))/$($x.Gdi)/$($x.UserObj)"
            $prevLogon = $x.Logon
        }
        [pscustomobject]$row
    }
}

# --- Output: summary first, then details ---
$summaryOutput = . {
    $header | ForEach-Object { Write-Host $_ }
    Write-Section "Findings (heuristic, verify before acting)"
    if ($findings.Count -eq 0) { Write-Host "  No threshold exceeded in this run. Compare the snapshot history across the week." }
    else { Write-Table ($findings | Sort-Object { if ($_.Severity -eq "WARN") { 0 } else { 1 } }) }
    Write-Section "Snapshot history (last 10 runs, oldest first)"
    if ($snapshotError) { Write-Host "  ERROR saving/reading snapshots: $snapshotError" }
    else {
        Write-Table ($history | Select-Object Time, UptimeDays, CpuAvg, AvailMB, CommitPct, PagedMB, NonPagedMB, Handles, GdiTotal, UserObjTotal, SyncroLiveH, SessAct, SessDisc)
        Write-Section "Per-session trend (handles in k / GDI / USER, * = new logon since previous run)"
        Write-Table (Get-SessionTrend $history)
    }
    Write-Host ""
    Write-Host "  Full report: $reportPath"
    Write-Host ""
    Write-Host "##################### DETAILS #####################"
} 6>&1

$report = @($summaryOutput) + @($detailOutput) | ForEach-Object { "$_" }

# Write and upload before printing, so the upload status is the first line of the
# (truncated) Syncro output.
$uploadStatus = "Report upload: disabled (-Upload 0)"
try {
    $report | Set-Content -Path $reportPath -Encoding UTF8
    foreach ($pattern in "snapshot_*.json", "report_*.txt") {
        Get-ChildItem $dataDir -Filter $pattern | Sort-Object LastWriteTime -Descending | Select-Object -Skip $keepRuns | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    if ($Upload -eq 1) {
        if (Get-Command Upload-File -ErrorAction SilentlyContinue) {
            Upload-File -FilePath $reportPath
            $uploadStatus = "Report upload: OK, $(Split-Path $reportPath -Leaf) attached to the asset (Syncro truncates this output)"
        } else {
            $uploadStatus = "Report upload: skipped, Upload-File not available (not run by Syncro)"
        }
    }
} catch {
    $uploadStatus = "Report upload: FAILED ($($_.Exception.Message)). Report is on the server: $reportPath"
}

Write-Host $uploadStatus
$report | ForEach-Object { Write-Host $_ }

exit 0
