#Requires -Version 5.1
<#
  ROM-OPTI v7  -  Windows tuning for Rust and other CPU-bound games

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
    if ($PSCommandPath) {
        try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PSCommandPath) } catch { }
        exit
    }
    # Started from memory (irm ... | iex): there is no file to relaunch, so fetch the same script
    # from the public repo into %TEMP% and start that copy elevated. Nothing else is downloaded.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $romTmp = Join-Path ([IO.Path]::GetTempPath()) 'Rom-Opti.ps1'
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/RomOpti/RomOpti/main/Rom-Opti.ps1' -OutFile $romTmp -UseBasicParsing
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $romTmp)
    } catch {
        Write-Host 'Rom-Opti needs administrator rights and could not relaunch itself. Open PowerShell as Administrator and run the command again.' -ForegroundColor Yellow
    }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$script:Version = '7.0'

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
try { Add-Type -TypeDefinition $NativeSrc -ErrorAction Stop; $script:NativeOk = $true; if ($PSCommandPath) { [RomNative]::HideConsole() } }
catch { $script:NativeOk = $false }

# ---- paths, logging ---------------------------------------------------------
$script:AppDir      = Join-Path $env:ProgramData 'RomOpti'
$script:JournalFile = Join-Path $script:AppDir 'journal.json'
$script:SessionFile = Join-Path $script:AppDir 'session.json'
$script:LogFile     = Join-Path $script:AppDir 'rom-opti.log'
if (-not (Test-Path -LiteralPath $script:AppDir)) { [void](New-Item -ItemType Directory -Path $script:AppDir -Force) }
try { if ((Test-Path -LiteralPath $script:LogFile) -and ((Get-Item -LiteralPath $script:LogFile).Length -gt 2MB)) { Remove-Item -LiteralPath $script:LogFile -Force } } catch { }

$script:UI     = $null
$script:AnimOn = $true
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
    $color = switch ($Kind) { 'ok' { '#2ED3A0' } 'warn' { '#FFB547' } 'err' { '#FF5C7A' } 'accent' { '#7C5CFF' } default { '#98A2C3' } }
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
    if (Get-Command Start-FadeSlide -ErrorAction SilentlyContinue) { Start-FadeSlide $tb 0 5 0 200; Start-FadeSlide $script:UI.lastLog 0 0 0 240 }
}

function Invoke-UiPump {
    # Lets WPF repaint during a synchronous loop. Only called from code paths where the
    # buttons are disabled, so re-entrancy is not a concern.
    if (-not $script:UI -or -not $script:UI.Win) { return }
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [void]$script:UI.Win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ $frame.Continue = $false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Wait-Ui {
    # Sleep without freezing the window: keeps painting and animating while it waits.
    param([int]$Ms)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) { Invoke-UiPump; Start-Sleep -Milliseconds 12 }
}

function Invoke-Blocking {
    # Runs slow work in a background runspace and keeps the UI alive while waiting.
    # The script block must be self-contained. -Functions copies named functions into the worker.
    param([scriptblock]$Script, [object[]]$ArgList = @(), [string[]]$Functions = @(), [int]$TimeoutSec = 180)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    try {
        $pre = "function Invoke-UiPump {}`n"
        foreach ($fn in $Functions) { $pre += ("function {0} {{`n{1}`n}}`n" -f $fn, (Get-Item -LiteralPath "function:$fn").ScriptBlock.ToString()) }
        [void]$ps.AddScript($pre)
        [void]$ps.Invoke()
        $ps.Commands.Clear()
        [void]$ps.AddScript($Script.ToString())
        foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
        $h = $ps.BeginInvoke()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $h.IsCompleted) {
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { $ps.Stop(); throw 'The operation timed out.' }
            Invoke-UiPump
            Start-Sleep -Milliseconds 15
        }
        $out = $ps.EndInvoke($h)
        if ($ps.Streams.Error.Count -gt 0 -and -not $out) { throw $ps.Streams.Error[0].ToString() }
        return $out
    } finally { try { $ps.Dispose(); $rs.Dispose() } catch { } }
}

function Stop-ServicesFast {
    param([string[]]$Names)
    if (-not $Names -or $Names.Count -eq 0) { return }
    [void](Invoke-Blocking -ArgList @(,$Names) -Script { param($n) foreach ($s in $n) { try { Stop-Service -Name $s -Force -ErrorAction Stop } catch { } } })
}

function Start-ServicesFast {
    param([string[]]$Names)
    if (-not $Names -or $Names.Count -eq 0) { return }
    [void](Invoke-Blocking -ArgList @(,$Names) -Script { param($n) foreach ($s in $n) { try { Start-Service -Name $s -ErrorAction Stop } catch { } } })
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
    if ($S.Running) { Start-ServicesFast @($S.Name) }
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
    Invoke-UiPump
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
    Invoke-UiPump
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
    Invoke-UiPump
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
    $f.RustHdd = $false
    try {
        if ($f.RustExe) {
            $m = [string](Get-Partition -DriveLetter $f.RustExe.Substring(0, 1) -ErrorAction Stop | Get-Disk -ErrorAction Stop | Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1).MediaType
            $f.RustHdd = ($m -eq 'HDD')
        }
    } catch { }
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
        $stopNames = @()
        foreach ($s in @($T.Svc | Where-Object { $_ })) {
            $svc = Get-Service -Name $s.N -ErrorAction SilentlyContinue
            if (-not $svc) { continue }
            if ($s.Stop -and $svc.Status -ne 'Stopped') { $stopNames += $s.N }
            Set-SvcStartup $s.N $s.S
        }
        if ($stopNames.Count -gt 0) { Stop-ServicesFast $stopNames }
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
    @{ Key = 'Sched';   Title = 'CPU scheduling & memory' }
    @{ Key = 'Gpu';     Title = 'GPU & display' }
    @{ Key = 'Rust';    Title = 'Rust (RustClient.exe)' }
    @{ Key = 'Input';   Title = 'Input' }
    @{ Key = 'Network'; Title = 'Network' }
    @{ Key = 'Svc';     Title = 'Services & scheduled tasks' }
    @{ Key = 'Bg';      Title = 'Background load' }
    @{ Key = 'Priv';    Title = 'Privacy, AI & ads' }
    @{ Key = 'Vis';     Title = 'Visual effects' }
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
        Desc = 'Creates a separate plan from Ultimate Performance (High Performance if unavailable): CPU never idles below 100%, aggressive boost, USB selective suspend off, PCIe link power saving off, hard disks never spin down, Wi-Fi adapters at maximum performance. Your current plan is remembered and restored on revert.'
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
            [void](Set-PlanValue $guid 'SUB_DISK' 'DISKIDLE' 0)
            [void](Set-PlanValue $guid '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1' '12bbebe6-58d6-4636-95bb-3217ef867c1a' 0)
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
            $r = @(Invoke-Blocking -Script {
                $ads = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
                if (-not $ads) { return $false }
                foreach ($a in $ads) {
                    $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue
                    if ($pm -and "$($pm.AllowComputerToTurnOffDevice)" -eq 'Enabled') { return $false }
                }
                return $true })
            return ($r.Count -gt 0 -and [bool]$r[0])
        }
        Apply = { param($t)
            $rows = @(Invoke-Blocking -Script {
                foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
                    try { $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction Stop
                          if ("$($pm.AllowComputerToTurnOffDevice)" -eq 'Enabled') { [pscustomobject]@{ Kind = 'pm'; Adapter = $a.Name; Kw = ''; Old = 'Enabled' } } } catch { }
                    foreach ($kw in '*EEE', 'EEE', 'EeePhyEnable', 'GreenEthernet', 'AdvancedEEE') {
                        $p = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $kw -ErrorAction SilentlyContinue
                        if ($p -and $p.RegistryValue -and ("$($p.RegistryValue[0])" -ne '0')) { [pscustomobject]@{ Kind = 'adv'; Adapter = $a.Name; Kw = $kw; Old = "$($p.RegistryValue[0])" } }
                    }
                } })
            if ($rows.Count -eq 0) { Write-Log 'Adapters already had power saving off, or do not expose these settings.' 'info'; return }
            foreach ($r in $rows) { Set-Extra $t.Id ("{0}|{1}|{2}" -f $r.Kind, $r.Adapter, $r.Kw) $r.Old }
            [void](Invoke-Blocking -ArgList @(,$rows) -Script {
                param($rows)
                foreach ($r in $rows) {
                    try {
                        if ($r.Kind -eq 'pm') { Set-NetAdapterPowerManagement -Name $r.Adapter -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop }
                        else { Set-NetAdapterAdvancedProperty -Name $r.Adapter -RegistryKeyword $r.Kw -RegistryValue '0' -ErrorAction Stop }
                    } catch { }
                } })
        }
        Undo = { param($t)
            $x = if ($script:Journal.ContainsKey($t.Id)) { $script:Journal[$t.Id].Extra } else { $null }
            if (-not $x) { return }
            $rows = @(foreach ($k in @($x.Keys)) { $p = $k -split '\|'; [pscustomobject]@{ Kind = $p[0]; Adapter = $p[1]; Kw = $p[2]; Old = [string]$x[$k] } })
            [void](Invoke-Blocking -ArgList @(,$rows) -Script {
                param($rows)
                foreach ($r in $rows) {
                    try {
                        if ($r.Kind -eq 'pm') { Set-NetAdapterPowerManagement -Name $r.Adapter -AllowComputerToTurnOffDevice Enabled -ErrorAction Stop }
                        else { Set-NetAdapterAdvancedProperty -Name $r.Adapter -RegistryKeyword $r.Kw -RegistryValue $r.Old -ErrorAction Stop }
                    } catch { }
                } })
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

    return (@($list.ToArray()) + @(Get-ExtraTweaks))
}

function Test-TweakRecommended {
    param($T)
    if ($null -eq $T.Rec) { return $false }
    if ($T.Rec -is [scriptblock]) { return [bool](& $T.Rec) }
    return [bool]$T.Rec
}
# ---- extra tweaks (v7) ---------------------------------------------------------
function Get-BcdValue {
    param([string]$Name)
    $r = Invoke-NativeOut { bcdedit /enum '{current}' }
    if ($r.Out -match ('(?im)^\s*' + [regex]::Escape($Name) + '\s+(\S+)')) { return $Matches[1] }
    return $null
}

function Get-IntelGen {
    # 2..14 for Intel Core iX-NNNN / NNNNN, otherwise $null
    $n = $script:Facts.CpuName
    if ($n -match 'Core\(TM\)\s+i[3579]-(\d{4,5})') {
        $d = $Matches[1]
        if ($d.Length -eq 5) { return [int]$d.Substring(0, 2) } else { return [int]$d.Substring(0, 1) }
    }
    return $null
}

function Get-NicTweakRows {
    param([string[]]$Keywords, [string]$WantValue = '0')
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and ([string]$_.PhysicalMediaType) -match '802\.3' })) {
        foreach ($kw in $Keywords) {
            $p = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $kw -ErrorAction SilentlyContinue
            if ($p -and $p.RegistryValue -and ("$($p.RegistryValue[0])" -ne $WantValue)) { [pscustomobject]@{ Adapter = $a.Name; Kw = $kw; Old = "$($p.RegistryValue[0])" } }
        }
    }
}

function Set-NicRows {
    param($Rows, [string]$Value = '')
    foreach ($r in @($Rows)) {
        try { $v = if ($Value -ne '') { $Value } else { $r.Old }; Set-NetAdapterAdvancedProperty -Name $r.Adapter -RegistryKeyword $r.Kw -RegistryValue $v -ErrorAction Stop } catch { }
    }
}

function Get-ExtraTweaks {
    $list = New-Object System.Collections.ArrayList
    $mm   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    $memk = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $gfx  = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $cdm  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

    # ======================= CPU SCHEDULING & MEMORY =======================
    [void]$list.Add(@{ Id = 'sch_prio'; Group = 'Sched'; Name = 'Foreground priority boost (short, fixed quanta)'; Impact = 1; Gain = @('Lows', 'Latency')
        Desc = 'Sets Win32PrioritySeparation to 0x26. The window you are using gets a stronger CPU share over background work in short, fixed time slices. Windows default is 2. This is one of the few scheduler settings with a real, if small, effect on game frametime consistency.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38) ) })
    [void]$list.Add(@{ Id = 'sch_mmcss'; Group = 'Sched'; Name = 'Multimedia scheduler: favor the foreground'; Impact = 1; Gain = @('Lows')
        Desc = 'Reserves 0% CPU for background multimedia tasks (default 20%) and lifts the network throttle. It only affects programs that register with the multimedia scheduler (MMCSS), which many games do not, so expect a small effect.'
        Rec = $true
        Reg = @( (RegItem $mm 'SystemResponsiveness' 0), (RegItem $mm 'NetworkThrottlingIndex' 4294967295) ) })
    [void]$list.Add(@{ Id = 'sch_games'; Group = 'Sched'; Name = 'Games task: highest scheduling class'; Impact = 1; Gain = @('Lows')
        Desc = 'Raises the "Games" MMCSS profile to GPU priority 8, CPU priority 6, High scheduling and High storage priority. Applies to titles that use MMCSS. Harmless for ones that do not.'
        Rec = $true
        Reg = @( (RegItem "$mm\Tasks\Games" 'GPU Priority' 8), (RegItem "$mm\Tasks\Games" 'Priority' 6),
                 (RegItem "$mm\Tasks\Games" 'Scheduling Category' 'High' 'String'), (RegItem "$mm\Tasks\Games" 'SFIO Priority' 'High' 'String') ) })
    [void]$list.Add(@{ Id = 'sch_hags'; Group = 'Sched'; Name = 'Hardware-accelerated GPU scheduling on'; Impact = 1; Gain = @('Latency', 'FPS'); Reboot = $true
        Desc = 'Lets the GPU manage its own memory queue instead of the CPU. Helps on newer cards, especially with frame generation (DLSS / FSR 3). On some GPUs and drivers it is neutral or slightly worse.'
        Note = 'Test it: run the same Rust scene before and after. Revert if lows get worse.'
        Rec = $false
        When = { if ($script:Facts.Build -ge 19041) { $true } else { 'Needs Windows 10 2004 or newer' } }
        Reg = @( (RegItem $gfx 'HwSchMode' 2) ) })
    [void]$list.Add(@{ Id = 'sch_pagexec'; Group = 'Sched'; Name = 'Keep the kernel in RAM'; Impact = 1; Gain = @('Lows'); Reboot = $true
        Desc = 'Stops Windows from paging out kernel and driver code. With plenty of RAM it avoids rare multi-millisecond stalls when a driver routine has to be paged back in.'
        Rec = { $script:Facts.RamGB -ge 15 }
        When = { if ($script:Facts.RamGB -ge 15) { $true } else { 'Needs 16 GB of RAM or more' } }
        Reg = @( (RegItem $memk 'DisablePagingExecutive' 1) ) })
    [void]$list.Add(@{ Id = 'sch_memcomp'; Group = 'Sched'; Name = 'Memory compression off'; Impact = 1; Gain = @('Lows'); Reboot = $true
        Desc = 'Windows compresses idle memory pages in the background, which spends a little CPU. With 16 GB or more you rarely need it. With less RAM, leave it on.'
        Rec = $false
        When = { if (-not (Get-Command Get-MMAgent -ErrorAction SilentlyContinue)) { 'Not supported on this Windows' } elseif ($script:Facts.RamGB -lt 15) { 'Needs 16 GB of RAM or more' } else { $true } }
        Check = { param($t) return (-not (Get-MMAgent).MemoryCompression) }
        Apply = { param($t) [void](Invoke-Blocking -Script { Disable-MMAgent -MemoryCompression }) }
        Undo  = { param($t) [void](Invoke-Blocking -Script { Enable-MMAgent -MemoryCompression }) } })
    [void]$list.Add(@{ Id = 'sch_tick'; Group = 'Sched'; Name = 'Disable dynamic tick'; Impact = 1; Gain = @('Latency'); Reboot = $true
        Desc = 'Makes the system timer tick at a constant rate instead of skipping ticks when idle. Some systems get steadier frame pacing. Idle power use goes up slightly.'
        Note = 'Unproven on many setups. Only keep it if you measure a difference.'
        Rec = $false
        Check = { param($t) return ((Get-BcdValue 'disabledynamictick') -eq 'Yes') }
        Apply = { param($t) Invoke-Native { bcdedit /set disabledynamictick yes } }
        Undo  = { param($t) $null = Invoke-NativeOut { bcdedit /deletevalue disabledynamictick } } })
    [void]$list.Add(@{ Id = 'sch_maint'; Group = 'Sched'; Name = 'Automatic maintenance off'; Impact = 1; Gain = @('Lows', 'Background')
        Desc = 'Stops Windows from launching its idle-time maintenance (defrag, scans, diagnostics) mid-session. You can still run Windows Update and Defender scans by hand.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' 'MaintenanceDisabled' 1) ) })
    [void]$list.Add(@{ Id = 'sch_fast'; Group = 'Sched'; Name = 'Fast Startup off'; Impact = 0; Gain = @('Stability')
        Desc = 'Fast Startup saves a kernel snapshot at shutdown, so a "shutdown" is really a hibernate. Turning it off makes every shutdown a true clean boot, which clears stuck drivers and odd GPU states.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0) ) })
    [void]$list.Add(@{ Id = 'sch_hibernate'; Group = 'Sched'; Name = 'Hibernation off (frees disk space)'; Impact = 0; Gain = @('Comfort')
        Desc = 'Deletes hiberfil.sys, which is roughly 40% of your RAM size on disk (often 6-20 GB).'
        Rec = $false
        When = { if ($script:Facts.Laptop) { 'Laptops need hibernate for low-battery safety' } else { $true } }
        Check = { param($t) return ((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 1) -eq 0) }
        Apply = { param($t) Invoke-Native { powercfg /hibernate off } }
        Undo  = { param($t) Invoke-Native { powercfg /hibernate on } } })
    [void]$list.Add(@{ Id = 'sch_defscan'; Group = 'Sched'; Name = 'Defender scans: low CPU priority'; Impact = 1; Gain = @('Background')
        Desc = 'Keeps Microsoft Defender protection fully on but makes its scans run at idle priority and cap at 10% average CPU, so a scan cannot hurt a game.'
        Rec = $true
        When = {
            if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) { return 'Defender cmdlets unavailable' }
            try { if (-not (Get-MpComputerStatus).RealTimeProtectionEnabled) { return 'Defender real-time protection is off (another antivirus may be active)' } } catch { return 'Defender unavailable' }
            return $true }
        Check = { param($t) $p = Get-MpPreference; return ([int]$p.ScanAvgCPULoadFactor -le 10 -and [bool]$p.EnableLowCpuPriority) }
        Apply = { param($t) $p = Get-MpPreference
                  Set-Extra $t.Id 'Load' ([string][int]$p.ScanAvgCPULoadFactor); Set-Extra $t.Id 'Low' ([string][bool]$p.EnableLowCpuPriority)
                  Set-MpPreference -ScanAvgCPULoadFactor 10 -EnableLowCpuPriority $true }
        Undo  = { param($t) $l = Get-Extra $t.Id 'Load'; $w = Get-Extra $t.Id 'Low'
                  if ($l) { Set-MpPreference -ScanAvgCPULoadFactor ([int]$l) }
                  if ($w) { Set-MpPreference -EnableLowCpuPriority ($w -eq 'True') } } })
    [void]$list.Add(@{ Id = 'sch_wudrv'; Group = 'Sched'; Name = 'Windows Update stops swapping your GPU driver'; Impact = 0; Gain = @('Stability')
        Desc = 'Prevents Windows Update from silently replacing your NVIDIA / AMD driver with an older one, a classic cause of "it ran fine yesterday" FPS drops. You still update the driver yourself from the vendor.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1) ) })
    [void]$list.Add(@{ Id = 'sch_mitig'; Group = 'Adv'; Name = 'CPU vulnerability mitigations off (older Intel only)'; Impact = 3; Gain = @('FPS', 'Lows'); Reboot = $true
        Desc = 'Turns off the Spectre / Meltdown software patches. On Intel 9th gen and older these cost real CPU performance; newer CPUs have the fix in hardware, so this tool blocks the tweak there.'
        Note = 'Real security tradeoff: exposes you to side-channel attacks. Reboot required.'
        Rec = $false
        When = { $g = Get-IntelGen; if ($null -ne $g -and $g -le 9) { $true } else { 'Only offered for Intel Core 9th gen and older. Newer CPUs would gain under 1%.' } }
        Reg = @( (RegItem $memk 'FeatureSettingsOverride' 3), (RegItem $memk 'FeatureSettingsOverrideMask' 3) ) })

    # ======================= GPU & DISPLAY (more) =======================
    [void]$list.Add(@{ Id = 'gpu_swap'; Group = 'Gpu'; Name = 'Optimizations for windowed / borderless games'; Impact = 2; Gain = @('FPS', 'Latency')
        Desc = 'Lets DirectX 10/11 games running windowed or borderless use the faster flip presentation model, like exclusive fullscreen does. This is a large gain only if you do not play in exclusive fullscreen.'
        Rec = $true
        When = { if ($script:Facts.Win11) { $true } else { 'Windows 11 only' } }
        Reg = { RegItem 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings' 'SwapEffectUpgradeEnable=1;' 'String' } })
    [void]$list.Add(@{ Id = 'gpu_fsegl'; Group = 'Gpu'; Name = 'Fullscreen optimizations off (all games)'; Impact = 1; Gain = @('Latency')
        Desc = 'Global version of the per-game setting: games that ask for exclusive fullscreen get it, instead of Windows substituting its own path. Lowers input latency on some setups, does nothing on others.'
        Rec = $false
        Reg = @( (RegItem 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2), (RegItem 'HKCU:\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' 1),
                 (RegItem 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 1), (RegItem 'HKCU:\System\GameConfigStore' 'GameDVR_EFSEFeatureFlags' 0) ) })
    [void]$list.Add(@{ Id = 'gpu_mpo'; Group = 'Gpu'; Name = 'Multiplane overlay (MPO) off'; Impact = 1; Gain = @('Stability'); Reboot = $true
        Desc = 'MPO is a known cause of stutter, flicker and black screens on some NVIDIA and AMD driver versions, mostly in borderless windowed mode. Turning it off only helps if you see those symptoms.'
        Rec = $false
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5) ) })

    # ======================= INPUT (more) =======================
    [void]$list.Add(@{ Id = 'inp_kbd'; Group = 'Input'; Name = 'Fastest keyboard repeat'; Impact = 0; Gain = @('Comfort')
        Desc = 'Shortest repeat delay and fastest repeat rate for typing and menus. Applies after you sign out and back in.'
        Rec = $false
        Reg = @( (RegItem 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' '0' 'String'), (RegItem 'HKCU:\Control Panel\Keyboard' 'KeyboardSpeed' '31' 'String') ) })

    # ======================= SERVICES & SCHEDULED TASKS =======================
    [void]$list.Add(@{ Id = 'svc_sysmain'; Group = 'Svc'; Name = 'SysMain (Superfetch) off'; Impact = 1; Gain = @('Lows', 'Background')
        Desc = 'SysMain pre-loads apps into RAM and can cause disk and memory spikes. It was designed for hard drives; on an SSD it adds little.'
        Rec = { -not $script:Facts.RustHdd }
        When = { if ($script:Facts.RustHdd) { 'Rust is on a hard disk, where SysMain actually helps' } else { $true } }
        Svc = @( @{ N = 'SysMain'; S = 'Disabled'; Stop = $true; D = 'Automatic' } ) })
    [void]$list.Add(@{ Id = 'svc_search'; Group = 'Svc'; Name = 'Windows Search indexing off'; Impact = 1; Gain = @('Background')
        Desc = 'Stops the indexer from reading your disk in the background. Start-menu file search becomes slower, but app search still works.'
        Rec = $false
        Svc = @( @{ N = 'WSearch'; S = 'Disabled'; Stop = $true; D = 'Automatic' } ) })
    [void]$list.Add(@{ Id = 'svc_misc'; Group = 'Svc'; Name = 'Unused background services off'; Impact = 1; Gain = @('Background')
        Desc = 'Maps downloader, retail demo, fax, Insider service, Phone service, geolocation, Wallet, Windows Media sharing, Remote Registry and mixed-reality services. None of them are needed for gaming.'
        Rec = $true
        Svc = @( @{ N = 'MapsBroker'; S = 'Disabled'; Stop = $true; D = 'Automatic' }, @{ N = 'RetailDemo'; S = 'Disabled'; Stop = $true; D = 'Manual' },
                 @{ N = 'Fax'; S = 'Disabled'; Stop = $true; D = 'Manual' }, @{ N = 'wisvc'; S = 'Disabled'; Stop = $true; D = 'Manual' },
                 @{ N = 'PhoneSvc'; S = 'Disabled'; Stop = $true; D = 'Manual' }, @{ N = 'lfsvc'; S = 'Disabled'; Stop = $true; D = 'Manual' },
                 @{ N = 'WalletService'; S = 'Disabled'; Stop = $true; D = 'Manual' }, @{ N = 'WMPNetworkSvc'; S = 'Disabled'; Stop = $true; D = 'Manual' },
                 @{ N = 'RemoteRegistry'; S = 'Disabled'; Stop = $true; D = 'Disabled' }, @{ N = 'SharedRealitySvc'; S = 'Disabled'; Stop = $true; D = 'Manual' },
                 @{ N = 'spectrum'; S = 'Disabled'; Stop = $true; D = 'Manual' }, @{ N = 'perceptionsimulation'; S = 'Disabled'; Stop = $true; D = 'Manual' } ) })
    [void]$list.Add(@{ Id = 'svc_xbox'; Group = 'Svc'; Name = 'Xbox services off'; Impact = 1; Gain = @('Background')
        Desc = 'Disables the Xbox auth, save-sync, accessory and networking services.'
        Note = 'Breaks Xbox app sign-in, Game Pass games and Xbox cloud saves. Skip this if you use any of them.'
        Rec = $false
        Svc = @( @{ N = 'XblAuthManager'; S = 'Disabled'; Stop = $true; D = 'Manual' }, @{ N = 'XblGameSave'; S = 'Disabled'; Stop = $true; D = 'Manual' },
                 @{ N = 'XboxNetApiSvc'; S = 'Disabled'; Stop = $true; D = 'Manual' }, @{ N = 'XboxGipSvc'; S = 'Disabled'; Stop = $true; D = 'Manual' } ) })
    [void]$list.Add(@{ Id = 'svc_spooler'; Group = 'Svc'; Name = 'Print Spooler off'; Impact = 0; Gain = @('Background')
        Desc = 'Stops the print service, which has a long history of security holes. Only offered when no physical printer is installed.'
        Rec = $false
        When = { try { $p = @(Get-Printer -ErrorAction Stop | Where-Object { $_.Name -notmatch 'PDF|XPS|OneNote|Fax' }); if ($p.Count -gt 0) { 'A physical printer is installed' } else { $true } } catch { $true } }
        Svc = @( @{ N = 'Spooler'; S = 'Disabled'; Stop = $true; D = 'Automatic' } ) })
    [void]$list.Add(@{ Id = 'svc_tasks'; Group = 'Svc'; Name = 'Extra diagnostic and feedback tasks off'; Impact = 1; Gain = @('Background')
        Desc = 'Disables scheduled tasks for error-report queueing, feedback prompts, maps updates, disk-diagnostic data collection and power-efficiency analysis. These wake up at random and use disk and CPU.'
        Rec = $true
        Tasks = @( '\Microsoft\Windows\Windows Error Reporting\QueueReporting', '\Microsoft\Windows\Feedback\Siuf\DmClient', '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
                   '\Microsoft\Windows\Maps\MapsUpdateTask', '\Microsoft\Windows\Maps\MapsToastTask', '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
                   '\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem', '\Microsoft\Windows\DiskFootprint\Diagnostics', '\Microsoft\Windows\Autochk\Proxy' ) })
    [void]$list.Add(@{ Id = 'svc_wer'; Group = 'Svc'; Name = 'Windows Error Reporting off'; Impact = 0; Gain = @('Background')
        Desc = 'Stops crash reports from being collected and uploaded. Saves a burst of disk and CPU after every crash.'
        Note = 'You lose Windows crash dumps, which makes debugging a crash harder.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1), (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1) )
        Svc = @( @{ N = 'WerSvc'; S = 'Disabled'; Stop = $true; D = 'Manual' } ) })

    # ======================= BACKGROUND LOAD (more) =======================
    [void]$list.Add(@{ Id = 'bg_onedrive'; Group = 'Bg'; Name = 'OneDrive sync off (policy)'; Impact = 1; Gain = @('Background')
        Desc = 'Blocks OneDrive from syncing and from running in the background. Your files are not deleted. Use the Debloat tab if you want to uninstall it entirely.'
        Rec = $false
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1) ) })
    [void]$list.Add(@{ Id = 'bg_toasts'; Group = 'Bg'; Name = 'Toast notifications off'; Impact = 0; Gain = @('Comfort')
        Desc = 'No more notification pop-ups sliding in over your game or stealing focus.'
        Rec = $false
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0) ) })
    [void]$list.Add(@{ Id = 'bg_highlights'; Group = 'Bg'; Name = 'Search highlights off'; Impact = 0; Gain = @('Background'); Explorer = $true
        Desc = 'Removes the daily doodle and trending content from the search box, which loads web content in the background.'
        Rec = $true
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 0) ) })

    # ======================= PRIVACY, AI & ADS =======================
    [void]$list.Add(@{ Id = 'prv_copilot'; Group = 'Priv'; Name = 'Windows Copilot off'; Impact = 1; Gain = @('Background')
        Desc = 'Disables the Copilot sidebar and its background components via policy.'
        Rec = $true
        When = { if ($script:Facts.Win11) { $true } else { 'Windows 11 only' } }
        Reg = @( (RegItem 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1), (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1) ) })
    [void]$list.Add(@{ Id = 'prv_recall'; Group = 'Priv'; Name = 'Recall / AI data analysis off'; Impact = 1; Gain = @('Background')
        Desc = 'Disables Windows AI snapshotting and on-device data analysis. These can run NPU, GPU or disk work in the background. Harmless if the feature is not on your PC.'
        Rec = $true
        When = { if ($script:Facts.Build -ge 22621) { $true } else { 'Needs Windows 11 22H2 or newer' } }
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1), (RegItem 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1) ) })
    [void]$list.Add(@{ Id = 'prv_cortana'; Group = 'Priv'; Name = 'Cortana and web search off'; Impact = 0; Gain = @('Background')
        Desc = 'Disables Cortana, location use in search and web results in Windows Search.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0), (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowSearchToUseLocation' 0),
                 (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0), (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1) ) })
    [void]$list.Add(@{ Id = 'prv_activity'; Group = 'Priv'; Name = 'Activity history off'; Impact = 0; Gain = @('Background')
        Desc = 'Stops Windows from logging and syncing what you open, which writes to disk constantly.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0), (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0), (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0) ) })
    [void]$list.Add(@{ Id = 'prv_adid'; Group = 'Priv'; Name = 'Advertising ID and tailored ads off'; Impact = 0; Gain = @('Comfort')
        Desc = 'Turns off the per-user ad identifier and "tailored experiences" built from your diagnostic data.'
        Rec = $true
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0), (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0),
                 (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1) ) })
    [void]$list.Add(@{ Id = 'prv_input'; Group = 'Priv'; Name = 'Typing and inking data collection off'; Impact = 0; Gain = @('Comfort')
        Desc = 'Stops Windows from collecting what you type and write to personalize suggestions.'
        Rec = $true
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1), (RegItem 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1),
                 (RegItem 'HKCU:\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0) ) })
    [void]$list.Add(@{ Id = 'prv_spotlight'; Group = 'Priv'; Name = 'Lock screen and Spotlight ads off'; Impact = 0; Gain = @('Comfort')
        Desc = 'Removes Spotlight promotions, fun facts and suggested apps from the lock screen and Settings.'
        Rec = $true
        Reg = @( (RegItem $cdm 'RotatingLockScreenOverlayEnabled' 0), (RegItem $cdm 'SubscribedContent-338387Enabled' 0), (RegItem $cdm 'SubscribedContent-353694Enabled' 0),
                 (RegItem $cdm 'SubscribedContent-353696Enabled' 0), (RegItem $cdm 'SubscribedContent-310093Enabled' 0), (RegItem $cdm 'ContentDeliveryAllowed' 0), (RegItem $cdm 'OemPreInstalledAppsEnabled' 0), (RegItem $cdm 'PreInstalledAppsEnabled' 0) ) })

    # ======================= VISUAL EFFECTS =======================
    [void]$list.Add(@{ Id = 'vis_snappy'; Group = 'Vis'; Name = 'Snappier interface (no animations)'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Removes menu delay, window minimize/maximize animation, taskbar animations and Aero Peek delay. Windows feels instant. Saves a sliver of GPU on integrated graphics.'
        Rec = $false
        Reg = @( (RegItem 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0' 'String'), (RegItem 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0), (RegItem 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewAlphaSelect' 0), (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewShadow' 0) ) })

    # ======================= GAME-CHANGERS (only offered where they apply) =======================
    [void]$list.Add(@{ Id = 'sch_hpet'; Group = 'Sched'; Name = 'Remove a forced HPET timer'; Impact = 2; Gain = @('FPS', 'Lows', 'Latency'); Reboot = $true
        Desc = 'Old tweak guides told people to run "bcdedit /set useplatformclock true", which forces the slow HPET timer for the whole OS and hurts frame pacing. If that override is on your PC, this removes it and lets Windows choose the best timer. If your PC is not forcing HPET, the tweak is hidden.'
        Rec = $true
        When = { if ((Get-BcdValue 'useplatformclock') -eq 'Yes') { $true } else { 'Not applicable: your PC is not forcing HPET' } }
        Check = { param($t) return ((Get-BcdValue 'useplatformclock') -ne 'Yes') }
        Apply = { param($t) $null = Invoke-NativeOut { bcdedit /deletevalue useplatformclock } }
        Undo  = { param($t) Invoke-Native { bcdedit /set useplatformclock true } } })
    [void]$list.Add(@{ Id = 'sch_fth'; Group = 'Stab'; Name = 'Fault Tolerant Heap off'; Impact = 2; Gain = @('Lows', 'Stability')
        Desc = 'After a program crashes a few times, Windows quietly applies slow "safe mode" memory shims to it (the Fault Tolerant Heap). A game that crashed once can run permanently slower afterward, with no warning. This turns the feature off so nothing gets throttled behind your back.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Microsoft\FTH' 'Enabled' 0) ) })
    [void]$list.Add(@{ Id = 'sch_hyper'; Group = 'Adv'; Name = 'Hypervisor off (Hyper-V / VBS platform)'; Impact = 3; Gain = @('FPS', 'Lows'); Reboot = $true
        Desc = 'Turns off the Windows hypervisor at boot. While it runs (Hyper-V, WSL2, Docker, Windows Sandbox, Memory Integrity), the whole OS sits on top of it, which costs CPU time in games. With it off you get native scheduling and timer behavior.'
        Note = 'Breaks WSL2, Docker Desktop, Windows Sandbox, the Android subsystem and Hyper-V VMs until reverted. Reboot required.'
        Rec = $false
        When = { try { if ((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent) { $true } else { 'No hypervisor is running, so there is nothing to gain' } } catch { $true } }
        Check = { param($t) return ((Get-BcdValue 'hypervisorlaunchtype') -eq 'Off') }
        Apply = { param($t) Invoke-Native { bcdedit /set hypervisorlaunchtype off } }
        Undo  = { param($t) $null = Invoke-NativeOut { bcdedit /set hypervisorlaunchtype auto } } })
    [void]$list.Add(@{ Id = 'net_lat'; Group = 'Network'; Name = 'Ethernet latency mode'; Impact = 1; Gain = @('Ping', 'Latency')
        Desc = 'Turns off interrupt moderation, large-send offload and flow control on your wired adapter. Packets reach the CPU immediately instead of being batched, which can cut jitter for UDP games. It costs a little CPU and can lower peak download speed on slow CPUs.'
        Note = 'Wired only. Your connection drops for a moment while it applies. Measure it with the Internet tab.'
        Rec = $false
        When = { try { if (@(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and ([string]$_.PhysicalMediaType) -match '802\.3' }).Count -gt 0) { $true } else { 'No connected wired adapter found' } } catch { 'Network adapters unavailable' } }
        Check = { param($t)
            if (-not $script:Journal.ContainsKey($t.Id)) { return $false }
            $n = @(Invoke-Blocking -Functions 'Get-NicTweakRows' -Script { @(Get-NicTweakRows @('*InterruptModeration', '*FlowControl', '*LsoV2IPv4', '*LsoV2IPv6')).Count })
            return ($n.Count -gt 0 -and [int]$n[0] -eq 0)
        }
        Apply = { param($t)
            $rows = @(Invoke-Blocking -Functions 'Get-NicTweakRows' -Script { Get-NicTweakRows @('*InterruptModeration', '*FlowControl', '*LsoV2IPv4', '*LsoV2IPv6') })
            if ($rows.Count -eq 0) { throw 'Your adapter does not expose these settings, or they are already off.' }
            foreach ($r in $rows) { Set-Extra $t.Id ("adv|{0}|{1}" -f $r.Adapter, $r.Kw) $r.Old }
            [void](Invoke-Blocking -Functions 'Set-NicRows' -ArgList @(,$rows) -Script { param($rows) Set-NicRows $rows '0' })
        }
        Undo = { param($t)
            $x = if ($script:Journal.ContainsKey($t.Id)) { $script:Journal[$t.Id].Extra } else { $null }
            if (-not $x) { return }
            $rows = @(foreach ($k in @($x.Keys)) { $p = $k -split '\|'; [pscustomobject]@{ Adapter = $p[1]; Kw = $p[2]; Old = [string]$x[$k] } })
            [void](Invoke-Blocking -Functions 'Set-NicRows' -ArgList @(,$rows) -Script { param($rows) Set-NicRows $rows })
        } })
    [void]$list.Add(@{ Id = 'svc_nvtelem'; Group = 'Svc'; Name = 'NVIDIA telemetry service off'; Impact = 1; Gain = @('Background')
        Desc = 'Stops the NVIDIA telemetry container, which uploads usage data and wakes up in the background. Your drivers, Control Panel and GeForce features keep working.'
        Rec = $true
        When = { if (Get-Service -Name NvTelemetryContainer -ErrorAction SilentlyContinue) { $true } else { 'NVIDIA telemetry service not present' } }
        Svc = @( @{ N = 'NvTelemetryContainer'; S = 'Disabled'; Stop = $true; D = 'Automatic' } ) })
    [void]$list.Add(@{ Id = 'app_discord'; Group = 'Bg'; Name = 'Discord hardware acceleration off'; Impact = 1; Gain = @('FPS', 'Lows')
        Desc = 'Discord renders its interface on your GPU by default, competing with your game for GPU time and VRAM. Turning it off moves that work to the CPU. The gain shows most on mid-range GPUs. Voice and screen share look the same.'
        Note = 'Discord must be closed while this applies, then reopen it.'
        Rec = $true
        When = { if (-not (Test-Path -LiteralPath (Join-Path $env:APPDATA 'discord\settings.json'))) { 'Discord settings file not found' } elseif (Get-Process -Name Discord -ErrorAction SilentlyContinue) { 'Close Discord first, then reopen this page' } else { $true } }
        Check = { param($t)
            $f = Join-Path $env:APPDATA 'discord\settings.json'
            if (-not (Test-Path -LiteralPath $f)) { return $false }
            try { $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; return (($j.PSObject.Properties.Name -contains 'enableHardwareAcceleration') -and ($j.enableHardwareAcceleration -eq $false)) } catch { return $false } }
        Apply = { param($t)
            $f = Join-Path $env:APPDATA 'discord\settings.json'
            if (Get-Process -Name Discord -ErrorAction SilentlyContinue) { throw 'Close Discord first.' }
            $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            $has = ($j.PSObject.Properties.Name -contains 'enableHardwareAcceleration')
            Set-Extra $t.Id 'Old' $(if ($has) { [string]$j.enableHardwareAcceleration } else { '(absent)' })
            if (-not (Test-Path -LiteralPath "$f.romopti.bak")) { Copy-Item -LiteralPath $f -Destination "$f.romopti.bak" -Force }
            if ($has) { $j.enableHardwareAcceleration = $false } else { Add-Member -InputObject $j -NotePropertyName 'enableHardwareAcceleration' -NotePropertyValue $false -Force }
            Write-TextFile $f (ConvertTo-Json -InputObject $j -Depth 20) }
        Undo = { param($t)
            $f = Join-Path $env:APPDATA 'discord\settings.json'
            if (-not (Test-Path -LiteralPath $f)) { return }
            if (Get-Process -Name Discord -ErrorAction SilentlyContinue) { throw 'Close Discord first.' }
            $old = Get-Extra $t.Id 'Old'
            $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            if ($old -eq '(absent)') { [void]$j.PSObject.Properties.Remove('enableHardwareAcceleration') }
            else { $j.enableHardwareAcceleration = ($old -ne 'False') }
            Write-TextFile $f (ConvertTo-Json -InputObject $j -Depth 20) } })

    return $list.ToArray()
}
# ---- findings: what is actually limiting this PC -------------------------------
function Get-Findings {
    param($F = $script:Facts, $NativeOk = $script:NativeOk)
    $out = New-Object System.Collections.ArrayList
    function Add-Finding { param($Level, $Title, $Detail) [void]$out.Add([pscustomobject]@{ Level = $Level; Title = $Title; Detail = $Detail }) }

    # Refresh rate: the most common free win
    try {
        if ($NativeOk) {
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
        if ($mods.Count -eq 1 -and -not $F.Laptop -and $F.RamGB -ge 4) { Add-Finding 'warn' 'Only one memory stick is installed' 'A single stick runs in single-channel mode, which roughly halves memory bandwidth. Two matched sticks in the slots your motherboard manual names is a free and large win for CPU-bound games like Rust.' }
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
                $bus = ''
                try { $bus = [string](Get-Partition -DriveLetter $letter -ErrorAction Stop | Get-Disk -ErrorAction Stop | Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1).BusType } catch { }
                $kind = if ($bus -eq 'NVMe') { 'NVMe solid-state drive' } else { 'solid-state drive' }
                Add-Finding 'ok' "Rust is on a $kind ($letter`:)" 'Good, asset streaming will not bottleneck on storage.'
                try {
                    $tr = Invoke-NativeOut { fsutil behavior query DisableDeleteNotify }
                    if ($tr.Out -match 'NTFS DisableDeleteNotify\s*=\s*1') { Add-Finding 'warn' 'TRIM is turned off' 'SSD TRIM keeps write speed and frame pacing from degrading over time. Turn it back on from an admin prompt: fsutil behavior set DisableDeleteNotify 0' }
                } catch { }
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

    foreach ($g in @($F.Gpus)) {
        try {
            if ($g.DriverDate) {
                $age = [int]((Get-Date) - [datetime]$g.DriverDate).TotalDays
                if ($age -gt 240) { Add-Finding 'info' "$($g.Name) driver is $age days old" 'Newer drivers often carry game-specific fixes and performance work. Download it from the GPU vendor yourself, this app never installs drivers.' }
            }
        } catch { }
    }

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
        @{ Id = 'shader';   Name = 'GPU shader caches (troubleshooting only)'; Rec = $false; Paths = @("$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\NVIDIA\GLCache", "$env:LOCALAPPDATA\AMD\DxCache", "$env:LOCALAPPDATA\AMD\DxcCache")
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
        $svcList = @($j.Services | Where-Object { $_ })
        if ($svcList.Count -gt 0) { Start-ServicesFast $svcList; $n = $svcList.Count }
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
            if ($svc -and $svc.Status -eq 'Running') { $stopped += $n }
        }
        $script:Session.Stopped = $stopped
        Save-SessionState
        Stop-ServicesFast $stopped
        Write-Log "Paused $($stopped.Count) background service(s) until the session ends." 'ok'
    }
    $script:Session.Prio  = [bool]$Opt.Priority
    $script:Session.Pin   = [bool]$Opt.Pin
    $script:Session.Purge = [bool]$Opt.Purge
    $script:Session.Tick  = 0
}

function Stop-GameSession {
    if (-not $script:Session.Active) { return }
    if ($script:Session.Timer -and $script:NativeOk) { [RomNative]::ReleaseTimer(); $script:Session.Timer = $false }
    $n = 0
    $n = @($script:Session.Stopped).Count
    Start-ServicesFast @($script:Session.Stopped)
    $script:Session.Stopped = @()
    Remove-Item -LiteralPath $script:SessionFile -Force -ErrorAction SilentlyContinue
    Reset-GameAffinity
    $script:Session.Active = $false; $script:Session.Prio = $false; $script:Session.Purge = $false; $script:Session.Pin = $false
    Write-Log "Session ended. Timer released, $n service(s) restarted." 'accent'
}

function Close-BackgroundApps {
    param([string[]]$Names)
    $closed = 0; $ram = 0.0
    $procs = @()
    foreach ($n in $Names) { $procs += @(Get-Process -Name $n -ErrorAction SilentlyContinue) }
    foreach ($p in $procs) { try { $ram += $p.WorkingSet64; [void]$p.CloseMainWindow() } catch { } }
    Wait-Ui 1500
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
        Checkpoint-Computer -Description 'Rom-Opti' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
    } finally {
        if ($null -eq $old) { Remove-RegValue $key 'SystemRestorePointCreationFrequency' } else { Set-Reg $key 'SystemRestorePointCreationFrequency' $old }
    }
}

function New-RestorePointAsync {
    # Checkpoint-Computer can take 10-30 seconds, so it runs in a worker while the window stays alive.
    [void](Invoke-Blocking -TimeoutSec 240 -Functions 'New-RestorePoint', 'Get-RegValue', 'Set-Reg', 'Remove-RegValue' -Script { New-RestorePoint })
}
# ---- debloat -------------------------------------------------------------------
# Safe = recommended removal for nearly everyone. Optional = real apps some people use.
function Get-DebloatCatalog {
    $rows = @(
        # Microsoft apps almost nobody uses
        ,@('3D Viewer',                 'ms',    $true,  @('Microsoft.Microsoft3DViewer'))
        ,@('Mixed Reality Portal',      'ms',    $true,  @('Microsoft.MixedReality.Portal'))
        ,@('Paint 3D',                  'ms',    $true,  @('Microsoft.MSPaint'))
        ,@('Print 3D',                  'ms',    $true,  @('Microsoft.Print3D'))
        ,@('Clipchamp video editor',    'ms',    $true,  @('Clipchamp.Clipchamp'))
        ,@('Cortana',                   'ms',    $true,  @('Microsoft.549981C3F5F10'))
        ,@('Copilot app',               'ms',    $true,  @('Microsoft.Copilot', 'Microsoft.Windows.Ai.Copilot.Provider'))
        ,@('Feedback Hub',              'ms',    $true,  @('Microsoft.WindowsFeedbackHub'))
        ,@('Get Help',                  'ms',    $true,  @('Microsoft.GetHelp'))
        ,@('Tips / Get Started',        'ms',    $true,  @('Microsoft.Getstarted'))
        ,@('Maps',                      'ms',    $true,  @('Microsoft.WindowsMaps'))
        ,@('News',                      'ms',    $true,  @('Microsoft.BingNews'))
        ,@('Weather',                   'ms',    $true,  @('Microsoft.BingWeather'))
        ,@('Bing Search',               'ms',    $true,  @('Microsoft.BingSearch'))
        ,@('Bing Finance / Sports / Travel / Food', 'ms', $true, @('Microsoft.BingFinance', 'Microsoft.BingSports', 'Microsoft.BingTranslator', 'Microsoft.BingTravel', 'Microsoft.BingFoodAndDrink', 'Microsoft.BingHealthAndFitness'))
        ,@('Solitaire Collection',      'ms',    $true,  @('Microsoft.MicrosoftSolitaireCollection'))
        ,@('Microsoft 365 hub',         'ms',    $true,  @('Microsoft.MicrosoftOfficeHub'))
        ,@('OneNote (Store)',           'ms',    $true,  @('Microsoft.Office.OneNote'))
        ,@('Sway',                      'ms',    $true,  @('Microsoft.Office.Sway'))
        ,@('Skype',                     'ms',    $true,  @('Microsoft.SkypeApp'))
        ,@('Teams (consumer)',          'ms',    $true,  @('MicrosoftTeams', 'MSTeams'))
        ,@('People',                    'ms',    $true,  @('Microsoft.People'))
        ,@('Mail and Calendar',         'ms',    $true,  @('microsoft.windowscommunicationsapps'))
        ,@('New Outlook',               'ms',    $true,  @('Microsoft.OutlookForWindows'))
        ,@('Phone Link',                'ms',    $true,  @('Microsoft.YourPhone', 'MicrosoftWindows.CrossDevice'))
        ,@('Power Automate',            'ms',    $true,  @('Microsoft.PowerAutomateDesktop'))
        ,@('Microsoft To Do',           'ms',    $true,  @('Microsoft.Todos'))
        ,@('Whiteboard',                'ms',    $true,  @('Microsoft.Whiteboard'))
        ,@('Journal',                   'ms',    $true,  @('Microsoft.MicrosoftJournal'))
        ,@('Wallet',                    'ms',    $true,  @('Microsoft.Wallet'))
        ,@('Movies and TV',             'ms',    $true,  @('Microsoft.ZuneVideo'))
        ,@('Microsoft Family',          'ms',    $true,  @('MicrosoftCorporationII.MicrosoftFamily'))
        ,@('Dev Home',                  'ms',    $true,  @('Microsoft.Windows.DevHome'))
        ,@('Messaging / OneConnect',    'ms',    $true,  @('Microsoft.Messaging', 'Microsoft.OneConnect'))
        ,@('Power BI',                  'ms',    $true,  @('Microsoft.MicrosoftPowerBIForWindows'))
        ,@('Network Speed Test',        'ms',    $true,  @('Microsoft.NetworkSpeedTest'))
        ,@('Edge Game Assist',          'ms',    $true,  @('Microsoft.Edge.GameAssist'))
        # Preinstalled third-party promos
        ,@('Spotify',                   'promo', $true,  @('SpotifyAB.SpotifyMusic'))
        ,@('Disney+',                   'promo', $true,  @('Disney.37853FC22B2CE'))
        ,@('Netflix',                   'promo', $true,  @('4DF9E0F8.Netflix'))
        ,@('Prime Video',               'promo', $true,  @('AmazonVideo.PrimeVideo'))
        ,@('Hulu',                      'promo', $true,  @('HULULLC.HULUPLUS'))
        ,@('TikTok',                    'promo', $true,  @('BytedancePte.Ltd.TikTok'))
        ,@('Instagram',                 'promo', $true,  @('Facebook.InstagramBeta'))
        ,@('Facebook',                  'promo', $true,  @('Facebook.Facebook'))
        ,@('Twitter / X',               'promo', $true,  @('9E2F88E3.Twitter'))
        ,@('LinkedIn',                  'promo', $true,  @('7EE7776C.LinkedInforWindows'))
        ,@('Candy Crush and King games','promo', $true,  @('king.com.*'))
        ,@('Duolingo',                  'promo', $true,  @('*Duolingo*'))
        ,@('Adobe Express / Photoshop Express', 'promo', $true, @('*AdobeExpress*', 'AdobeSystemsIncorporated.AdobePhotoshopExpress'))
        ,@('Pandora / iHeartRadio / Shazam', 'promo', $true, @('*Pandora*', '*iHeartRadio*', '*Shazam*'))
        ,@('PicsArt / Flipboard / Viber', 'promo', $true, @('*PicsArt*', '*Flipboard*', '*Viber*'))
        ,@('Gameloft and mobile games', 'promo', $true,  @('*GameloftSA*', '*Asphalt8*', '*MarchofEmpires*', '*RoyalRevolt*', '*HiddenCity*', '*CookingFever*', '*FarmVille*', '*BubbleWitch*'))
        ,@('Eclipse Manager / Actipro / SketchBook', 'promo', $true, @('*EclipseManager*', '*ActiproSoftwareLLC*', '*AutodeskSketchBook*'))
        ,@('McAfee (Store trial)',      'promo', $true,  @('*McAfee*'))
        # Xbox and gaming (needed for Game Pass, Minecraft launcher sign-in, etc.)
        ,@('Xbox app',                  'xbox',  $false, @('Microsoft.GamingApp', 'Microsoft.XboxApp'))
        ,@('Xbox Game Bar overlays',    'xbox',  $false, @('Microsoft.XboxGamingOverlay', 'Microsoft.XboxGameOverlay', 'Microsoft.XboxSpeechToTextOverlay'))
        ,@('Xbox identity + Gaming Services', 'xbox', $false, @('Microsoft.XboxIdentityProvider', 'Microsoft.GamingServices', 'Microsoft.Xbox.TCUI'))
        ,@('Minecraft Launcher (Store)', 'xbox', $false, @('Microsoft.MinecraftUWP', 'Microsoft.4297127D64EC6'))
        # Other optional
        ,@('Media Player',              'opt',   $false, @('Microsoft.ZuneMusic'))
        ,@('Sticky Notes',              'opt',   $false, @('Microsoft.MicrosoftStickyNotes'))
        ,@('Alarms and Clock',          'opt',   $false, @('Microsoft.WindowsAlarms'))
        ,@('Camera',                    'opt',   $false, @('Microsoft.WindowsCamera'))
        ,@('Sound Recorder',            'opt',   $false, @('Microsoft.WindowsSoundRecorder'))
        ,@('Quick Assist',              'opt',   $false, @('MicrosoftCorporationII.QuickAssist'))
        ,@('Remote Desktop (Store)',    'opt',   $false, @('Microsoft.RemoteDesktop'))
        ,@('Dolby Access',              'opt',   $false, @('DolbyLaboratories.DolbyAccess'))
        ,@('Widgets provider',          'opt',   $false, @('MicrosoftWindows.Client.WebExperience'))
    )
    $out = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($r in $rows) {
        $i++
        [void]$out.Add(@{ Id = ('d{0:D3}' -f $i); Name = $r[0]; Cat = $r[1]; Safe = $r[2]; Patterns = @($r[3]) })
    }
    [void]$out.Add(@{ Id = 'donedrive'; Name = 'OneDrive (uninstall the program)'; Cat = 'opt'; Safe = $false; Patterns = @(); Special = 'onedrive' })
    return $out.ToArray()
}

$script:DebloatCats = [ordered]@{
    ms    = 'Microsoft apps almost nobody uses'
    promo = 'Preinstalled promos and trial apps'
    xbox  = 'Xbox and gaming services (needed for Game Pass)'
    opt   = 'Other optional apps'
}

# Self-contained (runs in a background runspace). Returns installed package names.
$script:DebloatScan = {
    $names = New-Object System.Collections.Generic.List[string]
    try { foreach ($p in (Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)) { if (-not $p.NonRemovable -and -not $p.IsFramework) { $names.Add([string]$p.Name) } } } catch { }
    try { foreach ($p in (Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)) { $names.Add([string]$p.DisplayName) } } catch { }
    $od = @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($od) { $names.Add('__onedrive__') }
    ,($names | Sort-Object -Unique)
}

$script:DebloatWork = {
    param($Items)
    $all  = @(); $prov = @()
    try { $all  = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue) } catch { }
    try { $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue) } catch { }
    foreach ($it in $Items) {
        $Q.Enqueue(@{ Kind = 'start'; Id = $it.Id })
        $removed = 0; $err = $null
        try {
            if ($it.Special -eq 'onedrive') {
                Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                $exe = @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                if ($exe) { Start-Process -FilePath $exe -ArgumentList '/uninstall' -Wait -WindowStyle Hidden; $removed++ }
            } else {
                foreach ($pat in $it.Patterns) {
                    foreach ($p in @($all | Where-Object { $_.Name -like $pat -and -not $_.NonRemovable -and -not $_.IsFramework })) {
                        try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop; $removed++ }
                        catch { try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop; $removed++ } catch { $err = $_.Exception.Message } }
                    }
                    foreach ($pp in @($prov | Where-Object { $_.DisplayName -like $pat })) {
                        try { [void](Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop) } catch { }
                    }
                }
            }
        } catch { $err = $_.Exception.Message }
        $Q.Enqueue(@{ Kind = 'done'; Id = $it.Id; Removed = $removed; Err = $err })
    }
}

# ---- startup manager -------------------------------------------------------------
$script:StartupKeep = 'SecurityHealth|Windows Defender|Realtek|RtkAud|Audio|NVIDIA|NvBackend|Intel.*Graphics|IgfxTray|AMD|RadeonSoftware|Synaptics|Touchpad|Bluetooth|OneDrive'

function Get-StartupEnabled {
    param([string]$Key, [string]$Name)
    $v = Get-RegValue $Key $Name $null
    # Get-RegValue's return unrolls byte[] into object[], so test for any array
    if ($v -is [System.Array] -and $v.Count -gt 0) { return (([int]$v[0] -band 1) -eq 0) }
    return $true
}

function Set-StartupEnabled {
    param([string]$Key, [string]$Name, [bool]$On)
    if ($On) { $b = [byte[]]@(2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
    else     { $b = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc())) }
    Set-Reg $Key $Name $b 'Binary'
}

function Get-StartupItems {
    $items = New-Object System.Collections.ArrayList
    $appr = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $defs = @(
        @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; App = "HKCU:\$appr\Run"; Scope = 'Your account' }
        @{ Run = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; App = "HKLM:\$appr\Run"; Scope = 'All users' }
        @{ Run = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; App = "HKLM:\$appr\Run32"; Scope = 'All users (32-bit)' }
    )
    foreach ($d in $defs) {
        try {
            $k = Get-Item -LiteralPath $d.Run -ErrorAction Stop
            foreach ($n in $k.GetValueNames()) {
                if (-not $n) { continue }
                [void]$items.Add([pscustomobject]@{ Name = $n; Command = [string]$k.GetValue($n); Scope = $d.Scope; Key = $d.App; Enabled = (Get-StartupEnabled $d.App $n) })
            }
        } catch { }
    }
    $folders = @(
        @{ Dir = [Environment]::GetFolderPath('Startup');       App = "HKCU:\$appr\StartupFolder"; Scope = 'Startup folder' }
        @{ Dir = [Environment]::GetFolderPath('CommonStartup'); App = "HKLM:\$appr\StartupFolder"; Scope = 'Startup folder (all users)' }
    )
    foreach ($f in $folders) {
        try {
            if (-not $f.Dir -or -not (Test-Path -LiteralPath $f.Dir)) { continue }
            foreach ($file in (Get-ChildItem -LiteralPath $f.Dir -File -ErrorAction Stop | Where-Object { $_.Name -ne 'desktop.ini' })) {
                [void]$items.Add([pscustomobject]@{ Name = $file.Name; Command = $file.FullName; Scope = $f.Scope; Key = $f.App; Enabled = (Get-StartupEnabled $f.App $file.Name) })
            }
        } catch { }
    }
    return @($items | Sort-Object Name)
}
# ---- internet engine ---------------------------------------------------------------
# Uses Windows' supported NetTCPIP / NetAdapter cmdlets (locale independent), never raw registry hacks.
# The user's real baseline is captured before the first change and restored from, not guessed.
$script:NetBaselineFile = Join-Path $script:AppDir 'network-baseline.json'

function Get-NetPrimary {
    try {
        $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
        if (-not $r) { return $null }
        $ad  = Get-NetAdapter -InterfaceIndex $r.ifIndex -ErrorAction Stop
        $ip  = Get-NetIPAddress -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        $dns = @((Get-DnsClientServerAddress -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
        $ifc = Get-NetIPInterface -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $type = [string]$ad.PhysicalMediaType
        if ($type -match '802\.11|Wireless|Wi-?Fi') { $type = 'Wi-Fi' } elseif ($type -match '802\.3') { $type = 'Ethernet' } elseif (-not $type) { $type = [string]$ad.MediaType }
        return [pscustomobject]@{
            Name = $ad.Name; Desc = $ad.InterfaceDescription; Speed = [string]$ad.LinkSpeed; Type = $type
            Ip = $(if ($ip) { $ip.IPAddress } else { '' }); Gateway = [string]$r.NextHop; Dns = $dns
            Mtu = $(if ($ifc) { [int]$ifc.NlMtu } else { 0 }); Index = [int]$r.ifIndex
        }
    } catch { return $null }
}

function Get-TcpState {
    $t = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop
    $o = Get-NetOffloadGlobalSetting -ErrorAction Stop
    return @{
        AutoTuning = [string]$t.AutoTuningLevelLocal; Heuristics = [string]$t.ScalingHeuristics
        Ecn = [string]$t.EcnCapability; Timestamps = [string]$t.Timestamps
        Rss = [string]$o.ReceiveSideScaling; Rsc = [string]$o.ReceiveSegmentCoalescing
    }
}

function Set-TcpState {
    param($S)
    Set-NetTCPSetting -SettingName Internet -AutoTuningLevelLocal $S.AutoTuning -ScalingHeuristics $S.Heuristics -EcnCapability $S.Ecn -Timestamps $S.Timestamps -ErrorAction Stop
    Set-NetOffloadGlobalSetting -ReceiveSideScaling $S.Rss -ReceiveSegmentCoalescing $S.Rsc -ErrorAction Stop
}

# Background-worker wrappers: the NetTCPIP cmdlets can take seconds, so they never run on the UI thread.
function Get-TcpStateBg   { $x = @(Invoke-Blocking -Functions 'Get-TcpState' -Script { Get-TcpState })[0]; if ($x -is [System.Management.Automation.PSObject]) { $x = $x.BaseObject }; return $x }
function Set-TcpStateBg   { param($S) [void](Invoke-Blocking -Functions 'Set-TcpState' -ArgList @(,$S) -Script { param($s) Set-TcpState $s }) }
function Get-NetPrimaryBg { return @(Invoke-Blocking -Functions 'Get-NetPrimary' -Script { Get-NetPrimary })[0] }

function Save-NetBaseline {
    if (Test-Path -LiteralPath $script:NetBaselineFile) { return }
    $state = Get-TcpStateBg
    Write-TextFile $script:NetBaselineFile (ConvertTo-Json -InputObject @{ At = (Get-Date).ToString('s'); State = $state } -Depth 4)
}

function Get-NetBaseline {
    if (-not (Test-Path -LiteralPath $script:NetBaselineFile)) { return $null }
    try { $h = ConvertTo-Plain (ConvertFrom-Json (Get-Content -LiteralPath $script:NetBaselineFile -Raw)); return $h.State } catch { return $null }
}

function Get-TcpTarget {
    param([string]$Profile, $Base, $Cur)
    $b = if ($Base) { $Base } else { $Cur }
    switch ($Profile) {
        'default'    { return $b }
        'gaming'     { return @{ AutoTuning = 'Normal'; Heuristics = 'Disabled'; Ecn = 'Disabled'; Timestamps = 'Disabled'; Rss = 'Enabled'; Rsc = $b.Rsc } }
        'throughput' { return @{ AutoTuning = 'Normal'; Heuristics = 'Disabled'; Ecn = 'Disabled'; Timestamps = 'Disabled'; Rss = 'Enabled'; Rsc = 'Enabled' } }
    }
    return $b
}

function Compare-TcpState {
    param($From, $To)
    $diff = @()
    foreach ($k in 'AutoTuning', 'Heuristics', 'Ecn', 'Timestamps', 'Rss', 'Rsc') {
        if ("$($From[$k])" -ne "$($To[$k])") { $diff += ("{0}: {1} -> {2}" -f $k, $From[$k], $To[$k]) }
    }
    return $diff
}

function Test-PingStats {
    param([string]$Target, [int]$Count = 10, [int]$Timeout = 1000, [switch]$Pump)
    $res = @{ Sent = $Count; Lost = 0; Avg = 0.0; Min = 0.0; Max = 0.0; Jitter = 0.0 }
    if (-not $Target) { $res.Lost = $Count; return $res }
    $p = New-Object System.Net.NetworkInformation.Ping
    $times = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $task = $p.SendPingAsync($Target, $Timeout)
            while (-not $task.IsCompleted) { Invoke-UiPump; Start-Sleep -Milliseconds 8 }
            $r = $task.Result
            if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $times.Add([double]$r.RoundtripTime) } else { $res.Lost++ }
        } catch { $res.Lost++ }
        Wait-Ui 70
    }
    if ($times.Count -gt 0) {
        $res.Avg = [math]::Round(($times | Measure-Object -Average).Average, 1)
        $res.Min = ($times | Measure-Object -Minimum).Minimum
        $res.Max = ($times | Measure-Object -Maximum).Maximum
        if ($times.Count -gt 1) {
            $sum = 0.0
            for ($i = 1; $i -lt $times.Count; $i++) { $sum += [math]::Abs($times[$i] - $times[$i - 1]) }
            $res.Jitter = [math]::Round($sum / ($times.Count - 1), 1)
        }
    }
    return $res
}

function Find-PathMtu {
    # Largest unfragmented ICMP payload via binary search, plus 28 bytes of headers.
    param([string]$Target = '1.1.1.1', [switch]$Pump)
    $p = New-Object System.Net.NetworkInformation.Ping
    $opt = New-Object System.Net.NetworkInformation.PingOptions
    $opt.DontFragment = $true
    $try = {
        param([int]$size)
        $buf = New-Object byte[] $size
        try {
            $task = $p.SendPingAsync($Target, 1500, $buf, $opt)
            while (-not $task.IsCompleted) { Invoke-UiPump; Start-Sleep -Milliseconds 8 }
            return ($task.Result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
        } catch { return $false }
    }
    if (-not (& $try 32)) { return $null }
    if (& $try 1472) { return 1500 }
    $lo = 32; $hi = 1472
    while ($lo -lt $hi) {
        $mid = [int][math]::Ceiling(($lo + $hi) / 2)
        if (& $try $mid) { $lo = $mid } else { $hi = $mid - 1 }
        if ($Pump) { Invoke-UiPump }
    }
    return ($lo + 28)
}

function Test-DnsServers {
    param([string[]]$Servers, [switch]$Pump)
    $names = @('www.google.com', 'store.steampowered.com', 'www.cloudflare.com')
    $out = @()
    foreach ($s in ($Servers | Where-Object { $_ } | Select-Object -Unique)) {
        $ms = New-Object System.Collections.Generic.List[double]; $fail = 0
        foreach ($n in $names) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try { [void](Resolve-DnsName -Name $n -Server $s -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop); $ms.Add($sw.Elapsed.TotalMilliseconds) } catch { $fail++ }
            if ($Pump) { Invoke-UiPump }
        }
        $avg = if ($ms.Count -gt 0) { [math]::Round(($ms | Measure-Object -Average).Average, 1) } else { -1 }
        $out += [pscustomobject]@{ Server = $s; Avg = $avg; Failed = $fail }
    }
    return $out
}

function Invoke-TcpProfile {
    param([string]$Profile, [bool]$Rollback = $true, [switch]$Pump)
    Save-NetBaseline
    $base = Get-NetBaseline
    $cur  = Get-TcpStateBg
    $target = Get-TcpTarget $Profile $base $cur
    $diff = @(Compare-TcpState $cur $target)
    $result = @{ Changes = $diff; RolledBack = $false; Pre = $null; Post = $null }
    if ($diff.Count -eq 0) { return $result }
    $info = Get-NetPrimaryBg
    $result.Pre = Test-PingStats '1.1.1.1' 6 1000 -Pump:$Pump
    Set-TcpStateBg $target
    Wait-Ui 800
    $result.Post = Test-PingStats '1.1.1.1' 6 1000 -Pump:$Pump
    if ($Rollback) {
        $pre = $result.Pre; $post = $result.Post
        $broke = ($post.Lost -ge $post.Sent) -and ($pre.Lost -lt $pre.Sent)
        $lossier = ($post.Lost -gt ($pre.Lost + 1))
        $slower = ($pre.Avg -gt 0 -and $post.Avg -gt (($pre.Avg * 1.5) + 5))
        if ($broke -or $lossier -or $slower) { Set-TcpStateBg $cur; $result.RolledBack = $true }
    }
    return $result
}

# ---- profiles and full revert ---------------------------------------------------------
function Export-OptProfile {
    param([string]$Path)
    $F = $script:Facts
    $applied = @()
    foreach ($id in $script:Cards.Keys) { if ($script:Cards[$id].Applied) { $applied += $id } }
    $tcp = $null; try { $tcp = Get-TcpStateBg } catch { }
    $obj = @{
        Format = 1; App = 'Rom-Opti'; Version = $script:Version; Exported = (Get-Date).ToString('s')
        Windows = $F.OsName; Build = $F.Build; Cpu = $F.CpuName; RamGB = $F.RamGB
        Applied = $applied; Tcp = $tcp; NetBaseline = (Get-NetBaseline); Journal = $script:Journal
    }
    Write-TextFile $Path (ConvertTo-Json -InputObject $obj -Depth 10)
}

function Import-OptProfile {
    param([string]$Path)
    $j = ConvertFrom-Json (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
    if ($j.App -notin 'Rom-Opti', 'Rom-Opti') { throw 'That file is not a Rom-Opti profile.' }
    return @($j.Applied)
}
# ---- UI definition (XAML) -----------------------------------------------------
$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Rom-Opti" Width="1140" Height="740"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="CanMinimize" FontFamily="Segoe UI"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg0" Color="#070914"/>
    <SolidColorBrush x:Key="Bg1" Color="#0C0F1F"/>
    <SolidColorBrush x:Key="Bg2" Color="#121629"/>
    <SolidColorBrush x:Key="Bg3" Color="#191E36"/>
    <SolidColorBrush x:Key="Line" Color="#242A47"/>
    <SolidColorBrush x:Key="Text" Color="#ECEFFA"/>
    <SolidColorBrush x:Key="Muted" Color="#98A2C3"/>
    <SolidColorBrush x:Key="Dim" Color="#5F6A8E"/>
    <SolidColorBrush x:Key="Accent" Color="#7C5CFF"/>
    <SolidColorBrush x:Key="AccentHi" Color="#A28BFF"/>
    <SolidColorBrush x:Key="Good" Color="#2ED3A0"/>
    <SolidColorBrush x:Key="Warn" Color="#FFB547"/>
    <SolidColorBrush x:Key="Bad" Color="#FF5C7A"/>

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
            <Border x:Name="bd" CornerRadius="8" Background="Transparent" Padding="12,8">
              <Grid>
                <Rectangle x:Name="bar" Width="3" Height="16" RadiusX="1.5" RadiusY="1.5" Fill="{StaticResource Accent}" HorizontalAlignment="Left" Margin="-12,0,0,0" Visibility="Collapsed"/>
                <ContentPresenter VerticalAlignment="Center"><ContentPresenter.RenderTransform><TranslateTransform x:Name="nt" X="0"/></ContentPresenter.RenderTransform></ContentPresenter>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Bg2}"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
                <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="nt" Storyboard.TargetProperty="X" To="5" Duration="0:0:0.14"><DoubleAnimation.EasingFunction><QuadraticEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction></DoubleAnimation></Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="nt" Storyboard.TargetProperty="X" To="0" Duration="0:0:0.18"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="Transparent"/>
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
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform><ScaleTransform x:Name="bs" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="Opacity" To="0.82" Duration="0:0:0.12"/></Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.18"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="bs" Storyboard.TargetProperty="ScaleX" To="0.965" Duration="0:0:0.07"/>
                  <DoubleAnimation Storyboard.TargetName="bs" Storyboard.TargetProperty="ScaleY" To="0.965" Duration="0:0:0.07"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="bs" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.14"/>
                  <DoubleAnimation Storyboard.TargetName="bs" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.14"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="#0C0A1A"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="{StaticResource Bad}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="#4A2338"/>
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
      <Setter Property="Foreground" Value="#0D0A1F"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="30" Padding="46,17" RenderTransformOrigin="0.5,0.5">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                  <GradientStop Color="#A28BFF" Offset="0"/>
                  <GradientStop x:Name="hlStop" Color="#DCD3FF" Offset="0"/>
                  <GradientStop Color="#5B3FE0" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <Border.Effect><DropShadowEffect Color="#7C5CFF" BlurRadius="30" Opacity="0.42" ShadowDepth="0"/></Border.Effect>
              <Border.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Border.RenderTransform>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Effect">
                  <Setter.Value><DropShadowEffect Color="#A28BFF" BlurRadius="46" Opacity="0.7" ShadowDepth="0"/></Setter.Value>
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
              <Border x:Name="track" Width="38" Height="21" CornerRadius="10.5" VerticalAlignment="Center">
                <Border.Background><SolidColorBrush Color="#2C3354"/></Border.Background>
                <Ellipse x:Name="knob" Width="15" Height="15" Fill="#CBD3EE" HorizontalAlignment="Left" Margin="3,0,0,0"/>
              </Border>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="knob" Property="Fill" Value="#FFFFFF"/>
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <ThicknessAnimation Storyboard.TargetName="knob" Storyboard.TargetProperty="Margin" To="20,0,0,0" Duration="0:0:0.18"><ThicknessAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.35"/></ThicknessAnimation.EasingFunction></ThicknessAnimation>
                  <ColorAnimation Storyboard.TargetName="track" Storyboard.TargetProperty="Background.Color" To="#7C5CFF" Duration="0:0:0.18"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <ThicknessAnimation Storyboard.TargetName="knob" Storyboard.TargetProperty="Margin" To="3,0,0,0" Duration="0:0:0.16"/>
                  <ColorAnimation Storyboard.TargetName="track" Storyboard.TargetProperty="Background.Color" To="#2C3354" Duration="0:0:0.16"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
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
              <Border x:Name="box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.5" BorderBrush="#394167" Background="#0E1224" VerticalAlignment="Center">
                <Path x:Name="tick" Data="M 4,9.5 L 7.5,13 L 14,5" Stroke="#0C0A1A" StrokeThickness="2.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
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

    <Style x:Key="FilterChip" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" CornerRadius="14" Background="{StaticResource Bg2}" BorderBrush="{StaticResource Line}" BorderThickness="1" Padding="13,5">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter Property="Foreground" Value="#0C0A1A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Bg1}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Accent}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="10,6">
              <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
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
      <Setter Property="Background" Value="#1B2140"/>
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
                        <Border x:Name="tb" Background="#2A3050" CornerRadius="4" Margin="1"/>
                        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="tb" Property="Background" Value="#3E4870"/></Trigger></ControlTemplate.Triggers>
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
            <RadialGradientBrush x:Name="bgGrad" Center="0.5,0.46" GradientOrigin="0.5,0.46" RadiusX="0.62" RadiusY="0.62">
              <GradientStop Color="#1F7C5CFF" Offset="0"/>
              <GradientStop Color="#0A7C5CFF" Offset="0.45"/>
              <GradientStop Color="#00000000" Offset="1"/>
            </RadialGradientBrush>
          </Border.Background>
        </Border>
        <Canvas x:Name="bokeh" IsHitTestVisible="False" ClipToBounds="True"><Canvas.RenderTransform><TranslateTransform x:Name="parBokeh" X="0" Y="0"/></Canvas.RenderTransform></Canvas>
        <Canvas x:Name="particles" IsHitTestVisible="False" ClipToBounds="True"><Canvas.RenderTransform><TranslateTransform x:Name="parPart" X="0" Y="0"/></Canvas.RenderTransform></Canvas>
        <Ellipse x:Name="glow" Width="560" Height="560" IsHitTestVisible="False" Opacity="0.55" Margin="0,0,0,40" RenderTransformOrigin="0.5,0.5">
          <Ellipse.RenderTransform><ScaleTransform x:Name="glowScale" ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform>
          <Ellipse.Fill>
            <RadialGradientBrush>
              <GradientStop Color="#2C7C5CFF" Offset="0"/>
              <GradientStop Color="#007C5CFF" Offset="1"/>
            </RadialGradientBrush>
          </Ellipse.Fill>
        </Ellipse>

        <StackPanel x:Name="lnChrome" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,10,10,0" Opacity="0">
          <Button x:Name="lnMin" Style="{StaticResource Chrome}" Content="&#xE921;"/>
          <Button x:Name="lnClose" Style="{StaticResource Chrome}" Content="&#xE8BB;"/>
        </StackPanel>

        <StackPanel x:Name="hero" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-10,0,0">
          <Grid x:Name="logoWrap" Width="96" Height="96" HorizontalAlignment="Center" Opacity="0" RenderTransformOrigin="0.5,0.5">
            <Grid.RenderTransform><ScaleTransform x:Name="logoScale" ScaleX="0.5" ScaleY="0.5"/></Grid.RenderTransform>
            <Ellipse x:Name="ring2" Width="124" Height="124" Stroke="#337C5CFF" StrokeThickness="1" StrokeDashArray="1 6" RenderTransformOrigin="0.5,0.5">
              <Ellipse.RenderTransform><RotateTransform x:Name="ring2Rot" Angle="0"/></Ellipse.RenderTransform>
            </Ellipse>
            <Grid x:Name="orbit1" Width="114" Height="114" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><RotateTransform x:Name="orbit1Rot" Angle="0"/></Grid.RenderTransform>
              <Ellipse Width="5" Height="5" Fill="{StaticResource AccentHi}" HorizontalAlignment="Center" VerticalAlignment="Top"/>
            </Grid>
            <Grid x:Name="orbit2" Width="136" Height="136" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><RotateTransform x:Name="orbit2Rot" Angle="0"/></Grid.RenderTransform>
              <Ellipse Width="3.5" Height="3.5" Fill="#B87C5CFF" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
            <Ellipse x:Name="ring" Width="96" Height="96" Stroke="#667C5CFF" StrokeThickness="1.4" StrokeDashArray="2.5 5" RenderTransformOrigin="0.5,0.5">
              <Ellipse.RenderTransform><RotateTransform x:Name="ringRot" Angle="0"/></Ellipse.RenderTransform>
            </Ellipse>
            <Border Width="68" Height="68" CornerRadius="18" BorderBrush="#557C5CFF" BorderThickness="1" Background="#147C5CFF">
              <Border.Effect><DropShadowEffect x:Name="logoFx" Color="#7C5CFF" BlurRadius="26" Opacity="0.35" ShadowDepth="0"/></Border.Effect>
              <Viewbox Width="30" Height="30">
                <Path x:Name="logoBolt" Data="M 15,1 L 3,17 L 11,17 L 9,29 L 23,11 L 14,11 Z" Fill="{StaticResource Accent}"/>
              </Viewbox>
            </Border>
          </Grid>

          <TextBlock x:Name="lnTag" Opacity="0" Margin="0,26,0,0" HorizontalAlignment="Center" FontSize="11" FontWeight="SemiBold" Foreground="{StaticResource Dim}"/>
          <StackPanel x:Name="lnTitle" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,10,0,0"/>
          <TextBlock x:Name="lnSub" Opacity="0" Margin="0,2,0,0" HorizontalAlignment="Center" FontFamily="Bahnschrift, Segoe UI Semibold" FontSize="22" FontWeight="SemiBold" Foreground="{StaticResource Accent}"/>
          <Rectangle x:Name="lnUnder" Width="0" Height="2" RadiusX="1" RadiusY="1" Fill="{StaticResource Accent}" HorizontalAlignment="Center" Margin="0,10,0,0" Opacity="0.85"/>
          <TextBlock x:Name="lnLine" Opacity="0" Margin="0,16,0,0" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" MaxWidth="500" FontSize="14" LineHeight="22" Foreground="{StaticResource Muted}"
                     Text="Windows, scheduler and GPU tweaks, an app debloat and a startup cleaner. Gains depend on your hardware and are often small or zero if the GPU is the limit. Every change is journaled and reversible, and every toggle says what it is realistically worth."/>

          <Button x:Name="btnEnter" Opacity="0" Style="{StaticResource Enter}" HorizontalAlignment="Center" Margin="0,36,0,0"/>

          <StackPanel x:Name="lnChips" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,32,0,0">
            <Border x:Name="chipA" Opacity="0" Background="{StaticResource Bg1}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="14" Padding="12,5" Margin="4,0">
              <TextBlock Text="Fully reversible" FontSize="11.5" Foreground="{StaticResource Muted}"/>
            </Border>
            <Border x:Name="chipB" Opacity="0" Background="{StaticResource Bg1}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="14" Padding="12,5" Margin="4,0">
              <TextBlock Text="No game injection" FontSize="11.5" Foreground="{StaticResource Muted}"/>
            </Border>
            <Border x:Name="chipC" Opacity="0" Background="{StaticResource Bg1}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="14" Padding="12,5" Margin="4,0">
              <TextBlock Text="Honest impact ratings" FontSize="11.5" Foreground="{StaticResource Muted}"/>
            </Border>
          </StackPanel>
        </StackPanel>

        <TextBlock x:Name="lnSys" Opacity="0" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,22" FontSize="11.5" Foreground="{StaticResource Dim}"/>
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
            <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="22,24,16,18">
              <Border x:Name="sideLogo" Width="34" Height="34" CornerRadius="10" Background="#187C5CFF" BorderBrush="#447C5CFF" BorderThickness="1">
                <Border.Effect><DropShadowEffect x:Name="sideFx" Color="#7C5CFF" BlurRadius="8" Opacity="0.3" ShadowDepth="0"/></Border.Effect>
                <Viewbox Width="16" Height="16"><Path Data="M 15,1 L 3,17 L 11,17 L 9,29 L 23,11 L 14,11 Z" Fill="{StaticResource Accent}"/></Viewbox>
              </Border>
              <StackPanel Margin="11,0,0,0" VerticalAlignment="Center">
                <TextBlock Text="ROM-OPTI" FontFamily="Bahnschrift, Segoe UI Semibold" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                <TextBlock Text="OPTIMIZER" FontFamily="Bahnschrift, Segoe UI Semibold" FontSize="10.5" Foreground="{StaticResource Accent}"/>
              </StackPanel>
            </StackPanel>

            <StackPanel DockPanel.Dock="Bottom" Margin="14,6,14,16">
              <CheckBox x:Name="swMotion" Style="{StaticResource Switch}" Content="Animations" IsChecked="True" Foreground="{StaticResource Muted}" FontSize="12" Margin="6,0,0,10"/>
              <Border Padding="12,10" Background="{StaticResource Bg2}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="10">
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <Grid Width="7" Height="7" VerticalAlignment="Center">
                      <Ellipse x:Name="sideRing" Width="7" Height="7" Stroke="{StaticResource Good}" StrokeThickness="1" Opacity="0" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><ScaleTransform x:Name="sideRingS" ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform></Ellipse>
                      <Ellipse x:Name="sideDot" Width="7" Height="7" Fill="{StaticResource Dim}"/>
                    </Grid>
                    <TextBlock x:Name="sideTitle" Text="No active session" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Text}" Margin="8,0,0,0"/>
                  </StackPanel>
                  <TextBlock x:Name="sideSub" Margin="15,3,0,0" FontSize="11" Foreground="{StaticResource Dim}" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
            </StackPanel>

            <Grid DockPanel.Dock="Top">
            <Border x:Name="navHi" Background="#191E36" CornerRadius="8" Height="36" VerticalAlignment="Top" Margin="10,0" Visibility="Collapsed">
              <Border.RenderTransform><TranslateTransform x:Name="navHiT" Y="0"/></Border.RenderTransform>
            </Border>
            <StackPanel x:Name="navPanel">
              <RadioButton x:Name="navDash" Style="{StaticResource Nav}" GroupName="N" IsChecked="True">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE80F;"/><TextBlock Text="Dashboard"/></StackPanel></RadioButton>
              <RadioButton x:Name="navOpt" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE945;"/><TextBlock Text="Optimize"/></StackPanel></RadioButton>
              <RadioButton x:Name="navInternet" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE774;"/><TextBlock Text="Internet"/></StackPanel></RadioButton>
              <RadioButton x:Name="navDebloat" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE74D;"/><TextBlock Text="Debloat"/></StackPanel></RadioButton>
              <RadioButton x:Name="navStartup" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE7E8;"/><TextBlock Text="Startup"/></StackPanel></RadioButton>
              <RadioButton x:Name="navRust" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE7FC;"/><TextBlock Text="Rust"/></StackPanel></RadioButton>
              <RadioButton x:Name="navSession" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE768;"/><TextBlock Text="Game session"/></StackPanel></RadioButton>
              <RadioButton x:Name="navClean" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE894;"/><TextBlock Text="Cleaner"/></StackPanel></RadioButton>
              <RadioButton x:Name="navRestore" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE777;"/><TextBlock Text="Restore &amp; profiles"/></StackPanel></RadioButton>
              <RadioButton x:Name="navLog" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE8A5;"/><TextBlock Text="Activity log"/></StackPanel></RadioButton>
            </StackPanel>
            </Grid>
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
                <Rectangle x:Name="hdrBar" Width="0" Height="2" RadiusX="1" RadiusY="1" Fill="{StaticResource Accent}" HorizontalAlignment="Left" Margin="0,7,0,0"/>
              </StackPanel>
            </DockPanel>
          </Border>

          <Grid Grid.Row="1" Margin="30,4,30,8">

            <!-- Dashboard -->
            <ScrollViewer x:Name="pgDash" VerticalScrollBarVisibility="Auto">
              <StackPanel Margin="0,0,10,12">
                <ProgressBar x:Name="countProxy" Minimum="0" Maximum="1000" Value="0" Visibility="Collapsed" Height="0"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Border x:Name="dCard1" Grid.Column="0" Style="{StaticResource Card}">
                    <StackPanel>
                      <TextBlock Text="THIS PC" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="dCpu" Margin="0,10,0,0" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/>
                      <TextBlock x:Name="dGpu" Margin="0,5,0,0" FontSize="12.5" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                      <TextBlock x:Name="dRam" Margin="0,5,0,0" FontSize="12.5" Foreground="{StaticResource Muted}"/>
                      <TextBlock x:Name="dOs" Margin="0,5,0,0" FontSize="12.5" Foreground="{StaticResource Muted}"/>
                    </StackPanel>
                  </Border>
                  <Border x:Name="dCard2" Grid.Column="2" Style="{StaticResource Card}">
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
                  <Border x:Name="dCard3" Grid.Column="4" Style="{StaticResource Card}">
                    <StackPanel>
                      <TextBlock Text="RUST" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="dRust" Margin="0,10,0,0" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/>
                      <TextBlock x:Name="dRustSub" Margin="0,5,0,0" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                    </StackPanel>
                  </Border>
                </Grid>

                <Border x:Name="dOptCard" Style="{StaticResource Card}" Margin="0,16,0,0">
                  <DockPanel>
                    <Button x:Name="btnOptimizeAll" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Content="Optimize my PC" Padding="26,13" FontSize="14" VerticalAlignment="Center" Margin="16,0,0,0"/>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Text="One click, safe tweaks only" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                      <TextBlock Margin="0,4,0,0" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                        Text="Applies only the Safe-tier tweaks your PC supports, makes a restore point first, then lists exactly what changed. Test-it and Advanced tweaks are never applied automatically."/>
                    </StackPanel>
                  </DockPanel>
                </Border>
                <Border x:Name="dChanges" Style="{StaticResource Card}" Margin="0,12,0,0" Visibility="Collapsed">
                  <StackPanel>
                    <TextBlock x:Name="dChangesTitle" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock x:Name="dChangesSub" Margin="0,4,0,0" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                    <StackPanel x:Name="pnlChanges" Margin="0,10,0,0"/>
                  </StackPanel>
                </Border>

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
                <Border x:Name="bannerReboot" Visibility="Collapsed" Background="#161326" BorderBrush="#5A4A1E" BorderThickness="1" CornerRadius="10" Padding="14,9" Margin="0,0,0,10">
                  <TextBlock x:Name="bannerRebootText" FontSize="12.5" Foreground="{StaticResource Warn}" TextWrapping="Wrap"/>
                </Border>
                <DockPanel Margin="0,0,0,10" LastChildFill="True">
                  <TextBox x:Name="txtSearch" DockPanel.Dock="Right" Width="210" Style="{StaticResource Input}" ToolTip="Search tweaks by name or description"/>
                  <StackPanel Orientation="Horizontal">
                    <RadioButton x:Name="fAll" Style="{StaticResource FilterChip}" GroupName="F" Content="All" IsChecked="True"/>
                    <RadioButton x:Name="fSafe" Style="{StaticResource FilterChip}" GroupName="F" Content="Safe"/>
                    <RadioButton x:Name="fTest" Style="{StaticResource FilterChip}" GroupName="F" Content="Test it"/>
                    <RadioButton x:Name="fAdv" Style="{StaticResource FilterChip}" GroupName="F" Content="Advanced"/>
                    <RadioButton x:Name="fOpt" Style="{StaticResource FilterChip}" GroupName="F" Content="Optional"/>
                  </StackPanel>
                </DockPanel>
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
                      <CheckBox x:Name="loHigh" Style="{StaticResource Switch}" Content="-high   (optional, test it)" IsChecked="False" Margin="0,5,26,5"/>
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
                      Text="These run only while a session is active and undo themselves when it ends or when you close Rom-Opti. Startup settings are never changed, so nothing is left behind if something crashes."/>
                    <CheckBox x:Name="sesTimer" Style="{StaticResource Switch}" Content="Hold the finest system timer (usually 0.5 ms)" IsChecked="True" Margin="0,5"/>
                    <CheckBox x:Name="sesPurge" Style="{StaticResource Switch}" Content="Smart standby-memory cleaner (only when free memory runs low)" IsChecked="True" Margin="0,5"/>
                    <CheckBox x:Name="sesPrio" Style="{StaticResource Switch}" Content="Raise the game to Above Normal priority when it starts" IsChecked="True" Margin="0,5"/>
                    <CheckBox x:Name="sesPin" Style="{StaticResource Switch}" Content="Pin the game to the V-Cache cores (dual-CCD X3D only)" IsChecked="True" Margin="0,5" Visibility="Collapsed"/>
                    <CheckBox x:Name="sesSvc" Style="{StaticResource Switch}" Content="Pause background services (search indexing, Windows Update, telemetry, SysMain)" Margin="0,5"/>
                    <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                      <TextBlock Text="Game process" FontSize="12.5" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="0,0,12,0"/>
                      <TextBox x:Name="txtGameExe" Style="{StaticResource Input}" Width="200" Text="RustClient" ToolTip="Process name without .exe. Works for any game, for example cs2, FortniteClient-Win64-Shipping, javaw."/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                      <Button x:Name="btnSesToggle" Style="{StaticResource BtnPrimary}" Content="Start session" Padding="26,11"/>
                      <CheckBox x:Name="sesAuto" Content="Start and stop automatically with the game" Margin="18,0,0,0" VerticalAlignment="Center"/>
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

            <!-- Debloat -->
            <Grid x:Name="pgDebloat" Visibility="Collapsed">
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <StackPanel Grid.Row="0">
                <Border Style="{StaticResource Card}" Padding="14,10" Margin="0,0,0,10">
                  <TextBlock FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                    Text="Removes preinstalled apps for every user and from the install image, so they do not come back for new accounts. Microsoft Store, Photos, Notepad, Calculator, Terminal, Snipping Tool, Paint and Edge are never touched. A restore point is made first, and anything can be reinstalled from the Microsoft Store."/>
                </Border>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                  <Button x:Name="btnDbScan" Style="{StaticResource Btn}" Content="Scan this PC"/>
                  <Button x:Name="btnDbSafe" Style="{StaticResource Btn}" Content="Select safe" Margin="8,0,0,0"/>
                  <Button x:Name="btnDbAll" Style="{StaticResource Btn}" Content="Select all installed" Margin="8,0,0,0"/>
                  <Button x:Name="btnDbNone" Style="{StaticResource Btn}" Content="Clear" Margin="8,0,0,0"/>
                  <Button x:Name="btnDbRun" Style="{StaticResource BtnPrimary}" Content="Remove selected" Margin="8,0,0,0"/>
                </StackPanel>
              </StackPanel>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="pnlDebloat" Margin="0,0,10,8"/></ScrollViewer>
              <Border Grid.Row="2" Style="{StaticResource Card}" Padding="16,12" Margin="0,6,0,0">
                <StackPanel>
                  <DockPanel>
                    <TextBlock x:Name="txtDbCount" DockPanel.Dock="Right" FontSize="13" FontWeight="Bold" Foreground="{StaticResource Accent}"/>
                    <TextBlock x:Name="txtDbStatus" FontSize="12" Foreground="{StaticResource Muted}" Text="Press Scan to see which of these are installed."/>
                  </DockPanel>
                  <ProgressBar x:Name="barDb" Minimum="0" Maximum="100" Value="0" Margin="0,9,0,0"/>
                </StackPanel>
              </Border>
            </Grid>

            <!-- Startup -->
            <Grid x:Name="pgStartup" Visibility="Collapsed">
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
              <Border Grid.Row="0" Style="{StaticResource Card}" Padding="14,10" Margin="0,0,0,10">
                <DockPanel>
                  <Button x:Name="btnStRefresh" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Refresh" Margin="14,0,0,0" VerticalAlignment="Center"/>
                  <TextBlock FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                    Text="Programs that launch at sign-in and sit in the background using RAM and CPU. Turn off anything you do not need running while you play. This is instant and fully reversible. Leave audio, graphics driver and security entries alone."/>
                </DockPanel>
              </Border>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="pnlStartup" Margin="0,0,10,8"/></ScrollViewer>
            </Grid>

            <!-- Internet -->
            <ScrollViewer x:Name="pgInternet" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="pnlInternet" Margin="0,0,10,12">
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Connection" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,6,0,8" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Text="Your active connection, read from Windows. Nothing here changes anything."/>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Adapter" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="nAdapter" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Type" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="nType" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Link speed" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="nSpeed" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="IPv4 address" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="nIp" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Gateway" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="nGw" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="DNS servers" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="nDnsSrv" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Adapter MTU" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="nMtu" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <DockPanel>
                      <Button x:Name="btnNetTest" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Content="Run test"/>
                      <TextBlock Text="Network health" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}" VerticalAlignment="Center"/>
                    </DockPanel>
                    <TextBlock Margin="0,6,0,8" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Text="Measures ping, jitter and packet loss to your router and the internet. This does not change FPS. It tells you whether your connection or your PC is the problem."/>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Router (gateway)" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="hGw" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Internet (1.1.1.1)" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="hWan" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Packet loss" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="hLoss" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Jitter" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="hJit" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="DNS lookup" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="hDns" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="TCP profile" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,6,0,8" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                      Text="Rust and most shooters send game traffic over UDP, which these TCP settings do not touch. Expect better downloads, launchers and TCP-based services, and little to no in-game ping change. Your current settings are saved before the first change, and Windows default restores exactly those."/>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Auto-tuning" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="tAuto" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Scaling heuristics" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="tHeur" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="ECN" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="tEcn" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Timestamps" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="tTs" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Receive-side scaling" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="tRss" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Receive coalescing (RSC)" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="tRsc" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <CheckBox x:Name="swNetRollback" Style="{StaticResource Switch}" Content="Roll back automatically if connectivity gets worse" IsChecked="True" Foreground="{StaticResource Muted}" FontSize="12.5" Margin="0,12,0,0"/>
                    <WrapPanel Margin="0,12,0,0">
                      <Button x:Name="btnTcpGaming" Style="{StaticResource BtnPrimary}" Content="Gaming / balanced" Margin="0,0,8,8"/>
                      <Button x:Name="btnTcpThroughput" Style="{StaticResource Btn}" Content="High throughput" Margin="0,0,8,8"/>
                      <Button x:Name="btnTcpDefault" Style="{StaticResource BtnDanger}" Content="Windows default (restore)" Margin="0,0,8,8"/>
                    </WrapPanel>
                    <TextBlock x:Name="txtTcpStatus" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                    <TextBlock Margin="0,8,0,0" FontSize="11.5" Foreground="{StaticResource Dim}" TextWrapping="Wrap"
                      Text="Gaming / balanced: auto-tuning normal, scaling heuristics off (so Windows cannot quietly throttle your receive window), ECN and timestamps off, RSS on, RSC left as you had it. High throughput also turns RSC on. Neither touches registry hacks or fakes a lower ping."/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <DockPanel>
                      <Button x:Name="btnMtu" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Detect MTU"/>
                      <TextBlock Text="MTU" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}" VerticalAlignment="Center"/>
                    </DockPanel>
                    <TextBlock x:Name="txtMtu" Margin="0,8,0,0" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap" Text="Not tested yet."/>
                    <TextBlock Margin="0,6,0,0" FontSize="11.5" Foreground="{StaticResource Dim}" TextWrapping="Wrap"
                      Text="Finds the largest packet that crosses your connection without fragmenting. This only reports. Lowering MTU does not lower ping, and 1500 is right for most connections. A value like 1492 usually means PPPoE."/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <DockPanel>
                      <Button x:Name="btnDns" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Test DNS"/>
                      <TextBlock Text="DNS" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}" VerticalAlignment="Center"/>
                    </DockPanel>
                    <TextBlock x:Name="txtDns" Margin="0,8,0,0" FontFamily="Consolas" FontSize="12" Foreground="{StaticResource Text}" TextWrapping="Wrap" Text="Not tested yet."/>
                    <TextBlock Margin="0,6,0,0" FontSize="11.5" Foreground="{StaticResource Dim}" TextWrapping="Wrap"
                      Text="DNS only changes how fast names like store.steampowered.com resolve. It does not reduce the latency of a game connection that is already open. Nothing is changed here. Results are approximate because resolvers cache."/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>

            <!-- Restore -->
            <ScrollViewer x:Name="pgRestore" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
              <StackPanel Margin="0,0,10,12">
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Revert everything" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,6,0,12" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                      Text="Undoes every tweak this app applied, using the original values it saved before changing them. Your TCP settings go back to the baseline captured before the first network change. Removed apps are not restored here, reinstall those from the Microsoft Store."/>
                    <WrapPanel>
                      <Button x:Name="btnRevertAll" Style="{StaticResource BtnDanger}" Content="Revert all tweaks" Margin="0,0,8,8"/>
                      <Button x:Name="btnNetRestore" Style="{StaticResource Btn}" Content="Restore network defaults" Margin="0,0,8,8"/>
                    </WrapPanel>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Profiles" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,6,0,12" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                      Text="Export saves which tweaks are applied, your journal, TCP settings and a hardware summary to a file on your desktop. Import loads a profile's tweak choices onto the Optimize page so you can review them before applying. Nothing is applied automatically."/>
                    <WrapPanel>
                      <Button x:Name="btnExport" Style="{StaticResource Btn}" Content="Export profile" Margin="0,0,8,8"/>
                      <Button x:Name="btnImport" Style="{StaticResource Btn}" Content="Import profile" Margin="0,0,8,8"/>
                    </WrapPanel>
                  </StackPanel>
                </Border>
                <TextBlock x:Name="txtRestoreStatus" FontSize="12.5" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
              </StackPanel>
            </ScrollViewer>

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
              <Ellipse x:Name="spin" DockPanel.Dock="Left" Width="12" Height="12" Stroke="{StaticResource Accent}" StrokeThickness="2" StrokeDashArray="2.4 2.6" Margin="0,0,10,0" Visibility="Collapsed" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5">
                <Ellipse.RenderTransform><RotateTransform x:Name="spinRot" Angle="0"/></Ellipse.RenderTransform>
              </Ellipse>
              <TextBlock x:Name="lastLog" FontSize="11.5" Foreground="{StaticResource Dim}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Text="Ready."/>
            </DockPanel>
          </Border>
        </Grid>
      </Grid>

      <Border x:Name="toast" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,26,54" Visibility="Collapsed" IsHitTestVisible="False" Background="#191E36" BorderBrush="#7C5CFF" BorderThickness="1" CornerRadius="10" MinWidth="240" MaxWidth="380">
        <Border.RenderTransform><TranslateTransform x:Name="toastT" X="440"/></Border.RenderTransform>
        <Border.Effect><DropShadowEffect Color="#000000" BlurRadius="18" Opacity="0.5" ShadowDepth="4"/></Border.Effect>
        <StackPanel>
          <TextBlock x:Name="toastText" Margin="16,12,16,10" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/>
          <Rectangle x:Name="toastBar" Height="2" Fill="{StaticResource Accent}" HorizontalAlignment="Left" Width="240"/>
        </StackPanel>
      </Border>
    </Grid>
  </Border>
</Window>
'@
# ---- animation engine -----------------------------------------------------------
# Every animation checks $script:AnimOn, so the "Animations" switch in the sidebar turns them all off.
$script:BaseOp = @{}

function Get-Span { param([double]$Ms) return [TimeSpan]::FromMilliseconds($Ms) }
function Get-Dur  { param([double]$Ms) return (New-Object Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds($Ms))) }

function New-Ease {
    param([string]$Kind = 'Quad', [string]$Mode = 'EaseOut')
    $e = switch ($Kind) {
        'Back'  { New-Object Windows.Media.Animation.BackEase }
        'Sine'  { New-Object Windows.Media.Animation.SineEase }
        'Cubic' { New-Object Windows.Media.Animation.CubicEase }
        default { New-Object Windows.Media.Animation.QuadraticEase }
    }
    if ($Kind -eq 'Back') { $e.Amplitude = 0.45 }
    $e.EasingMode = $Mode
    return $e
}

function New-DAnim {
    param([double]$From, [double]$To, [double]$DurMs, [int]$Delay = 0, $Ease = $null)
    $a = New-Object Windows.Media.Animation.DoubleAnimation
    $a.From = $From
    $a.To = $To
    $a.Duration = Get-Dur $DurMs
    if ($Delay -gt 0) { $a.BeginTime = Get-Span $Delay }
    if ($Ease) { $a.EasingFunction = $Ease }
    return $a
}

function Start-FadeSlide {
    param($El, [int]$Delay = 0, [double]$Dy = 14, [double]$Dx = 0, [int]$Dur = 420)
    if (-not $El) { return }
    $key = $El.GetHashCode()
    if (-not $script:BaseOp.ContainsKey($key)) { $script:BaseOp[$key] = $(if ($El.Opacity -gt 0.05) { [double]$El.Opacity } else { 1.0 }) }
    $to = [double]$script:BaseOp[$key]
    $opacity = [Windows.UIElement]::OpacityProperty
    if (-not $script:AnimOn) {
        $El.BeginAnimation($opacity, $null)
        $El.Opacity = $to
        $El.RenderTransform = [Windows.Media.Transform]::Identity
        return
    }
    $tt = New-Object Windows.Media.TranslateTransform
    $tt.X = $Dx; $tt.Y = $Dy
    $El.RenderTransform = $tt
    $El.Opacity = 0
    $ease = New-Ease 'Quad' 'EaseOut'
    $El.BeginAnimation($opacity, (New-DAnim 0 $to $Dur $Delay $ease))
    if ($Dy -ne 0) { $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-DAnim $Dy 0 $Dur $Delay $ease)) }
    if ($Dx -ne 0) { $tt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, (New-DAnim $Dx 0 $Dur $Delay $ease)) }
}

function Start-Pop {
    param($El, [int]$Delay = 0, [double]$From = 0.6, [int]$Dur = 380)
    if (-not $El -or -not $script:AnimOn) { return }
    $El.RenderTransformOrigin = New-Object Windows.Point -ArgumentList 0.5, 0.5
    $st = New-Object Windows.Media.ScaleTransform
    $st.ScaleX = $From; $st.ScaleY = $From
    $El.RenderTransform = $st
    $ease = New-Ease 'Back' 'EaseOut'
    $st.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-DAnim $From 1 $Dur $Delay $ease))
    $st.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-DAnim $From 1 $Dur $Delay $ease))
}

function Start-Forever {
    param($Target, $Prop, [double]$From, [double]$To, [double]$Sec, [bool]$Reverse = $true, [string]$Kind = 'Sine', [int]$Delay = 0)
    if (-not $script:AnimOn -or -not $Target) { return }
    $a = New-DAnim $From $To ($Sec * 1000)
    $a.AutoReverse = $Reverse
    if ($Delay -gt 0) { $a.BeginTime = Get-Span $Delay }
    $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    if ($Reverse) { $a.EasingFunction = New-Ease $Kind 'EaseInOut' }
    $Target.BeginAnimation($Prop, $a)
}

function Stop-Anim {
    param($Target, $Prop)
    try { if ($Target) { $Target.BeginAnimation($Prop, $null) } } catch { }
}

function Start-Stagger {
    param($Panel, [int]$Max = 14, [int]$Step = 34, [int]$Base = 0, [double]$Dy = 12)
    if (-not $Panel) { return }
    $i = 0
    foreach ($ch in @($Panel.Children)) {
        if ($i -ge $Max) { break }
        Start-FadeSlide $ch ($Base + $i * $Step) $Dy 0 360
        $i++
    }
}

function Set-BarAnimated {
    param($Bar, [double]$Value)
    $old = $Bar.Value
    $Bar.Value = $Value
    if (-not $script:AnimOn -or [math]::Abs($old - $Value) -lt 0.5) { return }
    $a = New-DAnim $old $Value 650 0 (New-Ease 'Cubic' 'EaseOut')
    $a.FillBehavior = 'Stop'
    $Bar.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty, $a)
}

function Set-Spinner {
    param([bool]$On)
    $ui = $script:UI
    if (-not $ui.spin) { return }
    $prop = [Windows.Media.RotateTransform]::AngleProperty
    if ($On) {
        $ui.spin.Visibility = 'Visible'
        Start-Forever $ui.spinRot $prop 0 360 0.9 $false
    } else {
        Stop-Anim $ui.spinRot $prop
        $ui.spin.Visibility = 'Collapsed'
    }
}

function Add-CardHover {
    param($Card)
    $Card.BorderBrush = New-Object Windows.Media.SolidColorBrush -ArgumentList ([Windows.Media.ColorConverter]::ConvertFromString('#242A47'))
    $Card.Add_MouseEnter({
        param($s, $e)
        if ($script:AnimOn) {
            $ca = New-Object Windows.Media.Animation.ColorAnimation
            $ca.To = [Windows.Media.ColorConverter]::ConvertFromString('#3C3280'); $ca.Duration = Get-Dur 140
            $s.BorderBrush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $ca)
        }
    })
    $Card.Add_MouseLeave({
        param($s, $e)
        if ($script:AnimOn) {
            $ca = New-Object Windows.Media.Animation.ColorAnimation
            $ca.To = [Windows.Media.ColorConverter]::ConvertFromString('#242A47'); $ca.Duration = Get-Dur 240
            $s.BorderBrush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $ca)
        }
    })
}

function Update-ApplyGlow {
    $btn = $script:UI.btnOptApply
    if (-not $btn) { return }
    $n = $script:Sel.Count
    $label = if ($n -gt 0) { "Apply selected ($n)" } else { 'Apply selected' }
    if ($btn.Content -ne $label) { $btn.Content = $label; if ($n -gt 0) { Start-Pop $btn 0 0.94 220 } }
    if ($script:Sel.Count -gt 0 -and $script:AnimOn) {
        if (-not $btn.Effect) {
            $fx = New-Object Windows.Media.Effects.DropShadowEffect
            $fx.Color = [Windows.Media.ColorConverter]::ConvertFromString('#7C5CFF')
            $fx.ShadowDepth = 0; $fx.Opacity = 0.85; $fx.BlurRadius = 6
            $btn.Effect = $fx
            Start-Forever $fx ([Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty) 4 22 1.0 $true
        }
    } else { $btn.Effect = $null }
}

function Set-Ambient {
    # slow background pulses in the app shell
    $ui = $script:UI
    $blur = [Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty
    if ($script:AnimOn) {
        Start-Forever $ui.sideFx $blur 6 18 2.8 $true
        if (-not $ui.btnOptimizeAll.Effect) {
            $fx = New-Object Windows.Media.Effects.DropShadowEffect
            $fx.Color = [Windows.Media.ColorConverter]::ConvertFromString('#7C5CFF')
            $fx.ShadowDepth = 0; $fx.Opacity = 0.7; $fx.BlurRadius = 6
            $ui.btnOptimizeAll.Effect = $fx
            Start-Forever $fx $blur 6 26 1.7 $true
        }
    } else {
        Stop-Anim $ui.sideFx $blur
        $ui.btnOptimizeAll.Effect = $null
    }
}

function Start-Particles {
    $ui = $script:UI
    $c = $ui.particles
    $c.Children.Clear()
    if (-not $script:AnimOn) { return }
    $w = $ui.landing.ActualWidth; if ($w -lt 200) { $w = 1100 }
    $h = $ui.landing.ActualHeight; if ($h -lt 200) { $h = 720 }
    $rnd = New-Object System.Random
    for ($i = 0; $i -lt 16; $i++) {
        $size = 2 + $rnd.NextDouble() * 2.6
        $e = New-Object Windows.Shapes.Ellipse
        $e.Width = $size; $e.Height = $size
        $e.Fill = Get-Brush '#7C5CFF' (0.35 + $rnd.NextDouble() * 0.4)
        [Windows.Controls.Canvas]::SetLeft($e, $rnd.NextDouble() * $w)
        [Windows.Controls.Canvas]::SetTop($e, $h + 8)
        $tt = New-Object Windows.Media.TranslateTransform
        $e.RenderTransform = $tt
        $e.Opacity = 0
        [void]$c.Children.Add($e)
        $dur = 9 + $rnd.NextDouble() * 8
        $delay = [int]($rnd.NextDouble() * 7000)
        $ya = New-DAnim 0 (-($h * 0.9 + $rnd.NextDouble() * 120)) ($dur * 1000) $delay
        $ya.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $ya)
        $ka = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        $ka.Duration = Get-Dur ($dur * 1000)
        $ka.BeginTime = Get-Span $delay
        $ka.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        foreach ($kf in @(@(0, 0.0), @(0.8, 0.2), @(0.8, 0.7), @(0, 1.0))) {
            $frame = New-Object Windows.Media.Animation.LinearDoubleKeyFrame
            $frame.Value = [double]$kf[0]
            $frame.KeyTime = [Windows.Media.Animation.KeyTime]::FromPercent([double]$kf[1])
            [void]$ka.KeyFrames.Add($frame)
        }
        $e.BeginAnimation([Windows.UIElement]::OpacityProperty, $ka)
    }
}

function Stop-Particles {
    $c = $script:UI.particles
    foreach ($e in @($c.Children)) {
        try { $e.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null); $e.BeginAnimation([Windows.UIElement]::OpacityProperty, $null) } catch { }
    }
    $c.Children.Clear()
}

# ---- debloat page ---------------------------------------------------------------
$script:DbBuilt = $false
$script:DbCatalog = @()
$script:DbRows = @{}
$script:DbCtx = @{ Busy = $false; Seeded = $false }
$script:DbButtons = @('btnDbScan', 'btnDbSafe', 'btnDbAll', 'btnDbNone', 'btnDbRun')

function Update-DbCount {
    $n = 0
    foreach ($id in $script:DbRows.Keys) { $r = $script:DbRows[$id]; if ($r.Switch.IsChecked -and $r.Switch.IsEnabled) { $n++ } }
    $script:UI.txtDbCount.Text = "$n selected"
}

function Build-DebloatPage {
    $ui = $script:UI
    $script:DbCatalog = @(Get-DebloatCatalog)
    $ui.pnlDebloat.Children.Clear()
    $script:DbRows = @{}
    foreach ($cat in $script:DebloatCats.Keys) {
        $h = New-Tb ($script:DebloatCats[$cat].ToUpper()) 10.5 'Dim' $true
        $h.Margin = '2,14,0,8'
        [void]$ui.pnlDebloat.Children.Add($h)
        foreach ($d in @($script:DbCatalog | Where-Object { $_.Cat -eq $cat })) {
            $card = New-Object Windows.Controls.Border
            $card.Background = Get-Res 'Bg2'
            $card.BorderThickness = '1'
            $card.CornerRadius = New-Object Windows.CornerRadius -ArgumentList 10
            $card.Padding = '14,9'
            $card.Margin = '0,0,0,6'
            Add-CardHover $card
            $g = New-Object Windows.Controls.Grid
            foreach ($w in 'Auto', '*', 'Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$g.ColumnDefinitions.Add($cd) }
            $sw = New-Object Windows.Controls.CheckBox
            $sw.Style = Get-Res 'Switch'
            $sw.Tag = $d.Id
            $sw.VerticalAlignment = 'Center'
            $sw.Margin = '0,0,14,0'
            $sw.Add_Click({ Update-DbCount })
            [void]$g.Children.Add($sw)
            $mid = New-Object Windows.Controls.WrapPanel
            $mid.VerticalAlignment = 'Center'
            $nm = New-Tb $d.Name 13 'Text' $true
            $nm.TextWrapping = 'NoWrap'; $nm.Margin = '0,0,10,0'; $nm.VerticalAlignment = 'Center'
            [void]$mid.Children.Add($nm)
            if ($d.Safe) { [void]$mid.Children.Add((New-Chip 'Safe to remove' 'Good' 'Bg1')) } else { [void]$mid.Children.Add((New-Chip 'Optional' 'Warn' 'Bg1')) }
            [Windows.Controls.Grid]::SetColumn($mid, 1)
            [void]$g.Children.Add($mid)
            $st = New-Tb '' 11.5 'Dim' $true
            $st.TextWrapping = 'NoWrap'; $st.VerticalAlignment = 'Center'; $st.Margin = '12,0,0,0'
            [Windows.Controls.Grid]::SetColumn($st, 2)
            [void]$g.Children.Add($st)
            $card.Child = $g
            [void]$ui.pnlDebloat.Children.Add($card)
            $script:DbRows[$d.Id] = @{ Item = $d; Card = $card; Switch = $sw; Status = $st; Installed = $null }
        }
    }
    $script:DbBuilt = $true
    Update-DbCount
}

function Set-DbBusy {
    param([bool]$Busy)
    foreach ($b in $script:DbButtons) { $script:UI[$b].IsEnabled = -not $Busy }
    $script:DbCtx.Busy = $Busy
    $script:UI.navPanel.IsEnabled = -not $Busy
    Set-Spinner $Busy
}

function Start-DebloatScan {
    $ui = $script:UI
    if ($script:DbCtx.Busy) { return }
    Set-DbBusy $true
    $ui.txtDbStatus.Text = 'Scanning installed apps...'
    Invoke-Async -Work $script:DebloatScan -OnDone {
        param($res, $err)
        $ui = $script:UI
        Set-DbBusy $false
        if ($err) { $ui.txtDbStatus.Text = "Scan failed: $err"; Write-Log "Debloat scan failed: $err" 'err'; return }
        $names = @($res | ForEach-Object { $_ })
        $found = 0
        foreach ($id in $script:DbRows.Keys) {
            $r = $script:DbRows[$id]; $d = $r.Item; $has = $false
            if ($d.Special -eq 'onedrive') { $has = ($names -contains '__onedrive__') }
            else { foreach ($pat in $d.Patterns) { if (@($names | Where-Object { $_ -like $pat }).Count -gt 0) { $has = $true; break } } }
            $r.Installed = $has
            if ($has) {
                $found++
                $r.Status.Text = 'Installed'; $r.Status.Foreground = Get-Res 'Good'
                $r.Switch.IsEnabled = $true
            } else {
                $r.Status.Text = 'Not installed'; $r.Status.Foreground = Get-Res 'Dim'
                $r.Switch.IsChecked = $false; $r.Switch.IsEnabled = $false
            }
        }
        if (-not $script:DbCtx.Seeded) {
            $script:DbCtx.Seeded = $true
            foreach ($id in $script:DbRows.Keys) { $r = $script:DbRows[$id]; if ($r.Installed -and $r.Item.Safe) { $r.Switch.IsChecked = $true } }
        }
        $ui.txtDbStatus.Text = "$found removable app(s) found on this PC."
        Update-DbCount
        Write-Log "Debloat scan: $found removable app(s) installed." 'info'
    }
}

function Select-DbRows {
    param([string]$Mode)
    foreach ($id in $script:DbRows.Keys) {
        $r = $script:DbRows[$id]
        if (-not $r.Switch.IsEnabled) { continue }
        $r.Switch.IsChecked = switch ($Mode) { 'safe' { [bool]$r.Item.Safe } 'all' { $true } default { $false } }
    }
    Update-DbCount
}

function Start-DebloatRemove {
    $ui = $script:UI
    if ($script:DbCtx.Busy) { return }
    $sel = @($script:DbRows.Values | Where-Object { $_.Switch.IsChecked -and $_.Switch.IsEnabled -and $_.Installed -ne $false })
    if ($sel.Count -eq 0) { Write-Log 'Nothing selected to remove.' 'warn'; return }
    $msg = "Remove $($sel.Count) item(s) from this PC?"
    if (@($sel | Where-Object { $_.Item.Cat -eq 'xbox' }).Count -gt 0) { $msg += "`n`nYou ticked Xbox / Gaming Services items. Game Pass and some game launchers will stop working without them." }
    $ans = [Windows.MessageBox]::Show($msg, 'Rom-Opti', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return }
    Set-DbBusy $true
    try { Write-Log 'Creating a restore point...' 'info'; Invoke-UiPump; New-RestorePointAsync; Write-Log 'Restore point created.' 'ok' }
    catch { Write-Log "No restore point made: $($_.Exception.Message)" 'warn' }
    $items = @($sel | ForEach-Object { @{ Id = $_.Item.Id; Patterns = @($_.Item.Patterns); Special = $_.Item.Special } })
    $script:DbCtx.Count = $items.Count; $script:DbCtx.Done = 0; $script:DbCtx.Removed = 0; $script:DbCtx.Failed = 0
    $ui.barDb.Value = 0
    $ui.txtDbStatus.Text = 'Removing apps. This can take a few minutes...'
    Invoke-Async -Work $script:DebloatWork -ArgList @(, $items) -OnProgress {
        param($it)
        $ctx = $script:DbCtx
        $r = $script:DbRows[$it.Id]
        if ($it.Kind -eq 'start') { $r.Status.Text = 'Removing...'; $r.Status.Foreground = Get-Res 'Warn'; return }
        $ctx.Done++
        if ($it.Removed -gt 0) { $ctx.Removed++; $r.Status.Text = 'Removed'; $r.Status.Foreground = Get-Res 'Good'; $r.Installed = $false; Start-Pop $r.Status 0 0.7 300; Start-SlideOut $r.Card }
        elseif ($it.Err) { $ctx.Failed++; $r.Status.Text = 'Failed'; $r.Status.Foreground = Get-Res 'Bad'; $r.Status.ToolTip = [string]$it.Err }
        else { $r.Status.Text = 'Not found'; $r.Status.Foreground = Get-Res 'Dim'; $r.Installed = $false }
        $r.Switch.IsChecked = $false
        if ($it.Removed -gt 0) { $r.Switch.IsEnabled = $false }
        Set-BarAnimated $script:UI.barDb ([math]::Round(100 * $ctx.Done / [math]::Max(1, $ctx.Count)))
        $script:UI.txtDbStatus.Text = "Removing apps... $($ctx.Done) of $($ctx.Count)"
    } -OnDone {
        param($res, $err)
        $ctx = $script:DbCtx
        Set-DbBusy $false
        Update-DbCount
        if ($err) { $script:UI.txtDbStatus.Text = "Failed: $err"; Write-Log "Debloat failed: $err" 'err'; return }
        $script:UI.barDb.Value = 100
        $script:UI.txtDbStatus.Text = "Done. Removed $($ctx.Removed) item(s), $($ctx.Failed) failed."
        Write-Log "Debloat finished: $($ctx.Removed) removed, $($ctx.Failed) failed." $(if ($ctx.Failed -gt 0) { 'warn' } else { 'ok' })
        Show-Toast "Removed $($ctx.Removed) app(s)$(if ($ctx.Failed -gt 0) { ", $($ctx.Failed) failed" })" $(if ($ctx.Failed -gt 0) { 'warn' } else { 'ok' })
    }
}

# ---- startup page ---------------------------------------------------------------
$script:StItems = @()

function Build-StartupPage {
    $ui = $script:UI
    $ui.pnlStartup.Children.Clear()
    $script:StItems = @(Get-StartupItems)
    if ($script:StItems.Count -eq 0) {
        [void]$ui.pnlStartup.Children.Add((New-Tb 'No startup programs found. Nothing is launching at sign-in from the usual places.' 12.5 'Muted'))
        return
    }
    $i = 0
    foreach ($it in $script:StItems) {
        $card = New-Object Windows.Controls.Border
        $card.Background = Get-Res 'Bg2'
        $card.BorderThickness = '1'
        $card.CornerRadius = New-Object Windows.CornerRadius -ArgumentList 10
        $card.Padding = '14,10'
        $card.Margin = '0,0,0,6'
        Add-CardHover $card
        $g = New-Object Windows.Controls.Grid
        foreach ($w in 'Auto', '*') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$g.ColumnDefinitions.Add($cd) }
        $sw = New-Object Windows.Controls.CheckBox
        $sw.Style = Get-Res 'Switch'
        $sw.Tag = $i
        $sw.IsChecked = [bool]$it.Enabled
        $sw.VerticalAlignment = 'Center'
        $sw.Margin = '0,0,14,0'
        $sw.Add_Click({ param($s, $e) Invoke-Safe { Set-StartupItem ([int]$s.Tag) ([bool]$s.IsChecked) } 'Startup toggle'; Start-Flash $s.Parent.Parent })
        [void]$g.Children.Add($sw)
        $mid = New-Object Windows.Controls.StackPanel
        $head = New-Object Windows.Controls.WrapPanel
        $nm = New-Tb $it.Name 13 'Text' $true
        $nm.TextWrapping = 'NoWrap'; $nm.Margin = '0,0,10,0'; $nm.VerticalAlignment = 'Center'
        [void]$head.Children.Add($nm)
        [void]$head.Children.Add((New-Chip $it.Scope 'Dim' 'Bg1'))
        if (("$($it.Name) $($it.Command)") -match $script:StartupKeep) { [void]$head.Children.Add((New-Chip 'Likely needed' 'Warn' 'Bg1')) }
        [void]$mid.Children.Add($head)
        $cmd = New-Tb $it.Command 11 'Dim'
        $cmd.FontFamily = 'Consolas'; $cmd.TextTrimming = 'CharacterEllipsis'; $cmd.TextWrapping = 'NoWrap'; $cmd.Margin = '0,3,0,0'
        $cmd.ToolTip = $it.Command
        [void]$mid.Children.Add($cmd)
        [Windows.Controls.Grid]::SetColumn($mid, 1)
        [void]$g.Children.Add($mid)
        $card.Child = $g
        [void]$ui.pnlStartup.Children.Add($card)
        $i++
    }
}

function Set-StartupItem {
    param([int]$Index, [bool]$On)
    $it = $script:StItems[$Index]
    Set-StartupEnabled $it.Key $it.Name $On
    $it.Enabled = $On
    Write-Log ("Startup: {0} {1}." -f $it.Name, $(if ($On) { 'will launch at sign-in' } else { 'will no longer launch at sign-in' })) $(if ($On) { 'info' } else { 'accent' })
}
# ---- animation catalog -------------------------------------------------------------------------
# Every entry below is implemented in code. The Animations switch in the sidebar turns them all off.
$script:AnimCatalog = @(
    # landing page
    'Window fade-in', 'Window settle zoom', 'Background gradient drift', 'Glow breathing', 'Glow swell', 'Logo fade-in', 'Logo spring pop',
    'Ring rotation', 'Counter-rotating dotted ring', 'Orbiting dot (inner)', 'Orbiting dot (outer, reverse)', 'Logo glow pulse', 'Bolt flicker',
    'Tagline rise', 'Title letter cascade', 'Title letter hover lift', 'Title letter hover color flash', 'Subtitle rise', 'Subtitle underline grow',
    'Paragraph rise', 'Enter button fade-in', 'Enter button spring pop', 'Enter button light sweep', 'Enter button idle glow pulse',
    'Enter button arrow nudge', 'Enter button hover glow and grow', 'Chips staggered rise', 'Chips gentle bob', 'Footer fade-in',
    'Window controls fade-in', 'Floating particles', 'Bokeh drift', 'Parallax on mouse move', 'Click ripple', 'Landing exit fade', 'Landing exit zoom',
    # app shell
    'App slide-in', 'Nav staggered slide-in', 'Nav sliding highlight', 'Nav hover nudge', 'Nav icon pop', 'Sidebar logo spring pop',
    'Sidebar logo glow pulse', 'Animations switch fade-in', 'Page fade and slide', 'Page title rise', 'Page subtitle rise', 'Header accent bar grow',
    # dashboard
    'Dashboard cards staggered rise', 'Dashboard card hover lift', 'Applied count-up', 'Progress bar fill', 'Findings staggered rise',
    'Finding row hover glow', 'Warning dot pulse', 'Optimize-all button glow pulse', 'Change summary reveal', 'Change list stagger',
    # lists and controls
    'List stagger (optimize, debloat, startup, cleaner, internet)', 'Switch knob slide with overshoot', 'Switch track color fade', 'Button hover fade',
    'Button press squash', 'Card hover border glow', 'Status pill pop', 'Tier filter chip pop', 'Search box focus expand', 'Apply button glow pulse',
    'Apply count pop', 'Reboot banner drop-in', 'Reboot banner pulse', 'Busy spinner', 'Busy progress bar pulse', 'Cleaner result pop',
    'Removed app slide-out', 'Removed status pop', 'Startup toggle flash', 'Network result pop', 'Network test button pulse', 'TCP status pop',
    # feedback and chrome
    'Toast slide-in', 'Toast timer bar', 'Toast slide-out', 'Log row fade-in', 'Status text fade', 'Session dot pulse', 'Session ring ping',
    'Sidebar status title pop', 'Window drag dim', 'Window close fade', 'Window close shrink'
)

# ---- small helpers ---------------------------------------------------------------------------------
$script:EnterArrowT = $null
$script:Ready = $false
$script:Prepared = $false
$script:CloseNow = $false
$script:DeferFindings = $false
$script:FindingsBusy = $false
$script:ParLast = 0
$script:Ripples = New-Object System.Collections.Queue

function Get-Color { param([string]$Hex) return [Windows.Media.ColorConverter]::ConvertFromString($Hex) }

function Set-EnterContent {
    param([string]$Text, [bool]$Arrow = $true)
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = 14
    $tb.FontWeight = 'Bold'
    $tb.Foreground = Get-Brush '#0D0A1F'
    [void]$sp.Children.Add($tb)
    $script:EnterArrowT = $null
    if ($Arrow) {
        $ar = New-Object Windows.Controls.TextBlock
        $ar.Text = [string][char]0x2192
        $ar.FontSize = 15
        $ar.FontWeight = 'Bold'
        $ar.Foreground = Get-Brush '#0D0A1F'
        $ar.Margin = '12,0,0,0'
        $t = New-Object Windows.Media.TranslateTransform
        $ar.RenderTransform = $t
        $script:EnterArrowT = $t
        [void]$sp.Children.Add($ar)
        if ($script:AnimOn) { Start-Forever $t ([Windows.Media.TranslateTransform]::XProperty) 0 7 0.6 $true }
    }
    $script:UI.btnEnter.Content = $sp
}

function Set-LandingSys {
    $F = $script:Facts
    $dot = [string][char]0x00B7
    $script:UI.lnSys.Text = ("{0}   {1}   {2} GB RAM   {1}   v{3}" -f $F.CpuName, $dot, $F.RamGB, $script:Version)
}

function Move-NavHighlight {
    param($Item, [switch]$Instant)
    $ui = $script:UI
    if (-not $Item -or -not $ui.navHi) { return }
    try {
        $ui.navPanel.UpdateLayout()
        $pt = $Item.TransformToAncestor($ui.navPanel).Transform((New-Object Windows.Point -ArgumentList 0, 0))
        $ui.navHi.Visibility = 'Visible'
        $ui.navHi.Height = [double]$Item.ActualHeight
        $y = [Windows.Media.TranslateTransform]::YProperty
        if ($script:AnimOn -and -not $Instant) { $ui.navHiT.BeginAnimation($y, (New-DAnim $ui.navHiT.Y $pt.Y 300 0 (New-Ease 'Back' 'EaseOut'))) }
        else { $ui.navHiT.BeginAnimation($y, $null); $ui.navHiT.Y = $pt.Y }
    } catch { }
}

function Set-HeaderBar {
    $b = $script:UI.hdrBar
    if (-not $b) { return }
    $w = [Windows.FrameworkElement]::WidthProperty
    if ($script:AnimOn) { $b.BeginAnimation($w, (New-DAnim 0 44 420 80 (New-Ease 'Cubic' 'EaseOut'))) }
    else { $b.BeginAnimation($w, $null); $b.Width = 44 }
}

function Set-SessionRing {
    param([bool]$On)
    $ui = $script:UI
    if (-not $ui.sideRing) { return }
    $sx = [Windows.Media.ScaleTransform]::ScaleXProperty; $sy = [Windows.Media.ScaleTransform]::ScaleYProperty; $op = [Windows.UIElement]::OpacityProperty
    if ($On -and $script:AnimOn) {
        Start-Forever $ui.sideRingS $sx 1 3.4 1.5 $false
        Start-Forever $ui.sideRingS $sy 1 3.4 1.5 $false
        Start-Forever $ui.sideRing $op 0.9 0 1.5 $false
    } else {
        Stop-Anim $ui.sideRingS $sx; Stop-Anim $ui.sideRingS $sy; Stop-Anim $ui.sideRing $op
        $ui.sideRing.Opacity = 0
    }
}

function Add-CardLift {
    param($El)
    if (-not $El) { return }
    $El.Add_MouseEnter({ param($s, $e)
        if (-not $script:AnimOn) { return }
        if ($s.RenderTransform -isnot [Windows.Media.TranslateTransform]) { $s.RenderTransform = New-Object Windows.Media.TranslateTransform }
        $s.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-DAnim $s.RenderTransform.Y -3 150 0 (New-Ease)))
    })
    $El.Add_MouseLeave({ param($s, $e)
        if (-not $script:AnimOn) { return }
        if ($s.RenderTransform -is [Windows.Media.TranslateTransform]) { $s.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-DAnim $s.RenderTransform.Y 0 220 0 (New-Ease))) }
    })
}

function Start-Flash {
    param($Card)
    if (-not $Card -or -not $script:AnimOn -or $Card.BorderBrush -isnot [Windows.Media.SolidColorBrush]) { return }
    $ca = New-Object Windows.Media.Animation.ColorAnimation
    $ca.To = Get-Color '#7C5CFF'; $ca.Duration = Get-Dur 200; $ca.AutoReverse = $true
    try { $Card.BorderBrush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $ca) } catch { }
}

function Start-SlideOut {
    param($El)
    if (-not $El) { return }
    if (-not $script:AnimOn) { return }
    $tt = New-Object Windows.Media.TranslateTransform
    $El.RenderTransform = $tt
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, (New-DAnim 0 36 280 0 (New-Ease 'Quad' 'EaseIn')))
    $El.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-DAnim 1 0.4 280))
}

# ---- toast notifications ----------------------------------------------------------------------------
$script:ToastTimer = $null

function Hide-Toast {
    $ui = $script:UI
    if (-not $ui.toast) { return }
    if ($script:AnimOn) {
        $a = New-DAnim $ui.toastT.X 440 260 0 (New-Ease 'Quad' 'EaseIn')
        $a.Add_Completed({ $script:UI.toast.Visibility = 'Collapsed' })
        $ui.toastT.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $a)
    } else { $ui.toast.Visibility = 'Collapsed' }
}

function Show-Toast {
    param([string]$Text, [string]$Kind = 'ok')
    $ui = $script:UI
    if (-not $ui.toast) { return }
    $hex = switch ($Kind) { 'ok' { '#2ED3A0' } 'err' { '#FF5C7A' } 'warn' { '#FFB547' } default { '#7C5CFF' } }
    $ui.toast.BorderBrush = Get-Brush $hex
    $ui.toastBar.Fill = Get-Brush $hex
    $ui.toastText.Text = $Text
    $ui.toast.Visibility = 'Visible'
    $x = [Windows.Media.TranslateTransform]::XProperty
    if ($script:AnimOn) {
        $ui.toastT.BeginAnimation($x, (New-DAnim 440 0 380 0 (New-Ease 'Back' 'EaseOut')))
        $ui.toastBar.BeginAnimation([Windows.FrameworkElement]::WidthProperty, (New-DAnim 240 0 3400 300))
    } else {
        $ui.toastT.BeginAnimation($x, $null); $ui.toastT.X = 0
        $ui.toastBar.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $null); $ui.toastBar.Width = 240
    }
    if ($script:ToastTimer) { $script:ToastTimer.Stop() }
    $script:ToastTimer = New-Object Windows.Threading.DispatcherTimer
    $script:ToastTimer.Interval = [TimeSpan]::FromMilliseconds(3800)
    $script:ToastTimer.Add_Tick({ $script:ToastTimer.Stop(); Hide-Toast })
    $script:ToastTimer.Start()
}

# ---- landing extras ----------------------------------------------------------------------------------
function Start-Bokeh {
    $ui = $script:UI
    $c = $ui.bokeh
    $c.Children.Clear()
    if (-not $script:AnimOn) { return }
    $w = $ui.landing.ActualWidth; if ($w -lt 200) { $w = 1100 }
    $h = $ui.landing.ActualHeight; if ($h -lt 200) { $h = 720 }
    $rnd = New-Object System.Random
    for ($i = 0; $i -lt 6; $i++) {
        $size = 130 + $rnd.NextDouble() * 130
        $e = New-Object Windows.Shapes.Ellipse
        $e.Width = $size; $e.Height = $size
        $rg = New-Object Windows.Media.RadialGradientBrush
        [void]$rg.GradientStops.Add((New-Object Windows.Media.GradientStop -ArgumentList (Get-Color '#267C5CFF'), 0.0))
        [void]$rg.GradientStops.Add((New-Object Windows.Media.GradientStop -ArgumentList (Get-Color '#007C5CFF'), 1.0))
        $e.Fill = $rg
        [Windows.Controls.Canvas]::SetLeft($e, $rnd.NextDouble() * $w)
        [Windows.Controls.Canvas]::SetTop($e, $rnd.NextDouble() * $h)
        $tt = New-Object Windows.Media.TranslateTransform
        $e.RenderTransform = $tt
        [void]$c.Children.Add($e)
        Start-Forever $tt ([Windows.Media.TranslateTransform]::XProperty) (-30 - $rnd.NextDouble() * 50) (30 + $rnd.NextDouble() * 50) (9 + $rnd.NextDouble() * 8) $true 'Sine' ([int]($rnd.NextDouble() * 2000))
        Start-Forever $tt ([Windows.Media.TranslateTransform]::YProperty) (-24 - $rnd.NextDouble() * 40) (24 + $rnd.NextDouble() * 40) (11 + $rnd.NextDouble() * 8) $true 'Sine' ([int]($rnd.NextDouble() * 2000))
        Start-Forever $e ([Windows.UIElement]::OpacityProperty) 0.35 1 (5 + $rnd.NextDouble() * 4) $true 'Sine'
    }
}

function Start-Ripple {
    param($Pos)
    if (-not $script:AnimOn) { return }
    $c = $script:UI.particles
    $e = New-Object Windows.Shapes.Ellipse
    $e.Width = 40; $e.Height = 40
    $e.Stroke = Get-Brush '#7C5CFF'
    $e.StrokeThickness = 1.5
    $e.Opacity = 0.7
    $e.IsHitTestVisible = $false
    $e.RenderTransformOrigin = New-Object Windows.Point -ArgumentList 0.5, 0.5
    [Windows.Controls.Canvas]::SetLeft($e, $Pos.X - 20)
    [Windows.Controls.Canvas]::SetTop($e, $Pos.Y - 20)
    $st = New-Object Windows.Media.ScaleTransform
    $st.ScaleX = 0.2; $st.ScaleY = 0.2
    $e.RenderTransform = $st
    [void]$c.Children.Add($e)
    $ease = New-Ease 'Cubic' 'EaseOut'
    $st.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-DAnim 0.2 4 750 0 $ease))
    $st.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-DAnim 0.2 4 750 0 $ease))
    $e.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-DAnim 0.7 0 750))
    $script:Ripples.Enqueue($e)
    while ($script:Ripples.Count -gt 6) { $old = $script:Ripples.Dequeue(); $c.Children.Remove($old) }
}

function Invoke-Parallax {
    param($Pos)
    if (-not $script:AnimOn) { return }
    $now = [Environment]::TickCount
    if (($now - $script:ParLast) -lt 40) { return }
    $script:ParLast = $now
    $ui = $script:UI
    $w = [math]::Max(1.0, $ui.landing.ActualWidth); $h = [math]::Max(1.0, $ui.landing.ActualHeight)
    $nx = ($Pos.X / $w) - 0.5; $ny = ($Pos.Y / $h) - 0.5
    $xp = [Windows.Media.TranslateTransform]::XProperty; $yp = [Windows.Media.TranslateTransform]::YProperty
    $ui.parBokeh.BeginAnimation($xp, (New-DAnim $ui.parBokeh.X (-$nx * 36) 280))
    $ui.parBokeh.BeginAnimation($yp, (New-DAnim $ui.parBokeh.Y (-$ny * 26) 280))
    $ui.parPart.BeginAnimation($xp, (New-DAnim $ui.parPart.X (-$nx * 16) 280))
    $ui.parPart.BeginAnimation($yp, (New-DAnim $ui.parPart.Y (-$ny * 12) 280))
}

function Start-LandingAmbient {
    $ui = $script:UI
    if (-not $script:AnimOn) { $ui.lnUnder.Width = 120; return }
    $ang = [Windows.Media.RotateTransform]::AngleProperty
    Start-Forever $ui.orbit1Rot $ang 0 360 6 $false
    Start-Forever $ui.orbit2Rot $ang 360 0 9.5 $false
    Start-Forever $ui.ring2Rot $ang 360 0 34 $false
    # the bolt flickers every few seconds
    $ka = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $ka.Duration = Get-Dur 5200
    $ka.BeginTime = Get-Span 3000
    $ka.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    foreach ($kf in @(@(1, 0), @(1, 0.7), @(0.3, 0.75), @(1, 0.81), @(0.6, 0.88), @(1, 0.95), @(1, 1))) {
        $f = New-Object Windows.Media.Animation.LinearDoubleKeyFrame
        $f.Value = [double]$kf[0]
        $f.KeyTime = [Windows.Media.Animation.KeyTime]::FromPercent([double]$kf[1])
        [void]$ka.KeyFrames.Add($f)
    }
    $ui.logoBolt.BeginAnimation([Windows.UIElement]::OpacityProperty, $ka)
    # the enter button breathes
    $fx = New-Object Windows.Media.Effects.DropShadowEffect
    $fx.Color = Get-Color '#7C5CFF'; $fx.ShadowDepth = 0; $fx.Opacity = 0.55; $fx.BlurRadius = 8
    $ui.btnEnter.Effect = $fx
    Start-Forever $fx ([Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty) 8 36 1.8 $true
    # chips bob gently, out of step with each other
    $i = 0
    foreach ($chip in @($ui.chipA, $ui.chipB, $ui.chipC)) {
        if ($chip.RenderTransform -is [Windows.Media.TranslateTransform]) { Start-Forever $chip.RenderTransform ([Windows.Media.TranslateTransform]::YProperty) 0 -4 (2.2 + $i * 0.35) $true 'Sine' 2700 }
        $i++
    }
    $ui.lnUnder.BeginAnimation([Windows.FrameworkElement]::WidthProperty, (New-DAnim 0 120 700 1550 (New-Ease 'Cubic' 'EaseOut')))
    Start-Bokeh
}

# ---- X3D pinning (dual-CCD V-Cache chips) --------------------------------------------------------------
function Set-VCacheAffinity {
    param($Proc)
    $F = $script:Facts
    if (-not $F.DualCcdX3D -or $F.Threads -lt 4) { return }
    $half = [int]($F.Threads / 2)
    $mask = [int64]([math]::Pow(2, $half) - 1)
    try {
        if ([int64]$Proc.ProcessorAffinity -ne $mask) {
            $Proc.ProcessorAffinity = [IntPtr]$mask
            $script:Session.PinnedPid = $Proc.Id
            Write-Log ("{0} pinned to the first CCD ({1} logical cores, the V-Cache side)." -f $Proc.ProcessName, $half) 'ok'
        }
    } catch { Write-Log "Could not pin the game: $($_.Exception.Message)" 'warn' }
}

function Reset-GameAffinity {
    $F = $script:Facts
    if (-not $script:Session.PinnedPid) { return }
    try {
        $p = Get-Process -Id $script:Session.PinnedPid -ErrorAction Stop
        $all = [int64]([math]::Pow(2, [math]::Min(62, [int]$F.Threads)) - 1)
        $p.ProcessorAffinity = [IntPtr]$all
    } catch { }
    $script:Session.PinnedPid = $null
}

# ---- non-blocking startup --------------------------------------------------------------------------------
function Start-Prepare {
    # The window is already on screen. The hardware scan runs in a worker so nothing freezes.
    $ui = $script:UI
    Set-EnterContent 'Preparing...' $false
    $ui.btnEnter.IsEnabled = $false
    $work = "function Find-RustClient {`n" + (Get-Item -LiteralPath 'function:Find-RustClient').ScriptBlock.ToString() + "`n}`nfunction Get-SystemFacts {`n" + (Get-Item -LiteralPath 'function:Get-SystemFacts').ScriptBlock.ToString() + "`n}`nGet-SystemFacts"
    Invoke-Async -Work ([scriptblock]::Create($work)) -OnDone {
        param($res, $err)
        $f = $null
        try { $f = @($res)[0]; if ($f -is [System.Management.Automation.PSObject]) { $f = $f.BaseObject } } catch { }
        if ($f -isnot [hashtable]) {
            try { $f = Get-SystemFacts } catch { $f = @{ Build = [Environment]::OSVersion.Version.Build; Win11 = $false; OsName = 'Windows'; RamGB = 0; CpuName = 'Unknown CPU'; Cores = 0; Threads = 0; X3D = $false; DualCcdX3D = $false; Gpus = @(); Laptop = $false; RustExe = $null; RustHdd = $false } }
        }
        $script:Facts = $f
        try { Restore-OrphanedSession } catch { }
        Import-Journal
        $script:Tweaks = Get-TweakCatalog
        $script:Ready = $true
        Set-LandingSys
        Set-EnterContent 'ENTER OPTIMIZER' $true
        $script:UI.btnEnter.IsEnabled = $true
        if ($script:Facts.DualCcdX3D) { $script:UI.sesPin.Visibility = 'Visible' }
        Write-Log "Rom-Opti $($script:Version) ready on $($script:Facts.OsName)." 'accent'
    }
}

function Start-CloseAnim {
    $ui = $script:UI
    $a = New-DAnim 1 0 220 0 (New-Ease 'Quad' 'EaseIn')
    $a.Add_Completed({ $script:UI.Win.Close() })
    $fs = New-Object Windows.Media.ScaleTransform
    $ui.frame.RenderTransformOrigin = New-Object Windows.Point -ArgumentList 0.5, 0.5
    $ui.frame.RenderTransform = $fs
    $fs.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-DAnim 1 0.97 220))
    $fs.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-DAnim 1 0.97 220))
    $ui.Win.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
}

function Invoke-WindowDrag {
    $w = $script:UI.Win
    $op = [Windows.UIElement]::OpacityProperty
    if ($script:AnimOn) { $w.BeginAnimation($op, (New-DAnim $w.Opacity 0.92 120)) }
    try { $w.DragMove() } catch { }
    if ($script:AnimOn) {
        $a = New-DAnim 0.92 1 220
        $a.FillBehavior = 'Stop'
        $w.Opacity = 1
        $w.BeginAnimation($op, $a)
    } else { $w.Opacity = 1 }
}
# ---- settings (persisted between launches) ------------------------------------------------
$script:SettingsFile = Join-Path $script:AppDir 'settings.json'

function Get-Settings {
    $d = @{ Anim = $true }
    try {
        if (Test-Path -LiteralPath $script:SettingsFile) {
            $j = ConvertFrom-Json (Get-Content -LiteralPath $script:SettingsFile -Raw)
            if ($null -ne $j.Anim) { $d.Anim = [bool]$j.Anim }
        }
    } catch { }
    return $d
}

function Save-Settings {
    try { Write-TextFile $script:SettingsFile (ConvertTo-Json -InputObject @{ Anim = [bool]$script:AnimOn }) } catch { }
}

# ---- safety tiers ------------------------------------------------------------------------------
# Safe      applied by "Optimize my PC"
# Test      helps some PCs and hurts others, always opt-in, measure it
# Advanced  real security or stability tradeoff, always opt-in
# Optional  preferences and situational tweaks
$script:SecurityIds = @('rust_defender', 'adv_vbs', 'sch_hyper', 'sch_mitig')
$script:TestTierIds = @('sch_hags', 'gpu_fsegl', 'gpu_fso', 'gpu_mpo', 'sch_memcomp', 'sch_tick', 'gpu_tdr', 'net_lat')

function Get-TweakTier {
    param($T)
    if ($T.Group -eq 'Adv') { return 'Advanced' }
    if ($script:TestTierIds -contains $T.Id) { return 'Test' }
    $rec = $false
    try { $rec = Test-TweakRecommended $T } catch { }
    if ($rec) { return 'Safe' }
    return 'Optional'
}

function Get-TierBrush {
    param([string]$Tier)
    switch ($Tier) { 'Safe' { return 'Good' } 'Test' { return 'Warn' } 'Advanced' { return 'Bad' } default { return 'Dim' } }
}

$script:OptFilter = 'All'
$script:OptSearch = ''

function Update-OptFilter {
    $ui = $script:UI
    $hdr = $null; $cnt = 0
    $q = $script:OptSearch
    foreach ($ch in @($ui.pnlTweaks.Children)) {
        if ($ch.Tag -eq 'hdr') {
            if ($hdr) { $hdr.Visibility = $(if ($cnt -gt 0) { 'Visible' } else { 'Collapsed' }) }
            $hdr = $ch; $cnt = 0; continue
        }
        $c = $script:Cards[[string]$ch.Tag]
        if (-not $c) { continue }
        $show = ($script:OptFilter -eq 'All' -or $c.Tier -eq $script:OptFilter)
        if ($show -and $q) { $show = ((($c.Tweak.Name + ' ' + $c.Tweak.Desc).IndexOf($q, [StringComparison]::OrdinalIgnoreCase)) -ge 0) }
        $ch.Visibility = $(if ($show) { 'Visible' } else { 'Collapsed' })
        if ($show) { $cnt++ }
    }
    if ($hdr) { $hdr.Visibility = $(if ($cnt -gt 0) { 'Visible' } else { 'Collapsed' }) }
}

function Update-FilterCounts {
    $ui = $script:UI
    $n = @{ Safe = 0; Test = 0; Advanced = 0; Optional = 0 }
    foreach ($c in $script:Cards.Values) { $n[$c.Tier]++ }
    $ui.fAll.Content = "All ($($script:Cards.Count))"
    $ui.fSafe.Content = "Safe ($($n.Safe))"
    $ui.fTest.Content = "Test it ($($n.Test))"
    $ui.fAdv.Content = "Advanced ($($n.Advanced))"
    $ui.fOpt.Content = "Optional ($($n.Optional))"
}

# ---- one-click optimize + what changed ---------------------------------------------------------------
$script:LastRun = @{ Apply = $true; Ok = @(); Fail = @() }

function Show-ChangeSummary {
    param([int]$Already, [int]$Available, [int]$Skipped)
    $ui = $script:UI
    $ok = @($script:LastRun.Ok); $fail = @($script:LastRun.Fail)
    $tick = [string][char]0x2713; $dot = [string][char]0x2022
    $ui.dChanges.Visibility = 'Visible'
    $ui.dChangesTitle.Text = if ($ok.Count -gt 0) { "$($ok.Count) change(s) applied" } else { 'Nothing needed changing' }
    $parts = @("$Already already optimal", "$Available optional tweak(s) available (Test it, Advanced, Optional)")
    if ($Skipped -gt 0) { $parts += "$Skipped recommended tweak(s) skipped because they do not fit this PC" }
    if ($fail.Count -gt 0) { $parts += "$($fail.Count) failed, see the Activity log" }
    $ui.dChangesSub.Text = ($parts -join "   $dot   ")
    $ui.pnlChanges.Children.Clear()
    foreach ($grp in $script:Groups) {
        $mine = @($ok | Where-Object { $_.Group -eq $grp.Key })
        if ($mine.Count -eq 0) { continue }
        $h = New-Tb $grp.Title 11 'Dim' $true
        $h.Margin = '0,8,0,3'
        [void]$ui.pnlChanges.Children.Add($h)
        foreach ($t in $mine) { [void]$ui.pnlChanges.Children.Add((New-Tb ("$tick  " + $t.Name) 12.5 'Text')) }
    }
    foreach ($t in $fail) { [void]$ui.pnlChanges.Children.Add((New-Tb ("!  " + $t.Name + " (failed)") 12.5 'Bad')) }
    Start-FadeSlide $ui.dChanges 0 12 0 360
    Show-Toast $ui.dChangesTitle.Text $(if ($fail.Count -gt 0) { 'warn' } else { 'ok' })
    Start-Stagger $ui.pnlChanges 24 24 120 6
}

function Invoke-OptimizeAll {
    foreach ($c in $script:Cards.Values) { $c.Switch.IsChecked = $false }
    $n = 0; $already = 0; $skipped = 0; $available = 0
    foreach ($id in $script:Cards.Keys) {
        $c = $script:Cards[$id]
        $rec = $false
        try { $rec = Test-TweakRecommended $c.Tweak } catch { }
        if ($c.Blocked) { if ($rec) { $skipped++ }; continue }
        if ($c.Tier -eq 'Safe') {
            if ($c.Applied) { $already++ } else { $c.Switch.IsChecked = $true; $n++ }
        } elseif (-not $c.Applied) { $available++ }
    }
    if ($n -eq 0) {
        Write-Log 'Optimize my PC: every safe tweak for this PC is already applied.' 'ok'
        $script:LastRun = @{ Apply = $true; Ok = @(); Fail = @() }
    } else {
        Write-Log "Optimize my PC: applying $n safe tweak(s)..." 'accent'
        Invoke-OptRun $true
    }
    Show-ChangeSummary $already $available $skipped
}

# ---- internet page -------------------------------------------------------------------------------------
$script:NetBusy = $false

function Set-Tb {
    param($Tb, [string]$Text, [string]$Brush = 'Text')
    $Tb.Text = $Text
    $Tb.Foreground = Get-Res $Brush
}

function Update-NetPage {
    $ui = $script:UI
    $info = Get-NetPrimaryBg
    if ($info) {
        Set-Tb $ui.nAdapter $info.Desc
        Set-Tb $ui.nType $info.Type
        Set-Tb $ui.nSpeed $info.Speed
        Set-Tb $ui.nIp $info.Ip
        Set-Tb $ui.nGw $info.Gateway
        Set-Tb $ui.nDnsSrv $(if (@($info.Dns).Count -gt 0) { @($info.Dns) -join ', ' } else { 'Automatic' })
        Set-Tb $ui.nMtu "$($info.Mtu)"
    } else {
        foreach ($n in 'nAdapter', 'nType', 'nSpeed', 'nIp', 'nGw', 'nDnsSrv', 'nMtu') { Set-Tb $ui[$n] 'No active connection' 'Dim' }
    }
    try {
        $s = Get-TcpStateBg
        Set-Tb $ui.tAuto $s.AutoTuning; Set-Tb $ui.tHeur $s.Heuristics; Set-Tb $ui.tEcn $s.Ecn
        Set-Tb $ui.tTs $s.Timestamps; Set-Tb $ui.tRss $s.Rss; Set-Tb $ui.tRsc $s.Rsc
        $ui.txtTcpStatus.Text = $(if (Get-NetBaseline) { 'Baseline saved. Windows default restores your original settings.' } else { 'No baseline yet. It is saved automatically right before the first change.' })
    } catch {
        foreach ($n in 'tAuto', 'tHeur', 'tEcn', 'tTs', 'tRss', 'tRsc') { Set-Tb $ui[$n] 'Not available' 'Dim' }
        $ui.txtTcpStatus.Text = 'TCP settings could not be read on this system.'
    }
}

function Set-NetBusy {
    param([bool]$Busy)
    $script:NetBusy = $Busy
    foreach ($b in 'btnNetTest', 'btnTcpGaming', 'btnTcpThroughput', 'btnTcpDefault', 'btnMtu', 'btnDns') { $script:UI[$b].IsEnabled = -not $Busy }
    $script:UI.navPanel.IsEnabled = -not $Busy
    Set-Spinner $Busy
}

function Set-Latency {
    param($Tb, $Stats, [int]$Good = 30, [int]$Warn = 80)
    if ($Stats.Lost -ge $Stats.Sent) { Set-Tb $Tb 'No reply (the device may block ping)' 'Warn'; return }
    $brush = if ($Stats.Avg -le $Good) { 'Good' } elseif ($Stats.Avg -le $Warn) { 'Warn' } else { 'Bad' }
    Set-Tb $Tb ("{0} ms average  ({1} to {2} ms)" -f $Stats.Avg, $Stats.Min, $Stats.Max) $brush
}

function Start-NetTest {
    if ($script:NetBusy) { return }
    $ui = $script:UI
    Set-NetBusy $true
    Start-Forever $ui.btnNetTest ([Windows.UIElement]::OpacityProperty) 1 0.55 0.5 $true
    try {
        $info = Get-NetPrimaryBg
        if (-not $info) { Set-Tb $ui.hGw 'No active connection' 'Warn'; return }
        foreach ($n in 'hGw', 'hWan', 'hLoss', 'hJit', 'hDns') { Set-Tb $ui[$n] 'testing...' 'Dim' }
        Invoke-UiPump
        $g = Test-PingStats $info.Gateway 12 1000 -Pump
        Set-Latency $ui.hGw $g 5 20
        $w = Test-PingStats '1.1.1.1' 12 1000 -Pump
        Set-Latency $ui.hWan $w 30 80
        $loss = [math]::Round(100.0 * $w.Lost / [math]::Max(1, $w.Sent), 1)
        Set-Tb $ui.hLoss "$loss%" $(if ($loss -eq 0) { 'Good' } elseif ($loss -lt 3) { 'Warn' } else { 'Bad' })
        Set-Tb $ui.hJit "$($w.Jitter) ms" $(if ($w.Jitter -le 3) { 'Good' } elseif ($w.Jitter -le 10) { 'Warn' } else { 'Bad' })
        $ms = @(Invoke-Blocking -Script { $sw = [System.Diagnostics.Stopwatch]::StartNew(); try { [void](Resolve-DnsName -Name 'www.google.com' -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop); [math]::Round($sw.Elapsed.TotalMilliseconds, 0) } catch { -1 } })[0]
        if ($ms -lt 0) { Set-Tb $ui.hDns 'Lookup failed' 'Bad' } else { Set-Tb $ui.hDns "$ms ms" $(if ($ms -le 60) { 'Good' } elseif ($ms -le 200) { 'Warn' } else { 'Bad' }) }
        Write-Log ("Network test: router {0} ms, internet {1} ms, loss {2}%, jitter {3} ms." -f $g.Avg, $w.Avg, $loss, $w.Jitter) 'info'
        foreach ($n in 'hGw', 'hWan', 'hLoss', 'hJit', 'hDns') { Start-Pop $ui[$n] 0 0.92 260 }
    } finally { Stop-Anim $ui.btnNetTest ([Windows.UIElement]::OpacityProperty); $ui.btnNetTest.Opacity = 1; Set-NetBusy $false }
}

function Start-TcpProfile {
    param([string]$Profile)
    if ($script:NetBusy) { return }
    $ui = $script:UI
    Set-NetBusy $true
    try {
        $ui.txtTcpStatus.Text = 'Applying and re-testing your connection...'
        Invoke-UiPump
        $r = Invoke-TcpProfile $Profile ([bool]$ui.swNetRollback.IsChecked) -Pump
        if ($r.Changes.Count -eq 0) {
            $ui.txtTcpStatus.Text = 'Already set that way. Nothing changed.'
            $ui.txtTcpStatus.Foreground = Get-Res 'Muted'
        } elseif ($r.RolledBack) {
            $ui.txtTcpStatus.Text = ("Connectivity got worse after the change (loss {0}/{1} vs {2}/{3} before), so it was rolled back automatically." -f $r.Post.Lost, $r.Post.Sent, $r.Pre.Lost, $r.Pre.Sent)
            $ui.txtTcpStatus.Foreground = Get-Res 'Warn'
            Write-Log 'TCP profile rolled back: connectivity test got worse.' 'warn'
            Show-Toast 'Rolled back: connection got worse' 'warn'
        } else {
            $ui.txtTcpStatus.Text = 'Applied: ' + ($r.Changes -join '; ')
            $ui.txtTcpStatus.Foreground = Get-Res 'Good'
            foreach ($c in $r.Changes) { Write-Log "TCP: $c" 'ok' }
            Show-Toast 'TCP profile applied' 'ok'
        }
        Start-Pop $ui.txtTcpStatus 0 0.96 300
    } catch {
        $ui.txtTcpStatus.Text = "Failed: $($_.Exception.Message)"
        $ui.txtTcpStatus.Foreground = Get-Res 'Bad'
        Write-Log "TCP profile failed: $($_.Exception.Message)" 'err'
    } finally {
        Set-NetBusy $false
        Update-NetPage
    }
}

function Start-MtuTest {
    if ($script:NetBusy) { return }
    $ui = $script:UI
    Set-NetBusy $true
    try {
        $ui.txtMtu.Text = 'Testing...'; Invoke-UiPump
        $m = Find-PathMtu '1.1.1.1' -Pump
        $info = Get-NetPrimaryBg
        if (-not $m) { Set-Tb $ui.txtMtu 'Could not test. The path blocks ping or you are offline.' 'Warn'; return }
        $cur = if ($info) { $info.Mtu } else { 0 }
        if ($m -ge 1500 -or $m -ge $cur) { Set-Tb $ui.txtMtu "Detected path MTU: $m. No change recommended." 'Good' }
        else { Set-Tb $ui.txtMtu "Detected path MTU: $m (adapter is set to $cur). This usually means PPPoE or a tunnel. Windows normally adapts on its own, so only change it if you see fragmentation problems." 'Warn' }
        Write-Log "MTU detected: $m." 'info'
    } finally { Set-NetBusy $false }
}

function Start-DnsTest {
    if ($script:NetBusy) { return }
    $ui = $script:UI
    Set-NetBusy $true
    try {
        $ui.txtDns.Text = 'Testing...'; Invoke-UiPump
        $info = Get-NetPrimaryBg
        $servers = @()
        if ($info -and @($info.Dns).Count -gt 0) { $servers += $info.Dns[0] } elseif ($info) { $servers += $info.Gateway }
        $servers += '1.1.1.1', '8.8.8.8', '9.9.9.9'
        $rows = @(Invoke-Blocking -Functions 'Test-DnsServers' -ArgList @(,$servers) -Script { param($s) Test-DnsServers $s })
        $lines = foreach ($r in $rows) {
            $label = if ($info -and $r.Server -eq $servers[0]) { "$($r.Server) (yours)" } else { $r.Server }
            $val = if ($r.Avg -lt 0) { 'failed' } else { "$($r.Avg) ms" }
            if ($r.Failed -gt 0 -and $r.Avg -ge 0) { $val += "  ($($r.Failed) lookup(s) failed)" }
            ('{0,-24}{1}' -f $label, $val)
        }
        $ui.txtDns.Text = ($lines -join "`n")
        Write-Log 'DNS test finished.' 'info'
    } finally { Set-NetBusy $false }
}

# ---- restore and profiles ---------------------------------------------------------------------------------
function Invoke-RevertAll {
    $ui = $script:UI
    $ans = [Windows.MessageBox]::Show('Undo every tweak this app applied and restore your original values?', 'Rom-Opti', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    $ids = @($script:Journal.Keys)
    $ok = 0; $fail = 0; $explorer = $false
    foreach ($id in $ids) {
        $t = @($script:Tweaks | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
        if (-not $t) { Write-Log "Journal entry '$id' is not in this version's catalog, skipped." 'warn'; continue }
        try { Invoke-TweakUndo $t; $ok++; if ($t.Explorer) { $explorer = $true }; Write-Log "Reverted: $($t.Name)" 'accent' }
        catch { $fail++; Write-Log "FAILED to revert $($t.Name): $($_.Exception.Message)" 'err' }
        Invoke-UiPump
    }
    try { $b = Get-NetBaseline; if ($b) { Set-TcpStateBg $b; Write-Log 'TCP settings restored to your baseline.' 'accent' } } catch { Write-Log "TCP restore failed: $($_.Exception.Message)" 'err' }
    if ($explorer) { Restart-ExplorerShell }
    Update-AllCards
    $ui.txtRestoreStatus.Text = "Reverted $ok tweak(s), $fail failed."
    $ui.txtRestoreStatus.Foreground = Get-Res $(if ($fail -gt 0) { 'Warn' } else { 'Good' })
}

function Invoke-ExportProfile {
    $dir = [Environment]::GetFolderPath('Desktop')
    $path = Join-Path $dir ("RomOpti-Profile-{0}.json" -f (Get-Date -Format 'yyyy-MM-dd'))
    Export-OptProfile $path
    $script:UI.txtRestoreStatus.Text = "Profile saved to $path"
    $script:UI.txtRestoreStatus.Foreground = Get-Res 'Good'
    Write-Log "Profile exported to $path" 'ok'
    Show-Toast 'Profile saved to your desktop' 'ok'
}

function Invoke-ImportProfile {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Rom-Opti profile (*.json)|*.json'
    if (-not $dlg.ShowDialog()) { return }
    $ids = @(Import-OptProfile $dlg.FileName)
    $n = 0
    foreach ($c in $script:Cards.Values) { $c.Switch.IsChecked = $false }
    foreach ($id in $ids) {
        $c = $script:Cards[[string]$id]
        if ($c -and -not $c.Blocked -and -not $c.Applied) { $c.Switch.IsChecked = $true; $n++ }
    }
    Write-Log "Profile loaded: $n tweak(s) selected for review." 'ok'
    $script:UI.navOpt.IsChecked = $true
}

# ---- events for the new pages ------------------------------------------------------------------------------
function Register-ExtraEvents {
    $ui = $script:UI
    $ui.btnOptimizeAll.Add_Click({ Invoke-Safe { Invoke-OptimizeAll } 'Optimize my PC' })

    $filters = @{ fAll = 'All'; fSafe = 'Safe'; fTest = 'Test'; fAdv = 'Advanced'; fOpt = 'Optional' }
    foreach ($n in $filters.Keys) {
        $ui[$n].Tag = $filters[$n]
        $ui[$n].Add_Checked({ param($s, $e) $script:OptFilter = [string]$s.Tag; Start-Pop $s 0 0.85 260; Update-OptFilter })
    }
    $ui.txtSearch.Add_GotKeyboardFocus({ if ($script:AnimOn) { $script:UI.txtSearch.BeginAnimation([Windows.FrameworkElement]::WidthProperty, (New-DAnim $script:UI.txtSearch.ActualWidth 300 220 0 (New-Ease 'Cubic' 'EaseOut'))) } })
    $ui.txtSearch.Add_LostKeyboardFocus({ if ($script:AnimOn) { $script:UI.txtSearch.BeginAnimation([Windows.FrameworkElement]::WidthProperty, (New-DAnim $script:UI.txtSearch.ActualWidth 210 240 0 (New-Ease 'Cubic' 'EaseOut'))) } })
    foreach ($n in 'dCard1', 'dCard2', 'dCard3', 'dOptCard') { Add-CardLift $ui[$n] }
    $ui.txtSearch.Add_TextChanged({ $script:OptSearch = $script:UI.txtSearch.Text.Trim(); Update-OptFilter })

    $ui.btnNetTest.Add_Click({ Invoke-Safe { Start-NetTest } 'Network test' })
    $ui.btnMtu.Add_Click({ Invoke-Safe { Start-MtuTest } 'MTU test' })
    $ui.btnDns.Add_Click({ Invoke-Safe { Start-DnsTest } 'DNS test' })
    $ui.btnTcpGaming.Add_Click({ Invoke-Safe { Start-TcpProfile 'gaming' } 'TCP profile' })
    $ui.btnTcpThroughput.Add_Click({ Invoke-Safe { Start-TcpProfile 'throughput' } 'TCP profile' })
    $ui.btnTcpDefault.Add_Click({ Invoke-Safe { Start-TcpProfile 'default' } 'TCP restore' })

    $ui.btnRevertAll.Add_Click({ Invoke-Safe { Invoke-RevertAll } 'Revert all' })
    $ui.btnNetRestore.Add_Click({ Invoke-Safe { Start-TcpProfile 'default'; $script:UI.txtRestoreStatus.Text = 'Network settings restored to your baseline.' } 'Network restore' })
    $ui.btnExport.Add_Click({ Invoke-Safe { Invoke-ExportProfile } 'Export' })
    $ui.btnImport.Add_Click({ Invoke-Safe { Invoke-ImportProfile } 'Import' })

    $ui.swMotion.IsChecked = [bool]$script:AnimOn
    $ui.swMotion.Add_Click({ Save-Settings })
}
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
    $script:UI.navPanel.IsEnabled = -not $Busy
    Set-Spinner $Busy
}

# ---- pages --------------------------------------------------------------------
$script:PageMeta = [ordered]@{
    dash    = @{ Title = 'Dashboard';     Sub = 'Your PC at a glance, and what is really holding back your FPS.' }
    opt     = @{ Title = 'Optimize';      Sub = 'Toggle what you want, then apply. Everything is journaled and reversible.' }
    rust    = @{ Title = 'Rust';          Sub = 'Launch options and graphics config tuned for RustClient.' }
    session = @{ Title = 'Game session';  Sub = 'Boosts that run only while you play, then undo themselves.' }
    internet = @{ Title = 'Internet';     Sub = 'Measure your connection and apply safe, reversible TCP profiles.' }
    restore = @{ Title = 'Restore & profiles'; Sub = 'Undo everything, or export and import your setup.' }
    debloat = @{ Title = 'Debloat';       Sub = 'Remove preinstalled apps and promos for every user on this PC.' }
    startup = @{ Title = 'Startup';       Sub = 'Control which programs launch at sign-in.' }
    clean   = @{ Title = 'Cleaner';       Sub = 'Free disk space. Nothing is deleted until you confirm.' }
    log     = @{ Title = 'Activity log';  Sub = 'Everything this app has done on this PC.' }
}
$script:PageCtl = @{ dash = 'pgDash'; opt = 'pgOpt'; internet = 'pgInternet'; restore = 'pgRestore'; debloat = 'pgDebloat'; startup = 'pgStartup'; rust = 'pgRust'; session = 'pgSession'; clean = 'pgClean'; log = 'pgLog' }

function Start-PageIn {
    param([string]$Key)
    $ui = $script:UI
    $el = $ui[$script:PageCtl[$Key]]
    Start-FadeSlide $el 0 12 0 260
    Start-FadeSlide $ui.pageTitle 0 8 0 300
    Start-FadeSlide $ui.pageSub 70 6 0 300
    Set-HeaderBar
    switch ($Key) {
        'dash' {
            $i = 0
            foreach ($n in 'dCard1', 'dCard2', 'dCard3') { Start-FadeSlide $ui[$n] (60 + $i * 90) 18 0 420; $i++ }
            Start-Stagger $ui.pnlFindings 10 45 300 12
            Update-DashStats -Animate
        }
        'opt'     { Start-Stagger $ui.pnlTweaks 14 28 40 10 }
        'debloat' { Start-Stagger $ui.pnlDebloat 14 28 40 10 }
        'startup' { Start-Stagger $ui.pnlStartup 12 30 40 10 }
        'internet' { Start-Stagger $ui.pnlInternet 6 80 40 14 }
        'restore' { Start-Stagger $ui.pgRestore.Content 3 90 40 14 }
        'clean'   { Start-Stagger $ui.pnlClean 10 34 40 10 }
        'rust'    { Start-Stagger $ui.pgRust.Content 3 90 40 14 }
        'session' { Start-Stagger $ui.pgSession.Content 2 100 40 14 }
    }
}

function Show-Page {
    param([string]$Key, [switch]$NoAnim)
    $ui = $script:UI
    foreach ($k in $script:PageCtl.Keys) { $ui[$script:PageCtl[$k]].Visibility = 'Collapsed' }
    $ui[$script:PageCtl[$Key]].Visibility = 'Visible'
    $ui.pageTitle.Text = $script:PageMeta[$Key].Title
    $ui.pageSub.Text   = $script:PageMeta[$Key].Sub
    switch ($Key) {
        'dash'    { Update-Dashboard -KeepFindings }
        'opt'     { Update-AllCards }
        'internet' { Update-NetPage }
        'debloat' { if (-not $script:DbBuilt) { Build-DebloatPage; Start-DebloatScan } }
        'startup' { Build-StartupPage }
        'rust'    { Update-Launch }
        'session' { Update-SessionUi }
        'clean'   { if (-not $script:CleanBuilt) { Build-CleanPage } }
    }
    if (-not $NoAnim) { Start-PageIn $Key }
}

# ---- dashboard ----------------------------------------------------------------
function Update-Side {
    $ui = $script:UI
    if ($script:Session.Active) {
        $ui.sideDot.Fill = Get-Res 'Good'
        Start-Forever $ui.sideDot ([Windows.UIElement]::OpacityProperty) 1 0.3 0.9 $true
        Set-SessionRing $true
        if ($ui.sideTitle.Text -ne 'Session active') { Start-Pop $ui.sideTitle 0 0.9 260 }
        $ui.sideTitle.Text = 'Session active'
        $bits = @()
        if ($script:Session.Timer) { $bits += 'timer held' }
        if (@($script:Session.Stopped).Count -gt 0) { $bits += "$(@($script:Session.Stopped).Count) services paused" }
        if ($script:Session.Prio) { $bits += 'Rust priority' }
        if ($script:Session.Purge) { $bits += 'memory cleaner' }
        $ui.sideSub.Text = ($bits -join ', ')
    } else {
        $ui.sideDot.Fill = Get-Res 'Dim'
        Stop-Anim $ui.sideDot ([Windows.UIElement]::OpacityProperty)
        $ui.sideDot.Opacity = 1
        Set-SessionRing $false
        if ($ui.sideTitle.Text -ne 'No active session') { Start-Pop $ui.sideTitle 0 0.9 260 }
        $ui.sideTitle.Text = 'No active session'
        $n = $script:Journal.Count
        $ui.sideSub.Text = if ($n -gt 0) { "$n tweak(s) applied by this app" } else { 'No tweaks applied yet' }
    }
}

function Update-DashStats {
    param([switch]$Animate)
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
    $pct = if ($total -gt 0) { [math]::Round(100 * $done / $total) } else { 0 }
    $ui.dTotal.Text = "/ $total"
    $ui.dApplied.Text = "$done"
    if ($Animate -and $script:AnimOn) {
        $ui.dApplied.Text = '0'
        $ui.countProxy.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty, (New-DAnim 0 $done 750 180 (New-Ease 'Cubic' 'EaseOut')))
        $ui.dBar.Value = 0
        Set-BarAnimated $ui.dBar $pct
    } else { $ui.dBar.Value = $pct }
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
    if ($script:DeferFindings -or $script:FindingsBusy) { return }
    $script:FindingsBusy = $true
    $ui.pnlFindings.Children.Clear()
    [void]$ui.pnlFindings.Children.Add((New-Tb 'Scanning this PC...' 12.5 'Muted'))
    Invoke-UiPump
    $items = @()
    try { $items = @(Invoke-Blocking -Functions 'Get-Findings', 'Format-Bytes', 'Get-ActivePlan', 'Invoke-NativeOut' -ArgList @($script:Facts, $script:NativeOk) -Script { param($f, $n) Get-Findings -F $f -NativeOk $n }) } catch { Write-Log "Scan failed: $($_.Exception.Message)" 'err' }
    $script:FindingsBusy = $false
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
        Add-CardHover $row
        $g = New-Object Windows.Controls.Grid
        $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = 'Auto'
        $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = '*'
        [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1)
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 9; $dot.Height = 9; $dot.Margin = '0,5,14,0'; $dot.VerticalAlignment = 'Top'
        $dot.Fill = switch ($f.Level) { 'warn' { Get-Res 'Accent' } 'ok' { Get-Res 'Good' } default { Get-Res 'Dim' } }
        if ($f.Level -eq 'warn') { Start-Forever $dot ([Windows.UIElement]::OpacityProperty) 1 0.35 0.9 $true }
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
    Start-Stagger $ui.pnlFindings 12 40 0 10
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
    $card.Tag = $T.Id
    $card.Padding = '14,12'
    $card.Margin = '0,0,0,8'
    Add-CardHover $card

    $g = New-Object Windows.Controls.Grid
    foreach ($w in 'Auto', '*', 'Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$g.ColumnDefinitions.Add($cd) }

    $sw = New-Object Windows.Controls.CheckBox
    $sw.Style = Get-Res 'Switch'
    $sw.Tag = $T.Id
    $sw.VerticalAlignment = 'Top'
    $sw.Margin = '0,2,16,0'
    $sw.Add_Checked({ param($s, $e) [void]$script:Sel.Add([string]$s.Tag); Update-ApplyGlow })
    $sw.Add_Unchecked({ param($s, $e) [void]$script:Sel.Remove([string]$s.Tag); Update-ApplyGlow })
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
    $tier = Get-TweakTier $T
    [void]$head.Children.Add((New-Chip $tier (Get-TierBrush $tier) 'Bg1'))
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
    $script:Cards[$T.Id] = @{ Tweak = $T; Card = $card; Switch = $sw; Pill = $pill; PillText = $pt; Blocked = [bool]$blocked; Applied = $false; Tier = $tier }
    return $card
}

function Update-Card {
    param([string]$Id)
    $c = $script:Cards[$Id]
    if (-not $c) { return }
    if ($c.Blocked) { $c.PillText.Text = 'Unavailable'; $c.Pill.Background = Get-Res 'Bg1'; $c.PillText.Foreground = Get-Res 'Dim'; return }
    $on = $false
    try { $on = Test-TweakApplied $c.Tweak } catch { }
    $changed = ($c.Seen -and ($c.Applied -ne $on))
    $c.Applied = $on
    $c.Seen = $true
    if ($changed) { Start-Pop $c.Pill 0 0.6 360 }
    if ($on) { $c.PillText.Text = 'Applied'; $c.Pill.Background = [Windows.Media.Brushes]::Transparent; $c.PillText.Foreground = Get-Res 'Good'; $c.Pill.BorderBrush = Get-Res 'Good'; $c.Pill.BorderThickness = '1' }
    else     { $c.PillText.Text = 'Off'; $c.Pill.Background = Get-Res 'Bg1'; $c.PillText.Foreground = Get-Res 'Dim'; $c.Pill.BorderThickness = '0' }
}

function Update-AllCards {
    foreach ($id in @($script:Cards.Keys)) { Update-Card $id; Invoke-UiPump }
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
        $h.Tag = 'hdr'
        [void]$ui.pnlTweaks.Children.Add($h)
        foreach ($t in $mine) {
            [void]$ui.pnlTweaks.Children.Add((New-TweakCard $t))
            $script:BuildN = [int]$script:BuildN + 1
            if ($script:UI.landing.Visibility -eq 'Visible') { Set-EnterContent ("Scanning tweaks {0}/{1}" -f $script:BuildN, @($script:Tweaks).Count) $false }
            Invoke-UiPump
        }
    }
    $script:OptBuilt = $true
    Update-AllCards
    Update-FilterCounts
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
    if ($Apply) {
        $risky = @($sel | Where-Object { $script:SecurityIds -contains $_.Id })
        if ($risky.Count -gt 0) {
            $names = ($risky | ForEach-Object { '  - ' + $_.Name }) -join "`n"
            $ans = [Windows.MessageBox]::Show("These changes weaken a Windows security protection or exclude files from scanning:`n`n$names`n`nThey can be undone from this app. Apply them anyway?", 'Rom-Opti security confirmation', 'YesNo', 'Warning')
            if ($ans -ne 'Yes') { Write-Log 'Security-related tweaks were not applied.' 'warn'; return }
        }
    }
    $btns = @('btnOptApply', 'btnOptRevert', 'btnOptClear', 'btnOptRec')
    Set-Busy $true $btns
    $needExplorer = $false; $reboot = @(); $ok = 0; $fail = 0
    $script:LastRun = @{ Apply = $Apply; Ok = @(); Fail = @() }
    try {
        if ($Apply -and $ui.chkRestore.IsChecked) {
            Write-Log 'Creating a restore point...' 'info'; Invoke-UiPump
            try { New-RestorePointAsync; Write-Log 'Restore point created.' 'ok' }
            catch { Write-Log "No restore point made: $($_.Exception.Message)" 'warn' }
        }
        foreach ($t in $sel) {
            try {
                if ($Apply) { Invoke-TweakApply $t; Write-Log "Applied: $($t.Name)" 'ok' }
                else        { Invoke-TweakUndo $t;  Write-Log "Reverted: $($t.Name)" 'accent' }
                $ok++
                $script:LastRun.Ok += $t
                if ($t.Explorer) { $needExplorer = $true }
                if ($t.Reboot)   { $reboot += $t.Name }
                $script:Cards[$t.Id].Switch.IsChecked = $false
            } catch {
                $fail++
                $script:LastRun.Fail += $t
                Write-Log "FAILED: $($t.Name) - $($_.Exception.Message)" 'err'
            }
            Update-Card $t.Id
            Invoke-UiPump
        }
        if ($needExplorer) { Restart-ExplorerShell }
        if ($reboot.Count -gt 0) {
            $ui.bannerRebootText.Text = 'Restart Windows to finish: ' + ($reboot -join ', ') + '.'
            $ui.bannerReboot.Visibility = 'Visible'
            Start-FadeSlide $ui.bannerReboot 0 -12 0 320
            Start-Forever $ui.bannerReboot ([Windows.UIElement]::OpacityProperty) 1 0.65 1.1 $true 'Sine' 600
        }
        Write-Log ("{0} done: {1} succeeded, {2} failed." -f $(if ($Apply) { 'Apply' } else { 'Revert' }), $ok, $fail) $(if ($fail -gt 0) { 'warn' } else { 'ok' })
        Show-Toast ("{0} {1} tweak(s){2}" -f $(if ($Apply) { 'Applied' } else { 'Reverted' }), $ok, $(if ($fail -gt 0) { ", $fail failed" } else { '' })) $(if ($fail -gt 0) { 'warn' } else { 'ok' })
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
    return @{ Timer = [bool]$ui.sesTimer.IsChecked; Purge = [bool]$ui.sesPurge.IsChecked; Priority = [bool]$ui.sesPrio.IsChecked; Services = [bool]$ui.sesSvc.IsChecked; Pin = ([bool]$ui.sesPin.IsChecked -and [bool]$script:Facts.DualCcdX3D) }
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
    foreach ($n in 'sesTimer', 'sesPurge', 'sesPrio', 'sesPin', 'sesSvc') { $ui[$n].IsEnabled = -not $script:Session.Active }
    Update-Side
}

function Invoke-SessionTick {
    $rust = $null
    $gname = ([string]$script:UI.txtGameExe.Text).Trim() -replace '\.exe$', ''
    if (-not $gname) { $gname = 'RustClient' }
    try { $rust = Get-Process -Name $gname -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { }
    $auto = [bool]$script:UI.sesAuto.IsChecked
    if ($auto -and -not $script:Session.Active -and $rust) {
        $script:SessAutoStarted = $true; $script:RustGone = 0
        Write-Log 'Game started, beginning session.' 'accent'
        Start-GameSession (Get-SessionOptions); Update-SessionUi
    }
    elseif ($script:Session.Active -and $script:SessAutoStarted -and -not $rust) {
        $script:RustGone = [int]$script:RustGone + 1
        if ($script:RustGone -ge 2) { $script:SessAutoStarted = $false; Write-Log 'Game closed, ending session.' 'accent'; Stop-GameSession; Update-SessionUi }
    }
    if ($script:Session.Active) {
        if ($script:Session.Prio -and $rust) {
            try { if ($rust.PriorityClass -notin 'AboveNormal', 'High', 'RealTime') { $rust.PriorityClass = 'AboveNormal'; Write-Log "$($rust.ProcessName) priority set to Above Normal." 'ok' } }
            catch { Write-Log "Could not change Rust priority: $($_.Exception.Message)" 'warn' }
        }
        if ($script:Session.Pin -and $rust) { Set-VCacheAffinity $rust }
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
        $card.Padding = '14,10'; $card.Margin = '0,0,0,8'; Add-CardHover $card
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
        $ans = [Windows.MessageBox]::Show('This permanently deletes the ticked items. Continue?', 'Rom-Opti', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }
    }
    $script:CleanCtx = @{ Busy = $true; Done = 0; Count = $tasks.Count; Delete = $Delete; Freed = 0.0 }
    foreach ($b in 'btnScan', 'btnCleanRun', 'btnCleanRec', 'btnCleanNone') { $ui[$b].IsEnabled = $false }
    $ui.barClean.Value = 0
    Set-Spinner $true
    Start-Forever $ui.barClean ([Windows.UIElement]::OpacityProperty) 1 0.55 0.8 $true
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
                Start-Pop $script:CleanLbl[$it.Id] 0 0.85 240
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
        Set-Spinner $false
        Stop-Anim $ui.barClean ([Windows.UIElement]::OpacityProperty); $ui.barClean.Opacity = 1
        if ($err) { $ui.txtCleanStatus.Text = "Failed: $err"; Write-Log "Cleaner failed: $err" 'err'; return }
        if ($ctx.Delete) {
            $ui.txtCleanStatus.Text = 'Cleanup finished.'
            $ui.txtCleanTotal.Text = 'Freed ' + (Format-Bytes $ctx.Freed)
            Write-Log ("Cleaner freed {0}." -f (Format-Bytes $ctx.Freed)) 'ok'
            Show-Toast ("Freed {0}" -f (Format-Bytes $ctx.Freed)) 'ok'
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

function Start-AppEntrance {
    $ui = $script:UI
    Start-FadeSlide $ui.app 0 0 20 420
    $i = 0
    foreach ($n in @($ui.navPanel.Children)) { Start-FadeSlide $n (140 + $i * 55) 0 -18 380; $i++ }
    Start-Pop $ui.sideLogo 120 0.5 450
    Start-FadeSlide $ui.swMotion 520 0 0 320
    Move-NavHighlight $ui.navDash -Instant
    Set-Ambient
    Start-PageIn 'dash'
    $script:DeferFindings = $false
    $script:FindingsDone = $false
    Invoke-Safe { Update-Dashboard } 'Dashboard scan'
}

function Enter-App {
    $ui = $script:UI
    if (-not $script:Ready) { return }
    $ui.btnEnter.IsEnabled = $false
    Set-EnterContent 'Scanning your PC...' $false
    Invoke-UiPump
    $script:DeferFindings = $true
    $script:BuildN = 0
    try {
        Build-OptPage
        Build-KillList
        Build-CleanPage
        Update-Dashboard
    } catch { Write-Log "Startup scan hit a problem: $($_.Exception.Message)" 'warn' }
    Show-Page 'dash' -NoAnim
    if (-not $script:AnimOn) {
        Stop-Particles
        $ui.landing.Visibility = 'Collapsed'; $ui.app.Visibility = 'Visible'; $ui.app.Opacity = 1
        Start-PageIn 'dash'
        $script:DeferFindings = $false; $script:FindingsDone = $false
        Invoke-Safe { Update-Dashboard } 'Dashboard scan'
        return
    }
    $ui.hero.RenderTransformOrigin = New-Object Windows.Point -ArgumentList 0.5, 0.5
    $zoom = New-Object Windows.Media.ScaleTransform
    $ui.hero.RenderTransform = $zoom
    $zoom.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-DAnim 1 1.06 300 0 (New-Ease 'Quad' 'EaseIn')))
    $zoom.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-DAnim 1 1.06 300 0 (New-Ease 'Quad' 'EaseIn')))
    $fade = New-DAnim 1 0 300 0 (New-Ease 'Quad' 'EaseIn')
    $fade.Add_Completed({
        Stop-Particles
        $script:UI.landing.Visibility = 'Collapsed'
        $script:UI.app.Visibility = 'Visible'
        Start-AppEntrance
    })
    $ui.landing.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
}

function Start-LandingAnimations {
    $ui = $script:UI
    $letters = @($ui.lnTitle.Children)
    if (-not $script:AnimOn) {
        $ui.Win.Opacity = 1
        $ui.logoScale.ScaleX = 1; $ui.logoScale.ScaleY = 1; $ui.lnUnder.Width = 120
        foreach ($el in @($ui.logoWrap, $ui.lnTag, $ui.lnSub, $ui.lnLine, $ui.btnEnter, $ui.chipA, $ui.chipB, $ui.chipC, $ui.lnSys, $ui.lnChrome) + $letters) { Start-FadeSlide $el 0 0 0 1 }
        return
    }
    $op = [Windows.UIElement]::OpacityProperty
    $out = New-Ease 'Quad' 'EaseOut'
    # window open: fade + settle
    $wa = New-DAnim 0 1 450 0 $out
    $wa.FillBehavior = 'Stop'
    $wa.Add_Completed({ $script:UI.Win.Opacity = 1 })
    $ui.Win.BeginAnimation($op, $wa)
    $ui.frame.RenderTransformOrigin = New-Object Windows.Point -ArgumentList 0.5, 0.5
    $fs = New-Object Windows.Media.ScaleTransform
    $fs.ScaleX = 0.965; $fs.ScaleY = 0.965
    $ui.frame.RenderTransform = $fs
    $fs.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-DAnim 0.965 1 560 0 (New-Ease 'Cubic' 'EaseOut')))
    $fs.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-DAnim 0.965 1 560 0 (New-Ease 'Cubic' 'EaseOut')))
    # background gradient drifts slowly
    foreach ($prop in @([Windows.Media.RadialGradientBrush]::CenterProperty, [Windows.Media.RadialGradientBrush]::GradientOriginProperty)) {
        $pa = New-Object Windows.Media.Animation.PointAnimation
        $pa.From = New-Object Windows.Point -ArgumentList 0.44, 0.42
        $pa.To = New-Object Windows.Point -ArgumentList 0.56, 0.5
        $pa.Duration = Get-Dur 7000; $pa.AutoReverse = $true
        $pa.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $pa.EasingFunction = New-Ease 'Sine' 'EaseInOut'
        $ui.bgGrad.BeginAnimation($prop, $pa)
    }
    # glow breathes and swells
    Start-Forever $ui.glow $op 0.35 0.95 3.6 $true
    Start-Forever $ui.glowScale ([Windows.Media.ScaleTransform]::ScaleXProperty) 0.92 1.08 5.0 $true
    Start-Forever $ui.glowScale ([Windows.Media.ScaleTransform]::ScaleYProperty) 0.92 1.08 5.0 $true
    # logo mark: pop in, ring spins, glow pulses
    Start-FadeSlide $ui.logoWrap 150 0 0 600
    $ui.logoScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-DAnim 0.5 1 760 150 (New-Ease 'Back' 'EaseOut')))
    $ui.logoScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-DAnim 0.5 1 760 150 (New-Ease 'Back' 'EaseOut')))
    Start-Forever $ui.ringRot ([Windows.Media.RotateTransform]::AngleProperty) 0 360 20 $false
    Start-Forever $ui.logoFx ([Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty) 16 42 2.4 $true
    # text cascade
    Start-FadeSlide $ui.lnTag 480 10 0 520
    $i = 0
    foreach ($l in $letters) { Start-FadeSlide $l (640 + $i * 70) 24 0 560; $i++ }
    Start-FadeSlide $ui.lnSub 1300 12 0 520
    Start-FadeSlide $ui.lnLine 1500 10 0 560
    # enter button: fade, pop, then a light sweep across it
    Start-FadeSlide $ui.btnEnter 1750 0 0 500
    Start-Pop $ui.btnEnter 1750 0.86 560
    try {
        $ui.btnEnter.ApplyTemplate()
        $hl = $ui.btnEnter.Template.FindName('hlStop', $ui.btnEnter)
        if ($hl) {
            $ka = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
            $ka.Duration = Get-Dur 3600
            $ka.BeginTime = Get-Span 2600
            $ka.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            foreach ($kf in @(@(0, 0), @(1, 1300), @(1, 3600))) {
                $f = New-Object Windows.Media.Animation.LinearDoubleKeyFrame
                $f.Value = [double]$kf[0]
                $f.KeyTime = [Windows.Media.Animation.KeyTime]::FromTimeSpan((Get-Span $kf[1]))
                [void]$ka.KeyFrames.Add($f)
            }
            $hl.BeginAnimation([Windows.Media.GradientStop]::OffsetProperty, $ka)
        }
    } catch { }
    # chips, footer, window buttons
    Start-FadeSlide $ui.chipA 2000 12 0 420
    Start-FadeSlide $ui.chipB 2100 12 0 420
    Start-FadeSlide $ui.chipC 2200 12 0 420
    Start-FadeSlide $ui.lnSys 2500 0 0 600
    Start-FadeSlide $ui.lnChrome 600 0 0 500
    Start-Particles
    Start-LandingAmbient
}

function Register-Events {
    $ui = $script:UI
    $win = $ui.Win

    # landing text
    $ui.lnTag.Text   = Space-Text 'MEASURE  -  TUNE  -  VERIFY'
    foreach ($ch in 'ROM-OPTI'.ToCharArray()) {
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = [string]$ch
        $tb.FontFamily = 'Bahnschrift, Segoe UI Semibold'
        $tb.FontSize = 64
        $tb.FontWeight = 'SemiBold'
        $tb.Foreground = New-Object Windows.Media.SolidColorBrush -ArgumentList (Get-Color '#ECEFFA')
        $tb.Background = [Windows.Media.Brushes]::Transparent
        $tb.Margin = '0,0,5,0'
        $tb.Opacity = 0
        $tb.Add_MouseEnter({ param($s, $e)
            if (-not $script:AnimOn) { return }
            if ($s.RenderTransform -is [Windows.Media.TranslateTransform]) { $s.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-DAnim $s.RenderTransform.Y -10 150 0 (New-Ease))) }
            $ca = New-Object Windows.Media.Animation.ColorAnimation
            $ca.To = Get-Color '#A28BFF'; $ca.Duration = Get-Dur 150
            $s.Foreground.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $ca)
        })
        $tb.Add_MouseLeave({ param($s, $e)
            if (-not $script:AnimOn) { return }
            if ($s.RenderTransform -is [Windows.Media.TranslateTransform]) { $s.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-DAnim $s.RenderTransform.Y 0 240 0 (New-Ease))) }
            $ca = New-Object Windows.Media.Animation.ColorAnimation
            $ca.To = Get-Color '#ECEFFA'; $ca.Duration = Get-Dur 260
            $s.Foreground.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $ca)
        })
        [void]$ui.lnTitle.Children.Add($tb)
    }
    $ui.lnSub.Text   = Space-Text 'PERFORMANCE TUNER'
    Set-EnterContent 'Preparing...' $false
    $ui.btnEnter.IsEnabled = $false

    # window chrome and dragging
    $ui.landing.Add_MouseLeftButtonDown({ param($s, $e) if ($e.ChangedButton -eq 'Left') { Start-Ripple ($e.GetPosition($script:UI.landing)); Invoke-WindowDrag } })
    $ui.landing.Add_MouseMove({ param($s, $e) Invoke-Parallax ($e.GetPosition($script:UI.landing)) })
    $ui.header.Add_MouseLeftButtonDown({ param($s, $e) if ($e.ChangedButton -eq 'Left') { Invoke-WindowDrag } })
    $ui.lnMin.Add_Click({ $script:UI.Win.WindowState = 'Minimized' })
    $ui.appMin.Add_Click({ $script:UI.Win.WindowState = 'Minimized' })
    $ui.lnClose.Add_Click({ $script:UI.Win.Close() })
    $ui.appClose.Add_Click({ $script:UI.Win.Close() })
    $ui.btnEnter.Add_Click({ Invoke-Safe { Enter-App } 'Enter' })

    # navigation
    $navs = @{ navDash = 'dash'; navOpt = 'opt'; navInternet = 'internet'; navRestore = 'restore'; navDebloat = 'debloat'; navStartup = 'startup'; navRust = 'rust'; navSession = 'session'; navClean = 'clean'; navLog = 'log' }
    foreach ($n in $navs.Keys) {
        $ui[$n].Tag = $navs[$n]
        $ui[$n].Add_Checked({ param($s, $e) Move-NavHighlight $s; Start-Pop $s.Content.Children[0] 0 0.6 300; Invoke-Safe { Show-Page ([string]$s.Tag) } 'Navigation' })
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
            $ans = [Windows.MessageBox]::Show('Close the ticked apps now? Unsaved work in them will be lost.', 'Rom-Opti', 'YesNo', 'Warning')
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

    # animations switch and count-up proxy
    $ui.countProxy.Add_ValueChanged({ $script:UI.dApplied.Text = [string][int][math]::Round($script:UI.countProxy.Value) })
    $ui.swMotion.Add_Click({
        $script:AnimOn = [bool]$script:UI.swMotion.IsChecked
        Set-Ambient; Update-ApplyGlow; Update-Side
        Write-Log ("Animations {0}." -f $(if ($script:AnimOn) { 'on' } else { 'off' })) 'info'
    })

    # debloat
    $ui.btnDbScan.Add_Click({ Invoke-Safe { Start-DebloatScan } 'Debloat scan' })
    $ui.btnDbSafe.Add_Click({ Select-DbRows 'safe' })
    $ui.btnDbAll.Add_Click({ Select-DbRows 'all' })
    $ui.btnDbNone.Add_Click({ Select-DbRows 'none' })
    $ui.btnDbRun.Add_Click({ Invoke-Safe { Start-DebloatRemove } 'Debloat' })

    # startup
    $ui.btnStRefresh.Add_Click({ Invoke-Safe { Build-StartupPage; Start-Stagger $script:UI.pnlStartup 12 30 0 10 } 'Startup refresh' })

    # lifecycle
    $win.Opacity = 0
    $win.Add_Loaded({ Start-LandingAnimations })
    $win.Add_Closing({
        param($s, $e)
        if ($script:AnimOn -and -not $script:CloseNow) { $e.Cancel = $true; $script:CloseNow = $true; Start-CloseAnim; return }
        try { $script:SessionTimer.Stop() } catch { }
        try { Stop-GameSession } catch { }
        try { if ($script:NativeOk) { [RomNative]::ReleaseTimer() } } catch { }
    })
}

# ---- start -------------------------------------------------------------------------
$script:AnimOn = [bool](Get-Settings).Anim
try {
    [void](New-AppWindow)
    Register-Events
    Register-ExtraEvents
    $script:FindingsDone = $false
    $script:SessionTimer = New-Object Windows.Threading.DispatcherTimer
    $script:SessionTimer.Interval = [TimeSpan]::FromSeconds(3)
    $script:SessionTimer.Add_Tick({ if ($script:Ready) { try { Invoke-SessionTick } catch { } } })
    $script:SessionTimer.Start()
    $script:UI.Win.Dispatcher.Add_UnhandledException({
        param($s, $e)
        try { Write-Log "Unexpected error: $($e.Exception.Message)" 'err' } catch { }
        $e.Handled = $true
    })
    $script:UI.Win.Add_ContentRendered({ if (-not $script:Prepared) { $script:Prepared = $true; Start-Prepare } })
    [void]$script:UI.Win.ShowDialog()
} catch {
    $msg = $_.Exception.Message
    try { Add-Content -LiteralPath $script:LogFile -Value ("{0} [fatal] {1}`n{2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg, $_.ScriptStackTrace) } catch { }
    [void][Windows.MessageBox]::Show("Rom-Opti hit an error and could not continue:`n`n$msg`n`nDetails were saved to $($script:LogFile)", 'Rom-Opti', 'OK', 'Error')
}
