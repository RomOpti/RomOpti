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
$script:rng = New-Object System.Random

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
        accent = '#22D3EE'
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
    [pscustomobject]@{
        Id='tw_startup'; Category='Tweaks'; Name='Disable Common Startup Apps'; Recommended=$true
        Desc='Blocks heavy auto-start apps (Discord, Spotify, Steam, Epic, EA/Origin, GOG Galaxy, Teams, OneDrive, Adobe, and iCUE/Razer/Logitech/MSI/Corsair RGB software) from launching at boot. This is one of the biggest REAL gains: it cuts idle RAM use and background CPU spikes. Audio/GPU/antivirus drivers are never touched. Undo re-enables every entry.'
        Check={
            $appr='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            if (-not (Test-Path $appr)) { return $false }
            $targets=@('Discord','Spotify','Steam','EpicGamesLauncher','*Teams*','OneDrive','Adobe*','iCUE','*Razer*','*Logitech*','*Corsair*','*MSI*','GalaxyClient','EADM','*Origin*')
            $names=(Get-Item $appr).Property
            foreach ($n in $names) {
                foreach ($t in $targets) {
                    if ($n -like $t) {
                        $blob=(Get-ItemProperty $appr -Name $n -ErrorAction SilentlyContinue).$n
                        if ($blob -and $blob[0] -ge 3) { return $true }
                    }
                }
            }
            return $false
        }
        Apply={
            $appr='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            if (-not (Test-Path $appr)) { New-Item $appr -Force | Out-Null }
            $runKeys=@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
                       'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run')
            $targets=@('Discord','Spotify','Steam','EpicGamesLauncher','*Teams*','OneDrive','Adobe*','iCUE',
                       '*Razer*','*Logitech*','*Corsair*','*MSI*','*RGB*','GalaxyClient','EADM','*Origin*')
            $disabled=[byte[]](3,0,0,0,0,0,0,0,0,0,0,0)
            $count=0
            foreach ($rk in $runKeys) {
                if (-not (Test-Path $rk)) { continue }
                foreach ($n in (Get-Item $rk).Property) {
                    foreach ($t in $targets) {
                        if ($n -like $t) {
                            Set-ItemProperty -Path $appr -Name $n -Value $disabled -Type Binary -Force -ErrorAction SilentlyContinue
                            $count++
                            break
                        }
                    }
                }
            }
            Write-Log "Disabled $count startup entry(s). Confirm in Task Manager > Startup apps." 'ok'
        }
        Undo={
            $appr='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            $enabled=[byte[]](2,0,0,0,0,0,0,0,0,0,0,0)
            if (Test-Path $appr) {
                foreach ($n in (Get-Item $appr).Property) {
                    Set-ItemProperty -Path $appr -Name $n -Value $enabled -Type Binary -Force -ErrorAction SilentlyContinue
                }
            }
            Write-Log 'Startup apps re-enabled.' 'warn'
        }
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
    [pscustomobject]@{
        Id='r_procstate'; Category='Rust FPS'; Name='Lock CPU at 100% (Min/Max Processor State)'; Recommended=$true
        Desc='Pins the minimum and maximum processor state to 100% so the CPU never down-clocks mid-fight. Improves frametime consistency and 1% lows. Raises idle temps/power slightly.'
        Check={ (Get-PowerCfgAcValue 'SUB_PROCESSOR' 'PROCTHROTTLEMIN') -eq 100 -and (Get-PowerCfgAcValue 'SUB_PROCESSOR' 'PROCTHROTTLEMAX') -eq 100 }
        Apply={ powercfg -setacvalueindex scheme_current sub_processor PROCTHROTTLEMIN 100 | Out-Null
                powercfg -setdcvalueindex scheme_current sub_processor PROCTHROTTLEMIN 100 | Out-Null
                powercfg -setacvalueindex scheme_current sub_processor PROCTHROTTLEMAX 100 | Out-Null
                powercfg -setdcvalueindex scheme_current sub_processor PROCTHROTTLEMAX 100 | Out-Null
                powercfg -setactive scheme_current | Out-Null }
        Undo={ powercfg -setacvalueindex scheme_current sub_processor PROCTHROTTLEMIN 5 | Out-Null
               powercfg -setdcvalueindex scheme_current sub_processor PROCTHROTTLEMIN 5 | Out-Null
               powercfg -setacvalueindex scheme_current sub_processor PROCTHROTTLEMAX 100 | Out-Null
               powercfg -setdcvalueindex scheme_current sub_processor PROCTHROTTLEMAX 100 | Out-Null
               powercfg -setactive scheme_current | Out-Null }
    }
    [pscustomobject]@{
        Id='r_usbsuspend'; Category='Rust FPS'; Name='Disable USB Selective Suspend'; Recommended=$true
        Desc='Stops Windows from power-cycling USB ports, which can cause mouse/keyboard micro-stutters and brief input dropouts. Lower, more consistent input latency.'
        Check={ (Get-PowerCfgAcValue 'SUB_USB' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226') -eq 0 }
        Apply={ $g='48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
                powercfg -setacvalueindex scheme_current sub_usb $g 0 | Out-Null
                powercfg -setdcvalueindex scheme_current sub_usb $g 0 | Out-Null
                powercfg -setactive scheme_current | Out-Null }
        Undo={ $g='48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
               powercfg -setacvalueindex scheme_current sub_usb $g 1 | Out-Null
               powercfg -setdcvalueindex scheme_current sub_usb $g 1 | Out-Null
               powercfg -setactive scheme_current | Out-Null }
    }
    [pscustomobject]@{
        Id='r_diskoff'; Category='Rust FPS'; Name='Never Turn Off Disk'; Recommended=$true
        Desc='Sets the hard-disk idle timeout to Never so the drive never spins down or sleeps, preventing hitching when a game streams new assets.'
        Check={ (Get-PowerCfgAcValue 'SUB_DISK' '6738e2c4-e8a5-4a42-b16a-e040e769756e') -eq 0 }
        Apply={ $g='6738e2c4-e8a5-4a42-b16a-e040e769756e'
                powercfg -setacvalueindex scheme_current sub_disk $g 0 | Out-Null
                powercfg -setdcvalueindex scheme_current sub_disk $g 0 | Out-Null
                powercfg -setactive scheme_current | Out-Null }
        Undo={ $g='6738e2c4-e8a5-4a42-b16a-e040e769756e'
               powercfg -setacvalueindex scheme_current sub_disk $g 1200 | Out-Null
               powercfg -setdcvalueindex scheme_current sub_disk $g 600 | Out-Null
               powercfg -setactive scheme_current | Out-Null }
    }
    [pscustomobject]@{
        Id='r_pcie'; Category='Rust FPS'; Name='Disable PCIe Link State Power Management'
        Desc='Turns off ASPM so the PCIe link to your GPU/NVMe never enters a low-power state. Lowers latency on desktops. On laptops this increases battery drain.'
        Check={ (Get-PowerCfgAcValue 'SUB_PCIEXPRESS' 'ee12f906-d277-404b-b6da-e5fa1a576df5') -eq 0 }
        Apply={ $g='ee12f906-d277-404b-b6da-e5fa1a576df5'
                powercfg -setacvalueindex scheme_current sub_pciexpress $g 0 | Out-Null
                powercfg -setdcvalueindex scheme_current sub_pciexpress $g 0 | Out-Null
                powercfg -setactive scheme_current | Out-Null }
        Undo={ $g='ee12f906-d277-404b-b6da-e5fa1a576df5'
               powercfg -setacvalueindex scheme_current sub_pciexpress $g 1 | Out-Null
               powercfg -setdcvalueindex scheme_current sub_pciexpress $g 2 | Out-Null
               powercfg -setactive scheme_current | Out-Null }
    }
    [pscustomobject]@{
        Id='r_visualfx'; Category='Rust FPS'; Name='Visual Effects -> Best Performance'; Recommended=$true; ExplorerRestart=$true
        Desc='Switches Windows to "Adjust for best performance" and kills taskbar/window animations. Frees a little GPU and CPU and makes the desktop snappier when alt-tabbing out of a game.'
        Check={ (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 0) -eq 2 }
        Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewAlphaSelect' 0
                Set-Reg 'HKCU:\Control Panel\Desktop' 'DragFullWindows' '0' 'String' }
        Undo={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 0
               Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 1
               Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewAlphaSelect' 1
               Set-Reg 'HKCU:\Control Panel\Desktop' 'DragFullWindows' '1' 'String' }
    }
    [pscustomobject]@{
        Id='r_bgapps'; Category='Rust FPS'; Name='Disable Background Apps'; Recommended=$true
        Desc='Stops UWP/Store apps from running and updating in the background. Frees RAM and trims idle CPU/network so more headroom goes to the game.'
        Check={ (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 0) -eq 1 }
        Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2 }
        Undo={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 0
               Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 1
               Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' }
    }
    [pscustomobject]@{
        Id='r_prioritysep'; Category='Rust FPS'; Name='Foreground Priority Boost'; Recommended=$true
        Desc='Sets Win32PrioritySeparation to favor the active window, giving the foreground game longer, higher-priority CPU time slices. Helps responsiveness and 1% lows.'
        Check={ (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 2) -eq 38 }
        Apply={ Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38 }
        Undo={ Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 2 }
    }
    [pscustomobject]@{
        Id='r_qos'; Category='Rust FPS'; Name='Remove QoS Reserved Bandwidth'; Recommended=$true
        Desc='Removes the 20% of network bandwidth Windows reserves by default for QoS, freeing it for game traffic. Helps on busy or saturated connections.'
        Check={ (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 20) -eq 0 }
        Apply={ Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 0 }
        Undo={ Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' }
    }
    [pscustomobject]@{
        Id='r_gamebar'; Category='Rust FPS'; Name='Disable Xbox Game Bar Overlay'; Recommended=$true
        Desc='Disables the Game Bar overlay and its startup tip, removing recording/overlay overhead and frametime spikes from the in-game panel. Separate from Game DVR.'
        Check={ (Get-RegValue 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 1) -eq 0 -and
                (Get-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 1) -eq 0 }
        Apply={ Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0
                Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 0
                Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'GamePanelStartupTipIndex' 3
                Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 }
        Undo={ Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 1
               Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 1
               Remove-RegValue 'HKCU:\Software\Microsoft\GameBar' 'GamePanelStartupTipIndex'
               Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 1 }
    }
    [pscustomobject]@{
        Id='r_notif'; Category='Rust FPS'; Name='Disable Notifications & Toasts'; Recommended=$true
        Desc='Turns off Windows toast notifications so nothing steals focus or causes a hitch mid-match. Reduces minor background work from the notification platform.'
        Check={ (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 1) -eq 0 }
        Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' 0 }
        Undo={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 1
               Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' 1 }
    }
    [pscustomobject]@{
        Id='r_inputkeys'; Category='Rust FPS'; Name='Disable Sticky / Filter / Toggle Keys'; Recommended=$true
        Desc='Disables the accessibility key shortcuts so mashing Shift or holding a key during a fight never pops a prompt or alters input. Pure input-consistency tweak.'
        Check={ (Get-RegValue 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '510') -eq '506' }
        Apply={ Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
                Set-Reg 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'
                Set-Reg 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '38' 'String' }
        Undo={ Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '510' 'String'
               Set-Reg 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '126' 'String'
               Set-Reg 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '62' 'String' }
    }
    [pscustomobject]@{
        Id='r_menudelay'; Category='Rust FPS'; Name='Zero Menu & Keyboard Delay'; Recommended=$true
        Desc='Removes the menu-show delay and sets the fastest keyboard repeat delay for a snappier desktop and faster console/menu input. Takes effect at next sign-in.'
        Check={ (Get-RegValue 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '400') -eq '0' }
        Apply={ Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0' 'String'
                Set-Reg 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' '0' 'String' }
        Undo={ Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '400' 'String'
               Set-Reg 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' '1' 'String' }
    }
    [pscustomobject]@{
        Id='r_indexing'; Category='Rust FPS'; Name='Disable Windows Search Indexing'
        Desc='Stops the WSearch indexer, which periodically hammers the disk and CPU. Search still works but is slower to return file results. Best on SSD/NVMe.'
        Check={ (Get-ServiceStartup 'WSearch') -eq 'Disabled' }
        Apply={ Set-ServiceState -Name 'WSearch' -Startup Disabled -Stop }
        Undo={ Set-ServiceState -Name 'WSearch' -Startup Automatic; Start-Service -Name 'WSearch' -ErrorAction SilentlyContinue }
    }
    [pscustomobject]@{
        Id='r_memcomp'; Category='Rust FPS'; Name='Disable Memory Compression (16GB+ only)'
        Desc='Turns off the memory-compression engine so the CPU stops spending cycles compressing RAM pages. Only sensible with 16GB+; on low-RAM systems it forces more disk paging and HURTS performance.'
        Check={ try { -not (Get-MMAgent).MemoryCompression } catch { $false } }
        Apply={ Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue }
        Undo={ Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue }
    }
    [pscustomobject]@{
        Id='r_tdr'; Category='Rust FPS'; Name='Raise GPU TDR Timeout'
        Desc='Increases the time Windows waits before resetting a busy GPU driver (TdrDelay 2 -> 10s). Prevents false "display driver stopped responding" crashes and the stutter they cause under heavy load. Reboot required.'
        Check={ (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrDelay' 2) -eq 10 }
        Apply={ Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrDelay' 10
                Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrDdiDelay' 10 }
        Undo={ Remove-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrDelay'
               Remove-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrDdiDelay' }
    }
    [pscustomobject]@{
        Id='r_dyntick'; Category='Rust FPS'; Name='Disable Dynamic Tick'
        Desc='Disables the dynamic kernel timer tick (bcdedit disabledynamictick yes). Can smooth frametimes on some systems and is neutral on others. Fully reversible. Does NOT touch HPET/platform clock, which can cause stutter if changed.'
        Check={ $o = (bcdedit /enum '{current}' 2>$null | Out-String); $o -match 'disabledynamictick\s+Yes' }
        Apply={ bcdedit /set disabledynamictick yes | Out-Null }
        Undo={ bcdedit /deletevalue disabledynamictick | Out-Null }
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
    [pscustomobject]@{
        Id='db_bloatware'; Category='Debloat'; Name='Remove Bloatware Apps (Chris Titus-style)'
        Desc='Removes a curated set of preinstalled Store apps: Bing Weather/News/Finance/Sports, 3D Viewer/Builder, Print3D, Mixed Reality, Maps, Solitaire, Office Hub, OneNote (UWP), Skype, Groove Music, Movies & TV, People, Feedback Hub, Get Help, Tips, Clipchamp, Power Automate, Quick Assist, Dev Home, new Outlook, To Do and Journal. Core apps (Store, Calculator, Photos, Snipping Tool, Terminal, Notepad, Paint, Defender, winget) are NOT touched. Shows a confirmation first. Not auto-reversible (reinstall from the Store).'
        Check={ -not (Get-AppxPackage -Name 'Microsoft.BingWeather' -AllUsers -ErrorAction SilentlyContinue) -and
                -not (Get-AppxPackage -Name 'Microsoft.MicrosoftSolitaireCollection' -AllUsers -ErrorAction SilentlyContinue) }
        Apply={
            $msg = "This permanently removes a curated set of preinstalled Microsoft Store apps:`n`n" +
                   "Bing Weather/News/Finance/Sports, 3D Viewer/Builder, Print3D, Mixed Reality, Maps, Solitaire, Office Hub, OneNote (UWP), Skype, Groove Music, Movies & TV, People, Feedback Hub, Get Help, Tips, Clipchamp, Power Automate, Quick Assist, Dev Home, new Outlook, To Do, Journal.`n`n" +
                   "NOT touched: Store, Calculator, Photos, Snipping Tool, Terminal, Notepad, Paint, Defender, winget. (Use the Xbox tweak for Xbox apps.)`n`n" +
                   "Removed apps can be reinstalled later from the Microsoft Store, but this is NOT auto-reversible.`n`nContinue?"
            $r = [System.Windows.MessageBox]::Show($msg,'Confirm Bloatware Removal',[System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Warning)
            if ($r -ne [System.Windows.MessageBoxResult]::Yes) { Write-Log 'Bloatware removal cancelled by user.' 'warn'; return }
            $apps = @(
                'Microsoft.BingWeather','Microsoft.BingNews','Microsoft.BingFinance','Microsoft.BingSports',
                'Microsoft.3DBuilder','Microsoft.Microsoft3DViewer','Microsoft.Print3D','Microsoft.MixedReality.Portal',
                'Microsoft.WindowsMaps','Microsoft.MicrosoftSolitaireCollection','Microsoft.MicrosoftOfficeHub',
                'Microsoft.Office.OneNote','Microsoft.SkypeApp','Microsoft.ZuneMusic','Microsoft.ZuneVideo',
                'Microsoft.People','Microsoft.WindowsFeedbackHub','Microsoft.GetHelp','Microsoft.Getstarted',
                'Microsoft.Wallet','Clipchamp.Clipchamp','Microsoft.PowerAutomateDesktop',
                'MicrosoftCorporationII.QuickAssist','Microsoft.Windows.DevHome','Microsoft.OutlookForWindows',
                'Microsoft.Todos','Microsoft.MicrosoftJournal'
            )
            $removed=0
            foreach ($a in $apps) {
                try {
                    Get-AppxPackage -Name $a -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $a } |
                        ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
                    $removed++
                } catch { }
                Invoke-UiPump $window
            }
            Write-Log "Bloatware sweep complete. Processed $removed app package(s)." 'ok'
        }
        Undo={ Write-Log 'Removed Store apps cannot be auto-restored. Reinstall any you miss from the Microsoft Store.' 'warn' }
    }
    [pscustomobject]@{
        Id='db_xbox'; Category='Debloat'; Name='Remove Xbox Apps & Idle Xbox Services'
        Desc='Removes the Xbox app, Game Bar overlay and speech overlay, and sets the four Xbox background services to Manual. Keeps Xbox Identity Provider so non-Xbox games that use it for sign-in still work. Services are reversible; apps reinstall from the Store.'
        Check={ -not (Get-AppxPackage -Name 'Microsoft.GamingApp' -AllUsers -ErrorAction SilentlyContinue) -and
                (Get-ServiceStartup 'XblGameSave') -eq 'Manual' }
        Apply={
            'Microsoft.XboxApp','Microsoft.GamingApp','Microsoft.XboxGameOverlay','Microsoft.XboxGamingOverlay',
            'Microsoft.XboxSpeechToTextOverlay','Microsoft.Xbox.TCUI' | ForEach-Object {
                Get-AppxPackage -Name $_ -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            }
            'XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc' | ForEach-Object { Set-ServiceState -Name $_ -Startup Manual }
            Write-Log 'Xbox apps removed; Xbox services set to Manual.' 'ok'
        }
        Undo={ 'XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc' | ForEach-Object { Set-ServiceState -Name $_ -Startup Manual }
               Write-Log 'Xbox apps must be reinstalled from the Store if needed.' 'warn' }
    }
    [pscustomobject]@{
        Id='db_onedrive'; Category='Debloat'; Name='Uninstall OneDrive'
        Desc='Closes and uninstalls the OneDrive desktop client and removes its run-at-startup entry. Files already in the cloud are untouched; only the local sync app is removed.'
        Check={ -not (Test-Path "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe") }
        Apply={
            Start-Process 'taskkill.exe' '/f /im OneDrive.exe' -WindowStyle Hidden -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            $setup = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
            if (-not (Test-Path $setup)) { $setup = "$env:SystemRoot\System32\OneDriveSetup.exe" }
            if (Test-Path $setup) { Start-Process $setup '/uninstall' -Wait -ErrorAction SilentlyContinue }
            Remove-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'OneDrive'
            Write-Log 'OneDrive uninstalled.' 'ok'
        }
        Undo={ Write-Log 'Reinstall OneDrive from https://www.microsoft.com/microsoft-365/onedrive/download if needed.' 'warn' }
    }
    [pscustomobject]@{
        Id='db_teams'; Category='Debloat'; Name='Remove Teams / Chat'
        Desc='Removes the consumer Teams/Chat app and hides the Windows 11 taskbar Chat icon. Work or school Teams installed by your organization is separate and is not affected.'
        Check={ (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 0) -eq 3 }
        Apply={ Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 3
                'MicrosoftTeams','MSTeams' | ForEach-Object {
                    Get-AppxPackage -Name $_ -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue } }
        Undo={ Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon'
               Write-Log 'Teams/Chat can be reinstalled from the Store if needed.' 'warn' }
    }
    [pscustomobject]@{
        Id='db_phonelink'; Category='Debloat'; Name='Remove Phone Link'
        Desc='Removes the Phone Link (Your Phone) app that mirrors Android/iPhone to Windows. Safe to remove if you do not link your phone to the PC.'
        Check={ -not (Get-AppxPackage -Name 'Microsoft.YourPhone' -AllUsers -ErrorAction SilentlyContinue) }
        Apply={ Get-AppxPackage -Name 'Microsoft.YourPhone' -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'Microsoft.YourPhone' } |
                    ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
                Write-Log 'Phone Link removed.' 'ok' }
        Undo={ Write-Log 'Reinstall Phone Link from the Microsoft Store if needed.' 'warn' }
    }
    [pscustomobject]@{
        Id='db_widgets'; Category='Debloat'; Name='Remove Widgets'
        Desc='Removes the Windows Web Experience pack that powers the Widgets board and disables the news/interests policy, freeing the background Widgets process.'
        Check={ (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 1) -eq 0 -and
                -not (Get-AppxPackage -Name 'MicrosoftWindows.Client.WebExperience' -AllUsers -ErrorAction SilentlyContinue) }
        Apply={ Get-AppxPackage -Name 'MicrosoftWindows.Client.WebExperience' -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
                Write-Log 'Widgets removed.' 'ok' }
        Undo={ Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests'
               Write-Log 'Reinstall the Web Experience pack from the Store if needed.' 'warn' }
    }
    [pscustomobject]@{
        Id='db_recall'; Category='Debloat'; Name='Disable Windows Recall'; Recommended=$true
        Desc='Disables Windows Recall (the AI feature that periodically snapshots your screen) via policy and removes the optional feature where present. Privacy plus a little less background overhead.'
        Check={ (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 0) -eq 1 }
        Apply={ Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
                Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
                try { Disable-WindowsOptionalFeature -Online -FeatureName 'Recall' -NoRestart -ErrorAction SilentlyContinue | Out-Null } catch { } }
        Undo={ Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis'
               Remove-RegValue 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' }
    }
    [pscustomobject]@{
        Id='db_edge'; Category='Debloat'; Name='Tame Microsoft Edge'
        Desc='Disables Edge startup boost, background running, the sidebar/Hubs, the shopping assistant, and personalization reporting via policy. Edge is NOT uninstalled (removing it breaks Windows components); it is just stopped from running in the background and nagging.'
        Check={ (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 1) -eq 0 -and
                (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 1) -eq 0 }
        Apply={ $e='HKLM:\SOFTWARE\Policies\Microsoft\Edge'
                Set-Reg $e 'StartupBoostEnabled' 0
                Set-Reg $e 'BackgroundModeEnabled' 0
                Set-Reg $e 'HubsSidebarEnabled' 0
                Set-Reg $e 'EdgeShoppingAssistantEnabled' 0
                Set-Reg $e 'PersonalizationReportingEnabled' 0 }
        Undo={ $e='HKLM:\SOFTWARE\Policies\Microsoft\Edge'
               'StartupBoostEnabled','BackgroundModeEnabled','HubsSidebarEnabled','EdgeShoppingAssistantEnabled','PersonalizationReportingEnabled' |
               ForEach-Object { Remove-RegValue $e $_ } }
    }
    [pscustomobject]@{
        Id='db_p2p'; Category='Debloat'; Name='Disable Update Delivery Optimization (P2P)'; Recommended=$true
        Desc='Stops Windows from uploading update files to other PCs over the internet (peer-to-peer). Saves upload bandwidth that would otherwise compete with your game ping.'
        Check={ (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 1) -eq 0 }
        Apply={ Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
                Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 0 }
        Undo={ Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode'
               Remove-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' }
    }
    [pscustomobject]@{
        Id='db_reserved'; Category='Debloat'; Name='Disable Reserved Storage'
        Desc='Disables the multi-GB block Windows keeps reserved for updates, reclaiming that disk space. Updates still install (they may briefly use free space instead). Applies once no update is pending.'
        Check={ (Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ReserveManager' 'ShippedWithReserves' 1) -eq 0 }
        Apply={ try { Set-ReservedStorageState -State Disabled -ErrorAction SilentlyContinue } catch { }
                Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ReserveManager' 'ShippedWithReserves' 0 }
        Undo={ try { Set-ReservedStorageState -State Enabled -ErrorAction SilentlyContinue } catch { }
               Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ReserveManager' 'ShippedWithReserves' 1 }
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

    # Free space on fixed drives
    try {
        Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | ForEach-Object {
            $freeGb = [math]::Round($_.FreeSpace / 1GB, 0)
            $sizeGb = [math]::Round($_.Size / 1GB, 0)
            $pct = if ($_.Size -gt 0) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 0) } else { 0 }
            if ($pct -lt 15) {
                Add-Line "Drive $($_.DeviceID) $freeGb GB free of $sizeGb GB ($pct%). Under 15% free slows SSDs and causes stutter - free up space." 'warn'
            } else {
                Add-Line "Drive $($_.DeviceID) $freeGb GB free of $sizeGb GB ($pct%). Healthy headroom." 'ok'
            }
        }
    } catch {
        Add-Line "Could not read free space: $($_.Exception.Message)" 'warn'
    }

    Add-Line ''

    # Active power plan
    try {
        $plan = (powercfg /getactivescheme 2>$null) -replace '.*\(([^)]+)\).*','$1'
        if ($plan) { Add-Line "Active power plan: $plan" }
        if ($plan -notmatch 'Ultimate|High') {
            Add-Line 'Not on Ultimate/High Performance. Apply the Ultimate Performance plan in Rust FPS Engine.' 'accent'
        } else {
            Add-Line 'Power plan is performance-oriented.' 'ok'
        }
    } catch { }

    Add-Line ''

    # Display refresh rate
    try {
        $rr = (Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.CurrentRefreshRate } | Select-Object -First 1).CurrentRefreshRate
        if ($rr) {
            Add-Line "Current display refresh rate: $rr Hz"
            if ($rr -le 60) {
                Add-Line 'Running at 60 Hz or less. If your monitor supports more, set it in Settings > Display > Advanced display.' 'warn'
            }
        }
    } catch { }

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
    Add-Line '=== MANUAL HIGH-IMPACT STEPS (cannot be automated from here) ===' 'accent'
    Add-Line 'These are the biggest real FPS gains and must be done by hand:'
    Add-Line ''
    Add-Line '1. RAM: Enable EXPO (AMD) or XMP (Intel) in BIOS. Without it your RAM runs slow and 1% lows suffer. One of the biggest free boosts.' 'accent'
    Add-Line '2. Resizable BAR: Enable ReBAR + Above 4G Decoding in BIOS (and SAM in AMD software). Real gains in many GPU-bound games.' 'accent'
    Add-Line '3. GPU drivers: Do a clean install. Run DDU (Display Driver Uninstaller) in Safe Mode, then install the latest driver fresh. Best fix for microstutter, random FPS drops and instability.' 'accent'
    Add-Line '4. NVIDIA Control Panel: Low Latency Mode = Ultra, Power Management = Prefer Maximum Performance, Texture Filtering = High Performance, Shader Cache = On, V-Sync = Off (use G-Sync if supported). AMD Adrenalin: Anti-Lag On, Texture Filtering Performance, Surface Format Optimization On.' 'accent'
    Add-Line '5. GPU undervolt (MSI Afterburner): lower temps, quieter fans and more STABLE boost clocks, which often means higher sustained FPS. Done right it is free performance.' 'accent'
    Add-Line '6. Ryzen Curve Optimizer (AMD, in BIOS): a negative curve lowers temps and lets the CPU boost higher for longer. Excellent on Ryzen.' 'accent'
    Add-Line '7. FPS cap: cap a few frames below your refresh (237 on 240 Hz, 357 on 360 Hz) for smoother frametimes and lower latency. Set it in-game or with RTSS.' 'accent'
    Add-Line '8. SSD free space: keep 10-20% free. Nearly full SSDs slow down badly. See the free-space report above.' 'accent'
    Add-Line '9. Monitor Hz: confirm Windows is actually set to your panel max refresh rate (Settings > Display > Advanced display), not 60 Hz.' 'accent'
    Add-Line ''
    Add-Line 'Honest note: most in-Windows/registry tweaks improve frametime consistency, 1% lows and input latency more than they raise the average FPS number. The steps above (RAM speed, ReBAR, clean drivers, undervolt, in-game settings, cooling) move average FPS the most.' 'warn'
    Add-Line ''
    Add-Line 'Diagnostics complete. Review warnings before applying Rust FPS tweaks.' 'accent'

    if ($OutputBox) {
        $OutputBox.Text = ($lines -join [Environment]::NewLine)
    }
}

# ---- 6. XAML (Aura Design — dark + soft rounded) ----------------------------
$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Rom-Opti v3" Width="1060" Height="700"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        FontFamily="Segoe UI" ResizeMode="CanMinimize">

  <Window.Resources>
    <SolidColorBrush x:Key="BgDeep" Color="#030405"/>
    <SolidColorBrush x:Key="BgPanel" Color="#0A0B0F"/>
    <SolidColorBrush x:Key="BgGlass" Color="#880A0B10"/>
    <SolidColorBrush x:Key="BorderClr" Color="#181B24"/>
    <SolidColorBrush x:Key="TextWhite" Color="#F1F5F9"/>
    <SolidColorBrush x:Key="TextMuted" Color="#64748B"/>
    <SolidColorBrush x:Key="Accent" Color="#22D3EE"/>
    <SolidColorBrush x:Key="AccentViolet" Color="#6366F1"/>
    <SolidColorBrush x:Key="Danger" Color="#F87171"/>

    <Style x:Key="NavRadio" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="4,3"/>
      <Setter Property="Padding" Value="14,11"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="#141820"
                    BorderThickness="1" CornerRadius="12" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#141820"/>
                <Setter Property="Foreground" Value="{StaticResource Accent}"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#334155"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#0D0F14"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DeckButton" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="Background" Value="#0D0F14"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderClr}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="16,10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="12" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#141820"/>
                <Setter Property="Foreground" Value="{StaticResource TextWhite}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource DeckButton}">
      <Setter Property="Foreground" Value="#030405"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>

    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource DeckButton}">
      <Setter Property="Foreground" Value="{StaticResource Danger}"/>
      <Setter Property="Background" Value="#0D0F14"/>
    </Style>

    <Style x:Key="WinChrome" TargetType="Button">
      <Setter Property="Width" Value="34"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="10">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#141820"/>
                <Setter Property="Foreground" Value="{StaticResource TextWhite}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SoftCard" TargetType="Border">
      <Setter Property="Background" Value="#770A0B10"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderClr}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="16"/>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource TextWhite}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Margin" Value="0,6,16,6"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#0A0B0F"/>
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12"/>
      <Setter Property="MaxWidth" Value="340"/>
    </Style>
  </Window.Resources>

  <Border Background="#030405" BorderBrush="#181B24" BorderThickness="1" CornerRadius="20">
    <Grid ClipToBounds="True">
      <Canvas x:Name="SkyCanvas" IsHitTestVisible="False" Background="#030405"/>

      <Grid Margin="10">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="248"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- SIDEBAR -->
        <Border Grid.Column="0" Margin="0,0,6,0" Background="#770A0B10"
                BorderBrush="{StaticResource BorderClr}" BorderThickness="1" CornerRadius="16">
          <DockPanel LastChildFill="True">
            <StackPanel DockPanel.Dock="Top" Margin="18,22,16,14">
              <TextBlock Text="ROM-OPTI" FontSize="21" FontWeight="Bold" Foreground="{StaticResource TextWhite}"/>
              <TextBlock Text="v3  •  Rust FPS Tuner" FontSize="11" Foreground="{StaticResource TextMuted}" Margin="2,3,0,0"/>
              <TextBlock x:Name="sysLine" FontSize="10" Foreground="#475569" Margin="2,10,0,0" TextWrapping="Wrap"/>
            </StackPanel>

            <StackPanel DockPanel.Dock="Top" Margin="8,2,8,0">
              <RadioButton x:Name="navDashboard" Style="{StaticResource NavRadio}" Content="Dashboard" IsChecked="True" GroupName="Nav"/>
              <RadioButton x:Name="navPreferences" Style="{StaticResource NavRadio}" Content="System Preferences" GroupName="Nav"/>
              <RadioButton x:Name="navTweaks" Style="{StaticResource NavRadio}" Content="Performance Tweaks" GroupName="Nav"/>
              <RadioButton x:Name="navRust" Style="{StaticResource NavRadio}" Content="Rust FPS Engine" GroupName="Nav"/>
              <RadioButton x:Name="navDebloat" Style="{StaticResource NavRadio}" Content="Debloat Controls" GroupName="Nav"/>
              <RadioButton x:Name="navHardware" Style="{StaticResource NavRadio}" Content="Hardware Scanner" GroupName="Nav"/>
            </StackPanel>

            <Border DockPanel.Dock="Bottom" Margin="10,8,10,14" Background="#5506080C"
                    BorderBrush="{StaticResource BorderClr}" BorderThickness="1" CornerRadius="14" Height="168">
              <DockPanel>
                <TextBlock DockPanel.Dock="Top" Text="Activity Log" FontSize="10" Foreground="{StaticResource TextMuted}" Margin="12,10,12,6"/>
                <ScrollViewer x:Name="logScroll" VerticalScrollBarVisibility="Auto" Padding="10,0,10,10">
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
        <Border Grid.Column="1" Background="#770A0B10" BorderBrush="{StaticResource BorderClr}"
                BorderThickness="1" CornerRadius="16">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="54"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Border x:Name="titleBar" Grid.Row="0" BorderBrush="{StaticResource BorderClr}"
                    BorderThickness="0,0,0,1" Background="#4406080C" CornerRadius="16,16,0,0">
              <DockPanel Margin="22,0,10,0" LastChildFill="True">
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                  <Button x:Name="btnMinimize" Style="{StaticResource WinChrome}" Content="—"/>
                  <Button x:Name="btnClose" Style="{StaticResource WinChrome}" Content="✕" Foreground="{StaticResource Danger}"/>
                </StackPanel>
                <TextBlock x:Name="txtCategoryTitle" Text="Dashboard" FontSize="18" FontWeight="Bold"
                           Foreground="{StaticResource TextWhite}" VerticalAlignment="Center"/>
              </DockPanel>
            </Border>

            <Grid Grid.Row="1" Margin="22,18,22,14">
              <StackPanel x:Name="viewDashboard" Visibility="Visible">
                <TextBlock Text="Welcome to Rom-Opti v3" FontSize="17" FontWeight="SemiBold" Foreground="{StaticResource TextWhite}"/>
                <TextBlock Margin="0,10,0,0" TextWrapping="Wrap" Foreground="{StaticResource TextMuted}" FontSize="13"
                  Text="A single-file Windows optimizer built for Rust. Pick a category from the sidebar, review tweaks with the (?) tooltips, then Execute or Undo selected changes. Run Hardware Scanner first for tailored advice."/>
                <Border Style="{StaticResource SoftCard}" Margin="0,22,0,0">
                  <StackPanel>
                    <TextBlock Text="Quick Start" FontWeight="SemiBold" Foreground="{StaticResource Accent}" FontSize="13"/>
                    <TextBlock Margin="0,8,0,0" Foreground="{StaticResource TextMuted}" FontSize="12" TextWrapping="Wrap"
                      Text="1. Hardware Scanner → Run Diagnostics&#10;2. Performance Tweaks → tick Create Restore Point&#10;3. Rust FPS Engine → Apply Recommended preset&#10;4. EXECUTE SELECTED → reboot when prompted"/>
                  </StackPanel>
                </Border>
              </StackPanel>

              <ScrollViewer x:Name="svOptions" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
                <WrapPanel x:Name="pnlOptions" Orientation="Horizontal" Width="740"/>
              </ScrollViewer>

              <Grid x:Name="viewHardware" Visibility="Collapsed">
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <TextBlock Text="Scan your hardware and get tailored BIOS/storage/RAM advice before applying aggressive tweaks."
                           Foreground="{StaticResource TextMuted}" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,14"/>
                <Button x:Name="btnRunDiagnostics" Grid.Row="1" Style="{StaticResource PrimaryButton}"
                        Content="Run Diagnostics" HorizontalAlignment="Left" Margin="0,0,0,14"/>
                <Border Grid.Row="2" Style="{StaticResource SoftCard}" Padding="14">
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <TextBox x:Name="txtHardwareAdvice" Background="Transparent" BorderThickness="0"
                             Foreground="{StaticResource TextMuted}" FontFamily="Consolas" FontSize="12"
                             IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True"
                             Text="Click Run Diagnostics to analyze your system."/>
                  </ScrollViewer>
                </Border>
              </Grid>
            </Grid>

            <Border Grid.Row="2" BorderBrush="{StaticResource BorderClr}" BorderThickness="0,1,0,0"
                    Background="#4406080C" CornerRadius="0,0,16,16" Padding="20,14">
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
        </Border>
      </Grid>
    </Grid>
  </Border>
</Window>
"@

# ---- 7. METEOR SHOWER ------------------------------------------------------
function New-ColorBrush([string]$Hex) {
    New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Hex))
}

function New-Meteor {
    param([double]$W, [double]$H)

    $isOrange = ($script:rng.Next(75) -eq 0)
    $len  = if ($isOrange) { $script:rng.Next(110, 200) } else { $script:rng.Next(70, 150) }
    $thk  = if ($isOrange) { 3.2 } else { 2.4 }
    $angle = 28 + $script:rng.Next(-4, 5)
    $rad   = $angle * [Math]::PI / 180

    $m = New-Object Windows.Controls.Canvas
    $m.Width = $len; $m.Height = $thk

    $rect = New-Object Windows.Shapes.Rectangle
    $rect.Width = $len; $rect.Height = $thk
    $rect.RadiusX = $thk / 2; $rect.RadiusY = $thk / 2

    $grad = New-Object Windows.Media.LinearGradientBrush
    $grad.StartPoint = '0,0.5'; $grad.EndPoint = '1,0.5'

    if ($isOrange) {
        $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(0, 255, 120, 20), 0.0)))
        $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(160, 255, 140, 40), 0.65)))
        $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(255, 255, 200, 80), 1.0)))
    } else {
        $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(0, 0, 220, 255), 0.0)))
        $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(180, 34, 211, 238), 0.68)))
        $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(255, 224, 255, 255), 1.0)))
    }
    $rect.Fill = $grad
    [Windows.Controls.Canvas]::SetLeft($rect, 0)
    [Windows.Controls.Canvas]::SetTop($rect, 0)
    $m.Children.Add($rect) | Out-Null

    $head = New-Object Windows.Shapes.Ellipse
    $hr = if ($isOrange) { 4.2 } else { 3.0 }
    $head.Width = $hr * 2; $head.Height = $hr * 2
    $head.Fill = if ($isOrange) { New-ColorBrush '#FFE08A' } else { New-ColorBrush '#F0FDFF' }

    $glow = New-Object Windows.Media.Effects.DropShadowEffect
    if ($isOrange) {
        $glow.Color = [Windows.Media.Color]::FromRgb(255, 140, 30)
        $glow.BlurRadius = 18; $glow.Opacity = 1.0
    } else {
        $glow.Color = [Windows.Media.Color]::FromRgb(34, 211, 238)
        $glow.BlurRadius = 16; $glow.Opacity = 0.95
    }
    $glow.ShadowDepth = 0
    $head.Effect = $glow

    [Windows.Controls.Canvas]::SetLeft($head, $len - $hr)
    [Windows.Controls.Canvas]::SetTop($head, ($thk / 2) - $hr)
    $m.Children.Add($head) | Out-Null

    $rot = New-Object Windows.Media.RotateTransform ($angle, 0, 0)
    $tt  = New-Object Windows.Media.TranslateTransform
    $tg  = New-Object Windows.Media.TransformGroup
    $tg.Children.Add($rot); $tg.Children.Add($tt)
    $m.RenderTransform = $tg

    $dist   = $H + $len + 320
    $startX = $script:rng.Next(-280, [int]$W)
    $startY = -1 * $script:rng.Next(40, 420)
    $endX   = $startX + $dist * [Math]::Cos($rad)
    $endY   = $startY + $dist * [Math]::Sin($rad)
    $dur    = if ($isOrange) { $script:rng.Next(32, 52) / 10 } else { $script:rng.Next(14, 30) / 10 }
    $delay  = $script:rng.Next(0, 80) / 10

    $ax = New-Object Windows.Media.Animation.DoubleAnimation
    $ax.From = $startX; $ax.To = $endX
    $ax.Duration = New-Object Windows.Duration ([TimeSpan]::FromSeconds($dur))
    $ax.BeginTime = [TimeSpan]::FromSeconds($delay)
    $ax.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever

    $ay = New-Object Windows.Media.Animation.DoubleAnimation
    $ay.From = $startY; $ay.To = $endY
    $ay.Duration = New-Object Windows.Duration ([TimeSpan]::FromSeconds($dur))
    $ay.BeginTime = [TimeSpan]::FromSeconds($delay)
    $ay.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever

    $tt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $ax)
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $ay)
    return $m
}

function Build-Sky {
    param($Canvas)

    $w = $Canvas.ActualWidth;  if ($w -lt 50) { $w = 1060 }
    $h = $Canvas.ActualHeight; if ($h -lt 50) { $h = 700 }
    $Canvas.Children.Clear()

    for ($i = 0; $i -lt 90; $i++) {
        $s = New-Object Windows.Shapes.Ellipse
        $r = $script:rng.Next(3, 12) / 10.0
        $s.Width = $r * 2; $s.Height = $r * 2
        $s.Fill = New-ColorBrush '#64748B'
        $s.Opacity = $script:rng.Next(6, 35) / 100.0
        [Windows.Controls.Canvas]::SetLeft($s, $script:rng.Next(0, [int]$w))
        [Windows.Controls.Canvas]::SetTop($s, $script:rng.Next(0, [int]$h))
        $Canvas.Children.Add($s) | Out-Null
    }

    for ($i = 0; $i -lt 30; $i++) {
        $Canvas.Children.Add((New-Meteor -W $w -H $h)) | Out-Null
    }
}

# ---- 8. LOAD UI ------------------------------------------------------------
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
$SkyCanvas         = $window.FindName('SkyCanvas')

# System info line
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Split('@')[0].Trim()
    $sysLine.Text = "$cpu  •  ${ram}GB RAM  •  $($os.Caption)"
} catch {
    $sysLine.Text = 'System info unavailable'
}

# ---- 9. UI STATE -----------------------------------------------------------
$script:CheckBoxes = @{}
$script:AppliedBrush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#4ADE80'))
$script:DefaultBrush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#FFFFFF'))
$script:AccentBrush  = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#22D3EE'))

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

    $card = New-Object Windows.Controls.Border
    $card.Background = New-ColorBrush '#550A0B10'
    $card.BorderBrush = New-ColorBrush '#181B24'
    $card.BorderThickness = '1'
    $card.CornerRadius = 12
    $card.Padding = '12,8'
    $card.Margin = '0,5,14,5'
    $card.Width = 352

    $container = New-Object Windows.Controls.StackPanel
    $container.Orientation = 'Horizontal'

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
    $card.Child = $container

    $script:CheckBoxes[$Tweak.Id] = $cb
    return $card
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

# ---- 10. EVENT WIRING ------------------------------------------------------
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

# ---- 11. START -------------------------------------------------------------
$window.Add_Loaded({
    Build-Sky $SkyCanvas
    Show-Category 'Dashboard'
    Write-Log 'Rom-Opti v3 ready. Run Hardware Scanner first for tailored advice.' 'accent'
    Write-Log 'Watch the sky — bright cyan meteors, with a rare orange streak.' 'info'

    foreach ($t in $Tweaks) {
        try {
            if (& $t.Check) {
                Write-Log "Already optimized: $($t.Name)" 'ok'
            }
        } catch { }
    }
})

$window.Add_SizeChanged({
    if ($SkyCanvas.ActualWidth -gt 50) { Build-Sky $SkyCanvas }
})

$window.ShowDialog() | Out-Null
