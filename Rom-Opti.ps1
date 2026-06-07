#Requires -Version 5.1
<#
  ===========================================================================
   ROM-OPTI v3  -  Windows Optimizer & Rust FPS Tuner
   Single-file WPF utility with the Aura design system.

   RUN:  double-click Run-RomOpti.bat   (auto-elevates + bypasses policy)
         ...or right-click Rom-Opti.ps1 -> Run with PowerShell

   Every registry/service tweak includes Check, Apply, and Undo logic.
   Create a System Restore point before applying changes.
  ===========================================================================
#>

# ---- 1. SELF-ELEVATE -------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $sp = $MyInvocation.MyCommand.Definition
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$sp`"" -Verb RunAs
    exit
}

# ---- 2. ASSEMBLIES ---------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$ErrorActionPreference = 'Stop'

# ---- 3. HELPERS ------------------------------------------------------------
function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Get-RegValue {
    param([string]$Path, [string]$Name, $Default = $null)
    if (Test-Path $Path) {
        $p = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $p) { return $p.$Name }
    }
    return $Default
}

function Remove-RegValue {
    param([string]$Path, [string]$Name)
    if (Test-Path $Path) {
        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    }
}

function Set-ServiceState {
    param([string]$Name, [ValidateSet('Disabled','Manual','Automatic')]$Startup, [switch]$Stop)
    if (Get-Service -Name $Name -ErrorAction SilentlyContinue) {
        if ($Stop) { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        Set-Service -Name $Name -StartupType $Startup -ErrorAction SilentlyContinue
    }
}

function Get-ServiceStartup {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($svc) { return (Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue).StartMode }
    return $null
}

function Get-PowerCfgAcValue {
    param([string]$SubGroup, [string]$Setting)
    $out = powercfg -query SCHEME_CURRENT $SubGroup $Setting 2>$null
    if ($out -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') {
        return [int][convert]::ToInt32($Matches[1], 16)
    }
    return $null
}

function Test-UltimatePerformanceActive {
    $list = powercfg /list 2>$null
    $active = ($list | Where-Object { $_ -match '^\*' }) -replace '.*\s([0-9a-f-]{36}).*','$1'
    if (-not $active) { return $false }
    $detail = powercfg /query $active 2>$null | Out-String
    return ($list | Where-Object { $_ -match '^\*' }) -match 'Ultimate Performance'
}

function Get-ActiveNetAdapters {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -or $_.Status -eq 'Disconnected' }
}

# Write-Log is wired to lstLog after the WPF window loads.
$script:lstLog = $null
$script:logScroll = $null

function Write-Log {
    param([string]$Message, [ValidateSet('info','ok','warn','err','accent')]$Kind = 'info')
    if (-not $script:lstLog) { return }
    $colors = @{
        info   = '#94A3B8'
        ok     = '#4ADE80'
        warn   = '#FBBF24'
        err    = '#F87171'
        accent = '#6366F1'
    }
    $item = New-Object Windows.Controls.TextBlock
    $item.Text = $Message
    $item.TextWrapping = 'Wrap'
    $item.FontSize = 11.5
    $item.FontFamily = 'Consolas'
    $item.Margin = '0,1,0,1'
    $item.Foreground = (New-Object Windows.Media.SolidColorBrush (
        [Windows.Media.ColorConverter]::ConvertFromString($colors[$Kind])
    ))
    $script:lstLog.Items.Add($item) | Out-Null
    if ($script:logScroll) { $script:logScroll.ScrollToEnd() }
}

function Invoke-UiPump {
    param($Window)
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $null = $Window.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [action]{ $frame.Continue = $false }
    )
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

# ---- 4. TWEAK ENGINE -------------------------------------------------------
$Tweaks = @(
#region PREFERENCES
    [pscustomobject]@{
        Id='pref_dark'; Category='Preferences'; Name='Enable Dark Mode'; Recommended=$true; ExplorerRestart=$true
        Desc='Switches Windows apps and the system UI (taskbar, Start, Settings) to the dark theme.'
        Check={ (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 1) -eq 0 }
        Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 0
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0 }
        Undo={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 1
               Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 1 }
    }
    [pscustomobject]@{
        Id='pref_ext'; Category='Preferences'; Name='Show File Extensions'; Recommended=$true; ExplorerRestart=$true
        Desc='Reveals file types like .exe, .txt, .cfg in Explorer.'
        Check={ (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 1) -eq 0 }
        Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0 }
        Undo={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 1 }
    }
    [pscustomobject]@{
        Id='pref_hidden'; Category='Preferences'; Name='Show Hidden Files'; ExplorerRestart=$true
        Desc='Makes hidden files and folders visible (e.g. AppData, game config folders).'
        Check={ (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden' 0) -eq 1 }
        Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden' 1 }
        Undo={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden' 2 }
    }
    [pscustomobject]@{
        Id='pref_tbleft'; Category='Preferences'; Name='Left-Align Taskbar (Win11)'; ExplorerRestart=$true
        Desc='Moves the Windows 11 taskbar icons and Start button back to the left.'
        Check={ (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl' 1) -eq 0 }
        Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl' 0 }
        Undo={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl' 1 }
    }
    [pscustomobject]@{
        Id='pref_widgets'; Category='Preferences'; Name='Hide Taskbar Widgets'; Recommended=$true; ExplorerRestart=$true
        Desc='Removes the news/weather Widgets button and related background processes.'
        Check={ (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 1) -eq 0 }
        Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 }
        Undo={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 1
               Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' }
    }
    [pscustomobject]@{
        Id='pref_search'; Category='Preferences'; Name='Disable Bing/Web Search in Start'; Recommended=$true; ExplorerRestart=$true
        Desc='Stops the Start menu search from querying the internet.'
        Check={ (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 1) -eq 0 }
        Apply={ Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0 }
        Undo={ Remove-RegValue 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions'
               Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 1 }
    }
    [pscustomobject]@{
        Id='pref_context'; Category='Preferences'; Name='Classic Right-Click Menu (Win11)'; ExplorerRestart=$true
        Desc='Brings back the full Windows 10 context menu on Windows 11.'
        Check={ Test-Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' }
        Apply={ $k='HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
                New-Item $k -Force | Out-Null; Set-ItemProperty -Path $k -Name '(Default)' -Value '' -Force }
        Undo={ Remove-Item 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' -Recurse -Force -ErrorAction SilentlyContinue }
    }
    [pscustomobject]@{
        Id='pref_trans'; Category='Preferences'; Name='Disable Transparency Effects'
        Desc='Turns off blur/acrylic transparency on the taskbar and windows.'
        Check={ (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 1) -eq 0 }
        Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0 }
        Undo={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 1 }
    }
    [pscustomobject]@{
        Id='pref_thispc'; Category='Preferences'; Name='Open Explorer to "This PC"'; ExplorerRestart=$true
        Desc='Makes File Explorer open to "This PC" instead of Quick Access.'
        Check={ (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 0) -eq 1 }
        Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1 }
        Undo={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 2 }
    }
#endregion
#region TWEAKS
    [pscustomobject]@{
        Id='tw_restore'; Category='Tweaks'; Name='Create Restore Point (do this first)'; Default=$true; Recommended=$true
        Desc='Creates a System Restore point so you can roll back every change.'
        Check={ $false }
        Apply={ Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue
                Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
                Checkpoint-Computer -Description 'Rom-Opti v3' -RestorePointType 'MODIFY_SETTINGS' }
        Undo={ Write-Log 'Restore points cannot be undone automatically. Use System Restore from Windows Settings.' 'warn' }
    }
    [pscustomobject]@{
        Id='tw_temp'; Category='Tweaks'; Name='Delete Temporary Files'; Recommended=$true
        Desc='Clears user and Windows temp folders to free disk space.'
        Check={ $false }
        Apply={ Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue }
        Undo={ Write-Log 'Deleted temp files cannot be restored.' 'warn' }
    }
    [pscustomobject]@{
        Id='tw_telemetry'; Category='Tweaks'; Name='Disable Telemetry'; Recommended=$true
        Desc='Stops Windows diagnostic/usage data collection and disables DiagTrack.'
        Check={ (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 3) -eq 0 -and
                (Get-ServiceStartup 'DiagTrack') -eq 'Disabled' }
        Apply={ Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
                Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
                Set-ServiceState -Name 'DiagTrack' -Startup Disabled -Stop
                Set-ServiceState -Name 'dmwappushservice' -Startup Disabled -Stop }
        Undo={ Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry'
               Remove-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry'
               Set-ServiceState -Name 'DiagTrack' -Startup Automatic
               Set-ServiceState -Name 'dmwappushservice' -Startup Manual }
    }
    [pscustomobject]@{
        Id='tw_gamedvr'; Category='Tweaks'; Name='Disable Game DVR / Recording'; Recommended=$true
        Desc='Disables background game recording to free CPU/GPU overhead.'
        Check={ (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 1) -eq 0 }
        Apply={ Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
                Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 }
        Undo={ Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR'
               Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 1
               Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 1 }
    }
    [pscustomobject]@{
        Id='tw_hibernate'; Category='Tweaks'; Name='Disable Hibernation'
        Desc='Turns off hibernation and deletes hiberfil.sys to reclaim disk space.'
        Check={ -not (Test-Path "$env:SystemDrive\hiberfil.sys") }
        Apply={ powercfg.exe -h off | Out-Null }
        Undo={ powercfg.exe -h on | Out-Null }
    }
    [pscustomobject]@{
        Id='tw_endtask'; Category='Tweaks'; Name='Enable "End Task" on Right-Click'; Recommended=$true; ExplorerRestart=$true
        Desc='Adds an End Task option to the taskbar right-click menu.'
        Check={ (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\TaskbarDeveloperSettings' 'TaskbarEndTask' 0) -eq 1 }
        Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\TaskbarDeveloperSettings' 'TaskbarEndTask' 1 }
        Undo={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\TaskbarDeveloperSettings' 'TaskbarEndTask' 0 }
    }
    [pscustomobject]@{
        Id='tw_tips'; Category='Tweaks'; Name='Disable Tips, Ads & Suggestions'; Recommended=$true
        Desc='Removes Start menu app suggestions, lock-screen tips, and Windows tip popups.'
        Check={ (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 1) -eq 0 }
        Apply={ $c='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
                'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-338393Enabled',
                'SystemPaneSuggestionsEnabled','SilentInstalledAppsEnabled','SoftLandingEnabled' |
                ForEach-Object { Set-Reg $c $_ 0 } }
        Undo={ $c='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
               'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-338393Enabled',
               'SystemPaneSuggestionsEnabled','SilentInstalledAppsEnabled','SoftLandingEnabled' |
               ForEach-Object { Set-Reg $c $_ 1 } }
    }
    [pscustomobject]@{
        Id='tw_services'; Category='Tweaks'; Name='Set Non-Essential Services to Manual'
        Desc='Sets rarely-used services (Fax, Retail Demo, Maps Broker, etc.) to Manual.'
        Check={ (@('Fax','RetailDemo','MapsBroker') | ForEach-Object { (Get-ServiceStartup $_) -eq 'Manual' } | Where-Object { $_ }).Count -eq 3 }
        Apply={ 'Fax','RetailDemo','MapsBroker','PcaSvc','WMPNetworkSvc','RemoteRegistry','WbioSrvc' |
                ForEach-Object { Set-ServiceState -Name $_ -Startup Manual } }
        Undo={ 'Fax','RetailDemo','MapsBroker','PcaSvc','WMPNetworkSvc','RemoteRegistry','WbioSrvc' |
               ForEach-Object { Set-ServiceState -Name $_ -Startup Automatic } }
    }
#endregion
#region RUST FPS
    [pscustomobject]@{
        Id='r_ultimate'; Category='Rust FPS'; Name='Ultimate Performance Power Plan'; Recommended=$true
        Desc='Unlocks and activates the hidden Ultimate Performance power plan for maximum CPU clocks.'
        Check={ Test-UltimatePerformanceActive }
        Apply={ $o = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null
                if ($o -match '([0-9a-fA-F-]{36})') { powercfg -setactive $Matches[1] | Out-Null }
                else { powercfg -setactive e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null } }
        Undo={ powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e | Out-Null }
    }
    [pscustomobject]@{
        Id='r_unpark'; Category='Rust FPS'; Name='Disable CPU Core Parking'; Recommended=$true
        Desc='Keeps all CPU cores active instead of parking to save power. Reduces stutter in Rust.'
        Check={ (Get-PowerCfgAcValue 'SUB_PROCESSOR' '0cc5b647-c1df-4637-891a-dec35c318583') -eq 100 }
        Apply={ $g='0cc5b647-c1df-4637-891a-dec35c318583'
                powercfg -setacvalueindex scheme_current sub_processor $g 100 | Out-Null
                powercfg -setdcvalueindex scheme_current sub_processor $g 100 | Out-Null
                powercfg -setactive scheme_current | Out-Null }
        Undo={ $g='0cc5b647-c1df-4637-891a-dec35c318583'
               powercfg -setacvalueindex scheme_current sub_processor $g 10 | Out-Null
               powercfg -setdcvalueindex scheme_current sub_processor $g 10 | Out-Null
               powercfg -setactive scheme_current | Out-Null }
    }
    [pscustomobject]@{
        Id='r_paging'; Category='Rust FPS'; Name='Disable Paging Executive'; Recommended=$true
        Desc='Keeps the Windows kernel in RAM instead of paging to disk (DisablePagingExecutive = 1).'
        Check={ (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'DisablePagingExecutive' 0) -eq 1 }
        Apply={ Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'DisablePagingExecutive' 1 }
        Undo={ Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'DisablePagingExecutive' 0 }
    }
    [pscustomobject]@{
        Id='r_netmod'; Category='Rust FPS'; Name='Disable Network Interrupt Moderation'; Recommended=$true
        Desc='Disables checksum offload and interrupt moderation on physical adapters for lower latency.'
        Check={
            $adapters = Get-ActiveNetAdapters
            if (-not $adapters) { return $false }
            $all = $true
            foreach ($a in $adapters) {
                $im = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword '*InterruptModeration' -ErrorAction SilentlyContinue
                if ($im -and $im.DisplayValue -ne 'Disabled') { $all = $false }
            }
            return $all
        }
        Apply={
            Get-ActiveNetAdapters | ForEach-Object {
                Disable-NetAdapterChecksumOffload -Name $_.Name -TcpIPv4 -UdpIPv4 -ErrorAction SilentlyContinue
                Disable-NetAdapterInterruptModeration -Name $_.Name -ErrorAction SilentlyContinue
            }
        }
        Undo={
            Get-ActiveNetAdapters | ForEach-Object {
                Enable-NetAdapterChecksumOffload -Name $_.Name -TcpIPv4 -UdpIPv4 -ErrorAction SilentlyContinue
                Enable-NetAdapterInterruptModeration -Name $_.Name -ErrorAction SilentlyContinue
            }
        }
    }
    [pscustomobject]@{
        Id='r_sysmain'; Category='Rust FPS'; Name='Disable SysMain (Prefetch/Superfetch)'; Recommended=$true
        Desc='Disables SysMain prefetch. Recommended on SSD/NVMe only — skip on HDD systems.'
        Check={ (Get-ServiceStartup 'SysMain') -eq 'Disabled' }
        Apply={ Set-ServiceState -Name 'SysMain' -Startup Disabled -Stop }
        Undo={ Set-ServiceState -Name 'SysMain' -Startup Automatic; Start-Service -Name 'SysMain' -ErrorAction SilentlyContinue }
    }
    [pscustomobject]@{
        Id='r_throttle'; Category='Rust FPS'; Name='Disable Power Throttling'; Recommended=$true
        Desc='Stops Windows throttling CPU power to apps, keeping the game at full clocks.'
        Check={ (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 0) -eq 1 }
        Apply={ Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1 }
        Undo={ Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 0 }
    }
    [pscustomobject]@{
        Id='r_hags'; Category='Rust FPS'; Name='Enable GPU Hardware-Accelerated Scheduling'; Recommended=$true
        Desc='Lets the GPU manage its own scheduling for lower latency. Reboot required.'
        Check={ (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 1) -eq 2 }
        Apply={ Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2 }
        Undo={ Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 1 }
    }
    [pscustomobject]@{
        Id='r_gamemode'; Category='Rust FPS'; Name='Enable Windows Game Mode'; Recommended=$true
        Desc='Tells Windows to prioritize the foreground game.'
        Check={ (Get-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 0) -eq 1 }
        Apply={ Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
                Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1 }
        Undo={ Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 0
               Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 0 }
    }
    [pscustomobject]@{
        Id='r_mmcss'; Category='Rust FPS'; Name='Prioritize Games in Scheduler (MMCSS)'; Recommended=$true
        Desc='Tunes the multimedia scheduler to give games top GPU/CPU priority.'
        Check={ (Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'GPU Priority' 0) -ge 8 }
        Apply={ $sp='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
                Set-Reg $sp 'SystemResponsiveness' 10
                $games="$sp\Tasks\Games"
                Set-Reg $games 'GPU Priority' 8
                Set-Reg $games 'Priority' 6
                Set-Reg $games 'Scheduling Category' 'High' 'String'
                Set-Reg $games 'SFIO Priority' 'High' 'String' }
        Undo={ $sp='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
               Set-Reg $sp 'SystemResponsiveness' 20
               $games="$sp\Tasks\Games"
               Set-Reg $games 'GPU Priority' 8
               Set-Reg $games 'Priority' 2
               Set-Reg $games 'Scheduling Category' 'Medium' 'String'
               Set-Reg $games 'SFIO Priority' 'Normal' 'String' }
    }
    [pscustomobject]@{
        Id='r_netthrottle'; Category='Rust FPS'; Name='Disable Network Throttling'; Recommended=$true
        Desc='Removes the default packet throttle for multiplayer traffic.'
        Check={ (Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' 10) -eq 4294967295 }
        Apply={ Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' 4294967295 }
        Undo={ Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' 10 }
    }
    [pscustomobject]@{
        Id='r_nagle'; Category='Rust FPS'; Name="Disable Nagle's Algorithm"; Recommended=$true
        Desc='Disables TCP packet-batching across adapters to reduce latency spikes.'
        Check={
            $base='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
            $ifaces = Get-ChildItem $base -ErrorAction SilentlyContinue
            if (-not $ifaces) { return $false }
            ($ifaces | ForEach-Object {
                (Get-RegValue $_.PSPath 'TCPNoDelay' 0) -eq 1 -and (Get-RegValue $_.PSPath 'TcpAckFrequency' 0) -eq 1
            } | Where-Object { $_ } | Measure-Object).Count -eq $ifaces.Count
        }
        Apply={ $base='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
                Get-ChildItem $base | ForEach-Object {
                    Set-ItemProperty -Path $_.PSPath -Name 'TcpAckFrequency' -Value 1 -Type DWord -Force
                    Set-ItemProperty -Path $_.PSPath -Name 'TCPNoDelay' -Value 1 -Type DWord -Force } }
        Undo={ $base='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
               Get-ChildItem $base | ForEach-Object {
                   Remove-ItemProperty -Path $_.PSPath -Name 'TcpAckFrequency' -ErrorAction SilentlyContinue
                   Remove-ItemProperty -Path $_.PSPath -Name 'TCPNoDelay' -ErrorAction SilentlyContinue } }
    }
    [pscustomobject]@{
        Id='r_mouse'; Category='Rust FPS'; Name='Disable Mouse Acceleration'; Recommended=$true
        Desc='Turns off Enhance Pointer Precision for consistent 1:1 aim.'
        Check={ (Get-RegValue 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '1') -eq '0' }
        Apply={ Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
                Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
                Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String' }
        Undo={ Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '1' 'String'
               Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '6' 'String'
               Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '10' 'String' }
    }
    [pscustomobject]@{
        Id='r_fso'; Category='Rust FPS'; Name='Disable Fullscreen Optimizations (global)'
        Desc='Forces true exclusive fullscreen behaviour to reduce input lag.'
        Check={ (Get-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 0) -eq 2 }
        Apply={ $g='HKCU:\System\GameConfigStore'
                Set-Reg $g 'GameDVR_FSEBehaviorMode' 2
                Set-Reg $g 'GameDVR_HonorUserFSEBehaviorMode' 1
                Set-Reg $g 'GameDVR_DXGIHonorFSEWindowsCompatible' 1
                Set-Reg $g 'GameDVR_EFSEFeatureFlags' 0 }
        Undo={ $g='HKCU:\System\GameConfigStore'
               Set-Reg $g 'GameDVR_FSEBehaviorMode' 0
               Set-Reg $g 'GameDVR_HonorUserFSEBehaviorMode' 0
               Set-Reg $g 'GameDVR_DXGIHonorFSEWindowsCompatible' 0
               Set-Reg $g 'GameDVR_EFSEFeatureFlags' 0 }
    }
    [pscustomobject]@{
        Id='r_launch'; Category='Rust FPS'; Name='Copy Recommended Rust Launch Options'
        Desc='Copies tuned Steam launch options to clipboard for Rust.'
        Check={ $false }
        Apply={ '-high -maxMem=16384 -malloc=system -force-d3d11-no-singlethreaded -window-mode exclusive' | Set-Clipboard }
        Undo={ Write-Log 'Clipboard contents cannot be reverted.' 'warn' }
    }
#endregion
#region DEBLOAT
    [pscustomobject]@{
        Id='db_copilot'; Category='Debloat'; Name='Disable Windows Copilot'; Recommended=$true
        Desc='Turns off Windows Copilot and removes its taskbar button.'
        Check={ (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 0) -eq 1 }
        Apply={ Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 }
        Undo={ Remove-RegValue 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot'
               Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' }
    }
    [pscustomobject]@{
        Id='db_tasks'; Category='Debloat'; Name='Disable Telemetry Scheduled Tasks'; Recommended=$true
        Desc='Disables background tasks that collect compatibility/usage data.'
        Check={ $false }
        Apply={ '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
                '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
                '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
                '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip' |
                ForEach-Object { Disable-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue | Out-Null } }
        Undo={ '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
               '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
               '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
               '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip' |
               ForEach-Object { Enable-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue | Out-Null } }
    }
    [pscustomobject]@{
        Id='db_consumer'; Category='Debloat'; Name='Disable Consumer Features'; Recommended=$true
        Desc='Stops Windows auto-installing promoted/sponsored apps.'
        Check={ (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 0) -eq 1 }
        Apply={ Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1 }
        Undo={ Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' }
    }
#endregion
)

# ---- 5. HARDWARE SCANNER ---------------------------------------------------
function Get-HardwareAdvice {
    param([Windows.Controls.TextBox]$OutputBox)

    $lines = [System.Collections.Generic.List[string]]::new()
    function Add-Line([string]$Text, [string]$Level = 'info') {
        $prefix = switch ($Level) {
            'ok'     { '[OK]    ' }
            'warn'   { '[WARN]  ' }
            'crit'   { '[CRIT]  ' }
            'accent' { '[INFO]  ' }
            default  { '[INFO]  ' }
        }
        $line = "$prefix$Text"
        $lines.Add($line)
        $kind = switch ($Level) { 'ok' {'ok'} 'warn' {'warn'} 'crit' {'err'} 'accent' {'accent'} default {'info'} }
        Write-Log $line $kind
    }

    Add-Line '=== Rom-Opti Hardware Diagnostics ===' 'accent'
    Add-Line ''

    # RAM
    try {
        $ramBytes = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
        $ramGb = [math]::Round($ramBytes / 1GB, 1)
        Add-Line "Total Physical RAM: $ramGb GB"
        if ($ramGb -lt 16) {
            Add-Line 'Less than 16 GB RAM detected. Avoid disabling memory compression tweaks.' 'warn'
            Add-Line 'Rust benefits from 16 GB+. Consider upgrading RAM for large servers.' 'warn'
        } else {
            Add-Line 'RAM meets the 16 GB recommendation for aggressive memory tweaks.' 'ok'
        }
    } catch {
        Add-Line "Could not read RAM: $($_.Exception.Message)" 'warn'
    }

    Add-Line ''

    # Storage
    try {
        $disks = Get-PhysicalDisk -ErrorAction Stop
        $hdds = $disks | Where-Object { $_.MediaType -eq 'HDD' }
        if ($hdds) {
            foreach ($d in $hdds) {
                Add-Line "HDD detected: $($d.FriendlyName) ($($d.Size / 1GB | ForEach-Object { [math]::Round($_,0) }) GB)" 'crit'
            }
            Add-Line 'CRITICAL: Move Rust to an SSD. Do NOT disable SysMain/Superfetch on HDD systems.' 'crit'
        } else {
            Add-Line 'No HDD detected — SSD/NVMe storage looks good for disabling SysMain.' 'ok'
        }
    } catch {
        Add-Line "Could not read physical disks: $($_.Exception.Message)" 'warn'
    }

    Add-Line ''

    # CPU / BIOS
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $cpuName = $cpu.Name.Trim()
        Add-Line "CPU: $cpuName"
        Add-Line 'BIOS: Enable XMP (Intel) or DOCP/EXPO (AMD) for rated RAM speed.' 'accent'
        Add-Line 'BIOS: Enable ReBAR / Resizable BAR and Above 4G Decoding for modern GPUs.' 'accent'

        if ($cpuName -match 'Intel') {
            if ($cpuName -match 'i[3579]-1[2-9]\d{3}|Core Ultra|14th Gen|13th Gen|12th Gen') {
                Add-Line 'Intel hybrid CPU detected. In BIOS, consider disabling E-Cores for max FPS stability in Rust.' 'warn'
                Add-Line 'Alternatively use Windows Game Mode + process affinity to pin Rust to P-Cores.' 'accent'
            } else {
                Add-Line 'Intel CPU: verify XMP and ReBAR are enabled in BIOS for best Rust performance.' 'accent'
            }
        } elseif ($cpuName -match 'AMD|Ryzen') {
            Add-Line 'AMD CPU: enable EXPO/DOCP for RAM and SAM (Smart Access Memory) if you have an AMD GPU.' 'accent'
        }
    } catch {
        Add-Line "Could not read CPU info: $($_.Exception.Message)" 'warn'
    }

    Add-Line ''
    Add-Line 'Diagnostics complete. Review warnings before applying Rust FPS tweaks.' 'accent'

    if ($OutputBox) {
        $OutputBox.Text = ($lines -join [Environment]::NewLine)
    }
}

# ---- 6. XAML (Aura Design) -------------------------------------------------
$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Rom-Opti v3" Width="1060" Height="700"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        FontFamily="Segoe UI" ResizeMode="CanMinimize">

  <Window.Resources>
    <SolidColorBrush x:Key="BgDeep" Color="#0D0E12"/>
    <SolidColorBrush x:Key="BorderClr" Color="#1F2430"/>
    <SolidColorBrush x:Key="TextWhite" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="TextMuted" Color="#94A3B8"/>
    <SolidColorBrush x:Key="Accent" Color="#6366F1"/>
    <SolidColorBrush x:Key="AccentHover" Color="#818CF8"/>
    <SolidColorBrush x:Key="Danger" Color="#EF4444"/>

    <Style x:Key="NavRadio" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="8,2"/>
      <Setter Property="Padding" Value="12,10"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{StaticResource BorderClr}"
                    BorderThickness="1" CornerRadius="0" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1A1F2E"/>
                <Setter Property="Foreground" Value="{StaticResource Accent}"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#141820"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DeckButton" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="Background" Value="#141820"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderClr}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="14,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="0" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#1A1F2E"/>
                <Setter Property="Foreground" Value="{StaticResource TextWhite}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource DeckButton}">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
    </Style>

    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource DeckButton}">
      <Setter Property="Foreground" Value="{StaticResource Danger}"/>
      <Setter Property="Background" Value="#141820"/>
    </Style>

    <Style x:Key="WinChrome" TargetType="Button">
      <Setter Property="Width" Value="36"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#1A1F2E"/>
                <Setter Property="Foreground" Value="{StaticResource TextWhite}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource TextWhite}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Margin" Value="0,6,16,6"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#0D0E12"/>
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10"/>
      <Setter Property="MaxWidth" Value="340"/>
    </Style>
  </Window.Resources>

  <Border Background="{StaticResource BgDeep}" BorderBrush="{StaticResource BorderClr}" BorderThickness="1">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="240"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- SIDEBAR -->
      <Border Grid.Column="0" BorderBrush="{StaticResource BorderClr}" BorderThickness="0,0,1,0">
        <DockPanel LastChildFill="True">
          <StackPanel DockPanel.Dock="Top" Margin="18,20,14,12">
            <TextBlock Text="ROM-OPTI" FontSize="20" FontWeight="Bold" Foreground="{StaticResource TextWhite}"/>
            <TextBlock Text="v3  •  Rust FPS Tuner" FontSize="11" Foreground="{StaticResource TextMuted}" Margin="1,2,0,0"/>
            <TextBlock x:Name="sysLine" FontSize="10" Foreground="{StaticResource TextMuted}" Margin="1,10,0,0" TextWrapping="Wrap"/>
          </StackPanel>

          <StackPanel DockPanel.Dock="Top" Margin="6,4,6,0">
            <RadioButton x:Name="navDashboard" Style="{StaticResource NavRadio}" Content="Dashboard" IsChecked="True" GroupName="Nav"/>
            <RadioButton x:Name="navPreferences" Style="{StaticResource NavRadio}" Content="System Preferences" GroupName="Nav"/>
            <RadioButton x:Name="navTweaks" Style="{StaticResource NavRadio}" Content="Performance Tweaks" GroupName="Nav"/>
            <RadioButton x:Name="navRust" Style="{StaticResource NavRadio}" Content="Rust FPS Engine" GroupName="Nav"/>
            <RadioButton x:Name="navDebloat" Style="{StaticResource NavRadio}" Content="Debloat Controls" GroupName="Nav"/>
            <RadioButton x:Name="navHardware" Style="{StaticResource NavRadio}" Content="Hardware Scanner" GroupName="Nav"/>
          </StackPanel>

          <Border DockPanel.Dock="Bottom" Margin="10,8,10,12" BorderBrush="{StaticResource BorderClr}" BorderThickness="1" Height="160">
            <DockPanel>
              <TextBlock DockPanel.Dock="Top" Text="Activity Log" FontSize="10" Foreground="{StaticResource TextMuted}" Margin="8,6,8,4"/>
              <ScrollViewer x:Name="logScroll" VerticalScrollBarVisibility="Auto" Padding="8,0,8,6">
                <ListBox x:Name="lstLog" Background="Transparent" BorderThickness="0"
                         ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                  <ListBox.ItemContainerStyle>
                    <Style TargetType="ListBoxItem">
                      <Setter Property="Padding" Value="0"/>
                      <Setter Property="Margin" Value="0"/>
                      <Setter Property="Background" Value="Transparent"/>
                      <Setter Property="BorderThickness" Value="0"/>
                      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                      <Setter Property="Focusable" Value="False"/>
                    </Style>
                  </ListBox.ItemContainerStyle>
                </ListBox>
              </ScrollViewer>
            </DockPanel>
          </Border>
        </DockPanel>
      </Border>

      <!-- MAIN WORKSPACE -->
      <Grid Grid.Column="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="52"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <Border x:Name="titleBar" Grid.Row="0" BorderBrush="{StaticResource BorderClr}" BorderThickness="0,0,0,1"
                Background="#0D0E12">
          <DockPanel Margin="20,0,8,0" LastChildFill="True">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="btnMinimize" Style="{StaticResource WinChrome}" Content="—"/>
              <Button x:Name="btnClose" Style="{StaticResource WinChrome}" Content="✕" Foreground="{StaticResource Danger}"/>
            </StackPanel>
            <TextBlock x:Name="txtCategoryTitle" Text="Dashboard" FontSize="18" FontWeight="Bold"
                       Foreground="{StaticResource TextWhite}" VerticalAlignment="Center"/>
          </DockPanel>
        </Border>

        <!-- Content -->
        <Grid Grid.Row="1" Margin="20,16,20,12">
          <!-- Dashboard -->
          <StackPanel x:Name="viewDashboard" Visibility="Visible">
            <TextBlock Text="Welcome to Rom-Opti v3" FontSize="16" FontWeight="SemiBold" Foreground="{StaticResource TextWhite}"/>
            <TextBlock Margin="0,10,0,0" TextWrapping="Wrap" Foreground="{StaticResource TextMuted}" FontSize="13"
              Text="A single-file Windows optimizer built for Rust. Pick a category from the sidebar, review tweaks with the (?) tooltips, then Execute or Undo selected changes. Run Hardware Scanner first for tailored advice."/>
            <Border Margin="0,20,0,0" BorderBrush="{StaticResource BorderClr}" BorderThickness="1" Padding="16">
              <StackPanel>
                <TextBlock Text="Quick Start" FontWeight="SemiBold" Foreground="{StaticResource Accent}" FontSize="13"/>
                <TextBlock Margin="0,8,0,0" Foreground="{StaticResource TextMuted}" FontSize="12" TextWrapping="Wrap"
                  Text="1. Hardware Scanner → Run Diagnostics&#10;2. Performance Tweaks → tick Create Restore Point&#10;3. Rust FPS Engine → Apply Recommended preset&#10;4. EXECUTE SELECTED → reboot when prompted"/>
              </StackPanel>
            </Border>
          </StackPanel>

          <!-- Tweak panels -->
          <ScrollViewer x:Name="svOptions" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
            <WrapPanel x:Name="pnlOptions" Orientation="Horizontal" Width="760"/>
          </ScrollViewer>

          <!-- Hardware Scanner -->
          <Grid x:Name="viewHardware" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <TextBlock Text="Scan your hardware and get tailored BIOS/storage/RAM advice before applying aggressive tweaks."
                       Foreground="{StaticResource TextMuted}" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,12"/>
            <Button x:Name="btnRunDiagnostics" Grid.Row="1" Style="{StaticResource PrimaryButton}"
                    Content="Run Diagnostics" HorizontalAlignment="Left" Margin="0,0,0,12"/>
            <Border Grid.Row="2" BorderBrush="{StaticResource BorderClr}" BorderThickness="1" Padding="12">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <TextBox x:Name="txtHardwareAdvice" Background="Transparent" BorderThickness="0"
                         Foreground="{StaticResource TextMuted}" FontFamily="Consolas" FontSize="12"
                         IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True"
                         Text="Click Run Diagnostics to analyze your system."/>
              </ScrollViewer>
            </Border>
          </Grid>
        </Grid>

        <!-- Control Deck -->
        <Border Grid.Row="2" BorderBrush="{StaticResource BorderClr}" BorderThickness="0,1,0,0" Padding="20,12">
          <DockPanel LastChildFill="False">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
              <Button x:Name="btnExecute" Style="{StaticResource PrimaryButton}" Content="EXECUTE SELECTED" Margin="8,0,0,0"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnRecommended" Style="{StaticResource DeckButton}" Content="Apply Recommended"/>
              <Button x:Name="btnSelectAll" Style="{StaticResource DeckButton}" Content="Select All" Margin="8,0,0,0"/>
              <Button x:Name="btnClear" Style="{StaticResource DeckButton}" Content="Clear" Margin="8,0,0,0"/>
              <Button x:Name="btnUndo" Style="{StaticResource DangerButton}" Content="UNDO SELECTED" Margin="8,0,0,0"/>
            </StackPanel>
          </DockPanel>
        </Border>
      </Grid>
    </Grid>
  </Border>
</Window>
"@

# ---- 7. LOAD UI ------------------------------------------------------------
[xml]$xamlXml = $XAML
$reader = New-Object System.Xml.XmlNodeReader $xamlXml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Wire title-bar drag (borderless window)
$window.FindName('titleBar').Add_MouseLeftButtonDown({
    param($sender, $e)
    if ($e.ChangedButton -eq 'Left') { $window.DragMove() }
})

$script:lstLog    = $window.FindName('lstLog')
$script:logScroll = $window.FindName('logScroll')
$pnlOptions       = $window.FindName('pnlOptions')
$txtCategoryTitle = $window.FindName('txtCategoryTitle')
$sysLine          = $window.FindName('sysLine')
$viewDashboard    = $window.FindName('viewDashboard')
$viewHardware     = $window.FindName('viewHardware')
$svOptions        = $window.FindName('svOptions')
$txtHardwareAdvice = $window.FindName('txtHardwareAdvice')
$btnRunDiagnostics = $window.FindName('btnRunDiagnostics')

# System info line
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Split('@')[0].Trim()
    $sysLine.Text = "$cpu  •  ${ram}GB RAM  •  $($os.Caption)"
} catch {
    $sysLine.Text = 'System info unavailable'
}

# ---- 8. UI STATE -----------------------------------------------------------
$script:CheckBoxes = @{}
$script:AppliedBrush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#4ADE80'))
$script:DefaultBrush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#FFFFFF'))
$script:AccentBrush  = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#6366F1'))

$NavMap = [ordered]@{
    Dashboard         = @{ Title='Dashboard';          Category=$null;       View='dashboard' }
    Preferences       = @{ Title='System Preferences'; Category='Preferences'; View='options' }
    Tweaks            = @{ Title='Performance Tweaks'; Category='Tweaks';       View='options' }
    Rust              = @{ Title='Rust FPS Engine';    Category='Rust FPS';    View='options' }
    Debloat           = @{ Title='Debloat Controls';   Category='Debloat';     View='options' }
    Hardware          = @{ Title='Hardware Scanner';   Category=$null;       View='hardware' }
}

function New-TweakCheckBox {
    param($Tweak)

    $container = New-Object Windows.Controls.StackPanel
    $container.Orientation = 'Horizontal'
    $container.Margin = '0,4,24,4'
    $container.Width = 360

    $cb = New-Object Windows.Controls.CheckBox
    $cb.Tag = $Tweak.Id
    $cb.Content = $Tweak.Name
    if ($Tweak.PSObject.Properties.Name -contains 'Default' -and $Tweak.Default) {
        $cb.IsChecked = $true
    }

    $badge = New-Object Windows.Controls.TextBlock
    $badge.Text = ' ?'
    $badge.Foreground = $script:AccentBrush
    $badge.FontWeight = 'Bold'
    $badge.FontSize = 12
    $badge.VerticalAlignment = 'Center'
    $badge.Cursor = 'Help'
    $badge.ToolTip = $Tweak.Desc
    [Windows.Controls.ToolTipService]::SetInitialShowDelay($badge, 200)
    [Windows.Controls.ToolTipService]::SetShowDuration($badge, 60000)

    $container.Children.Add($cb) | Out-Null
    $container.Children.Add($badge) | Out-Null

    $script:CheckBoxes[$Tweak.Id] = $cb
    return $container
}

function Update-TweakAppliedState {
    param($Tweak)

    $cb = $script:CheckBoxes[$Tweak.Id]
    if (-not $cb) { return }

    try {
        $applied = & $Tweak.Check
        if ($applied) {
            $cb.Content = "$($Tweak.Name) (Applied)"
            $cb.Foreground = $script:AppliedBrush
        } else {
            $cb.Content = $Tweak.Name
            $cb.Foreground = $script:DefaultBrush
        }
    } catch {
        $cb.Content = $Tweak.Name
        $cb.Foreground = $script:DefaultBrush
    }
}

function Show-Category {
    param([string]$NavKey)

    $nav = $NavMap[$NavKey]
    $txtCategoryTitle.Text = $nav.Title

    $viewDashboard.Visibility = 'Collapsed'
    $viewHardware.Visibility = 'Collapsed'
    $svOptions.Visibility = 'Collapsed'
    switch ($nav.View) {
        'dashboard' {
            $viewDashboard.Visibility = 'Visible'
        }
        'hardware' {
            $viewHardware.Visibility = 'Visible'
        }
        'options' {
            $svOptions.Visibility = 'Visible'
            $pnlOptions.Children.Clear()
            $script:CheckBoxes.Clear()
            $categoryTweaks = $Tweaks | Where-Object { $_.Category -eq $nav.Category }
            foreach ($t in $categoryTweaks) {
                $pnlOptions.Children.Add((New-TweakCheckBox $t)) | Out-Null
                Update-TweakAppliedState $t
            }
        }
    }
}

function Get-SelectedTweaks {
    $Tweaks | Where-Object {
        $cb = $script:CheckBoxes[$_.Id]
        $cb -and $cb.IsChecked
    }
}

function Invoke-ExecuteSelected {
    $btn = $window.FindName('btnExecute')
    $btn.IsEnabled = $false
    Write-Log '=== Executing selected optimizations ===' 'accent'

    $selected = Get-SelectedTweaks
    if (-not $selected) {
        Write-Log 'Nothing selected. Tick some options first.' 'warn'
        $btn.IsEnabled = $true
        return
    }

    $selected = $selected | Sort-Object { if ($_.Id -eq 'tw_restore') { 0 } else { 1 } }
    $needExplorer = $false

    foreach ($t in $selected) {
        try {
            & $t.Apply
            Write-Log "[OK]   $($t.Name)" 'ok'
            if ($t.PSObject.Properties.Name -contains 'ExplorerRestart' -and $t.ExplorerRestart) {
                $needExplorer = $true
            }
            Update-TweakAppliedState $t
        } catch {
            Write-Log "[FAIL] $($t.Name) -> $($_.Exception.Message)" 'err'
        }
        Invoke-UiPump $window
    }

    if ($needExplorer) {
        Write-Log 'Restarting Explorer to apply interface changes...' 'accent'
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    }

    Write-Log '=== Execution complete. Reboot recommended for full effect. ===' 'ok'
    $btn.IsEnabled = $true
}

function Invoke-UndoSelected {
    $btn = $window.FindName('btnUndo')
    $btn.IsEnabled = $false
    Write-Log '=== Reverting selected tweaks ===' 'accent'

    $selected = Get-SelectedTweaks
    if (-not $selected) {
        Write-Log 'Nothing selected to undo.' 'warn'
        $btn.IsEnabled = $true
        return
    }

    $needExplorer = $false
    foreach ($t in ($selected | Sort-Object Name)) {
        try {
            & $t.Undo
            Write-Log "[UNDO] $($t.Name)" 'warn'
            if ($t.PSObject.Properties.Name -contains 'ExplorerRestart' -and $t.ExplorerRestart) {
                $needExplorer = $true
            }
            Update-TweakAppliedState $t
        } catch {
            Write-Log "[FAIL] Undo $($t.Name) -> $($_.Exception.Message)" 'err'
        }
        Invoke-UiPump $window
    }

    if ($needExplorer) {
        Write-Log 'Restarting Explorer...' 'accent'
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    }

    Write-Log '=== Undo complete ===' 'accent'
    $btn.IsEnabled = $true
}

function Set-RecommendedSelection {
    foreach ($t in $Tweaks) {
        if ($script:CheckBoxes.ContainsKey($t.Id)) {
            $rec = ($t.PSObject.Properties.Name -contains 'Recommended') -and $t.Recommended
            $script:CheckBoxes[$t.Id].IsChecked = [bool]$rec
        }
    }
    Write-Log 'Recommended tweaks selected in current view. Review, then EXECUTE.' 'accent'
}

# ---- 9. EVENT WIRING -------------------------------------------------------
$navRadios = @{
    Dashboard   = $window.FindName('navDashboard')
    Preferences = $window.FindName('navPreferences')
    Tweaks      = $window.FindName('navTweaks')
    Rust        = $window.FindName('navRust')
    Debloat     = $window.FindName('navDebloat')
    Hardware    = $window.FindName('navHardware')
}

foreach ($key in $navRadios.Keys) {
    $k = $key
    $navRadios[$k].Add_Checked({
        Show-Category $k
    }.GetNewClosure())
}

$window.FindName('btnMinimize').Add_Click({ $window.WindowState = 'Minimized' })
$window.FindName('btnClose').Add_Click({ $window.Close() })
$window.FindName('btnRecommended').Add_Click({ Set-RecommendedSelection })
$window.FindName('btnSelectAll').Add_Click({
    foreach ($cb in $script:CheckBoxes.Values) { $cb.IsChecked = $true }
})
$window.FindName('btnClear').Add_Click({
    foreach ($cb in $script:CheckBoxes.Values) { $cb.IsChecked = $false }
})
$window.FindName('btnExecute').Add_Click({ Invoke-ExecuteSelected })
$window.FindName('btnUndo').Add_Click({ Invoke-UndoSelected })
$btnRunDiagnostics.Add_Click({ Get-HardwareAdvice -OutputBox $txtHardwareAdvice })

# ---- 10. START -------------------------------------------------------------
$window.Add_Loaded({
    Show-Category 'Dashboard'
    Write-Log 'Rom-Opti v3 ready. Run Hardware Scanner first for tailored advice.' 'accent'

    # Pre-scan all tweaks for applied state (checkboxes built on category switch)
    foreach ($t in $Tweaks) {
        try {
            if (& $t.Check) {
                Write-Log "Already optimized: $($t.Name)" 'ok'
            }
        } catch { }
    }
})

$window.ShowDialog() | Out-Null
