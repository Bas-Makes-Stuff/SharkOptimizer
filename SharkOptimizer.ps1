
#Requires -Version 5.1
<#
  SharkOptimizer  -  PowerShell + WPF PC optimizer
  Run: right-click > Run with PowerShell (auto-elevates to Administrator)
  Every tweak is tracked so it can be undone individually or all at once.
#>
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    exit
}
trap { Write-Host "`nERROR: $($_.Exception.Message)`n$($_.InvocationInfo.PositionMessage)" -ForegroundColor Red; Read-Host 'Press Enter to close'; exit 1 }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, Microsoft.VisualBasic
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- storage
$DataDir = Join-Path $env:ProgramData 'SharkOptimizer'
New-Item $DataDir -ItemType Directory -Force | Out-Null
$StateFile = Join-Path $DataDir 'state.json'
$LogFile   = Join-Path $DataDir 'log.txt'
$State = @{}
if (Test-Path $StateFile) {
    try {
        $o = Get-Content $StateFile -Raw | ConvertFrom-Json
        foreach ($prop in $o.PSObject.Properties) { $State[$prop.Name] = @($prop.Value | Where-Object { $_ }) }
    } catch {}
}
function Save-State { $State | ConvertTo-Json -Depth 6 | Set-Content $StateFile -Encoding UTF8 }

# ---------------------------------------------------------------- hardware detection
function Get-Specs {
    $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpus = @(Get-CimInstance Win32_VideoController)
    $gpu  = $gpus | Where-Object { $_.Name -match 'NVIDIA|Radeon|Arc' } | Select-Object -First 1
    if (-not $gpu) { $gpu = $gpus | Select-Object -First 1 }
    $cs   = Get-CimInstance Win32_ComputerSystem
    $ram  = [math]::Round($cs.TotalPhysicalMemory / 1GB)
    $laptop = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    if (-not $laptop) { $ct = (Get-CimInstance Win32_SystemEnclosure).ChassisTypes; if ($ct | Where-Object { $_ -in 8,9,10,14,30,31 }) { $laptop = $true } }
    $ssd = $false
    try { $ssd = [bool](Get-Partition -DriveLetter ([string]$env:SystemDrive[0]) | Get-Disk | Get-PhysicalDisk | Where-Object MediaType -eq 'SSD') } catch {}
    $nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
    $wifi = [bool]($nics | Where-Object { $_.PhysicalMediaType -match '802.11' })
    $build = [Environment]::OSVersion.Version.Build
    $gname = if ($gpu) { [string]$gpu.Name } else { 'Unknown GPU' }
    $tier = if ($ram -le 8 -or $cpu.NumberOfLogicalProcessors -le 4) { 'Entry-level' } elseif ($ram -ge 32 -and $cpu.NumberOfLogicalProcessors -ge 12) { 'High-end' } else { 'Mid-range' }
    [pscustomobject]@{
        CPU=$cpu.Name.Trim(); Cores=$cpu.NumberOfCores; Threads=$cpu.NumberOfLogicalProcessors
        Intel=($cpu.Name -match 'Intel'); AMD=($cpu.Name -match 'AMD')
        GPU=$gname; Nvidia=($gname -match 'NVIDIA'); AmdGpu=($gname -match 'Radeon|AMD'); IntelGpu=($gname -match 'Intel'); GpuCount=$gpus.Count
        RamGB=$ram; Laptop=$laptop; SSD=$ssd; Wifi=$wifi; Nics=@($nics | ForEach-Object Name)
        Build=$build; Win11=($build -ge 22000)
        OS=(Get-CimInstance Win32_OperatingSystem).Caption; Tier=$tier
    }
}
$Spec = Get-Specs

# ---------------------------------------------------------------- tracked changes (undo engine)
$script:CurId = ''
function Add-Track($entry) { $State[$script:CurId] = @(@($State[$script:CurId]) + $entry | Where-Object { $_ }) }
function Set-Tracked {
    param($Path, $Name, $Value, $Type = 'DWord')
    $existed = $false; $old = $null; $kind = $Type
    if (Test-Path -LiteralPath $Path) {
        $k = Get-Item -LiteralPath $Path
        if ($k.GetValueNames() -contains $Name) {
            $existed = $true; $kind = $k.GetValueKind($Name).ToString()
            $old = $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
        }
    } else { New-Item -Path $Path -Force | Out-Null }
    $already = @($State[$script:CurId]) | Where-Object { $_ -and $_.K -eq 'Reg' -and $_.Path -eq $Path -and $_.Name -eq $Name }
    if (-not $already -and $kind -notin 'Binary','MultiString') {
        Add-Track ([pscustomobject]@{ K='Reg'; Path=$Path; Name=$Name; Existed=$existed; Old=$old; Type=$kind })
    }
    Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type -Force
}
function Set-SvcTracked {
    param($Name)
    $svc = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    Add-Track ([pscustomobject]@{ K='Svc'; Name=$Name; Old=$svc.StartMode })
    Stop-Service $Name -Force -ErrorAction SilentlyContinue
    Set-Service $Name -StartupType Disabled -ErrorAction SilentlyContinue
}
function Set-AdvTracked {
    param($Pattern, $Value)
    foreach ($ad in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')) {
        foreach ($pr in @(Get-NetAdapterAdvancedProperty -Name $ad.Name -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $Pattern })) {
            $oldv = $pr.DisplayValue
            try {
                Set-NetAdapterAdvancedProperty -Name $ad.Name -DisplayName $pr.DisplayName -DisplayValue $Value -ErrorAction Stop
                Add-Track ([pscustomobject]@{ K='Adv'; Adapter=$ad.Name; DisplayName=$pr.DisplayName; Old=$oldv })
            } catch {}
        }
    }
}
function Restore-Entry($e) {
    if ($e.K -eq 'Reg') {
        if ($e.Existed) { Set-ItemProperty -LiteralPath $e.Path -Name $e.Name -Value $e.Old -Type $e.Type -Force -ErrorAction SilentlyContinue }
        else { Remove-ItemProperty -LiteralPath $e.Path -Name $e.Name -Force -ErrorAction SilentlyContinue }
    } elseif ($e.K -eq 'Svc') {
        $m = switch ($e.Old) { 'Auto' {'Automatic'} 'Manual' {'Manual'} default {'Disabled'} }
        Set-Service $e.Name -StartupType $m -ErrorAction SilentlyContinue
        if ($m -eq 'Automatic') { Start-Service $e.Name -ErrorAction SilentlyContinue }
    } elseif ($e.K -eq 'Adv') {
        Set-NetAdapterAdvancedProperty -Name $e.Adapter -DisplayName $e.DisplayName -DisplayValue $e.Old -ErrorAction SilentlyContinue
    }
}
function Get-UpAdapters { Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' }
function PCfg($sub, $set, $ac, $dc) {
    powercfg -setacvalueindex SCHEME_CURRENT $sub $set $ac | Out-Null
    if ($null -ne $dc) { powercfg -setdcvalueindex SCHEME_CURRENT $sub $set $dc | Out-Null }
    powercfg -setactive SCHEME_CURRENT | Out-Null
}

# ---------------------------------------------------------------- tweak catalogue
$Tweaks = New-Object System.Collections.ArrayList
# NOTE: "R" is a built-in alias in PowerShell, so the helper is called Rg
function Rg($path, $name, $value, $type = 'DWord') { , @($path, $name, $value, $type) }
function Add-Tweak {
    param($Id, $Cat, $Name, $Desc, $Risk = 'Safe', $Warn = '', [bool]$Rec = $false, [scriptblock]$Req = $null,
          $ReqText = '', $Reg = @(), [scriptblock]$Do = $null, [scriptblock]$Undo = $null, [bool]$Reboot = $false)
    [void]$Tweaks.Add([pscustomobject]@{ Id=$Id; Cat=$Cat; Name=$Name; Desc=$Desc; Risk=$Risk; Warn=$Warn; Rec=$Rec
        Req=$Req; ReqText=$ReqText; Reg=@($Reg); Do=$Do; Undo=$Undo; Reboot=$Reboot })
}
$cPriv='Privacy & Security'; $cQol='Quality of Life'; $cNet='Network & Ping'; $cFps='FPS & Latency'; $cWin='Windows Optimization'; $cAdv='Advanced'
$CV='HKCU:\Software\Microsoft\Windows\CurrentVersion'
$POL='HKLM:\SOFTWARE\Policies\Microsoft\Windows'
$SP='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$TCP='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
$FS='HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
$MM='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$EXP="$CV\Explorer\Advanced"
$WLAN='19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'; $WLANSET='12bbebe6-58d6-4636-95bb-3217ef867c1a'
$TaskList = @('\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser','\Microsoft\Windows\Customer Experience Improvement Program\Consolidator','\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip','\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector')
$AdNames = @('SubscribedContent-338387Enabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-338393Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SubscribedContent-310093Enabled','SystemPaneSuggestionsEnabled','SoftLandingEnabled','RotatingLockScreenOverlayEnabled','ContentDeliveryAllowed','OemPreInstalledAppsEnabled','PreInstalledAppsEnabled','SilentInstalledAppsEnabled')
$AdRegs = @(); foreach ($adn in $AdNames) { $AdRegs += , (Rg "$CV\ContentDeliveryManager" $adn 0) }
$SvcKB = [int64]$Spec.RamGB * 1048576; if ($SvcKB -gt 2147483647) { $SvcKB = 2147483647 }

# ---------- Privacy & Security
Add-Tweak 'p_telemetry' $cPriv 'Disable Telemetry' 'Sets telemetry to the minimum and stops the DiagTrack service. Less background CPU, disk and network use.' 'Safe' -Rec $true `
  -Reg @((Rg "$POL\DataCollection" 'AllowTelemetry' 0)) `
  -Do { Set-SvcTracked 'DiagTrack'; Set-SvcTracked 'dmwappushservice' }
Add-Tweak 'p_tasks' $cPriv 'Disable Telemetry Tasks' 'Turns off the Compatibility Appraiser, CEIP and disk-diagnostic tasks that wake up in the background.' 'Safe' -Rec $true `
  -Do { foreach($tk in $TaskList){ schtasks /Change /TN $tk /Disable 2>$null | Out-Null } } `
  -Undo { foreach($tk in $TaskList){ schtasks /Change /TN $tk /Enable 2>$null | Out-Null } }
Add-Tweak 'p_adid' $cPriv 'Disable Advertising ID' 'Stops apps from using a unique ad ID to profile you.' 'Safe' -Rec $true -Reg @((Rg "$CV\AdvertisingInfo" 'Enabled' 0))
Add-Tweak 'p_bing' $cPriv 'Disable Web Search in Start' 'Start searches only your PC, not Bing. Faster results and no queries sent out.' 'Safe' -Rec $true `
  -Reg @((Rg "$CV\Search" 'BingSearchEnabled' 0), (Rg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1))
Add-Tweak 'p_cortana' $cPriv 'Disable Cortana and Cloud Search' 'Turns Cortana and cloud search integration off by policy.' 'Safe' -Rec $true `
  -Reg @((Rg "$POL\Windows Search" 'AllowCortana' 0), (Rg "$POL\Windows Search" 'AllowCloudSearch' 0))
Add-Tweak 'p_activity' $cPriv 'Disable Activity History' 'Stops Windows collecting and uploading your activity timeline.' 'Safe' -Rec $true `
  -Reg @((Rg "$POL\System" 'EnableActivityFeed' 0), (Rg "$POL\System" 'PublishUserActivities' 0), (Rg "$POL\System" 'UploadUserActivities' 0))
Add-Tweak 'p_ads' $cPriv 'Remove Windows Ads' 'Turns off Start menu ads, lock-screen tips, Settings promos and silent app installs.' 'Safe' -Rec $true -Reg $AdRegs
Add-Tweak 'p_consumer' $cPriv 'Block Consumer Features' 'Stops Windows from pushing suggested apps, Spotlight content and promotional installs.' 'Safe' -Rec $true `
  -Reg @((Rg "$POL\CloudContent" 'DisableWindowsConsumerFeatures' 1), (Rg "$POL\CloudContent" 'DisableWindowsSpotlightFeatures' 1), (Rg "$POL\CloudContent" 'DisableSoftLanding' 1))
Add-Tweak 'p_copilot' $cPriv 'Disable Copilot' 'Turns Copilot off by policy so it stops loading in the background.' 'Safe' -Req { $Spec.Build -ge 22621 } -ReqText 'Needs Windows 11 22H2 or newer' `
  -Reg @((Rg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1))
Add-Tweak 'p_recall' $cPriv 'Disable Windows AI Data Analysis' 'Blocks Recall-style AI snapshots and analysis of your screen activity.' 'Safe' -Rec $true -Req { $Spec.Build -ge 26100 } -ReqText 'Needs Windows 11 24H2 or newer' `
  -Reg @((Rg "$POL\WindowsAI" 'DisableAIDataAnalysis' 1))
Add-Tweak 'p_widgets' $cPriv 'Disable Widgets' 'Stops the Widgets board and its web content process.' 'Safe' -Req { $Spec.Win11 } -ReqText 'Needs Windows 11' `
  -Reg @((Rg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0))
Add-Tweak 'p_wer' $cPriv 'Disable Error Reporting' 'Windows stops building and sending crash reports.' 'Safe' -Reg @((Rg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1))
Add-Tweak 'p_feedback' $cPriv 'Disable Feedback Prompts' 'Windows stops asking you for feedback.' 'Safe' -Rec $true `
  -Reg @((Rg 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0), (Rg 'HKCU:\Software\Microsoft\Siuf\Rules' 'PeriodInNanoSeconds' 0))
Add-Tweak 'p_inventory' $cPriv 'Disable App Inventory and Steps Recorder' 'Stops the application inventory collector and Steps Recorder data gathering.' 'Safe' `
  -Reg @((Rg "$POL\AppCompat" 'DisableInventory' 1), (Rg "$POL\AppCompat" 'DisableUAR' 1))
Add-Tweak 'p_ink' $cPriv 'Stop Typing and Inking Data Collection' 'Stops Windows collecting handwriting and typing samples to improve suggestions.' 'Safe' -Rec $true `
  -Reg @((Rg 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1), (Rg 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1))
Add-Tweak 'p_clip' $cPriv 'Disable Clipboard Cloud Sync' 'Your clipboard history no longer syncs between devices.' 'Safe' -Reg @((Rg "$POL\System" 'AllowCrossDeviceClipboard' 0))
Add-Tweak 'p_location' $cPriv 'Disable Location Services' 'Turns Windows location tracking off for the whole PC.' 'Caution' -Warn 'Maps, Weather and Find My Device stop working.' `
  -Reg @((Rg "$POL\LocationAndSensors" 'DisableLocation' 1))
Add-Tweak 'p_llmnr' $cPriv 'Disable LLMNR' 'Turns off a legacy name-resolution protocol that attackers abuse on shared networks.' 'Safe' -Rec $true `
  -Reg @((Rg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast' 0))
Add-Tweak 'p_remreg' $cPriv 'Disable Remote Registry' 'Stops the service that lets other PCs edit your registry over the network.' 'Safe' -Rec $true -Do { Set-SvcTracked 'RemoteRegistry' }
Add-Tweak 'p_remote' $cPriv 'Disable Remote Assistance' 'Closes the Remote Assistance door and reduces your attack surface.' 'Safe' -Rec $true `
  -Reg @((Rg 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowToGetHelp' 0))
Add-Tweak 'p_nvtel' $cPriv 'Disable NVIDIA Telemetry' 'Stops the NVIDIA Telemetry Container. Drivers and games keep working.' 'Safe' -Rec $Spec.Nvidia -Req { $Spec.Nvidia } -ReqText 'Needs an NVIDIA GPU' `
  -Do { Set-SvcTracked 'NvTelemetryContainer' }
Add-Tweak 'p_do' $cPriv 'Disable Update Sharing (P2P)' 'Windows stops uploading updates to other PCs with your bandwidth.' 'Safe' -Rec $true `
  -Reg @((Rg "$POL\DeliveryOptimization" 'DODownloadMode' 0))

# ---------- Quality of Life
Add-Tweak 'q_ext' $cQol 'Show File Extensions' 'Always show .exe, .png, .txt and more. Helps you spot fake files.' 'Safe' -Rec $true -Reg @((Rg $EXP 'HideFileExt' 0))
Add-Tweak 'q_hidden' $cQol 'Show Hidden Files' 'Shows hidden files and folders in Explorer.' 'Safe' -Reg @((Rg $EXP 'Hidden' 1))
Add-Tweak 'q_thispc' $cQol 'Open Explorer to This PC' 'File Explorer opens on This PC instead of Quick Access.' 'Safe' -Reg @((Rg $EXP 'LaunchTo' 1))
Add-Tweak 'q_recent' $cQol 'Hide Recent and Frequent Files' 'Explorer stops listing recent and frequent files in Quick Access.' 'Safe' `
  -Reg @((Rg "$CV\Explorer" 'ShowRecent' 0), (Rg "$CV\Explorer" 'ShowFrequent' 0))
Add-Tweak 'q_shake' $cQol 'Disable Aero Shake' 'Shaking a window no longer minimizes all the others.' 'Safe' -Reg @((Rg $EXP 'DisallowShaking' 1))
Add-Tweak 'q_dark' $cQol 'Dark Mode' 'Switches Windows and apps to the dark theme.' 'Safe' `
  -Reg @((Rg "$CV\Themes\Personalize" 'AppsUseLightTheme' 0), (Rg "$CV\Themes\Personalize" 'SystemUsesLightTheme' 0))
Add-Tweak 'q_taskbar' $cQol 'Clean Windows 11 Taskbar' 'Aligns the taskbar left and hides the Widgets, Task View and search buttons.' 'Safe' -Req { $Spec.Win11 } -ReqText 'Needs Windows 11' `
  -Reg @((Rg $EXP 'TaskbarAl' 0), (Rg $EXP 'TaskbarDa' 0), (Rg $EXP 'ShowTaskViewButton' 0), (Rg "$CV\Search" 'SearchboxTaskbarMode' 0))
Add-Tweak 'q_classic' $cQol 'Classic Right-Click Menu' 'Brings back the full context menu on Windows 11.' 'Safe' -Req { $Spec.Win11 } -ReqText 'Needs Windows 11' `
  -Do { $ck='HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'; New-Item $ck -Force | Out-Null; Set-ItemProperty $ck -Name '(default)' -Value '' } `
  -Undo { Remove-Item 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' -Recurse -Force -ErrorAction SilentlyContinue }
Add-Tweak 'q_boot' $cQol 'Detailed Boot Messages' 'Shows detailed startup and shutdown messages. Does not speed up boot, but helps troubleshooting.' 'Safe' `
  -Reg @((Rg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'VerboseStatus' 1))
Add-Tweak 'q_menu' $cQol 'Instant Menus' 'Menus open with no delay.' 'Safe' -Rec $true -Reg @((Rg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0' 'String'))
Add-Tweak 'q_kb' $cQol 'Fast Keyboard Repeat' 'Shortest repeat delay and fastest repeat rate.' 'Safe' `
  -Reg @((Rg 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' '0' 'String'), (Rg 'HKCU:\Control Panel\Keyboard' 'KeyboardSpeed' '31' 'String'))
Add-Tweak 'q_shutdown' $cQol 'Faster Shutdown' 'Services and apps get 2 seconds to close. Hung apps are ended automatically.' 'Caution' -Warn 'Apps with unsaved work can be closed during shutdown.' `
  -Reg @((Rg 'HKLM:\SYSTEM\CurrentControlSet\Control' 'WaitToKillServiceTimeout' '2000' 'String'), (Rg 'HKCU:\Control Panel\Desktop' 'WaitToKillAppTimeout' '2000' 'String'), (Rg 'HKCU:\Control Panel\Desktop' 'HungAppTimeout' '2000' 'String'), (Rg 'HKCU:\Control Panel\Desktop' 'AutoEndTasks' '1' 'String'))
Add-Tweak 'q_startdelay' $cQol 'Remove Startup Delay' 'Startup apps launch right away instead of waiting about 10 seconds.' 'Safe' -Rec $true -Reg @((Rg "$CV\Explorer\Serialize" 'StartupDelayInMSec' 0))
Add-Tweak 'q_sticky' $cQol 'Disable Sticky Keys Popups' 'No more Shift x5 popup in the middle of a game.' 'Safe' -Rec $true `
  -Reg @((Rg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'), (Rg 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'), (Rg 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' 'String'))
Add-Tweak 'q_reboot' $cQol 'Block Forced Update Restarts' 'Windows will not restart by itself while you are signed in.' 'Safe' -Rec $true `
  -Reg @((Rg "$POL\WindowsUpdate\AU" 'NoAutoRebootWithLoggedOnUsers' 1))
Add-Tweak 'q_welcome' $cQol 'Skip Post-Update Welcome Screens' 'Hides the "Let us finish setting up your device" pages after updates.' 'Safe' -Rec $true `
  -Reg @((Rg "$CV\UserProfileEngagement" 'ScoobeSystemSettingEnabled' 0))
Add-Tweak 'q_visfx' $cQol 'Lightweight Visuals' 'Turns off animations and transparency for a snappier desktop and lower GPU and RAM use.' 'Safe' -Rec ($Spec.RamGB -le 8 -or $Spec.IntelGpu) `
  -Reg @((Rg "$CV\Explorer\VisualEffects" 'VisualFXSetting' 2), (Rg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'), (Rg "$CV\Themes\Personalize" 'EnableTransparency' 0), (Rg $EXP 'TaskbarAnimations' 0))
Add-Tweak 'q_bgapps' $cQol 'Block Background Apps' 'Stops Store apps from running in the background. Saves RAM and CPU.' 'Caution' -Warn 'Mail, Calendar and other Store apps will not notify you while closed.' -Rec ($Spec.RamGB -le 8) `
  -Reg @((Rg "$POL\AppPrivacy" 'LetAppsRunInBackground' 2))
Add-Tweak 'q_search' $cQol 'Disable Search Indexing' 'Stops the indexer. Lower disk use on HDD systems.' 'Caution' -Warn 'File searches in Start and Explorer will be much slower.' -Rec (-not $Spec.SSD) `
  -Do { Set-SvcTracked 'WSearch' }

# ---------- FPS & Latency
Add-Tweak 'f_gamemode' $cFps 'Enable Game Mode' 'Tells Windows to prioritise your game and pause driver updates while you play.' 'Safe' -Rec $true `
  -Reg @((Rg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1), (Rg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1))
Add-Tweak 'f_dvr' $cFps 'Disable Background Recording' 'Stops Xbox Game Bar capture, a known source of frametime spikes.' 'Caution' -Warn 'Win+G and Win+Alt+R capture will stop working.' -Rec $true `
  -Reg @((Rg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0), (Rg "$CV\GameDVR" 'AppCaptureEnabled' 0), (Rg "$POL\GameDVR" 'AllowGameDVR' 0))
Add-Tweak 'f_overlay' $cFps 'Disable Game Bar Overlay' 'Removes the Game Bar prompt and controller shortcut hooks.' 'Safe' -Rec $true `
  -Reg @((Rg 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0), (Rg 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 0))
Add-Tweak 'f_power' $cFps 'Ultimate Performance Plan' 'Activates the Ultimate Performance power plan: no core parking and no CPU frequency delays.' 'Caution' -Warn 'Higher power draw and heat. Drains laptop batteries fast.' -Rec (-not $Spec.Laptop) `
  -Do { powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 99999999-9999-9999-9999-999999999999 | Out-Null; powercfg -changename 99999999-9999-9999-9999-999999999999 'SharkOptimizer Ultimate' | Out-Null; powercfg -setactive 99999999-9999-9999-9999-999999999999 } `
  -Undo { powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e | Out-Null; powercfg -delete 99999999-9999-9999-9999-999999999999 | Out-Null }
Add-Tweak 'f_usb' $cFps 'Disable USB Selective Suspend' 'Stops Windows powering down USB ports. Prevents mouse, keyboard and headset dropouts.' 'Safe' -Rec (-not $Spec.Laptop) `
  -Do { PCfg '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' 0 0 } -Undo { PCfg '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' 1 1 }
Add-Tweak 'f_pcie' $cFps 'Disable PCIe Link Power Saving' 'Keeps the PCIe link to your GPU and SSD at full speed (ASPM off).' 'Safe' -Rec (-not $Spec.Laptop) `
  -Do { PCfg '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5' 0 $null } -Undo { PCfg '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5' 1 $null }
Add-Tweak 'f_diskoff' $cFps 'Never Sleep Hard Disks' 'Disks stay spun up on AC power, which avoids stutter when a game loads data after idle.' 'Safe' -Rec (-not $Spec.SSD) `
  -Do { PCfg '0012ee47-9041-4b5d-9b77-535fba8b1442' '6738e2c4-e8a5-4a42-b16a-e040e769756e' 0 $null } -Undo { PCfg '0012ee47-9041-4b5d-9b77-535fba8b1442' '6738e2c4-e8a5-4a42-b16a-e040e769756e' 1200 $null }
Add-Tweak 'f_cpumin' $cFps 'CPU Minimum State 100%' 'CPU never downclocks on AC power. Removes ramp-up latency in competitive games.' 'Caution' -Warn 'Higher idle temperatures and power draw. Not for laptops on battery.' -Req { -not $Spec.Laptop } -ReqText 'Desktop PCs only' `
  -Do { PCfg '54533251-82be-4824-96c1-47b60b740d00' '893dee8e-2bef-41e0-89c6-b55d0929964c' 100 $null } -Undo { PCfg '54533251-82be-4824-96c1-47b60b740d00' '893dee8e-2bef-41e0-89c6-b55d0929964c' 5 $null }
Add-Tweak 'f_throttle' $cFps 'Disable Power Throttling' 'Stops Windows slowing down background apps such as Discord, OBS and launchers.' 'Safe' -Rec (-not $Spec.Laptop) `
  -Reg @((Rg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1))
Add-Tweak 'f_prio' $cFps 'Foreground Priority Boost' 'Sets Win32PrioritySeparation to 0x26 (short quanta, 3:1 foreground boost), a standard input-latency setting.' 'Safe' -Rec $true `
  -Reg @((Rg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38))
Add-Tweak 'f_mmcss' $cFps 'Game Scheduling (MMCSS)' 'Gives the Games task high GPU and CPU priority and lowers the multimedia reserve.' 'Safe' -Rec $true `
  -Reg @((Rg $SP 'SystemResponsiveness' 10), (Rg "$SP\Tasks\Games" 'GPU Priority' 8), (Rg "$SP\Tasks\Games" 'Priority' 6), (Rg "$SP\Tasks\Games" 'Scheduling Category' 'High' 'String'), (Rg "$SP\Tasks\Games" 'SFIO Priority' 'High' 'String'))
Add-Tweak 'f_fso' $cFps 'Disable Fullscreen Optimizations' 'Uses true exclusive fullscreen behaviour. Can lower input lag in older DX9 and DX11 games.' 'Caution' -Warn 'Can add tearing or reduce FPS in some DX12 games.' `
  -Reg @((Rg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2), (Rg 'HKCU:\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' 1), (Rg 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 1), (Rg 'HKCU:\System\GameConfigStore' 'GameDVR_EFSEFeatureFlags' 0))
Add-Tweak 'f_mouse' $cFps 'Raw Mouse Input' 'Turns off pointer acceleration for 1:1 aim. Needs a sign-out.' 'Safe' -Rec $true -Reboot $true `
  -Reg @((Rg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'), (Rg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'), (Rg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'))
Add-Tweak 'f_hags' $cFps 'GPU Scheduling (HAGS)' 'Lets the GPU manage its own scheduling. Required for DLSS Frame Generation and can lower CPU overhead.' 'Caution' -Warn 'Can cause stutter on older GPUs or drivers. Test your games after a restart.' -Rec ($Spec.Nvidia -or $Spec.AmdGpu) -Req { $Spec.Build -ge 19041 } -ReqText 'Needs Windows 10 2004 or newer' -Reboot $true `
  -Reg @((Rg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2))
Add-Tweak 'f_mpo' $cFps 'Disable Multiplane Overlay (MPO)' 'Can fix stutter, flicker and black screens on some NVIDIA and AMD setups.' 'Caution' -Warn 'Only use this if you see flicker or stutter. It can slightly raise power use.' -Req { $Spec.Nvidia -or $Spec.AmdGpu } -ReqText 'Needs an NVIDIA or AMD GPU' -Reboot $true `
  -Reg @((Rg 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5))
Add-Tweak 'f_fast' $cFps 'Disable Fast Startup' 'Forces a real cold boot on shutdown. Fixes stale drivers and stutter after long uptimes.' 'Caution' -Warn 'Cold boots are a few seconds slower, mainly on HDDs.' -Rec $Spec.SSD `
  -Reg @((Rg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0))
Add-Tweak 'f_sysmain' $cFps 'Disable SysMain' 'SSDs do not need prefetching. Cuts random disk and RAM activity.' 'Safe' -Rec $Spec.SSD -Req { $Spec.SSD } -ReqText 'Needs an SSD system drive' `
  -Do { Set-SvcTracked 'SysMain' }
Add-Tweak 'f_timerreq' $cFps 'Global Timer Resolution' 'Restores per-process timer resolution on Windows 11 so timer-hungry games stay consistent.' 'Caution' -Warn 'Slightly higher power use. Only matters for games that request 0.5 ms timers.' -Req { $Spec.Build -ge 19041 } -ReqText 'Needs Windows 10 2004 or newer' -Reboot $true `
  -Reg @((Rg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1))

# ---------- Network & Ping
Add-Tweak 'n_nagle' $cNet 'Disable Nagle''s Algorithm' 'Sends small packets immediately. A classic ping and jitter fix for online games.' 'Safe' -Rec $true `
  -Do { Get-ChildItem "$TCP\Interfaces" | ForEach-Object { Set-Tracked $_.PSPath 'TcpAckFrequency' 1; Set-Tracked $_.PSPath 'TCPNoDelay' 1 } }
Add-Tweak 'n_throttle' $cNet 'Disable Network Throttling' 'Removes the multimedia network throttle.' 'Safe' -Rec $true -Reg @((Rg $SP 'NetworkThrottlingIndex' -1))
Add-Tweak 'n_qos' $cNet 'Remove QoS Bandwidth Reserve' 'Frees the 20% of bandwidth Windows can reserve for QoS.' 'Safe' -Rec $true `
  -Reg @((Rg "$POL\Psched" 'NonBestEffortLimit' 0))
Add-Tweak 'n_ports' $cNet 'Faster TCP Port Reuse' 'Shorter TIME_WAIT (30 s) and 65,534 user ports. Helps with lobbies that reconnect often.' 'Safe' `
  -Reg @((Rg $TCP 'TcpTimedWaitDelay' 30), (Rg $TCP 'MaxUserPort' 65534))
Add-Tweak 'n_heur' $cNet 'Disable TCP Heuristics' 'Stops Windows overriding TCP window scaling on its own, which keeps throughput steady.' 'Safe' -Rec $true `
  -Do { netsh int tcp set heuristics disabled | Out-Null } -Undo { netsh int tcp set heuristics default | Out-Null }
Add-Tweak 'n_dns' $cNet 'Fast DNS (Cloudflare)' 'Sets 1.1.1.1 on your active adapters for quicker lookups. Benchmark first in the Network tab.' 'Safe' -Rec $true `
  -Do { foreach($ad in Get-UpAdapters){ Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses '1.1.1.1','1.0.0.1' } } `
  -Undo { foreach($ad in Get-UpAdapters){ Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ResetServerAddresses } }
Add-Tweak 'n_rsc' $cNet 'Disable Packet Coalescing (RSC)' 'Stops the adapter batching incoming packets. Lower latency, slightly more CPU use.' 'Safe' -Rec (-not $Spec.Wifi) `
  -Do { foreach($ad in Get-UpAdapters){ Disable-NetAdapterRsc -Name $ad.Name -ErrorAction SilentlyContinue } } `
  -Undo { foreach($ad in Get-UpAdapters){ Enable-NetAdapterRsc -Name $ad.Name -ErrorAction SilentlyContinue } }
Add-Tweak 'n_lso' $cNet 'Disable Large Send Offload' 'Fixes bursty upload latency on some adapters and drivers.' 'Caution' -Warn 'May slightly raise CPU use during large uploads.' `
  -Do { foreach($ad in Get-UpAdapters){ Disable-NetAdapterLso -Name $ad.Name -ErrorAction SilentlyContinue } } `
  -Undo { foreach($ad in Get-UpAdapters){ Enable-NetAdapterLso -Name $ad.Name -ErrorAction SilentlyContinue } }
Add-Tweak 'n_nicpwr' $cNet 'Disable Adapter Power Saving' 'Stops Windows powering down the adapter, which prevents lag spikes and random disconnects.' 'Safe' -Rec $true `
  -Do { foreach($ad in Get-UpAdapters){ Disable-NetAdapterPowerManagement -Name $ad.Name -ErrorAction SilentlyContinue } } `
  -Undo { foreach($ad in Get-UpAdapters){ Enable-NetAdapterPowerManagement -Name $ad.Name -ErrorAction SilentlyContinue } }
Add-Tweak 'n_eee' $cNet 'Disable Green Ethernet / EEE' 'Turns off Energy-Efficient Ethernet and similar adapter power modes that add wake-up latency.' 'Safe' -Rec (-not $Spec.Wifi) -Req { -not $Spec.Wifi } -ReqText 'Ethernet adapters only' `
  -Do { Set-AdvTracked 'Energy.?Efficient|Green Ethernet|Power Saving Mode' 'Disabled' }
Add-Tweak 'n_flow' $cNet 'Disable Flow Control' 'Stops the adapter pausing traffic when a link partner asks. Can smooth latency spikes.' 'Caution' -Warn 'Heavy local file transfers may behave slightly differently.' -Req { -not $Spec.Wifi } -ReqText 'Ethernet adapters only' `
  -Do { Set-AdvTracked '^Flow Control' 'Disabled' }
Add-Tweak 'n_intmod' $cNet 'Disable Interrupt Moderation' 'Delivers packets to the CPU immediately instead of batching them. Lower ping, higher CPU use.' 'Caution' -Warn 'Raises CPU usage during heavy network traffic. Weak CPUs may lose FPS.' -Req { -not $Spec.Wifi -and $Spec.Threads -ge 6 } -ReqText 'Ethernet and 6+ CPU threads' `
  -Do { Set-AdvTracked 'Interrupt Moderation' 'Disabled' }
Add-Tweak 'n_rss' $cNet 'Enable Receive Side Scaling' 'Spreads network processing across CPU cores.' 'Safe' -Rec ($Spec.Threads -ge 6) -Req { $Spec.Threads -ge 4 } -ReqText 'Needs 4 or more threads' `
  -Do { netsh int tcp set global rss=enabled | Out-Null } -Undo { netsh int tcp set global rss=default | Out-Null }
Add-Tweak 'n_wifi' $cNet 'Wi-Fi Maximum Performance' 'Sets wireless power saving to Maximum Performance on AC and battery.' 'Safe' -Rec $Spec.Wifi -Req { $Spec.Wifi } -ReqText 'Needs a Wi-Fi adapter' `
  -Do { PCfg $WLAN $WLANSET 0 0 } -Undo { PCfg $WLAN $WLANSET 0 2 }
Add-Tweak 'n_netbios' $cNet 'Disable NetBIOS over TCP/IP' 'Turns off legacy NetBIOS name broadcasts. Less background network noise.' 'Caution' -Warn 'Very old file-sharing setups that rely on NetBIOS names stop working.' `
  -Do { Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' | ForEach-Object { Set-Tracked $_.PSPath 'NetbiosOptions' 2 } }
Add-Tweak 'n_teredo' $cNet 'Disable Teredo Tunneling' 'Turns off the IPv6-over-IPv4 tunnel that adds overhead and can slow connections.' 'Caution' -Warn 'Xbox Live party chat and some peer-to-peer games rely on Teredo.' `
  -Do { netsh interface teredo set state disabled | Out-Null } -Undo { netsh interface teredo set state default | Out-Null }

# ---------- Windows Optimization
Add-Tweak 'w_edge' $cWin 'Stop Edge Background Activity' 'Disables Edge Startup Boost and background mode so it stops running when closed.' 'Safe' -Rec $true `
  -Reg @((Rg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0), (Rg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0))
Add-Tweak 'w_services' $cWin 'Disable Unused Services' 'Turns off Fax, Retail Demo, Windows Media sharing and Maps Broker. Frees RAM and handles.' 'Safe' -Rec $true `
  -Do { foreach($sv in 'Fax','RetailDemo','WMPNetworkSvc','MapsBroker'){ Set-SvcTracked $sv } }
Add-Tweak 'w_chat' $cWin 'Remove Teams Chat Icon' 'Removes the Chat button from the Windows 11 taskbar.' 'Safe' -Rec $true -Req { $Spec.Win11 } -ReqText 'Needs Windows 11' `
  -Reg @((Rg "$POL\Windows Chat" 'ChatIcon' 3))
Add-Tweak 'w_lastaccess' $cWin 'Disable NTFS Last-Access Updates' 'Windows stops writing a timestamp every time a file is read. Less disk activity.' 'Safe' -Rec $true -Reg @((Rg $FS 'NtfsDisableLastAccessUpdate' 1))
Add-Tweak 'w_8dot3' $cWin 'Disable 8.3 Filenames' 'Stops creating legacy short filenames for every file. Faster file creation.' 'Caution' -Warn 'Very old 16-bit installers may fail. Existing short names are kept.' -Reg @((Rg $FS 'NtfsDisable8dot3NameCreation' 1))
Add-Tweak 'w_svchost' $cWin 'Merge Service Host Processes' 'Groups services into fewer svchost.exe processes when you have enough RAM.' 'Caution' -Warn 'If one grouped service crashes, others in that group can stop with it.' -Rec ($Spec.RamGB -ge 16) -Req { $Spec.RamGB -ge 8 } -ReqText 'Needs 8 GB RAM or more' -Reboot $true `
  -Reg @((Rg 'HKLM:\SYSTEM\CurrentControlSet\Control' 'SvcHostSplitThresholdInKB' ([int]$SvcKB)))
Add-Tweak 'w_pagingexec' $cWin 'Keep Kernel in RAM' 'Stops Windows paging the kernel and drivers out to disk. Helps responsiveness on large-RAM PCs.' 'Caution' -Warn 'Uses a little more RAM permanently.' -Req { $Spec.RamGB -ge 16 } -ReqText 'Needs 16 GB RAM or more' -Reboot $true `
  -Reg @((Rg $MM 'DisablePagingExecutive' 1))
Add-Tweak 'w_memcomp' $cWin 'Disable Memory Compression' 'Skips compressing RAM pages, which saves a little CPU when you have plenty of memory.' 'Caution' -Warn 'Slows things down if your RAM fills up.' -Req { $Spec.RamGB -ge 16 } -ReqText 'Needs 16 GB RAM or more' -Reboot $true `
  -Do { Disable-MMAgent -MemoryCompression -ErrorAction Stop } -Undo { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue }
Add-Tweak 'w_prefetch' $cWin 'Disable Prefetcher' 'Turns off the prefetcher and Superfetch preloading. Not needed on SSDs.' 'Caution' -Warn 'Programs can launch slightly slower on hard drives.' -Rec $Spec.SSD -Req { $Spec.SSD } -ReqText 'Needs an SSD system drive' -Reboot $true `
  -Reg @((Rg "$MM\PrefetchParameters" 'EnablePrefetcher' 0), (Rg "$MM\PrefetchParameters" 'EnableSuperfetch' 0))
Add-Tweak 'w_maint' $cWin 'Disable Automatic Maintenance' 'Stops Windows running idle-time maintenance jobs on its own schedule.' 'Caution' -Warn 'Scheduled defrag and diagnostics will not run. Use Boost-Up instead.' `
  -Reg @((Rg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' 'MaintenanceDisabled' 1))
Add-Tweak 'w_onedrive' $cWin 'Disable OneDrive Sync' 'Turns OneDrive file sync off by policy.' 'Caution' -Warn 'Files stay on your PC but stop syncing to the cloud.' `
  -Reg @((Rg "$POL\OneDrive" 'DisableFileSyncNGSC' 1))
Add-Tweak 'w_wudrv' $cWin 'Block Drivers via Windows Update' 'Windows Update stops replacing your GPU and chipset drivers with its own versions.' 'Caution' -Warn 'You must update drivers yourself from the vendor.' -Rec $true `
  -Reg @((Rg "$POL\WindowsUpdate" 'ExcludeWUDriversInQualityUpdate' 1))
Add-Tweak 'w_spooler' $cWin 'Disable Print Spooler' 'Stops the print service. Saves RAM and closes a common attack surface.' 'Caution' -Warn 'Printing and PDF printers stop working.' -Do { Set-SvcTracked 'Spooler' }

# ---------- Advanced
Add-Tweak 'a_msi' $cAdv 'GPU MSI Mode' 'Switches the GPU to Message Signaled Interrupts for lower DPC latency.' 'Caution' -Warn 'An unsupported GPU or driver can cause black screens. Keep a restore point.' -Reboot $true `
  -Do { Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue | ForEach-Object { Set-Tracked "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties" 'MSISupported' 1 } }
Add-Tweak 'a_tick' $cAdv 'Disable Dynamic Tick' 'Constant timer interrupts for steadier frametimes (bcdedit).' 'Caution' -Warn 'Higher idle power use and heat.' -Req { -not $Spec.Laptop } -ReqText 'Desktop PCs only' -Reboot $true `
  -Do { bcdedit /set disabledynamictick yes | Out-Null } -Undo { bcdedit /deletevalue disabledynamictick | Out-Null }
Add-Tweak 'a_hyperv' $cAdv 'Turn Off Hypervisor' 'Stops the Windows hypervisor from loading at boot, removing virtualization overhead.' 'Warning' -Warn 'WSL2, Docker, Windows Sandbox and Android emulators stop working until you undo this.' -Reboot $true `
  -Do { bcdedit /set hypervisorlaunchtype off | Out-Null } -Undo { bcdedit /set hypervisorlaunchtype auto | Out-Null }
Add-Tweak 'a_xbox' $cAdv 'Disable Xbox Services' 'Turns off Xbox Live auth, game save, networking and accessory services.' 'Warning' -Warn 'Breaks the Xbox app, Game Pass on PC, Xbox sign-in and cloud saves.' `
  -Do { foreach($sv in 'XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc'){ Set-SvcTracked $sv } }
Add-Tweak 'a_ipv6' $cAdv 'Disable IPv6' 'Forces IPv4 only. Can fix odd routing or DNS delays on some ISPs.' 'Warning' -Warn 'Some games, Xbox Live and ISPs that rely on IPv6 may fail or connect slower.' -Reboot $true `
  -Reg @((Rg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 255))
Add-Tweak 'a_spectre' $cAdv 'Disable CPU Mitigations' 'Turns off Spectre and Meltdown mitigations. Can raise FPS on older Intel CPUs.' 'Warning' -Warn 'Security risk: exposes your CPU to speculative-execution attacks. Avoid on PCs used for banking or work.' -Req { $Spec.Intel } -ReqText 'Needs an Intel CPU' -Reboot $true `
  -Reg @((Rg $MM 'FeatureSettingsOverride' 3), (Rg $MM 'FeatureSettingsOverrideMask' 3))
Add-Tweak 'a_vbs' $cAdv 'Disable VBS / Memory Integrity' 'Turns off Virtualization-Based Security and HVCI, which can cost FPS on some systems.' 'Warning' -Warn 'Lowers kernel protection. Some anti-cheats and work policies expect it on.' -Req { $Spec.Build -ge 19041 } -ReqText 'Needs Windows 10 2004 or newer' -Reboot $true `
  -Reg @((Rg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0), (Rg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0))
Add-Tweak 'a_hib' $cAdv 'Disable Hibernation' 'Deletes hiberfil.sys and frees several GB on the system drive.' 'Caution' -Warn 'Hibernate and Fast Startup stop working.' `
  -Do { powercfg -h off | Out-Null } -Undo { powercfg -h on | Out-Null }

# ---------------------------------------------------------------- apply / undo
function Apply-Tweak($t) {
    $script:CurId = $t.Id
    $State[$t.Id] = @()
    foreach ($rr in $t.Reg) { Set-Tracked $rr[0] $rr[1] $rr[2] $rr[3] }
    if ($t.Do) { & $t.Do }
    if (-not $State.ContainsKey($t.Id)) { $State[$t.Id] = @() }
}
function Undo-Tweak($t) {
    $script:CurId = $t.Id
    $arr = @($State[$t.Id] | Where-Object { $_ }); [array]::Reverse($arr)
    foreach ($e in $arr) { Restore-Entry $e }
    if ($t.Undo) { & $t.Undo }
    $State.Remove($t.Id)
}
function Test-Applicable($t) { if ($t.Req) { [bool](& $t.Req) } else { $true } }
function Get-Tweak($id) { $Tweaks | Where-Object { $_.Id -eq $id } | Select-Object -First 1 }

# ---------------------------------------------------------------- presets
$Presets = [ordered]@{
 'Safe Essentials' = { $Tweaks | Where-Object { $_.Rec -and $_.Risk -eq 'Safe' } }
 'Competitive'     = { $ids = 'f_dvr','f_fso','f_hags','f_fast','f_timerreq','n_rsc','n_eee','f_cpumin','f_usb','f_pcie'; $Tweaks | Where-Object { ($_.Rec -and $_.Risk -eq 'Safe') -or $ids -contains $_.Id } }
 'Max Privacy'     = { $Tweaks | Where-Object { $_.Cat -eq $cPriv -and $_.Risk -eq 'Safe' } }
 'Low-End PC'      = { $ids = 'q_visfx','q_bgapps','f_sysmain','w_edge','w_services','w_svchost','w_prefetch','p_telemetry','p_tasks','q_startdelay','f_throttle'; $Tweaks | Where-Object { $ids -contains $_.Id } }
 'Laptop Safe'     = { $skip = 'f_power','f_cpumin','f_usb','f_pcie','f_throttle'; $Tweaks | Where-Object { $_.Rec -and $_.Risk -eq 'Safe' -and $skip -notcontains $_.Id } }
}

# ---------------------------------------------------------------- game profiles
$Games = @(
 @{ Id='valorant'; Name='VALORANT'; Exes=@('VALORANT-Win64-Shipping.exe'); AC='Riot Vanguard'
    Tweaks=@('f_gamemode','f_dvr','f_overlay','f_throttle','f_prio','f_mmcss','f_mouse','f_hags','f_usb','n_nagle','n_throttle','n_dns')
    Tips=@('Set Material, Texture, Detail and UI Quality to Low.','Turn off Vignette, Bloom, Distortion, Cast Shadows and V-Sync.','Use MSAA 2x with Anisotropic Filtering 1x and keep Multithreaded Rendering on.','Enable NVIDIA Reflex Low Latency (On + Boost) if your GPU supports it.','Cap FPS about 3 below your monitor refresh rate (Limit FPS Always).','Vanguard needs Secure Boot and TPM 2.0 on Windows 11. Memory Integrity (VBS) is not required, so disabling it is optional.')
    Launch='' }
 @{ Id='fortnite'; Name='Fortnite'; Exes=@('FortniteClient-Win64-Shipping.exe'); AC='Easy Anti-Cheat'
    Tweaks=@('f_gamemode','f_dvr','f_overlay','f_throttle','f_prio','f_mmcss','f_mouse','f_hags','f_usb','n_nagle','n_throttle','n_dns')
    Tips=@('Performance Mode gives the most consistent FPS on most PCs. DX12 can feel smoother on some newer or AMD systems, so test both.','Shadows Off is the biggest single FPS gain. Set Effects and Post Processing to Low.','Low Textures and Meshes reduce VRAM use and streaming stutter.','Cap FPS slightly below your monitor refresh rate.')
    Launch='-USEALLAVAILABLECORES -NOSPLASH -NOTEXTURESTREAMING -high'; LaunchWhere='Epic Games Launcher > profile > Settings > Fortnite > Additional Command Line Arguments. Community-reported, test it yourself.' }
 @{ Id='cs2'; Name='Counter-Strike 2'; Exes=@('cs2.exe'); AC='VAC'
    Tweaks=@('f_gamemode','f_dvr','f_overlay','f_throttle','f_prio','f_mmcss','f_mouse','f_fso','f_usb','f_cpumin','n_nagle','n_throttle','n_dns')
    Tips=@('Launch options help only a little. Most gains come from in-game video settings and GPU driver settings.','Set a frame cap 10 above your refresh rate if you want stable frametimes (for example +fps_max 250 for 240 Hz).','Disable V-Sync and use raw mouse input in game.')
    Launch='-novid -fullscreen +fps_max 0 -allow_third_party_software'; LaunchWhere='Steam > right-click CS2 > Properties > Launch Options. For low-end PCs, use +fps_max 60 for stability.' }
 @{ Id='apex'; Name='Apex Legends'; Exes=@('r5apex.exe','r5apex_dx12.exe'); AC='Easy Anti-Cheat'
    Tweaks=@('f_gamemode','f_dvr','f_overlay','f_throttle','f_prio','f_mmcss','f_mouse','f_hags','f_usb','n_nagle','n_throttle','n_dns')
    Tips=@('General advice: use exclusive fullscreen, turn V-Sync off and cap FPS just under your refresh rate.','Lower Texture Streaming Budget if you have little VRAM to avoid stutter.','Update your GPU driver before changing settings.')
    Launch='' }
 @{ Id='warzone'; Name='Call of Duty: Warzone'; Exes=@('cod.exe'); AC='Ricochet'
    Tweaks=@('f_gamemode','f_dvr','f_overlay','f_throttle','f_prio','f_mmcss','f_mouse','f_hags','f_usb','n_nagle','n_throttle','n_dns')
    Tips=@('General advice: pre-compile shaders after each update and keep the game on an SSD.','Cap FPS just under your refresh rate and use exclusive fullscreen.','Close overlays and launchers you do not need while playing.')
    Launch='' }
 @{ Id='fivem'; Name='FiveM / GTA V'; Exes=@('FiveM.exe','FiveM_*GTAProcess.exe','GTA5.exe'); AC=''
    Tweaks=@('f_gamemode','f_dvr','f_overlay','f_throttle','f_prio','f_mmcss','f_mouse','f_usb','f_hags','n_nagle','n_throttle','n_dns','w_edge')
    Tips=@('Press F8 in game and enter cl_drawfps true to show FPS, or cl_drawperf true to show ping, packet loss, CPU and GPU usage.','Turn off MSAA and Reflection MSAA, set Grass Quality to Normal and keep Extended Distance Scaling at its minimum.','Lower str_maxVehicleTextureRes in the console to cut VRAM use on heavy servers.','Server scripts and streamed assets often cause more lag than your graphics settings, so test on a few servers.')
    Launch='' }
 @{ Id='roblox'; Name='Roblox'; Exes=@('RobloxPlayerBeta.exe'); AC='Hyperion'
    Tweaks=@('f_gamemode','f_dvr','f_overlay','f_throttle','f_prio','f_mmcss','f_mouse','f_usb','n_nagle','n_throttle','n_dns')
    Tips=@('General advice: set Graphics Quality manually to a lower level in Roblox settings.','Do not modify Roblox files. Windows-level tweaks are the safe route.','Close extra browser tabs and launchers, because Roblox is CPU-heavy.')
    Launch='' }
 @{ Id='rocketleague'; Name='Rocket League'; Exes=@('RocketLeague.exe'); AC='Easy Anti-Cheat'
    Tweaks=@('f_gamemode','f_dvr','f_overlay','f_throttle','f_prio','f_mmcss','f_mouse','f_usb','n_nagle','n_throttle','n_dns')
    Tips=@('General advice: disable V-Sync and cap FPS at or above your refresh rate for the lowest input lag.','Lower Render Quality and Effects Quality if you see frametime spikes.')
    Launch='' }
 @{ Id='overwatch'; Name='Overwatch 2'; Exes=@('Overwatch.exe'); AC=''
    Tweaks=@('f_gamemode','f_dvr','f_overlay','f_throttle','f_prio','f_mmcss','f_mouse','f_usb','n_nagle','n_throttle','n_dns')
    Tips=@('General advice: enable Reduce Buffering, turn V-Sync off and cap FPS slightly above your refresh rate.','Use Low or Medium Shadow and Effects detail for clearer visuals.')
    Launch='' }
 @{ Id='rust'; Name='Rust'; Exes=@('RustClient.exe'); AC='Easy Anti-Cheat'
    Tweaks=@('f_gamemode','f_dvr','f_overlay','f_throttle','f_prio','f_mmcss','f_mouse','f_usb','n_nagle','n_throttle','n_dns','w_pagingexec')
    Tips=@('General advice: keep the game on an SSD and lower Draw Distance and Shadow Cascades.','Rust is RAM-hungry, so close other apps before playing on 16 GB or less.')
    Launch='' }
)

# ---------------------------------------------------------------- UI
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
  Title="SharkOptimizer" Width="1280" Height="860" MinWidth="1060" MinHeight="680" Background="#08101D" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI">
 <Window.Resources>
  <DrawingImage x:Key="SharkIcon"><DrawingImage.Drawing><DrawingGroup>
   <GeometryDrawing Geometry="M0,0 H48 V48 H0 Z"><GeometryDrawing.Brush><SolidColorBrush Color="#00000000"/></GeometryDrawing.Brush></GeometryDrawing>
   <GeometryDrawing Geometry="M2,30 C9,15 25,10 40,18 L47,9 L45,24 L47,37 L38,31 C28,39 12,38 2,30 Z M19,17 L25,3 L31,15 Z M30,33 L34,41 L24,35 Z"><GeometryDrawing.Brush><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#5BE3FF" Offset="0"/><GradientStop Color="#1B7BFF" Offset="1"/></LinearGradientBrush></GeometryDrawing.Brush></GeometryDrawing>
   <GeometryDrawing Brush="White" Geometry="M10,24 A1.8,1.8 0 1 1 13.6,24 A1.8,1.8 0 1 1 10,24 Z"/>
  </DrawingGroup></DrawingImage.Drawing></DrawingImage>
  <Style TargetType="Button"><Setter Property="Foreground" Value="#E8ECF4"/><Setter Property="Background" Value="#16233A"/><Setter Property="Padding" Value="16,9"/><Setter Property="Margin" Value="4"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontWeight" Value="SemiBold"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="10" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
     <Border.RenderTransform><ScaleTransform x:Name="sc" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
     <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True">
      <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="bd" Storyboard.TargetProperty="Opacity" To="0.82" Duration="0:0:0.12"/></Storyboard></BeginStoryboard></Trigger.EnterActions>
      <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="bd" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.18"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
     </Trigger>
     <Trigger Property="IsPressed" Value="True">
      <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="0.96" Duration="0:0:0.08"/><DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="0.96" Duration="0:0:0.08"/></Storyboard></BeginStoryboard></Trigger.EnterActions>
      <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.15"/><DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.15"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
     </Trigger>
     <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.4"/></Trigger>
    </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style x:Key="NavBtn" TargetType="Button"><Setter Property="Foreground" Value="#C2CCDF"/><Setter Property="Background" Value="#0B1424"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Tag" Value=""/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Grid>
     <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="10" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/></Border>
     <Border x:Name="ind" Width="3" Height="18" CornerRadius="2" Background="#1FB6FF" HorizontalAlignment="Left" Visibility="Collapsed"/>
    </Grid>
    <ControlTemplate.Triggers>
     <Trigger Property="Tag" Value="on"><Setter TargetName="ind" Property="Visibility" Value="Visible"/></Trigger>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger>
    </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style x:Key="SbPage" TargetType="RepeatButton"><Setter Property="Focusable" Value="False"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="ScrollBar"><Setter Property="Width" Value="9"/><Setter Property="Background" Value="Transparent"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar"><Grid Background="Transparent">
    <Track x:Name="PART_Track" IsDirectionReversed="True" Orientation="Vertical">
     <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource SbPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
     <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource SbPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
     <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border x:Name="tb" Background="#2A3A5C" CornerRadius="4" Margin="1"/><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="tb" Property="Background" Value="#1FB6FF"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
    </Track></Grid></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="TextBox"><Setter Property="Background" Value="#0F1A2C"/><Setter Property="Foreground" Value="#E8ECF4"/><Setter Property="BorderBrush" Value="#1E2E4B"/><Setter Property="CaretBrush" Value="White"/><Setter Property="Padding" Value="10,7"/></Style>
  <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#E8ECF4"/><Setter Property="VerticalContentAlignment" Value="Center"/></Style>
  <Style TargetType="ProgressBar"><Setter Property="Height" Value="7"/><Setter Property="Foreground" Value="#35D07F"/><Setter Property="Background" Value="#1E2B45"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Maximum" Value="100"/></Style>
 </Window.Resources>
 <Grid>
  <Grid.ColumnDefinitions><ColumnDefinition Width="190"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <Border Background="#0B1424" BorderBrush="#15213A" BorderThickness="0,0,1,0">
   <DockPanel>
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="18,22,0,26">
     <Image Source="{StaticResource SharkIcon}" Width="38" Height="38"/>
     <StackPanel Margin="10,0,0,0" VerticalAlignment="Center"><TextBlock Text="Shark" Foreground="White" FontWeight="Black" FontSize="17"/><TextBlock Text="OPTIMIZER" Foreground="#1FB6FF" FontWeight="SemiBold" FontSize="10.5" Margin="0,-2,0,0"/></StackPanel>
    </StackPanel>
    <TextBlock x:Name="txtSide" DockPanel.Dock="Bottom" Foreground="#566684" FontSize="11" Margin="16" TextWrapping="Wrap"/>
    <StackPanel>
     <Button x:Name="navDash" Style="{StaticResource NavBtn}" HorizontalContentAlignment="Left" Margin="10,3" Padding="14,10"><StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Text="&#xE80F;" Width="28" VerticalAlignment="Center"/><TextBlock Text="Dashboard" FontSize="13.5"/></StackPanel></Button>
     <Button x:Name="navTweaks" Style="{StaticResource NavBtn}" HorizontalContentAlignment="Left" Margin="10,3" Padding="14,10"><StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Text="&#xE713;" Width="28" VerticalAlignment="Center"/><TextBlock Text="Tweaks" FontSize="13.5"/></StackPanel></Button>
     <Button x:Name="navGames" Style="{StaticResource NavBtn}" HorizontalContentAlignment="Left" Margin="10,3" Padding="14,10"><StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Text="&#xE7FC;" Width="28" VerticalAlignment="Center"/><TextBlock Text="Games" FontSize="13.5"/></StackPanel></Button>
     <Button x:Name="navWin" Style="{StaticResource NavBtn}" HorizontalContentAlignment="Left" Margin="10,3" Padding="14,10"><StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Text="&#xE7F4;" Width="28" VerticalAlignment="Center"/><TextBlock Text="Windows" FontSize="13.5"/></StackPanel></Button>
     <Button x:Name="navBoost" Style="{StaticResource NavBtn}" HorizontalContentAlignment="Left" Margin="10,3" Padding="14,10"><StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Text="&#xE945;" Width="28" VerticalAlignment="Center"/><TextBlock Text="Boost-Up" FontSize="13.5"/></StackPanel></Button>
     <Button x:Name="navNet" Style="{StaticResource NavBtn}" HorizontalContentAlignment="Left" Margin="10,3" Padding="14,10"><StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Text="&#xE774;" Width="28" VerticalAlignment="Center"/><TextBlock Text="Network" FontSize="13.5"/></StackPanel></Button>
     <Button x:Name="navRestore" Style="{StaticResource NavBtn}" HorizontalContentAlignment="Left" Margin="10,3" Padding="14,10"><StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Text="&#xE777;" Width="28" VerticalAlignment="Center"/><TextBlock Text="Restore" FontSize="13.5"/></StackPanel></Button>
     
    </StackPanel>
   </DockPanel>
  </Border>
  <Grid Grid.Column="1" Margin="26,20,26,12">
   <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="96"/></Grid.RowDefinitions>
   <Grid Grid.Row="0">

    <ScrollViewer x:Name="pgDash" VerticalScrollBarVisibility="Auto">
     <StackPanel>
      <TextBlock Text="Welcome to SharkOptimizer" Foreground="White" FontSize="30" FontWeight="Bold"/>
      <TextBlock x:Name="txtTier" Foreground="#7F8FAE" Margin="0,2,0,14"/>
      <UniformGrid Columns="3" Margin="-6,0">
       <Border Margin="6" Padding="18" CornerRadius="14" Background="#0F1A2C" BorderBrush="#1A2943" BorderThickness="1"><StackPanel><TextBlock Text="CPU USAGE" Foreground="#7F8FAE" FontSize="11" FontWeight="SemiBold"/><TextBlock x:Name="txtCpu" Text="0%" Foreground="White" FontSize="34" FontWeight="Bold" Margin="0,2,0,8"/><ProgressBar x:Name="barCpu" Foreground="#35D07F"/></StackPanel></Border> <Border Margin="6" Padding="18" CornerRadius="14" Background="#0F1A2C" BorderBrush="#1A2943" BorderThickness="1"><StackPanel><TextBlock Text="GPU 3D USAGE" Foreground="#7F8FAE" FontSize="11" FontWeight="SemiBold"/><TextBlock x:Name="txtGpu" Text="0%" Foreground="White" FontSize="34" FontWeight="Bold" Margin="0,2,0,8"/><ProgressBar x:Name="barGpu" Foreground="#1FB6FF"/></StackPanel></Border> <Border Margin="6" Padding="18" CornerRadius="14" Background="#0F1A2C" BorderBrush="#1A2943" BorderThickness="1"><StackPanel><TextBlock Text="RAM USAGE" Foreground="#7F8FAE" FontSize="11" FontWeight="SemiBold"/><TextBlock x:Name="txtRam" Text="0%" Foreground="White" FontSize="34" FontWeight="Bold" Margin="0,2,0,8"/><ProgressBar x:Name="barRam" Foreground="#FFC857"/></StackPanel></Border>
      </UniformGrid>
      <UniformGrid Columns="4" Margin="-6,0">
       <Border Margin="6" Padding="16" CornerRadius="14" Background="#0F1A2C" BorderBrush="#1A2943" BorderThickness="1"><StackPanel><TextBlock x:Name="txtActive" Text="0" Foreground="#35D07F" FontSize="26" FontWeight="Bold"/><TextBlock Text="Optimizations active" Foreground="#7F8FAE" FontSize="12"/></StackPanel></Border> <Border Margin="6" Padding="16" CornerRadius="14" Background="#0F1A2C" BorderBrush="#1A2943" BorderThickness="1"><StackPanel><TextBlock x:Name="txtRecCnt" Text="0" Foreground="#FFC857" FontSize="26" FontWeight="Bold"/><TextBlock Text="Recommended pending" Foreground="#7F8FAE" FontSize="12"/></StackPanel></Border> <Border Margin="6" Padding="16" CornerRadius="14" Background="#0F1A2C" BorderBrush="#1A2943" BorderThickness="1"><StackPanel><TextBlock x:Name="txtTotal" Text="0" Foreground="#FFFFFF" FontSize="26" FontWeight="Bold"/><TextBlock Text="Tweaks available" Foreground="#7F8FAE" FontSize="12"/></StackPanel></Border>
       <Border Margin="6" Padding="16" CornerRadius="14" Background="#0F1A2C" BorderBrush="#1A2943" BorderThickness="1"><StackPanel><TextBlock x:Name="txtScore" Text="0%" Foreground="#1FB6FF" FontSize="26" FontWeight="Bold"/><TextBlock Text="Optimization score" Foreground="#7F8FAE" FontSize="12" Margin="0,0,0,6"/><ProgressBar x:Name="barScore" Foreground="#1FB6FF"/></StackPanel></Border>
      </UniformGrid>
      <Border Margin="0,6,0,6" Padding="16" CornerRadius="14" Background="#0F1A2C" BorderBrush="#1A2943" BorderThickness="1">
       <StackPanel><TextBlock Text="Presets" Foreground="White" FontWeight="Bold" Margin="0,0,0,6"/>
        <TextBlock Text="Pick a preset to select its tweaks. You review them on the Tweaks page before anything is applied." Foreground="#7F8FAE" FontSize="12" TextWrapping="Wrap"/>
        <WrapPanel x:Name="pnlPresets" Margin="-4,6,0,0"/></StackPanel></Border>
      <Border Margin="0,6,0,10" Padding="18" CornerRadius="14" Background="#0F1A2C" BorderBrush="#1A2943" BorderThickness="1"><TextBlock x:Name="txtSpecs" Foreground="#C2CCDF" FontFamily="Consolas" FontSize="13" LineHeight="22"/></Border>
      <StackPanel Orientation="Horizontal">
       <Button x:Name="btnDashApply" Content="Apply Recommended" Background="#1FB6FF" Foreground="#06121F"/>
       <Button x:Name="btnDashRP" Content="Create Restore Point"/>
      </StackPanel>
      <TextBlock Text="Recommended applies safe tweaks only." Foreground="#566684" FontSize="11.5" Margin="6,2"/>
     </StackPanel>
    </ScrollViewer>

    <Grid x:Name="pgTweaks" Visibility="Collapsed">
     <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
     <DockPanel Grid.Row="0" Margin="0,0,0,10">
      <TextBlock Text="Tweaks" Foreground="White" FontSize="28" FontWeight="Bold" DockPanel.Dock="Left"/>
      <CheckBox x:Name="chkRec" Content="Recommended only" DockPanel.Dock="Right" Margin="12,0,0,0" VerticalAlignment="Center"/>
      <TextBox x:Name="txtSearch" Width="230" DockPanel.Dock="Right" ToolTip="Search tweaks"/>
      <Grid/>
     </DockPanel>
     <WrapPanel x:Name="chips" Grid.Row="1" Margin="-4,0,0,8"/>
     <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto"><WrapPanel x:Name="wrap"/></ScrollViewer>
     <DockPanel Grid.Row="3" Margin="0,8,0,0">
      <TextBlock x:Name="txtSel" Foreground="#7F8FAE" VerticalAlignment="Center" DockPanel.Dock="Left"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
       <Button x:Name="btnSelRec" Content="Select Recommended"/>
       <Button x:Name="btnSelAll" Content="Select Visible"/>
       <Button x:Name="btnClear" Content="Clear"/>
       <Button x:Name="btnUndo" Content="Undo Selected" Background="#3A1F2B"/>
       <Button x:Name="btnApply" Content="Apply Selected" Background="#1FB6FF" Foreground="#06121F"/>
      </StackPanel>
     </DockPanel>
    </Grid>

    <Grid x:Name="pgGames" Visibility="Collapsed">
     <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
     <StackPanel>
      <TextBlock Text="Games" Foreground="White" FontSize="28" FontWeight="Bold"/>
      <DockPanel Margin="0,2,0,10"><Button x:Name="btnScan" Content="Scan for Games" DockPanel.Dock="Left" Margin="0,4,8,4"/><TextBlock x:Name="txtScan" Foreground="#7F8FAE" VerticalAlignment="Center" Text="Pick a game for a tuned profile. Scan to detect your installs."/></DockPanel>
     </StackPanel>
     <Grid Grid.Row="1"><Grid.ColumnDefinitions><ColumnDefinition Width="260"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="gameList"/></ScrollViewer>
      <ScrollViewer Grid.Column="1" Margin="16,0,0,0" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="gameDetail"/></ScrollViewer>
     </Grid>
    </Grid>

    <ScrollViewer x:Name="pgWin" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
     <StackPanel>
      <TextBlock Text="Windows" Foreground="White" FontSize="28" FontWeight="Bold"/>
      <TextBlock Text="Repair tools, startup control, built-in app removal and a heavy-app closer. More Windows tweaks are under Tweaks > Windows Optimization." Foreground="#7F8FAE" TextWrapping="Wrap"/>
      <TextBlock Text="Quick Tools" Foreground="White" FontSize="16" FontWeight="Bold" Margin="4,20,0,8"/>
      <WrapPanel x:Name="pnlTools" Margin="-4,0"/>
      <TextBlock Text="Startup Apps" Foreground="White" FontSize="16" FontWeight="Bold" Margin="4,20,0,8"/>
      <TextBlock Text="Untick an app to stop it launching at sign-in. Changes apply immediately and can be reversed." Foreground="#7F8FAE" FontSize="12" Margin="4,0,0,6"/>
      <StackPanel x:Name="lstStartup"/>
      <Button x:Name="btnStartRef" Content="Refresh" HorizontalAlignment="Left"/>
      <TextBlock Text="Remove Built-in Apps" Foreground="White" FontSize="16" FontWeight="Bold" Margin="4,20,0,8"/>
      <TextBlock Text="Removes Microsoft apps you may not use. They can be reinstalled from the Microsoft Store, but this cannot be undone here." Foreground="#FFC857" FontSize="12" TextWrapping="Wrap" Margin="4,0,0,6"/>
      <WrapPanel x:Name="lstBloat" Margin="0,0,0,4"/>
      <WrapPanel><Button x:Name="btnBloatRef" Content="Refresh"/><Button x:Name="btnBloat" Content="Remove Selected" Background="#3A1F2B"/></WrapPanel>
      <TextBlock Text="Close Heavy Apps" Foreground="White" FontSize="16" FontWeight="Bold" Margin="4,20,0,8"/>
      <TextBlock Text="Open apps using the most RAM. Closing asks each app to quit normally, so you can still save your work." Foreground="#7F8FAE" FontSize="12" Margin="4,0,0,6"/>
      <StackPanel x:Name="lstProc"/>
      <WrapPanel><Button x:Name="btnProcRef" Content="Refresh"/><Button x:Name="btnProcClose" Content="Close Selected" Background="#1FB6FF" Foreground="#06121F"/></WrapPanel>
     </StackPanel>
    </ScrollViewer>

    <Grid x:Name="pgBoost" Visibility="Collapsed">
     <StackPanel>
      <TextBlock Text="Boost-Up" Foreground="White" FontSize="28" FontWeight="Bold"/>
      <TextBlock Text="Routine cleanups. Run monthly or when your PC feels slow." Foreground="#7F8FAE" Margin="0,0,0,14"/>
      <ScrollViewer MaxHeight="520" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="lstBoost"/></ScrollViewer>
      <Button x:Name="btnBoostAll" Content="Run All" Background="#1FB6FF" Foreground="#06121F" HorizontalAlignment="Left" Margin="0,10"/>
     </StackPanel>
    </Grid>

    <Grid x:Name="pgNet" Visibility="Collapsed">
     <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
     <StackPanel>
      <TextBlock Text="Network &amp; Ping" Foreground="White" FontSize="28" FontWeight="Bold"/>
      <TextBlock Text="Measures ping, jitter and packet loss. Region tests use cloud endpoints as a route-quality guide. Enter a game server host to test it directly." Foreground="#7F8FAE" TextWrapping="Wrap" Margin="0,0,0,12"/>
      <WrapPanel>
       <Button x:Name="btnPing" Content="Test Regions"/>
       <TextBox x:Name="txtHost" Width="220" Margin="4" ToolTip="Host or IP of your game server"/>
       <Button x:Name="btnHost" Content="Test Host"/>
       <Button x:Name="btnDns" Content="DNS Benchmark"/>
       <Button x:Name="btnBestDns" Content="Apply Best DNS" Background="#1FB6FF" Foreground="#06121F"/>
       <Button x:Name="btnFlush" Content="Flush DNS"/>
      </WrapPanel>
     </StackPanel>
     <TextBox x:Name="txtNet" Grid.Row="1" IsReadOnly="True" FontFamily="Consolas" FontSize="12.5" VerticalScrollBarVisibility="Auto" Margin="4,8,0,0"/>
    </Grid>

    <Grid x:Name="pgRestore" Visibility="Collapsed">
     <StackPanel>
      <TextBlock Text="Restore" Foreground="White" FontSize="28" FontWeight="Bold"/>
      <TextBlock Text="Every change is recorded, so you can revert it at any time." Foreground="#7F8FAE" Margin="0,0,0,12"/>
      <WrapPanel>
       <Button x:Name="btnRP" Content="Create Restore Point"/>
       <Button x:Name="btnUndoAll" Content="Undo All Tweaks" Background="#3A1F2B"/>
       <Button x:Name="btnLog" Content="Open Log"/>
      </WrapPanel>
      <TextBlock Text="Currently applied" Foreground="White" FontWeight="Bold" Margin="4,16,0,6"/>
      <TextBlock x:Name="txtApplied" Foreground="#C2CCDF" TextWrapping="Wrap" Margin="4,0"/>
     </StackPanel>
    </Grid>
   </Grid>
   <TextBox x:Name="txtLog" Grid.Row="1" IsReadOnly="True" FontFamily="Consolas" FontSize="11.5" VerticalScrollBarVisibility="Auto" Margin="0,10,0,0"/>
  </Grid>
 </Grid>
</Window>
'@
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
$window.Icon = $window.FindResource('SharkIcon')
$ui = @{}
foreach ($nm in 'navDash','navTweaks','navGames','navWin','navBoost','navNet','navRestore','txtSide','pgDash','pgTweaks','pgGames','pgWin','pgBoost','pgNet','pgRestore','txtTier','txtCpu','barCpu','txtGpu','barGpu','txtRam','barRam','txtActive','txtRecCnt','txtTotal','txtScore','barScore','pnlPresets','txtSpecs','btnDashApply','btnDashRP','chkRec','txtSearch','chips','wrap','txtSel','btnSelRec','btnSelAll','btnClear','btnUndo','btnApply','btnScan','txtScan','gameList','gameDetail','pnlTools','lstStartup','btnStartRef','lstBloat','btnBloatRef','btnBloat','lstProc','btnProcRef','btnProcClose','lstBoost','btnBoostAll','btnPing','txtHost','btnHost','btnDns','btnBestDns','btnFlush','txtNet','btnRP','btnUndoAll','btnLog','txtApplied','txtLog') {
    $ui[$nm] = $window.FindName($nm)
    if (-not $ui[$nm]) { throw "UI element not found: $nm" }
}

function Brush($hex) { [Windows.Media.BrushConverter]::new().ConvertFromString($hex) }
function Flush-UI { $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background) }
function Log($m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    $ui.txtLog.AppendText($line + "`r`n"); $ui.txtLog.ScrollToEnd()
    Add-Content $LogFile $line -ErrorAction SilentlyContinue
    Flush-UI
}
function New-Text($text, $size = 12, $color = '#C2CCDF', $bold = $false, $margin = '0') {
    $tb = New-Object Windows.Controls.TextBlock; $tb.Text = $text; $tb.FontSize = $size; $tb.Foreground = Brush $color
    $tb.TextWrapping = 'Wrap'; $tb.Margin = $margin; if ($bold) { $tb.FontWeight = 'Bold' }; $tb
}
function New-RestorePoint {
    Log 'Creating restore point...'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord -Force
        Checkpoint-Computer -Description 'SharkOptimizer' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Log 'Restore point created.'
    } catch { Log "Restore point failed: $($_.Exception.Message)" }
}

$ui.txtSide.Text = "$($Spec.CPU)`n$($Spec.GPU)"
$ui.txtTier.Text = "$($Spec.Tier) PC  -  tweaks matched to your hardware"
$ui.txtSpecs.Text = @(
 "OS       $($Spec.OS)  (build $($Spec.Build))",
 "CPU      $($Spec.CPU)  [$($Spec.Cores)C / $($Spec.Threads)T]",
 "GPU      $($Spec.GPU)",
 "RAM      $($Spec.RamGB) GB",
 "Storage  $(if($Spec.SSD){'SSD'}else{'HDD or unknown'}) system drive",
 "Type     $(if($Spec.Laptop){'Laptop'}else{'Desktop'})",
 "Network  $(if($Spec.Wifi){'Wi-Fi'}else{'Ethernet'})  ($($Spec.Nics -join ', '))") -join "`n"

$pages = [ordered]@{ navDash='pgDash'; navTweaks='pgTweaks'; navGames='pgGames'; navWin='pgWin'; navBoost='pgBoost'; navNet='pgNet'; navRestore='pgRestore' }

# ---- animation helpers
function Animate-In($el, $delayMs = 0, $dist = 12, $ms = 280, $to = 1) {
    try {
        $ease = New-Object Windows.Media.Animation.CubicEase; $ease.EasingMode = 'EaseOut'
        $a1 = New-Object Windows.Media.Animation.DoubleAnimation; $a1.From = 0; $a1.To = [double]$to
        $a1.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($ms)); $a1.BeginTime = [TimeSpan]::FromMilliseconds($delayMs); $a1.EasingFunction = $ease
        $tt = New-Object Windows.Media.TranslateTransform; $tt.Y = $dist
        $a2 = New-Object Windows.Media.Animation.DoubleAnimation; $a2.From = $dist; $a2.To = 0
        $a2.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($ms)); $a2.BeginTime = [TimeSpan]::FromMilliseconds($delayMs); $a2.EasingFunction = $ease
        $el.RenderTransform = $tt
        $el.Opacity = 0
        $el.BeginAnimation([Windows.UIElement]::OpacityProperty, $a1)
        $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $a2)
    } catch { try { $el.Opacity = $to } catch {} }
}
function Set-Bar($bar, $val) {
    try {
        $ease = New-Object Windows.Media.Animation.CubicEase; $ease.EasingMode = 'EaseOut'
        $a = New-Object Windows.Media.Animation.DoubleAnimation; $a.To = [double]$val
        $a.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(700)); $a.EasingFunction = $ease
        $bar.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty, $a)
    } catch { $bar.Value = $val }
}
function Show-Page($nav) {
    foreach ($k in @($pages.Keys)) {
        $on = ($k -eq $nav)
        $ui[$pages[$k]].Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
        $ui[$k].Tag = if ($on) { 'on' } else { '' }
        $ui[$k].Background = if ($on) { Brush '#10304A' } else { Brush '#0B1424' }
        $ui[$k].Foreground = if ($on) { Brush '#1FB6FF' } else { Brush '#C2CCDF' }
    }
    Animate-In $ui[$pages[$nav]] 0 14 300
    Update-Stats
}
foreach ($k in @($pages.Keys)) { $ui[$k].Add_Click({ Show-Page $this.Name }) }

$script:Selected = New-Object 'System.Collections.Generic.HashSet[string]'
$script:CatFilter = 'All'
$cats = 'All','Privacy & Security','Quality of Life','FPS & Latency','Network & Ping','Windows Optimization','Advanced'

function Update-Stats {
    $ui.txtActive.Text = "$(@($State.Keys | Where-Object { $_ -notlike 'game_*' }).Count)"
    $ui.txtTotal.Text  = "$($Tweaks.Count)"
    $rec = @($Tweaks | Where-Object { $_.Rec -and (Test-Applicable $_) })
    $done = @($rec | Where-Object { $State.ContainsKey($_.Id) }).Count
    $ui.txtRecCnt.Text = "$($rec.Count - $done)"
    $score = if ($rec.Count) { [math]::Round(100 * $done / $rec.Count) } else { 100 }
    $ui.txtScore.Text = "$score%"; Set-Bar $ui.barScore $score
    $ui.txtApplied.Text = if ($State.Keys.Count) { (($State.Keys | Sort-Object | ForEach-Object { $id = $_; $tw = Get-Tweak $id; if ($tw) { "-  $($tw.Name)" } else { "-  Game profile: $($id -replace '^game_','')" } }) -join "`n") } else { 'Nothing applied yet.' }
    $ui.txtSel.Text = "$($script:Selected.Count) selected"
}
function New-Tag($text, $bg, $fg) {
    $b = New-Object Windows.Controls.Border; $b.Background = Brush $bg; $b.CornerRadius = 6; $b.Padding = '8,3'; $b.Margin = '0,0,6,6'
    $tb = New-Object Windows.Controls.TextBlock; $tb.Text = $text; $tb.Foreground = Brush $fg; $tb.FontSize = 10.5; $tb.FontWeight = 'SemiBold'
    $b.Child = $tb; $b
}
function New-Card($t) {
    $ok = Test-Applicable $t
    $active = $State.ContainsKey($t.Id)
    $card = New-Object Windows.Controls.Border
    $card.Width = 356; $card.Margin = '0,0,14,14'; $card.Padding = '16'; $card.CornerRadius = 14; $card.Background = Brush '#0F1A2C'; $card.BorderThickness = 1
    $card.BorderBrush = Brush $(if ($active) { '#35D07F' } elseif ($t.Risk -eq 'Warning') { '#6E2A33' } else { '#1A2943' })
    $card.Opacity = $(if ($ok) { 1 } else { 0.5 })
    $card.Tag = $card.BorderBrush; $card.Add_MouseEnter({ $this.Background = Brush '#13213A'; $this.BorderBrush = Brush '#1FB6FF' })
    $card.Add_MouseLeave({ $this.Background = Brush '#0F1A2C'; $this.BorderBrush = $this.Tag })
    $stack = New-Object Windows.Controls.StackPanel
    $tags = New-Object Windows.Controls.WrapPanel
    $tags.Children.Add((New-Tag $t.Cat '#1B2E4F' '#8FB2EE')) | Out-Null
    switch ($t.Risk) {
        'Safe'    { $tags.Children.Add((New-Tag 'SAFE' '#14352A' '#35D07F')) | Out-Null }
        'Caution' { $tags.Children.Add((New-Tag 'CAUTION' '#3A3016' '#FFC857')) | Out-Null }
        'Warning' { $tags.Children.Add((New-Tag 'CORE WINDOWS CHANGE' '#40191F' '#FF6B6B')) | Out-Null }
    }
    if ($t.Rec -and $ok) { $tags.Children.Add((New-Tag 'FOR YOUR PC' '#0F2E45' '#1FB6FF')) | Out-Null }
    if ($t.Reboot) { $tags.Children.Add((New-Tag 'RESTART NEEDED' '#25254A' '#A9A9FF')) | Out-Null }
    $stack.Children.Add($tags) | Out-Null
    $stack.Children.Add((New-Text $t.Name 15.5 '#FFFFFF' $true)) | Out-Null
    $desc = New-Text $t.Desc 12 '#7F8FAE' $false '0,6,0,8'; $desc.MinHeight = 48; $stack.Children.Add($desc) | Out-Null
    if ($t.Warn) { $stack.Children.Add((New-Text $t.Warn 11.5 $(if ($t.Risk -eq 'Warning') { '#FF8A8A' } else { '#FFC857' }) $false '0,0,0,8')) | Out-Null }
    if (-not $ok) { $stack.Children.Add((New-Text $t.ReqText 11.5 '#7F8FAE' $false '0,0,0,8')) | Out-Null }
    $row = New-Object Windows.Controls.DockPanel
    $cb = New-Object Windows.Controls.CheckBox; $cb.Content = 'Select'; $cb.Tag = $t.Id; $cb.IsEnabled = $ok; $cb.IsChecked = $script:Selected.Contains($t.Id)
    $cb.Add_Click({ if ($this.IsChecked) { [void]$script:Selected.Add($this.Tag) } else { [void]$script:Selected.Remove($this.Tag) }; Update-Stats })
    $st = New-Object Windows.Controls.TextBlock; $st.HorizontalAlignment = 'Right'; $st.FontSize = 11.5; $st.FontWeight = 'SemiBold'
    $st.Text = $(if ($active) { 'ACTIVE' } else { 'Inactive' }); $st.Foreground = Brush $(if ($active) { '#35D07F' } else { '#566684' })
    [Windows.Controls.DockPanel]::SetDock($cb, 'Left'); $row.Children.Add($cb) | Out-Null; $row.Children.Add($st) | Out-Null
    $stack.Children.Add($row) | Out-Null
    $card.Child = $stack; $card
}
function Get-Visible {
    $q = $ui.txtSearch.Text.Trim()
    $Tweaks | Where-Object {
        ($script:CatFilter -eq 'All' -or $_.Cat -eq $script:CatFilter) -and
        (-not $q -or $_.Name -like "*$q*" -or $_.Desc -like "*$q*") -and
        (-not $ui.chkRec.IsChecked -or ($_.Rec -and (Test-Applicable $_)))
    }
}
function Render-Tweaks {
    $ui.wrap.Children.Clear(); $script:cardIdx = 0
    foreach ($tw in @(Get-Visible)) { $cd = New-Card $tw; $ui.wrap.Children.Add($cd) | Out-Null; $tgt = $(if (Test-Applicable $tw) { 1 } else { 0.5 }); Animate-In $cd ([math]::Min($script:cardIdx * 16, 360)) 10 240 $tgt; $script:cardIdx++ }
    foreach ($chip in $ui.chips.Children) {
        $on = ($chip.Tag -eq $script:CatFilter)
        $chip.Background = Brush $(if ($on) { '#1FB6FF' } else { '#16233A' }); $chip.Foreground = Brush $(if ($on) { '#06121F' } else { '#C2CCDF' })
    }
    Update-Stats
}
foreach ($cat in $cats) {
    $chipBtn = New-Object Windows.Controls.Button; $chipBtn.Content = $cat; $chipBtn.Tag = $cat; $chipBtn.Padding = '14,7'
    $chipBtn.Add_Click({ $script:CatFilter = $this.Tag; Render-Tweaks }); $ui.chips.Children.Add($chipBtn) | Out-Null
}
$ui.txtSearch.Add_TextChanged({ Render-Tweaks })
$ui.chkRec.Add_Click({ Render-Tweaks })
$ui.btnSelRec.Add_Click({ foreach ($tw in $Tweaks) { if ($tw.Rec -and $tw.Risk -eq 'Safe' -and (Test-Applicable $tw) -and -not $State.ContainsKey($tw.Id)) { [void]$script:Selected.Add($tw.Id) } }; Render-Tweaks })
$ui.btnSelAll.Add_Click({ foreach ($tw in @(Get-Visible)) { if (Test-Applicable $tw) { [void]$script:Selected.Add($tw.Id) } }; Render-Tweaks })
$ui.btnClear.Add_Click({ $script:Selected.Clear(); Render-Tweaks })

function Invoke-Apply($list) {
    $list = @($list)
    if (-not $list.Count) { [void][Windows.MessageBox]::Show('Nothing selected.', 'SharkOptimizer'); return }
    $risky = @($list | Where-Object { $_.Risk -ne 'Safe' })
    if ($risky.Count) {
        $msg = "These tweaks change how Windows behaves:`n`n" + (($risky | ForEach-Object { "[$($_.Risk.ToUpper())] $($_.Name)`n   $($_.Warn)" }) -join "`n`n") + "`n`nA restore point is created first. Continue?"
        if ([Windows.MessageBox]::Show($msg, 'SharkOptimizer - review before applying', 'YesNo', 'Warning') -ne 'Yes') { return $false }
    }
    New-RestorePoint
    $reboot = $false
    foreach ($tw in $list) {
        Log "Applying: $($tw.Name)"
        try { Apply-Tweak $tw; if ($tw.Reboot) { $reboot = $true } } catch { Log "  Failed: $($_.Exception.Message)" }
    }
    Save-State; $script:Selected.Clear(); Render-Tweaks
    Log 'Done.'
    if ($reboot) { Log 'Some tweaks need a restart.'; [void][Windows.MessageBox]::Show('Done. Restart your PC to finish applying all changes.', 'SharkOptimizer') }
    return $true
}
function Invoke-Undo($list) {
    foreach ($tw in @($list)) {
        if (-not $State.ContainsKey($tw.Id)) { continue }
        Log "Undoing: $($tw.Name)"
        try { Undo-Tweak $tw } catch { Log "  Failed: $($_.Exception.Message)" }
    }
    Save-State; $script:Selected.Clear(); Render-Tweaks; Log 'Undo finished.'
}
$ui.btnApply.Add_Click({ [void](Invoke-Apply ($Tweaks | Where-Object { $script:Selected.Contains($_.Id) })) })
$ui.btnUndo.Add_Click({ Invoke-Undo ($Tweaks | Where-Object { $script:Selected.Contains($_.Id) }) })
$ui.btnDashApply.Add_Click({ [void](Invoke-Apply ($Tweaks | Where-Object { $_.Rec -and $_.Risk -eq 'Safe' -and (Test-Applicable $_) -and -not $State.ContainsKey($_.Id) })); Update-Stats })
$ui.btnDashRP.Add_Click({ New-RestorePoint })
$ui.btnRP.Add_Click({ New-RestorePoint })
$ui.btnUndoAll.Add_Click({
    if ([Windows.MessageBox]::Show('Revert every applied tweak and game profile?', 'Undo all', 'YesNo', 'Question') -eq 'Yes') {
        Invoke-Undo ($Tweaks | Where-Object { $State.ContainsKey($_.Id) })
        foreach ($gk in @($State.Keys | Where-Object { $_ -like 'game_*' })) { Undo-GameKey $gk }
        Save-State; Update-Stats
    }
})
$ui.btnLog.Add_Click({ Start-Process notepad.exe $LogFile })

# presets
foreach ($pn in @($Presets.Keys)) {
    $pb = New-Object Windows.Controls.Button; $pb.Content = $pn; $pb.Tag = $pn; $pb.Padding = '14,8'
    $pb.Add_Click({
        $name = $this.Tag
        $list = @(& $Presets[$name])
        $script:Selected.Clear()
        foreach ($tw in $list) { if ((Test-Applicable $tw) -and -not $State.ContainsKey($tw.Id)) { [void]$script:Selected.Add($tw.Id) } }
        $script:CatFilter = 'All'; $ui.chkRec.IsChecked = $false; $ui.txtSearch.Text = ''
        Render-Tweaks; Show-Page 'navTweaks'
        Log "Preset '$name': $($script:Selected.Count) tweaks selected. Review them, then click Apply Selected."
    })
    $ui.pnlPresets.Children.Add($pb) | Out-Null
}

# ---------------------------------------------------------------- Boost-Up
function Remove-Dir($path) {
    $freed = 0
    Get-ChildItem -LiteralPath $path -Force -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
        $len = $_.Length; try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $freed += $len } catch {}
    }
    $freed
}
try { Add-Type -Name Mem -Namespace Boost -MemberDefinition '[System.Runtime.InteropServices.DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(System.IntPtr h);' -ErrorAction Stop } catch {}
$BoostItems = @(
 @{ Name='Junk Cleaner'; Desc='Temp files, update download cache, crash dumps and the Recycle Bin.'; Run={
     $fr = 0; foreach($dir in $env:TEMP,'C:\Windows\Temp',"$env:LOCALAPPDATA\CrashDumps",'C:\ProgramData\Microsoft\Windows\WER\ReportArchive'){ $fr += Remove-Dir $dir }
     Stop-Service wuauserv -Force -ErrorAction SilentlyContinue; $fr += Remove-Dir 'C:\Windows\SoftwareDistribution\Download'; Start-Service wuauserv -ErrorAction SilentlyContinue
     Clear-RecycleBin -Force -ErrorAction SilentlyContinue
     "freed {0:N0} MB" -f ($fr/1MB) } },
 @{ Name='Optimize Drives'; Desc='TRIM on SSDs, defrag on HDDs (system drive).'; Run={
     $dl = [string]$env:SystemDrive[0]; if ($Spec.SSD) { Optimize-Volume -DriveLetter $dl -ReTrim -ErrorAction Stop | Out-Null; 'TRIM complete' } else { Optimize-Volume -DriveLetter $dl -Defrag -ErrorAction Stop | Out-Null; 'defrag complete' } } },
 @{ Name='Clean Recent Documents'; Desc='Clears your Explorer recent files history.'; Run={ $fr = Remove-Dir "$env:APPDATA\Microsoft\Windows\Recent"; 'cleared' } },
 @{ Name='Clean Thumbnail Cache'; Desc='Rebuilds Explorer thumbnails and fixes broken previews.'; Run={ $fr = Remove-Dir "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"; "freed {0:N1} MB" -f ($fr/1MB) } },
 @{ Name='Clean Font Cache'; Desc='Resets the Windows font cache.'; Run={ Stop-Service FontCache -Force -ErrorAction SilentlyContinue; $fr = Remove-Dir 'C:\Windows\ServiceProfiles\LocalService\AppData\Local\FontCache'; Start-Service FontCache -ErrorAction SilentlyContinue; 'done' } },
 @{ Name='Clear Shader Caches'; Desc='DirectX, NVIDIA and AMD shader caches. Your first game launch afterwards may stutter while they rebuild.'; Run={
     $fr = 0; foreach($dir in "$env:LOCALAPPDATA\D3DSCache","$env:LOCALAPPDATA\NVIDIA\DXCache","$env:LOCALAPPDATA\NVIDIA\GLCache","$env:LOCALAPPDATA\AMD\DxCache"){ if(Test-Path $dir){ $fr += Remove-Dir $dir } }
     "freed {0:N0} MB" -f ($fr/1MB) } },
 @{ Name='Clean Browser Caches'; Desc='Cache folders for Chrome, Edge, Brave and Firefox. Logins and bookmarks are kept.'; Run={
     $fr = 0
     foreach($dir in "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache","$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache","$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache","$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache","$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache"){ if(Test-Path $dir){ $fr += Remove-Dir $dir } }
     Get-ChildItem "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $c = Join-Path $_.FullName 'cache2'; if (Test-Path $c) { $fr += Remove-Dir $c } }
     "freed {0:N0} MB" -f ($fr/1MB) } },
 @{ Name='Trim Process RAM'; Desc='Trims background process memory. The effect is temporary.'; Run={
     $before = (New-Object Microsoft.VisualBasic.Devices.ComputerInfo).AvailablePhysicalMemory
     Get-Process | ForEach-Object { try { [void][Boost.Mem]::EmptyWorkingSet($_.Handle) } catch {} }
     $after = (New-Object Microsoft.VisualBasic.Devices.ComputerInfo).AvailablePhysicalMemory
     "freed {0:N0} MB RAM" -f (($after-$before)/1MB) } },
 @{ Name='Flush DNS Cache'; Desc='Clears stale DNS entries.'; Run={ ipconfig /flushdns | Out-Null; 'flushed' } }
)
$boostStatus = @{}
foreach ($bi in $BoostItems) {
    $brow = New-Object Windows.Controls.Border; $brow.Background = Brush '#0F1A2C'; $brow.BorderBrush = Brush '#1A2943'; $brow.BorderThickness = 1; $brow.CornerRadius = 12; $brow.Padding = '16,10'; $brow.Margin = '0,0,0,8'
    $dock = New-Object Windows.Controls.DockPanel
    $runBtn = New-Object Windows.Controls.Button; $runBtn.Content = 'Run'; $runBtn.Tag = $bi.Name; [Windows.Controls.DockPanel]::SetDock($runBtn, 'Right')
    $stat = New-Text 'Not run yet' 12 '#7F8FAE' $false '0,0,14,0'; $stat.VerticalAlignment = 'Center'
    [Windows.Controls.DockPanel]::SetDock($stat, 'Right'); $boostStatus[$bi.Name] = $stat
    $tx = New-Object Windows.Controls.StackPanel
    $tx.Children.Add((New-Text $bi.Name 14 '#FFFFFF' $true)) | Out-Null; $tx.Children.Add((New-Text $bi.Desc 12 '#7F8FAE')) | Out-Null
    $dock.Children.Add($runBtn) | Out-Null; $dock.Children.Add($stat) | Out-Null; $dock.Children.Add($tx) | Out-Null
    $brow.Child = $dock; $ui.lstBoost.Children.Add($brow) | Out-Null
    $runBtn.Add_Click({ Run-Boost $this.Tag })
}
function Run-Boost($name) {
    $item = $BoostItems | Where-Object { $_.Name -eq $name }
    $s = $boostStatus[$name]; $s.Text = 'Running...'; $s.Foreground = Brush '#FFC857'; Flush-UI
    try { $res = & $item.Run; $s.Text = "$res  -  $(Get-Date -Format HH:mm)"; $s.Foreground = Brush '#35D07F'; Log "Boost: $name - $res" }
    catch { $s.Text = 'Failed'; $s.Foreground = Brush '#FF6B6B'; Log "Boost: $name failed - $($_.Exception.Message)" }
}
$ui.btnBoostAll.Add_Click({ foreach ($bi2 in $BoostItems) { Run-Boost $bi2.Name } })

# ---------------------------------------------------------------- Network tools
function Test-Tcp($hostName, $port = 443, $count = 8) {
    $times = @(); $lost = 0
    for ($i = 0; $i -lt $count; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew(); $tc = New-Object Net.Sockets.TcpClient
        try {
            $iar = $tc.BeginConnect($hostName, $port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(1500) -and $tc.Connected) { $times += $sw.Elapsed.TotalMilliseconds } else { $lost++ }
        } catch { $lost++ } finally { $tc.Close() }
        Start-Sleep -Milliseconds 80
    }
    if ($times.Count) {
        $avg = ($times | Measure-Object -Average).Average; $jit = 0
        for ($i = 1; $i -lt $times.Count; $i++) { $jit += [math]::Abs($times[$i] - $times[$i-1]) }
        if ($times.Count -gt 1) { $jit /= ($times.Count - 1) }
        [pscustomobject]@{ Host=$hostName; Avg=[math]::Round($avg,1); Min=[math]::Round(($times|Measure-Object -Minimum).Minimum,1); Jitter=[math]::Round($jit,1); Loss=[math]::Round(100*$lost/$count) }
    } else { [pscustomobject]@{ Host=$hostName; Avg=$null; Min=$null; Jitter=$null; Loss=100 } }
}
function Net-Line($label, $r) {
    if ($null -eq $r.Avg) { "{0,-20} timeout (100% loss)" -f $label }
    else { "{0,-20} {1,7} ms   min {2,6}   jitter {3,5}   loss {4}%" -f $label, $r.Avg, $r.Min, $r.Jitter, $r.Loss }
}
$Regions = [ordered]@{
 'Cloudflare DNS'='1.1.1.1'; 'Google DNS'='8.8.8.8'; 'EU Frankfurt'='ec2.eu-central-1.amazonaws.com'; 'EU Ireland'='ec2.eu-west-1.amazonaws.com'
 'EU London'='ec2.eu-west-2.amazonaws.com'; 'EU Stockholm'='ec2.eu-north-1.amazonaws.com'; 'US East'='ec2.us-east-1.amazonaws.com'
 'US West'='ec2.us-west-2.amazonaws.com'; 'South America'='ec2.sa-east-1.amazonaws.com'; 'Asia Tokyo'='ec2.ap-northeast-1.amazonaws.com'
 'Asia Singapore'='ec2.ap-southeast-1.amazonaws.com'; 'Oceania Sydney'='ec2.ap-southeast-2.amazonaws.com' }
$ui.btnPing.Add_Click({
    $ui.txtNet.Text = "REGION LATENCY (TCP 443)`r`n" + ('-' * 72) + "`r`n"; Flush-UI
    foreach ($rk in @($Regions.Keys)) { $res = Test-Tcp $Regions[$rk]; $ui.txtNet.AppendText((Net-Line $rk $res) + "`r`n"); Flush-UI }
    $ui.txtNet.AppendText("`r`nUnder 40 ms is great. Jitter under 5 ms is stable. Ethernet beats Wi-Fi.`r`n")
})
$ui.btnHost.Add_Click({
    $h = $ui.txtHost.Text.Trim(); if (-not $h) { $ui.txtNet.Text = 'Enter a host or IP first.'; return }
    $ui.txtNet.AppendText("`r`nTesting $h ...`r`n"); Flush-UI
    $ui.txtNet.AppendText((Net-Line $h (Test-Tcp $h 443 12)) + "`r`n")
})
$script:BestDns = $null
$ui.btnDns.Add_Click({
    $servers = [ordered]@{ 'Cloudflare'=@('1.1.1.1','1.0.0.1'); 'Google'=@('8.8.8.8','8.8.4.4'); 'Quad9'=@('9.9.9.9','149.112.112.112'); 'OpenDNS'=@('208.67.222.222','208.67.220.220') }
    $dnames = 'google.com','youtube.com','cloudflare.com','wikipedia.org','steampowered.com','epicgames.com'
    $ui.txtNet.Text = "DNS BENCHMARK (average lookup time)`r`n" + ('-' * 48) + "`r`n"; Flush-UI
    $best = $null; $bestMs = 1e9
    foreach ($sk in @($servers.Keys)) {
        $tm = @()
        foreach ($dn in $dnames) { $sw = [Diagnostics.Stopwatch]::StartNew(); try { Resolve-DnsName $dn -Server $servers[$sk][0] -DnsOnly -ErrorAction Stop | Out-Null; $tm += $sw.Elapsed.TotalMilliseconds } catch {} }
        if ($tm.Count) { $ms = [math]::Round(($tm | Measure-Object -Average).Average, 1); $ui.txtNet.AppendText(("{0,-12} {1,-18} {2,7} ms`r`n" -f $sk, $servers[$sk][0], $ms)); if ($ms -lt $bestMs) { $bestMs = $ms; $best = $sk } }
        else { $ui.txtNet.AppendText(("{0,-12} {1,-18} unreachable`r`n" -f $sk, $servers[$sk][0])) }
        Flush-UI
    }
    if ($best) { $script:BestDns = $servers[$best]; $ui.txtNet.AppendText("`r`nFastest: $best. Click Apply Best DNS to use it.`r`n") }
})
$ui.btnBestDns.Add_Click({
    if (-not $script:BestDns) { $ui.txtNet.AppendText("`r`nRun the DNS Benchmark first.`r`n"); return }
    foreach ($ad in @(Get-UpAdapters)) { Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses $script:BestDns }
    Log "DNS set to $($script:BestDns -join ', ')."
    $ui.txtNet.AppendText("`r`nDNS applied: $($script:BestDns -join ', ')`r`n")
})
$ui.btnFlush.Add_Click({ ipconfig /flushdns | Out-Null; Log 'DNS cache flushed.'; $ui.txtNet.AppendText("`r`nDNS cache flushed.`r`n") })

# ---------------------------------------------------------------- Games
$script:GamePaths = @{}
$script:CurGame = $null
$IFEO = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$GPUPREF = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'

function Get-GameRoots {
    $roots = New-Object System.Collections.ArrayList
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ($steam) {
        [void]$roots.Add((Join-Path $steam 'steamapps\common'))
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($mm in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                [void]$roots.Add((Join-Path ($mm.Groups[1].Value -replace '\\\\', '\') 'steamapps\common'))
            }
        }
    }
    foreach ($pth in "$env:ProgramFiles\Epic Games", "${env:ProgramFiles(x86)}\Epic Games", "$env:ProgramFiles\Riot Games", 'C:\Riot Games', "$env:LOCALAPPDATA\FiveM", "$env:LOCALAPPDATA\Roblox\Versions", "${env:ProgramFiles(x86)}\Overwatch", "$env:ProgramFiles\Call of Duty", "${env:ProgramFiles(x86)}\Call of Duty", "$env:ProgramFiles\Rockstar Games", "${env:ProgramFiles(x86)}\Rockstar Games") { [void]$roots.Add($pth) }
    foreach ($dv in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        foreach ($sub in 'Games','Epic Games','SteamLibrary\steamapps\common','Riot Games') { [void]$roots.Add((Join-Path $dv.Root $sub)) }
    }
    @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}
function Scan-Games {
    $ui.btnScan.IsEnabled = $false
    $patterns = @($Games | ForEach-Object { $_.Exes } | Select-Object -Unique)
    $hits = New-Object System.Collections.ArrayList
    foreach ($root in @(Get-GameRoots)) {
        $ui.txtScan.Text = "Scanning $root ..."; Flush-UI
        Get-ChildItem -Path $root -Recurse -Depth 5 -File -Include $patterns -ErrorAction SilentlyContinue | ForEach-Object { [void]$hits.Add($_) }
    }
    $script:GamePaths = @{}
    foreach ($g in $Games) {
        $mine = @()
        foreach ($h in $hits) { foreach ($pt in $g.Exes) { if ($h.Name -like $pt) { $mine += $h.FullName; break } } }
        $script:GamePaths[$g.Id] = @($mine | Select-Object -Unique)
    }
    $n = @($Games | Where-Object { @($script:GamePaths[$_.Id]).Count -gt 0 }).Count
    $ui.txtScan.Text = "Scan finished. Found $n of $($Games.Count) supported games."
    $ui.btnScan.IsEnabled = $true
    Render-GameList
    if ($script:CurGame) { Show-Game $script:CurGame }
    Log "Game scan: $n games found."
}
function Render-GameList {
    $ui.gameList.Children.Clear()
    foreach ($g in $Games) {
        $found = @($script:GamePaths[$g.Id]).Count -gt 0
        $applied = $State.ContainsKey("game_$($g.Id)")
        $b = New-Object Windows.Controls.Button; $b.Tag = $g.Id; $b.HorizontalContentAlignment = 'Stretch'; $b.Padding = '14,10'; $b.Margin = '0,0,6,6'
        $b.Background = Brush $(if ($script:CurGame -eq $g.Id) { '#10304A' } else { '#0F1A2C' })
        $sp2 = New-Object Windows.Controls.StackPanel
        $sp2.Children.Add((New-Text $g.Name 14 '#FFFFFF' $true)) | Out-Null
        $status = if ($applied) { 'Profile active' } elseif ($found) { 'Installed' } else { 'Not detected' }
        $sp2.Children.Add((New-Text $status 11 $(if ($applied) { '#35D07F' } elseif ($found) { '#1FB6FF' } else { '#566684' }))) | Out-Null
        $b.Content = $sp2
        $b.Add_Click({ Show-Game $this.Tag })
        $ui.gameList.Children.Add($b) | Out-Null
    }
}
function Show-Game($id) {
    $script:CurGame = $id
    $g = $Games | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if (-not $g) { return }
    Render-GameList
    $d = $ui.gameDetail; $d.Children.Clear()
    $paths = @($script:GamePaths[$id])
    $d.Children.Add((New-Text $g.Name 24 '#FFFFFF' $true)) | Out-Null
    $tags = New-Object Windows.Controls.WrapPanel; $tags.Margin = '0,6,0,0'
    if ($paths.Count) { $tags.Children.Add((New-Tag 'INSTALLED' '#14352A' '#35D07F')) | Out-Null } else { $tags.Children.Add((New-Tag 'NOT DETECTED' '#1B2E4F' '#8FB2EE')) | Out-Null }
    if ($g.AC) { $tags.Children.Add((New-Tag "ANTI-CHEAT: $($g.AC)" '#3A3016' '#FFC857')) | Out-Null }
    if ($State.ContainsKey("game_$id")) { $tags.Children.Add((New-Tag 'PROFILE ACTIVE' '#0F2E45' '#1FB6FF')) | Out-Null }
    $d.Children.Add($tags) | Out-Null
    if ($paths.Count) { $d.Children.Add((New-Text $paths[0] 11 '#566684' $false '0,0,0,6')) | Out-Null }
    if ($g.AC) { $d.Children.Add((New-Text 'This game uses anti-cheat, so SharkOptimizer only changes Windows settings. It does not touch the game process, its files or its priority.' 12 '#FFC857' $false '0,0,0,6')) | Out-Null }

    $d.Children.Add((New-Text 'Recommended Windows tweaks' 15 '#FFFFFF' $true '0,12,0,6')) | Out-Null
    foreach ($tid in $g.Tweaks) {
        $tw = Get-Tweak $tid; if (-not $tw) { continue }
        $ok = Test-Applicable $tw; $on = $State.ContainsKey($tid)
        $line = if ($on) { "ACTIVE     $($tw.Name)" } elseif (-not $ok) { "Unavailable  $($tw.Name)" } else { "Pending    $($tw.Name)" }
        $d.Children.Add((New-Text $line 12.5 $(if ($on) { '#35D07F' } elseif (-not $ok) { '#566684' } else { '#C2CCDF' }) $false '4,1,0,1')) | Out-Null
    }
    if ($paths.Count) {
        $extra = @()
        if ($Spec.GpuCount -gt 1) { $extra += 'Set the game to use the high-performance GPU' }
        if (-not $g.AC) { $extra += 'Launch the game with High CPU priority' }
        if ($extra.Count) { $d.Children.Add((New-Text ('Game-specific: ' + ($extra -join ', ') + '.') 12 '#8FB2EE' $false '4,6,0,0')) | Out-Null }
    }

    $d.Children.Add((New-Text 'In-game tips' 15 '#FFFFFF' $true '0,14,0,6')) | Out-Null
    foreach ($tip in $g.Tips) { $d.Children.Add((New-Text "-  $tip" 12.5 '#C2CCDF' $false '4,2,0,2')) | Out-Null }

    if ($g.Launch) {
        $d.Children.Add((New-Text 'Launch options' 15 '#FFFFFF' $true '0,14,0,6')) | Out-Null
        $lb = New-Object Windows.Controls.TextBox; $lb.Text = $g.Launch; $lb.IsReadOnly = $true; $lb.FontFamily = 'Consolas'
        $d.Children.Add($lb) | Out-Null
        if ($g.LaunchWhere) { $d.Children.Add((New-Text $g.LaunchWhere 11.5 '#7F8FAE' $false '0,4,0,0')) | Out-Null }
        $cp = New-Object Windows.Controls.Button; $cp.Content = 'Copy'; $cp.Tag = $g.Launch; $cp.HorizontalAlignment = 'Left'
        $cp.Add_Click({ [Windows.Clipboard]::SetText($this.Tag); Log 'Launch options copied to clipboard.' })
        $d.Children.Add($cp) | Out-Null
    }

    $btns = New-Object Windows.Controls.WrapPanel; $btns.Margin = '0,16,0,20'
    $ob = New-Object Windows.Controls.Button; $ob.Content = "Optimize for $($g.Name)"; $ob.Background = Brush '#1FB6FF'; $ob.Foreground = Brush '#06121F'
    $ob.Add_Click({ Optimize-Game $script:CurGame })
    $ub = New-Object Windows.Controls.Button; $ub.Content = 'Undo Game Settings'; $ub.Background = Brush '#3A1F2B'
    $ub.Add_Click({ Undo-GameKey "game_$($script:CurGame)"; Save-State; Show-Game $script:CurGame; Update-Stats })
    $btns.Children.Add($ob) | Out-Null; $btns.Children.Add($ub) | Out-Null
    if ($paths.Count) {
        $fb = New-Object Windows.Controls.Button; $fb.Content = 'Open Folder'; $fb.Tag = $paths[0]
        $fb.Add_Click({ Start-Process explorer.exe "/select,`"$($this.Tag)`"" })
        $btns.Children.Add($fb) | Out-Null
    }
    $d.Children.Add($btns) | Out-Null; Animate-In $d 0 10 260
}
function Optimize-Game($id) {
    $g = $Games | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if (-not $g) { return }
    $pending = @($g.Tweaks | ForEach-Object { Get-Tweak $_ } | Where-Object { $_ -and (Test-Applicable $_) -and -not $State.ContainsKey($_.Id) })
    if ($pending.Count) {
        $res = @(Invoke-Apply $pending) | Select-Object -Last 1
        if ($res -eq $false) { return }
    }
    $paths = @($script:GamePaths[$id])
    $script:CurId = "game_$id"; $State[$script:CurId] = @()
    foreach ($p in $paths) {
        if ($Spec.GpuCount -gt 1) { Set-Tracked $GPUPREF $p 'GpuPreference=2;' 'String'; Log "GPU preference set to high performance: $p" }
        if (-not $g.AC) {
            $exe = Split-Path $p -Leaf
            Set-Tracked "$IFEO\$exe\PerfOptions" 'CpuPriorityClass' 3
            Log "High CPU priority set for $exe"
        }
    }
    Save-State; Render-Tweaks; Show-Game $id; Update-Stats
    Log "Game profile applied: $($g.Name)."
}
function Undo-GameKey($key) {
    if (-not $State.ContainsKey($key)) { return }
    $arr = @($State[$key] | Where-Object { $_ }); [array]::Reverse($arr)
    foreach ($e in $arr) { Restore-Entry $e }
    $State.Remove($key)
    Log "Removed game settings: $key"
}
$ui.btnScan.Add_Click({ Scan-Games })

# ---------------------------------------------------------------- Windows page
function Confirm-Box($text) { [Windows.MessageBox]::Show($text, 'SharkOptimizer', 'YesNo', 'Question') -eq 'Yes' }
$Tools = @(
 @{ Name='System File Check'; Run={ Start-Process cmd.exe -ArgumentList '/k','sfc /scannow' } }
 @{ Name='DISM Repair'; Run={ Start-Process cmd.exe -ArgumentList '/k','DISM /Online /Cleanup-Image /RestoreHealth' } }
 @{ Name='Check Disk (scan)'; Run={ Start-Process cmd.exe -ArgumentList '/k','chkdsk /scan' } }
 @{ Name='Reset Windows Update'; Run={
     if (Confirm-Box 'Stop update services and reset the update cache? Pending downloads restart from zero.') {
         foreach ($s in 'wuauserv','bits','cryptsvc') { Stop-Service $s -Force -ErrorAction SilentlyContinue }
         foreach ($f in 'C:\Windows\SoftwareDistribution','C:\Windows\System32\catroot2') { if (Test-Path $f) { Remove-Item "$f.bak" -Recurse -Force -ErrorAction SilentlyContinue; Rename-Item $f "$(Split-Path $f -Leaf).bak" -ErrorAction SilentlyContinue } }
         foreach ($s in 'cryptsvc','bits','wuauserv') { Start-Service $s -ErrorAction SilentlyContinue }
         Log 'Windows Update components reset.' } } }
 @{ Name='Rebuild Icon Cache'; Run={
     if (Confirm-Box 'Restart Explorer and rebuild the icon cache? Your taskbar flickers briefly.') {
         Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Sleep 1
         Remove-Item "$env:LOCALAPPDATA\IconCache.db" -Force -ErrorAction SilentlyContinue
         Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Filter 'iconcache*' -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
         Start-Process explorer.exe; Log 'Icon cache rebuilt.' } } }
 @{ Name='Restart Explorer'; Run={ Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Sleep 1; if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }; Log 'Explorer restarted.' } }
 @{ Name='Disk Cleanup'; Run={ Start-Process cleanmgr.exe } }
 @{ Name='Power Options'; Run={ Start-Process powercfg.cpl } }
 @{ Name='Services'; Run={ Start-Process services.msc } }
 @{ Name='Task Manager'; Run={ Start-Process taskmgr.exe } }
)
foreach ($tl in $Tools) {
    $tb2 = New-Object Windows.Controls.Button; $tb2.Content = $tl.Name; $tb2.Tag = $tl.Name; $tb2.Padding = '14,9'
    $tb2.Add_Click({ $nm2 = $this.Tag; $tool = $Tools | Where-Object { $_.Name -eq $nm2 }; try { & $tool.Run } catch { Log "Tool failed: $($_.Exception.Message)" } })
    $ui.pnlTools.Children.Add($tb2) | Out-Null
}

# startup apps
$StartDefs = @(
 @{ Hive='HKCU'; Run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Appr='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
 @{ Hive='HKLM'; Run='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Appr='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
)
function Refresh-Startup {
    $ui.lstStartup.Children.Clear()
    $count = 0
    foreach ($df in $StartDefs) {
        if (-not (Test-Path $df.Run)) { continue }
        $k = Get-Item $df.Run
        foreach ($vn in $k.GetValueNames()) {
            if (-not $vn) { continue }
            $enabled = $true
            if (Test-Path $df.Appr) {
                $bytes = (Get-ItemProperty $df.Appr -Name $vn -ErrorAction SilentlyContinue).$vn
                if ($bytes -and ($bytes[0] % 2) -eq 1) { $enabled = $false }
            }
            $cmd = [string]$k.GetValue($vn)
            if ($cmd.Length -gt 90) { $cmd = $cmd.Substring(0, 90) + '...' }
            $cb = New-Object Windows.Controls.CheckBox; $cb.IsChecked = $enabled; $cb.Tag = "$($df.Hive)|$vn"; $cb.Margin = '4,3,0,3'
            $sp3 = New-Object Windows.Controls.StackPanel; $sp3.Orientation = 'Horizontal'
            $sp3.Children.Add((New-Text $vn 13 '#FFFFFF' $true '0,0,10,0')) | Out-Null; $sp3.Children.Add((New-Text "($($df.Hive))  $cmd" 11 '#566684')) | Out-Null
            $cb.Content = $sp3
            $cb.Add_Click({
                $parts = $this.Tag -split '\|', 2
                $def = $StartDefs | Where-Object { $_.Hive -eq $parts[0] }
                if (-not (Test-Path $def.Appr)) { New-Item $def.Appr -Force | Out-Null }
                $bin = New-Object byte[] 12; $bin[0] = $(if ($this.IsChecked) { 2 } else { 3 })
                try { Set-ItemProperty -Path $def.Appr -Name $parts[1] -Value $bin -Type Binary -Force; Log "Startup app '$($parts[1])': $(if ($this.IsChecked) { 'enabled' } else { 'disabled' })" } catch { Log "Startup change failed: $($_.Exception.Message)" }
            })
            $ui.lstStartup.Children.Add($cb) | Out-Null; $count++
        }
    }
    if (-not $count) { $ui.lstStartup.Children.Add((New-Text 'No registry startup entries found.' 12 '#7F8FAE' $false '4,0,0,6')) | Out-Null }
}
$ui.btnStartRef.Add_Click({ Refresh-Startup })

# built-in apps
$BloatApps = [ordered]@{
 'Microsoft.BingNews'='Microsoft News'; 'Microsoft.BingWeather'='Weather'; 'Microsoft.GetHelp'='Get Help'; 'Microsoft.Getstarted'='Tips'
 'Microsoft.MicrosoftSolitaireCollection'='Solitaire Collection'; 'Microsoft.People'='People'; 'Microsoft.WindowsFeedbackHub'='Feedback Hub'
 'Microsoft.ZuneMusic'='Media Player (Groove)'; 'Microsoft.ZuneVideo'='Movies and TV'; 'Microsoft.YourPhone'='Phone Link'
 'Microsoft.MicrosoftOfficeHub'='Microsoft 365 Hub'; 'Microsoft.Todos'='To Do'; 'Microsoft.PowerAutomateDesktop'='Power Automate'
 'Clipchamp.Clipchamp'='Clipchamp'; 'Microsoft.549981C3F5F10'='Cortana'; 'MicrosoftTeams'='Teams (personal)'
 'Microsoft.MixedReality.Portal'='Mixed Reality Portal'; 'Microsoft.SkypeApp'='Skype'; 'Microsoft.WindowsMaps'='Maps'; 'Microsoft.Microsoft3DViewer'='3D Viewer' }
function Refresh-Bloat {
    $ui.lstBloat.Children.Clear()
    $ui.txtScan.Text = $ui.txtScan.Text
    $installed = @(Get-AppxPackage -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $n = 0
    foreach ($key in @($BloatApps.Keys)) {
        if ($installed -notcontains $key) { continue }
        $cb = New-Object Windows.Controls.CheckBox; $cb.Content = $BloatApps[$key]; $cb.Tag = $key; $cb.Margin = '4,3,18,3'; $cb.Width = 210
        $ui.lstBloat.Children.Add($cb) | Out-Null; $n++
    }
    if (-not $n) { $ui.lstBloat.Children.Add((New-Text 'None of the listed apps are installed.' 12 '#7F8FAE' $false '4,0,0,6')) | Out-Null }
}
$ui.btnBloatRef.Add_Click({ Refresh-Bloat })
$ui.btnBloat.Add_Click({
    $sel = @($ui.lstBloat.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] -and $_.IsChecked })
    if (-not $sel.Count) { [void][Windows.MessageBox]::Show('Nothing selected.', 'SharkOptimizer'); return }
    $names = ($sel | ForEach-Object { $_.Content }) -join ', '
    if ([Windows.MessageBox]::Show("Remove these apps?`n`n$names`n`nYou can reinstall them from the Microsoft Store, but this cannot be undone here.", 'SharkOptimizer - remove apps', 'YesNo', 'Warning') -ne 'Yes') { return }
    New-RestorePoint
    foreach ($cb in $sel) {
        Log "Removing app: $($cb.Content)"
        try { Get-AppxPackage -Name $cb.Tag -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction Stop } catch { Log "  Failed: $($_.Exception.Message)" }
    }
    Refresh-Bloat; Log 'App removal finished.'
})

# heavy apps
$ProtectedProcs = 'explorer','dwm','ShellExperienceHost','SearchHost','StartMenuExperienceHost','TextInputHost','SystemSettings','ApplicationFrameHost','powershell','pwsh','WindowsTerminal','taskmgr','csrss','winlogon','LockApp'
function Refresh-Procs {
    $ui.lstProc.Children.Clear()
    $list = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.Id -ne $PID -and $ProtectedProcs -notcontains $_.ProcessName } | Sort-Object WorkingSet64 -Descending | Select-Object -First 15)
    foreach ($pr in $list) {
        $cb = New-Object Windows.Controls.CheckBox; $cb.Tag = $pr.Id; $cb.Margin = '4,3,0,3'
        $title = [string]$pr.MainWindowTitle; if ($title.Length -gt 60) { $title = $title.Substring(0, 60) + '...' }
        $sp4 = New-Object Windows.Controls.StackPanel; $sp4.Orientation = 'Horizontal'
        $sp4.Children.Add((New-Text $pr.ProcessName 13 '#FFFFFF' $true '0,0,10,0')) | Out-Null
        $sp4.Children.Add((New-Text ("{0:N0} MB   {1}" -f ($pr.WorkingSet64 / 1MB), $title) 11 '#7F8FAE')) | Out-Null
        $cb.Content = $sp4; $ui.lstProc.Children.Add($cb) | Out-Null
    }
    if (-not $list.Count) { $ui.lstProc.Children.Add((New-Text 'No other app windows are open.' 12 '#7F8FAE' $false '4,0,0,6')) | Out-Null }
}
$ui.btnProcRef.Add_Click({ Refresh-Procs })
$ui.btnProcClose.Add_Click({
    $sel = @($ui.lstProc.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] -and $_.IsChecked })
    foreach ($cb in $sel) {
        $pr = Get-Process -Id $cb.Tag -ErrorAction SilentlyContinue
        if ($pr) { [void]$pr.CloseMainWindow(); Log "Asked $($pr.ProcessName) to close." }
    }
    Start-Sleep -Milliseconds 800; Refresh-Procs
})

# ---------------------------------------------------------------- live monitors
$script:cpuC = $null; $script:gpuC = @(); $script:tick = 0
try { $script:cpuC = New-Object Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total'); [void]$script:cpuC.NextValue() } catch {}
$ci = New-Object Microsoft.VisualBasic.Devices.ComputerInfo
function Refresh-GpuCounters {
    try {
        $pcat = New-Object Diagnostics.PerformanceCounterCategory('GPU Engine')
        $script:gpuC = @($pcat.GetInstanceNames() | Where-Object { $_ -like '*engtype_3D*' } | Select-Object -First 40 | ForEach-Object { $pc = New-Object Diagnostics.PerformanceCounter('GPU Engine', 'Utilization Percentage', $_); [void]$pc.NextValue(); $pc })
    } catch { $script:gpuC = @() }
}
Refresh-GpuCounters
$timer = New-Object Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({
    try {
        if ($ui.pgDash.Visibility -ne 'Visible') { return }
        $script:tick++
        if ($script:cpuC) { $cv = [math]::Round($script:cpuC.NextValue()); $ui.txtCpu.Text = "$cv%"; Set-Bar $ui.barCpu $cv }
        $rv = [math]::Round(100 * (1 - $ci.AvailablePhysicalMemory / $ci.TotalPhysicalMemory)); $ui.txtRam.Text = "$rv%"; Set-Bar $ui.barRam $rv
        $gv = 0; foreach ($pc in $script:gpuC) { try { $gv += $pc.NextValue() } catch {} }
        $gv = [math]::Min(100, [math]::Round($gv)); $ui.txtGpu.Text = "$gv%"; Set-Bar $ui.barGpu $gv
        if ($script:tick % 15 -eq 0) { Refresh-GpuCounters }
    } catch {}
})
$timer.Start()


# ================================================================ SharkOptimizer Lab (added module)
$AppVersion = '1.1.0'
$window.Title = "SharkOptimizer v$AppVersion"
$BenchFile = Join-Path $DataDir 'bench.json'
function Test-Cmd($n) { [bool](Get-Command $n -ErrorAction SilentlyContinue) }

# ---------------------------------------------------------------- custom data files (structure)
$CustomTweaksFile = Join-Path $DataDir 'custom-tweaks.json'
$CustomGamesFile  = Join-Path $DataDir 'custom-games.json'
$exTweaks = '[ { "id": "c_example", "cat": "Quality of Life", "name": "Example custom tweak", "desc": "Copy this file to custom-tweaks.json and edit it to add your own registry tweaks.", "risk": "Safe", "warn": "", "rec": false, "reboot": false, "enabled": false, "reg": [ { "path": "HKCU:\\Software\\Example", "name": "Value", "value": 1, "type": "DWord" } ] } ]'
$exGames = '[ { "id": "mygame", "name": "My Game", "exes": [ "mygame.exe" ], "ac": "", "tweaks": [ "f_gamemode", "f_dvr", "n_nagle" ], "tips": [ "Your own tip here." ], "launch": "", "enabled": false } ]'
if (-not (Test-Path ($CustomTweaksFile + '.example'))) { Set-Content ($CustomTweaksFile + '.example') $exTweaks -Encoding UTF8 }
if (-not (Test-Path ($CustomGamesFile + '.example'))) { Set-Content ($CustomGamesFile + '.example') $exGames -Encoding UTF8 }
if (Test-Path $CustomTweaksFile) {
    try {
        $data = Get-Content $CustomTweaksFile -Raw | ConvertFrom-Json
        $added = 0
        foreach ($ct in @($data)) {
            if (-not $ct.id -or $ct.enabled -eq $false -or (Get-Tweak ([string]$ct.id))) { continue }
            $regs = @()
            foreach ($cr in @($ct.reg)) { $ty = if ($cr.type) { [string]$cr.type } else { 'DWord' }; $regs += , (Rg ([string]$cr.path) ([string]$cr.name) $cr.value $ty) }
            $risk = if ($ct.risk) { [string]$ct.risk } else { 'Safe' }
            $cat = if ($ct.cat) { [string]$ct.cat } else { 'Advanced' }
            Add-Tweak ([string]$ct.id) $cat ([string]$ct.name) ([string]$ct.desc) $risk ([string]$ct.warn) -Rec ([bool]$ct.rec) -Reg $regs -Reboot ([bool]$ct.reboot)
            $added++
        }
        Log "Loaded $added custom tweaks from custom-tweaks.json."
    } catch { Log "custom-tweaks.json error: $($_.Exception.Message)" }
}
if (Test-Path $CustomGamesFile) {
    try {
        $data = Get-Content $CustomGamesFile -Raw | ConvertFrom-Json
        $added = 0
        foreach ($cg in @($data)) {
            if (-not $cg.id -or $cg.enabled -eq $false -or ($Games | Where-Object { $_.Id -eq [string]$cg.id })) { continue }
            $Games += @{ Id=[string]$cg.id; Name=[string]$cg.name; Exes=@($cg.exes | ForEach-Object { [string]$_ }); AC=[string]$cg.ac
                         Tweaks=@($cg.tweaks | ForEach-Object { [string]$_ }); Tips=@($cg.tips | ForEach-Object { [string]$_ }); Launch=[string]$cg.launch; LaunchWhere=[string]$cg.launchWhere }
            $added++
        }
        Log "Loaded $added custom games from custom-games.json."
    } catch { Log "custom-games.json error: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- tweak details window
function Show-Info($t) {
    if (-not $t) { return }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.AddRange(@($t.Name, "Category: $($t.Cat)    Risk: $($t.Risk)", '', $t.Desc, ''))
    if ($t.Warn) { [void]$lines.Add("Warning: $($t.Warn)"); [void]$lines.Add('') }
    if (@($t.Reg).Count) {
        [void]$lines.Add('Registry changes:')
        foreach ($r in $t.Reg) { [void]$lines.Add("  $($r[0])"); [void]$lines.Add("      $($r[1]) = $($r[2])   [$($r[3])]") }
        [void]$lines.Add('')
    }
    if ($t.Do) { [void]$lines.Add('Commands run when applied:'); foreach ($ln in ($t.Do.ToString().Trim() -split "`n")) { [void]$lines.Add('  ' + $ln.TrimEnd()) }; [void]$lines.Add('') }
    if ($t.Undo) { [void]$lines.Add('Commands run when undone:'); foreach ($ln in ($t.Undo.ToString().Trim() -split "`n")) { [void]$lines.Add('  ' + $ln.TrimEnd()) }; [void]$lines.Add('') }
    if ($State.ContainsKey($t.Id)) {
        [void]$lines.Add('Original values saved for undo:')
        foreach ($e in @($State[$t.Id] | Where-Object { $_ })) {
            if ($e.K -eq 'Reg') { [void]$lines.Add("  $($e.Path)\$($e.Name) = $(if ($e.Existed) { $e.Old } else { '(did not exist)' })") }
            elseif ($e.K -eq 'Svc') { [void]$lines.Add("  Service $($e.Name): start type was $($e.Old)") }
            elseif ($e.K -eq 'Adv') { [void]$lines.Add("  $($e.Adapter) / $($e.DisplayName): was $($e.Old)") }
        }
    } else { [void]$lines.Add('Not applied. Nothing has been changed yet.') }
    $w = New-Object Windows.Window; $w.Title = "Details - $($t.Name)"; $w.Width = 700; $w.Height = 540; $w.Background = Brush '#08101D'
    $w.WindowStartupLocation = 'CenterOwner'; $w.Owner = $window
    $tb = New-Object Windows.Controls.TextBox; $tb.Text = ($lines -join "`r`n"); $tb.IsReadOnly = $true; $tb.FontFamily = 'Consolas'; $tb.FontSize = 12.5
    $tb.TextWrapping = 'Wrap'; $tb.VerticalScrollBarVisibility = 'Auto'; $tb.BorderThickness = 0; $tb.Margin = 14; $tb.Background = Brush '#08101D'; $tb.Foreground = Brush '#C2CCDF'
    $w.Content = $tb; [void]$w.ShowDialog()
}
$script:OrigNewCard = ${function:New-Card}
function New-Card($t) {
    $c = & $script:OrigNewCard $t
    try {
        $stack = $c.Child; $row = $stack.Children[$stack.Children.Count - 1]
        $ib = New-Object Windows.Controls.Button; $ib.Content = 'Details'; $ib.Tag = $t.Id; $ib.Padding = '10,3'; $ib.Margin = '0,0,8,0'; $ib.FontSize = 11; $ib.Background = Brush '#16233A'
        $ib.Add_Click({ Show-Info (Get-Tweak $this.Tag) })
        [Windows.Controls.DockPanel]::SetDock($ib, 'Right'); $row.Children.Insert(1, $ib)
    } catch {}
    $c
}

# ---------------------------------------------------------------- restore point line
$script:txtRP = New-Text 'Last restore point: checking...' 12 '#7F8FAE' $false '4,0,0,10'
try { $ui.txtApplied.Parent.Children.Insert(3, $script:txtRP) } catch {}
function Update-RPLine {
    try {
        $rp = Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object SequenceNumber -Descending | Select-Object -First 1
        if ($rp) {
            $dt = [Management.ManagementDateTimeConverter]::ToDateTime($rp.CreationTime); $ago = (Get-Date) - $dt
            $when = if ($ago.TotalHours -lt 1) { "$([int]$ago.TotalMinutes) min ago" } elseif ($ago.TotalDays -lt 1) { "$([int]$ago.TotalHours) h ago" } else { "$([int]$ago.TotalDays) days ago" }
            $script:txtRP.Text = "Last restore point: $when  ($($rp.Description))"
        } else { $script:txtRP.Text = 'Last restore point: none found. Create one before applying risky tweaks.' }
    } catch { $script:txtRP.Text = 'Last restore point: unavailable (System Protection may be off).' }
}
$script:OrigRP = ${function:New-RestorePoint}
function New-RestorePoint { & $script:OrigRP; Update-RPLine }

# ---------------------------------------------------------------- Lab page (built in code)
$labScroll = New-Object Windows.Controls.ScrollViewer; $labScroll.VerticalScrollBarVisibility = 'Auto'; $labScroll.Visibility = 'Collapsed'
$lab = New-Object Windows.Controls.StackPanel; $labScroll.Content = $lab
$ui.pgDash.Parent.Children.Add($labScroll) | Out-Null
$labNav = New-Object Windows.Controls.Button
try { $labNav.Style = $window.FindResource('NavBtn') } catch { $labNav.Background = Brush '#0B1424' }
$labNav.HorizontalContentAlignment = 'Left'; $labNav.Margin = '10,3'; $labNav.Padding = '14,10'
$navSp = New-Object Windows.Controls.StackPanel; $navSp.Orientation = 'Horizontal'
$navIc = New-Object Windows.Controls.TextBlock; $navIc.FontFamily = 'Segoe MDL2 Assets'; $navIc.FontSize = 15; $navIc.Text = [string][char]0xE9D9; $navIc.Width = 28; $navIc.VerticalAlignment = 'Center'
$navLb = New-Object Windows.Controls.TextBlock; $navLb.Text = 'Lab'; $navLb.FontSize = 13.5
$navSp.Children.Add($navIc) | Out-Null; $navSp.Children.Add($navLb) | Out-Null; $labNav.Content = $navSp
$ui.navDash.Parent.Children.Insert(4, $labNav) | Out-Null
$ui['navLab'] = $labNav; $ui['pgLab'] = $labScroll; $pages.Add('navLab', 'pgLab')

function New-LabButton($text, [scriptblock]$click, $accent = $false) {
    $b = New-Object Windows.Controls.Button; $b.Content = $text; $b.Padding = '14,9'
    if ($accent) { $b.Background = Brush '#1FB6FF'; $b.Foreground = Brush '#06121F' }
    $b.Add_Click($click); $b
}
function New-LabBox($height) {
    $tb = New-Object Windows.Controls.TextBox; $tb.IsReadOnly = $true; $tb.FontFamily = 'Consolas'; $tb.FontSize = 12.5; $tb.Height = $height
    $tb.VerticalScrollBarVisibility = 'Auto'; $tb.Margin = '4,6,0,0'; $tb
}
function Add-LabSection($title, $sub) {
    $lab.Children.Add((New-Text $title 17 '#FFFFFF' $true '4,24,0,2')) | Out-Null
    if ($sub) { $lab.Children.Add((New-Text $sub 12 '#7F8FAE' $false '4,0,0,8')) | Out-Null }
}
function Add-LabRow($buttons) { $wp = New-Object Windows.Controls.WrapPanel; $wp.Margin = '-4,0,0,0'; foreach ($b in $buttons) { $wp.Children.Add($b) | Out-Null }; $lab.Children.Add($wp) | Out-Null }

$lab.Children.Add((New-Text 'Lab' 28 '#FFFFFF' $true)) | Out-Null
$lab.Children.Add((New-Text 'Measure results, run Game Mode, check your hardware and manage your setup.' 12.5 '#7F8FAE' $false '0,0,0,0')) | Out-Null

# ----- 1. benchmark
function Get-Bench {
    $r = [ordered]@{}
    $script:txtBenchStatus.Text = 'Testing ping...'; Flush-UI
    $p1 = Test-Tcp '1.1.1.1' 443 10; $p2 = Test-Tcp '8.8.8.8' 443 10
    $pv = @($p1.Avg, $p2.Avg) | Where-Object { $null -ne $_ }; $jv = @($p1.Jitter, $p2.Jitter) | Where-Object { $null -ne $_ }
    $r.PingMs = if ($pv) { [math]::Round(($pv | Measure-Object -Average).Average, 1) } else { $null }
    $r.JitterMs = if ($jv) { [math]::Round(($jv | Measure-Object -Average).Average, 1) } else { $null }
    $script:txtBenchStatus.Text = 'Testing DNS...'; Flush-UI
    $dt = @()
    foreach ($dn in 'google.com','cloudflare.com','wikipedia.org','steampowered.com','epicgames.com') {
        try { Clear-DnsClientCache } catch {}
        $sw = [Diagnostics.Stopwatch]::StartNew(); try { Resolve-DnsName $dn -DnsOnly -ErrorAction Stop | Out-Null; $dt += $sw.Elapsed.TotalMilliseconds } catch {}
    }
    $r.DnsMs = if ($dt.Count) { [math]::Round(($dt | Measure-Object -Average).Average, 1) } else { $null }
    $script:txtBenchStatus.Text = 'Sampling CPU at idle...'; Flush-UI
    try { $pc = New-Object Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total'); [void]$pc.NextValue(); $cs = @(); 1..4 | ForEach-Object { Start-Sleep -Milliseconds 800; $cs += $pc.NextValue() }; $r.CpuIdlePct = [math]::Round(($cs | Measure-Object -Average).Average, 1) } catch { $r.CpuIdlePct = $null }
    $cinfo = New-Object Microsoft.VisualBasic.Devices.ComputerInfo
    $r.RamUsedPct = [math]::Round(100 * (1 - $cinfo.AvailablePhysicalMemory / $cinfo.TotalPhysicalMemory), 1)
    $r.Processes = @(Get-Process).Count
    $r.Services = @(Get-Service | Where-Object Status -eq 'Running').Count
    $r.BootSec = $null
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction Stop
        $xml = [xml]$ev.ToXml(); $bt = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' }).'#text'
        if ($bt) { $r.BootSec = [math]::Round([double]$bt / 1000, 1) }
    } catch {}
    $r
}
function Format-Bench {
    if (-not (Test-Path $BenchFile)) { return 'No results yet.' + "`r`n" + '1) Click Run BEFORE.  2) Apply tweaks and restart if asked.  3) Click Run AFTER.' }
    $d = Get-Content $BenchFile -Raw | ConvertFrom-Json
    $labels = [ordered]@{ PingMs='Ping (ms)'; JitterMs='Jitter (ms)'; DnsMs='DNS lookup (ms)'; CpuIdlePct='CPU at idle (%)'; RamUsedPct='RAM used (%)'; Processes='Processes'; Services='Running services'; BootSec='Last boot time (s)' }
    $out = @(("{0,-22}{1,10}{2,10}   {3}" -f 'Metric', 'Before', 'After', 'Change'), ('-' * 62))
    foreach ($k in @($labels.Keys)) {
        $b = if ($d.Before) { $d.Before.$k } else { $null }; $a = if ($d.After) { $d.After.$k } else { $null }
        $bs = if ($null -ne $b) { "$b" } else { '-' }; $as = if ($null -ne $a) { "$a" } else { '-' }
        $chg = ''
        if ($null -ne $b -and $null -ne $a) {
            $diff = [double]$a - [double]$b
            if ([math]::Abs($diff) -lt 0.05) { $chg = 'same' } else { $pct = if ([double]$b -ne 0) { [math]::Round(100 * $diff / [double]$b) } else { 0 }; $chg = "{0:+0.#;-0.#} ({1}%)  {2}" -f $diff, $pct, $(if ($diff -lt 0) { 'better' } else { 'worse' }) }
        }
        $out += ("{0,-22}{1,10}{2,10}   {3}" -f $labels[$k], $bs, $as, $chg)
    }
    $out += ''; $out += 'Lower is better for every row. Network numbers move a few ms between runs, so repeat the test if the change is small.'
    $out -join "`r`n"
}
function Save-Bench($slot, $res) {
    $store = @{}
    if (Test-Path $BenchFile) { $o = Get-Content $BenchFile -Raw | ConvertFrom-Json; foreach ($pr in $o.PSObject.Properties) { $store[$pr.Name] = $pr.Value } }
    $store[$slot] = $res; $store["${slot}Time"] = (Get-Date).ToString('s')
    $store | ConvertTo-Json -Depth 4 | Set-Content $BenchFile -Encoding UTF8
}
Add-LabSection 'Before and after benchmark' 'Measures ping, jitter, DNS speed, idle CPU, RAM, process count and boot time, so you can see what your tweaks really changed. Takes about 20 seconds.'
$script:txtBenchStatus = New-Text '' 12 '#1FB6FF' $false '4,0,0,4'
$script:txtBench = New-LabBox 230
$script:txtBench.Text = Format-Bench
Add-LabRow @(
    (New-LabButton 'Run BEFORE' { $res = Get-Bench; Save-Bench 'Before' $res; $script:txtBench.Text = Format-Bench; $script:txtBenchStatus.Text = 'Saved as BEFORE.'; Log 'Benchmark BEFORE saved.' }),
    (New-LabButton 'Run AFTER' { $res = Get-Bench; Save-Bench 'After' $res; $script:txtBench.Text = Format-Bench; $script:txtBenchStatus.Text = 'Saved as AFTER.'; Log 'Benchmark AFTER saved.' } $true),
    (New-LabButton 'Clear Results' { Remove-Item $BenchFile -Force -ErrorAction SilentlyContinue; $script:txtBench.Text = Format-Bench; $script:txtBenchStatus.Text = '' })
)
$lab.Children.Add($script:txtBenchStatus) | Out-Null; $lab.Children.Add($script:txtBench) | Out-Null

# ----- 2. game mode
$script:GM = @{ Active = $false; Plan = $null; WUStopped = $false; ProcName = $null; Seen = $false; Misses = 0; Started = $null; Timer = $null }
function Get-ActivePlan { $o = (powercfg /getactivescheme) -join ' '; if ($o -match '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}') { $Matches[0] } }
function Refresh-GmProcs {
    $script:lstGm.Children.Clear()
    $list = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.Id -ne $PID -and $ProtectedProcs -notcontains $_.ProcessName } | Sort-Object WorkingSet64 -Descending | Select-Object -First 12)
    foreach ($pr in $list) {
        $cb = New-Object Windows.Controls.CheckBox; $cb.Tag = $pr.Id; $cb.Margin = '4,2,0,2'
        $cb.Content = New-Text ("{0}   {1:N0} MB" -f $pr.ProcessName, ($pr.WorkingSet64 / 1MB)) 12.5 '#C2CCDF'
        $script:lstGm.Children.Add($cb) | Out-Null
    }
    if (-not $list.Count) { $script:lstGm.Children.Add((New-Text 'No other app windows are open.' 12 '#7F8FAE' $false '4,0,0,4')) | Out-Null }
}
function Refresh-GmGames {
    $script:cmbGm.Items.Clear()
    $none = New-Object Windows.Controls.ComboBoxItem; $none.Content = '(none - manual start and end)'; $none.Tag = $null; [void]$script:cmbGm.Items.Add($none)
    foreach ($g in $Games) {
        $ps = @($script:GamePaths[$g.Id])
        if ($ps.Count -and $ps[0]) { $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = $g.Name; $it.Tag = $ps[0]; [void]$script:cmbGm.Items.Add($it) }
    }
    $script:cmbGm.SelectedIndex = 0
}
function End-GameMode {
    if (-not $script:GM.Active) { return }
    try { if ($script:GM.Timer) { $script:GM.Timer.Stop() } } catch {}
    if ($script:GM.Plan) { powercfg /setactive $script:GM.Plan 2>&1 | Out-Null; Log "Power plan restored." }
    if ($script:GM.WUStopped) { Start-Service wuauserv -ErrorAction SilentlyContinue; Log 'Windows Update service resumed.' }
    $script:GM.Active = $false; $script:txtGm.Text = 'Game Mode is off.'; Log 'Game Mode ended.'
}
function Start-GameMode {
    if ($script:GM.Active) { Log 'Game Mode is already active.'; return }
    $exe = $null; $sel = $script:cmbGm.SelectedItem; if ($sel -and $sel.Tag) { $exe = [string]$sel.Tag }
    $script:GM.Plan = Get-ActivePlan; $script:GM.WUStopped = $false
    if ($script:chkGmPlan.IsChecked) {
        $target = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
        if ((powercfg /list) -match '99999999-9999-9999-9999-999999999999') { $target = '99999999-9999-9999-9999-999999999999' }
        powercfg /setactive $target 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Log "Power plan set to performance ($target)." } else { Log 'Could not switch the power plan on this PC.' }
    }
    if ($script:chkGmWU.IsChecked) { $svc = Get-Service wuauserv -ErrorAction SilentlyContinue; if ($svc -and $svc.Status -eq 'Running') { Stop-Service wuauserv -Force -ErrorAction SilentlyContinue; $script:GM.WUStopped = $true; Log 'Windows Update service paused.' } }
    foreach ($cb in @($script:lstGm.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] -and $_.IsChecked })) {
        $pr = Get-Process -Id $cb.Tag -ErrorAction SilentlyContinue; if ($pr) { [void]$pr.CloseMainWindow(); Log "Asked $($pr.ProcessName) to close." }
    }
    if ($script:chkGmTrim.IsChecked) { Start-Sleep -Milliseconds 1200; Get-Process | ForEach-Object { try { [void][Boost.Mem]::EmptyWorkingSet($_.Handle) } catch {} }; Log 'Background memory trimmed.' }
    $script:GM.Active = $true; $script:GM.Seen = $false; $script:GM.Misses = 0; $script:GM.Started = Get-Date
    if ($exe -and (Test-Path -LiteralPath $exe)) {
        $script:GM.ProcName = [IO.Path]::GetFileNameWithoutExtension($exe)
        try { Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) } catch { Log "Could not launch the game: $($_.Exception.Message)" }
        $script:txtGm.Text = "Game Mode is on. It ends automatically when $($script:GM.ProcName) closes."
        $tm = New-Object Windows.Threading.DispatcherTimer; $tm.Interval = [TimeSpan]::FromSeconds(5)
        $tm.Add_Tick({
            $running = [bool](Get-Process -Name $script:GM.ProcName -ErrorAction SilentlyContinue)
            if ($running) { $script:GM.Seen = $true; $script:GM.Misses = 0 }
            else { $script:GM.Misses++; if (($script:GM.Seen -and $script:GM.Misses -ge 2) -or (-not $script:GM.Seen -and ((Get-Date) - $script:GM.Started).TotalSeconds -gt 180)) { End-GameMode } }
        })
        $script:GM.Timer = $tm; $tm.Start()
    } else { $script:GM.ProcName = $null; $script:txtGm.Text = 'Game Mode is on. Start your game, then click End Game Mode when you are done.' }
    Log 'Game Mode started.'
}
Add-LabSection 'Game Mode' 'Switches to a performance power plan, pauses Windows Update, closes apps you pick and trims memory. Everything is restored when it ends. Run a scan on the Games tab to list your games here.'
$script:chkGmPlan = New-Object Windows.Controls.CheckBox; $script:chkGmPlan.Content = 'Switch to a performance power plan'; $script:chkGmPlan.IsChecked = $true; $script:chkGmPlan.Margin = '4,2'
$script:chkGmWU = New-Object Windows.Controls.CheckBox; $script:chkGmWU.Content = 'Pause the Windows Update service'; $script:chkGmWU.IsChecked = $true; $script:chkGmWU.Margin = '4,2'
$script:chkGmTrim = New-Object Windows.Controls.CheckBox; $script:chkGmTrim.Content = 'Trim background memory'; $script:chkGmTrim.IsChecked = $true; $script:chkGmTrim.Margin = '4,2'
foreach ($c in $script:chkGmPlan, $script:chkGmWU, $script:chkGmTrim) { $lab.Children.Add($c) | Out-Null }
$lab.Children.Add((New-Text 'Launch this game when Game Mode starts:' 12 '#C2CCDF' $false '4,8,0,2')) | Out-Null
$script:cmbGm = New-Object Windows.Controls.ComboBox; $script:cmbGm.Width = 320; $script:cmbGm.HorizontalAlignment = 'Left'; $script:cmbGm.Margin = '4,0,0,6'
$lab.Children.Add($script:cmbGm) | Out-Null
$lab.Children.Add((New-Text 'Close these apps first:' 12 '#C2CCDF' $false '4,6,0,2')) | Out-Null
$script:lstGm = New-Object Windows.Controls.StackPanel; $lab.Children.Add($script:lstGm) | Out-Null
$script:txtGm = New-Text 'Game Mode is off.' 12 '#1FB6FF' $false '4,6,0,4'
Add-LabRow @(
    (New-LabButton 'Start Game Mode' { Start-GameMode } $true),
    (New-LabButton 'End Game Mode' { End-GameMode }),
    (New-LabButton 'Refresh Lists' { Refresh-GmProcs; Refresh-GmGames })
)
$lab.Children.Add($script:txtGm) | Out-Null
$window.Add_Closing({ try { End-GameMode } catch {} })

# ----- 3. system check
function Add-CheckRow($level, $text) {
    $col = switch ($level) { 'OK' { '#35D07F' } 'WARN' { '#FFC857' } default { '#7F8FAE' } }
    $script:lstCheck.Children.Add((New-Text ("{0,-5} {1}" -f $level, $text) 12.5 $col $false '4,2,0,2')) | Out-Null
}
function Run-SystemCheck {
    $script:lstCheck.Children.Clear()
    $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA|Radeon|Arc' } | Select-Object -First 1
    if (-not $gpu) { $gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1 }
    if ($gpu) {
        $age = $null; try { $age = ((Get-Date) - [Management.ManagementDateTimeConverter]::ToDateTime($gpu.DriverDate)).TotalDays } catch {}
        $txt = "GPU driver $($gpu.DriverVersion) for $($gpu.Name)" + $(if ($null -ne $age) { " ($([int]$age) days old)" } else { '' })
        if ($null -ne $age -and $age -gt 180) { Add-CheckRow 'WARN' "$txt. Consider updating from the GPU vendor." } else { Add-CheckRow 'OK' $txt }
        if ($gpu.CurrentRefreshRate) { Add-CheckRow 'INFO' "Display is running at $($gpu.CurrentRefreshRate) Hz. If your monitor supports more, raise it in Settings > Display > Advanced display." }
    }
    $mem = @(Get-CimInstance Win32_PhysicalMemory)
    if ($mem.Count) {
        $rated = ($mem | Measure-Object Speed -Maximum).Maximum; $cfg = ($mem | Measure-Object ConfiguredClockSpeed -Minimum).Minimum
        if ($rated -and $cfg -and $cfg -lt ($rated * 0.95)) { Add-CheckRow 'WARN' "RAM runs at $cfg MHz but is rated for $rated MHz. Enable XMP or EXPO in the BIOS." }
        elseif ($cfg) { Add-CheckRow 'OK' "RAM runs at $cfg MHz ($($mem.Count) module(s))." }
        if ($mem.Count -eq 1) { Add-CheckRow 'INFO' 'Single RAM stick detected. Two matched sticks (dual channel) are noticeably faster for gaming.' }
    }
    try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop; Add-CheckRow $(if ($sb) { 'OK' } else { 'INFO' }) "Secure Boot is $(if ($sb) { 'on' } else { 'off' }). Some anti-cheats (such as Vanguard) require it." } catch { Add-CheckRow 'INFO' 'Secure Boot status is unavailable (legacy BIOS mode or no access).' }
    try { $tpm = Get-Tpm -ErrorAction Stop; Add-CheckRow $(if ($tpm.TpmPresent) { 'OK' } else { 'INFO' }) "TPM present: $($tpm.TpmPresent), ready: $($tpm.TpmReady)." } catch {}
    try { $dg = Get-CimInstance -Namespace 'root/Microsoft/Windows/DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop; Add-CheckRow 'INFO' "Virtualization-Based Security is $(if ($dg.VirtualizationBasedSecurityStatus -eq 2) { 'running (can cost some FPS)' } else { 'not running' })." } catch {}
    $plan = (powercfg /getactivescheme) -replace '^.*\((.*)\).*$', '$1'; Add-CheckRow 'INFO' "Active power plan: $plan"
    if ($Spec.Wifi) { Add-CheckRow 'WARN' 'You are on Wi-Fi. Ethernet gives lower and steadier ping for gaming.' } else { Add-CheckRow 'OK' 'Wired connection detected.' }
    try { $dr = Get-PSDrive -Name ([string]$env:SystemDrive[0]); $free = [math]::Round(100 * $dr.Free / ($dr.Free + $dr.Used)); if ($free -lt 15) { Add-CheckRow 'WARN' "System drive has only $free% free space. Free some room for best performance." } else { Add-CheckRow 'OK' "System drive has $free% free." } } catch {}
    Add-CheckRow 'INFO' 'Resizable BAR cannot be read reliably from Windows. Check it in your GPU control panel or the BIOS.'
}
Add-LabSection 'System check' 'Looks at drivers, RAM speed, display refresh rate and security features that affect gaming.'
$script:lstCheck = New-Object Windows.Controls.StackPanel
Add-LabRow @((New-LabButton 'Run System Check' { Run-SystemCheck } $true))
$lab.Children.Add($script:lstCheck) | Out-Null

# ----- 4. verify
$script:Drift = @()
function Test-TweakDrift($t) {
    $issues = @()
    foreach ($r in $t.Reg) {
        $cur = $null; try { $cur = (Get-ItemProperty -LiteralPath $r[0] -Name $r[1] -ErrorAction Stop).($r[1]) } catch {}
        if ("$cur" -ne "$($r[2])") { $issues += "$($r[1]) is '$cur', expected '$($r[2])'" }
    }
    foreach ($e in @($State[$t.Id] | Where-Object { $_ -and $_.K -eq 'Svc' })) {
        $s = Get-CimInstance Win32_Service -Filter "Name='$($e.Name)'" -ErrorAction SilentlyContinue
        if ($s -and $s.StartMode -ne 'Disabled') { $issues += "service $($e.Name) is $($s.StartMode)" }
    }
    $issues
}
Add-LabSection 'Verify applied tweaks' 'Windows updates and driver installers sometimes undo tweaks. This re-reads every applied tweak and shows any that drifted.'
$script:txtVerify = New-LabBox 140
Add-LabRow @(
    (New-LabButton 'Verify Now' {
        $script:Drift = @(); $out = @()
        foreach ($t in @($Tweaks | Where-Object { $State.ContainsKey($_.Id) })) {
            $iss = @(Test-TweakDrift $t)
            if ($iss.Count) { $script:Drift += $t; $out += "DRIFTED  $($t.Name)"; foreach ($i in $iss) { $out += "           $i" } }
        }
        $applied = @($Tweaks | Where-Object { $State.ContainsKey($_.Id) }).Count
        $script:txtVerify.Text = if ($script:Drift.Count) { ($out -join "`r`n") + "`r`n`r`n$($script:Drift.Count) of $applied tweaks drifted." } else { "All $applied applied tweaks are still in place." }
        Log "Verify: $($script:Drift.Count) drifted."
    } $true),
    (New-LabButton 'Re-apply Drifted' {
        foreach ($t in $script:Drift) {
            foreach ($r in $t.Reg) { try { Set-ItemProperty -LiteralPath $r[0] -Name $r[1] -Value $r[2] -Type $r[3] -Force -ErrorAction Stop } catch {} }
            foreach ($e in @($State[$t.Id] | Where-Object { $_ -and $_.K -eq 'Svc' })) { Stop-Service $e.Name -Force -ErrorAction SilentlyContinue; Set-Service $e.Name -StartupType Disabled -ErrorAction SilentlyContinue }
            Log "Re-applied: $($t.Name)"
        }
        $script:Drift = @(); $script:txtVerify.Text = 'Re-applied. Run Verify Now to confirm.'
    })
)
$lab.Children.Add($script:txtVerify) | Out-Null

# ----- 5. profiles and guided apply
function Invoke-Guided {
    $list = @($Tweaks | Where-Object { $script:Selected.Contains($_.Id) -and (Test-Applicable $_) -and -not $State.ContainsKey($_.Id) })
    if (-not $list.Count) { [void][Windows.MessageBox]::Show('Select tweaks on the Tweaks page first.', 'SharkOptimizer'); return }
    $risky = @($list | Where-Object { $_.Risk -ne 'Safe' })
    if ($risky.Count) {
        $msg = "These tweaks change how Windows behaves:`n`n" + (($risky | ForEach-Object { "[$($_.Risk.ToUpper())] $($_.Name)`n   $($_.Warn)" }) -join "`n`n") + "`n`nContinue with guided apply?"
        if ([Windows.MessageBox]::Show($msg, 'SharkOptimizer - review', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    New-RestorePoint
    $batches = @(for ($i = 0; $i -lt $list.Count; $i += 3) { , @($list[$i..([math]::Min($i + 2, $list.Count - 1))]) })
    $n = 0
    foreach ($b in $batches) {
        $n++
        foreach ($t in $b) { Log "Applying: $($t.Name)"; try { Apply-Tweak $t } catch { Log "  Failed: $($_.Exception.Message)" } }
        Save-State; Render-Tweaks
        $names = ($b | ForEach-Object { $_.Name }) -join "`n- "
        $ans = [Windows.MessageBox]::Show("Batch $n of $($batches.Count) applied:`n- $names`n`nTest your game or ping now. Keep these changes?", 'SharkOptimizer - guided apply', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { foreach ($t in $b) { try { Undo-Tweak $t } catch {} }; Save-State; Render-Tweaks; Log "Batch $n undone." }
    }
    $script:Selected.Clear(); Render-Tweaks; Log 'Guided apply finished.'
}
Add-LabSection 'Profiles and safe apply' 'Export what you applied, import it on another PC, apply selected tweaks in small batches you can test, or go back to Windows defaults.'
Add-LabRow @(
    (New-LabButton 'Export Profile' {
        $dlg = New-Object Microsoft.Win32.SaveFileDialog; $dlg.Filter = 'SharkOptimizer profile (*.json)|*.json'; $dlg.FileName = 'shark-profile.json'
        if ($dlg.ShowDialog() -eq $true) {
            $ids = @($State.Keys | Where-Object { $_ -notlike 'game_*' } | Sort-Object)
            @{ App = 'SharkOptimizer'; Version = $AppVersion; Created = (Get-Date).ToString('s'); Tweaks = $ids } | ConvertTo-Json | Set-Content $dlg.FileName -Encoding UTF8
            Log "Profile exported: $($dlg.FileName) ($($ids.Count) tweaks)."
        }
    }),
    (New-LabButton 'Import Profile' {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog; $dlg.Filter = 'SharkOptimizer profile (*.json)|*.json'
        if ($dlg.ShowDialog() -eq $true) {
            try {
                $p = Get-Content $dlg.FileName -Raw | ConvertFrom-Json
                $script:Selected.Clear(); $n = 0
                foreach ($id in @($p.Tweaks)) { $tw = Get-Tweak ([string]$id); if ($tw -and (Test-Applicable $tw) -and -not $State.ContainsKey($tw.Id)) { [void]$script:Selected.Add($tw.Id); $n++ } }
                $script:CatFilter = 'All'; Render-Tweaks; Show-Page 'navTweaks'
                Log "Profile imported: $n tweaks selected. Review them, then click Apply Selected."
            } catch { Log "Import failed: $($_.Exception.Message)" }
        }
    }),
    (New-LabButton 'Guided Apply (selected tweaks)' { Invoke-Guided } $true),
    (New-LabButton 'Reset to Windows Defaults' {
        if ([Windows.MessageBox]::Show('Undo every applied tweak and game profile and return to your original settings?', 'Reset to defaults', 'YesNo', 'Warning') -eq 'Yes') {
            New-RestorePoint
            Invoke-Undo ($Tweaks | Where-Object { $State.ContainsKey($_.Id) })
            foreach ($gk in @($State.Keys | Where-Object { $_ -like 'game_*' })) { Undo-GameKey $gk }
            Save-State; Update-Stats; Render-Tweaks; Log 'Reset to defaults finished.'
        }
    })
)

# ----- 6. network tools
$script:PingVals = New-Object System.Collections.ArrayList
$script:PingTask = $null; $script:PingHost = '1.1.1.1'; $script:PingLoss = 0; $script:PingTotal = 0
$script:Pinger = New-Object Net.NetworkInformation.Ping
function Update-PingGraph {
    $vals = @($script:PingVals | Where-Object { $_ -ge 0 })
    $maxScale = [math]::Max(100, $(if ($vals.Count) { ($vals | Measure-Object -Maximum).Maximum * 1.2 } else { 100 }))
    $pts = New-Object Windows.Media.PointCollection
    $n = $script:PingVals.Count; $stepX = 640.0 / 59
    $startI = [math]::Max(0, 60 - $n)
    for ($i = 0; $i -lt $n; $i++) {
        $v = $script:PingVals[$i]; if ($v -lt 0) { continue }
        $y = 108 - [math]::Min($v, $maxScale) / $maxScale * 100
        [void]$pts.Add((New-Object Windows.Point(($startI + $i) * $stepX, $y)))
    }
    $script:poly.Points = $pts
    if ($vals.Count) {
        $jit = 0; $c = 0; for ($i = 1; $i -lt $vals.Count; $i++) { $jit += [math]::Abs($vals[$i] - $vals[$i-1]); $c++ }
        if ($c) { $jit = $jit / $c }
        $loss = if ($script:PingTotal) { [math]::Round(100 * $script:PingLoss / $script:PingTotal) } else { 0 }
        $script:txtPing.Text = ("{0}   now {1} ms   avg {2:N0}   min {3:N0}   max {4:N0}   jitter {5:N1}   loss {6}%" -f $script:PingHost, $vals[-1], ($vals | Measure-Object -Average).Average, ($vals | Measure-Object -Minimum).Minimum, ($vals | Measure-Object -Maximum).Maximum, $jit, $loss)
    }
}
$pingTimer = New-Object Windows.Threading.DispatcherTimer; $pingTimer.Interval = [TimeSpan]::FromSeconds(1)
$pingTimer.Add_Tick({
    try {
        if ($script:PingTask -and ($script:PingTask.IsCompleted -or $script:PingTask.IsFaulted)) {
            $val = -1
            if (-not $script:PingTask.IsFaulted) { $rep = $script:PingTask.Result; if ($rep.Status -eq 'Success') { $val = [int]$rep.RoundtripTime } }
            $script:PingTotal++; if ($val -lt 0) { $script:PingLoss++ }
            [void]$script:PingVals.Add($val); if ($script:PingVals.Count -gt 60) { $script:PingVals.RemoveAt(0) }
            $script:PingTask = $null
            Update-PingGraph
        }
        if (-not $script:PingTask) { $script:PingTask = $script:Pinger.SendPingAsync($script:PingHost, 900) }
    } catch {}
})
Add-LabSection 'Network tools' 'Live ping graph, traceroute and a Wi-Fi channel check. Use a game server address for the most useful graph.'
$script:txtPingHost = New-Object Windows.Controls.TextBox; $script:txtPingHost.Text = '1.1.1.1'; $script:txtPingHost.Width = 220; $script:txtPingHost.Margin = '4'
$pingRow = New-Object Windows.Controls.WrapPanel; $pingRow.Margin = '-4,0,0,0'; $pingRow.Children.Add($script:txtPingHost) | Out-Null
$pingRow.Children.Add((New-LabButton 'Start Live Ping' {
    $h = $script:txtPingHost.Text.Trim(); if (-not $h) { return }
    $script:PingHost = $h; $script:PingVals.Clear(); $script:PingLoss = 0; $script:PingTotal = 0; $script:PingTask = $null; $pingTimer.Start(); Log "Live ping started: $h"
} $true)) | Out-Null
$pingRow.Children.Add((New-LabButton 'Stop' { $pingTimer.Stop(); Log 'Live ping stopped.' })) | Out-Null
$pingRow.Children.Add((New-LabButton 'Traceroute' {
    $h = $script:txtPingHost.Text.Trim(); if ($h -match '^[A-Za-z0-9\.\-:]+$') { Start-Process cmd.exe -ArgumentList '/k', "tracert -d -h 20 -w 800 $h" } else { Log 'Enter a valid host first.' }
})) | Out-Null
$pingRow.Children.Add((New-LabButton 'Scan Wi-Fi Channels' {
    $script:txtWifi.Text = 'Scanning...'; Flush-UI
    try {
        $scan = (netsh wlan show networks mode=bssid) -join "`n"; $mine = (netsh wlan show interfaces) -join "`n"
        $chs = @([regex]::Matches($scan, 'Channel\s*:\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
        if (-not $chs.Count) { $script:txtWifi.Text = 'No Wi-Fi networks found. You may be on Ethernet or have no wireless adapter.'; return }
        $lines = @('Networks per channel:')
        foreach ($g in ($chs | Group-Object | Sort-Object { [int]$_.Name })) { $lines += ("  Channel {0,3}: {1} network(s)" -f $g.Name, $g.Count) }
        $m = [regex]::Match($mine, 'Channel\s*:\s*(\d+)'); if ($m.Success) { $lines += ''; $lines += "Your channel: $($m.Groups[1].Value)" }
        $best = 1, 6, 11 | Sort-Object { $c = $_; @($chs | Where-Object { $_ -ge $c - 2 -and $_ -le $c + 2 }).Count } | Select-Object -First 1
        $lines += "Least crowded 2.4 GHz channel (of 1, 6, 11): $best. Prefer 5 GHz when your router supports it."
        $script:txtWifi.Text = $lines -join "`r`n"
    } catch { $script:txtWifi.Text = "Scan failed: $($_.Exception.Message)" }
})) | Out-Null
$lab.Children.Add($pingRow) | Out-Null
$graphBorder = New-Object Windows.Controls.Border; $graphBorder.Background = Brush '#0F1A2C'; $graphBorder.BorderBrush = Brush '#1A2943'; $graphBorder.BorderThickness = 1; $graphBorder.CornerRadius = 12
$graphBorder.Width = 660; $graphBorder.Height = 120; $graphBorder.HorizontalAlignment = 'Left'; $graphBorder.Margin = '4,6,0,0'
$canvas = New-Object Windows.Controls.Canvas; $canvas.Width = 640; $canvas.Height = 110; $canvas.ClipToBounds = $true
$script:poly = New-Object Windows.Shapes.Polyline; $script:poly.Stroke = Brush '#1FB6FF'; $script:poly.StrokeThickness = 2; $script:poly.StrokeLineJoin = 'Round'
[void]$canvas.Children.Add($script:poly); $graphBorder.Child = $canvas
$lab.Children.Add($graphBorder) | Out-Null
$script:txtPing = New-Text 'Press Start Live Ping.' 12 '#1FB6FF' $false '4,6,0,0'; $lab.Children.Add($script:txtPing) | Out-Null
$script:txtWifi = New-LabBox 130; $lab.Children.Add($script:txtWifi) | Out-Null
$lab.Children.Add((New-Text ' ' 20 '#08101D')) | Out-Null

# ----- wire up the page
$labNav.Add_Click({ Refresh-GmProcs; Refresh-GmGames; Show-Page 'navLab' })
Refresh-GmProcs; Refresh-GmGames; Update-RPLine


# ================================================================ SharkOptimizer Pro UI (added module)
$ProVersion = '1.2.0'
function Has-Fn($n) { [bool](Get-Command $n -CommandType Function -ErrorAction SilentlyContinue) }
function Step($name, [scriptblock]$body) { try { & $body } catch { Log "UI step '$name' failed: $($_.Exception.Message)" } }
try { $window.Title = "SharkOptimizer v$ProVersion" } catch {}
$script:CurNav = 'navDash'
$script:QuickMode = $false
$script:LastRP = [datetime]::MinValue

# ---------------------------------------------------------------- 1. custom font (Poppins, open license, downloaded once)
Step 'font' {
    $fontDir = Join-Path $PSScriptRoot 'fonts'
    New-Item $fontDir -ItemType Directory -Force | Out-Null
    $files = [ordered]@{
        'Poppins-Regular.ttf' = 'https://raw.githubusercontent.com/google/fonts/main/ofl/poppins/Poppins-Regular.ttf'
        'Poppins-Bold.ttf'    = 'https://raw.githubusercontent.com/google/fonts/main/ofl/poppins/Poppins-Bold.ttf'
    }
    $marker = Join-Path $fontDir '.offline'
    $recentFail = (Test-Path $marker) -and (((Get-Date) - (Get-Item $marker).LastWriteTime).TotalDays -lt 3)
    foreach ($fn in @($files.Keys)) {
        $dest = Join-Path $fontDir $fn
        if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 50000) { continue }
        if ($recentFail) { continue }
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $files[$fn] -OutFile $dest -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        } catch { Remove-Item $dest -Force -ErrorAction SilentlyContinue; Set-Content $marker (Get-Date).ToString('s'); Log "Font download skipped: $($_.Exception.Message)"; break }
    }
    $ok = $true; foreach ($fn in @($files.Keys)) { $p = Join-Path $fontDir $fn; if (-not ((Test-Path $p) -and (Get-Item $p).Length -gt 50000)) { $ok = $false } }
    if ($ok) {
        $base = New-Object Uri(((Resolve-Path $fontDir).Path.TrimEnd('\') + '\'))
        $window.FontFamily = New-Object Windows.Media.FontFamily($base, './#Poppins')
        Log 'Custom font loaded (Poppins).'
    } else {
        $window.FontFamily = New-Object Windows.Media.FontFamily('Segoe UI Variable Display, Segoe UI')
    }
}

# ---------------------------------------------------------------- 2. custom title bar + header with quick actions
$right = $ui.pgDash.Parent.Parent
$hdrOk = $false
Step 'header' {
    $rd = New-Object Windows.Controls.RowDefinition; $rd.Height = [Windows.GridLength]::Auto
    $right.RowDefinitions.Insert(0, $rd)
    foreach ($ch in @($right.Children)) { [Windows.Controls.Grid]::SetRow($ch, [Windows.Controls.Grid]::GetRow($ch) + 1) }
    $right.Margin = '26,8,10,12'

    function New-HdrBtn($text, [scriptblock]$click, $accent = $false, $glyph = $false) {
        $b = New-Object Windows.Controls.Button; $b.Content = $text; $b.Padding = '12,6'; $b.Margin = '3,0'; $b.FontSize = 12; $b.VerticalAlignment = 'Center'
        if ($glyph) { $b.FontFamily = 'Segoe MDL2 Assets'; $b.FontSize = 11; $b.Padding = '12,8'; $b.Background = Brush '#0B1424' }
        if ($accent) { $b.Background = Brush '#1FB6FF'; $b.Foreground = Brush '#06121F' }
        $b.Add_Click($click)
        [System.Windows.Shell.WindowChrome]::SetIsHitTestVisibleInChrome($b, $true)
        $b
    }
    $hdr = New-Object Windows.Controls.Grid; $hdr.Height = 52; $hdr.Margin = '0,0,0,6'
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = '*'; $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = 'Auto'
    $hdr.ColumnDefinitions.Add($c1); $hdr.ColumnDefinitions.Add($c2)

    $left = New-Object Windows.Controls.StackPanel; $left.VerticalAlignment = 'Center'
    $script:hdrTitle = New-Text 'Dashboard' 15 '#FFFFFF' $true; $script:hdrTitle.TextWrapping = 'NoWrap'
    $script:hdrHint = New-Text '' 11.5 '#7F8FAE'; $script:hdrHint.TextWrapping = 'NoWrap'
    $left.Children.Add($script:hdrTitle) | Out-Null; $left.Children.Add($script:hdrHint) | Out-Null
    $hdr.Children.Add($left) | Out-Null

    $rp = New-Object Windows.Controls.StackPanel; $rp.Orientation = 'Horizontal'; $rp.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($rp, 1)
    $chip = New-Tag 'Score 0%' '#0F2E45' '#1FB6FF'; $chip.Margin = '0,0,10,0'; $chip.VerticalAlignment = 'Center'; $script:chipText = $chip.Child
    $rp.Children.Add($chip) | Out-Null
    $script:hdrApply = New-HdrBtn 'Apply Selected' { [void](Invoke-Apply ($Tweaks | Where-Object { $script:Selected.Contains($_.Id) })) } $true
    $script:hdrApply.Visibility = 'Collapsed'
    $rp.Children.Add($script:hdrApply) | Out-Null
    $rp.Children.Add((New-HdrBtn 'Apply Recommended' {
        [void](Invoke-Apply ($Tweaks | Where-Object { $_.Rec -and $_.Risk -eq 'Safe' -and (Test-Applicable $_) -and -not $State.ContainsKey($_.Id) })); Update-Stats
    } $true)) | Out-Null
    $script:hdrGame = New-HdrBtn 'Game Mode: Off' {
        if (Has-Fn 'Start-GameMode') { if ($script:GM.Active) { End-GameMode } else { Start-GameMode }; Update-ProChrome } else { Show-Page 'navDash' }
    }
    $rp.Children.Add($script:hdrGame) | Out-Null
    $rp.Children.Add((New-HdrBtn 'Restore Point' { New-RestorePoint })) | Out-Null
    $rp.Children.Add((New-HdrBtn ([string][char]0xE897) { Show-Guide (Get-GuideIndex $script:CurNav) } $false $true)) | Out-Null
    $sep = New-Object Windows.Controls.Border; $sep.Width = 1; $sep.Height = 22; $sep.Background = Brush '#1A2943'; $sep.Margin = '8,0'; $rp.Children.Add($sep) | Out-Null
    $rp.Children.Add((New-HdrBtn ([string][char]0xE921) { $window.WindowState = 'Minimized' } $false $true)) | Out-Null
    $script:hdrMax = New-HdrBtn ([string][char]0xE922) { if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' } else { $window.WindowState = 'Maximized' } } $false $true
    $rp.Children.Add($script:hdrMax) | Out-Null
    $closeBtn = New-HdrBtn ([string][char]0xE8BB) { $window.Close() } $false $true; $closeBtn.Background = Brush '#3A1F2B'
    $rp.Children.Add($closeBtn) | Out-Null
    $hdr.Children.Add($rp) | Out-Null
    [Windows.Controls.Grid]::SetRow($hdr, 0); $right.Children.Add($hdr) | Out-Null

    $wc = New-Object System.Windows.Shell.WindowChrome
    $wc.CaptionHeight = 52; $wc.ResizeBorderThickness = New-Object Windows.Thickness(6)
    $wc.GlassFrameThickness = New-Object Windows.Thickness(0); $wc.UseAeroCaptionButtons = $false
    [System.Windows.Shell.WindowChrome]::SetWindowChrome($window, $wc)
    $window.Add_StateChanged({
        if ($window.WindowState -eq 'Maximized') { $window.Content.Margin = New-Object Windows.Thickness(7); $script:hdrMax.Content = [string][char]0xE923 }
        else { $window.Content.Margin = New-Object Windows.Thickness(0); $script:hdrMax.Content = [string][char]0xE922 }
    })
    $script:hdrOk = $true
}

# ---------------------------------------------------------------- 3. sidebar sections, guide button, version
Step 'sidebar' {
    $nav = $ui.navDash.Parent
    function Add-NavLabel($before, $text) {
        $tb = New-Text $text 10 '#566684' $true '22,16,0,4'
        $i = $nav.Children.IndexOf($before); if ($i -ge 0) { $nav.Children.Insert($i, $tb) }
    }
    Add-NavLabel $ui.navDash 'OVERVIEW'
    Add-NavLabel $ui.navTweaks 'TUNE'
    Add-NavLabel $ui.navWin 'SYSTEM'
    Add-NavLabel $ui.navBoost 'MAINTAIN'
    $gb = New-Object Windows.Controls.Button; $gb.Content = 'Guide  (how to use)'; $gb.Margin = '10,0,10,4'; $gb.Padding = '14,9'; $gb.FontSize = 12
    $gb.Add_Click({ Show-Guide (Get-GuideIndex $script:CurNav) })
    [Windows.Controls.DockPanel]::SetDock($gb, 'Bottom')
    $dock = $ui.txtSide.Parent; $dock.Children.Insert($dock.Children.IndexOf($ui.txtSide) + 1, $gb)
    $ui.txtSide.Text = $ui.txtSide.Text + "`nv$ProVersion"
}

# ---------------------------------------------------------------- 4. switches + Quick Tune card
$switchXaml = @'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="CheckBox">
 <Setter Property="Foreground" Value="#E8ECF4"/><Setter Property="Cursor" Value="Hand"/>
 <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
  <StackPanel Orientation="Horizontal" Background="Transparent">
   <Grid Width="42" Height="24" VerticalAlignment="Center">
    <Border x:Name="track" CornerRadius="12" Background="#26324D"/>
    <Ellipse Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"><Ellipse.RenderTransform><TranslateTransform x:Name="kt" X="0"/></Ellipse.RenderTransform></Ellipse>
   </Grid>
   <ContentPresenter Margin="12,0,0,0" VerticalAlignment="Center"/>
  </StackPanel>
  <ControlTemplate.Triggers>
   <Trigger Property="IsChecked" Value="True">
    <Setter TargetName="track" Property="Background" Value="#1FB6FF"/>
    <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="kt" Storyboard.TargetProperty="X" To="18" Duration="0:0:0.16"/></Storyboard></BeginStoryboard></Trigger.EnterActions>
    <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="kt" Storyboard.TargetProperty="X" To="0" Duration="0:0:0.16"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
   </Trigger>
   <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
  </ControlTemplate.Triggers>
 </ControlTemplate></Setter.Value></Setter>
</Style>
'@
$script:QuickToggles = @()
$script:OrigRP2 = ${function:New-RestorePoint}
function New-RestorePoint {
    if ($script:QuickMode -and ((Get-Date) - $script:LastRP).TotalMinutes -lt 30) { Log 'Using the recent restore point.'; return }
    & $script:OrigRP2; $script:LastRP = Get-Date
}
function Invoke-QuickToggle($cb) {
    $t = Get-Tweak $cb.Tag; if (-not $t) { return }
    $script:QuickMode = $true
    try {
        if ($cb.IsChecked) { $res = @(Invoke-Apply @($t)) | Select-Object -Last 1; if ($res -ne $true) { $cb.IsChecked = $false } }
        else { Invoke-Undo @($t) }
    } finally { $script:QuickMode = $false }
    Update-Stats
}
Step 'quicktune' {
    $sw = [Windows.Markup.XamlReader]::Parse($switchXaml)
    $quick = @(
        @{ Id = 'f_gamemode'; Name = 'Game Mode'; Sub = 'Windows prioritises your game' }
        @{ Id = 'f_dvr'; Name = 'Background recording off'; Sub = 'Fewer frametime spikes' }
        @{ Id = 'f_power'; Name = 'Ultimate Performance plan'; Sub = 'Max speed, more heat and power' }
        @{ Id = 'n_nagle'; Name = 'Lower ping (Nagle off)'; Sub = 'Sends small packets instantly' }
        @{ Id = 'n_dns'; Name = 'Fast DNS (Cloudflare)'; Sub = 'Quicker lookups' }
        @{ Id = 'f_mouse'; Name = 'Raw mouse input'; Sub = 'No pointer acceleration' }
        @{ Id = 'q_visfx'; Name = 'Light visuals'; Sub = 'Less animation, less GPU use' }
        @{ Id = 'p_telemetry'; Name = 'Telemetry off'; Sub = 'Less background activity' }
    )
    $card = New-Object Windows.Controls.Border; $card.Margin = '0,6,0,6'; $card.Padding = '18,14'; $card.CornerRadius = 14
    $card.Background = Brush '#0F1A2C'; $card.BorderBrush = Brush '#1A2943'; $card.BorderThickness = 1
    $st = New-Object Windows.Controls.StackPanel
    $st.Children.Add((New-Text 'Quick Tune' 15 '#FFFFFF' $true)) | Out-Null
    $st.Children.Add((New-Text 'Flip a switch to apply or undo a tweak right away. Risky ones ask first.' 12 '#7F8FAE' $false '0,2,0,8')) | Out-Null
    $ug = New-Object Windows.Controls.Primitives.UniformGrid; $ug.Columns = 2
    foreach ($q in $quick) {
        $tw = Get-Tweak $q.Id; if (-not $tw) { continue }
        $cb = New-Object Windows.Controls.CheckBox; $cb.Style = $sw; $cb.Tag = $q.Id; $cb.Margin = '0,7,14,7'
        $cb.IsEnabled = (Test-Applicable $tw); $cb.IsChecked = $State.ContainsKey($q.Id)
        $txt = New-Object Windows.Controls.StackPanel
        $txt.Children.Add((New-Text $q.Name 13 '#FFFFFF' $true)) | Out-Null
        $subColor = if ($tw.Risk -eq 'Safe') { '#7F8FAE' } else { '#FFC857' }
        $txt.Children.Add((New-Text ($q.Sub + $(if ($tw.Risk -ne 'Safe') { '  (' + $tw.Risk.ToLower() + ')' } else { '' })) 11 $subColor)) | Out-Null
        $cb.Content = $txt
        $cb.Add_Click({ Invoke-QuickToggle $this })
        $ug.Children.Add($cb) | Out-Null; $script:QuickToggles += $cb
    }
    $st.Children.Add($ug) | Out-Null; $card.Child = $st
    $ui.pgDash.Content.Children.Insert(4, $card)
}

# ---------------------------------------------------------------- 5. toast notifications
Step 'toast' {
    $script:toast = New-Object Windows.Controls.Border; $script:toast.CornerRadius = 12; $script:toast.Padding = '16,10'
    $script:toast.Background = Brush '#10304A'; $script:toast.BorderBrush = Brush '#1FB6FF'; $script:toast.BorderThickness = 1
    $script:toast.HorizontalAlignment = 'Right'; $script:toast.VerticalAlignment = 'Bottom'; $script:toast.Margin = '0,0,8,112'
    $script:toast.IsHitTestVisible = $false; $script:toast.Visibility = 'Collapsed'; [Windows.Controls.Panel]::SetZIndex($script:toast, 50)
    $script:toastText = New-Text '' 12.5 '#FFFFFF' $true; $script:toast.Child = $script:toastText
    [Windows.Controls.Grid]::SetRowSpan($script:toast, 3); $right.Children.Add($script:toast) | Out-Null
    $script:toastTimer = New-Object Windows.Threading.DispatcherTimer; $script:toastTimer.Interval = [TimeSpan]::FromSeconds(2.8)
    $script:toastTimer.Add_Tick({
        $script:toastTimer.Stop()
        $a = New-Object Windows.Media.Animation.DoubleAnimation; $a.To = 0; $a.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(300))
        $a.Add_Completed({ $script:toast.Visibility = 'Collapsed' })
        $script:toast.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
    })
}
function Show-Toast($msg, $bad = $false) {
    if (-not $script:toast) { return }
    $m = [string]$msg; if ($m.Length -gt 95) { $m = $m.Substring(0, 95) + '...' }
    $script:toastText.Text = $m
    $script:toast.BorderBrush = Brush $(if ($bad) { '#FF6B6B' } else { '#1FB6FF' })
    $script:toast.Visibility = 'Visible'
    $a = New-Object Windows.Media.Animation.DoubleAnimation; $a.From = 0; $a.To = 1; $a.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(220))
    $script:toast.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
    $script:toastTimer.Stop(); $script:toastTimer.Start()
}
$script:OrigLog = ${function:Log}
function Log($m) {
    & $script:OrigLog $m
    try {
        $s = [string]$m
        if ($s -match '(?i)failed|error') { Show-Toast $s $true }
        elseif ($s -match '^(Restore point created|Done\.|Undo finished|Guided apply finished|Game profile applied|Benchmark|Profile (exported|imported)|Preset|Launch options copied|Game Mode (started|ended)|Verify|Reset to defaults|Removed game|Custom font loaded|Startup app|Live ping)') { Show-Toast $s }
    } catch {}
}

# ---------------------------------------------------------------- 6. guide
$GuideFlag = Join-Path $DataDir 'guide-seen.txt'
$Slides = @(
    @{ T = 'Welcome to SharkOptimizer'; B = "SharkOptimizer matches tweaks to your PC and records every change, so you can undo it at any time.`n`nFirst, make a restore point. You can reopen this guide with the ? button at the top, or Guide in the sidebar."; Nav = $null; Btn = 'Create restore point'; Act = { New-RestorePoint } }
    @{ T = 'Dashboard'; B = "Live CPU, GPU and RAM sit at the top. Quick Tune switches apply or undo common tweaks instantly.`n`nPresets select a ready-made set on the Tweaks page for you to review. The score shows how many recommended tweaks you have applied."; Nav = 'navDash'; Btn = 'Go to Dashboard' }
    @{ T = 'Tweaks'; B = "Use the tabs to filter by category. Tags show the risk: SAFE, CAUTION or CORE WINDOWS CHANGE.`n`nTick tweaks, then press Apply Selected (also at the top). Details shows exactly what a tweak changes. Undo Selected reverses it."; Nav = 'navTweaks'; Btn = 'Go to Tweaks' }
    @{ T = 'Games'; B = "Press Scan for Games, pick a game, read the tips and press Optimize.`n`nGames with anti-cheat only get Windows-level changes. Nothing touches game files."; Nav = 'navGames'; Btn = 'Go to Games' }
    @{ T = 'Windows and Boost-Up'; B = "Windows has repair tools, startup app control, built-in app removal and a heavy-app closer.`n`nBoost-Up runs cleaners. Running it about once a month is enough."; Nav = 'navWin'; Btn = 'Go to Windows' }
    @{ T = 'Lab: measure and verify'; B = "Run the benchmark BEFORE, apply your tweaks, restart if asked, then run it AFTER to see what changed.`n`nGame Mode closes the apps you pick and restores everything when your game exits. Verify checks that your tweaks are still in place."; Nav = $(if ($ui.Contains('navLab')) { 'navLab' } else { 'navDash' }); Btn = 'Go to Lab' }
    @{ T = 'Network'; B = "Test Regions and DNS Benchmark show your ping and the fastest DNS. Apply Best DNS uses it.`n`nA live ping graph and traceroute are in the Lab."; Nav = 'navNet'; Btn = 'Go to Network' }
    @{ T = 'Stay safe'; B = "The Restore tab lists everything applied and lets you undo it. Reset to Windows Defaults (in the Lab) undoes everything.`n`nIf a game or app acts odd after a change, undo the last tweak first."; Nav = 'navRestore'; Btn = 'Go to Restore' }
)
function Get-GuideIndex($nav) {
    switch ($nav) { 'navDash' { 1 } 'navTweaks' { 2 } 'navGames' { 3 } 'navWin' { 4 } 'navBoost' { 4 } 'navLab' { 5 } 'navNet' { 6 } 'navRestore' { 7 } default { 0 } }
}
function Render-Slide {
    $s = $Slides[$script:gi]
    $script:gStep.Text = "STEP $($script:gi + 1) OF $($Slides.Count)"
    $script:gTitle.Text = $s.T; $script:gBody.Text = $s.B
    $script:gGo.Content = $s.Btn; $script:gGo.Visibility = $(if ($s.Btn) { 'Visible' } else { 'Collapsed' })
    $script:gBack.IsEnabled = ($script:gi -gt 0)
    $script:gNext.Content = $(if ($script:gi -ge $Slides.Count - 1) { 'Finish' } else { 'Next' })
    for ($i = 0; $i -lt $script:gDots.Children.Count; $i++) { $script:gDots.Children[$i].Background = Brush $(if ($i -eq $script:gi) { '#1FB6FF' } else { '#26324D' }) }
    if (Has-Fn 'Animate-In') { Animate-In $script:gPanel 0 10 220 }
}
function Show-Guide($start = 0) {
    if ($script:GuideWin -and $script:GuideWin.IsVisible) { $script:gi = $start; Render-Slide; $script:GuideWin.Activate(); return }
    $script:gi = [math]::Max(0, [math]::Min($start, $Slides.Count - 1))
    $g = New-Object Windows.Window; $g.Title = 'Guide - SharkOptimizer'; $g.Width = 620; $g.Height = 410; $g.WindowStyle = 'None'; $g.ResizeMode = 'NoResize'
    $g.Background = Brush '#0B1424'; $g.Owner = $window; $g.WindowStartupLocation = 'CenterOwner'
    $outer = New-Object Windows.Controls.Border; $outer.BorderBrush = Brush '#1FB6FF'; $outer.BorderThickness = 1; $outer.Padding = '34,28,34,22'
    $grid = New-Object Windows.Controls.Grid
    foreach ($h in 'Auto', '*', 'Auto') { $r = New-Object Windows.Controls.RowDefinition; $r.Height = $h; $grid.RowDefinitions.Add($r) }
    $script:gDots = New-Object Windows.Controls.StackPanel; $script:gDots.Orientation = 'Horizontal'
    foreach ($d in $Slides) { $dot = New-Object Windows.Controls.Border; $dot.Width = 18; $dot.Height = 5; $dot.CornerRadius = 3; $dot.Margin = '0,0,5,0'; $dot.Background = Brush '#26324D'; $script:gDots.Children.Add($dot) | Out-Null }
    [Windows.Controls.Grid]::SetRow($script:gDots, 0); $grid.Children.Add($script:gDots) | Out-Null
    $script:gPanel = New-Object Windows.Controls.StackPanel; $script:gPanel.Margin = '0,20,0,0'
    $script:gStep = New-Text '' 11 '#1FB6FF' $true; $script:gTitle = New-Text '' 26 '#FFFFFF' $true '0,4,0,10'; $script:gBody = New-Text '' 14 '#C2CCDF'
    $script:gBody.LineHeight = 22
    $script:gGo = New-Object Windows.Controls.Button; $script:gGo.HorizontalAlignment = 'Left'; $script:gGo.Margin = '0,18,0,0'; $script:gGo.Padding = '16,9'
    $script:gGo.Add_Click({ $s = $Slides[$script:gi]; if ($s.Nav) { Show-Page $s.Nav }; if ($s.Act) { & $s.Act } })
    foreach ($e in $script:gStep, $script:gTitle, $script:gBody, $script:gGo) { $script:gPanel.Children.Add($e) | Out-Null }
    [Windows.Controls.Grid]::SetRow($script:gPanel, 1); $grid.Children.Add($script:gPanel) | Out-Null
    $foot = New-Object Windows.Controls.DockPanel
    $skip = New-Object Windows.Controls.Button; $skip.Content = 'Close'; $skip.Add_Click({ $script:GuideWin.Close() }); [Windows.Controls.DockPanel]::SetDock($skip, 'Left')
    $script:gNext = New-Object Windows.Controls.Button; $script:gNext.Background = Brush '#1FB6FF'; $script:gNext.Foreground = Brush '#06121F'; [Windows.Controls.DockPanel]::SetDock($script:gNext, 'Right')
    $script:gNext.Add_Click({ if ($script:gi -ge $Slides.Count - 1) { $script:GuideWin.Close() } else { $script:gi++; Render-Slide } })
    $script:gBack = New-Object Windows.Controls.Button; $script:gBack.Content = 'Back'; [Windows.Controls.DockPanel]::SetDock($script:gBack, 'Right')
    $script:gBack.Add_Click({ if ($script:gi -gt 0) { $script:gi--; Render-Slide } })
    foreach ($e in $skip, $script:gNext, $script:gBack) { $foot.Children.Add($e) | Out-Null }
    [Windows.Controls.Grid]::SetRow($foot, 2); $grid.Children.Add($foot) | Out-Null
    $outer.Child = $grid; $g.Content = $outer
    $g.Add_MouseLeftButtonDown({ try { $script:GuideWin.DragMove() } catch {} })
    $g.Add_Closed({ try { Set-Content $GuideFlag (Get-Date).ToString('s') } catch {} })
    $script:GuideWin = $g
    Render-Slide
    $g.Show()
}
if (-not (Test-Path $GuideFlag)) { $window.Add_ContentRendered({ try { if (-not (Test-Path $GuideFlag)) { Show-Guide 0 } } catch {} }) }

# ---------------------------------------------------------------- 7. keep the chrome in sync
$PageInfo = @{
    navDash = @('Dashboard', 'Your PC at a glance. Use Quick Tune and Presets for fast results.')
    navTweaks = @('Tweaks', 'Tick tweaks, then Apply Selected. Tags show how risky each one is.')
    navGames = @('Games', 'Scan, pick a game, then Optimize. Anti-cheat games get safe Windows-level changes only.')
    navWin = @('Windows', 'Repair tools, startup apps, built-in app removal and heavy-app closer.')
    navLab = @('Lab', 'Benchmark before and after, Game Mode, system check, verify and profiles.')
    navBoost = @('Boost-Up', 'Routine cleanups. Run about once a month.')
    navNet = @('Network', 'Ping, DNS benchmark and server tests.')
    navRestore = @('Restore', 'See what is applied and undo anything.')
}
function Update-ProChrome {
    if (-not $script:hdrTitle) { return }
    try {
        $info = $PageInfo[$script:CurNav]; if ($info) { $script:hdrTitle.Text = "SharkOptimizer  /  $($info[0])"; $script:hdrHint.Text = $info[1] }
        $script:chipText.Text = "Score $($ui.txtScore.Text)"
        $n = $script:Selected.Count
        $script:hdrApply.Content = "Apply Selected ($n)"
        $script:hdrApply.Visibility = $(if ($script:CurNav -eq 'navTweaks' -and $n -gt 0) { 'Visible' } else { 'Collapsed' })
        $on = ($script:GM -and $script:GM.Active)
        $script:hdrGame.Content = $(if ($on) { 'Game Mode: On' } else { 'Game Mode: Off' })
        $script:hdrGame.Background = Brush $(if ($on) { '#14352A' } else { '#16233A' })
        foreach ($cb in $script:QuickToggles) { $cb.IsChecked = $State.ContainsKey([string]$cb.Tag) }
    } catch {}
}
$script:OrigUS = ${function:Update-Stats}
function Update-Stats { & $script:OrigUS; Update-ProChrome }
$script:OrigShowPage = ${function:Show-Page}
function Show-Page($nav) { $script:CurNav = $nav; & $script:OrigShowPage $nav; Update-ProChrome }
Update-ProChrome


# ================================================================ SharkOptimizer Declutter (added module)
function Hide-Safe($el) { try { if ($el) { $el.Visibility = 'Collapsed' } } catch {} }

# 1. Dashboard: remove Quick Tune and extra text
try {
    $dc = $ui.pgDash.Content
    foreach ($ch in @($dc.Children)) {
        if ($ch -is [Windows.Controls.Border] -and $ch.Child -is [Windows.Controls.StackPanel] -and $ch.Child.Children.Count -gt 0 -and $ch.Child.Children[0].Text -eq 'Quick Tune') { $dc.Children.Remove($ch) }
        elseif ($ch -is [Windows.Controls.TextBlock] -and $ch.Text -like 'Recommended applies*') { $ch.Visibility = 'Collapsed' }
        elseif ($ch -is [Windows.Controls.Border] -and $ch.Child -is [Windows.Controls.StackPanel]) {
            foreach ($x in @($ch.Child.Children)) { if ($x -is [Windows.Controls.TextBlock] -and $x.Text -like 'Pick a preset*') { $x.Visibility = 'Collapsed' } }
        }
    }
    $script:QuickToggles = @()
} catch {}

# 2. Header: keep only the page name, Apply Selected (when relevant), help and window buttons
try {
    if ($script:hdrTitle) {
        Hide-Safe $script:hdrHint
        Hide-Safe $script:hdrGame
        Hide-Safe $script:chipText.Parent
        foreach ($b in @($script:hdrApply.Parent.Children)) {
            if ($b -is [Windows.Controls.Button] -and ($b.Content -eq 'Apply Recommended' -or $b.Content -eq 'Restore Point')) { $b.Visibility = 'Collapsed' }
        }
    }
} catch {}

# 3. Sidebar: remove section headings
try {
    $navPanel = $ui.navDash.Parent
    foreach ($x in @($navPanel.Children)) {
        if ($x -is [Windows.Controls.TextBlock] -and @('OVERVIEW', 'TUNE', 'SYSTEM', 'MAINTAIN') -contains $x.Text) { $navPanel.Children.Remove($x) }
    }
} catch {}

# 4. Smaller activity log
try {
    $rootGrid = $ui.pgDash.Parent.Parent
    if ($rootGrid.RowDefinitions.Count -ge 3) { $rootGrid.RowDefinitions[2].Height = New-Object Windows.GridLength(64) }
} catch {}

# 5. Tweak cards: drop the category tag when a category tab is selected
$script:OrigNewCard2 = ${function:New-Card}
function New-Card($t) {
    $c = & $script:OrigNewCard2 $t
    try {
        if ($script:CatFilter -ne 'All') {
            $tags = $c.Child.Children[0]
            if ($tags -is [Windows.Controls.WrapPanel] -and $tags.Children.Count -gt 1) { $tags.Children.RemoveAt(0) }
        }
    } catch {}
    $c
}
try { Update-ProChrome } catch {}


# ================================================================ SharkOptimizer Settings, Dutch and Updates (added module)
$AppVer = '1.3.0'
try { $window.Title = "SharkOptimizer v$AppVer" } catch {}
function Has-Fn($n) { [bool](Get-Command $n -CommandType Function -ErrorAction SilentlyContinue) }
function Tn($en, $nl) { if ($script:Lang -eq 'nl') { $nl } else { $en } }

# ---------------------------------------------------------------- settings
$SettingsFile = Join-Path $DataDir 'settings.json'
$Settings = @{ Language = 'en'; AutoUpdate = $true; Toasts = $true; ShowLog = $true; ScanOnStart = $false
               UpdateUrl = 'https://raw.githubusercontent.com/Bas-Makes-Stuff/SharkOptimizer/main/version.json' }
try { if ((Get-UICulture).TwoLetterISOLanguageName -eq 'nl') { $Settings.Language = 'nl' } } catch {}
if (Test-Path $SettingsFile) { try { $so = Get-Content $SettingsFile -Raw | ConvertFrom-Json; foreach ($spx in $so.PSObject.Properties) { $Settings[$spx.Name] = $spx.Value } } catch {} }
function Save-Settings { try { $Settings | ConvertTo-Json | Set-Content $SettingsFile -Encoding UTF8 } catch {} }
$script:Lang = 'en'

# ---------------------------------------------------------------- games: no fake "installed" at startup, remember scan results
foreach ($g in $Games) { if (-not $script:GamePaths.ContainsKey($g.Id)) { $script:GamePaths[$g.Id] = @() } }
$GameCache = Join-Path $DataDir 'games-cache.json'
if (Test-Path $GameCache) {
    try {
        $gc = Get-Content $GameCache -Raw | ConvertFrom-Json
        foreach ($gp in $gc.PSObject.Properties) { $script:GamePaths[$gp.Name] = @($gp.Value | Where-Object { $_ -and (Test-Path -LiteralPath ([string]$_)) } | ForEach-Object { [string]$_ }) }
    } catch {}
}
$script:OrigScan = ${function:Scan-Games}
function Scan-Games {
    & $script:OrigScan
    try {
        $out = @{}; foreach ($g in $Games) { $out[$g.Id] = @($script:GamePaths[$g.Id] | Where-Object { $_ }) }
        $out | ConvertTo-Json | Set-Content $GameCache -Encoding UTF8
    } catch {}
}
if ($Settings.ScanOnStart) { $window.Add_ContentRendered({ try { Scan-Games } catch {} }) }

# ---------------------------------------------------------------- Dutch data
$NL = @{}
$nlText = @'
Dashboard => Dashboard
Tweaks => Tweaks
Games => Games
Windows => Windows
Lab => Lab
Boost-Up => Boost-Up
Network => Netwerk
Restore => Herstel
Guide  (how to use) => Handleiding (uitleg)
Welcome to SharkOptimizer => Welkom bij SharkOptimizer
CPU USAGE => CPU-GEBRUIK
GPU 3D USAGE => GPU 3D-GEBRUIK
RAM USAGE => RAM-GEBRUIK
Optimizations active => Actieve optimalisaties
Recommended pending => Aanbevolen, nog te doen
Tweaks available => Beschikbare tweaks
Optimization score => Optimalisatiescore
Presets => Voorinstellingen
Safe Essentials => Veilige basis
Competitive => Competitief
Max Privacy => Maximale privacy
Low-End PC => Zwakke pc
Laptop Safe => Laptopveilig
Apply Recommended => Aanbevolen toepassen
Create Restore Point => Herstelpunt maken
Pick a preset to select its tweaks. You review them on the Tweaks page before anything is applied. => Kies een voorinstelling om de tweaks te selecteren. Je bekijkt ze op de Tweaks-pagina voordat er iets wordt toegepast.
Recommended applies safe tweaks only. => Aanbevolen past alleen veilige tweaks toe.
Recommended only => Alleen aanbevolen
All => Alles
Privacy & Security => Privacy en beveiliging
Quality of Life => Gebruiksgemak
FPS & Latency => FPS en latency
Network & Ping => Netwerk en ping
Windows Optimization => Windows-optimalisatie
Advanced => Geavanceerd
Select Recommended => Aanbevolen selecteren
Select Visible => Zichtbare selecteren
Clear => Wissen
Undo Selected => Geselecteerde ongedaan maken
Apply Selected => Geselecteerde toepassen
SAFE => VEILIG
CAUTION => LET OP
CORE WINDOWS CHANGE => KERNWIJZIGING WINDOWS
FOR YOUR PC => VOOR JOUW PC
RESTART NEEDED => HERSTART NODIG
Select => Selecteer
ACTIVE => ACTIEF
Inactive => Inactief
Details => Details
Needs Windows 11 22H2 or newer => Vereist Windows 11 22H2 of nieuwer
Needs Windows 11 24H2 or newer => Vereist Windows 11 24H2 of nieuwer
Needs Windows 11 => Vereist Windows 11
Needs an NVIDIA GPU => Vereist een NVIDIA-GPU
Needs an NVIDIA or AMD GPU => Vereist een NVIDIA- of AMD-GPU
Needs an Intel CPU => Vereist een Intel-CPU
Needs Windows 10 2004 or newer => Vereist Windows 10 2004 of nieuwer
Needs an SSD system drive => Vereist een SSD als systeemschijf
Needs 4 or more threads => Vereist 4 of meer threads
Needs 8 GB RAM or more => Vereist 8 GB RAM of meer
Needs 16 GB RAM or more => Vereist 16 GB RAM of meer
Needs a Wi-Fi adapter => Vereist een wifi-adapter
Desktop PCs only => Alleen desktop-pc's
Ethernet adapters only => Alleen ethernet-adapters
Ethernet and 6+ CPU threads => Ethernet en 6+ CPU-threads
Scan for Games => Games zoeken
Pick a game for a tuned profile. Scan to detect your installs. => Kies een game voor een afgestemd profiel. Zoek om je installaties te vinden.
Installed => Geïnstalleerd
Not detected => Niet gevonden
Profile active => Profiel actief
INSTALLED => GEÏNSTALLEERD
NOT DETECTED => NIET GEVONDEN
PROFILE ACTIVE => PROFIEL ACTIEF
Recommended Windows tweaks => Aanbevolen Windows-tweaks
In-game tips => Tips voor in de game
Launch options => Startopties
Copy => Kopiëren
Undo Game Settings => Game-instellingen ongedaan maken
Open Folder => Map openen
This game uses anti-cheat, so SharkOptimizer only changes Windows settings. It does not touch the game process, its files or its priority. => Deze game gebruikt anti-cheat, dus SharkOptimizer wijzigt alleen Windows-instellingen. Het raakt het gameproces, de bestanden of de prioriteit niet aan.
Repair tools, startup control, built-in app removal and a heavy-app closer. More Windows tweaks are under Tweaks > Windows Optimization. => Reparatiehulpmiddelen, beheer van opstart-apps, ingebouwde apps verwijderen en een sluiter voor zware apps. Meer Windows-tweaks staan onder Tweaks > Windows-optimalisatie.
Quick Tools => Snelle hulpmiddelen
Startup Apps => Opstart-apps
Untick an app to stop it launching at sign-in. Changes apply immediately and can be reversed. => Haal het vinkje weg om te voorkomen dat een app bij het aanmelden start. Wijzigingen gelden direct en zijn terug te draaien.
Refresh => Vernieuwen
Remove Built-in Apps => Ingebouwde apps verwijderen
Removes Microsoft apps you may not use. They can be reinstalled from the Microsoft Store, but this cannot be undone here. => Verwijdert Microsoft-apps die je misschien niet gebruikt. Je kunt ze opnieuw installeren via de Microsoft Store, maar dit is hier niet ongedaan te maken.
Remove Selected => Geselecteerde verwijderen
Close Heavy Apps => Zware apps sluiten
Open apps using the most RAM. Closing asks each app to quit normally, so you can still save your work. => Open apps met het meeste RAM-gebruik. Sluiten vraagt elke app om normaal af te sluiten, zodat je nog kunt opslaan.
Close Selected => Geselecteerde sluiten
System File Check => Systeembestanden controleren
DISM Repair => DISM-reparatie
Check Disk (scan) => Schijf controleren (scan)
Reset Windows Update => Windows Update resetten
Rebuild Icon Cache => Pictogramcache herbouwen
Restart Explorer => Verkenner herstarten
Disk Cleanup => Schijfopruiming
Power Options => Energiebeheer
Services => Services
Task Manager => Taakbeheer
No registry startup entries found. => Geen opstartitems in het register gevonden.
None of the listed apps are installed. => Geen van de genoemde apps is geïnstalleerd.
No other app windows are open. => Er zijn geen andere app-vensters open.
Routine cleanups. Run monthly or when your PC feels slow. => Routineopruiming. Voer maandelijks uit of als je pc traag aanvoelt.
Run All => Alles uitvoeren
Run => Uitvoeren
Not run yet => Nog niet uitgevoerd
Not needed on this PC => Niet nodig op deze pc
Junk Cleaner => Rommelopruimer
Temp files, update download cache, crash dumps and the Recycle Bin. => Tijdelijke bestanden, update-downloadcache, crashdumps en de Prullenbak.
Optimize Drives => Schijven optimaliseren
TRIM on SSDs, defrag on HDDs (system drive). => TRIM op SSD's, defragmenteren op harde schijven (systeemschijf).
Clean Recent Documents => Recente documenten wissen
Clears your Explorer recent files history. => Wist de lijst met recente bestanden van Verkenner.
Clean Thumbnail Cache => Miniatuurcache wissen
Rebuilds Explorer thumbnails and fixes broken previews. => Bouwt miniaturen van Verkenner opnieuw op en herstelt kapotte voorbeelden.
Clean Font Cache => Lettertypecache wissen
Resets the Windows font cache. => Zet de lettertypecache van Windows terug.
Clear Shader Caches => Shadercaches wissen
DirectX, NVIDIA and AMD shader caches. Your first game launch afterwards may stutter while they rebuild. => DirectX-, NVIDIA- en AMD-shadercaches. Bij de eerste start van een game kan het haperen terwijl ze opnieuw worden opgebouwd.
Clean Browser Caches => Browsercaches wissen
Cache folders for Chrome, Edge, Brave and Firefox. Logins and bookmarks are kept. => Cachemappen van Chrome, Edge, Brave en Firefox. Aanmeldingen en bladwijzers blijven behouden.
Trim Process RAM => Proces-RAM vrijmaken
Trims background process memory. The effect is temporary. => Maakt geheugen van achtergrondprocessen vrij. Het effect is tijdelijk.
Flush DNS Cache => DNS-cache legen
Clears stale DNS entries. => Wist verouderde DNS-items.
Measures ping, jitter and packet loss. Region tests use cloud endpoints as a route-quality guide. Enter a game server host to test it directly. => Meet ping, jitter en pakketverlies. Regiotests gebruiken cloud-eindpunten als maatstaf voor routekwaliteit. Vul een gameserver in om die direct te testen.
Test Regions => Regio's testen
Test Host => Host testen
DNS Benchmark => DNS-benchmark
Apply Best DNS => Beste DNS toepassen
Flush DNS => DNS legen
Every change is recorded, so you can revert it at any time. => Elke wijziging wordt vastgelegd, zodat je het altijd kunt terugdraaien.
Undo All Tweaks => Alle tweaks ongedaan maken
Open Log => Log openen
Currently applied => Nu toegepast
Nothing applied yet. => Nog niets toegepast.
Measure results, run Game Mode, check your hardware and manage your setup. => Meet resultaten, start Game Mode, controleer je hardware en beheer je opstelling.
Before and after benchmark => Meting voor en na
Measures ping, jitter, DNS speed, idle CPU, RAM, process count and boot time, so you can see what your tweaks really changed. Takes about 20 seconds. => Meet ping, jitter, DNS-snelheid, CPU in rust, RAM, aantal processen en opstarttijd, zodat je ziet wat je tweaks echt veranderd hebben. Duurt ongeveer 20 seconden.
Run BEFORE => Meting VOOR
Run AFTER => Meting NA
Clear Results => Resultaten wissen
Game Mode => Game Mode
Switches to a performance power plan, pauses Windows Update, closes apps you pick and trims memory. Everything is restored when it ends. Run a scan on the Games tab to list your games here. => Schakelt over naar een prestatie-energieplan, pauzeert Windows Update, sluit apps die je kiest en maakt geheugen vrij. Alles wordt hersteld als het stopt. Zoek eerst games op het tabblad Games om ze hier te zien.
Switch to a performance power plan => Schakel over naar een prestatie-energieplan
Pause the Windows Update service => Pauzeer de Windows Update-service
Trim background memory => Maak achtergrondgeheugen vrij
Launch this game when Game Mode starts: => Start deze game zodra Game Mode begint:
Close these apps first: => Sluit eerst deze apps:
Start Game Mode => Game Mode starten
End Game Mode => Game Mode stoppen
Refresh Lists => Lijsten vernieuwen
Game Mode is off. => Game Mode staat uit.
(none - manual start and end) => (geen - handmatig starten en stoppen)
System check => Systeemcontrole
Looks at drivers, RAM speed, display refresh rate and security features that affect gaming. => Kijkt naar stuurprogramma's, RAM-snelheid, beeldverversing en beveiligingsfuncties die gamen beïnvloeden.
Run System Check => Systeemcontrole uitvoeren
Verify applied tweaks => Toegepaste tweaks controleren
Windows updates and driver installers sometimes undo tweaks. This re-reads every applied tweak and shows any that drifted. => Windows-updates en driverinstallaties maken soms tweaks ongedaan. Dit leest elke toegepaste tweak opnieuw uit en toont welke zijn teruggedraaid.
Verify Now => Nu controleren
Re-apply Drifted => Teruggedraaide opnieuw toepassen
Profiles and safe apply => Profielen en veilig toepassen
Export what you applied, import it on another PC, apply selected tweaks in small batches you can test, or go back to Windows defaults. => Exporteer wat je hebt toegepast, importeer het op een andere pc, pas geselecteerde tweaks toe in kleine testbare groepjes, of ga terug naar de Windows-standaard.
Export Profile => Profiel exporteren
Import Profile => Profiel importeren
Guided Apply (selected tweaks) => Stap voor stap toepassen (geselecteerd)
Reset to Windows Defaults => Terug naar Windows-standaard
Network tools => Netwerkhulpmiddelen
Live ping graph, traceroute and a Wi-Fi channel check. Use a game server address for the most useful graph. => Live pinggrafiek, traceroute en een wifi-kanaalcontrole. Gebruik een gameserveradres voor de nuttigste grafiek.
Start Live Ping => Live ping starten
Stop => Stop
Traceroute => Traceroute
Scan Wi-Fi Channels => Wifi-kanalen scannen
Press Start Live Ping. => Druk op Live ping starten.
Close => Sluiten
Back => Terug
Next => Volgende
Finish => Klaar
Settings => Instellingen
Language, updates and behaviour. => Taal, updates en gedrag.
Language => Taal
Choose the language of the app. It changes instantly. => Kies de taal van de app. Deze verandert direct.
Updates => Updates
Check for updates when SharkOptimizer starts => Zoek naar updates bij het starten van SharkOptimizer
Update address (version.json) => Update-adres (version.json)
Save => Opslaan
Check now => Nu controleren
Open download page => Downloadpagina openen
Install update => Update installeren
Behaviour => Gedrag
Show pop-up notifications => Toon pop-upmeldingen
Show the activity log => Toon het activiteitenlogboek
Scan for games when SharkOptimizer starts => Zoek games bij het starten van SharkOptimizer
Help and data => Hulp en gegevens
Show the guide again => Toon de handleiding opnieuw
Open data folder => Gegevensmap openen
Open log file => Logbestand openen
Clear saved game scan => Opgeslagen game-scan wissen
Reset settings => Instellingen herstellen
About => Over
Made by Bas. Free to use. Every change can be undone. => Gemaakt door Bas. Gratis te gebruiken. Elke wijziging is ongedaan te maken.
Update available => Update beschikbaar
Download => Downloaden
Install now => Nu installeren
Later => Later
Not checked yet. => Nog niet gecontroleerd.
'@
foreach ($ln in ($nlText -split "`r?`n")) { $i = $ln.IndexOf(' => '); if ($i -gt 0) { $NL[$ln.Substring(0, $i)] = $ln.Substring($i + 4) } }
$NLRules = @(
    @('^Optimize for (.+)$', 'Optimaliseren voor $1'), @('^ACTIVE(\s{5})(.+)$', 'ACTIEF$1$2'), @('^Pending(\s{4})(.+)$', 'Nog niet$1$2'),
    @('^Unavailable(\s{2})(.+)$', 'Niet beschikbaar$1$2'), @('^(\d+) selected$', '$1 geselecteerd'), @('^Apply Selected \((\d+)\)$', 'Geselecteerde toepassen ($1)'),
    @('^STEP (\d+) OF (\d+)$', 'STAP $1 VAN $2'), @('^Scan finished\. Found (\d+) of (\d+) supported games\.$', 'Zoeken klaar. $1 van de $2 ondersteunde games gevonden.'),
    @('^Scanning (.+) \.\.\.$', 'Zoeken in $1 ...'), @('^Update available: v(.+)$', 'Update beschikbaar: v$1'), @('^SharkOptimizer  /  (.+)$', 'SharkOptimizer  /  $1')
)
$TweakNl = @{}
$tweakText = @'
p_telemetry|Telemetrie uitschakelen|Zet telemetrie op het minimum en stopt de DiagTrack-service. Minder CPU-, schijf- en netwerkgebruik op de achtergrond.
p_tasks|Telemetrietaken uitschakelen|Schakelt de Compatibility Appraiser-, CEIP- en schijfdiagnosetaken uit die op de achtergrond wakker worden.
p_adid|Advertentie-ID uitschakelen|Voorkomt dat apps een unieke advertentie-ID gebruiken om je te profileren.
p_bing|Webzoeken in Start uitschakelen|Start zoekt alleen op je pc, niet via Bing. Snellere resultaten en er worden geen zoekopdrachten verstuurd.
p_cortana|Cortana en cloudzoeken uitschakelen|Schakelt Cortana en cloudzoeken uit via beleid.
p_activity|Activiteitengeschiedenis uitschakelen|Windows verzamelt en uploadt je activiteitentijdlijn niet meer.
p_ads|Windows-advertenties verwijderen|Schakelt advertenties in het Startmenu, tips op het vergrendelscherm, promoties in Instellingen en stille app-installaties uit.
p_consumer|Consumentenfuncties blokkeren|Voorkomt dat Windows voorgestelde apps, Spotlight-inhoud en promotionele installaties pusht.
p_copilot|Copilot uitschakelen|Zet Copilot uit via beleid zodat het niet meer op de achtergrond laadt.
p_recall|Windows AI-gegevensanalyse uitschakelen|Blokkeert Recall-achtige AI-schermopnames en analyse van je activiteit.
p_widgets|Widgets uitschakelen|Stopt het Widgets-paneel en het bijbehorende webproces.
p_wer|Foutrapportage uitschakelen|Windows maakt en verstuurt geen crashrapporten meer.
p_feedback|Feedbackvragen uitschakelen|Windows vraagt je niet meer om feedback.
p_inventory|App-inventaris en Probleemstappenrecorder uitschakelen|Stopt de app-inventarisatie en het verzamelen van gegevens door de Probleemstappenrecorder.
p_ink|Verzamelen van typ- en inktgegevens stoppen|Windows verzamelt geen handschrift- en typvoorbeelden meer om suggesties te verbeteren.
p_clip|Klembordsynchronisatie via de cloud uitschakelen|Je klembordgeschiedenis wordt niet meer gesynchroniseerd tussen apparaten.
p_location|Locatieservices uitschakelen|Schakelt locatiebepaling van Windows uit voor de hele pc.|Kaarten, Weer en Mijn apparaat zoeken werken niet meer.
p_llmnr|LLMNR uitschakelen|Schakelt een verouderd naamresolutieprotocol uit dat aanvallers misbruiken op gedeelde netwerken.
p_remreg|Extern register uitschakelen|Stopt de service waarmee andere pc's via het netwerk je register kunnen bewerken.
p_remote|Extern assistentie uitschakelen|Sluit de deur voor Extern assistentie en verkleint je aanvalsoppervlak.
p_nvtel|NVIDIA-telemetrie uitschakelen|Stopt de NVIDIA Telemetry Container. Stuurprogramma's en games blijven werken.
p_do|Update-delen (P2P) uitschakelen|Windows uploadt geen updates meer naar andere pc's met jouw bandbreedte.
q_ext|Bestandsextensies tonen|Toont altijd .exe, .png, .txt enzovoort. Helpt bij het herkennen van nepbestanden.
q_hidden|Verborgen bestanden tonen|Toont verborgen bestanden en mappen in Verkenner.
q_thispc|Verkenner openen op Deze pc|Verkenner opent op Deze pc in plaats van Snelle toegang.
q_recent|Recente en veelgebruikte bestanden verbergen|Verkenner toont geen recente en veelgebruikte bestanden meer in Snelle toegang.
q_shake|Vensters schudden uitschakelen|Een venster schudden minimaliseert de andere niet meer.
q_dark|Donkere modus|Zet Windows en apps over op het donkere thema.
q_taskbar|Opgeruimde Windows 11-taakbalk|Lijnt de taakbalk links uit en verbergt de knoppen voor Widgets, Taakweergave en zoeken.
q_classic|Klassiek rechtsklikmenu|Brengt het volledige contextmenu terug in Windows 11.
q_boot|Gedetailleerde opstartberichten|Toont gedetailleerde berichten bij het opstarten en afsluiten. Maakt opstarten niet sneller, maar helpt bij het oplossen van problemen.
q_menu|Directe menu's|Menu's openen zonder vertraging.
q_kb|Snelle toetsenbordherhaling|Kortste herhalingsvertraging en snelste herhalingssnelheid.
q_shutdown|Sneller afsluiten|Services en apps krijgen 2 seconden om te sluiten. Vastgelopen apps worden automatisch beëindigd.|Apps met niet-opgeslagen werk kunnen tijdens het afsluiten worden gesloten.
q_startdelay|Opstartvertraging verwijderen|Opstart-apps starten direct in plaats van ongeveer 10 seconden te wachten.
q_sticky|Plakkende-toetsen-meldingen uitschakelen|Geen Shift x5-melding meer midden in een game.
q_reboot|Geforceerde herstarts door updates blokkeren|Windows herstart niet meer uit zichzelf terwijl je bent aangemeld.
q_welcome|Welkomstschermen na updates overslaan|Verbergt de pagina's "Laten we je apparaat afmaken" na updates.
q_visfx|Lichte visuele effecten|Schakelt animaties en transparantie uit voor een vlugger bureaublad en minder GPU- en RAM-gebruik.
q_bgapps|Achtergrond-apps blokkeren|Voorkomt dat Store-apps op de achtergrond draaien. Bespaart RAM en CPU.|Mail, Agenda en andere Store-apps sturen geen meldingen meer als ze gesloten zijn.
q_search|Zoekindexering uitschakelen|Stopt de indexer. Minder schijfgebruik op systemen met een harde schijf.|Zoeken naar bestanden in Start en Verkenner wordt veel trager.
f_gamemode|Spelmodus inschakelen|Zegt tegen Windows je game voorrang te geven en stuurprogramma-updates te pauzeren tijdens het spelen.
f_dvr|Achtergrondopname uitschakelen|Stopt Xbox Game Bar-opnames, een bekende oorzaak van frametime-pieken.|Win+G en Win+Alt+R-opnames werken niet meer.
f_overlay|Game Bar-overlay uitschakelen|Verwijdert de Game Bar-melding en de sneltoetsen voor de controller.
f_power|Energieplan Ultieme prestaties|Activeert het energieplan Ultieme prestaties: geen core parking en geen CPU-frequentievertragingen.|Meer stroomverbruik en warmte. Leegt laptopaccu's snel.
f_usb|USB selectief onderbreken uitschakelen|Voorkomt dat Windows USB-poorten uitschakelt. Voorkomt haperingen bij muis, toetsenbord en headset.
f_pcie|PCIe-energiebesparing uitschakelen|Houdt de PCIe-verbinding naar je GPU en SSD op volle snelheid (ASPM uit).
f_diskoff|Harde schijven nooit laten slapen|Schijven blijven actief op netstroom, wat haperingen voorkomt als een game na inactiviteit data laadt.
f_cpumin|Minimale CPU-status 100%|De CPU klokt op netstroom nooit terug. Haalt opstarttijd weg in competitieve games.|Hogere temperaturen en stroomverbruik in rust. Niet voor laptops op accu.
f_throttle|Energie-throttling uitschakelen|Voorkomt dat Windows achtergrond-apps zoals Discord, OBS en launchers vertraagt.
f_prio|Voorgrondprioriteit verhogen|Zet Win32PrioritySeparation op 0x26 (korte quanta, 3:1 voorgrondboost), een standaardinstelling voor lage inputlag.
f_mmcss|Gameplanning (MMCSS)|Geeft de Games-taak hoge GPU- en CPU-prioriteit en verlaagt de multimediareserve.
f_fso|Volledigschermoptimalisaties uitschakelen|Gebruikt echt exclusief volledig scherm. Kan de inputlag verlagen in oudere DX9- en DX11-games.|Kan tearing veroorzaken of FPS verlagen in sommige DX12-games.
f_mouse|Ruwe muisinvoer|Schakelt aanwijzerversnelling uit voor 1:1 richten. Afmelden is nodig.
f_hags|GPU-planning (HAGS)|Laat de GPU zijn eigen planning beheren. Nodig voor DLSS Frame Generation en kan CPU-belasting verlagen.|Kan haperingen geven op oudere GPU's of stuurprogramma's. Test je games na een herstart.
f_mpo|Multiplane Overlay (MPO) uitschakelen|Kan haperingen, flikkeren en zwarte schermen oplossen op sommige NVIDIA- en AMD-systemen.|Gebruik dit alleen bij flikkeren of haperingen. Het kan het stroomverbruik iets verhogen.
f_fast|Snel opstarten uitschakelen|Dwingt een echte koude start af bij afsluiten. Lost verouderde stuurprogramma's en haperingen na lange uptime op.|Koude starts duren een paar seconden langer, vooral op harde schijven.
f_sysmain|SysMain uitschakelen|SSD's hebben geen prefetching nodig. Vermindert willekeurige schijf- en RAM-activiteit.
f_timerreq|Globale timerresolutie|Herstelt timerresolutie per proces op Windows 11 zodat timerzware games consistent blijven.|Iets hoger stroomverbruik. Alleen relevant voor games die 0,5 ms-timers aanvragen.
n_nagle|Nagle-algoritme uitschakelen|Verstuurt kleine pakketten direct. Een klassieke oplossing voor ping en jitter in online games.
n_throttle|Netwerk-throttling uitschakelen|Verwijdert de netwerkbeperking voor multimedia.
n_qos|QoS-bandbreedtereserve verwijderen|Maakt de 20% bandbreedte vrij die Windows voor QoS kan reserveren.
n_ports|Sneller hergebruik van TCP-poorten|Kortere TIME_WAIT (30 s) en 65.534 gebruikerspoorten. Helpt bij lobby's die vaak opnieuw verbinden.
n_heur|TCP-heuristiek uitschakelen|Voorkomt dat Windows zelf TCP-venstergroottes overschrijft, wat de doorvoer stabiel houdt.
n_dns|Snelle DNS (Cloudflare)|Stelt 1.1.1.1 in op je actieve adapters voor snellere opzoekingen. Test eerst in het tabblad Netwerk.
n_rsc|Pakketsamenvoeging uitschakelen (RSC)|Stopt het bundelen van binnenkomende pakketten door de adapter. Lagere latency, iets meer CPU-gebruik.
n_lso|Large Send Offload uitschakelen|Verhelpt hapering bij uploads op sommige adapters en stuurprogramma's.|Kan het CPU-gebruik bij grote uploads iets verhogen.
n_nicpwr|Energiebesparing van adapter uitschakelen|Voorkomt dat Windows de adapter uitschakelt, wat lagpieken en willekeurige verbrekingen voorkomt.
n_eee|Green Ethernet / EEE uitschakelen|Schakelt Energy-Efficient Ethernet en vergelijkbare energiestanden uit die wakker-worden-vertraging toevoegen.
n_flow|Flow control uitschakelen|Voorkomt dat de adapter verkeer pauzeert als de ander daarom vraagt. Kan latencypieken verzachten.|Zware lokale bestandsoverdrachten kunnen zich iets anders gedragen.
n_intmod|Interrupt-moderatie uitschakelen|Levert pakketten direct aan de CPU in plaats van ze te bundelen. Lagere ping, hoger CPU-gebruik.|Verhoogt het CPU-gebruik bij veel netwerkverkeer. Zwakke CPU's kunnen FPS verliezen.
n_rss|Receive Side Scaling inschakelen|Verdeelt netwerkverwerking over CPU-kernen.
n_wifi|Wi-Fi maximale prestaties|Zet de wifi-energiebesparing op Maximale prestaties, op netstroom en accu.
n_netbios|NetBIOS over TCP/IP uitschakelen|Schakelt verouderde NetBIOS-naamberichten uit. Minder achtergrondruis op het netwerk.|Zeer oude bestandsdeling die op NetBIOS-namen vertrouwt werkt niet meer.
n_teredo|Teredo-tunneling uitschakelen|Schakelt de IPv6-over-IPv4-tunnel uit die overhead toevoegt en verbindingen kan vertragen.|Xbox Live-partychat en sommige peer-to-peer-games gebruiken Teredo.
w_edge|Achtergrondactiviteit van Edge stoppen|Schakelt Edge Startup Boost en achtergrondmodus uit, zodat Edge niet meer draait als het gesloten is.
w_services|Ongebruikte services uitschakelen|Zet Fax, Retail Demo, Windows Media-delen en Maps Broker uit. Maakt RAM en handles vrij.
w_chat|Teams-chatpictogram verwijderen|Verwijdert de Chat-knop uit de Windows 11-taakbalk.
w_lastaccess|NTFS-laatste-toegang bijwerken uitschakelen|Windows schrijft niet meer een tijdstempel bij elke leesactie. Minder schijfactiviteit.
w_8dot3|8.3-bestandsnamen uitschakelen|Stopt het maken van verouderde korte bestandsnamen voor elk bestand. Sneller bestanden maken.|Zeer oude 16-bits installatieprogramma's kunnen mislukken. Bestaande korte namen blijven behouden.
w_svchost|Service-hostprocessen samenvoegen|Groepeert services in minder svchost.exe-processen als je genoeg RAM hebt.|Als één gegroepeerde service crasht, kunnen andere in die groep ermee stoppen.
w_pagingexec|Kernel in RAM houden|Voorkomt dat Windows de kernel en stuurprogramma's naar schijf wegschrijft. Helpt de reactiesnelheid op pc's met veel RAM.|Gebruikt permanent iets meer RAM.
w_memcomp|Geheugencompressie uitschakelen|Slaat het comprimeren van RAM-pagina's over, wat wat CPU bespaart als je veel geheugen hebt.|Maakt dingen trager als je RAM vol raakt.
w_prefetch|Prefetcher uitschakelen|Schakelt de prefetcher en het vooraf laden van Superfetch uit. Niet nodig op SSD's.|Programma's kunnen op harde schijven iets trager starten.
w_maint|Automatisch onderhoud uitschakelen|Stopt Windows met het uitvoeren van onderhoudstaken in rusttijd volgens eigen schema.|Geplande defragmentatie en diagnose draaien niet. Gebruik in plaats daarvan Boost-Up.
w_onedrive|OneDrive-synchronisatie uitschakelen|Zet OneDrive-bestandssynchronisatie uit via beleid.|Bestanden blijven op je pc maar worden niet meer met de cloud gesynchroniseerd.
w_wudrv|Stuurprogramma's via Windows Update blokkeren|Windows Update vervangt je GPU- en chipsetstuurprogramma's niet meer door eigen versies.|Je moet stuurprogramma's zelf bijwerken via de fabrikant.
w_spooler|Printspooler uitschakelen|Stopt de printservice. Bespaart RAM en sluit een veelvoorkomend aanvalsoppervlak.|Printen en pdf-printers werken niet meer.
a_msi|GPU MSI-modus|Zet de GPU op Message Signaled Interrupts voor lagere DPC-latency.|Een niet-ondersteunde GPU of driver kan zwarte schermen geven. Houd een herstelpunt bij de hand.
a_tick|Dynamische tick uitschakelen|Constante timerinterrupts voor stabielere frametimes (bcdedit).|Hoger stroomverbruik en meer warmte in rust.
a_hyperv|Hypervisor uitschakelen|Voorkomt dat de Windows-hypervisor bij het opstarten laadt, waardoor virtualisatie-overhead verdwijnt.|WSL2, Docker, Windows Sandbox en Android-emulators werken niet meer totdat je dit ongedaan maakt.
a_xbox|Xbox-services uitschakelen|Schakelt Xbox Live-verificatie, opslaan van games, netwerken en accessoireservices uit.|Breekt de Xbox-app, Game Pass op pc, Xbox-aanmelding en cloudopslag.
a_ipv6|IPv6 uitschakelen|Dwingt alleen IPv4 af. Kan vreemde routering of DNS-vertraging bij sommige providers verhelpen.|Sommige games, Xbox Live en providers die op IPv6 vertrouwen kunnen falen of trager verbinden.
a_spectre|CPU-beveiligingsmaatregelen uitschakelen|Schakelt Spectre- en Meltdown-maatregelen uit. Kan FPS verhogen op oudere Intel-CPU's.|Beveiligingsrisico: stelt je CPU bloot aan speculatieve-uitvoeringsaanvallen. Vermijd dit op pc's voor bankieren of werk.
a_vbs|VBS / Geheugenintegriteit uitschakelen|Zet Virtualization-Based Security en HVCI uit, wat op sommige systemen FPS kost.|Verlaagt de kernelbeveiliging. Sommige anti-cheats en werkbeleid verwachten dat dit aan staat.
a_hib|Slaapstand uitschakelen|Verwijdert hiberfil.sys en maakt enkele GB vrij op de systeemschijf.|Slaapstand en Snel opstarten werken niet meer.
'@
foreach ($ln in ($tweakText -split "`r?`n")) { if (-not $ln.Trim()) { continue }; $f = $ln.Split('|'); $TweakNl[$f[0]] = @{ N = $f[1]; D = $f[2]; W = $(if ($f.Count -gt 3) { $f[3] } else { '' }) } }
$TipsNl = @{
    'valorant' = @('Zet Material, Texture, Detail en UI Quality op Low.', 'Schakel Vignette, Bloom, Distortion, Cast Shadows en V-Sync uit.', 'Gebruik MSAA 2x met Anisotropic Filtering 1x en laat Multithreaded Rendering aan.', 'Zet NVIDIA Reflex Low Latency aan (On + Boost) als je GPU dit ondersteunt.', 'Begrens FPS op ongeveer 3 onder de verversingssnelheid van je monitor (Limit FPS Always).', 'Vanguard vereist Secure Boot en TPM 2.0 op Windows 11. Geheugenintegriteit (VBS) is niet vereist, dus uitschakelen is optioneel.')
    'fortnite' = @('Performance Mode geeft op de meeste pc''s de stabielste FPS. DX12 kan op sommige nieuwere of AMD-systemen soepeler voelen, dus test beide.', 'Schaduwen uit is de grootste FPS-winst. Zet Effects en Post Processing op Low.', 'Lage Textures en Meshes verminderen VRAM-gebruik en streaming-haperingen.', 'Begrens FPS iets onder de verversingssnelheid van je monitor.')
    'cs2' = @('Startopties helpen maar een klein beetje. De meeste winst komt van de videoinstellingen in de game en de GPU-driverinstellingen.', 'Stel een FPS-limiet 10 boven je verversingssnelheid in voor stabiele frametimes (bijvoorbeeld +fps_max 250 voor 240 Hz).', 'Schakel V-Sync uit en gebruik ruwe muisinvoer in de game.')
    'apex' = @('Algemeen advies: gebruik exclusief volledig scherm, zet V-Sync uit en begrens FPS net onder je verversingssnelheid.', 'Verlaag Texture Streaming Budget als je weinig VRAM hebt om haperingen te voorkomen.', 'Werk je GPU-driver bij voordat je instellingen verandert.')
    'warzone' = @('Algemeen advies: compileer shaders na elke update opnieuw en houd de game op een SSD.', 'Begrens FPS net onder je verversingssnelheid en gebruik exclusief volledig scherm.', 'Sluit overlays en launchers die je niet nodig hebt tijdens het spelen.')
    'fivem' = @('Druk in de game op F8 en typ cl_drawfps true om FPS te tonen, of cl_drawperf true om ping, pakketverlies, CPU- en GPU-gebruik te tonen.', 'Zet MSAA en Reflection MSAA uit, zet Grass Quality op Normal en houd Extended Distance Scaling op het minimum.', 'Verlaag str_maxVehicleTextureRes in de console om VRAM-gebruik op zware servers te verminderen.', 'Serverscripts en gestreamde assets veroorzaken vaak meer lag dan je grafische instellingen, dus test op een paar servers.')
    'roblox' = @('Algemeen advies: zet Graphics Quality handmatig lager in de Roblox-instellingen.', 'Pas geen Roblox-bestanden aan. Tweaks op Windows-niveau zijn de veilige weg.', 'Sluit extra browsertabbladen en launchers, want Roblox belast de CPU zwaar.')
    'rocketleague' = @('Algemeen advies: schakel V-Sync uit en begrens FPS op of boven je verversingssnelheid voor de laagste inputlag.', 'Verlaag Render Quality en Effects Quality als je frametime-pieken ziet.')
    'overwatch' = @('Algemeen advies: zet Reduce Buffering aan, schakel V-Sync uit en begrens FPS iets boven je verversingssnelheid.', 'Gebruik Low of Medium voor Shadow en Effects detail voor een duidelijker beeld.')
    'rust' = @('Algemeen advies: houd de game op een SSD en verlaag Draw Distance en Shadow Cascades.', 'Rust gebruikt veel RAM, dus sluit andere apps voordat je speelt met 16 GB of minder.')
}
$LaunchWhereNl = @{ 'fortnite' = 'Epic Games Launcher > profiel > Settings > Fortnite > Additional Command Line Arguments. Door de community gemeld, test het zelf.'; 'cs2' = 'Steam > rechtsklik op CS2 > Eigenschappen > Startopties. Gebruik voor zwakke pc''s +fps_max 60 voor stabiliteit.' }
$PageNl = @{
    'navDash' = @('Dashboard', 'Je pc in één oogopslag. Gebruik voorinstellingen voor snelle resultaten.')
    'navTweaks' = @('Tweaks', 'Vink tweaks aan en kies Geselecteerde toepassen. Labels tonen hoe riskant elke tweak is.')
    'navGames' = @('Games', 'Zoek, kies een game en kies Optimaliseren. Games met anti-cheat krijgen alleen veilige wijzigingen op Windows-niveau.')
    'navWin' = @('Windows', 'Reparatiehulpmiddelen, opstart-apps, ingebouwde apps verwijderen en zware apps sluiten.')
    'navLab' = @('Lab', 'Meting voor en na, Game Mode, systeemcontrole, controleren en profielen.')
    'navBoost' = @('Boost-Up', 'Routineopruiming. Ongeveer één keer per maand uitvoeren.')
    'navNet' = @('Netwerk', 'Ping, DNS-benchmark en servertests.')
    'navRestore' = @('Herstel', 'Bekijk wat is toegepast en maak alles ongedaan.')
    'navSettings' = @('Instellingen', 'Taal, updates en gedrag.')
}
$slideText = @'
Welkom bij SharkOptimizer|SharkOptimizer stemt tweaks af op jouw pc en legt elke wijziging vast, zodat je alles op elk moment ongedaan kunt maken.\n\nMaak eerst een herstelpunt. Je kunt deze handleiding opnieuw openen met de ?-knop bovenaan, of via Handleiding in de zijbalk.|Herstelpunt maken
Dashboard|Bovenaan zie je live CPU, GPU en RAM.\n\nVoorinstellingen selecteren een kant-en-klare set op de Tweaks-pagina, zodat jij ze kunt bekijken. De score laat zien hoeveel aanbevolen tweaks je hebt toegepast.|Naar Dashboard
Tweaks|Gebruik de tabbladen om op categorie te filteren. Labels tonen het risico: VEILIG, LET OP of KERNWIJZIGING WINDOWS.\n\nVink tweaks aan en druk op Geselecteerde toepassen (ook bovenaan). Details toont precies wat een tweak wijzigt. Geselecteerde ongedaan maken draait het terug.|Naar Tweaks
Games|Druk op Games zoeken, kies een game, lees de tips en druk op Optimaliseren.\n\nGames met anti-cheat krijgen alleen wijzigingen op Windows-niveau. Er wordt niets aan gamebestanden aangeraakt.|Naar Games
Windows en Boost-Up|Windows heeft reparatiehulpmiddelen, beheer van opstart-apps, het verwijderen van ingebouwde apps en een sluiter voor zware apps.\n\nBoost-Up voert opruimacties uit. Ongeveer één keer per maand is genoeg.|Naar Windows
Lab: meten en controleren|Voer de meting VOOR uit, pas je tweaks toe, herstart als erom gevraagd wordt en voer daarna de meting NA uit om te zien wat er veranderd is.\n\nGame Mode sluit de apps die je kiest en zet alles terug als je game stopt. Controleren kijkt of je tweaks nog actief zijn.|Naar Lab
Netwerk|Regio's testen en DNS-benchmark tonen je ping en de snelste DNS. Beste DNS toepassen gebruikt die.\n\nEen live pinggrafiek en traceroute staan in het Lab.|Naar Netwerk
Veilig blijven|Het tabblad Herstel toont alles wat is toegepast en laat je het ongedaan maken. Terug naar Windows-standaard (in het Lab) maakt alles ongedaan.\n\nAls een game of app raar doet na een wijziging, maak dan eerst de laatste tweak ongedaan.|Naar Herstel
'@
$SlidesNl = @(); foreach ($ln in ($slideText -split "`r?`n")) { if (-not $ln.Trim()) { continue }; $f = $ln.Split('|'); $SlidesNl += , @{ T = $f[0]; B = ($f[1] -replace '\\n', "`n"); Btn = $f[2] } }

# keep English originals for switching back
$script:TweakEn = @{}; foreach ($t in $Tweaks) { $script:TweakEn[$t.Id] = @{ N = $t.Name; D = $t.Desc; W = $t.Warn } }
$script:TipsEn = @{}; $script:LwEn = @{}; foreach ($g in $Games) { $script:TipsEn[$g.Id] = @($g.Tips); $script:LwEn[$g.Id] = $g.LaunchWhere }
$script:TierEn = $ui.txtTier.Text; $script:SpecEn = $ui.txtSpecs.Text
$script:SlidesEn = $null
if ($Slides) {
    try { $Slides[1].B = "Live CPU, GPU and RAM sit at the top.`n`nPresets select a ready-made set on the Tweaks page for you to review. The score shows how many recommended tweaks you have applied." } catch {}
    $script:SlidesEn = @($Slides | ForEach-Object { @{ T = $_.T; B = $_.B; Btn = $_.Btn } })
}
$script:PageEn = $null
if ($PageInfo) { $PageInfo['navSettings'] = @('Settings', 'Language, updates and behaviour.'); $script:PageEn = $PageInfo.Clone() }
$script:L10nApplied = @{}

function Get-Nl($txt) {
    if ($null -eq $txt -or $txt -eq '') { return $null }
    if ($NL.ContainsKey($txt)) { return $NL[$txt] }
    foreach ($r in $NLRules) { if ($txt -match $r[0]) { return ($txt -replace $r[0], $r[1]) } }
    $null
}
function Translate-El($el) {
    if ($el -is [Windows.Controls.TextBlock]) {
        $nl = Get-Nl $el.Text
        if ($nl -and $nl -ne $el.Text) { $script:L10nApplied[$el] = @{ El = $el; Kind = 'T'; En = $el.Text; Nl = $nl }; $el.Text = $nl }
    } elseif ($el -is [Windows.Controls.ContentControl] -and $el.Content -is [string]) {
        $nl = Get-Nl $el.Content
        if ($nl -and $nl -ne $el.Content) { $script:L10nApplied[$el] = @{ El = $el; Kind = 'C'; En = $el.Content; Nl = $nl }; $el.Content = $nl }
    }
}
function Walk-Tree($o) {
    if ($null -eq $o) { return }
    Translate-El $o
    try { foreach ($c in @([Windows.LogicalTreeHelper]::GetChildren($o))) { if ($c -is [Windows.DependencyObject]) { Walk-Tree $c } } } catch {}
}
function Translate-Now($root) { if ($script:Lang -eq 'nl' -and $root) { try { Walk-Tree $root } catch {} } }

function Update-DashTexts {
    if ($script:Lang -eq 'nl') {
        $tier = switch ($Spec.Tier) { 'Entry-level' { 'Instapklasse' } 'High-end' { 'High-end' } default { 'Middenklasse' } }
        $ui.txtTier.Text = "$tier pc  -  tweaks afgestemd op jouw hardware"
        $ui.txtSpecs.Text = @(
            "OS       $($Spec.OS)  (build $($Spec.Build))",
            "CPU      $($Spec.CPU)  [$($Spec.Cores)C / $($Spec.Threads)T]",
            "GPU      $($Spec.GPU)",
            "RAM      $($Spec.RamGB) GB",
            "Opslag   $(if ($Spec.SSD) { 'SSD' } else { 'HDD of onbekend' }) systeemschijf",
            "Type     $(if ($Spec.Laptop) { 'Laptop' } else { 'Desktop' })",
            "Netwerk  $(if ($Spec.Wifi) { 'Wi-Fi' } else { 'Ethernet' })  ($($Spec.Nics -join ', '))") -join "`n"
    } else { $ui.txtTier.Text = $script:TierEn; $ui.txtSpecs.Text = $script:SpecEn }
}

function Set-Language($lang) {
    # 1. undo UI translations
    foreach ($rec in @($script:L10nApplied.Values)) {
        try {
            if ($rec.Kind -eq 'T') { if ($rec.El.Text -eq $rec.Nl) { $rec.El.Text = $rec.En } }
            else { if ($rec.El.Content -eq $rec.Nl) { $rec.El.Content = $rec.En } }
        } catch {}
    }
    $script:L10nApplied.Clear()
    $script:Lang = $lang; $Settings.Language = $lang; Save-Settings
    # 2. swap data (tweaks, tips, guide, header texts)
    foreach ($t in $Tweaks) {
        if ($lang -eq 'nl' -and $TweakNl.ContainsKey($t.Id)) { $x = $TweakNl[$t.Id]; $t.Name = $x.N; $t.Desc = $x.D; $t.Warn = $x.W }
        elseif ($script:TweakEn.ContainsKey($t.Id)) { $x = $script:TweakEn[$t.Id]; $t.Name = $x.N; $t.Desc = $x.D; $t.Warn = $x.W }
    }
    foreach ($g in $Games) {
        if ($lang -eq 'nl' -and $TipsNl.ContainsKey($g.Id)) { $g.Tips = @($TipsNl[$g.Id]) } else { $g.Tips = @($script:TipsEn[$g.Id]) }
        if ($lang -eq 'nl' -and $LaunchWhereNl.ContainsKey($g.Id)) { $g.LaunchWhere = $LaunchWhereNl[$g.Id] } else { $g.LaunchWhere = $script:LwEn[$g.Id] }
    }
    if ($Slides -and $script:SlidesEn) {
        for ($i = 0; $i -lt $Slides.Count; $i++) {
            $src = if ($lang -eq 'nl' -and $i -lt $SlidesNl.Count) { $SlidesNl[$i] } else { $script:SlidesEn[$i] }
            $Slides[$i].T = $src.T; $Slides[$i].B = $src.B; $Slides[$i].Btn = $src.Btn
        }
    }
    if ($PageInfo -and $script:PageEn) { foreach ($k in @($script:PageEn.Keys)) { $PageInfo[$k] = $(if ($lang -eq 'nl' -and $PageNl.ContainsKey($k)) { $PageNl[$k] } else { $script:PageEn[$k] }) } }
    # 3. translate static UI
    if ($lang -eq 'nl') { Walk-Tree $window }
    Update-DashTexts
    # 4. redraw dynamic parts
    try { Render-Tweaks } catch {}
    try { Render-GameList; if ($script:CurGame) { Show-Game $script:CurGame } } catch {}
    try { Update-Stats } catch {}
    try { if ($script:CurNav) { Update-ProChrome } } catch {}
    try { Refresh-LangButtons } catch {}
    if ($script:GuideWin -and $script:GuideWin.IsVisible) { try { Render-Slide; Translate-Now $script:GuideWin } catch {} }
}
# translate things that are rebuilt after the first switch
foreach ($fn in 'Render-Tweaks', 'Render-GameList', 'Show-Game', 'Show-Page', 'Show-Guide', 'Render-Slide', 'Update-Stats', 'Refresh-Startup', 'Refresh-Procs', 'Refresh-Bloat') {
    if (-not (Has-Fn $fn)) { continue }
    Set-Variable -Name ('Orig_' + ($fn -replace '-', '_')) -Scope Script -Value (Get-Command $fn -CommandType Function).ScriptBlock
}
function Render-Tweaks { & $script:Orig_Render_Tweaks; Translate-Now $ui.wrap }
function Render-GameList { & $script:Orig_Render_GameList; Translate-Now $ui.gameList }
function Show-Game($id) {
    & $script:Orig_Show_Game $id
    try {
        foreach ($b in @($ui.gameDetail.Children | ForEach-Object { if ($_ -is [Windows.Controls.WrapPanel]) { $_.Children } })) {
            if ($b -is [Windows.Controls.Button] -and $b.Content -eq 'Undo Game Settings') { $b.IsEnabled = $State.ContainsKey("game_$id") }
        }
    } catch {}
    Translate-Now $ui.gameDetail
}
function Show-Page($nav) {
    & $script:Orig_Show_Page $nav
    try { Translate-Now $ui[$pages[$nav]]; if ($script:Lang -eq 'nl' -and $script:hdrApply) { $nl = Get-Nl ([string]$script:hdrApply.Content); if ($nl) { $script:hdrApply.Content = $nl } } } catch {}
}
function Show-Guide($start = 0) { & $script:Orig_Show_Guide $start; Translate-Now $script:GuideWin }
function Render-Slide {
    & $script:Orig_Render_Slide
    if ($script:Lang -eq 'nl') {
        try {
            $script:gNext.Content = $(if ($script:gNext.Content -eq 'Finish') { 'Klaar' } else { 'Volgende' })
            $script:gStep.Text = Get-Nl $script:gStep.Text
        } catch {}
    }
}
function Refresh-Startup { & $script:Orig_Refresh_Startup; Translate-Now $ui.lstStartup }
function Refresh-Procs { & $script:Orig_Refresh_Procs; Translate-Now $ui.lstProc }
function Refresh-Bloat { & $script:Orig_Refresh_Bloat; Translate-Now $ui.lstBloat }

# ---------------------------------------------------------------- disable what does not apply
$script:BoostSkip = @()
function Test-BoostNeeded($name) {
    switch ($name) {
        'Clean Browser Caches' {
            $paths = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache", "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache", "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache", "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
            return [bool]($paths | Where-Object { Test-Path $_ })
        }
        'Clear Shader Caches' { return [bool]("$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\NVIDIA\GLCache", "$env:LOCALAPPDATA\AMD\DxCache" | Where-Object { Test-Path $_ }) }
        'Clean Font Cache' { return [bool](Get-Service FontCache -ErrorAction SilentlyContinue) }
        'Clean Thumbnail Cache' { return [bool](Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Filter 'thumbcache*' -Force -ErrorAction SilentlyContinue | Select-Object -First 1) }
        'Clean Recent Documents' { return [bool](Get-ChildItem "$env:APPDATA\Microsoft\Windows\Recent" -Force -ErrorAction SilentlyContinue | Select-Object -First 1) }
        default { return $true }
    }
}
try {
    for ($i = 0; $i -lt $BoostItems.Count; $i++) {
        $nm = $BoostItems[$i].Name
        if (Test-BoostNeeded $nm) { continue }
        $script:BoostSkip += $nm
        $row = $ui.lstBoost.Children[$i]; $dp = $row.Child
        foreach ($c in @($dp.Children)) {
            if ($c -is [Windows.Controls.Button]) { $c.IsEnabled = $false }
            elseif ($c -is [Windows.Controls.TextBlock]) { $c.Text = 'Not needed on this PC' }
        }
        $row.Opacity = 0.5
    }
} catch {}
$script:OrigRunBoost = ${function:Run-Boost}
function Run-Boost($name) { if ($script:BoostSkip -contains $name) { return }; & $script:OrigRunBoost $name }
try {
    if ($lab -and -not (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -match '802.11' })) {
        foreach ($pnl in @($lab.Children | Where-Object { $_ -is [Windows.Controls.WrapPanel] })) {
            foreach ($b in @($pnl.Children | Where-Object { $_ -is [Windows.Controls.Button] -and $_.Content -eq 'Scan Wi-Fi Channels' })) { $b.IsEnabled = $false }
        }
    }
} catch {}
$script:OrigUS3 = ${function:Update-Stats}
function Update-Stats {
    & $script:OrigUS3
    try {
        $ui.btnDashApply.IsEnabled = ($ui.txtRecCnt.Text -ne '0')
        $ui.btnApply.IsEnabled = ($script:Selected.Count -gt 0)
        $ui.btnUndo.IsEnabled = (@($Tweaks | Where-Object { $script:Selected.Contains($_.Id) -and $State.ContainsKey($_.Id) }).Count -gt 0)
        $ui.btnUndoAll.IsEnabled = ($State.Count -gt 0)
        if ($script:Lang -eq 'nl') {
            foreach ($tb in $ui.txtSel, $ui.txtApplied) { $nl = Get-Nl $tb.Text; if ($nl) { $tb.Text = $nl } }
            if ($script:hdrApply) { $nl = Get-Nl ([string]$script:hdrApply.Content); if ($nl) { $script:hdrApply.Content = $nl } }
        }
    } catch {}
}

# ---------------------------------------------------------------- toasts follow the settings
if (Has-Fn 'Show-Toast') {
    $script:OrigToast = ${function:Show-Toast}
    function Show-Toast($msg, $bad = $false) {
        if (-not $Settings.Toasts) { return }
        $m = [string]$msg
        if ($script:Lang -eq 'nl') {
            $m = $m -replace '^Restore point created\.', 'Herstelpunt gemaakt.' -replace '^Done\.', 'Klaar.' -replace '^Undo finished\.', 'Ongedaan maken klaar.' `
                -replace '^Guided apply finished\.', 'Stap voor stap toepassen klaar.' -replace '^Game profile applied: ', 'Gameprofiel toegepast: ' `
                -replace '^Launch options copied to clipboard\.', 'Startopties gekopieerd.' -replace '^Game Mode started\.', 'Game Mode gestart.' -replace '^Game Mode ended\.', 'Game Mode gestopt.' `
                -replace '^Reset to defaults finished\.', 'Teruggezet naar Windows-standaard.' -replace '^Custom font loaded.*', 'Lettertype geladen.'
        }
        & $script:OrigToast $m $bad
    }
}

# ---------------------------------------------------------------- update checker
function Compare-Newer($remote, $local) { try { [version]$remote -gt [version]$local } catch { $false } }
$script:UpdInfo = $null; $script:UpdTask = $null; $script:UpdManual = $false
$script:updBanner = $null
function Show-UpdateBanner {
    if (-not $script:updBanner -or -not $script:UpdInfo) { return }
    $script:updBannerText.Text = (Tn 'Update available' 'Update beschikbaar') + ": v$($script:UpdInfo.version)" + $(if ($script:UpdInfo.notes) { "  -  $($script:UpdInfo.notes)" } else { '' })
    $script:updBanner.Visibility = 'Visible'
    $script:btnUpdInstall.Visibility = $(if ($script:UpdInfo.files) { 'Visible' } else { 'Collapsed' })
    $script:btnSetInstall.Visibility = $script:btnUpdInstall.Visibility; $script:btnSetOpen.Visibility = 'Visible'
}
function Set-UpdStatus($text) { if ($script:txtUpdStatus) { $script:txtUpdStatus.Text = $text; Translate-Now $script:txtUpdStatus.Parent } }
function Start-UpdateCheck($manual = $false) {
    $url = [string]$Settings.UpdateUrl
    if (-not $url -or $url -notmatch '^https://') { if ($manual) { Set-UpdStatus (Tn 'Enter a valid https address first.' 'Vul eerst een geldig https-adres in.') }; return }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object Net.WebClient; $wc.Headers.Add('User-Agent', 'SharkOptimizer'); $wc.Encoding = [Text.Encoding]::UTF8
        $sep = if ($url.Contains('?')) { '&' } else { '?' }
        $script:UpdTask = $wc.DownloadStringTaskAsync([Uri]($url + $sep + 't=' + [guid]::NewGuid().ToString('N')))
        $script:UpdManual = $manual
        if ($manual) { Set-UpdStatus (Tn 'Checking...' 'Bezig met controleren...') }
        $script:UpdTimer.Start()
    } catch { if ($manual) { Set-UpdStatus (Tn 'Could not start the check.' 'Controle kon niet starten.') } }
}
$script:UpdTimer = New-Object Windows.Threading.DispatcherTimer; $script:UpdTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:UpdTimer.Add_Tick({
    if (-not $script:UpdTask) { $script:UpdTimer.Stop(); return }
    if (-not ($script:UpdTask.IsCompleted -or $script:UpdTask.IsFaulted -or $script:UpdTask.IsCanceled)) { return }
    $script:UpdTimer.Stop()
    try {
        if ($script:UpdTask.IsFaulted -or $script:UpdTask.IsCanceled) { throw 'offline' }
        $j = $script:UpdTask.Result | ConvertFrom-Json
        if (Compare-Newer ([string]$j.version) $AppVer) {
            $script:UpdInfo = $j; Show-UpdateBanner
            Set-UpdStatus ((Tn 'Update available' 'Update beschikbaar') + ": v$($j.version)")
            Log "Update available: v$($j.version)"
        } else { Set-UpdStatus (Tn "You are up to date (v$AppVer)." "Je hebt de nieuwste versie (v$AppVer).") }
    } catch {
        if ($script:UpdManual) { Set-UpdStatus (Tn 'Could not check for updates. Are you online, and is the address right?' 'Updatecontrole mislukt. Ben je online en klopt het adres?') }
    }
    $script:UpdTask = $null
})
function Install-Update {
    $info = $script:UpdInfo
    if (-not $info) { return }
    if (-not $info.files) { if ($info.url) { Start-Process ([string]$info.url) }; return }
    $msg = Tn "Download and install version $($info.version)?`n`nYour current files are backed up first. Every file is checked against a SHA-256 hash before it is used." "Versie $($info.version) downloaden en installeren?`n`nJe huidige bestanden worden eerst geback-upt. Elk bestand wordt gecontroleerd met een SHA-256-hash voordat het wordt gebruikt."
    if ([Windows.MessageBox]::Show($msg, 'SharkOptimizer', 'YesNo', 'Question') -ne 'Yes') { return }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $staged = @()
        foreach ($f in @($info.files)) {
            $name = [string]$f.name; $url = [string]$f.url; $hash = ([string]$f.sha256).ToLower()
            if ($name -notmatch '^[A-Za-z0-9._-]+\.(ps1|cmd|json|txt)$') { throw "File name not allowed: $name" }
            if ($url -notmatch '^https://') { throw "Only https downloads are allowed: $name" }
            if ($hash -notmatch '^[0-9a-f]{64}$') { throw "No valid SHA-256 hash for $name" }
            $wc = New-Object Net.WebClient; $wc.Headers.Add('User-Agent', 'SharkOptimizer')
            $bytes = $wc.DownloadData($url)
            $txt = ([Text.Encoding]::UTF8.GetString($bytes)).TrimStart([char]0xFEFF) -replace "`r`n", "`n"
            $sha = [Security.Cryptography.SHA256]::Create()
            $got = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($txt)) | ForEach-Object { $_.ToString('x2') })
            if ($got -ne $hash) { throw "Hash check failed for $name. Nothing was changed." }
            $staged += @{ Name = $name; Bytes = $bytes }
        }
        $backup = Join-Path $PSScriptRoot ("backup-v$AppVer-" + (Get-Date -Format 'yyyyMMdd-HHmmss')); New-Item $backup -ItemType Directory -Force | Out-Null
        foreach ($s in $staged) {
            $dest = Join-Path $PSScriptRoot $s.Name
            if (Test-Path $dest) { Copy-Item $dest (Join-Path $backup $s.Name) -Force }
            [IO.File]::WriteAllBytes($dest, $s.Bytes)
        }
        Log "Updated to v$($info.version). Backup: $backup"
        [void][Windows.MessageBox]::Show((Tn "Updated to version $($info.version). Close and start SharkOptimizer again to use it." "Bijgewerkt naar versie $($info.version). Sluit SharkOptimizer en start het opnieuw om het te gebruiken."), 'SharkOptimizer')
    } catch { Log "Update failed: $($_.Exception.Message)"; [void][Windows.MessageBox]::Show("Update failed: $($_.Exception.Message)", 'SharkOptimizer', 'OK', 'Warning') }
}

# banner on the dashboard
try {
    $script:updBanner = New-Object Windows.Controls.Border; $script:updBanner.CornerRadius = 12; $script:updBanner.Padding = '14,10'; $script:updBanner.Margin = '0,0,0,10'
    $script:updBanner.Background = Brush '#10304A'; $script:updBanner.BorderBrush = Brush '#1FB6FF'; $script:updBanner.BorderThickness = 1; $script:updBanner.Visibility = 'Collapsed'
    $ub = New-Object Windows.Controls.DockPanel
    $bb = New-Object Windows.Controls.StackPanel; $bb.Orientation = 'Horizontal'; [Windows.Controls.DockPanel]::SetDock($bb, 'Right')
    $b1 = New-Object Windows.Controls.Button; $b1.Content = 'Download'; $b1.Padding = '12,6'; $b1.Add_Click({ if ($script:UpdInfo.url) { Start-Process ([string]$script:UpdInfo.url) } })
    $script:btnUpdInstall = New-Object Windows.Controls.Button; $script:btnUpdInstall.Content = 'Install now'; $script:btnUpdInstall.Padding = '12,6'; $script:btnUpdInstall.Background = Brush '#1FB6FF'; $script:btnUpdInstall.Foreground = Brush '#06121F'; $script:btnUpdInstall.Add_Click({ Install-Update })
    $b3 = New-Object Windows.Controls.Button; $b3.Content = 'Later'; $b3.Padding = '12,6'; $b3.Add_Click({ $script:updBanner.Visibility = 'Collapsed' })
    foreach ($x in $b1, $script:btnUpdInstall, $b3) { $bb.Children.Add($x) | Out-Null }
    $script:updBannerText = New-Text '' 13 '#FFFFFF' $true; $script:updBannerText.VerticalAlignment = 'Center'
    $ub.Children.Add($bb) | Out-Null; $ub.Children.Add($script:updBannerText) | Out-Null; $script:updBanner.Child = $ub
    $ui.pgDash.Content.Children.Insert(2, $script:updBanner)
} catch {}

# ---------------------------------------------------------------- settings page
$setScroll = New-Object Windows.Controls.ScrollViewer; $setScroll.VerticalScrollBarVisibility = 'Auto'; $setScroll.Visibility = 'Collapsed'
$setPanel = New-Object Windows.Controls.StackPanel; $setScroll.Content = $setPanel
$ui.pgDash.Parent.Children.Add($setScroll) | Out-Null
$ui['navSettings'] = (New-Object Windows.Controls.Button); $ui['pgSettings'] = $setScroll; $pages.Add('navSettings', 'pgSettings')
$swStyle = $null; try { if ($switchXaml) { $swStyle = [Windows.Markup.XamlReader]::Parse($switchXaml) } } catch {}

function New-SetBtn($text, [scriptblock]$click, $accent = $false) {
    $b = New-Object Windows.Controls.Button; $b.Content = $text; $b.Padding = '14,9'
    if ($accent) { $b.Background = Brush '#1FB6FF'; $b.Foreground = Brush '#06121F' }
    $b.Add_Click($click); $b
}
function Add-SetSection($title, $sub) {
    $setPanel.Children.Add((New-Text $title 17 '#FFFFFF' $true '4,24,0,2')) | Out-Null
    if ($sub) { $setPanel.Children.Add((New-Text $sub 12 '#7F8FAE' $false '4,0,0,8')) | Out-Null }
}
function Add-SetRow($items) { $wp = New-Object Windows.Controls.WrapPanel; $wp.Margin = '-4,0,0,0'; foreach ($i in $items) { $wp.Children.Add($i) | Out-Null }; $setPanel.Children.Add($wp) | Out-Null }
function Add-SetToggle($text, $key) {
    $cb = New-Object Windows.Controls.CheckBox; $cb.Content = $text; $cb.Tag = $key; $cb.Margin = '4,7'; $cb.IsChecked = [bool]$Settings[$key]
    if ($swStyle) { $cb.Style = $swStyle }
    $cb.Add_Click({ $Settings[[string]$this.Tag] = [bool]$this.IsChecked; Save-Settings; Apply-Settings })
    $setPanel.Children.Add($cb) | Out-Null
}
function Apply-Settings {
    try {
        $rg = $ui.pgDash.Parent.Parent; $last = $rg.RowDefinitions.Count - 1
        if ($Settings.ShowLog) { $rg.RowDefinitions[$last].Height = New-Object Windows.GridLength(64); $ui.txtLog.Visibility = 'Visible' }
        else { $rg.RowDefinitions[$last].Height = New-Object Windows.GridLength(0); $ui.txtLog.Visibility = 'Collapsed' }
    } catch {}
}
function Refresh-LangButtons {
    if (-not $script:btnEn) { return }
    $script:btnEn.Background = Brush $(if ($script:Lang -eq 'en') { '#1FB6FF' } else { '#16233A' }); $script:btnEn.Foreground = Brush $(if ($script:Lang -eq 'en') { '#06121F' } else { '#E8ECF4' })
    $script:btnNl.Background = Brush $(if ($script:Lang -eq 'nl') { '#1FB6FF' } else { '#16233A' }); $script:btnNl.Foreground = Brush $(if ($script:Lang -eq 'nl') { '#06121F' } else { '#E8ECF4' })
    if ($script:hdrLang) { $script:hdrLang.Content = $(if ($script:Lang -eq 'nl') { 'EN' } else { 'NL' }) }
}

$setPanel.Children.Add((New-Text 'Settings' 28 '#FFFFFF' $true)) | Out-Null
$setPanel.Children.Add((New-Text 'Language, updates and behaviour.' 12.5 '#7F8FAE')) | Out-Null
Add-SetSection 'Language' 'Choose the language of the app. It changes instantly.'
$script:btnEn = New-Object Windows.Controls.Button; $script:btnEn.Content = 'English'; $script:btnEn.Padding = '18,9'; $script:btnEn.Add_Click({ Set-Language 'en' })
$script:btnNl = New-Object Windows.Controls.Button; $script:btnNl.Content = 'Nederlands'; $script:btnNl.Padding = '18,9'; $script:btnNl.Add_Click({ Set-Language 'nl' })
Add-SetRow @($script:btnEn, $script:btnNl)

Add-SetSection 'Updates' $null
$script:txtVer = New-Text "SharkOptimizer v$AppVer" 13 '#C2CCDF' $false '4,0,0,6'; $setPanel.Children.Add($script:txtVer) | Out-Null
Add-SetToggle 'Check for updates when SharkOptimizer starts' 'AutoUpdate'
$setPanel.Children.Add((New-Text 'Update address (version.json)' 12 '#7F8FAE' $false '4,8,0,2')) | Out-Null
$script:txtUpdUrl = New-Object Windows.Controls.TextBox; $script:txtUpdUrl.Text = [string]$Settings.UpdateUrl; $script:txtUpdUrl.Width = 560; $script:txtUpdUrl.HorizontalAlignment = 'Left'; $script:txtUpdUrl.Margin = '4,0,0,6'
$setPanel.Children.Add($script:txtUpdUrl) | Out-Null
$script:btnSetOpen = New-SetBtn 'Open download page' { if ($script:UpdInfo.url) { Start-Process ([string]$script:UpdInfo.url) } }; $script:btnSetOpen.Visibility = 'Collapsed'
$script:btnSetInstall = New-SetBtn 'Install update' { Install-Update } $true; $script:btnSetInstall.Visibility = 'Collapsed'
Add-SetRow @((New-SetBtn 'Save' { $Settings.UpdateUrl = $script:txtUpdUrl.Text.Trim(); Save-Settings; Set-UpdStatus (Tn 'Saved.' 'Opgeslagen.') }), (New-SetBtn 'Check now' { $Settings.UpdateUrl = $script:txtUpdUrl.Text.Trim(); Save-Settings; Start-UpdateCheck $true } $true), $script:btnSetOpen, $script:btnSetInstall)
$script:txtUpdStatus = New-Text 'Not checked yet.' 12 '#1FB6FF' $false '4,6,0,0'; $setPanel.Children.Add($script:txtUpdStatus) | Out-Null

Add-SetSection 'Behaviour' $null
Add-SetToggle 'Show pop-up notifications' 'Toasts'
Add-SetToggle 'Show the activity log' 'ShowLog'
Add-SetToggle 'Scan for games when SharkOptimizer starts' 'ScanOnStart'

Add-SetSection 'Help and data' $null
Add-SetRow @(
    (New-SetBtn 'Show the guide again' { if (Has-Fn 'Show-Guide') { Show-Guide 0 } }),
    (New-SetBtn 'Open data folder' { Start-Process explorer.exe $DataDir }),
    (New-SetBtn 'Open log file' { if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } }),
    (New-SetBtn 'Clear saved game scan' {
        Remove-Item $GameCache -Force -ErrorAction SilentlyContinue
        foreach ($g in $Games) { $script:GamePaths[$g.Id] = @() }
        Render-GameList; if ($script:CurGame) { Show-Game $script:CurGame }; Log 'Saved game scan cleared.'
    }),
    (New-SetBtn 'Reset settings' {
        Remove-Item $SettingsFile -Force -ErrorAction SilentlyContinue
        $Settings.AutoUpdate = $true; $Settings.Toasts = $true; $Settings.ShowLog = $true; $Settings.ScanOnStart = $false; Apply-Settings
        Log 'Settings reset. Restart SharkOptimizer to refresh the switches.'
    })
)
Add-SetSection 'About' $null
$setPanel.Children.Add((New-Text "SharkOptimizer v$AppVer" 13 '#C2CCDF' $true '4,0,0,2')) | Out-Null
$setPanel.Children.Add((New-Text 'Made by Bas. Free to use. Every change can be undone.' 12 '#7F8FAE' $false '4,0,0,24')) | Out-Null

# ---------------------------------------------------------------- header buttons: settings + language
try {
    if ($script:hdrApply) {
        $bar = $script:hdrApply.Parent
        $helpBtn = $bar.Children | Where-Object { $_ -is [Windows.Controls.Button] -and $_.Content -eq [string][char]0xE897 } | Select-Object -First 1
        $at = if ($helpBtn) { $bar.Children.IndexOf($helpBtn) } else { $bar.Children.Count }
        $gear = New-Object Windows.Controls.Button; $gear.Content = [string][char]0xE713; $gear.FontFamily = 'Segoe MDL2 Assets'; $gear.FontSize = 11; $gear.Padding = '12,8'; $gear.Margin = '3,0'; $gear.Background = Brush '#0B1424'; $gear.VerticalAlignment = 'Center'
        $gear.Add_Click({ Show-Page 'navSettings' })
        $script:hdrLang = New-Object Windows.Controls.Button; $script:hdrLang.Content = 'NL'; $script:hdrLang.FontSize = 11.5; $script:hdrLang.Padding = '10,6'; $script:hdrLang.Margin = '3,0'; $script:hdrLang.VerticalAlignment = 'Center'
        $script:hdrLang.Add_Click({ Set-Language $(if ($script:Lang -eq 'nl') { 'en' } else { 'nl' }) })
        foreach ($hb in $gear, $script:hdrLang) { [System.Windows.Shell.WindowChrome]::SetIsHitTestVisibleInChrome($hb, $true) }
        $bar.Children.Insert($at, $gear); $bar.Children.Insert($at, $script:hdrLang)
    }
} catch {}

# ---------------------------------------------------------------- start-up
Apply-Settings
if ($Settings.Language -eq 'nl') { Set-Language 'nl' } else { $script:Lang = 'en'; Refresh-LangButtons }
if ($Settings.AutoUpdate) { Start-UpdateCheck $false }

# ---------------------------------------------------------------- start
Log "Loaded $($Tweaks.Count) tweaks and $($Games.Count) game profiles. Detected: $($Spec.Tier) PC, $($Spec.RamGB) GB RAM, $($Spec.GPU)."
Render-Tweaks
Render-GameList
Refresh-Startup
Refresh-Procs
Show-Page 'navDash'
$window.Add_ContentRendered({ try { Animate-In $window.Content 0 0 450 } catch {}; try { Refresh-Bloat } catch {} })
[void]$window.ShowDialog()
Save-State
