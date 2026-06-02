#Requires -Version 5.1
<#
  ===========================================================================
   ROM OPTI  -  Windows Optimizer & Rust FPS Tuner
   Multi-page WPF utility with an animated meteor-shower background.
   Inspired by the simplicity of Chris Titus WinUtil.

   RUN:  double-click Run-RomOpti.bat   (auto-elevates + bypasses policy)
         ...or right-click Rom-Opti.ps1 -> Run with PowerShell

   Every change is reversible via Windows System Restore. The "Create Restore
   Point" option is ON by default and always runs first.
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
function Set-ServiceState {
    param([string]$Name, [ValidateSet('Disabled','Manual','Automatic')]$Startup, [switch]$Stop)
    if (Get-Service -Name $Name -ErrorAction SilentlyContinue) {
        if ($Stop) { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        Set-Service -Name $Name -StartupType $Startup -ErrorAction SilentlyContinue
    }
}

# ---- 4. TWEAK REGISTRY (UI is generated from this) -------------------------
$Tweaks = @(
#region PREFERENCES
 [pscustomobject]@{ Id='pref_dark'; Category='Preferences'; Name='Enable Dark Mode'; Recommended=$true; ExplorerRestart=$true
   Desc='Switches Windows apps and the system UI (taskbar, Start, Settings) to the dark theme in one click.'
   Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 0
           Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0 } }
 [pscustomobject]@{ Id='pref_light'; Category='Preferences'; Name='Enable Light Mode'; ExplorerRestart=$true
   Desc='The opposite of dark mode. Restores the bright/white Windows theme. (Do not tick both.)'
   Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 1
           Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 1 } }
 [pscustomobject]@{ Id='pref_ext'; Category='Preferences'; Name='Show File Extensions'; Recommended=$true; ExplorerRestart=$true
   Desc='Reveals file types like .exe, .txt, .cfg in Explorer. Important for spotting fake/malicious files.'
   Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0 } }
 [pscustomobject]@{ Id='pref_hidden'; Category='Preferences'; Name='Show Hidden Files'; ExplorerRestart=$true
   Desc='Makes hidden files and folders visible (e.g. AppData, game config folders).'
   Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden' 1 } }
 [pscustomobject]@{ Id='pref_tbleft'; Category='Preferences'; Name='Left-Align Taskbar (Win11)'; ExplorerRestart=$true
   Desc='Moves the Windows 11 taskbar icons and Start button back to the left, classic style.'
   Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl' 0 } }
 [pscustomobject]@{ Id='pref_widgets'; Category='Preferences'; Name='Hide Taskbar Widgets'; Recommended=$true; ExplorerRestart=$true
   Desc='Removes the news/weather Widgets button. It runs background processes you do not need while gaming.'
   Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
           Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 } }
 [pscustomobject]@{ Id='pref_search'; Category='Preferences'; Name='Disable Bing/Web Search in Start'; Recommended=$true; ExplorerRestart=$true
   Desc='Stops the Start menu search from querying the internet, making it instant and local-only.'
   Apply={ Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
           Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0 } }
 [pscustomobject]@{ Id='pref_context'; Category='Preferences'; Name='Classic Right-Click Menu (Win11)'; ExplorerRestart=$true
   Desc='Brings back the full Windows 10 context menu, removing the extra "Show more options" click.'
   Apply={ $k='HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
           New-Item $k -Force | Out-Null; Set-ItemProperty -Path $k -Name '(Default)' -Value '' -Force } }
 [pscustomobject]@{ Id='pref_trans'; Category='Preferences'; Name='Disable Transparency Effects'
   Desc='Turns off blur/acrylic transparency on the taskbar and windows. Small GPU/CPU saving.'
   Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0 } }
 [pscustomobject]@{ Id='pref_thispc'; Category='Preferences'; Name='Open Explorer to "This PC"'; ExplorerRestart=$true
   Desc='Makes File Explorer open to "This PC" (drives) instead of Quick Access.'
   Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1 } }
 [pscustomobject]@{ Id='pref_seconds'; Category='Preferences'; Name='Show Seconds in Taskbar Clock'; ExplorerRestart=$true
   Desc='Displays seconds on the taskbar clock. Handy for timing in-game events.'
   Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSecondsInSystemClock' 1 } }
 [pscustomobject]@{ Id='pref_verbose'; Category='Preferences'; Name='Verbose Startup/Shutdown Messages'
   Desc='Shows detailed status text on boot/shutdown instead of a blank spinner.'
   Apply={ Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'VerboseStatus' 1 } }
#endregion
#region TWEAKS
 [pscustomobject]@{ Id='tw_restore'; Category='Tweaks'; Name='Create Restore Point (do this first)'; Default=$true; Recommended=$true
   Desc='Creates a System Restore point so you can roll back every change. Highly recommended.'
   Apply={ Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue
           Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
           Checkpoint-Computer -Description 'Rom Opti' -RestorePointType 'MODIFY_SETTINGS' } }
 [pscustomobject]@{ Id='tw_temp'; Category='Tweaks'; Name='Delete Temporary Files'; Recommended=$true
   Desc='Clears user and Windows temp folders to free disk space. Safe to run anytime.'
   Apply={ Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
           Remove-Item "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue } }
 [pscustomobject]@{ Id='tw_telemetry'; Category='Tweaks'; Name='Disable Telemetry'; Recommended=$true
   Desc='Stops Windows from sending diagnostic/usage data and disables the DiagTrack service.'
   Apply={ Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
           Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
           Set-ServiceState -Name 'DiagTrack' -Startup Disabled -Stop
           Set-ServiceState -Name 'dmwappushservice' -Startup Disabled -Stop } }
 [pscustomobject]@{ Id='tw_consumer'; Category='Tweaks'; Name='Disable Consumer Features'; Recommended=$true
   Desc='Stops Windows auto-installing promoted/sponsored apps and ads on your account.'
   Apply={ Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1 } }
 [pscustomobject]@{ Id='tw_activity'; Category='Tweaks'; Name='Disable Activity History'; Recommended=$true
   Desc='Stops Windows collecting and uploading your Timeline activity history.'
   Apply={ Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
           Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
           Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0 } }
 [pscustomobject]@{ Id='tw_folder'; Category='Tweaks'; Name='Disable Auto Folder Type Discovery'
   Desc='Stops Explorer auto-detecting folder types, which causes lag in large folders.'
   Apply={ $p='HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'
           Set-Reg $p 'FolderType' 'NotSpecified' 'String' } }
 [pscustomobject]@{ Id='tw_gamedvr'; Category='Tweaks'; Name='Disable Game DVR / Recording'; Recommended=$true
   Desc='Disables background game recording. Frees CPU/GPU overhead and can improve in-game FPS.'
   Apply={ Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
           Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
           Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 } }
 [pscustomobject]@{ Id='tw_hibernate'; Category='Tweaks'; Name='Disable Hibernation'
   Desc='Turns off hibernation and deletes hiberfil.sys (can reclaim several GB on SSD).'
   Apply={ powercfg.exe -h off | Out-Null } }
 [pscustomobject]@{ Id='tw_location'; Category='Tweaks'; Name='Disable Location Tracking'; Recommended=$true
   Desc='Blocks the system location service so apps cannot read your physical location.'
   Apply={ Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String'
           Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration' 'Status' 0 } }
 [pscustomobject]@{ Id='tw_storage'; Category='Tweaks'; Name='Disable Storage Sense'
   Desc='Disables Storage Sense so Windows does not auto-delete files/temp data in the background.'
   Apply={ Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' 'AllowStorageSenseGlobal' 0 } }
 [pscustomobject]@{ Id='tw_wifi'; Category='Tweaks'; Name='Disable Wi-Fi Sense'
   Desc='Stops Windows auto-connecting to and sharing open Wi-Fi hotspots.'
   Apply={ Set-Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting' 'value' 0
           Set-Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots' 'value' 0 } }
 [pscustomobject]@{ Id='tw_endtask'; Category='Tweaks'; Name='Enable "End Task" on Right-Click'; Recommended=$true; ExplorerRestart=$true
   Desc='Adds an End Task option to the taskbar right-click menu to instantly kill a frozen game.'
   Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\TaskbarDeveloperSettings' 'TaskbarEndTask' 1 } }
 [pscustomobject]@{ Id='tw_pwsh7'; Category='Tweaks'; Name='Disable PowerShell 7 Telemetry'
   Desc='Sets the system-wide opt-out flag so PowerShell 7 stops sending telemetry.'
   Apply={ [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT','1','Machine') } }
 [pscustomobject]@{ Id='tw_advid'; Category='Tweaks'; Name='Disable Advertising ID'; Recommended=$true
   Desc='Disables the per-user advertising ID used to personalize ads across apps.'
   Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 } }
 [pscustomobject]@{ Id='tw_tips'; Category='Tweaks'; Name='Disable Tips, Ads & Suggestions'; Recommended=$true
   Desc='Removes Start menu app suggestions, lock-screen tips, and Windows tip popups.'
   Apply={ $c='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
           'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-338393Enabled',
           'SystemPaneSuggestionsEnabled','SilentInstalledAppsEnabled','SoftLandingEnabled' |
           ForEach-Object { Set-Reg $c $_ 0 } } }
 [pscustomobject]@{ Id='tw_services'; Category='Tweaks'; Name='Set Non-Essential Services to Manual'
   Desc='Sets a curated, safe list of rarely-used services (Fax, Retail Demo, Maps Broker, etc.) to Manual.'
   Apply={ 'Fax','RetailDemo','MapsBroker','PcaSvc','WMPNetworkSvc','RemoteRegistry','WbioSrvc' |
           ForEach-Object { Set-ServiceState -Name $_ -Startup Manual } } }
#endregion
#region RUST
 [pscustomobject]@{ Id='r_ultimate'; Category='Rust'; Name='Activate "Ultimate Performance" Power Plan'; Recommended=$true
   Desc='Unlocks and switches to the hidden Ultimate Performance plan so the CPU never down-clocks. Best on desktop / plugged-in.'
   Apply={ $o = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null
           if ($o -match '([0-9a-fA-F-]{36})') { powercfg -setactive $Matches[1] | Out-Null } } }
 [pscustomobject]@{ Id='r_unpark'; Category='Rust'; Name='Disable CPU Core Parking'; Recommended=$true
   Desc='Keeps all CPU cores active instead of parking to save power. Reduces stutter in CPU-heavy Rust scenes.'
   Apply={ $g='0cc5b647-c1df-4637-891a-dec35c318583'
           powercfg -setacvalueindex scheme_current sub_processor $g 100 | Out-Null
           powercfg -setdcvalueindex scheme_current sub_processor $g 100 | Out-Null
           powercfg -setactive scheme_current | Out-Null } }
 [pscustomobject]@{ Id='r_throttle'; Category='Rust'; Name='Disable Power Throttling'; Recommended=$true
   Desc='Stops Windows throttling CPU power to apps, keeping the game at full clocks.'
   Apply={ Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1 } }
 [pscustomobject]@{ Id='r_hags'; Category='Rust'; Name='Enable GPU Hardware-Accelerated Scheduling'; Recommended=$true
   Desc='Lets the GPU manage its own scheduling, which can lower latency and raise FPS on modern GPUs. Reboot required.'
   Apply={ Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2 } }
 [pscustomobject]@{ Id='r_gamemode'; Category='Rust'; Name='Enable Windows Game Mode'; Recommended=$true
   Desc='Tells Windows to prioritize the foreground game and pause background updates while playing.'
   Apply={ Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
           Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1 } }
 [pscustomobject]@{ Id='r_gamebar'; Category='Rust'; Name='Disable Xbox Game Bar Overlay'; Recommended=$true
   Desc='Disables the Xbox Game Bar overlay (Win+G). It hooks every game and adds input lag / overhead.'
   Apply={ Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
           Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0
           Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 } }
 [pscustomobject]@{ Id='r_mmcss'; Category='Rust'; Name='Prioritize Games in Scheduler (MMCSS)'; Recommended=$true
   Desc='Tunes the multimedia scheduler to give games top GPU/CPU priority and lowest background interference.'
   Apply={ $sp='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
           Set-Reg $sp 'SystemResponsiveness' 10
           $games="$sp\Tasks\Games"
           Set-Reg $games 'GPU Priority' 8
           Set-Reg $games 'Priority' 6
           Set-Reg $games 'Scheduling Category' 'High' 'String'
           Set-Reg $games 'SFIO Priority' 'High' 'String' } }
 [pscustomobject]@{ Id='r_netthrottle'; Category='Rust'; Name='Disable Network Throttling'; Recommended=$true
   Desc='Removes the default packet throttle so multiplayer traffic is never artificially limited.'
   Apply={ Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' 4294967295 } }
 [pscustomobject]@{ Id='r_nagle'; Category='Rust'; Name="Disable Nagle's Algorithm (lower ping)"; Recommended=$true
   Desc='Disables TCP packet-batching across your adapters, reducing latency spikes in online shooters.'
   Apply={ $base='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
           Get-ChildItem $base | ForEach-Object {
               Set-ItemProperty -Path $_.PSPath -Name 'TcpAckFrequency' -Value 1 -Type DWord -Force
               Set-ItemProperty -Path $_.PSPath -Name 'TCPNoDelay' -Value 1 -Type DWord -Force } } }
 [pscustomobject]@{ Id='r_mouse'; Category='Rust'; Name='Disable Mouse Acceleration (raw aim)'; Recommended=$true
   Desc='Turns off Enhance Pointer Precision so aim is 1:1 and consistent - critical for Rust gunplay.'
   Apply={ Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
           Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
           Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String' } }
 [pscustomobject]@{ Id='r_visualfx'; Category='Rust'; Name='Set Visual Effects to Best Performance'
   Desc='Disables window animations, fades and shadows to free RAM/GPU for the game.'
   Apply={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2 } }
 [pscustomobject]@{ Id='r_fso'; Category='Rust'; Name='Disable Fullscreen Optimizations (global)'
   Desc='Forces true exclusive fullscreen behaviour, which can reduce input lag and stutter.'
   Apply={ $g='HKCU:\System\GameConfigStore'
           Set-Reg $g 'GameDVR_FSEBehaviorMode' 2
           Set-Reg $g 'GameDVR_HonorUserFSEBehaviorMode' 1
           Set-Reg $g 'GameDVR_DXGIHonorFSEWindowsCompatible' 1
           Set-Reg $g 'GameDVR_EFSEFeatureFlags' 0 } }
 [pscustomobject]@{ Id='r_sysmain'; Category='Rust'; Name='Disable SysMain (Superfetch)'
   Desc='Disables SysMain prefetch. Recommended ONLY on SSD/NVMe - stops background disk thrashing. Skip on a slow HDD.'
   Apply={ Set-ServiceState -Name 'SysMain' -Startup Disabled -Stop } }
 [pscustomobject]@{ Id='r_launch'; Category='Rust'; Name='Copy Recommended Rust Launch Options'
   Desc='Copies a tuned Steam launch-options string to your clipboard. Paste into Steam > Rust > Properties > Launch Options.'
   Apply={ '-high -maxMem=16384 -malloc=system -force-d3d11-no-singlethreaded -window-mode exclusive' | Set-Clipboard } }
#endregion
#region DEBLOAT
 [pscustomobject]@{ Id='db_apps'; Category='Debloat'; Name='Remove Bloatware Apps'; Recommended=$true
   Desc='Uninstalls unused preinstalled apps: 3D Builder/Viewer, Bing News/Weather, Get Help, Solitaire, Maps, People, Mixed Reality, Feedback Hub, Skype, Zune, Clipchamp. Keeps Store, Calculator, Photos.'
   Apply={ 'Microsoft.3DBuilder','Microsoft.Microsoft3DViewer','Microsoft.BingNews','Microsoft.BingWeather',
           'Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.MicrosoftSolitaireCollection','Microsoft.WindowsMaps',
           'Microsoft.People','Microsoft.MixedReality.Portal','Microsoft.WindowsFeedbackHub','Microsoft.SkypeApp',
           'Microsoft.ZuneMusic','Microsoft.ZuneVideo','Clipchamp.Clipchamp' |
           ForEach-Object { Get-AppxPackage -Name $_ -AllUsers -ErrorAction SilentlyContinue |
                            Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue } } }
 [pscustomobject]@{ Id='db_xbox'; Category='Debloat'; Name='Remove Xbox Apps (keep for Game Pass)'
   Desc='Removes Xbox companion apps & overlays. SAFE for Steam games like Rust. Do NOT tick if you play Game Pass / Store games.'
   Apply={ 'Microsoft.XboxApp','Microsoft.XboxGameOverlay','Microsoft.XboxGamingOverlay',
           'Microsoft.XboxSpeechToTextOverlay','Microsoft.Xbox.TCUI' |
           ForEach-Object { Get-AppxPackage -Name $_ -AllUsers -ErrorAction SilentlyContinue |
                            Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue } } }
 [pscustomobject]@{ Id='db_copilot'; Category='Debloat'; Name='Disable Windows Copilot'; Recommended=$true
   Desc='Turns off the built-in Windows Copilot AI assistant and removes its taskbar button.'
   Apply={ Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
           Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 } }
 [pscustomobject]@{ Id='db_tasks'; Category='Debloat'; Name='Disable Telemetry Scheduled Tasks'; Recommended=$true
   Desc='Disables background tasks that collect compatibility/usage data.'
   Apply={ '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
           '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
           '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
           '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip' |
           ForEach-Object { Disable-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue | Out-Null } } }
 [pscustomobject]@{ Id='db_onedrive'; Category='Debloat'; Name='Uninstall OneDrive (advanced)'
   Desc='Runs the built-in OneDrive uninstaller. Only tick this if you do NOT use OneDrive to sync files.'
   Apply={ $od="$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
           if (-not (Test-Path $od)) { $od="$env:SystemRoot\System32\OneDriveSetup.exe" }
           if (Test-Path $od) { Start-Process $od '/uninstall' -Wait } } }
#endregion
)

# ---- 5. XAML (product-grade UI) -------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Title="Rom Opti" Height="840" Width="940" MinWidth="860" MinHeight="720"
        WindowStyle="None" ResizeMode="CanResize" AllowsTransparency="False"
        WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI Variable Text, Segoe UI" TextOptions.TextFormattingMode="Ideal"
        TextOptions.TextRenderingMode="ClearType" UseLayoutRounding="True" SnapsToDevicePixels="True">

  <shell:WindowChrome.WindowChrome>
    <shell:WindowChrome CaptionHeight="42" ResizeBorderThickness="6" CornerRadius="0"
                        GlassFrameThickness="0" UseAeroCaptionButtons="False"/>
  </shell:WindowChrome.WindowChrome>

  <Window.Background>
    <LinearGradientBrush StartPoint="0,0" EndPoint="0.4,1">
      <GradientStop Color="#05060A" Offset="0"/>
      <GradientStop Color="#0A0C12" Offset="0.5"/>
      <GradientStop Color="#070810" Offset="1"/>
    </LinearGradientBrush>
  </Window.Background>

  <Window.Resources>
    <!-- palette -->
    <Color x:Key="cAccent">#54C7E0</Color>
    <Color x:Key="cAccentHi">#7FE0F2</Color>
    <SolidColorBrush x:Key="Accent"   Color="#54C7E0"/>
    <SolidColorBrush x:Key="AccentHi" Color="#7FE0F2"/>
    <SolidColorBrush x:Key="Gold"     Color="#E6B45C"/>
    <SolidColorBrush x:Key="TextHi"   Color="#ECEEF2"/>
    <SolidColorBrush x:Key="Text"     Color="#C2C7CF"/>
    <SolidColorBrush x:Key="TextMut"  Color="#7A818B"/>
    <SolidColorBrush x:Key="Hair"     Color="#1C1F27"/>

    <!-- ===== minimal scrollbar ===== -->
    <Style x:Key="SbPage" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SbThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="t" CornerRadius="3" Background="#2B303B" Margin="2,1"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Background" Value="#3C4350"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb><Thumb Style="{StaticResource SbThumb}"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource SbPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource SbPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== standard button (animated) ===== -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource TextHi}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="8" Padding="{TemplateBinding Padding}"
                    BorderThickness="1" RenderTransformOrigin="0.5,0.5">
              <Border.Background><SolidColorBrush x:Name="bg" Color="#171A21"/></Border.Background>
              <Border.BorderBrush><SolidColorBrush x:Name="br" Color="#23272F"/></Border.BorderBrush>
              <Border.RenderTransform>
                <TransformGroup>
                  <ScaleTransform x:Name="sc" ScaleX="1" ScaleY="1"/>
                  <TranslateTransform x:Name="tt" Y="0"/>
                </TransformGroup>
              </Border.RenderTransform>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <EventTrigger RoutedEvent="MouseEnter">
                <BeginStoryboard><Storyboard>
                  <ColorAnimation Storyboard.TargetName="bg" Storyboard.TargetProperty="Color" To="#222732" Duration="0:0:0.14"/>
                  <ColorAnimation Storyboard.TargetName="br" Storyboard.TargetProperty="Color" To="#3A4250" Duration="0:0:0.14"/>
                  <DoubleAnimation Storyboard.TargetName="tt" Storyboard.TargetProperty="Y" To="-1.5" Duration="0:0:0.14"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <EventTrigger RoutedEvent="MouseLeave">
                <BeginStoryboard><Storyboard>
                  <ColorAnimation Storyboard.TargetName="bg" Storyboard.TargetProperty="Color" To="#171A21" Duration="0:0:0.18"/>
                  <ColorAnimation Storyboard.TargetName="br" Storyboard.TargetProperty="Color" To="#23272F" Duration="0:0:0.18"/>
                  <DoubleAnimation Storyboard.TargetName="tt" Storyboard.TargetProperty="Y" To="0" Duration="0:0:0.18"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <EventTrigger RoutedEvent="PreviewMouseLeftButtonDown">
                <BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="0.96" Duration="0:0:0.07"/>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="0.96" Duration="0:0:0.07"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <EventTrigger RoutedEvent="PreviewMouseLeftButtonUp">
                <BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.12"/>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.12"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== primary button (accent + glow) ===== -->
    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Foreground" Value="#04141A"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Padding" Value="18,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="8" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
              <Border.Background><SolidColorBrush x:Name="bg" Color="#54C7E0"/></Border.Background>
              <Border.Effect><DropShadowEffect x:Name="gl" Color="#54C7E0" BlurRadius="0" ShadowDepth="0" Opacity="0"/></Border.Effect>
              <Border.RenderTransform>
                <TransformGroup><ScaleTransform x:Name="sc" ScaleX="1" ScaleY="1"/><TranslateTransform x:Name="tt" Y="0"/></TransformGroup>
              </Border.RenderTransform>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <EventTrigger RoutedEvent="MouseEnter">
                <BeginStoryboard><Storyboard>
                  <ColorAnimation Storyboard.TargetName="bg" Storyboard.TargetProperty="Color" To="#7FE0F2" Duration="0:0:0.14"/>
                  <DoubleAnimation Storyboard.TargetName="gl" Storyboard.TargetProperty="BlurRadius" To="20" Duration="0:0:0.18"/>
                  <DoubleAnimation Storyboard.TargetName="gl" Storyboard.TargetProperty="Opacity" To="0.55" Duration="0:0:0.18"/>
                  <DoubleAnimation Storyboard.TargetName="tt" Storyboard.TargetProperty="Y" To="-1.5" Duration="0:0:0.14"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <EventTrigger RoutedEvent="MouseLeave">
                <BeginStoryboard><Storyboard>
                  <ColorAnimation Storyboard.TargetName="bg" Storyboard.TargetProperty="Color" To="#54C7E0" Duration="0:0:0.18"/>
                  <DoubleAnimation Storyboard.TargetName="gl" Storyboard.TargetProperty="BlurRadius" To="0" Duration="0:0:0.2"/>
                  <DoubleAnimation Storyboard.TargetName="gl" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.2"/>
                  <DoubleAnimation Storyboard.TargetName="tt" Storyboard.TargetProperty="Y" To="0" Duration="0:0:0.18"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <EventTrigger RoutedEvent="PreviewMouseLeftButtonDown">
                <BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="0.96" Duration="0:0:0.07"/>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="0.96" Duration="0:0:0.07"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <EventTrigger RoutedEvent="PreviewMouseLeftButtonUp">
                <BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.12"/>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.12"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== window caption buttons ===== -->
    <Style x:Key="Cap" TargetType="Button">
      <Setter Property="Width" Value="44"/><Setter Property="Height" Value="42"/>
      <Setter Property="Foreground" Value="#9097A1"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/><Setter Property="FontSize" Value="10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b"><Border.Background><SolidColorBrush x:Name="bg" Color="#00000000"/></Border.Background>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
              <EventTrigger RoutedEvent="MouseEnter"><BeginStoryboard><Storyboard>
                <ColorAnimation Storyboard.TargetName="bg" Storyboard.TargetProperty="Color" To="#1E222B" Duration="0:0:0.12"/></Storyboard></BeginStoryboard></EventTrigger>
              <EventTrigger RoutedEvent="MouseLeave"><BeginStoryboard><Storyboard>
                <ColorAnimation Storyboard.TargetName="bg" Storyboard.TargetProperty="Color" To="#00000000" Duration="0:0:0.16"/></Storyboard></BeginStoryboard></EventTrigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CapClose" TargetType="Button" BasedOn="{StaticResource Cap}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b"><Border.Background><SolidColorBrush x:Name="bg" Color="#00000000"/></Border.Background>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
              <EventTrigger RoutedEvent="MouseEnter"><BeginStoryboard><Storyboard>
                <ColorAnimation Storyboard.TargetName="bg" Storyboard.TargetProperty="Color" To="#E13D3D" Duration="0:0:0.12"/></Storyboard></BeginStoryboard></EventTrigger>
              <EventTrigger RoutedEvent="MouseLeave"><BeginStoryboard><Storyboard>
                <ColorAnimation Storyboard.TargetName="bg" Storyboard.TargetProperty="Color" To="#00000000" Duration="0:0:0.16"/></Storyboard></BeginStoryboard></EventTrigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== nav item (RadioButton) ===== -->
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Height" Value="44"/>
      <Setter Property="Foreground" Value="{StaticResource TextMut}"/>
      <Setter Property="FontSize" Value="13.5"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="12,2,12,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" CornerRadius="9" Padding="16,0">
              <Border.Background><SolidColorBrush x:Name="bg" Color="#00000000"/></Border.Background>
              <Grid>
                <Border x:Name="stripe" Width="3" Height="18" CornerRadius="2" HorizontalAlignment="Left"
                        Background="{StaticResource Accent}" Opacity="0" RenderTransformOrigin="0.5,0.5">
                  <Border.RenderTransform><ScaleTransform x:Name="ss" ScaleY="0.3"/></Border.RenderTransform>
                </Border>
                <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Left" Margin="14,0,0,0"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <EventTrigger RoutedEvent="MouseEnter"><BeginStoryboard><Storyboard>
                <ColorAnimation Storyboard.TargetName="bg" Storyboard.TargetProperty="Color" To="#15181F" Duration="0:0:0.12"/></Storyboard></BeginStoryboard></EventTrigger>
              <EventTrigger RoutedEvent="MouseLeave"><BeginStoryboard><Storyboard>
                <ColorAnimation Storyboard.TargetName="bg" Storyboard.TargetProperty="Color" To="#00000000" Duration="0:0:0.16"/></Storyboard></BeginStoryboard></EventTrigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background"><Setter.Value><SolidColorBrush Color="#16202A"/></Setter.Value></Setter>
                <Setter Property="Foreground" Value="{StaticResource TextHi}"/>
                <Trigger.EnterActions>
                  <BeginStoryboard><Storyboard>
                    <DoubleAnimation Storyboard.TargetName="stripe" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.2"/>
                    <DoubleAnimation Storyboard.TargetName="ss" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.26">
                      <DoubleAnimation.EasingFunction><BackEase Amplitude="0.6" EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                    </DoubleAnimation>
                  </Storyboard></BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard><Storyboard>
                    <DoubleAnimation Storyboard.TargetName="stripe" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.14"/>
                    <DoubleAnimation Storyboard.TargetName="ss" Storyboard.TargetProperty="ScaleY" To="0.3" Duration="0:0:0.14"/>
                  </Storyboard></BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== modern checkbox ===== -->
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="19" Height="19" CornerRadius="5" BorderThickness="1.6" VerticalAlignment="Center"
                      RenderTransformOrigin="0.5,0.5">
                <Border.Background><SolidColorBrush x:Name="bg" Color="#00000000"/></Border.Background>
                <Border.BorderBrush><SolidColorBrush x:Name="br" Color="#3A4150"/></Border.BorderBrush>
                <Border.RenderTransform><ScaleTransform x:Name="sc" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
                <Path x:Name="chk" Stretch="Uniform" Margin="3.5" Opacity="0"
                      Stroke="#04141A" StrokeThickness="2.4" StrokeEndLineCap="Round" StrokeStartLineCap="Round"
                      Data="M 2,9 L 7,14 L 16,3"/>
              </Border>
              <ContentPresenter x:Name="lbl" VerticalAlignment="Center" Margin="11,0,0,0" RecognizesAccessKey="True"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{StaticResource TextHi}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard><Storyboard>
                    <ColorAnimation Storyboard.TargetName="bg" Storyboard.TargetProperty="Color" To="#54C7E0" Duration="0:0:0.16"/>
                    <ColorAnimation Storyboard.TargetName="br" Storyboard.TargetProperty="Color" To="#54C7E0" Duration="0:0:0.16"/>
                    <DoubleAnimation Storyboard.TargetName="chk" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.14"/>
                    <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" From="0.7" To="1" Duration="0:0:0.22">
                      <DoubleAnimation.EasingFunction><BackEase Amplitude="0.7" EasingMode="EaseOut"/></DoubleAnimation.EasingFunction></DoubleAnimation>
                    <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" From="0.7" To="1" Duration="0:0:0.22">
                      <DoubleAnimation.EasingFunction><BackEase Amplitude="0.7" EasingMode="EaseOut"/></DoubleAnimation.EasingFunction></DoubleAnimation>
                  </Storyboard></BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard><Storyboard>
                    <ColorAnimation Storyboard.TargetName="bg" Storyboard.TargetProperty="Color" To="#00000000" Duration="0:0:0.14"/>
                    <ColorAnimation Storyboard.TargetName="br" Storyboard.TargetProperty="Color" To="#3A4150" Duration="0:0:0.14"/>
                    <DoubleAnimation Storyboard.TargetName="chk" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.1"/>
                  </Storyboard></BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== help badge (?) ===== -->
    <Style x:Key="Help" TargetType="Border">
      <Setter Property="Width" Value="17"/><Setter Property="Height" Value="17"/>
      <Setter Property="CornerRadius" Value="9"/><Setter Property="Margin" Value="9,0,0,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Cursor" Value="Help"/>
      <Setter Property="Background"><Setter.Value><SolidColorBrush Color="#1B1F27"/></Setter.Value></Setter>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush"><Setter.Value><SolidColorBrush Color="#2C323D"/></Setter.Value></Setter>
    </Style>

    <!-- tooltip -->
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#05070B"/>
      <Setter Property="Foreground" Value="#D7DCE3"/>
      <Setter Property="BorderBrush" Value="#54C7E0"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,10"/>
      <Setter Property="MaxWidth" Value="370"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="HasDropShadow" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <Border.Effect><DropShadowEffect Color="#000000" BlurRadius="18" ShadowDepth="3" Opacity="0.5"/></Border.Effect>
              <ContentPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextHi}"/><Setter Property="FontSize" Value="23"/><Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style x:Key="P" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextMut}"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="TextWrapping" Value="Wrap"/><Setter Property="LineHeight" Value="20"/>
    </Style>
  </Window.Resources>

  <!-- ROOT -->
  <Grid>
    <Canvas Name="SkyCanvas" IsHitTestVisible="False"/>

    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="42"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- TITLE BAR -->
      <Grid Grid.Row="0" Background="Transparent">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="20,0,0,0">
          <Ellipse Width="9" Height="9" Fill="{StaticResource Accent}" Margin="0,0,9,0"/>
          <TextBlock Text="ROM OPTI" Foreground="{StaticResource TextHi}" FontWeight="Bold" FontSize="13"/>
          <TextBlock Text="optimizer" Foreground="#5A616B" FontSize="11.5" Margin="8,1,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <Button Name="btnMin"   Style="{StaticResource Cap}"      shell:WindowChrome.IsHitTestVisibleInChrome="True" Content="&#xE921;"/>
          <Button Name="btnMax"   Style="{StaticResource Cap}"      shell:WindowChrome.IsHitTestVisibleInChrome="True" Content="&#xE922;"/>
          <Button Name="btnClose" Style="{StaticResource CapClose}" shell:WindowChrome.IsHitTestVisibleInChrome="True" Content="&#xE8BB;"/>
        </StackPanel>
      </Grid>

      <!-- BODY -->
      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions><ColumnDefinition Width="216"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

        <!-- SIDEBAR -->
        <Border Grid.Column="0" Background="#F00C0E13" BorderBrush="{StaticResource Hair}" BorderThickness="0,0,1,0">
          <DockPanel LastChildFill="False">
            <StackPanel DockPanel.Dock="Top" Margin="0,16,0,8">
              <RadioButton Name="navHome"    Style="{StaticResource Nav}" GroupName="nav" Content="Home"/>
              <RadioButton Name="navPref"    Style="{StaticResource Nav}" GroupName="nav" Content="Preferences"/>
              <RadioButton Name="navTweaks"  Style="{StaticResource Nav}" GroupName="nav" Content="Tweaks"/>
              <RadioButton Name="navRust"    Style="{StaticResource Nav}" GroupName="nav" Content="Rust FPS"/>
              <RadioButton Name="navDebloat" Style="{StaticResource Nav}" GroupName="nav" Content="Debloat"/>
              <RadioButton Name="navAbout"   Style="{StaticResource Nav}" GroupName="nav" Content="About"/>
            </StackPanel>
            <TextBlock DockPanel.Dock="Bottom" Margin="24,0,18,18" FontSize="10.5" Foreground="#454C55"
                       TextWrapping="Wrap" Text="v1.0  •  reversible via System Restore"/>
          </DockPanel>
        </Border>

        <!-- CONTENT -->
        <Grid Grid.Column="1" Margin="20,14,20,16">
          <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

          <Grid Grid.Row="0" Name="PageHost">
            <Border Name="pgHome" CornerRadius="14" Padding="36" Visibility="Visible"
                    Background="#F70F1118" BorderBrush="{StaticResource Hair}" BorderThickness="1">
              <StackPanel>
                <TextBlock Style="{StaticResource H1}" Text="Welcome to Rom Opti"/>
                <TextBlock Style="{StaticResource P}" Margin="0,12,0,0"
                  Text="A clean, one-click Windows optimizer and Rust FPS tuner. Pick a category on the left, hover the ? on any option to see exactly what it does, then hit Apply. Start with the Recommended preset for a safe, balanced setup."/>
                <StackPanel Orientation="Horizontal" Margin="0,28,0,0">
                  <Button Name="homeRecommend" Style="{StaticResource Primary}" Content="Apply Recommended Preset"/>
                  <Button Name="homeRust" Style="{StaticResource Btn}" Content="Open Rust FPS Tweaks" Margin="12,0,0,0"/>
                </StackPanel>
                <Border Margin="0,30,0,0" CornerRadius="11" Padding="20" Background="#12141B" BorderBrush="{StaticResource Hair}" BorderThickness="1">
                  <StackPanel>
                    <TextBlock Foreground="{StaticResource Gold}" FontWeight="SemiBold" FontSize="13" Text="How it works"/>
                    <TextBlock Style="{StaticResource P}" Margin="0,8,0,0"
                      Text="Preferences — dark mode, taskbar, Explorer and quality-of-life toggles.&#10;Tweaks — privacy, telemetry and the classic system cleanups.&#10;Rust FPS — power, GPU scheduling, latency and aim tuning for maximum frames.&#10;Debloat — remove unused preinstalled apps and background tasks.&#10;&#10;Leave 'Create Restore Point' ticked so you can always roll back."/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </Border>

            <Border Name="pgPref" CornerRadius="14" Padding="6" Visibility="Collapsed" Background="#F70F1118" BorderBrush="{StaticResource Hair}" BorderThickness="1">
              <DockPanel>
                <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="Preferences" Margin="26,20,0,2"/>
                <TextBlock DockPanel.Dock="Top" Style="{StaticResource P}" Margin="26,0,26,10" Text="Appearance and quality-of-life toggles."/>
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="26,4,18,16"><StackPanel Name="spPreferences"/></ScrollViewer>
              </DockPanel>
            </Border>
            <Border Name="pgTweaks" CornerRadius="14" Padding="6" Visibility="Collapsed" Background="#F70F1118" BorderBrush="{StaticResource Hair}" BorderThickness="1">
              <DockPanel>
                <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="Tweaks" Margin="26,20,0,2"/>
                <TextBlock DockPanel.Dock="Top" Style="{StaticResource P}" Margin="26,0,26,10" Text="Privacy, telemetry and classic system cleanups."/>
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="26,4,18,16"><StackPanel Name="spTweaks"/></ScrollViewer>
              </DockPanel>
            </Border>
            <Border Name="pgRust" CornerRadius="14" Padding="6" Visibility="Collapsed" Background="#F70F1118" BorderBrush="{StaticResource Hair}" BorderThickness="1">
              <DockPanel>
                <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="Rust FPS" Margin="26,20,0,2"/>
                <TextBlock DockPanel.Dock="Top" Style="{StaticResource P}" Margin="26,0,26,10" Text="Squeeze maximum frames and minimum latency out of Rust."/>
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="26,4,18,16"><StackPanel Name="spRust"/></ScrollViewer>
              </DockPanel>
            </Border>
            <Border Name="pgDebloat" CornerRadius="14" Padding="6" Visibility="Collapsed" Background="#F70F1118" BorderBrush="{StaticResource Hair}" BorderThickness="1">
              <DockPanel>
                <TextBlock DockPanel.Dock="Top" Style="{StaticResource H1}" Text="Debloat" Margin="26,20,0,2"/>
                <TextBlock DockPanel.Dock="Top" Style="{StaticResource P}" Margin="26,0,26,10" Text="Remove unused preinstalled apps and background tasks."/>
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="26,4,18,16"><StackPanel Name="spDebloat"/></ScrollViewer>
              </DockPanel>
            </Border>
            <Border Name="pgAbout" CornerRadius="14" Padding="36" Visibility="Collapsed" Background="#F70F1118" BorderBrush="{StaticResource Hair}" BorderThickness="1">
              <StackPanel>
                <TextBlock Style="{StaticResource H1}" Text="About Rom Opti"/>
                <TextBlock Style="{StaticResource P}" Margin="0,12,0,0"
                  Text="Rom Opti is a lightweight, single-file Windows utility for gamers. It applies well-known, documented registry and service tweaks - the same kinds used by popular open-source optimizers - wrapped in a clean interface with plain-English explanations on every option."/>
                <TextBlock Foreground="{StaticResource Gold}" FontWeight="SemiBold" Margin="0,24,0,0" Text="Safety"/>
                <TextBlock Style="{StaticResource P}" Margin="0,8,0,0"
                  Text="Nothing here is destructive, but system tweaks always carry some risk. Keep 'Create Restore Point' ticked, and if anything feels off you can roll back from Windows System Restore. A reboot is recommended after applying."/>
                <TextBlock Foreground="{StaticResource Gold}" FontWeight="SemiBold" Margin="0,24,0,0" Text="Tip"/>
                <TextBlock Style="{StaticResource P}" Margin="0,8,0,0"
                  Text="Watch the sky - most meteors burn cyan, but every so often a golden one drifts past."/>
              </StackPanel>
            </Border>
          </Grid>

          <!-- ACTION BAR -->
          <Border Grid.Row="1" Margin="0,14,0,0" CornerRadius="13" Padding="14,11" Background="#F00B0D13" BorderBrush="{StaticResource Hair}" BorderThickness="1">
            <StackPanel Orientation="Horizontal">
              <Button Name="btnRecommend" Style="{StaticResource Btn}" Content="Recommended"/>
              <Button Name="btnAll"  Style="{StaticResource Btn}" Content="Select All" Margin="9,0,0,0"/>
              <Button Name="btnNone" Style="{StaticResource Btn}" Content="Clear All"  Margin="9,0,0,0"/>
              <Button Name="btnApply" Style="{StaticResource Primary}" Content="APPLY SELECTED" Margin="9,0,0,0"/>
            </StackPanel>
          </Border>

          <!-- LOG -->
          <Border Grid.Row="2" Margin="0,11,0,0" Height="120" CornerRadius="13" Padding="6" Background="#F0070810" BorderBrush="{StaticResource Hair}" BorderThickness="1">
            <ScrollViewer Name="logScroll" VerticalScrollBarVisibility="Auto" Padding="14,8"><ItemsControl Name="lstLog"/></ScrollViewer>
          </Border>
        </Grid>
      </Grid>
    </Grid>
  </Grid>
</Window>
'@

# ---- 6. LOAD + WIRE --------------------------------------------------------
try {
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    [System.Windows.MessageBox]::Show("UI failed to load:`n$($_.Exception.Message)","Rom Opti") | Out-Null
    exit
}

$SkyCanvas = $window.FindName('SkyCanvas')
$lstLog    = $window.FindName('lstLog')
$logScroll = $window.FindName('logScroll')

function B($hex) { New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex)) }
$c_ok=B '#62E08C'; $c_err=B '#F2706F'; $c_warn=B '#E6B45C'; $c_info=B '#828A94'; $c_accent=B '#54C7E0'

function Write-Log {
    param([string]$msg, [string]$kind='info')
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text=$msg; $tb.TextWrapping='Wrap'; $tb.FontSize=12; $tb.Margin='0,1.5,0,1.5'; $tb.FontFamily='Cascadia Mono, Consolas'
    $tb.Foreground = switch ($kind) { 'ok'{$c_ok} 'err'{$c_err} 'warn'{$c_warn} 'accent'{$c_accent} default{$c_info} }
    $tb.Opacity=0
    $lstLog.Items.Add($tb) | Out-Null
    $fade = New-Object Windows.Media.Animation.DoubleAnimation 0,1,(New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(260)))
    $tb.BeginAnimation([Windows.UIElement]::OpacityProperty,$fade)
    $logScroll.ScrollToEnd()
}
function DoEvents {
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $null = $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ $frame.Continue=$false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

# ---- METEOR SHOWER (parallax layers + fade + twinkle + rare gold) ----------
function New-Meteor {
    param($w, $h, $layer)   # layer 1=far 2=mid 3=near
    $isGold = ($script:rng.NextDouble() -lt 0.10)
    switch ($layer) {
        1 { $lmin=30;$lmax=70;  $thk=1.1; $base=0.34; $dmin=22;$dmax=34 }
        2 { $lmin=55;$lmax=105; $thk=1.7; $base=0.62; $dmin=15;$dmax=25 }
        default { $lmin=85;$lmax=150;$thk=2.4; $base=0.92; $dmin=11;$dmax=19 }
    }
    $len = if ($isGold) { [int]($lmax*1.25) } else { $script:rng.Next($lmin,$lmax) }
    if ($isGold) { $thk += 0.7; $base = [Math]::Min(1.0,$base+0.1) }
    $angle = 26 + $script:rng.Next(-4,5)
    $rad = $angle * [Math]::PI / 180

    $m = New-Object Windows.Controls.Canvas
    $m.Width=$len; $m.Height=$thk

    $rect = New-Object Windows.Shapes.Rectangle
    $rect.Width=$len; $rect.Height=$thk; $rect.RadiusX=$thk/2; $rect.RadiusY=$thk/2
    $grad = New-Object Windows.Media.LinearGradientBrush
    $grad.StartPoint='0,0.5'; $grad.EndPoint='1,0.5'
    if ($isGold) {
        $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(0,255,196,90),0.0)))
        $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(110,255,202,108),0.7)))
        $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(255,255,236,176),1.0)))
    } else {
        $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(0,120,210,240),0.0)))
        $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(105,150,225,248),0.72)))
        $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(245,228,250,255),1.0)))
    }
    $rect.Fill=$grad
    [Windows.Controls.Canvas]::SetLeft($rect,0); [Windows.Controls.Canvas]::SetTop($rect,0)
    $m.Children.Add($rect) | Out-Null

    $head = New-Object Windows.Shapes.Ellipse
    $hr = if ($isGold) { 3.6 } else { ($thk*0.9)+1.1 }
    $head.Width=$hr*2; $head.Height=$hr*2
    $head.Fill = if ($isGold) { B '#FFF1CC' } else { B '#E9FAFF' }
    if ($isGold -or $layer -eq 3) {
        $glow = New-Object Windows.Media.Effects.DropShadowEffect
        $glow.Color = if ($isGold) { [Windows.Media.Color]::FromRgb(255,196,92) } else { [Windows.Media.Color]::FromRgb(120,220,240) }
        $glow.BlurRadius = if ($isGold) { 16 } else { 9 }; $glow.ShadowDepth=0; $glow.Opacity=0.9
        $head.Effect=$glow
    }
    [Windows.Controls.Canvas]::SetLeft($head, $len-$hr); [Windows.Controls.Canvas]::SetTop($head, ($thk/2)-$hr)
    $m.Children.Add($head) | Out-Null

    $rot = New-Object Windows.Media.RotateTransform ($angle,0,0)
    $tt  = New-Object Windows.Media.TranslateTransform
    $tg  = New-Object Windows.Media.TransformGroup
    $tg.Children.Add($rot); $tg.Children.Add($tt)
    $m.RenderTransform=$tg

    $dist=$h+$len+300
    $startX=$script:rng.Next(-340,[int]$w)
    $startY=-1*$script:rng.Next(60,420)
    $endX=$startX+$dist*[Math]::Cos($rad)
    $endY=$startY+$dist*[Math]::Sin($rad)
    $dur  = if ($isGold) { $script:rng.Next(($dmax+8),($dmax+20))/10 } else { $script:rng.Next($dmin,$dmax)/10 }
    $delay= $script:rng.Next(0,90)/10
    $durObj = New-Object Windows.Duration ([TimeSpan]::FromSeconds($dur))
    $beg = [TimeSpan]::FromSeconds($delay)

    $ax=New-Object Windows.Media.Animation.DoubleAnimation; $ax.From=$startX; $ax.To=$endX; $ax.Duration=$durObj; $ax.BeginTime=$beg; $ax.RepeatBehavior=[Windows.Media.Animation.RepeatBehavior]::Forever
    $ay=New-Object Windows.Media.Animation.DoubleAnimation; $ay.From=$startY; $ay.To=$endY; $ay.Duration=$durObj; $ay.BeginTime=$beg; $ay.RepeatBehavior=[Windows.Media.Animation.RepeatBehavior]::Forever
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty,$ax)
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$ay)

    # fade in/out so trails never pop
    $op=New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $op.Duration=$durObj; $op.BeginTime=$beg; $op.RepeatBehavior=[Windows.Media.Animation.RepeatBehavior]::Forever
    $op.KeyFrames.Add((New-Object Windows.Media.Animation.LinearDoubleKeyFrame(0.0,[Windows.Media.Animation.KeyTime]::FromPercent(0.0)))) | Out-Null
    $op.KeyFrames.Add((New-Object Windows.Media.Animation.LinearDoubleKeyFrame($base,[Windows.Media.Animation.KeyTime]::FromPercent(0.14)))) | Out-Null
    $op.KeyFrames.Add((New-Object Windows.Media.Animation.LinearDoubleKeyFrame($base,[Windows.Media.Animation.KeyTime]::FromPercent(0.74)))) | Out-Null
    $op.KeyFrames.Add((New-Object Windows.Media.Animation.LinearDoubleKeyFrame(0.0,[Windows.Media.Animation.KeyTime]::FromPercent(1.0)))) | Out-Null
    $m.BeginAnimation([Windows.UIElement]::OpacityProperty,$op)
    return $m
}

function New-Star {
    param($w,$h)
    $s=New-Object Windows.Shapes.Ellipse
    $r=$script:rng.Next(4,13)/10
    $s.Width=$r*2; $s.Height=$r*2; $s.Fill=B '#AFC9D8'
    $baseOp=$script:rng.Next(7,40)/100
    $s.Opacity=$baseOp
    [Windows.Controls.Canvas]::SetLeft($s,$script:rng.Next(0,[int]$w))
    [Windows.Controls.Canvas]::SetTop($s,$script:rng.Next(0,[int]$h))
    if ($script:rng.NextDouble() -lt 0.34) {   # ~1/3 twinkle
        $tw=New-Object Windows.Media.Animation.DoubleAnimation
        $tw.From=$baseOp*0.3; $tw.To=[Math]::Min(0.85,$baseOp+0.3)
        $tw.Duration=New-Object Windows.Duration ([TimeSpan]::FromSeconds($script:rng.Next(14,40)/10))
        $tw.BeginTime=[TimeSpan]::FromSeconds($script:rng.Next(0,40)/10)
        $tw.AutoReverse=$true; $tw.RepeatBehavior=[Windows.Media.Animation.RepeatBehavior]::Forever
        $ease=New-Object Windows.Media.Animation.SineEase; $ease.EasingMode='EaseInOut'; $tw.EasingFunction=$ease
        $s.BeginAnimation([Windows.UIElement]::OpacityProperty,$tw)
    }
    return $s
}

function Build-Sky {
    $w=$SkyCanvas.ActualWidth;  if ($w -lt 50){$w=940}
    $h=$SkyCanvas.ActualHeight; if ($h -lt 50){$h=840}
    $SkyCanvas.Children.Clear()
    for ($i=0;$i -lt 110;$i++){ $SkyCanvas.Children.Add((New-Star -w $w -h $h)) | Out-Null }
    $layerCounts = [ordered]@{ 1=11; 2=10; 3=8 }   # far / mid / near
    foreach ($layer in $layerCounts.Keys) {
        for ($i=0;$i -lt $layerCounts[$layer];$i++){ $SkyCanvas.Children.Add((New-Meteor -w $w -h $h -layer ([int]$layer))) | Out-Null }
    }
}

# ---- CHECKBOX LISTS --------------------------------------------------------
$panels=@{ Preferences=$window.FindName('spPreferences'); Tweaks=$window.FindName('spTweaks'); Rust=$window.FindName('spRust'); Debloat=$window.FindName('spDebloat') }
$helpStyle=$window.TryFindResource('Help')
$CheckBoxes=@{}
foreach ($t in $Tweaks) {
    $row=New-Object Windows.Controls.StackPanel; $row.Orientation='Horizontal'; $row.Margin='0,6,0,6'
    $cb=New-Object Windows.Controls.CheckBox; $cb.Content=$t.Name; $cb.VerticalAlignment='Center'
    if ($t.PSObject.Properties.Name -contains 'Default' -and $t.Default){ $cb.IsChecked=$true }
    $badge=New-Object Windows.Controls.Border; $badge.Style=$helpStyle; $badge.ToolTip=$t.Desc
    $qm=New-Object Windows.Controls.TextBlock; $qm.Text='?'; $qm.FontSize=11; $qm.FontWeight='Bold'
    $qm.Foreground=$c_accent; $qm.HorizontalAlignment='Center'; $qm.VerticalAlignment='Center'
    $badge.Child=$qm
    [Windows.Controls.ToolTipService]::SetInitialShowDelay($badge,140)
    [Windows.Controls.ToolTipService]::SetShowDuration($badge,60000)
    $row.AddChild($cb); $row.AddChild($badge)
    $panels[$t.Category].AddChild($row)
    $CheckBoxes[$t.Id]=$cb
}

# ---- NAVIGATION (animated page transition) ---------------------------------
$pages=@{ Home=$window.FindName('pgHome'); Preferences=$window.FindName('pgPref'); Tweaks=$window.FindName('pgTweaks'); Rust=$window.FindName('pgRust'); Debloat=$window.FindName('pgDebloat'); About=$window.FindName('pgAbout') }
$navs =@{ Home=$window.FindName('navHome'); Preferences=$window.FindName('navPref'); Tweaks=$window.FindName('navTweaks'); Rust=$window.FindName('navRust'); Debloat=$window.FindName('navDebloat'); About=$window.FindName('navAbout') }
function Show-Page($name){
    foreach($k in $pages.Keys){ $pages[$k].Visibility='Collapsed' }
    $p=$pages[$name]; $p.Visibility='Visible'
    $tt=New-Object Windows.Media.TranslateTransform; $p.RenderTransform=$tt
    $ease=New-Object Windows.Media.Animation.CubicEase; $ease.EasingMode='EaseOut'
    $fade=New-Object Windows.Media.Animation.DoubleAnimation 0,1,(New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(220))); $fade.EasingFunction=$ease
    $slide=New-Object Windows.Media.Animation.DoubleAnimation 14,0,(New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(280))); $slide.EasingFunction=$ease
    $p.BeginAnimation([Windows.UIElement]::OpacityProperty,$fade)
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$slide)
}
foreach ($k in @($navs.Keys)) { $n=$k; $navs[$n].Add_Checked({ Show-Page $n }.GetNewClosure()) }

# ---- ACTIONS ---------------------------------------------------------------
function Set-Recommended {
    foreach ($t in $Tweaks){ $rec=($t.PSObject.Properties.Name -contains 'Recommended' -and $t.Recommended); $CheckBoxes[$t.Id].IsChecked=[bool]$rec }
    Write-Log 'Recommended safe preset selected. Review, then APPLY.' 'accent'
}
function Invoke-Apply {
    $btn=$window.FindName('btnApply'); $btn.IsEnabled=$false
    $lstLog.Items.Clear()
    Write-Log '=== Rom Opti :: applying selected optimizations ===' 'accent'
    $sel=$Tweaks | Where-Object { $CheckBoxes[$_.Id].IsChecked }
    if (-not $sel){ Write-Log 'Nothing selected. Tick some options first.' 'warn'; $btn.IsEnabled=$true; return }
    $sel=$sel | Sort-Object { if ($_.Id -eq 'tw_restore'){0}else{1} }
    $needExplorer=$false
    foreach ($t in $sel){
        try { & $t.Apply; Write-Log ("[ OK ] "+$t.Name) 'ok'
              if ($t.PSObject.Properties.Name -contains 'ExplorerRestart' -and $t.ExplorerRestart){ $needExplorer=$true } }
        catch { Write-Log ("[FAIL] "+$t.Name+"  ->  "+$_.Exception.Message) 'err' }
        DoEvents
    }
    if ($needExplorer){ Write-Log 'Restarting Explorer to apply interface changes...' 'accent'; DoEvents; Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue }
    Write-Log '=== Done. A reboot is recommended for full effect. ===' 'ok'
    $btn.IsEnabled=$true
}
$window.FindName('btnRecommend').Add_Click({ Set-Recommended })
$window.FindName('btnAll').Add_Click({ foreach ($cb in $CheckBoxes.Values){ $cb.IsChecked=$true } })
$window.FindName('btnNone').Add_Click({ foreach ($cb in $CheckBoxes.Values){ $cb.IsChecked=$false } })
$window.FindName('btnApply').Add_Click({ Invoke-Apply })
$window.FindName('homeRecommend').Add_Click({ Set-Recommended; $navs['Tweaks'].IsChecked=$true })
$window.FindName('homeRust').Add_Click({ $navs['Rust'].IsChecked=$true })

# ---- WINDOW CONTROLS -------------------------------------------------------
$window.FindName('btnMin').Add_Click({ $window.WindowState='Minimized' })
$window.FindName('btnMax').Add_Click({ if ($window.WindowState -eq 'Maximized'){ $window.WindowState='Normal' } else { $window.WindowState='Maximized' } })
$window.FindName('btnClose').Add_Click({ $window.Close() })

# ---- START -----------------------------------------------------------------
$window.Add_Loaded({
    Build-Sky
    $navs['Home'].IsChecked=$true
    Write-Log 'Welcome to Rom Opti. Click Recommended for a safe preset, or pick your own.' 'accent'
    Write-Log 'Tip: leave "Create Restore Point" ticked so you can always roll back.' 'info'
})
$window.Add_SizeChanged({ if ($SkyCanvas.ActualWidth -gt 50){ Build-Sky } })

try { $window.ShowDialog() | Out-Null }
catch { [System.Windows.MessageBox]::Show("Runtime error:`n$($_.Exception.Message)","Rom Opti") | Out-Null }
