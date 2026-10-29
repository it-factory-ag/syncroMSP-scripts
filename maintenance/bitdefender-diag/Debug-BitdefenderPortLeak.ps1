<#
.SYNOPSIS
  Diagnose fuer TCP-Port-Erschoepfung durch Bitdefender GravityZone (EPSecurityService).
  Sammelt Zeitreihe ab Boot + statische Daten und packt alles in ein ZIP fuer den Bitdefender-Support.

.DESCRIPTION
  Sobald die Ports voll sind, kann auch der Syncro-Agent keine neuen Verbindungen mehr aufbauen.
  Deshalb arbeitet das Script in drei Modi:

  -Mode Install  (via Syncro, Standard)
      Kopiert dieses Script nach C:\ProgramData\BDDiag\ und registriert einen einmaligen
      Scheduled Task (SYSTEM, beim Systemstart), der -Mode Collect ausfuehrt. Optional -Reboot 1.
  -Mode Collect  (laeuft lokal per Task beim Boot, ohne Netz-/Syncro-Abhaengigkeit)
      1. Monitoring ab Boot (Standard 15 min, alle 10 s): Verbindungen EPSecurityService nach Status,
         belegte/freie dynamische Ports pro IPv4/IPv6, Handles, NonPaged Pool.
         Jede Minute ein kurzer TCP/443-Test zu den Bitdefender-Zielen, zusammen mit der Anzahl
         freier Ports -> trennt "Netz blockiert" von "lokale Ports voll".
         Zusaetzlich ein Kontrollziel (-ControlTarget), um "alles blockiert" zu erkennen.
         Paketmitschnitt (pktmon) zu den Zielen, abschaltbar mit -Capture 0.
      2. Danach statische Daten: Bitdefender-Version/Update-Status, Dienste, Dateien, Logs,
         Treiber/WFP, Netzwerk-Konfiguration, Ereignisprotokolle, Installationen der letzten Tage.
      3. Zusammenfassung + ZIP. Der Task entfernt sich danach selbst.
  -Mode Upload   (via Syncro, wenn das Geraet wieder erreichbar ist, z.B. Agent in GZ deaktiviert)
      Haengt das neueste ZIP per Upload-File an das Syncro-Asset.

  Lokaler Lauf ohne Syncro ist moeglich (Import-Module nur, wenn $env:SyncroModule gesetzt ist):
    powershell -ExecutionPolicy Bypass -File .\Debug-BitdefenderPortLeak.ps1 -Mode Collect -MonitorMinutes 5
  Kein Mock-Modul: Collect ruft keine Syncro-Funktionen auf, Install/Upload sind trivial.

  Exit-Codes: 0 = ok / nicht anwendbar, 1 = Fehler.
#>
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Collect', 'Upload')]
    [string]$Mode            = 'Install',
    [int]$MonitorMinutes     = 15,
    [int]$IntervalSeconds    = 10,
    [int]$Capture            = 1,
    [int]$Reboot             = 0,
    [int]$EventDays          = 14,
    [string]$Targets         = '34.120.68.241,34.54.215.149',
    [string]$ControlTarget   = '1.1.1.1',
    [string]$OutRoot         = 'C:\ProgramData\BDDiag'
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

if ($env:SyncroModule) { Import-Module $env:SyncroModule }

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$TaskName      = 'ITFactory-BDDiag-Collect'
$LocalScript   = Join-Path $OutRoot 'Debug-BitdefenderPortLeak.ps1'
$AlertCategory = 'Bitdefender Diag'
$BdProcName    = 'EPSecurityService'
$uninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'

function Send-Alert([string]$msg) {
    Write-Host "ERROR: $msg"
    if (Get-Command Rmm-Alert -ErrorAction SilentlyContinue) { Rmm-Alert -Category $AlertCategory -Body $msg }
}

# =====================================================================
# Mode Install
# =====================================================================
if ($Mode -eq 'Install') {
    $svc = Get-Service -Name EPSecurityService -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host "Bitdefender EPSecurityService nicht gefunden - Script nicht anwendbar."
        exit 0
    }
    try {
        New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null
        if ($PSCommandPath -ne $LocalScript) { Copy-Item -Path $PSCommandPath -Destination $LocalScript -Force }

        $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$LocalScript`" -Mode Collect " +
               "-MonitorMinutes $MonitorMinutes -IntervalSeconds $IntervalSeconds -Capture $Capture " +
               "-EventDays $EventDays -Targets `"$Targets`" -ControlTarget `"$ControlTarget`" -OutRoot `"$OutRoot`""
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -ExecutionTimeLimit (New-TimeSpan -Hours 2) -Hidden
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
            -Settings $settings -Force -ErrorAction Stop | Out-Null

        Write-Host "Task '$TaskName' registriert. Beim naechsten Boot laeuft die Sammlung ($MonitorMinutes min Monitoring + statische Daten)."
        Write-Host "Ergebnis: $OutRoot\<COMPUTERNAME>_<Zeit>.zip - danach mit -Mode Upload an das Asset haengen."
        if ($Reboot -eq 1) {
            Write-Host "Neustart in 60 s."
            shutdown.exe /r /t 60 /c "IT Factory: Neustart fuer Bitdefender-Diagnose" | Out-Null
        }
        exit 0
    } catch {
        Send-Alert "Install fehlgeschlagen: $($_.Exception.Message)"
        exit 1
    }
}

# =====================================================================
# Mode Upload
# =====================================================================
if ($Mode -eq 'Upload') {
    $zip = Get-ChildItem -Path $OutRoot -Filter '*.zip' -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $zip) {
        Send-Alert "Kein ZIP in $OutRoot gefunden. Lief der Collect-Task schon? Siehe $OutRoot\collect_task.log"
        exit 1
    }
    Write-Host "Lade hoch: $($zip.FullName) ($([math]::Round($zip.Length/1MB,1)) MB)"
    try {
        Upload-File -FilePath $zip.FullName
        Write-Host "Upload ok."
        exit 0
    } catch {
        Send-Alert "Upload von $($zip.Name) fehlgeschlagen: $($_.Exception.Message)"
        exit 1
    }
}

# =====================================================================
# Mode Collect
# =====================================================================
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$out   = Join-Path $OutRoot "$($env:COMPUTERNAME)_$stamp"
New-Item -ItemType Directory -Path $out -Force | Out-Null
"[$(Get-Date -Format s)] Collect gestartet -> $out" | Add-Content (Join-Path $OutRoot 'collect_task.log')
Start-Transcript -Path (Join-Path $out '00_transcript.txt') | Out-Null

$targetList = @($Targets -split '[,; ]+' | Where-Object { $_ })

# ---------- Hilfsfunktionen ----------
function Step([string]$name, [scriptblock]$sb) {
    Write-Host "[$(Get-Date -Format T)] $name ..."
    try { & $sb }
    catch { "[$(Get-Date -Format s)] FEHLER in '$name': $_" | Add-Content (Join-Path $out '00_errors.txt') }
}
function Save([string]$file, $data) {
    $data | Out-File -FilePath (Join-Path $out $file) -Encoding UTF8 -Width 4096
}
function SaveCsv([string]$file, $data) {
    if ($data) { $data | Export-Csv -Path (Join-Path $out $file) -NoTypeInformation -Encoding UTF8 -Delimiter ';' }
}
function AppendCsv([string]$file, $data) {
    $data | Export-Csv -Path (Join-Path $out $file) -Append -NoTypeInformation -Encoding UTF8 -Delimiter ';'
}

# netsh-Ausgabe ist lokalisiert ("Start Port"/"Startport") -> nur die ersten zwei Zahlen lesen
function Get-DynRange([string]$family) {
    $nums = @((netsh int $family show dynamicport tcp) -join ' ' | Select-String -Pattern '\d+' -AllMatches |
              ForEach-Object { $_.Matches.Value })
    if ($nums.Count -ge 2) { [pscustomobject]@{ Start = [int]$nums[0]; Count = [int]$nums[1] } }
    else { [pscustomobject]@{ Start = 49152; Count = 16384 } }
}
$rangeV4 = Get-DynRange 'ipv4'
$rangeV6 = Get-DynRange 'ipv6'

function Test-Tcp([string]$ip, [int]$port = 443, [int]$timeoutMs = 3000) {
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        $iar = $tcp.BeginConnect($ip, $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs)) { return 'Timeout' }
        $tcp.EndConnect($iar); 'OK'
    } catch { $_.Exception.InnerException.Message -replace '\s+', ' ' }
    finally { $tcp.Close() }
}

function Get-TlsInfo([string]$ip, [string]$sni) {
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        $iar = $tcp.BeginConnect($ip, 443, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(5000)) { return 'TCP-Connect Timeout (5 s)' }
        $tcp.EndConnect($iar)
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, ({ $true }))
        try {
            $ssl.AuthenticateAsClient($sni)
            $c = $ssl.RemoteCertificate
            "Protokoll=$($ssl.SslProtocol) | Subject=$($c.Subject) | Issuer=$($c.Issuer)"
        } catch { "TLS-Fehler: $($_.Exception.InnerException.Message)" }
        finally { $ssl.Dispose() }
    } catch { "Fehler: $($_.Exception.Message)" }
    finally { $tcp.Close() }
}

# ---------- 1. Monitoring ab Boot ----------
Step "Monitoring ($MonitorMinutes min, alle $IntervalSeconds s)" {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Host "  Letzter Boot: $($os.LastBootUpTime)  Portbereich v4: $($rangeV4.Start)+$($rangeV4.Count)  v6: $($rangeV6.Start)+$($rangeV6.Count)"

    $pktmonRunning = $false
    if ($Capture -eq 1 -and $targetList.Count -gt 0 -and (Get-Command pktmon.exe -ErrorAction SilentlyContinue)) {
        pktmon filter remove | Out-Null
        $n = 0
        foreach ($ip in @($targetList) + @($ControlTarget | Where-Object { $_ })) { $n++; pktmon filter add "T$n" -i $ip | Out-Null }
        pktmon start --capture --comp nics --pkt-size 128 --file-name "$out\10_capture.etl" --file-size 100 | Out-Null
        $pktmonRunning = ($LASTEXITCODE -eq 0)
        Write-Host "  pktmon aktiv: $pktmonRunning"
    }

    $end = (Get-Date).AddMinutes($MonitorMinutes)
    $lastConnTest = [datetime]::MinValue
    $firstFull    = $true
    while ((Get-Date) -lt $end) {
        $t0 = Get-Date
        $ts = $t0.ToString('s')
        $bdProc = @(Get-Process -Name $BdProcName -ErrorAction SilentlyContinue)
        $bdPids = @{}; $bdProc | ForEach-Object { $bdPids[[uint32]$_.Id] = $true }
        $s   = @(Get-NetTCPConnection -ErrorAction SilentlyContinue)
        $tGet = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)

        # Ein Durchlauf: Status-Zaehler, belegte dynamische Ports, BD- und System-Verbindungen (PID 4)
        $all = @{}; $bds = @{}; $perPid = @{}; $p4 = @{}; $p6 = @{}
        $bd = New-Object System.Collections.Generic.List[object]
        $sys = New-Object System.Collections.Generic.List[object]
        $lo4 = $rangeV4.Start; $hi4 = $rangeV4.Start + $rangeV4.Count - 1
        $lo6 = $rangeV6.Start; $hi6 = $rangeV6.Start + $rangeV6.Count - 1
        foreach ($c in $s) {
            $st = [string]$c.State
            $all[$st] = 1 + [int]$all[$st]
            $perPid[$c.OwningProcess] = 1 + [int]$perPid[$c.OwningProcess]
            $lp = [int]$c.LocalPort
            if ($c.LocalAddress.Contains(':')) { if ($lp -ge $lo6 -and $lp -le $hi6) { $p6[$lp] = $true } }
            elseif ($lp -ge $lo4 -and $lp -le $hi4) { $p4[$lp] = $true }
            if ($bdPids.ContainsKey($c.OwningProcess)) { $bd.Add($c); $bds[$st] = 1 + [int]$bds[$st] }
            elseif ($c.OwningProcess -eq 4) { $sys.Add($c) }
        }
        $usedV4 = $p4.Count; $usedV6 = $p6.Count
        $mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction SilentlyContinue
        $top = $perPid.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object {
            $p = Get-Process -Id ([int]$_.Key) -ErrorAction SilentlyContinue
            "$(if ($p) { $p.ProcessName } else { $_.Key }):$($_.Value)"
        }

        AppendCsv '01_monitor_summary.csv' ([pscustomobject]@{
            Zeit            = $ts
            SeitBootMin     = [math]::Round(($t0 - $os.LastBootUpTime).TotalMinutes, 1)
            Gesamt          = $s.Count
            DynPortsFreiV4  = $rangeV4.Count - $usedV4
            DynPortsFreiV6  = $rangeV6.Count - $usedV6
            Sys_TimeWait    = [int]$all['TimeWait']
            System_PID4     = $sys.Count
            BD_Gesamt       = $bd.Count
            BD_Bound        = [int]$bds['Bound']
            BD_SynSent      = [int]$bds['SynSent']
            BD_CloseWait    = [int]$bds['CloseWait']
            BD_Established  = [int]$bds['Established']
            BD_TimeWait     = [int]$bds['TimeWait']
            BD_Handles      = ($bdProc | Measure-Object Handles -Sum).Sum
            BD_WorkingSetMB = [math]::Round((($bdProc | Measure-Object WorkingSet64 -Sum).Sum) / 1MB, 1)
            NonPagedPoolMB  = if ($mem) { [math]::Round($mem.PoolNonpagedBytes / 1MB, 1) } else { '' }
            Top3            = $top -join ', '
            AbfrageSek      = $tGet
        })

        if ($bd.Count) {
            AppendCsv '01_monitor_bd_detail.csv' ($bd | Group-Object State, RemoteAddress, RemotePort |
                Sort-Object Count -Descending | Select-Object -First 15 |
                Select-Object @{n='Zeit';e={$ts}}, Count, Name)
        }
        # Verbindungen des System-Prozesses (PID 4) - z.B. Kernel-Treiber/umgeleitete Verbindungen
        if ($sys.Count -gt 100) {
            AppendCsv '01_monitor_system_detail.csv' ($sys | Group-Object State, RemoteAddress, RemotePort |
                Sort-Object Count -Descending | Select-Object -First 15 |
                Select-Object @{n='Zeit';e={$ts}}, Count, Name)
        }

        # Voller Snapshot einmal, sobald der Anstieg beginnt (BD > 2000 oder v4-Bereich > 50 % belegt)
        if ($firstFull -and ($bd.Count -gt 2000 -or $usedV4 -gt 0.5 * $rangeV4.Count)) {
            $firstFull = $false
            SaveCsv '02_tcp_full_at_burst.csv' ($s | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess, CreationTime)
            Save '02_netstat_s_at_burst.txt' (netstat -s)
            Write-Host "  Anstieg erkannt - Snapshot gespeichert"
        }

        # Konnektivitaetstest jede Minute, mit Anzahl freier Ports zum gleichen Zeitpunkt.
        # NetzBereit: Adapter up + Default-Gateway, sonst sind Fehlschlaege direkt nach Boot wertlos.
        if (((Get-Date) - $lastConnTest).TotalSeconds -ge 60) {
            $lastConnTest = Get-Date
            $netUp = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue |
                       Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' }).Count -gt 0
            foreach ($ip in @($targetList) + @($ControlTarget | Where-Object { $_ })) {
                AppendCsv '03_connectivity_timeline.csv' ([pscustomobject]@{
                    Zeit = (Get-Date).ToString('s'); Ziel = $ip; Kontrolle = ($ip -eq $ControlTarget)
                    NetzBereit = $netUp; DynPortsFreiV4 = $rangeV4.Count - $usedV4
                    Tcp443 = Test-Tcp $ip
                })
            }
        }

        Write-Host ("  {0}  Gesamt={1}  BD={2}  System={3}  frei v4={4}  ({5} s)" -f $ts, $s.Count, $bd.Count, $sys.Count, ($rangeV4.Count - $usedV4), $tGet)
        $wait = $IntervalSeconds - ((Get-Date) - $t0).TotalSeconds
        if ($wait -gt 0) { Start-Sleep -Seconds ([int][math]::Ceiling($wait)) }
    }

    if ($pktmonRunning) {
        pktmon stop | Out-Null
        pktmon etl2pcap "$out\10_capture.etl" --out "$out\10_capture.pcapng" | Out-Null
        pktmon filter remove | Out-Null
    }
}

Step 'TCP-Snapshot (Ende Monitoring)' {
    $procs = @{}; Get-Process | ForEach-Object { $procs[$_.Id] = $_.ProcessName }
    $e = @(Get-NetTCPConnection -ErrorAction SilentlyContinue |
        Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess,
                      @{n='Process';e={ $procs[[int]$_.OwningProcess] }}, CreationTime)
    SaveCsv '02_tcp_full_end.csv'         $e
    SaveCsv '02_tcp_by_process_state.csv' ($e | Group-Object Process, State | Sort-Object Count -Descending | Select-Object Count, Name)
    SaveCsv '02_tcp_bd_by_remote.csv'     ($e | Where-Object Process -eq $BdProcName |
        Group-Object State, RemoteAddress, RemotePort | Sort-Object Count -Descending | Select-Object Count, Name)
    Save '02_netstat_ano.txt' (netstat -ano)
    Save '02_netstat_s.txt'   (netstat -s)
}

# ---------- 2. TLS (einmalig, nach dem Monitoring) ----------
# Hinweis: Ist bei Bitdefender "Encrypted Traffic Scan" aktiv, kann der Issuer hier Bitdefender
# selbst sein - das ist dann keine SSL-Inspection der Firewall.
Step 'TLS-Zertifikate der Bitdefender-Ziele' {
    $cache = Get-DnsClientCache -ErrorAction SilentlyContinue
    $res = foreach ($ip in $targetList) {
        $names = @($cache | Where-Object Data -eq $ip | Select-Object -ExpandProperty Entry -Unique)
        $sni   = if ($names) { $names[0] } else { $ip }
        [pscustomobject]@{ Zeit = Get-Date -Format s; Ziel = $ip; DnsCacheNamen = $names -join ','; SNI = $sni; TLS = Get-TlsInfo $ip $sni }
    }
    SaveCsv '03_tls.csv' $res
    Save '03_dns_cache_bd.txt' ($cache | Where-Object { $_.Entry -match 'bitdefender|gravityzone' -or $_.Data -in $targetList } |
        Select-Object Entry, Data, TimeToLive | Format-Table -AutoSize | Out-String)
}

# ---------- 3. Bitdefender ----------
Step 'Bitdefender-Version und Update-Status' {
    $pc = Get-ChildItem "$env:ProgramFiles\Bitdefender" -Recurse -Filter 'product.console.exe' -File -ErrorAction SilentlyContinue |
          Select-Object -First 1
    # Mit Timeout: product.console.exe blieb als SYSTEM im Task schon unbegrenzt haengen
    $lines = foreach ($c in 'GetVersion product', 'GetVersion antivirus', 'GetUpdateStatus product', 'GetUpdateStatus antivirus') {
        "### $c"
        if (-not $pc) { 'product.console.exe nicht gefunden'; ''; continue }
        $tmp = Join-Path $out '_pc_out.txt'; $nul = Join-Path $out '_pc_in.txt'
        Set-Content -Path $nul -Value '' -Encoding ASCII
        $proc = Start-Process -FilePath $pc.FullName -ArgumentList $c -NoNewWindow -PassThru `
                    -RedirectStandardOutput $tmp -RedirectStandardInput $nul
        if (-not $proc.WaitForExit(30000)) { $proc | Stop-Process -Force -ErrorAction SilentlyContinue; 'TIMEOUT nach 30 s' }
        Get-Content $tmp -ErrorAction SilentlyContinue
        Remove-Item $tmp, $nul -ErrorAction SilentlyContinue
        ''
    }
    Save '04_bd_version.txt' $lines
}

Step 'Bitdefender-Dienste, Prozesse, Dateien' {
    Save '04_bd_services.txt' (Get-Service | Where-Object { $_.DisplayName -match 'Bitdefender' -or $_.Name -match '^EP|bdredline' } |
        Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize | Out-String)
    SaveCsv '04_bd_processes.csv' (Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -match 'Bitdefender' -or $_.Name -match '^EP' } |
        Select-Object ProcessId, Name, ExecutablePath, CreationDate, HandleCount, ThreadCount,
                      @{n='WorkingSetMB';e={[math]::Round($_.WorkingSetSize/1MB,1)}})
    # Neueste Aenderungen zuerst -> zeigt, ob um den Beginn des Problems ein Update eingespielt wurde
    SaveCsv '04_bd_files_by_date.csv' (Get-ChildItem "$env:ProgramFiles\Bitdefender" -Recurse -Include *.exe, *.dll, *.sys -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object LastWriteTime, FullName, @{n='FileVersion';e={$_.VersionInfo.FileVersion}}, Length)
}

Step 'Bitdefender-Logs kopieren' {
    $dest = Join-Path $out '04_bd_logs'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $total = 0; $cap = 200MB; $since = (Get-Date).AddDays(-$EventDays)
    Get-ChildItem "$env:ProgramFiles\Bitdefender", "$env:ProgramData\Bitdefender" -Recurse -File -Include *.log, *.txt -ErrorAction SilentlyContinue |
        Where-Object LastWriteTime -gt $since | Sort-Object LastWriteTime -Descending | ForEach-Object {
            if ($total + $_.Length -gt $cap) { return }
            $name = $_.FullName.Substring(3) -replace '[:\\]', '_'
            Copy-Item $_.FullName (Join-Path $dest $name) -ErrorAction SilentlyContinue
            if ($?) { $total += $_.Length }
        }
    "Kopiert: $([math]::Round($total/1MB,1)) MB (Selbstschutz kann einzelne Dateien blockieren)" | Out-File (Join-Path $dest '_info.txt') -Encoding UTF8
}

# ---------- 4. System / Netzwerk ----------
Step 'System und Netzwerk' {
    $os = Get-CimInstance Win32_OperatingSystem
    Save '05_os.txt' ($os | Select-Object Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime, InstallDate | Format-List | Out-String)
    Save '05_hotfixes.txt' (Get-HotFix | Sort-Object InstalledOn -Descending | Format-Table -AutoSize | Out-String)
    SaveCsv '05_software.csv' (Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue | Where-Object DisplayName |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate | Sort-Object DisplayName)
    Save '05_ipconfig.txt'      (ipconfig /all)
    Save '05_route.txt'         (route print)
    Save '05_dynamicport.txt'   $(netsh int ipv4 show dynamicport tcp; netsh int ipv6 show dynamicport tcp)
    Save '05_tcp_global.txt'    (netsh int tcp show global)
    Save '05_winhttp_proxy.txt' (netsh winhttp show proxy)
    Save '05_tcpip_params.txt'  (Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters | Format-List | Out-String)
    SaveCsv '05_adapters.csv'   (Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress, DriverVersion, DriverDate)
    SaveCsv '05_net_profile.csv' (Get-NetConnectionProfile | Select-Object Name, InterfaceAlias, NetworkCategory, IPv4Connectivity, IPv6Connectivity)
}

Step 'Filtertreiber und WFP' {
    Save '06_fltmc_filters.txt' (fltmc filters)
    SaveCsv '06_drivers.csv' (Get-CimInstance Win32_SystemDriver | Select-Object Name, DisplayName, State, StartMode, PathName)
    netsh wfp show state file="$out\06_wfp_state.xml" | Out-Null
}

# ---------- 5. Ereignisprotokolle ----------
Step 'Ereignisprotokolle' {
    $since = (Get-Date).AddDays(-$EventDays)
    foreach ($log in 'System', 'Application') {
        wevtutil epl $log (Join-Path $out "07_$log.evtx")
        SaveCsv "07_${log}_warn_err.csv" (Get-WinEvent -FilterHashtable @{LogName=$log; Level=1,2,3; StartTime=$since} -ErrorAction SilentlyContinue |
            Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, @{n='Msg';e={ $_.Message -replace '\s+', ' ' }})
    }
    SaveCsv '07_tcpip_4227_4231.csv' (Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Tcpip'; Id=4227,4231; StartTime=$since} -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, @{n='Msg';e={ $_.Message -replace '\s+', ' ' }})
    SaveCsv '07_boot_shutdown.csv' (Get-WinEvent -FilterHashtable @{LogName='System'; Id=6005,6006,6008,41,1074; StartTime=$since} -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, ProviderName, @{n='Msg';e={ $_.Message -replace '\s+', ' ' }})
    # Installationen/Updates im Zeitraum (MSI, Windows Update) -> was hat sich zu Beginn des Problems geaendert?
    SaveCsv '07_installs.csv' (@(
        Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='MsiInstaller'; Id=1033,1034,11707,11724; StartTime=$since} -ErrorAction SilentlyContinue
        Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WindowsUpdateClient'; Id=19,20,43; StartTime=$since} -ErrorAction SilentlyContinue
    ) | Sort-Object TimeCreated | Select-Object TimeCreated, Id, ProviderName, @{n='Msg';e={ $_.Message -replace '\s+', ' ' }})
    Get-WinEvent -ListLog *Bitdefender* -ErrorAction SilentlyContinue | ForEach-Object {
        wevtutil epl $_.LogName (Join-Path $out ("07_" + ($_.LogName -replace '[\\/ ]', '_') + '.evtx'))
    }
}

# ---------- 6. Zusammenfassung ----------
Step 'Zusammenfassung' {
    $os   = Get-CimInstance Win32_OperatingSystem
    $bdsw = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue | Where-Object DisplayName -match 'Bitdefender' |
            ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)" }
    $ev   = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Tcpip'; Id=4227,4231; StartTime=(Get-Date).AddDays(-$EventDays)} -ErrorAction SilentlyContinue)
    $mon  = @(Import-Csv (Join-Path $out '01_monitor_summary.csv') -Delimiter ';' -ErrorAction SilentlyContinue)
    $maxBd   = ($mon | ForEach-Object { [int]$_.BD_Gesamt } | Measure-Object -Maximum).Maximum
    $minFree = ($mon | ForEach-Object { [int]$_.DynPortsFreiV4 } | Measure-Object -Minimum).Minimum
    $firstLow = $mon | Where-Object { [int]$_.DynPortsFreiV4 -lt 0.1 * $rangeV4.Count } | Select-Object -First 1
    $conn = @(Import-Csv (Join-Path $out '03_connectivity_timeline.csv') -Delimiter ';' -ErrorAction SilentlyContinue)
    $connLines = $conn | Group-Object Ziel | ForEach-Object {
        $okFree   = @($_.Group | Where-Object { $_.NetzBereit -eq 'True' -and [int]$_.DynPortsFreiV4 -gt 1000 })
        $okFreeOk = @($okFree | Where-Object Tcp443 -eq 'OK').Count
        $label    = if ($_.Group[0].Kontrolle -eq 'True') { ' (Kontrolle)' } else { '' }
        "  $($_.Name)$label`: $okFreeOk von $($okFree.Count) Tests OK (Netz bereit, > 1000 Ports frei)"
    }
    $bdVer = Get-Content (Join-Path $out '04_bd_version.txt') -ErrorAction SilentlyContinue

    $lines = @(
        "Bitdefender GravityZone - TCP-Port-Erschoepfung durch EPSecurityService"
        "======================================================================"
        "Rechner:            $env:COMPUTERNAME"
        "Erstellt:           $(Get-Date -Format s)"
        "OS:                 $($os.Caption) $($os.Version)"
        "Letzter Boot:       $($os.LastBootUpTime)"
        "Bitdefender:        $($bdsw -join '; ')"
        "Portbereich:        IPv4 $($rangeV4.Start)+$($rangeV4.Count), IPv6 $($rangeV6.Start)+$($rangeV6.Count)"
        "Tcpip 4227/4231:    $($ev.Count) Ereignisse in den letzten $EventDays Tagen"
        "Monitoring:         $($mon.Count) Messungen, max. Verbindungen EPSecurityService: $maxBd"
        "Min. freie Ports:   IPv4 $minFree"
        "< 10 % frei ab:     $(if ($firstLow) { "$($firstLow.Zeit) ($($firstLow.SeitBootMin) min nach Boot)" } else { 'nie' })"
        ""
        "TCP/443, solange Netz bereit und Ports frei (BD-Ziel 0 OK + Kontrolle OK = Ziel wird im Netz blockiert):"
    ) + $connLines + @(
        ""
        "product.console.exe:"
    ) + ($bdVer | ForEach-Object { "  $_" }) + @(
        ""
        "Dateien: 01_monitor_summary.csv (Zeitreihe ab Boot), 01_monitor_bd_detail.csv, 03_connectivity_timeline.csv,"
        "02_tcp_full_at_exhaustion.csv, 03_tls.csv, 04_* (Bitdefender), 07_* (Ereignisprotokolle), 10_capture.pcapng."
    )
    Save '00_SUMMARY.txt' $lines
}

Stop-Transcript | Out-Null

$zip = "$out.zip"
try {
    Compress-Archive -Path "$out\*" -DestinationPath $zip -Force -ErrorAction Stop
    Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
    "[$(Get-Date -Format s)] Fertig: $zip" | Add-Content (Join-Path $OutRoot 'collect_task.log')
    Write-Host "Fertig: $zip"
} catch {
    "[$(Get-Date -Format s)] ZIP fehlgeschlagen: $($_.Exception.Message) - Ordner: $out" | Add-Content (Join-Path $OutRoot 'collect_task.log')
}

# Einmal-Task entfernen, damit nicht jeder weitere Boot erneut sammelt
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
exit 0
