#Requires -Version 5.1
<#
  ROM-OPTI v4  -  Windows tuning for Rust and other CPU-bound games

  Start it with Run-RomOpti.bat (or right-click this file > Run with PowerShell).
  It asks for administrator rights once.

  How it works
    - Before any change is made, the previous value is written to a journal
      (C:\ProgramData\RomOpti\journal.json). Revert restores YOUR old values,
      not hard-coded defaults.
    - Every toggle says what it does, how much it can realistically matter,
      and what the tradeoff is. Most Windows tweaks are worth a few percent at
      best; the Dashboard tells you which bigger problems your PC actually has.
    - Nothing here injects into the game process or edits game binaries.
#>

# ---- elevation --------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PSCommandPath)
    } catch { }
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$script:Version = '4.0'

# ---- native helpers ---------------------------------------------------------
$NativeSrc = @'
using System;
using System.Runtime.InteropServices;

public static class RomNative {
    [DllImport("ntdll.dll")] static extern uint NtSetTimerResolution(uint desired, bool set, out uint current);
    [DllImport("ntdll.dll")] static extern uint NtQueryTimerResolution(out uint min, out uint max, out uint current);
    [DllImport("ntdll.dll")] static extern uint NtSetSystemInformation(int cls, ref int info, int len);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string system, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES np, int len, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", CharSet = CharSet.Ansi)] static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE dm);

    // Pack=4 matters: the real TOKEN_PRIVILEGES has the LUID at offset 4. With the default
    // packing the LUID lands at offset 8, the privilege is never enabled and the standby
    // purge fails with STATUS_PRIVILEGE_NOT_HELD.
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct TOKEN_PRIVILEGES { public int Count; public long Luid; public int Attr; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight; public int dmDisplayFlags; public int dmDisplayFrequency;
        public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType;
        public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
    }

    static bool EnablePrivilege(string name) {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return false;
        try {
            long luid;
            if (!LookupPrivilegeValue(null, name, out luid)) return false;
            TOKEN_PRIVILEGES tp; tp.Count = 1; tp.Luid = luid; tp.Attr = 2;
            if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
            return Marshal.GetLastWin32Error() == 0;   // 1300 = not all assigned
        } finally { CloseHandle(tok); }
    }

    // ---- timer resolution: ask for the finest the hardware offers ----
    public static double HoldFinestTimer() {
        uint a, b, cur;
        NtQueryTimerResolution(out a, out b, out cur);
        uint finest = Math.Min(a, b);          // smaller value = finer resolution (5000 = 0.5 ms)
        uint r = NtSetTimerResolution(finest, true, out cur);
        if (r != 0) return -1;
        NtQueryTimerResolution(out a, out b, out cur);
        return cur / 10000.0;
    }
    public static void ReleaseTimer() { uint cur; NtSetTimerResolution(156250, false, out cur); }
    public static double TimerMs() { uint min, max, cur; NtQueryTimerResolution(out min, out max, out cur); return cur / 10000.0; }

    // ---- standby list purge (what ISLC does) ----
    public static uint PurgeStandby() {
        if (!EnablePrivilege("SeProfileSingleProcessPrivilege")) return 0xC0000061;
        int cmd = 4;                                        // MemoryPurgeStandbyList
        return NtSetSystemInformation(80, ref cmd, 4);      // SystemMemoryListInformation
    }

    // ---- primary display: { current Hz, max Hz at same resolution, width, height } ----
    public static int[] DisplayInfo() {
        DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettings(null, -1, ref dm)) return new int[] { 0, 0, 0, 0 };
        int cur = dm.dmDisplayFrequency, w = dm.dmPelsWidth, h = dm.dmPelsHeight, bpp = dm.dmBitsPerPel, max = cur;
        for (int i = 0; ; i++) {
            DEVMODE m = new DEVMODE(); m.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettings(null, i, ref m)) break;
            if (m.dmPelsWidth == w && m.dmPelsHeight == h && m.dmBitsPerPel == bpp && m.dmDisplayFrequency > max) max = m.dmDisplayFrequency;
        }
        return new int[] { cur, max, w, h };
    }

    public static void HideConsole() { IntPtr h = GetConsoleWindow(); if (h != IntPtr.Zero) ShowWindow(h, 0); }
}
'@
try { Add-Type -TypeDefinition $NativeSrc -ErrorAction Stop; $script:NativeOk = $true; [RomNative]::HideConsole() }
catch { $script:NativeOk = $false }

# ---- paths, logging ---------------------------------------------------------
$script:AppDir      = Join-Path $env:ProgramData 'RomOpti'
$script:JournalFile = Join-Path $script:AppDir 'journal.json'
$script:SessionFile = Join-Path $script:AppDir 'session.json'
$script:LogFile     = Join-Path $script:AppDir 'rom-opti.log'
if (-not (Test-Path -LiteralPath $script:AppDir)) { [void](New-Item -ItemType Directory -Path $script:AppDir -Force) }
try { if ((Test-Path -LiteralPath $script:LogFile) -and ((Get-Item -LiteralPath $script:LogFile).Length -gt 2MB)) { Remove-Item -LiteralPath $script:LogFile -Force } } catch { }

$script:UI     = $null
$script:Brushes = @{}

function Get-Brush {
    param([string]$Hex, [double]$Opacity = 1.0)
    $key = "$Hex|$Opacity"
    if (-not $script:Brushes.ContainsKey($key)) {
        $c = [Windows.Media.ColorConverter]::ConvertFromString($Hex)
        $c.A = [byte][math]::Round(255 * $Opacity)
        $b = New-Object Windows.Media.SolidColorBrush $c
        $b.Freeze()
        $script:Brushes[$key] = $b
    }
    return $script:Brushes[$key]
}

function Write-TextFile {
    # UTF-8 *without* BOM. Windows PowerShell's Set-Content -Encoding UTF8 writes a BOM, which
    # can corrupt the first line of a game .cfg or break a JSON parser.
    param([string]$Path, [string]$Text)
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [System.IO.File]::Delete($Path) }
    [System.IO.File]::Move($tmp, $Path)
}

function Write-Log {
    param([string]$Message, [string]$Kind = 'info')
    try { Add-Content -LiteralPath $script:LogFile -Value ("{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Kind, $Message) -ErrorAction SilentlyContinue } catch { }
    if (-not $script:UI -or -not $script:UI.logList) { return }
    $color = switch ($Kind) { 'ok' { '#3FB950' } 'warn' { '#D9A23A' } 'err' { '#E5534B' } 'accent' { '#E8743B' } default { '#8D96A3' } }
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
    $tb.TextWrapping = 'Wrap'
    $tb.FontFamily = 'Consolas'
    $tb.FontSize = 11.5
    $tb.Margin = '0,1,0,1'
    $tb.Foreground = Get-Brush $color
    [void]$script:UI.logList.Items.Add($tb)
    while ($script:UI.logList.Items.Count -gt 400) { $script:UI.logList.Items.RemoveAt(0) }
    $script:UI.logList.ScrollIntoView($tb)
    $script:UI.lastLog.Text = $Message
    $script:UI.lastLog.Foreground = Get-Brush $color
}

function Invoke-UiPump {
    # Lets WPF repaint during a synchronous loop. Only called from code paths where the
    # buttons are disabled, so re-entrancy is not a concern.
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [void]$script:UI.Win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ $frame.Continue = $false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

# ---- async helper (keeps the window responsive during slow work) -------------
$script:Jobs = New-Object System.Collections.ArrayList

function Invoke-Async {
    # $Work runs in its own runspace and must be self-contained. It may push progress objects
    # into $Q (a ConcurrentQueue) which are handed to $OnProgress on the UI thread.
    # Callbacks must use $script: state - they run later, in a different scope.
    param([scriptblock]$Work, [object[]]$ArgList = @(), [scriptblock]$OnProgress, [scriptblock]$OnDone)
    $q  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Q', $q)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Work.ToString())
    foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
    $job = [pscustomobject]@{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Q = $q; OnProgress = $OnProgress; OnDone = $OnDone; Timer = $null }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(60)
    $timer.Tag = $job
    $job.Timer = $timer
    $timer.Add_Tick({
        param($s, $e)
        $j = $s.Tag
        $item = $null
        while ($j.Q.TryDequeue([ref]$item)) { if ($j.OnProgress) { & $j.OnProgress $item } }
        if ($j.Handle.IsCompleted) {
            $s.Stop()
            $result = $null; $failure = $null
            try { $result = $j.PS.EndInvoke($j.Handle) } catch { $failure = $_.Exception.Message }
            if (-not $failure -and $j.PS.Streams.Error.Count -gt 0) { $failure = $j.PS.Streams.Error[0].ToString() }
            try { $j.PS.Dispose(); $j.RS.Dispose() } catch { }
            [void]$script:Jobs.Remove($j)
            if ($j.OnDone) { & $j.OnDone $result $failure }
        }
    })
    [void]$script:Jobs.Add($job)
    $timer.Start()
}

# ---- registry / service / task primitives ------------------------------------
function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -Path $Path -Force) }
    switch ($Type) {
        'DWord'       { $n = [int64]$Value; if ($n -gt [int]::MaxValue) { $n -= 4294967296 }; $Value = [int]$n }
        'QWord'       { $Value = [int64]$Value }
        'Binary'      { $Value = [byte[]]@($Value) }
        'MultiString' { $Value = [string[]]@($Value) }
        default       { $Value = [string]$Value }
    }
    [void](New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force)
}

function Get-RegValue {
    param([string]$Path, [string]$Name, $Default = $null)
    try { $k = Get-Item -LiteralPath $Path -ErrorAction Stop } catch { return $Default }
    if ($k.GetValueNames() -notcontains $Name) { return $Default }
    return $k.GetValue($Name, $Default, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

function Remove-RegValue {
    param([string]$Path, [string]$Name)
    if (Test-Path -LiteralPath $Path) { Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue }
}

function New-RegSnapshot {
    param($It)
    $snap = @{ Path = $It.P; Name = $It.N; Existed = $false }
    try { $k = Get-Item -LiteralPath $It.P -ErrorAction Stop } catch { return $snap }
    if ($k.GetValueNames() -notcontains $It.N) { return $snap }
    $val = $k.GetValue($It.N, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($val -is [byte[]]) { $val = [int[]]$val }
    $snap.Existed = $true
    $snap.Kind    = $k.GetValueKind($It.N).ToString()
    $snap.Value   = $val
    return $snap
}

function Restore-RegSnapshot {
    param($S)
    if ($S.Existed) { Set-Reg $S.Path $S.Name $S.Value $S.Kind } else { Remove-RegValue $S.Path $S.Name }
}

function Test-RegItem {
    param($It)
    $cur = Get-RegValue $It.P $It.N $null
    if ($null -eq $cur) { return $false }
    $type = if ($It.T) { $It.T } else { 'DWord' }
    if ($type -in 'DWord', 'QWord') { try { return ([int64]$cur) -eq ([int64]$It.V) } catch { return $false } }
    return ("$cur" -eq "$($It.V)")
}

function RegItem { param($P, $N, $V, $T = 'DWord') @{ P = $P; N = $N; V = $V; T = $T } }   # tweak shorthand (not 'R': that is an alias for Invoke-History)

function Get-ServiceStartup {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }
    return [string]$svc.StartType
}

function Set-SvcStartup {
    param([string]$Name, [string]$Mode, [bool]$Delayed = $false)
    if ($Mode -eq 'Automatic' -and $Delayed) {
        $out = & sc.exe config $Name start= delayed-auto 2>&1
        if ($LASTEXITCODE -ne 0) { throw "sc config $Name failed: $out" }
    } else {
        Set-Service -Name $Name -StartupType $Mode -ErrorAction Stop
    }
}

function New-SvcSnapshot {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }
    $delayed = ((Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" 'DelayedAutostart' 0) -eq 1)
    return @{ Name = $Name; Start = [string]$svc.StartType; Running = ($svc.Status -eq 'Running'); Delayed = $delayed }
}

function Restore-SvcSnapshot {
    param($S)
    if ($S.Start -in 'Automatic', 'Manual', 'Disabled') { Set-SvcStartup $S.Name $S.Start ([bool]$S.Delayed) }
    if ($S.Running) { Start-Service -Name $S.Name -ErrorAction SilentlyContinue }
}

function Split-TaskPath {
    param([string]$Full)
    $i = $Full.LastIndexOf('\')
    return @{ Path = $Full.Substring(0, $i + 1); Name = $Full.Substring($i + 1) }
}

function Get-TaskEnabled {
    param([string]$Full)
    $p = Split-TaskPath $Full
    $t = Get-ScheduledTask -TaskPath $p.Path -TaskName $p.Name -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    return ($t.State -ne 'Disabled')
}

function Set-TaskEnabled {
    param([string]$Full, [bool]$Enabled)
    $p = Split-TaskPath $Full
    if (-not (Get-ScheduledTask -TaskPath $p.Path -TaskName $p.Name -ErrorAction SilentlyContinue)) { return }
    if ($Enabled) { [void](Enable-ScheduledTask -TaskPath $p.Path -TaskName $p.Name -ErrorAction Stop) }
    else          { [void](Disable-ScheduledTask -TaskPath $p.Path -TaskName $p.Name -ErrorAction Stop) }
}

# ---- power plan helpers ------------------------------------------------------
function Get-ActivePlan {
    $o = (powercfg /getactivescheme 2>$null | Out-String)
    if ($o -match '([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})\s+\((.+?)\)') { return [pscustomobject]@{ Guid = $Matches[1]; Name = $Matches[2] } }
    return $null
}

function Invoke-Native {
    # Run a native command; throw with its output on a nonzero exit code.
    param([scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try { $out = (& $Command 2>&1 | ForEach-Object { "$_" }) -join ' ' } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { throw "$($Command.ToString().Trim()) -> $($out.Trim()) (exit $LASTEXITCODE)" }
}

function Invoke-NativeOut {
    # Like Invoke-Native but returns { Out, Code } instead of throwing, for settings that are
    # allowed to be missing on some machines.
    param([scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try { $out = (& $Command 2>&1 | ForEach-Object { "$_" }) -join "`n" } finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Out = $out; Code = $global:LASTEXITCODE }
}

# ---- system facts (read once at start) --------------------------------------
function Find-RustClient {
    if ($script:RustExeCache) { return $script:RustExeCache }
    try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch { return $null }
    if (-not $steam) { return $null }
    $steam = $steam -replace '/', '\'
    $libs = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += $m.Groups[1].Value.Replace('\\', '\') }
    }
    foreach ($l in ($libs | Select-Object -Unique)) {
        $p = Join-Path $l 'steamapps\common\Rust\RustClient.exe'
        if (Test-Path -LiteralPath $p) { $script:RustExeCache = $p; return $p }
    }
    return $null
}

function Get-SystemFacts {
    $f = @{}
    $f.Build  = [Environment]::OSVersion.Version.Build
    $f.Win11  = ($f.Build -ge 22000)
    $f.OsName = 'Windows'
    try { $f.OsName = (Get-CimInstance Win32_OperatingSystem).Caption -replace '^Microsoft\s+', '' } catch { }
    $f.RamGB = 0
    try { $f.RamGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) } catch { }
    $f.CpuName = 'Unknown CPU'; $f.Cores = 0; $f.Threads = 0
    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $f.CpuName = ($cpu.Name -replace '\s+', ' ').Trim()
        $f.Cores = [int]$cpu.NumberOfCores; $f.Threads = [int]$cpu.NumberOfLogicalProcessors
    } catch { }
    $f.X3D        = [bool]($f.CpuName -match 'X3D')
    $f.DualCcdX3D = [bool]($f.CpuName -match '(7|9)9[05]0X3D')
    $f.Gpus = @()
    try { $f.Gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -and $_.Name -notmatch 'Basic|Remote|Virtual|Mirage|Parsec|Meta|Hyper' }) } catch { }
    $f.Laptop = $false
    try { $f.Laptop = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) } catch { }
    $f.RustExe = Find-RustClient
    return $f
}

# ---- journal -----------------------------------------------------------------
$script:Journal = @{}

function ConvertTo-Plain {
    param($O)
    if ($null -eq $O) { return $null }
    if ($O -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $O.PSObject.Properties) { $h[$p.Name] = ConvertTo-Plain $p.Value }
        return $h
    }
    if (($O -is [System.Collections.IEnumerable]) -and ($O -isnot [string])) {
        $list = New-Object System.Collections.ArrayList
        foreach ($i in $O) { [void]$list.Add((ConvertTo-Plain $i)) }
        return ,$list.ToArray()
    }
    return $O
}

function Import-Journal {
    $script:Journal = @{}
    if (-not (Test-Path -LiteralPath $script:JournalFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:JournalFile -Raw -Encoding UTF8
        if ($raw -and $raw.Trim()) {
            $h = ConvertTo-Plain (ConvertFrom-Json $raw)
            if ($h -is [hashtable]) { $script:Journal = $h }
        }
    } catch { Write-Log "Journal unreadable, starting fresh: $($_.Exception.Message)" 'warn' }
}

function Save-Journal {
    Write-TextFile $script:JournalFile (ConvertTo-Json -InputObject $script:Journal -Depth 8)
}

function New-JournalEntry { @{ At = (Get-Date).ToString('s'); Regs = @(); Svcs = @(); Tasks = @(); Extra = @{} } }

function Get-Extra {
    param([string]$Id, [string]$Key)
    if ($script:Journal.ContainsKey($Id)) {
        $x = $script:Journal[$Id].Extra
        if ($x -and $x.ContainsKey($Key)) { return $x[$Key] }
    }
    return $null
}

function Set-Extra {
    param([string]$Id, [string]$Key, $Value)
    if (-not $script:Journal.ContainsKey($Id)) { $script:Journal[$Id] = New-JournalEntry }
    if (-not $script:Journal[$Id].Extra) { $script:Journal[$Id].Extra = @{} }
    $script:Journal[$Id].Extra[$Key] = $Value
    Save-Journal
}

# ---- tweak engine ------------------------------------------------------------
function Get-TweakRegItems {
    param($T)
    if (-not $T.Reg) { return @() }
    if ($T.Reg -is [scriptblock]) { return @(& $T.Reg | Where-Object { $_ }) }
    return @($T.Reg)
}

function Get-TweakBlock {
    # $null when the tweak can run on this PC, otherwise the reason it can't.
    param($T)
    if ($T.When) {
        $r = & $T.When $T
        if (($r -is [string]) -and $r) { return $r }
    }
    return $null
}

function Test-TweakApplied {
    param($T)
    if ($T.Check) { return [bool](& $T.Check $T) }
    $regs = Get-TweakRegItems $T
    $svcs = @($T.Svc | Where-Object { $_ })
    $tasks = @($T.Tasks | Where-Object { $_ })
    if (-not $regs -and -not $svcs -and -not $tasks) { return $false }
    foreach ($it in $regs) { if (-not (Test-RegItem $it)) { return $false } }
    foreach ($s in $svcs) {
        $cur = Get-ServiceStartup $s.N
        if ($null -ne $cur -and $cur -ne $s.S) { return $false }
    }
    foreach ($tk in $tasks) {
        $en = Get-TaskEnabled $tk
        if ($null -ne $en -and $en) { return $false }
    }
    return $true
}

function Invoke-TweakUndo {
    param($T)
    $e = if ($script:Journal.ContainsKey($T.Id)) { $script:Journal[$T.Id] } else { $null }
    if ($T.Undo) { & $T.Undo $T }
    if ($e) {
        for ($i = @($e.Regs).Count - 1; $i -ge 0; $i--) { Restore-RegSnapshot @($e.Regs)[$i] }
        foreach ($s in @($e.Svcs)) { if ($s) { Restore-SvcSnapshot $s } }
        foreach ($tk in @($e.Tasks)) { if ($tk) { if ($tk.Enabled) { Set-TaskEnabled $tk.Name $true } } }
    } else {
        # Applied outside this tool (e.g. by an older version): fall back to removing our values.
        foreach ($it in (Get-TweakRegItems $T)) { Remove-RegValue $it.P $it.N }
        foreach ($s in @($T.Svc | Where-Object { $_ })) { if ($s.D) { Set-SvcStartup $s.N $s.D } }
        foreach ($tk in @($T.Tasks | Where-Object { $_ })) { Set-TaskEnabled $tk $true }
    }
    if ($script:Journal.ContainsKey($T.Id)) { $script:Journal.Remove($T.Id); Save-Journal }
}

function Invoke-TweakApply {
    param($T)
    if (-not $script:Journal.ContainsKey($T.Id)) {
        # Snapshot only once: re-applying must never overwrite the true original values.
        $e = New-JournalEntry
        foreach ($it in (Get-TweakRegItems $T)) { $e.Regs += ,(New-RegSnapshot $it) }
        foreach ($s in @($T.Svc | Where-Object { $_ })) { $snap = New-SvcSnapshot $s.N; if ($snap) { $e.Svcs += ,$snap } }
        foreach ($tk in @($T.Tasks | Where-Object { $_ })) {
            $en = Get-TaskEnabled $tk
            if ($null -ne $en) { $e.Tasks += ,@{ Name = $tk; Enabled = $en } }
        }
        $script:Journal[$T.Id] = $e
        Save-Journal
    }
    try {
        foreach ($it in (Get-TweakRegItems $T)) {
            $type = if ($it.T) { $it.T } else { 'DWord' }
            Set-Reg $it.P $it.N $it.V $type
        }
        foreach ($s in @($T.Svc | Where-Object { $_ })) {
            $svc = Get-Service -Name $s.N -ErrorAction SilentlyContinue
            if (-not $svc) { continue }
            if ($s.Stop -and $svc.Status -ne 'Stopped') { try { Stop-Service -Name $s.N -Force -ErrorAction Stop } catch { } }
            Set-SvcStartup $s.N $s.S
        }
        foreach ($tk in @($T.Tasks | Where-Object { $_ })) { Set-TaskEnabled $tk $false }
        if ($T.Apply) { & $T.Apply $T }
    } catch {
        $msg = $_.Exception.Message
        try { Invoke-TweakUndo $T } catch { }
        throw $msg
    }
}
# ---- tweak catalog -----------------------------------------------------------
# Fields
#   Impact  0 = no FPS effect (comfort/stability), 1 = small, 2 = noticeable, 3 = large *when the condition applies*
#   Gain    FPS | Lows | Latency | Ping | Stability | Background | Comfort
#   Reg     declarative registry values (snapshotted automatically)   Svc / Tasks   same for services and tasks
#   When    returns $true, or a string explaining why this PC can't use the tweak
#   Rec     recommended (bool or scriptblock). Preferences are never recommended.

$script:Groups = @(
    @{ Key = 'Power';   Title = 'Power & CPU' }
    @{ Key = 'Gpu';     Title = 'GPU & display' }
    @{ Key = 'Rust';    Title = 'Rust (RustClient.exe)' }
    @{ Key = 'Input';   Title = 'Input' }
    @{ Key = 'Network'; Title = 'Network' }
    @{ Key = 'Bg';      Title = 'Background load' }
    @{ Key = 'Stab';    Title = 'Stability' }
    @{ Key = 'Adv';     Title = 'Advanced (security tradeoff)' }
    @{ Key = 'Prefs';   Title = 'Windows preferences' }
)

function Set-PlanValue {
    param([string]$Guid, [string]$Sub, [string]$Setting, $Value)
    $a = Invoke-NativeOut { powercfg -setacvalueindex $Guid $Sub $Setting $Value }
    $null = Invoke-NativeOut { powercfg -setdcvalueindex $Guid $Sub $Setting $Value }
    return ($a.Code -eq 0)
}

function Find-PlanGuid {
    param([string]$Name)
    foreach ($line in ((powercfg /list 2>$null | Out-String) -split "`r?`n")) {
        if ($line -match ('([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})\s+\(' + [regex]::Escape($Name) + '\)')) { return $Matches[1] }
    }
    return $null
}

function Get-TweakCatalog {
    $F = $script:Facts
    $prefAdv  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $personal = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $gfx      = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'

    $list = New-Object System.Collections.ArrayList

    # ======================= POWER & CPU =======================
    [void]$list.Add(@{
        Id = 'pwr_plan'; Group = 'Power'; Name = 'Performance power plan'; Impact = 2; Gain = @('FPS', 'Lows', 'Latency')
        Desc = 'Creates a separate plan from Ultimate Performance (High Performance if unavailable): CPU never idles below 100%, aggressive boost, USB selective suspend off, PCIe link power saving off. Your current plan is remembered and restored on revert.'
        Rec = { -not $script:Facts.Laptop }
        Note = { if ($script:Facts.Laptop) { 'Laptop detected: more heat and battery drain. Only use it plugged in.' }
                 elseif ($script:Facts.DualCcdX3D) { 'Dual-CCD X3D: core parking is left alone so AMD''s scheduler keeps working.' } }
        Check = { param($t) $p = Get-ActivePlan; return ($p -and $p.Name -eq 'Rom-Opti Performance') }
        Apply = {
            param($t)
            $name = 'Rom-Opti Performance'
            $prev = Get-ActivePlan
            if ($prev -and $prev.Name -ne $name) { Set-Extra $t.Id 'PrevPlan' $prev.Guid }
            $guid = Find-PlanGuid $name
            if (-not $guid) {
                foreach ($src in 'e9a42b02-d5df-448d-aa00-03f14749eb61', '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') {
                    $r = Invoke-NativeOut { powercfg -duplicatescheme $src }
                    if ($r.Code -eq 0 -and $r.Out -match '([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})') { $guid = $Matches[1]; break }
                }
            }
            if (-not $guid) { throw 'Windows would not create a performance plan on this PC (common on Modern Standby laptops).' }
            Invoke-Native { powercfg -changename $guid $name 'Created by Rom-Opti' }
            Set-Extra $t.Id 'PlanGuid' $guid
            $sub = 'SUB_PROCESSOR'
            [void](Set-PlanValue $guid $sub 'PROCTHROTTLEMIN' 100)
            [void](Set-PlanValue $guid $sub 'PROCTHROTTLEMAX' 100)
            [void](Set-PlanValue $guid $sub 'PERFBOOSTMODE' 2)
            [void](Set-PlanValue $guid $sub 'PERFEPP' 0)
            if (-not $script:Facts.DualCcdX3D) { [void](Set-PlanValue $guid $sub 'CPMINCORES' 100) }
            [void](Set-PlanValue $guid '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' 0)
            if (-not $script:Facts.Laptop) { [void](Set-PlanValue $guid '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5' 0) }
            Invoke-Native { powercfg -setactive $guid }
        }
        Undo = {
            param($t)
            $guid = Get-Extra $t.Id 'PlanGuid'
            if (-not $guid) { $guid = Find-PlanGuid 'Rom-Opti Performance' }
            $prev = Get-Extra $t.Id 'PrevPlan'
            if (-not $prev -or ((powercfg /list 2>$null | Out-String) -notmatch [regex]::Escape($prev))) { $prev = '381b4222-f694-41f0-9685-ff5bb260df2e' }
            Invoke-Native { powercfg -setactive $prev }
            if ($guid) { $null = Invoke-NativeOut { powercfg -delete $guid } }
        }
    })
    [void]$list.Add(@{
        Id = 'pwr_throttle'; Group = 'Power'; Name = 'Power Throttling off'; Impact = 1; Gain = @('Lows')
        Desc = 'Stops Windows from pushing threads it classes as background onto efficiency clocks. Matters most on laptops and Intel hybrid CPUs, where a game helper thread can get demoted.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1) )
    })

    # ======================= GPU & DISPLAY =======================
    [void]$list.Add(@{
        Id = 'gpu_gamemode'; Group = 'Gpu'; Name = 'Game Mode on'; Impact = 1; Gain = @('Lows')
        Desc = 'Windows holds back driver installs and some background work while a game has focus. Already on by default on most installs; this makes sure. (Dual-CCD X3D chips need it on.)'
        Rec = $true
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1), (RegItem 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1) )
    })
    [void]$list.Add(@{
        Id = 'gpu_dvr'; Group = 'Gpu'; Name = 'Game capture off'; Impact = 1; Gain = @('FPS', 'Lows')
        Desc = 'Disables the background recording hooks (Game DVR / app capture). Only worth it if you never use Xbox Game Bar clips; use OBS or ShadowPlay for recording instead.'
        Rec = $true
        When = { if ($script:Facts.DualCcdX3D) { 'Skipped: dual-CCD X3D scheduling relies on Game Bar components' } else { $true } }
        Reg = @( (RegItem 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0),
                 (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0) )
    })

    # ======================= RUST =======================
    [void]$list.Add(@{
        Id = 'gpu_pref'; Group = 'Rust'; Name = 'Use the high-performance GPU'; Impact = 3; Gain = @('FPS')
        Desc = 'Pins RustClient.exe to your fast GPU in Windows Graphics settings. Only matters on PCs that also have an integrated GPU (laptops, and desktop CPUs with built-in graphics) where Windows can schedule the game onto the wrong one.'
        Rec = $true
        When = { if (-not $script:Facts.RustExe) { 'RustClient.exe not found in your Steam libraries' }
                 elseif (@($script:Facts.Gpus).Count -lt 2) { 'Only one GPU detected, nothing to choose between' } else { $true } }
        Reg = { $exe = $script:Facts.RustExe; if ($exe) { RegItem 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $exe 'GpuPreference=2;' 'String' } }
    })
    [void]$list.Add(@{
        Id = 'gpu_fso'; Group = 'Rust'; Name = 'Disable fullscreen optimizations for Rust'; Impact = 1; Gain = @('Latency')
        Desc = 'Per-app compatibility flag that makes Windows treat Rust as true exclusive fullscreen instead of its flip-model path. The effect is small and hardware dependent: some setups get lower input latency, others see nothing. Test it.'
        Rec = $false
        When = { if ($script:Facts.RustExe) { $true } else { 'RustClient.exe not found in your Steam libraries' } }
        Reg = {
            $exe = $script:Facts.RustExe; if (-not $exe) { return }
            $p = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
            $flags = @(([string](Get-RegValue $p $exe '')) -split '\s+' | Where-Object { $_ -and $_ -ne '~' })
            if ($flags -notcontains 'DISABLEDXMAXIMIZEDWINDOWEDMODE') { $flags += 'DISABLEDXMAXIMIZEDWINDOWEDMODE' }
            RegItem $p $exe ('~ ' + ($flags -join ' ')) 'String'
        }
    })
    [void]$list.Add(@{
        Id = 'rust_defender'; Group = 'Rust'; Name = 'Exclude the Rust folder from Defender scanning'; Impact = 1; Gain = @('Lows')
        Desc = 'Stops Microsoft Defender real-time scanning from inspecting every asset Rust streams in, which causes load hitches on slower storage.'
        Note = 'Tradeoff: files placed in that folder are no longer scanned in real time.'
        Rec = $false
        When = {
            if (-not $script:Facts.RustExe) { return 'RustClient.exe not found in your Steam libraries' }
            if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) { return 'Defender cmdlets unavailable' }
            try { if (-not (Get-MpComputerStatus).RealTimeProtectionEnabled) { return 'Defender real-time protection is off (another antivirus may be active)' } } catch { return 'Defender unavailable' }
            return $true
        }
        Check = { param($t) $dir = Split-Path $script:Facts.RustExe -Parent; return (@((Get-MpPreference).ExclusionPath) -contains $dir) }
        Apply = { param($t) Add-MpPreference -ExclusionPath (Split-Path $script:Facts.RustExe -Parent) }
        Undo  = { param($t) Remove-MpPreference -ExclusionPath (Split-Path $script:Facts.RustExe -Parent) }
    })

    # ======================= INPUT =======================
    [void]$list.Add(@{
        Id = 'inp_keys'; Group = 'Input'; Name = 'Turn off Sticky / Filter / Toggle Keys shortcuts'; Impact = 0; Gain = @('Comfort')
        Desc = 'Tapping Shift five times in a fight (sprint) opens the Sticky Keys prompt and can minimize a fullscreen game. This removes those hotkeys. Takes effect after you sign out and back in.'
        Rec = $true
        Reg = @( (RegItem 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'),
                 (RegItem 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'),
                 (RegItem 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' 'String') )
    })
    [void]$list.Add(@{
        Id = 'inp_mouse'; Group = 'Input'; Name = 'Mouse acceleration off'; Impact = 0; Gain = @('Comfort')
        Desc = 'Turns off "Enhance pointer precision" so the desktop cursor moves 1:1. Games that read raw input already ignore it, so this mostly matters for menus and desktop aiming.'
        Rec = $true
        Reg = @( (RegItem 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'),
                 (RegItem 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'),
                 (RegItem 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String') )
    })
    [void]$list.Add(@{
        Id = 'inp_timer'; Group = 'Input'; Name = 'Allow global timer resolution requests'; Impact = 1; Gain = @('Lows', 'Latency'); Reboot = $true
        Desc = 'Windows 11 ignores high-resolution timer requests from background programs. This restores the older behavior so the 0.5 ms timer held by Game Session can actually reach the game. Reboot required.'
        Rec = $true
        When = { if ($script:Facts.Win11) { $true } else { 'Windows 10 already behaves this way' } }
        Reg = @( (RegItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1) )
    })

    # ======================= NETWORK =======================
    [void]$list.Add(@{
        Id = 'net_nic'; Group = 'Network'; Name = 'Network adapter power saving off'; Impact = 1; Gain = @('Ping', 'Stability')
        Desc = 'Turns off power management and Energy-Efficient Ethernet on your connected physical adapters, which can cause link renegotiation and latency spikes mid-match. Wired connections benefit most.'
        Note = 'Your connection drops for a second or two while the adapter settings are applied.'
        Rec = $true
        Check = { param($t)
            $ads = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
            if (-not $ads) { return $false }
            foreach ($a in $ads) {
                $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue
                if ($pm -and "$($pm.AllowComputerToTurnOffDevice)" -eq 'Enabled') { return $false }
            }
            return $true
        }
        Apply = { param($t)
            $changed = 0
            foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
                try {
                    $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction Stop
                    if ("$($pm.AllowComputerToTurnOffDevice)" -eq 'Enabled') {
                        Set-Extra $t.Id ("pm|" + $a.Name) 'Enabled'
                        Set-NetAdapterPowerManagement -Name $a.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
                        $changed++
                    }
                } catch { Write-Log "Adapter '$($a.Name)': power management not changeable ($($_.Exception.Message))" 'warn' }
                foreach ($kw in '*EEE', 'EEE', 'EeePhyEnable', 'GreenEthernet', 'AdvancedEEE') {
                    $p = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $kw -ErrorAction SilentlyContinue
                    if ($p -and $p.RegistryValue -and ("$($p.RegistryValue[0])" -ne '0')) {
                        try {
                            Set-Extra $t.Id ("adv|" + $a.Name + "|" + $kw) ("$($p.RegistryValue[0])")
                            Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $kw -RegistryValue '0' -ErrorAction Stop
                            $changed++
                        } catch { }
                    }
                }
            }
            if ($changed -eq 0) { Write-Log 'Adapters already had power saving off, or do not expose these settings.' 'info' }
        }
        Undo = { param($t)
            $x = if ($script:Journal.ContainsKey($t.Id)) { $script:Journal[$t.Id].Extra } else { $null }
            if (-not $x) { return }
            foreach ($k in @($x.Keys)) {
                $parts = $k -split '\|'
                try {
                    if ($parts[0] -eq 'pm')  { Set-NetAdapterPowerManagement -Name $parts[1] -AllowComputerToTurnOffDevice Enabled -ErrorAction Stop }
                    if ($parts[0] -eq 'adv') { Set-NetAdapterAdvancedProperty -Name $parts[1] -RegistryKeyword $parts[2] -RegistryValue ([string]$x[$k]) -ErrorAction Stop }
                } catch { }
            }
        }
    })
    [void]$list.Add(@{
        Id = 'net_p2p'; Group = 'Network'; Name = 'Stop Windows Update uploading to other PCs'; Impact = 1; Gain = @('Ping')
        Desc = 'Disables Delivery Optimization peer sharing so Windows never spends your upload bandwidth on updates while you play.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0) )
    })

    # ======================= BACKGROUND LOAD =======================
    [void]$list.Add(@{
        Id = 'bg_apps'; Group = 'Bg'; Name = 'Block Store apps from running in the background'; Impact = 1; Gain = @('Background')
        Desc = 'Per-user switch that stops UWP apps from running and refreshing in the background. Frees a little RAM and idle CPU.'
        Rec = $true
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0) )
    })
    [void]$list.Add(@{
        Id = 'bg_telemetry'; Group = 'Bg'; Name = 'Telemetry service and tasks off'; Impact = 1; Gain = @('Background')
        Desc = 'Disables the DiagTrack service and the compatibility-appraiser / CEIP scheduled tasks. Those are what wake up CompatTelRunner and spike disk and CPU at random times. Also a privacy win.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0) )
        Svc = @( @{ N = 'DiagTrack'; S = 'Disabled'; Stop = $true; D = 'Automatic' }, @{ N = 'dmwappushservice'; S = 'Disabled'; Stop = $true; D = 'Manual' } )
        Tasks = @( '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
                   '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
                   '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
                   '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip' )
    })
    [void]$list.Add(@{
        Id = 'bg_widgets'; Group = 'Bg'; Name = 'Widgets off'; Impact = 1; Gain = @('Background'); Explorer = $true
        Desc = 'Hides the Widgets button and stops the Widgets board and its web-view processes from running.'
        Rec = $true
        When = { if ($script:Facts.Win11) { $true } else { 'Windows 11 only' } }
        Reg = @( (RegItem $prefAdv 'TaskbarDa' 0), (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0) )
    })
    [void]$list.Add(@{
        Id = 'bg_edge'; Group = 'Bg'; Name = 'Edge startup boost and background mode off'; Impact = 1; Gain = @('Background')
        Desc = 'Stops Edge from preloading at sign-in and from staying resident after you close it. Edge is not uninstalled.'
        Note = 'Uses an Edge policy, so edge://policy and Edge settings will say "managed by your organization".'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0), (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0) )
    })
    [void]$list.Add(@{
        Id = 'bg_tips'; Group = 'Bg'; Name = 'Ads, suggestions and auto-installed apps off'; Impact = 0; Gain = @('Background', 'Comfort')
        Desc = 'Turns off Start menu suggestions, lock-screen tips and the silent installs of promoted apps.'
        Rec = $true
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 0),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 0),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 0),
                 (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1) )
    })

    # ======================= STABILITY =======================
    [void]$list.Add(@{
        Id = 'mem_pagefile'; Group = 'Stab'; Name = 'Re-enable the system-managed page file'; Impact = 0; Gain = @('Stability'); Reboot = $true
        Desc = 'Rust can commit well over your RAM size. With no page file, Windows has nowhere to put that and the game can crash with out-of-memory errors even when RAM looks free. Reboot required.'
        Rec = $true
        When = { if (@(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue).Count -gt 0) { 'A page file is already configured' } else { $true } }
        Check = { param($t) return (@(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue).Count -gt 0) }
        Apply = { param($t) $cs = Get-WmiObject Win32_ComputerSystem -EnableAllPrivileges; $cs.AutomaticManagedPagefile = $true; [void]$cs.Put() }
        Undo  = { param($t) Write-Log 'Page file setting left as is. Change it under System > Advanced > Performance if you really want it off.' 'warn' }
    })
    [void]$list.Add(@{
        Id = 'gpu_tdr'; Group = 'Stab'; Name = 'Raise the GPU timeout (TDR) to 10 s'; Impact = 0; Gain = @('Stability'); Reboot = $true
        Desc = 'Gives a busy GPU 10 seconds instead of 2 before Windows resets the driver. Only worth it if you have seen "display driver stopped responding" during shader compiles. A genuine hang takes longer to recover.'
        Rec = $false
        Reg = @( (RegItem $gfx 'TdrDelay' 10), (RegItem $gfx 'TdrDdiDelay' 10) )
    })

    # ======================= ADVANCED =======================
    [void]$list.Add(@{
        Id = 'adv_vbs'; Group = 'Adv'; Name = 'Memory Integrity / VBS off'; Impact = 3; Gain = @('FPS', 'Lows'); Reboot = $true
        Desc = 'Virtualization-based security runs the kernel under the hypervisor, which costs CPU time in games: typically a few percent, more on some systems. Turning it off removes a Windows security layer (kernel exploit protection). Only do this if you accept that.'
        Note = 'Security tradeoff. Reboot required. Not recommended on a PC you also use for banking or work.'
        Rec = $false
        Live = { try {
                    $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
                    if ([int]$dg.VirtualizationBasedSecurityStatus -eq 2) { 'Right now: virtualization-based security is running' + $(if (@($dg.SecurityServicesRunning) -contains 2) { ' (Memory Integrity on).' } else { '.' }) }
                    else { 'Right now: virtualization-based security is not running, so there is nothing to gain here.' }
                 } catch { $null } }
        Reg = @( (RegItem 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0),
                 (RegItem 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0) )
        Check = { param($t)
            $set = $true
            foreach ($it in (Get-TweakRegItems $t)) { if (-not (Test-RegItem $it)) { $set = $false } }
            if ($set) { return $true }
            try { return ([int](Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop).VirtualizationBasedSecurityStatus -ne 2) } catch { return $false }
        }
    })

    # ======================= WINDOWS PREFERENCES (never in "Recommended") =======================
    [void]$list.Add(@{ Id = 'pref_dark'; Group = 'Prefs'; Name = 'Dark mode'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Dark theme for apps and the system UI.'
        Reg = @( (RegItem $personal 'AppsUseLightTheme' 0), (RegItem $personal 'SystemUsesLightTheme' 0) ) })
    [void]$list.Add(@{ Id = 'pref_ext'; Group = 'Prefs'; Name = 'Show file extensions'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Shows .exe, .cfg, .txt and so on in Explorer. Makes it harder to be tricked by "document.pdf.exe".'
        Reg = @( (RegItem $prefAdv 'HideFileExt' 0) ) })
    [void]$list.Add(@{ Id = 'pref_hidden'; Group = 'Prefs'; Name = 'Show hidden files'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Reveals hidden folders such as AppData, where many game configs live.'
        Reg = @( (RegItem $prefAdv 'Hidden' 1) ) })
    [void]$list.Add(@{ Id = 'pref_thispc'; Group = 'Prefs'; Name = 'Explorer opens to This PC'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'File Explorer starts at This PC instead of Home / Quick access.'
        Reg = @( (RegItem $prefAdv 'LaunchTo' 1) ) })
    [void]$list.Add(@{ Id = 'pref_tbleft'; Group = 'Prefs'; Name = 'Taskbar icons on the left'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Moves the Windows 11 taskbar icons and Start button to the left.'
        When = { if ($script:Facts.Win11) { $true } else { 'Windows 11 only' } }
        Reg = @( (RegItem $prefAdv 'TaskbarAl' 0) ) })
    [void]$list.Add(@{ Id = 'pref_context'; Group = 'Prefs'; Name = 'Classic right-click menu'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Brings back the full Windows 10 context menu on Windows 11.'
        When = { if ($script:Facts.Win11) { $true } else { 'Windows 11 only' } }
        Check = { param($t) Test-Path -LiteralPath 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' }
        Apply = { param($t) $k = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'; [void](New-Item -Path $k -Force); Set-ItemProperty -LiteralPath $k -Name '(default)' -Value '' }
        Undo  = { param($t) Remove-Item -LiteralPath 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' -Recurse -Force -ErrorAction SilentlyContinue } })
    [void]$list.Add(@{ Id = 'pref_bing'; Group = 'Prefs'; Name = 'No web results in Start search'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Start search only looks at your PC, not Bing.'
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0), (RegItem 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1) ) })
    [void]$list.Add(@{ Id = 'pref_trans'; Group = 'Prefs'; Name = 'Transparency effects off'; Impact = 0; Gain = @('Comfort')
        Desc = 'Removes acrylic blur from the taskbar and windows. Saves a sliver of GPU on integrated graphics.'
        Reg = @( (RegItem $personal 'EnableTransparency' 0) ) })
    [void]$list.Add(@{ Id = 'pref_endtask'; Group = 'Prefs'; Name = 'End Task on taskbar right-click'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Adds "End task" to the taskbar right-click menu, handy for a frozen game.'
        When = { if ($script:Facts.Build -ge 22631) { $true } else { 'Needs Windows 11 23H2 or newer' } }
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\TaskbarDeveloperSettings' 'TaskbarEndTask' 1) ) })

    return $list.ToArray()
}

function Test-TweakRecommended {
    param($T)
    if ($null -eq $T.Rec) { return $false }
    if ($T.Rec -is [scriptblock]) { return [bool](& $T.Rec) }
    return [bool]$T.Rec
}
# ---- findings: what is actually limiting this PC -------------------------------
function Get-Findings {
    $F = $script:Facts
    $out = New-Object System.Collections.ArrayList
    function Add-Finding { param($Level, $Title, $Detail) [void]$out.Add([pscustomobject]@{ Level = $Level; Title = $Title; Detail = $Detail }) }

    # Refresh rate: the most common free win
    try {
        if ($script:NativeOk) {
            $d = [RomNative]::DisplayInfo()
            if ($d[0] -gt 0) {
                if ($d[1] -gt ($d[0] + 5)) {
                    Add-Finding 'warn' "Your monitor is set to $($d[0]) Hz but supports $($d[1]) Hz" "Windows is not using your panel's full refresh rate at $($d[2])x$($d[3]). Fix it in Settings > System > Display > Advanced display. This is the single most common free upgrade."
                } else {
                    Add-Finding 'ok' "Display is running at $($d[0]) Hz" 'That is the highest rate your panel offers at the current resolution.'
                }
            }
        }
    } catch { }

    # RAM size and speed
    try {
        if ($F.RamGB -gt 0 -and $F.RamGB -lt 15) {
            Add-Finding 'warn' "$($F.RamGB) GB of RAM is tight for Rust" 'Rust regularly wants 12 GB or more for itself. With 8 GB you will see hitching as Windows swaps. More RAM beats any tweak in this app.'
        }
        $mods = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        $conf = ($mods | ForEach-Object { [int]$_.ConfiguredClockSpeed } | Where-Object { $_ -gt 0 } | Measure-Object -Minimum).Minimum
        $rated = ($mods | ForEach-Object { [int]$_.Speed } | Where-Object { $_ -gt 0 } | Measure-Object -Maximum).Maximum
        if ($conf) {
            if ($rated -and $rated -gt ($conf + 200)) {
                Add-Finding 'warn' "RAM runs at $conf MT/s, but it is rated for $rated MT/s" 'The XMP / EXPO / DOCP profile is almost certainly off. Enable it in BIOS. Memory speed is one of the biggest free gains for Rust, mostly in 1% lows.'
            } elseif ($conf -le 2933) {
                Add-Finding 'info' "RAM is running at $conf MT/s" 'If the box or sticker says a higher speed, enable XMP / EXPO / DOCP in BIOS.'
            } else {
                Add-Finding 'ok' "RAM is running at $conf MT/s" 'Memory is clocked at a healthy speed.'
            }
        }
    } catch { }

    # Where Rust is installed
    try {
        if ($F.RustExe) {
            $letter = $F.RustExe.Substring(0, 1)
            $media = $null
            try { $media = [string](Get-Partition -DriveLetter $letter -ErrorAction Stop | Get-Disk -ErrorAction Stop | Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1).MediaType } catch { }
            if ($media -eq 'HDD') {
                Add-Finding 'warn' "Rust is installed on a hard disk ($letter`:)" 'This causes long load times and streaming hitches that no tweak can fix. Move Rust to an SSD (Steam > Properties > Installed Files > Move install folder).'
            } elseif ($media) {
                Add-Finding 'ok' "Rust is on a solid-state drive ($letter`:)" 'Good, asset streaming will not bottleneck on storage.'
            }
            $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$letter`:'" -ErrorAction Stop
            if ($ld.Size -gt 0) {
                $pct = [math]::Round(100 * $ld.FreeSpace / $ld.Size)
                if ($pct -lt 12) { Add-Finding 'warn' "Drive $letter`: is $(100 - $pct)% full" "SSDs slow down and stutter when nearly full. Keep at least 10-15% free (you have $(Format-Bytes $ld.FreeSpace)). The Cleaner tab can help." }
            }
        } else {
            Add-Finding 'info' 'Rust was not found in your Steam libraries' 'Rust-specific tools (GPU preference, config presets, launch options) will unlock once Steam has Rust installed.'
        }
    } catch { }

    # GPUs
    try {
        $gpus = @($F.Gpus)
        if ($gpus.Count -ge 2) {
            Add-Finding 'info' "$($gpus.Count) graphics adapters detected" ((($gpus | ForEach-Object { $_.Name }) -join '  /  ') + '. Make sure Rust runs on the fast one: apply "Use the high-performance GPU" in Optimize.')
        }
    } catch { }

    # Power plan
    try {
        $plan = Get-ActivePlan
        if ($plan) {
            if ($plan.Name -match 'Balanced|saver') {
                Add-Finding 'info' "Power plan: $($plan.Name)" 'Balanced ramps clocks up a beat late. The performance plan in Optimize removes that delay, at the cost of idle power.'
            } else {
                Add-Finding 'ok' "Power plan: $($plan.Name)" 'Already performance-oriented.'
            }
        }
    } catch { }

    # VBS
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        if ([int]$dg.VirtualizationBasedSecurityStatus -eq 2) {
            Add-Finding 'info' 'Virtualization-based security is running' 'It costs some CPU performance in games (often a few percent). Disabling is a security tradeoff, so it is opt-in under Optimize > Advanced.'
        }
    } catch { }

    # Page file
    try {
        if (@(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop).Count -eq 0) {
            Add-Finding 'warn' 'No page file is configured' 'Rust can crash with out-of-memory errors even when RAM looks free. Fix it in Optimize > Stability.'
        }
    } catch { }

    if ($F.X3D) { Add-Finding 'info' 'Ryzen X3D CPU detected' 'Keep Game Mode on and leave core parking alone on dual-CCD models. Rom-Opti already skips the conflicting tweaks for you.' }
    if ($F.Laptop) { Add-Finding 'info' 'Laptop detected' 'Plug in while gaming. The performance tweaks assume AC power and will raise heat and battery drain.' }

    return @($out)
}

# ---- disk cleaner --------------------------------------------------------------
function Get-CleanTasks {
    return @(
        @{ Id = 'usertemp'; Name = 'User temp files'; Rec = $true;  Paths = @($env:TEMP, "$env:LOCALAPPDATA\Temp")
           Desc = 'Leftovers from installers and apps. Anything in use is skipped.' }
        @{ Id = 'wintemp';  Name = 'Windows temp files'; Rec = $true; Paths = @("$env:windir\Temp")
           Desc = 'System-wide temp folder.' }
        @{ Id = 'wu';       Name = 'Windows Update download cache'; Rec = $true; Paths = @("$env:windir\SoftwareDistribution\Download"); Stop = @('wuauserv', 'bits')
           Desc = 'Installers Windows already used. The update services pause during the cleanup and come back afterward.' }
        @{ Id = 'wer';      Name = 'Error reports and crash dumps'; Rec = $true; Paths = @("$env:LOCALAPPDATA\Microsoft\Windows\WER", "$env:ProgramData\Microsoft\Windows\WER", "$env:LOCALAPPDATA\CrashDumps", "$env:windir\Minidump")
           Desc = 'Saved crash data. Skip it if you are actively debugging a crash.' }
        @{ Id = 'thumb';    Name = 'Thumbnail and icon cache'; Rec = $true; Paths = @("$env:LOCALAPPDATA\Microsoft\Windows\Explorer"); Filter = @('thumbcache_*.db', 'iconcache_*.db')
           Desc = 'Rebuilt automatically when needed.' }
        @{ Id = 'shader';   Name = 'GPU shader caches'; Rec = $false; Paths = @("$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\NVIDIA\GLCache", "$env:LOCALAPPDATA\AMD\DxCache", "$env:LOCALAPPDATA\AMD\DxcCache")
           Desc = 'Only clear these if a game stutters after a driver update. They rebuild on next launch, so the first session afterward is hitchier, not smoother.' }
        @{ Id = 'inet';     Name = 'Internet cache (legacy)'; Rec = $false; Paths = @("$env:LOCALAPPDATA\Microsoft\Windows\INetCache")
           Desc = 'Cached web content from the older WinINet store.' }
        @{ Id = 'recycle';  Name = 'Empty the Recycle Bin'; Rec = $false; Special = 'recycle'
           Desc = 'Permanent. Deleted items cannot be recovered afterward.' }
        @{ Id = 'dns';      Name = 'Flush DNS cache'; Rec = $false; Special = 'dns'
           Desc = 'Fixes stale name lookups. Frees no disk space.' }
    )
}

# Runs in a background runspace, so it is fully self-contained.
$script:CleanWork = {
    param($Tasks, [bool]$DoDelete)
    function Get-Files {
        param($Root, $Filters)
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($Root)
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            try { foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                    if ($Filters -and $Filters.Count -gt 0) {
                        $leaf = [System.IO.Path]::GetFileName($f); $hit = $false
                        foreach ($flt in $Filters) { if ($leaf -like $flt) { $hit = $true; break } }
                        if (-not $hit) { continue }
                    }
                    $f } } catch { }
            if ($Filters -and $Filters.Count -gt 0) { continue }
            try { foreach ($d in [System.IO.Directory]::EnumerateDirectories($dir)) { $stack.Push($d) } } catch { }
        }
    }
    $total = 0.0
    foreach ($t in $Tasks) {
        $Q.Enqueue(@{ Kind = 'start'; Id = $t.Id })
        if ($t.Special) {
            if ($DoDelete) {
                if ($t.Special -eq 'recycle') { try { Clear-RecycleBin -Force -ErrorAction Stop; $Q.Enqueue(@{ Kind = 'done'; Id = $t.Id; Text = 'emptied' }) } catch { $Q.Enqueue(@{ Kind = 'done'; Id = $t.Id; Text = 'already empty' }) } }
                if ($t.Special -eq 'dns')     { try { & ipconfig.exe /flushdns | Out-Null; $Q.Enqueue(@{ Kind = 'done'; Id = $t.Id; Text = 'flushed' }) } catch { $Q.Enqueue(@{ Kind = 'done'; Id = $t.Id; Text = 'failed' }) } }
            } else { $Q.Enqueue(@{ Kind = 'done'; Id = $t.Id; Text = '-' }) }
            continue
        }
        $stopped = @()
        if ($DoDelete -and $t.Stop) { foreach ($s in $t.Stop) { try { $svc = Get-Service $s -ErrorAction Stop; if ($svc.Status -eq 'Running') { Stop-Service $s -Force -ErrorAction Stop; $stopped += $s } } catch { } } }
        $bytes = 0.0; $n = 0
        foreach ($root in $t.Paths) {
            if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
            foreach ($f in (Get-Files $root $t.Filter)) {
                try {
                    $len = ([System.IO.FileInfo]$f).Length
                    if ($DoDelete) { [System.IO.File]::Delete($f) }
                    $bytes += $len
                } catch { }
                $n++
                if (($n % 300) -eq 0) { $Q.Enqueue(@{ Kind = 'tick'; Id = $t.Id; Bytes = $bytes }) }
            }
            if ($DoDelete -and -not $t.Filter) {
                try { foreach ($d in [System.IO.Directory]::EnumerateDirectories($root)) { try { [System.IO.Directory]::Delete($d, $true) } catch { } } } catch { }
            }
        }
        foreach ($s in $stopped) { try { Start-Service $s -ErrorAction SilentlyContinue } catch { } }
        $total += $bytes
        $Q.Enqueue(@{ Kind = 'done'; Id = $t.Id; Bytes = $bytes })
    }
    $Q.Enqueue(@{ Kind = 'total'; Bytes = $total })
}

# ---- game session -------------------------------------------------------------
$script:SessionSvcNames = @('SysMain', 'WSearch', 'DiagTrack', 'wuauserv', 'BITS', 'DoSvc', 'WerSvc', 'MapsBroker')
$script:KillGroups = [ordered]@{
    'Web browsers'    = @('chrome', 'msedge', 'firefox', 'opera', 'brave', 'vivaldi')
    'OneDrive'        = @('OneDrive')
    'Epic Launcher'   = @('EpicGamesLauncher', 'EpicWebHelper')
    'Spotify'         = @('Spotify')
    'RGB software'    = @('iCUE', 'LightingService', 'ArmouryCrate.Service', 'ArmourySwAgent', 'RazerAppEngine', 'SteelSeriesGG', 'Lghub', 'lghub_agent')
    'Discord (voice!)' = @('Discord')
}
$script:Session = @{ Active = $false; Timer = $false; Stopped = @(); Prio = $false; Purge = $false; Counters = $null }

function Get-MemSnapshot {
    if (-not $script:Session.Counters) {
        try {
            $c = @{}
            foreach ($n in 'Standby Cache Normal Priority Bytes', 'Standby Cache Reserve Bytes', 'Standby Cache Core Bytes', 'Free & Zero Page List Bytes') {
                $c[$n] = New-Object System.Diagnostics.PerformanceCounter('Memory', $n)
            }
            $script:Session.Counters = $c
        } catch { return $null }
    }
    try {
        $c = $script:Session.Counters
        $standby = $c['Standby Cache Normal Priority Bytes'].NextValue() + $c['Standby Cache Reserve Bytes'].NextValue() + $c['Standby Cache Core Bytes'].NextValue()
        $free = $c['Free & Zero Page List Bytes'].NextValue()
        return @{ Standby = $standby; Free = $free }
    } catch { return $null }
}

function Invoke-PurgeStandby {
    param([switch]$Quiet)
    if (-not $script:NativeOk) { if (-not $Quiet) { Write-Log 'Native helpers did not load, cannot purge.' 'err' }; return }
    $before = Get-MemSnapshot
    $r = [RomNative]::PurgeStandby()
    if ($r -eq 0) {
        $after = Get-MemSnapshot
        if ($before -and $after) { Write-Log ("Standby list purged, {0} returned to free memory." -f (Format-Bytes ([math]::Max(0, $after.Free - $before.Free)))) 'ok' }
        else { Write-Log 'Standby list purged.' 'ok' }
    } else { Write-Log ("Standby purge failed (NTSTATUS 0x{0:X8})." -f $r) 'err' }
}

function Save-SessionState {
    Write-TextFile $script:SessionFile (ConvertTo-Json -InputObject @{ Services = @($script:Session.Stopped) } -Depth 4)
}

function Restore-OrphanedSession {
    # If the app was killed mid-session, services it stopped must not stay stopped.
    if (-not (Test-Path -LiteralPath $script:SessionFile)) { return }
    try {
        $j = Get-Content -LiteralPath $script:SessionFile -Raw | ConvertFrom-Json
        $n = 0
        foreach ($s in @($j.Services)) { if ($s) { try { Start-Service -Name $s -ErrorAction Stop; $n++ } catch { } } }
        Remove-Item -LiteralPath $script:SessionFile -Force -ErrorAction SilentlyContinue
        if ($n -gt 0) { Write-Log "Recovered from an interrupted session: restarted $n service(s)." 'warn' }
    } catch { Remove-Item -LiteralPath $script:SessionFile -Force -ErrorAction SilentlyContinue }
}

function Start-GameSession {
    param($Opt)
    if ($script:Session.Active) { return }
    $script:Session.Active = $true
    if ($Opt.Timer -and $script:NativeOk) {
        $ms = [RomNative]::HoldFinestTimer()
        if ($ms -gt 0) { $script:Session.Timer = $true; Write-Log ("Holding the system timer at {0:N3} ms." -f $ms) 'ok' }
        else { Write-Log 'Windows refused the timer request.' 'err' }
    }
    if ($Opt.Services) {
        $stopped = @()
        foreach ($n in $script:SessionSvcNames) {
            $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                try { Stop-Service -Name $n -Force -ErrorAction Stop; $stopped += $n } catch { }
            }
        }
        $script:Session.Stopped = $stopped
        Save-SessionState
        Write-Log "Paused $($stopped.Count) background service(s) until the session ends." 'ok'
    }
    $script:Session.Prio  = [bool]$Opt.Priority
    $script:Session.Purge = [bool]$Opt.Purge
    $script:Session.Tick  = 0
}

function Stop-GameSession {
    if (-not $script:Session.Active) { return }
    if ($script:Session.Timer -and $script:NativeOk) { [RomNative]::ReleaseTimer(); $script:Session.Timer = $false }
    $n = 0
    foreach ($s in @($script:Session.Stopped)) { try { Start-Service -Name $s -ErrorAction Stop; $n++ } catch { } }
    $script:Session.Stopped = @()
    Remove-Item -LiteralPath $script:SessionFile -Force -ErrorAction SilentlyContinue
    $script:Session.Active = $false; $script:Session.Prio = $false; $script:Session.Purge = $false
    Write-Log "Session ended. Timer released, $n service(s) restarted." 'accent'
}

function Close-BackgroundApps {
    param([string[]]$Names)
    $closed = 0; $ram = 0.0
    $procs = @()
    foreach ($n in $Names) { $procs += @(Get-Process -Name $n -ErrorAction SilentlyContinue) }
    foreach ($p in $procs) { try { $ram += $p.WorkingSet64; [void]$p.CloseMainWindow() } catch { } }
    Start-Sleep -Milliseconds 1500
    foreach ($p in $procs) {
        try { $p.Refresh(); if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction Stop }; $closed++ } catch { }
    }
    if ($closed -gt 0) { Write-Log ("Closed {0} process(es), about {1} of RAM." -f $closed, (Format-Bytes $ram)) 'ok' } else { Write-Log 'Nothing from that selection was running.' 'info' }
}

# ---- Rust: launch options and client.cfg ---------------------------------------
function Get-RustLaunchOptions {
    param($Opt)
    $F = $script:Facts
    $parts = New-Object System.Collections.ArrayList
    if ($Opt.High)    { [void]$parts.Add('-high') }
    if ($Opt.Exclusive) { [void]$parts.Add('-window-mode exclusive') }
    if ($Opt.Cpu -and $F.Cores -gt 0) { [void]$parts.Add("-cpuCount=$($F.Cores)"); [void]$parts.Add("-exThreads=$($F.Threads)") }
    if ($Opt.D3d)     { [void]$parts.Add('-force-d3d11-no-singlethreaded') }
    if ($Opt.NoLog)   { [void]$parts.Add('-nolog') }
    return ($parts -join ' ')
}

# Convars that exist in the live game. gc.buffer is the one with a measurable stutter effect.
$script:RustPresets = @{
    Max = [ordered]@{ 'gc.buffer' = '4096'; 'graphics.shadowdistance' = '0'; 'graphics.shadowlights' = '0'; 'graphics.parallax' = '0'
        'effects.motionblur' = 'false'; 'effects.dof' = 'false'; 'effects.ao' = 'false'; 'effects.vignet' = 'false'; 'effects.shafts' = 'false'; 'effects.lensdirt' = 'false'; 'grass.displacement' = 'false' }
    Competitive = [ordered]@{ 'gc.buffer' = '4096'; 'graphics.shadowdistance' = '75'; 'graphics.shadowlights' = '1'; 'graphics.parallax' = '0'
        'effects.motionblur' = 'false'; 'effects.dof' = 'false'; 'effects.ao' = 'false'; 'effects.vignet' = 'false'; 'effects.shafts' = 'false'; 'effects.lensdirt' = 'false' }
    Balanced = [ordered]@{ 'gc.buffer' = '2048'; 'graphics.shadowdistance' = '150'; 'graphics.shadowlights' = '2'
        'effects.motionblur' = 'false'; 'effects.dof' = 'false'; 'effects.vignet' = 'false'; 'effects.lensdirt' = 'false' }
}

function Get-RustCfgPath {
    if (-not $script:Facts.RustExe) { return $null }
    return (Join-Path (Split-Path $script:Facts.RustExe -Parent) 'cfg\client.cfg')
}

function Set-RustPreset {
    param([string]$Key)
    if (Get-Process -Name RustClient -ErrorAction SilentlyContinue) { throw 'Rust is running. Close it first, it rewrites client.cfg when it exits.' }
    $cfg = Get-RustCfgPath
    if (-not $cfg) { throw 'Rust was not found in your Steam libraries.' }
    if (-not (Test-Path -LiteralPath $cfg)) { throw 'client.cfg does not exist yet. Start Rust once and quit it, then try again.' }
    $bak = "$cfg.romopti.bak"
    if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $cfg -Destination $bak -Force }
    $set = $script:RustPresets[$Key]
    $kept = New-Object System.Collections.ArrayList
    foreach ($ln in (Get-Content -LiteralPath $cfg)) {
        $managed = $false
        foreach ($k in $set.Keys) { if ($ln -match ('^\s*' + [regex]::Escape($k) + '\s')) { $managed = $true; break } }
        if (-not $managed) { [void]$kept.Add($ln) }
    }
    foreach ($k in $set.Keys) { [void]$kept.Add(('{0} "{1}"' -f $k, $set[$k])) }
    Write-TextFile $cfg (($kept -join "`r`n") + "`r`n")
    return $set.Count
}

function Restore-RustCfg {
    $cfg = Get-RustCfgPath
    if (-not $cfg) { throw 'Rust was not found in your Steam libraries.' }
    $bak = "$cfg.romopti.bak"
    if (-not (Test-Path -LiteralPath $bak)) { throw 'No backup exists yet, so nothing has been changed.' }
    if (Get-Process -Name RustClient -ErrorAction SilentlyContinue) { throw 'Close Rust first.' }
    Copy-Item -LiteralPath $bak -Destination $cfg -Force
}

function New-RestorePoint {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $old = Get-RegValue $key 'SystemRestorePointCreationFrequency' $null
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Set-Reg $key 'SystemRestorePointCreationFrequency' 0
        Checkpoint-Computer -Description 'Daqueece Optimizer' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
    } finally {
        if ($null -eq $old) { Remove-RegValue $key 'SystemRestorePointCreationFrequency' } else { Set-Reg $key 'SystemRestorePointCreationFrequency' $old }
    }
}
# ---- UI definition (XAML) -----------------------------------------------------
$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Daqueece Optimizer" Width="1140" Height="740"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="CanMinimize" FontFamily="Segoe UI"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg0" Color="#0A0C0F"/>
    <SolidColorBrush x:Key="Bg1" Color="#0F1217"/>
    <SolidColorBrush x:Key="Bg2" Color="#151920"/>
    <SolidColorBrush x:Key="Bg3" Color="#1B2028"/>
    <SolidColorBrush x:Key="Line" Color="#232933"/>
    <SolidColorBrush x:Key="Text" Color="#E8EBEF"/>
    <SolidColorBrush x:Key="Muted" Color="#8D96A3"/>
    <SolidColorBrush x:Key="Dim" Color="#5C6573"/>
    <SolidColorBrush x:Key="Accent" Color="#E8743B"/>
    <SolidColorBrush x:Key="AccentHi" Color="#F58A55"/>
    <SolidColorBrush x:Key="Good" Color="#3FB950"/>
    <SolidColorBrush x:Key="Warn" Color="#D9A23A"/>
    <SolidColorBrush x:Key="Bad" Color="#E5534B"/>

    <!-- sidebar navigation -->
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="10,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" CornerRadius="8" Background="Transparent" Padding="12,10">
              <Grid>
                <Rectangle x:Name="bar" Width="3" Height="16" RadiusX="1.5" RadiusY="1.5" Fill="{StaticResource Accent}" HorizontalAlignment="Left" Margin="-12,0,0,0" Visibility="Collapsed"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Bg2}"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Bg3}"/>
                <Setter TargetName="bar" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- buttons -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Background" Value="{StaticResource Bg3}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.86"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="#14100D"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="{StaticResource Bad}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="#4A2A2B"/>
    </Style>
    <Style x:Key="Chrome" TargetType="Button">
      <Setter Property="Width" Value="38"/><Setter Property="Height" Value="30"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="{StaticResource Bg3}"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- the big landing-page button -->
    <Style x:Key="Enter" TargetType="Button">
      <Setter Property="Foreground" Value="#160E09"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="30" Padding="46,17" RenderTransformOrigin="0.5,0.5">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                  <GradientStop Color="#F58A55" Offset="0"/>
                  <GradientStop Color="#E0612B" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <Border.Effect><DropShadowEffect Color="#E8743B" BlurRadius="30" Opacity="0.42" ShadowDepth="0"/></Border.Effect>
              <Border.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Border.RenderTransform>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Effect">
                  <Setter.Value><DropShadowEffect Color="#F58A55" BlurRadius="46" Opacity="0.7" ShadowDepth="0"/></Setter.Value>
                </Setter>
                <Setter TargetName="bd" Property="RenderTransform">
                  <Setter.Value><ScaleTransform ScaleX="1.035" ScaleY="1.035"/></Setter.Value>
                </Setter>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="RenderTransform">
                  <Setter.Value><ScaleTransform ScaleX="0.98" ScaleY="0.98"/></Setter.Value>
                </Setter>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- toggle switch (tweaks, session options) -->
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="track" Width="38" Height="21" CornerRadius="10.5" Background="#2B323D" VerticalAlignment="Center">
                <Ellipse x:Name="knob" Width="15" Height="15" Fill="#C9D0DA" HorizontalAlignment="Left" Margin="3,0,0,0"/>
              </Border>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="knob" Property="Margin" Value="0,0,3,0"/>
                <Setter TargetName="knob" Property="Fill" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,5,16,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.5" BorderBrush="#3A4250" Background="#10141A" VerticalAlignment="Center">
                <Path x:Name="tick" Data="M 4,9.5 L 7.5,13 L 14,5" Stroke="#14100D" StrokeThickness="2.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Bg2}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18"/>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="{StaticResource Bg3}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="MaxWidth" Value="360"/>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Background" Value="#1D232C"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border Background="{TemplateBinding Background}" CornerRadius="4">
              <Grid ClipToBounds="True">
                <Border x:Name="PART_Track"/>
                <Border x:Name="PART_Indicator" HorizontalAlignment="Left" CornerRadius="4" Background="{TemplateBinding Foreground}"/>
              </Grid>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border x:Name="tb" Background="#2A313C" CornerRadius="4" Margin="1"/>
                        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="tb" Property="Background" Value="#3D4756"/></Trigger></ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="frame" Background="{StaticResource Bg0}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="14">
    <Grid>

      <!-- ===================== LANDING ===================== -->
      <Grid x:Name="landing" Background="Transparent">
        <Border CornerRadius="14">
          <Border.Background>
            <RadialGradientBrush Center="0.5,0.46" GradientOrigin="0.5,0.46" RadiusX="0.62" RadiusY="0.62">
              <GradientStop Color="#1FE8743B" Offset="0"/>
              <GradientStop Color="#0AE8743B" Offset="0.45"/>
              <GradientStop Color="#00000000" Offset="1"/>
            </RadialGradientBrush>
          </Border.Background>
        </Border>
        <Ellipse x:Name="glow" Width="560" Height="560" IsHitTestVisible="False" Opacity="0.55" Margin="0,0,0,40">
          <Ellipse.Fill>
            <RadialGradientBrush>
              <GradientStop Color="#2CE8743B" Offset="0"/>
              <GradientStop Color="#00E8743B" Offset="1"/>
            </RadialGradientBrush>
          </Ellipse.Fill>
        </Ellipse>

        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,10,10,0">
          <Button x:Name="lnMin" Style="{StaticResource Chrome}" Content="&#xE921;"/>
          <Button x:Name="lnClose" Style="{StaticResource Chrome}" Content="&#xE8BB;"/>
        </StackPanel>

        <StackPanel x:Name="hero" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0" Margin="0,-10,0,0">
          <StackPanel.RenderTransform><TranslateTransform x:Name="heroShift" Y="18"/></StackPanel.RenderTransform>

          <Border Width="68" Height="68" CornerRadius="18" HorizontalAlignment="Center" BorderBrush="#55E8743B" BorderThickness="1" Background="#14E8743B">
            <Border.Effect><DropShadowEffect Color="#E8743B" BlurRadius="26" Opacity="0.35" ShadowDepth="0"/></Border.Effect>
            <Viewbox Width="30" Height="30">
              <Path Data="M 15,1 L 3,17 L 11,17 L 9,29 L 23,11 L 14,11 Z" Fill="{StaticResource Accent}"/>
            </Viewbox>
          </Border>

          <TextBlock x:Name="lnTag" Margin="0,30,0,0" HorizontalAlignment="Center" FontSize="11" FontWeight="SemiBold" Foreground="{StaticResource Dim}"/>
          <TextBlock x:Name="lnTitle" Margin="0,10,0,0" HorizontalAlignment="Center" FontFamily="Bahnschrift, Segoe UI Semibold" FontSize="64" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
          <TextBlock x:Name="lnSub" Margin="0,2,0,0" HorizontalAlignment="Center" FontFamily="Bahnschrift, Segoe UI Semibold" FontSize="22" FontWeight="SemiBold" Foreground="{StaticResource Accent}"/>
          <TextBlock x:Name="lnLine" Margin="0,26,0,0" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" MaxWidth="470" FontSize="14" LineHeight="22" Foreground="{StaticResource Muted}"
                     Text="Tune Windows for higher FPS and steadier frametimes. Every change is journaled and fully reversible, and every toggle tells you what it is actually worth."/>

          <Button x:Name="btnEnter" Style="{StaticResource Enter}" HorizontalAlignment="Center" Margin="0,38,0,0"/>

          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,34,0,0">
            <Border Background="{StaticResource Bg1}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="14" Padding="12,5" Margin="4,0">
              <TextBlock Text="Fully reversible" FontSize="11.5" Foreground="{StaticResource Muted}"/>
            </Border>
            <Border Background="{StaticResource Bg1}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="14" Padding="12,5" Margin="4,0">
              <TextBlock Text="No game injection" FontSize="11.5" Foreground="{StaticResource Muted}"/>
            </Border>
            <Border Background="{StaticResource Bg1}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="14" Padding="12,5" Margin="4,0">
              <TextBlock Text="Honest impact ratings" FontSize="11.5" Foreground="{StaticResource Muted}"/>
            </Border>
          </StackPanel>
        </StackPanel>

        <TextBlock x:Name="lnSys" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,22" FontSize="11.5" Foreground="{StaticResource Dim}"/>
      </Grid>

      <!-- ===================== APP ===================== -->
      <Grid x:Name="app" Visibility="Collapsed" Opacity="0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="238"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- sidebar -->
        <Border Grid.Column="0" Background="{StaticResource Bg1}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0" CornerRadius="14,0,0,14">
          <DockPanel LastChildFill="True">
            <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="22,24,16,22">
              <Border Width="34" Height="34" CornerRadius="10" Background="#18E8743B" BorderBrush="#44E8743B" BorderThickness="1">
                <Viewbox Width="16" Height="16"><Path Data="M 15,1 L 3,17 L 11,17 L 9,29 L 23,11 L 14,11 Z" Fill="{StaticResource Accent}"/></Viewbox>
              </Border>
              <StackPanel Margin="11,0,0,0" VerticalAlignment="Center">
                <TextBlock Text="DAQUEECE" FontFamily="Bahnschrift, Segoe UI Semibold" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                <TextBlock Text="OPTIMIZER" FontFamily="Bahnschrift, Segoe UI Semibold" FontSize="10.5" Foreground="{StaticResource Accent}"/>
              </StackPanel>
            </StackPanel>

            <Border DockPanel.Dock="Bottom" Margin="14,10,14,16" Padding="12,10" Background="{StaticResource Bg2}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="10">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <Ellipse x:Name="sideDot" Width="7" Height="7" Fill="{StaticResource Dim}" VerticalAlignment="Center"/>
                  <TextBlock x:Name="sideTitle" Text="No active session" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Text}" Margin="8,0,0,0"/>
                </StackPanel>
                <TextBlock x:Name="sideSub" Margin="15,3,0,0" FontSize="11" Foreground="{StaticResource Dim}" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>

            <StackPanel DockPanel.Dock="Top">
              <RadioButton x:Name="navDash" Style="{StaticResource Nav}" GroupName="N" IsChecked="True">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE80F;"/><TextBlock Text="Dashboard"/></StackPanel></RadioButton>
              <RadioButton x:Name="navOpt" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE945;"/><TextBlock Text="Optimize"/></StackPanel></RadioButton>
              <RadioButton x:Name="navRust" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE7FC;"/><TextBlock Text="Rust"/></StackPanel></RadioButton>
              <RadioButton x:Name="navSession" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE768;"/><TextBlock Text="Game session"/></StackPanel></RadioButton>
              <RadioButton x:Name="navClean" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE74D;"/><TextBlock Text="Cleaner"/></StackPanel></RadioButton>
              <RadioButton x:Name="navLog" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE8A5;"/><TextBlock Text="Activity log"/></StackPanel></RadioButton>
            </StackPanel>
          </DockPanel>
        </Border>

        <!-- content -->
        <Grid Grid.Column="1">
          <Grid.RowDefinitions>
            <RowDefinition Height="74"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="36"/>
          </Grid.RowDefinitions>

          <Border x:Name="header" Grid.Row="0" Background="Transparent">
            <DockPanel Margin="30,0,10,0">
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top" Margin="0,10,0,0">
                <Button x:Name="appMin" Style="{StaticResource Chrome}" Content="&#xE921;"/>
                <Button x:Name="appClose" Style="{StaticResource Chrome}" Content="&#xE8BB;"/>
              </StackPanel>
              <StackPanel VerticalAlignment="Center">
                <TextBlock x:Name="pageTitle" FontSize="22" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                <TextBlock x:Name="pageSub" FontSize="12.5" Foreground="{StaticResource Muted}" Margin="0,3,0,0"/>
              </StackPanel>
            </DockPanel>
          </Border>

          <Grid Grid.Row="1" Margin="30,4,30,8">

            <!-- Dashboard -->
            <ScrollViewer x:Name="pgDash" VerticalScrollBarVisibility="Auto">
              <StackPanel Margin="0,0,10,12">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Border Grid.Column="0" Style="{StaticResource Card}">
                    <StackPanel>
                      <TextBlock Text="THIS PC" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="dCpu" Margin="0,10,0,0" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/>
                      <TextBlock x:Name="dGpu" Margin="0,5,0,0" FontSize="12.5" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                      <TextBlock x:Name="dRam" Margin="0,5,0,0" FontSize="12.5" Foreground="{StaticResource Muted}"/>
                      <TextBlock x:Name="dOs" Margin="0,5,0,0" FontSize="12.5" Foreground="{StaticResource Muted}"/>
                    </StackPanel>
                  </Border>
                  <Border Grid.Column="2" Style="{StaticResource Card}">
                    <StackPanel>
                      <TextBlock Text="RECOMMENDED TWEAKS" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Dim}"/>
                      <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                        <TextBlock x:Name="dApplied" FontSize="34" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                        <TextBlock x:Name="dTotal" FontSize="16" Foreground="{StaticResource Dim}" VerticalAlignment="Bottom" Margin="6,0,0,6"/>
                      </StackPanel>
                      <ProgressBar x:Name="dBar" Minimum="0" Maximum="100" Value="0" Margin="0,8,0,0"/>
                      <TextBlock x:Name="dAppliedNote" Margin="0,9,0,0" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                    </StackPanel>
                  </Border>
                  <Border Grid.Column="4" Style="{StaticResource Card}">
                    <StackPanel>
                      <TextBlock Text="RUST" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="dRust" Margin="0,10,0,0" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/>
                      <TextBlock x:Name="dRustSub" Margin="0,5,0,0" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                    </StackPanel>
                  </Border>
                </Grid>

                <DockPanel Margin="0,26,0,10" LastChildFill="False">
                  <StackPanel DockPanel.Dock="Left">
                    <TextBlock Text="What is actually limiting your FPS" FontSize="15" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Text="Checked against this PC right now. Fix the orange items first, they matter more than any registry tweak." FontSize="12" Foreground="{StaticResource Muted}" Margin="0,3,0,0"/>
                  </StackPanel>
                  <Button x:Name="btnRescan" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Rescan" VerticalAlignment="Center"/>
                </DockPanel>
                <StackPanel x:Name="pnlFindings"/>

                <Button x:Name="btnGoOpt" Style="{StaticResource BtnPrimary}" Content="Review recommended tweaks" HorizontalAlignment="Left" Margin="0,18,0,0" Padding="22,12"/>
              </StackPanel>
            </ScrollViewer>

            <!-- Optimize -->
            <Grid x:Name="pgOpt" Visibility="Collapsed">
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <StackPanel Grid.Row="0">
                <Border Style="{StaticResource Card}" Padding="14,10" Margin="0,0,0,10">
                  <TextBlock FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                    Text="Honest expectations: most Windows tweaks are worth a few percent at best and help 1% lows and latency more than average FPS. Each toggle shows an impact rating. Your old values are saved before any change, so Revert restores exactly what you had."/>
                </Border>
                <Border x:Name="bannerReboot" Visibility="Collapsed" Background="#1F1A0E" BorderBrush="#5A4A1E" BorderThickness="1" CornerRadius="10" Padding="14,9" Margin="0,0,0,10">
                  <TextBlock x:Name="bannerRebootText" FontSize="12.5" Foreground="{StaticResource Warn}" TextWrapping="Wrap"/>
                </Border>
              </StackPanel>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="pnlTweaks" Margin="0,0,10,8"/></ScrollViewer>
              <Border Grid.Row="2" Style="{StaticResource Card}" Padding="16,12" Margin="0,6,0,0">
                <DockPanel LastChildFill="False">
                  <CheckBox x:Name="chkRestore" Style="{StaticResource Switch}" Content="Create a restore point first" IsChecked="True" DockPanel.Dock="Left" VerticalAlignment="Center" Foreground="{StaticResource Muted}" FontSize="12.5"/>
                  <Button x:Name="btnOptApply" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Content="Apply selected" Margin="8,0,0,0"/>
                  <Button x:Name="btnOptRevert" DockPanel.Dock="Right" Style="{StaticResource BtnDanger}" Content="Revert selected" Margin="8,0,0,0"/>
                  <Button x:Name="btnOptClear" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Clear" Margin="8,0,0,0"/>
                  <Button x:Name="btnOptRec" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Select recommended"/>
                </DockPanel>
              </Border>
            </Grid>

            <!-- Rust -->
            <ScrollViewer x:Name="pgRust" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
              <StackPanel Margin="0,0,10,12">
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Steam launch options" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,4,0,12" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                      Text="Pick the flags you want, copy, then paste into Steam > Rust > Properties > General > Launch Options. The thread counts are filled in from your CPU. Gains are small and vary by system. If anything misbehaves, remove that flag."/>
                    <WrapPanel>
                      <CheckBox x:Name="loHigh" Style="{StaticResource Switch}" Content="-high   (raise process priority)" IsChecked="True" Margin="0,5,26,5"/>
                      <CheckBox x:Name="loExcl" Style="{StaticResource Switch}" Content="-window-mode exclusive" IsChecked="True" Margin="0,5,26,5"/>
                      <CheckBox x:Name="loCpu" Style="{StaticResource Switch}" Content="-cpuCount / -exThreads" IsChecked="True" Margin="0,5,26,5"/>
                      <CheckBox x:Name="loD3d" Style="{StaticResource Switch}" Content="-force-d3d11-no-singlethreaded" IsChecked="True" Margin="0,5,26,5"/>
                      <CheckBox x:Name="loLog" Style="{StaticResource Switch}" Content="-nolog" IsChecked="True" Margin="0,5,26,5"/>
                    </WrapPanel>
                    <Border Background="{StaticResource Bg0}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Padding="12,10" Margin="0,12,0,0">
                      <TextBox x:Name="txtLaunch" IsReadOnly="True" Background="Transparent" BorderThickness="0" FontFamily="Consolas" FontSize="12.5" Foreground="{StaticResource AccentHi}" TextWrapping="Wrap"/>
                    </Border>
                    <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                      <Button x:Name="btnCopyLaunch" Style="{StaticResource BtnPrimary}" Content="Copy to clipboard"/>
                      <TextBlock x:Name="txtLaunchNote" Margin="14,0,0,0" VerticalAlignment="Center" FontSize="12" Foreground="{StaticResource Muted}"/>
                    </StackPanel>
                    <TextBlock Margin="0,12,0,0" FontSize="11.5" Foreground="{StaticResource Dim}" TextWrapping="Wrap"
                      Text="Left out on purpose: -maxMem and -malloc=system from older guides. They are folklore for this game, and the system allocator can make things worse."/>
                  </StackPanel>
                </Border>

                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Graphics config presets" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,4,0,12" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                      Text="Writes real in-game convars to client.cfg, the same values the F1 console saves, so it is EAC-safe. The biggest single stutter fix here is a larger gc.buffer. Rust must be closed. A backup is made the first time, and Restore puts it back."/>
                    <WrapPanel>
                      <Button x:Name="btnPreMax" Style="{StaticResource Btn}" Content="Max FPS" Margin="0,0,8,8"/>
                      <Button x:Name="btnPreComp" Style="{StaticResource Btn}" Content="Competitive" Margin="0,0,8,8"/>
                      <Button x:Name="btnPreBal" Style="{StaticResource Btn}" Content="Balanced" Margin="0,0,8,8"/>
                      <Button x:Name="btnPreRestore" Style="{StaticResource BtnDanger}" Content="Restore backup" Margin="0,0,8,8"/>
                    </WrapPanel>
                    <TextBlock x:Name="txtPreStatus" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                    <TextBlock Margin="0,10,0,0" FontSize="11.5" Foreground="{StaticResource Dim}" TextWrapping="Wrap"
                      Text="Max FPS: shadows off, all post effects off. Competitive: short shadows kept so you can still see players in them. Balanced: looks decent, still avoids the expensive effects."/>
                  </StackPanel>
                </Border>

                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="Things that move FPS more than any tweak" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,8,0,0" FontSize="12.5" Foreground="{StaticResource Muted}" TextWrapping="Wrap" LineHeight="20"
                      Text="1. Enable XMP / EXPO in BIOS (see Dashboard).&#10;2. Run Rust from an SSD with free space.&#10;3. Do a clean GPU driver install (DDU in Safe Mode) if you have unexplained stutter.&#10;4. Cap your FPS a few frames below your refresh rate for smoother frametimes.&#10;5. In-game, render distance and shadows cost the most. Type perf 1 in F1 to watch your real numbers while you test."/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>

            <!-- Game session -->
            <ScrollViewer x:Name="pgSession" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
              <StackPanel Margin="0,0,10,12">
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Session boosts" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,4,0,12" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                      Text="These run only while a session is active and undo themselves when it ends or when you close Daqueece Optimizer. Startup settings are never changed, so nothing is left behind if something crashes."/>
                    <CheckBox x:Name="sesTimer" Style="{StaticResource Switch}" Content="Hold the finest system timer (usually 0.5 ms)" IsChecked="True" Margin="0,5"/>
                    <CheckBox x:Name="sesPurge" Style="{StaticResource Switch}" Content="Smart standby-memory cleaner (only when free memory runs low)" IsChecked="True" Margin="0,5"/>
                    <CheckBox x:Name="sesPrio" Style="{StaticResource Switch}" Content="Set RustClient to High priority when it starts" IsChecked="True" Margin="0,5"/>
                    <CheckBox x:Name="sesSvc" Style="{StaticResource Switch}" Content="Pause background services (search indexing, Windows Update, telemetry, SysMain)" Margin="0,5"/>
                    <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                      <Button x:Name="btnSesToggle" Style="{StaticResource BtnPrimary}" Content="Start session" Padding="26,11"/>
                      <CheckBox x:Name="sesAuto" Content="Start and stop automatically with Rust" Margin="18,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <TextBlock x:Name="txtSesStatus" Margin="0,12,0,0" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                    <TextBlock Margin="0,10,0,0" FontSize="11.5" Foreground="{StaticResource Dim}" TextWrapping="Wrap"
                      Text="Keep this window open (it can sit minimized) while you play. On Windows 11 the timer only reaches the game if the global timer tweak is applied and you have rebooted."/>
                  </StackPanel>
                </Border>

                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="Close background apps" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,4,0,10" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                      Text="Asks each app to close first, then ends whatever is left. Save your work. Steam is never touched, Rust runs under it."/>
                    <WrapPanel x:Name="pnlKill"/>
                    <Button x:Name="btnKill" Style="{StaticResource BtnDanger}" Content="Close selected" HorizontalAlignment="Left" Margin="0,10,0,0"/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>

            <!-- Cleaner -->
            <Grid x:Name="pgClean" Visibility="Collapsed">
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
                <Button x:Name="btnScan" Style="{StaticResource Btn}" Content="Scan sizes"/>
                <Button x:Name="btnCleanRec" Style="{StaticResource Btn}" Content="Select recommended" Margin="8,0,0,0"/>
                <Button x:Name="btnCleanNone" Style="{StaticResource Btn}" Content="Clear" Margin="8,0,0,0"/>
                <Button x:Name="btnCleanRun" Style="{StaticResource BtnPrimary}" Content="Clean selected" Margin="8,0,0,0"/>
              </StackPanel>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="pnlClean" Margin="0,0,10,0"/></ScrollViewer>
              <Border Grid.Row="2" Style="{StaticResource Card}" Padding="16,12" Margin="0,10,0,0">
                <StackPanel>
                  <DockPanel>
                    <TextBlock x:Name="txtCleanTotal" DockPanel.Dock="Right" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Accent}"/>
                    <TextBlock x:Name="txtCleanStatus" FontSize="12" Foreground="{StaticResource Muted}" Text="Idle."/>
                  </DockPanel>
                  <ProgressBar x:Name="barClean" Minimum="0" Maximum="100" Value="0" Margin="0,9,0,0"/>
                </StackPanel>
              </Border>
            </Grid>

            <!-- Log -->
            <Grid x:Name="pgLog" Visibility="Collapsed">
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
                <Button x:Name="btnLogFile" Style="{StaticResource Btn}" Content="Open log file"/>
                <Button x:Name="btnLogClear" Style="{StaticResource Btn}" Content="Clear view" Margin="8,0,0,0"/>
              </StackPanel>
              <Border Grid.Row="1" Style="{StaticResource Card}" Padding="12">
                <ListBox x:Name="logList" Background="Transparent" BorderThickness="0" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                  <ListBox.ItemContainerStyle>
                    <Style TargetType="ListBoxItem">
                      <Setter Property="Padding" Value="0"/><Setter Property="Margin" Value="0"/>
                      <Setter Property="Focusable" Value="False"/>
                      <Setter Property="Template">
                        <Setter.Value><ControlTemplate TargetType="ListBoxItem"><ContentPresenter/></ControlTemplate></Setter.Value>
                      </Setter>
                    </Style>
                  </ListBox.ItemContainerStyle>
                </ListBox>
              </Border>
            </Grid>
          </Grid>

          <Border Grid.Row="2" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0">
            <DockPanel Margin="30,0,24,0">
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                <Ellipse Width="6" Height="6" Fill="{StaticResource Good}" VerticalAlignment="Center"/>
                <TextBlock Text="Administrator" FontSize="11" Foreground="{StaticResource Dim}" Margin="7,0,0,0"/>
              </StackPanel>
              <TextBlock x:Name="lastLog" FontSize="11.5" Foreground="{StaticResource Dim}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Text="Ready."/>
            </DockPanel>
          </Border>
        </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
'@
# ---- UI helpers ---------------------------------------------------------------
function Get-Res { param([string]$Key) return $script:UI.Win.FindResource($Key) }

function Space-Text {
    param([string]$s)
    return (($s.ToCharArray() | ForEach-Object { [string]$_ }) -join [string][char]0x2009)
}

function New-Tb {
    param([string]$Text, [double]$Size = 12.5, [string]$Brush = 'Muted', [bool]$Bold = $false)
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = $Size
    $tb.TextWrapping = 'Wrap'
    $tb.Foreground = Get-Res $Brush
    if ($Bold) { $tb.FontWeight = 'SemiBold' }
    return $tb
}

function New-Chip {
    param([string]$Text, [string]$Fg = 'Muted', [string]$Bg = 'Bg3')
    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = New-Object Windows.CornerRadius 9
    $b.Padding = '8,2'
    $b.Margin = '0,0,6,0'
    $b.Background = Get-Res $Bg
    $b.VerticalAlignment = 'Center'
    $t = New-Tb $Text 10.5 $Fg $true
    $t.TextWrapping = 'NoWrap'
    $b.Child = $t
    return $b
}

function Invoke-Safe {
    param([scriptblock]$Block, [string]$What = 'Action')
    try { & $Block } catch { Write-Log "$What failed: $($_.Exception.Message)" 'err' }
}

function Set-Busy {
    param([bool]$Busy, [string[]]$Buttons)
    foreach ($n in $Buttons) { $script:UI[$n].IsEnabled = -not $Busy }
    $script:UI.Win.Cursor = if ($Busy) { [Windows.Input.Cursors]::Wait } else { $null }
}

# ---- pages --------------------------------------------------------------------
$script:PageMeta = [ordered]@{
    dash    = @{ Title = 'Dashboard';     Sub = 'Your PC at a glance, and what is really holding back your FPS.' }
    opt     = @{ Title = 'Optimize';      Sub = 'Toggle what you want, then apply. Everything is journaled and reversible.' }
    rust    = @{ Title = 'Rust';          Sub = 'Launch options and graphics config tuned for RustClient.' }
    session = @{ Title = 'Game session';  Sub = 'Boosts that run only while you play, then undo themselves.' }
    clean   = @{ Title = 'Cleaner';       Sub = 'Free disk space. Nothing is deleted until you confirm.' }
    log     = @{ Title = 'Activity log';  Sub = 'Everything this app has done on this PC.' }
}
$script:PageCtl = @{ dash = 'pgDash'; opt = 'pgOpt'; rust = 'pgRust'; session = 'pgSession'; clean = 'pgClean'; log = 'pgLog' }

function Show-Page {
    param([string]$Key)
    $ui = $script:UI
    foreach ($k in $script:PageCtl.Keys) { $ui[$script:PageCtl[$k]].Visibility = 'Collapsed' }
    $ui[$script:PageCtl[$Key]].Visibility = 'Visible'
    $ui.pageTitle.Text = $script:PageMeta[$Key].Title
    $ui.pageSub.Text   = $script:PageMeta[$Key].Sub
    switch ($Key) {
        'dash'    { Update-Dashboard -KeepFindings }
        'opt'     { Update-AllCards }
        'rust'    { Update-Launch }
        'session' { Update-SessionUi }
        'clean'   { if (-not $script:CleanBuilt) { Build-CleanPage } }
    }
}

# ---- dashboard ----------------------------------------------------------------
function Update-Side {
    $ui = $script:UI
    if ($script:Session.Active) {
        $ui.sideDot.Fill = Get-Res 'Good'
        $ui.sideTitle.Text = 'Session active'
        $bits = @()
        if ($script:Session.Timer) { $bits += 'timer held' }
        if (@($script:Session.Stopped).Count -gt 0) { $bits += "$(@($script:Session.Stopped).Count) services paused" }
        if ($script:Session.Prio) { $bits += 'Rust priority' }
        if ($script:Session.Purge) { $bits += 'memory cleaner' }
        $ui.sideSub.Text = ($bits -join ', ')
    } else {
        $ui.sideDot.Fill = Get-Res 'Dim'
        $ui.sideTitle.Text = 'No active session'
        $n = $script:Journal.Count
        $ui.sideSub.Text = if ($n -gt 0) { "$n tweak(s) applied by this app" } else { 'No tweaks applied yet' }
    }
}

function Update-DashStats {
    $ui = $script:UI
    $total = 0; $done = 0
    foreach ($id in $script:Cards.Keys) {
        $c = $script:Cards[$id]
        if ($c.Blocked) { continue }
        $rec = $false
        try { $rec = Test-TweakRecommended $c.Tweak } catch { }
        if (-not $rec) { continue }
        $total++
        if ($c.Applied) { $done++ }
    }
    $ui.dApplied.Text = "$done"
    $ui.dTotal.Text = "/ $total"
    $ui.dBar.Value = if ($total -gt 0) { [math]::Round(100 * $done / $total) } else { 0 }
    $ui.dAppliedNote.Text = if ($done -ge $total -and $total -gt 0) { 'Everything recommended for this PC is applied.' } else { "$($total - $done) recommended tweak(s) available for this PC." }
}

function Update-Dashboard {
    param([switch]$KeepFindings)
    $ui = $script:UI; $F = $script:Facts
    $ui.dCpu.Text = $F.CpuName
    $ui.dGpu.Text = if (@($F.Gpus).Count -gt 0) { (@($F.Gpus) | ForEach-Object { $_.Name }) -join ' + ' } else { 'GPU not detected' }
    $ui.dRam.Text = "$($F.RamGB) GB RAM"
    $ui.dOs.Text  = $F.OsName
    if ($F.RustExe) { $ui.dRust.Text = 'Rust found'; $ui.dRustSub.Text = $F.RustExe }
    else { $ui.dRust.Text = 'Rust not found'; $ui.dRustSub.Text = 'Install Rust through Steam to unlock the Rust tools.' }
    Update-DashStats
    Update-Side
    if ($KeepFindings -and $script:FindingsDone) { return }
    $ui.pnlFindings.Children.Clear()
    [void]$ui.pnlFindings.Children.Add((New-Tb 'Scanning this PC...' 12.5 'Muted'))
    Invoke-UiPump
    $items = @()
    try { $items = Get-Findings } catch { Write-Log "Scan failed: $($_.Exception.Message)" 'err' }
    $ui.pnlFindings.Children.Clear()
    $order = @{ warn = 0; info = 1; ok = 2 }
    foreach ($f in ($items | Sort-Object { $order[$_.Level] })) {
        $row = New-Object Windows.Controls.Border
        $row.Background = Get-Res 'Bg2'
        $row.BorderBrush = Get-Res 'Line'
        $row.BorderThickness = '1'
        $row.CornerRadius = New-Object Windows.CornerRadius 10
        $row.Padding = '14,11'
        $row.Margin = '0,0,0,8'
        $g = New-Object Windows.Controls.Grid
        $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = 'Auto'
        $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = '*'
        [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1)
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 9; $dot.Height = 9; $dot.Margin = '0,5,14,0'; $dot.VerticalAlignment = 'Top'
        $dot.Fill = switch ($f.Level) { 'warn' { Get-Res 'Accent' } 'ok' { Get-Res 'Good' } default { Get-Res 'Dim' } }
        $sp = New-Object Windows.Controls.StackPanel
        [void]$sp.Children.Add((New-Tb $f.Title 13 'Text' $true))
        $d = New-Tb $f.Detail 12 'Muted'; $d.Margin = '0,3,0,0'
        [void]$sp.Children.Add($d)
        [Windows.Controls.Grid]::SetColumn($sp, 1)
        [void]$g.Children.Add($dot); [void]$g.Children.Add($sp)
        $row.Child = $g
        [void]$ui.pnlFindings.Children.Add($row)
    }
    $script:FindingsDone = $true
}

# ---- optimize page ------------------------------------------------------------
$script:Cards = @{}
$script:Sel = New-Object 'System.Collections.Generic.HashSet[string]'
$script:OptBuilt = $false

function New-TweakCard {
    param($T)
    $blocked = $null
    try { $blocked = Get-TweakBlock $T } catch { }

    $card = New-Object Windows.Controls.Border
    $card.Background = Get-Res 'Bg2'
    $card.BorderBrush = Get-Res 'Line'
    $card.BorderThickness = '1'
    $card.CornerRadius = New-Object Windows.CornerRadius 10
    $card.Padding = '14,12'
    $card.Margin = '0,0,0,8'

    $g = New-Object Windows.Controls.Grid
    foreach ($w in 'Auto', '*', 'Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$g.ColumnDefinitions.Add($cd) }

    $sw = New-Object Windows.Controls.CheckBox
    $sw.Style = Get-Res 'Switch'
    $sw.Tag = $T.Id
    $sw.VerticalAlignment = 'Top'
    $sw.Margin = '0,2,16,0'
    $sw.Add_Checked({ param($s, $e) [void]$script:Sel.Add([string]$s.Tag) })
    $sw.Add_Unchecked({ param($s, $e) [void]$script:Sel.Remove([string]$s.Tag) })
    $sw.IsChecked = $script:Sel.Contains($T.Id)
    [void]$g.Children.Add($sw)

    $mid = New-Object Windows.Controls.StackPanel
    $head = New-Object Windows.Controls.WrapPanel
    $nm = New-Tb $T.Name 13.5 'Text' $true
    $nm.Margin = '0,0,10,0'; $nm.TextWrapping = 'NoWrap'; $nm.VerticalAlignment = 'Center'
    [void]$head.Children.Add($nm)
    $impact = switch ([int]$T.Impact) {
        0 { @('No FPS change', 'Dim') }
        1 { @('Small gain', 'Muted') }
        2 { @('Medium gain', 'AccentHi') }
        default { @('Large gain if it applies', 'Accent') }
    }
    [void]$head.Children.Add((New-Chip $impact[0] $impact[1]))
    foreach ($gn in @($T.Gain)) { [void]$head.Children.Add((New-Chip $gn 'Dim' 'Bg1')) }
    if ($T.Reboot) { [void]$head.Children.Add((New-Chip 'Reboot' 'Warn' 'Bg1')) }
    [void]$mid.Children.Add($head)

    $desc = New-Tb $T.Desc 12 'Muted'; $desc.Margin = '0,5,0,0'
    [void]$mid.Children.Add($desc)

    if ($T.Note) {
        $n = $null
        try { $n = & $T.Note } catch { }
        if ($n) { $nt = New-Tb ([string]$n) 11.5 'Warn'; $nt.Margin = '0,5,0,0'; [void]$mid.Children.Add($nt) }
    }
    if ($T.Live -and -not $blocked) {
        $l = $null
        try { $l = & $T.Live } catch { }
        if ($l) { $lt = New-Tb ([string]$l) 11.5 'AccentHi'; $lt.Margin = '0,5,0,0'; [void]$mid.Children.Add($lt) }
    }
    if ($blocked) {
        $bt = New-Tb ([string]$blocked) 11.5 'Dim'; $bt.Margin = '0,5,0,0'; $bt.FontStyle = 'Italic'
        [void]$mid.Children.Add($bt)
        $sw.IsEnabled = $false
        $card.Opacity = 0.6
    }
    [Windows.Controls.Grid]::SetColumn($mid, 1)
    [void]$g.Children.Add($mid)

    $pill = New-Object Windows.Controls.Border
    $pill.CornerRadius = New-Object Windows.CornerRadius 9
    $pill.Padding = '10,3'
    $pill.VerticalAlignment = 'Top'
    $pill.Margin = '14,1,0,0'
    $pt = New-Tb '' 11 'Dim' $true
    $pt.TextWrapping = 'NoWrap'
    $pill.Child = $pt
    [Windows.Controls.Grid]::SetColumn($pill, 2)
    [void]$g.Children.Add($pill)

    $card.Child = $g
    $script:Cards[$T.Id] = @{ Tweak = $T; Card = $card; Switch = $sw; Pill = $pill; PillText = $pt; Blocked = [bool]$blocked; Applied = $false }
    return $card
}

function Update-Card {
    param([string]$Id)
    $c = $script:Cards[$Id]
    if (-not $c) { return }
    if ($c.Blocked) { $c.PillText.Text = 'Unavailable'; $c.Pill.Background = Get-Res 'Bg1'; $c.PillText.Foreground = Get-Res 'Dim'; return }
    $on = $false
    try { $on = Test-TweakApplied $c.Tweak } catch { }
    $c.Applied = $on
    if ($on) { $c.PillText.Text = 'Applied'; $c.Pill.Background = [Windows.Media.Brushes]::Transparent; $c.PillText.Foreground = Get-Res 'Good'; $c.Pill.BorderBrush = Get-Res 'Good'; $c.Pill.BorderThickness = '1' }
    else     { $c.PillText.Text = 'Off'; $c.Pill.Background = Get-Res 'Bg1'; $c.PillText.Foreground = Get-Res 'Dim'; $c.Pill.BorderThickness = '0' }
}

function Update-AllCards {
    foreach ($id in @($script:Cards.Keys)) { Update-Card $id }
    Update-DashStats
    Update-Side
}

function Build-OptPage {
    if ($script:OptBuilt) { return }
    $ui = $script:UI
    $ui.pnlTweaks.Children.Clear()
    foreach ($grp in $script:Groups) {
        $mine = @($script:Tweaks | Where-Object { $_.Group -eq $grp.Key })
        if ($mine.Count -eq 0) { continue }
        $h = New-Tb ($grp.Title.ToUpper()) 10.5 'Dim' $true
        $h.Margin = '2,14,0,8'
        [void]$ui.pnlTweaks.Children.Add($h)
        foreach ($t in $mine) { [void]$ui.pnlTweaks.Children.Add((New-TweakCard $t)) }
    }
    $script:OptBuilt = $true
    Update-AllCards
}

function Get-SelectedTweaks {
    return @($script:Tweaks | Where-Object { $script:Sel.Contains($_.Id) -and -not $script:Cards[$_.Id].Blocked })
}

function Restart-ExplorerShell {
    Write-Log 'Restarting Explorer to apply interface changes...' 'info'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
}

function Invoke-OptRun {
    param([bool]$Apply)
    $ui = $script:UI
    $sel = @(Get-SelectedTweaks)
    if ($sel.Count -eq 0) { Write-Log 'Nothing selected. Flip some switches first.' 'warn'; return }
    $btns = @('btnOptApply', 'btnOptRevert', 'btnOptClear', 'btnOptRec')
    Set-Busy $true $btns
    $needExplorer = $false; $reboot = @(); $ok = 0; $fail = 0
    try {
        if ($Apply -and $ui.chkRestore.IsChecked) {
            Write-Log 'Creating a restore point...' 'info'; Invoke-UiPump
            try { New-RestorePoint; Write-Log 'Restore point created.' 'ok' }
            catch { Write-Log "No restore point made: $($_.Exception.Message)" 'warn' }
        }
        foreach ($t in $sel) {
            try {
                if ($Apply) { Invoke-TweakApply $t; Write-Log "Applied: $($t.Name)" 'ok' }
                else        { Invoke-TweakUndo $t;  Write-Log "Reverted: $($t.Name)" 'accent' }
                $ok++
                if ($t.Explorer) { $needExplorer = $true }
                if ($t.Reboot)   { $reboot += $t.Name }
                $script:Cards[$t.Id].Switch.IsChecked = $false
            } catch {
                $fail++
                Write-Log "FAILED: $($t.Name) - $($_.Exception.Message)" 'err'
            }
            Update-Card $t.Id
            Invoke-UiPump
        }
        if ($needExplorer) { Restart-ExplorerShell }
        if ($reboot.Count -gt 0) {
            $ui.bannerRebootText.Text = 'Restart Windows to finish: ' + ($reboot -join ', ') + '.'
            $ui.bannerReboot.Visibility = 'Visible'
        }
        Write-Log ("{0} done: {1} succeeded, {2} failed." -f $(if ($Apply) { 'Apply' } else { 'Revert' }), $ok, $fail) $(if ($fail -gt 0) { 'warn' } else { 'ok' })
    } finally {
        Set-Busy $false $btns
        Update-DashStats
        Update-Side
    }
}

function Select-Recommended {
    $n = 0
    foreach ($id in $script:Cards.Keys) {
        $c = $script:Cards[$id]
        if ($c.Blocked -or $c.Applied) { continue }
        $rec = $false
        try { $rec = Test-TweakRecommended $c.Tweak } catch { }
        if ($rec) { $c.Switch.IsChecked = $true; $n++ }
    }
    Write-Log "Selected $n recommended tweak(s) that are not applied yet." 'info'
}

# ---- Rust page ----------------------------------------------------------------
function Update-Launch {
    $ui = $script:UI
    $opt = @{ High = [bool]$ui.loHigh.IsChecked; Exclusive = [bool]$ui.loExcl.IsChecked; Cpu = [bool]$ui.loCpu.IsChecked; D3d = [bool]$ui.loD3d.IsChecked; NoLog = [bool]$ui.loLog.IsChecked }
    $ui.txtLaunch.Text = Get-RustLaunchOptions $opt
    $F = $script:Facts
    $ui.txtLaunchNote.Text = if ($F.Cores -gt 0) { "Detected $($F.Cores) cores / $($F.Threads) threads." } else { '' }
}

function Invoke-Preset {
    param([string]$Key, [string]$Label)
    $ui = $script:UI
    try {
        $n = Set-RustPreset $Key
        $ui.txtPreStatus.Text = "$Label written ($n settings). It applies the next time you start Rust."
        $ui.txtPreStatus.Foreground = Get-Res 'Good'
        Write-Log "Rust preset '$Label' written to client.cfg." 'ok'
    } catch {
        $ui.txtPreStatus.Text = $_.Exception.Message
        $ui.txtPreStatus.Foreground = Get-Res 'Warn'
        Write-Log "Rust preset: $($_.Exception.Message)" 'warn'
    }
}

# ---- game session page --------------------------------------------------------
function Get-SessionOptions {
    $ui = $script:UI
    return @{ Timer = [bool]$ui.sesTimer.IsChecked; Purge = [bool]$ui.sesPurge.IsChecked; Priority = [bool]$ui.sesPrio.IsChecked; Services = [bool]$ui.sesSvc.IsChecked }
}

function Update-SessionUi {
    $ui = $script:UI
    if ($script:Session.Active) {
        $ui.btnSesToggle.Content = 'End session'
        $ui.txtSesStatus.Text = 'Session is running. Boosts are active until you end it or close this app.'
        $ui.txtSesStatus.Foreground = Get-Res 'Good'
    } else {
        $ui.btnSesToggle.Content = 'Start session'
        $ui.txtSesStatus.Text = if ($ui.sesAuto.IsChecked) { 'Waiting for Rust to start...' } else { 'No session running.' }
        $ui.txtSesStatus.Foreground = Get-Res 'Muted'
    }
    foreach ($n in 'sesTimer', 'sesPurge', 'sesPrio', 'sesSvc') { $ui[$n].IsEnabled = -not $script:Session.Active }
    Update-Side
}

function Invoke-SessionTick {
    $rust = $null
    try { $rust = Get-Process -Name RustClient -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { }
    $auto = [bool]$script:UI.sesAuto.IsChecked
    if ($auto -and -not $script:Session.Active -and $rust) {
        $script:SessAutoStarted = $true; $script:RustGone = 0
        Write-Log 'Rust started, beginning session.' 'accent'
        Start-GameSession (Get-SessionOptions); Update-SessionUi
    }
    elseif ($script:Session.Active -and $script:SessAutoStarted -and -not $rust) {
        $script:RustGone = [int]$script:RustGone + 1
        if ($script:RustGone -ge 2) { $script:SessAutoStarted = $false; Write-Log 'Rust closed, ending session.' 'accent'; Stop-GameSession; Update-SessionUi }
    }
    if ($script:Session.Active) {
        if ($script:Session.Prio -and $rust) {
            try { if ($rust.PriorityClass -ne 'High') { $rust.PriorityClass = 'High'; Write-Log 'RustClient priority set to High.' 'ok' } }
            catch { Write-Log "Could not change Rust priority: $($_.Exception.Message)" 'warn' }
        }
        $script:Session.Tick = [int]$script:Session.Tick + 1
        if ($script:Session.Purge -and ($script:Session.Tick % 6) -eq 0) {
            $m = Get-MemSnapshot
            if ($m -and $m.Free -lt 1.5GB -and $m.Standby -gt 1GB) { Invoke-PurgeStandby }
        }
    }
}

function Build-KillList {
    $ui = $script:UI
    $ui.pnlKill.Children.Clear()
    $defaults = @('OneDrive', 'Epic Launcher')
    foreach ($k in $script:KillGroups.Keys) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = $k
        $cb.Tag = $k
        $cb.Margin = '0,5,22,5'
        $cb.IsChecked = ($defaults -contains $k)
        [void]$ui.pnlKill.Children.Add($cb)
    }
}

# ---- cleaner page -------------------------------------------------------------
$script:CleanBuilt = $false
$script:CleanTasks = @()
$script:CleanChk = @{}
$script:CleanLbl = @{}
$script:CleanCtx = @{ Busy = $false }

function Build-CleanPage {
    $ui = $script:UI
    $script:CleanTasks = @(Get-CleanTasks)
    $ui.pnlClean.Children.Clear()
    foreach ($t in $script:CleanTasks) {
        $card = New-Object Windows.Controls.Border
        $card.Background = Get-Res 'Bg2'; $card.BorderBrush = Get-Res 'Line'; $card.BorderThickness = '1'
        $card.CornerRadius = New-Object Windows.CornerRadius 10
        $card.Padding = '14,10'; $card.Margin = '0,0,0,8'
        $g = New-Object Windows.Controls.Grid
        $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = '*'
        $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
        [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1)
        $sp = New-Object Windows.Controls.StackPanel
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = $t.Name; $cb.FontWeight = 'SemiBold'; $cb.Margin = '0,0,0,0'
        $cb.IsChecked = [bool]$t.Rec
        $d = New-Tb $t.Desc 11.5 'Muted'; $d.Margin = '28,3,12,0'
        [void]$sp.Children.Add($cb); [void]$sp.Children.Add($d)
        $lbl = New-Tb '-' 12.5 'Accent' $true
        $lbl.TextWrapping = 'NoWrap'; $lbl.VerticalAlignment = 'Top'; $lbl.FontFamily = 'Consolas'
        [Windows.Controls.Grid]::SetColumn($lbl, 1)
        [void]$g.Children.Add($sp); [void]$g.Children.Add($lbl)
        $card.Child = $g
        [void]$ui.pnlClean.Children.Add($card)
        $script:CleanChk[$t.Id] = $cb
        $script:CleanLbl[$t.Id] = $lbl
    }
    $script:CleanBuilt = $true
}

function Start-CleanJob {
    param([bool]$Delete)
    $ui = $script:UI
    if ($script:CleanCtx.Busy) { return }
    $tasks = @($script:CleanTasks | Where-Object { $script:CleanChk[$_.Id].IsChecked })
    if ($Delete -and $tasks.Count -eq 0) { Write-Log 'Nothing ticked to clean.' 'warn'; return }
    if (-not $Delete) { $tasks = @($script:CleanTasks) }
    if ($Delete) {
        $ans = [Windows.MessageBox]::Show('This permanently deletes the ticked items. Continue?', 'Daqueece Optimizer', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }
    }
    $script:CleanCtx = @{ Busy = $true; Done = 0; Count = $tasks.Count; Delete = $Delete; Freed = 0.0 }
    foreach ($b in 'btnScan', 'btnCleanRun', 'btnCleanRec', 'btnCleanNone') { $ui[$b].IsEnabled = $false }
    $ui.barClean.Value = 0
    $ui.txtCleanTotal.Text = ''
    $ui.txtCleanStatus.Text = if ($Delete) { 'Cleaning...' } else { 'Scanning...' }
    Invoke-Async -Work $script:CleanWork -ArgList @($tasks, $Delete) -OnProgress {
        param($it)
        $ctx = $script:CleanCtx
        switch ($it.Kind) {
            'start' { $script:CleanLbl[$it.Id].Text = '...' }
            'tick'  { $script:CleanLbl[$it.Id].Text = (Format-Bytes $it.Bytes) }
            'done'  {
                $script:CleanLbl[$it.Id].Text = if ($it.Text) { $it.Text } else { Format-Bytes $it.Bytes }
                $ctx.Done++
                $script:UI.barClean.Value = [math]::Round(100 * $ctx.Done / [math]::Max(1, $ctx.Count))
            }
            'total' { $ctx.Freed = $it.Bytes }
        }
    } -OnDone {
        param($res, $err)
        $ctx = $script:CleanCtx; $ui = $script:UI
        $ctx.Busy = $false
        foreach ($b in 'btnScan', 'btnCleanRun', 'btnCleanRec', 'btnCleanNone') { $ui[$b].IsEnabled = $true }
        $ui.barClean.Value = 100
        if ($err) { $ui.txtCleanStatus.Text = "Failed: $err"; Write-Log "Cleaner failed: $err" 'err'; return }
        if ($ctx.Delete) {
            $ui.txtCleanStatus.Text = 'Cleanup finished.'
            $ui.txtCleanTotal.Text = 'Freed ' + (Format-Bytes $ctx.Freed)
            Write-Log ("Cleaner freed {0}." -f (Format-Bytes $ctx.Freed)) 'ok'
        } else {
            $ui.txtCleanStatus.Text = 'Scan complete.'
            $ui.txtCleanTotal.Text = (Format-Bytes $ctx.Freed) + ' reclaimable'
            Write-Log ("Cleaner scan: {0} reclaimable." -f (Format-Bytes $ctx.Freed)) 'info'
        }
    }
}

# ---- build the window ------------------------------------------------------------
function New-AppWindow {
    $xml = [xml]$script:Xaml
    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))
    $ui = @{ Win = $win }
    foreach ($m in [regex]::Matches($script:Xaml, 'x:Name="([^"]+)"')) {
        $n = $m.Groups[1].Value
        $el = $win.FindName($n)
        if ($el) { $ui[$n] = $el }
    }
    $script:UI = $ui
    return $win
}

function Enter-App {
    $ui = $script:UI
    $ui.btnEnter.IsEnabled = $false
    $ui.btnEnter.Content = 'Scanning your PC...'
    Invoke-UiPump
    try {
        Build-OptPage
        Build-KillList
        Build-CleanPage
        Update-Dashboard
    } catch { Write-Log "Startup scan hit a problem: $($_.Exception.Message)" 'warn' }
    Show-Page 'dash'
    $fade = New-Object Windows.Media.Animation.DoubleAnimation(1, 0, [TimeSpan]::FromMilliseconds(260))
    $fade.Add_Completed({
        $script:UI.landing.Visibility = 'Collapsed'
        $script:UI.app.Visibility = 'Visible'
        $in = New-Object Windows.Media.Animation.DoubleAnimation(0, 1, [TimeSpan]::FromMilliseconds(380))
        $script:UI.app.BeginAnimation([Windows.UIElement]::OpacityProperty, $in)
    })
    $ui.landing.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
}

function Start-LandingAnimations {
    $ui = $script:UI
    $ease = New-Object Windows.Media.Animation.QuadraticEase
    $ease.EasingMode = 'EaseOut'
    $a1 = New-Object Windows.Media.Animation.DoubleAnimation(0, 1, [TimeSpan]::FromMilliseconds(900)); $a1.EasingFunction = $ease
    $ui.hero.BeginAnimation([Windows.UIElement]::OpacityProperty, $a1)
    $a2 = New-Object Windows.Media.Animation.DoubleAnimation(18, 0, [TimeSpan]::FromMilliseconds(900)); $a2.EasingFunction = $ease
    $ui.heroShift.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $a2)
    $a3 = New-Object Windows.Media.Animation.DoubleAnimation(0.35, 0.95, [TimeSpan]::FromSeconds(3.6))
    $a3.AutoReverse = $true
    $a3.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $sine = New-Object Windows.Media.Animation.SineEase; $sine.EasingMode = 'EaseInOut'; $a3.EasingFunction = $sine
    $ui.glow.BeginAnimation([Windows.UIElement]::OpacityProperty, $a3)
}

function Register-Events {
    $ui = $script:UI
    $win = $ui.Win

    # landing text
    $ui.lnTag.Text   = Space-Text 'WINDOWS TUNING FOR RUST'
    $ui.lnTitle.Text = Space-Text 'DAQUEECE'
    $ui.lnSub.Text   = Space-Text 'OPTIMIZER'
    $ui.btnEnter.Content = ('ENTER OPTIMIZER   ' + [char]0x2192)
    $dot = [string][char]0x00B7
    $ui.lnSys.Text = ("{0}   {1}   {2} GB RAM   {1}   v{3}" -f $script:Facts.CpuName, $dot, $script:Facts.RamGB, $script:Version)

    # window chrome and dragging
    $drag = { param($s, $e) if ($e.ChangedButton -eq 'Left') { try { $script:UI.Win.DragMove() } catch { } } }
    $ui.landing.Add_MouseLeftButtonDown($drag)
    $ui.header.Add_MouseLeftButtonDown($drag)
    $ui.lnMin.Add_Click({ $script:UI.Win.WindowState = 'Minimized' })
    $ui.appMin.Add_Click({ $script:UI.Win.WindowState = 'Minimized' })
    $ui.lnClose.Add_Click({ $script:UI.Win.Close() })
    $ui.appClose.Add_Click({ $script:UI.Win.Close() })
    $ui.btnEnter.Add_Click({ Invoke-Safe { Enter-App } 'Enter' })

    # navigation
    $navs = @{ navDash = 'dash'; navOpt = 'opt'; navRust = 'rust'; navSession = 'session'; navClean = 'clean'; navLog = 'log' }
    foreach ($n in $navs.Keys) {
        $ui[$n].Tag = $navs[$n]
        $ui[$n].Add_Checked({ param($s, $e) Invoke-Safe { Show-Page ([string]$s.Tag) } 'Navigation' })
    }

    # dashboard
    $ui.btnRescan.Add_Click({ Invoke-Safe { $script:FindingsDone = $false; Update-AllCards; Update-Dashboard } 'Rescan' })
    $ui.btnGoOpt.Add_Click({ Invoke-Safe { $script:UI.navOpt.IsChecked = $true; Select-Recommended } 'Review' })

    # optimize
    $ui.btnOptApply.Add_Click({ Invoke-Safe { Invoke-OptRun $true } 'Apply' })
    $ui.btnOptRevert.Add_Click({ Invoke-Safe { Invoke-OptRun $false } 'Revert' })
    $ui.btnOptRec.Add_Click({ Invoke-Safe { Select-Recommended } 'Select' })
    $ui.btnOptClear.Add_Click({ foreach ($c in $script:Cards.Values) { $c.Switch.IsChecked = $false } })

    # rust
    foreach ($n in 'loHigh', 'loExcl', 'loCpu', 'loD3d', 'loLog') { $ui[$n].Add_Click({ Update-Launch }) }
    $ui.btnCopyLaunch.Add_Click({
        Invoke-Safe {
            [Windows.Clipboard]::SetText($script:UI.txtLaunch.Text)
            $script:UI.txtLaunchNote.Text = 'Copied. Paste it into Steam > Rust > Properties > Launch Options.'
            Write-Log 'Rust launch options copied to the clipboard.' 'ok'
        } 'Copy'
    })
    $ui.btnPreMax.Add_Click({ Invoke-Safe { Invoke-Preset 'Max' 'Max FPS' } 'Preset' })
    $ui.btnPreComp.Add_Click({ Invoke-Safe { Invoke-Preset 'Competitive' 'Competitive' } 'Preset' })
    $ui.btnPreBal.Add_Click({ Invoke-Safe { Invoke-Preset 'Balanced' 'Balanced' } 'Preset' })
    $ui.btnPreRestore.Add_Click({
        try { Restore-RustCfg; $script:UI.txtPreStatus.Text = 'Original client.cfg restored.'; $script:UI.txtPreStatus.Foreground = Get-Res 'Good'; Write-Log 'Rust client.cfg restored from backup.' 'ok' }
        catch { $script:UI.txtPreStatus.Text = $_.Exception.Message; $script:UI.txtPreStatus.Foreground = Get-Res 'Warn' }
    })

    # session
    $ui.btnSesToggle.Add_Click({
        Invoke-Safe {
            if ($script:Session.Active) { $script:SessAutoStarted = $false; Stop-GameSession }
            else { $script:SessAutoStarted = $false; Start-GameSession (Get-SessionOptions) }
            Update-SessionUi
        } 'Session'
    })
    $ui.sesAuto.Add_Click({ Update-SessionUi })
    $ui.btnKill.Add_Click({
        Invoke-Safe {
            $names = @()
            foreach ($cb in $script:UI.pnlKill.Children) { if ($cb.IsChecked) { $names += $script:KillGroups[[string]$cb.Tag] } }
            if ($names.Count -eq 0) { Write-Log 'No app groups ticked.' 'warn'; return }
            $ans = [Windows.MessageBox]::Show('Close the ticked apps now? Unsaved work in them will be lost.', 'Daqueece Optimizer', 'YesNo', 'Warning')
            if ($ans -ne 'Yes') { return }
            $script:UI.btnKill.IsEnabled = $false
            try { Close-BackgroundApps $names } finally { $script:UI.btnKill.IsEnabled = $true }
        } 'Close apps'
    })

    # cleaner
    $ui.btnScan.Add_Click({ Invoke-Safe { Start-CleanJob $false } 'Scan' })
    $ui.btnCleanRun.Add_Click({ Invoke-Safe { Start-CleanJob $true } 'Clean' })
    $ui.btnCleanRec.Add_Click({ foreach ($t in $script:CleanTasks) { $script:CleanChk[$t.Id].IsChecked = [bool]$t.Rec } })
    $ui.btnCleanNone.Add_Click({ foreach ($cb in $script:CleanChk.Values) { $cb.IsChecked = $false } })

    # log
    $ui.btnLogFile.Add_Click({ try { Start-Process notepad.exe -ArgumentList "`"$($script:LogFile)`"" } catch { } })
    $ui.btnLogClear.Add_Click({ $script:UI.logList.Items.Clear() })

    # lifecycle
    $win.Add_Loaded({ Start-LandingAnimations })
    $win.Add_Closing({
        try { $script:SessionTimer.Stop() } catch { }
        try { Stop-GameSession } catch { }
        try { if ($script:NativeOk) { [RomNative]::ReleaseTimer() } } catch { }
    })
}

# ---- start -------------------------------------------------------------------------
Restore-OrphanedSession
$script:Facts = Get-SystemFacts
Import-Journal
$script:Tweaks = Get-TweakCatalog
$script:FindingsDone = $false
[void](New-AppWindow)
Register-Events
$script:SessionTimer = New-Object Windows.Threading.DispatcherTimer
$script:SessionTimer.Interval = [TimeSpan]::FromSeconds(3)
$script:SessionTimer.Add_Tick({ try { Invoke-SessionTick } catch { } })
$script:SessionTimer.Start()
Write-Log "Daqueece Optimizer $($script:Version) started on $($script:Facts.OsName)." 'accent'
[void]$script:UI.Win.ShowDialog()
