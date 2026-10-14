
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

# Write JSON beside the destination, then atomically replace it. A crash during
# serialization must not truncate the only copy of the undo history.
function Write-JsonAtomic([string]$Path, [object]$Value, [int]$Depth = 6) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $tempPath = Join-Path $directory ('.' + [IO.Path]::GetFileName($fullPath) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $json = ConvertTo-Json -InputObject $Value -Depth $Depth
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($tempPath, $json, $utf8)
    try {
        if (Test-Path -LiteralPath $fullPath) {
            [IO.File]::Copy($fullPath, ($fullPath + '.bak'), $true)
            [IO.File]::Replace($tempPath, $fullPath, $null)
        }
        else { [IO.File]::Move($tempPath, $fullPath) }
    } catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

$State = @{}
$script:StateLoadNotice = $null
if (Test-Path $StateFile) {
    try {
        $o = Get-Content $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $o -or $o -is [string] -or $o -is [System.Array]) { throw 'Saved change history is not a JSON object.' }
        foreach ($prop in $o.PSObject.Properties) { $State[$prop.Name] = @($prop.Value | Where-Object { $_ }) }
    } catch {
        $primaryError = $_.Exception.Message
        try {
            $backupFile = $StateFile + '.bak'
            if (-not (Test-Path -LiteralPath $backupFile)) { throw 'No saved backup was found.' }
            $o = Get-Content $backupFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $o -or $o -is [string] -or $o -is [System.Array]) { throw 'Saved backup is not a JSON object.' }
            foreach ($prop in $o.PSObject.Properties) { $State[$prop.Name] = @($prop.Value | Where-Object { $_ }) }
            $script:StateLoadNotice = 'The saved change history was damaged. SharkOptimizer recovered the previous copy; review Restore before making more changes.'
        } catch {
            $State.Clear()
            $script:StateLoadNotice = "The saved change history could not be read ($primaryError). No applied-change history was loaded; use Restore carefully."
        }
    }
}
function Save-State {
    try { Write-JsonAtomic $StateFile $State 6 }
    catch { if (Get-Command Log -ErrorAction SilentlyContinue) { Log "Could not save change history: $($_.Exception.Message)" } }
}

# ---------------------------------------------------------------- hardware detection
function Get-Specs {
    $cpu = $null; $cs = $null; $osInfo = $null
    $gpus = @(); $nics = @(); $laptop = $false
    try { $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 } catch {}
    try { $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop) } catch {}
    $gpu  = $gpus | Where-Object { $_.Name -match 'NVIDIA|Radeon|Arc' } | Select-Object -First 1
    if (-not $gpu) { $gpu = $gpus | Select-Object -First 1 }
    try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch {}
    $ram = if ($cs -and $cs.TotalPhysicalMemory) { [math]::Round($cs.TotalPhysicalMemory / 1GB) } else { 0 }
    try { $laptop = [bool](Get-CimInstance Win32_Battery -ErrorAction Stop) } catch {}
    if (-not $laptop) { try { $ct = (Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes; if ($ct | Where-Object { $_ -in 8,9,10,14,30,31 }) { $laptop = $true } } catch {} }
    $ssd = $false
    try { $ssd = [bool](Get-Partition -DriveLetter ([string]$env:SystemDrive[0]) | Get-Disk | Get-PhysicalDisk | Where-Object MediaType -eq 'SSD') } catch {}
    try { $nics = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Status -eq 'Up') } catch {}
    $wifi = [bool]($nics | Where-Object { $_.PhysicalMediaType -match '802.11' })
    $build = [Environment]::OSVersion.Version.Build
    $gname = if ($gpu) { [string]$gpu.Name } else { 'Unknown GPU' }
    try { $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch {}
    $cpuName = if ($cpu -and $cpu.Name) { ([string]$cpu.Name).Trim() } else { 'Unknown CPU' }
    $cores = if ($cpu) { [int]$cpu.NumberOfCores } else { 0 }
    $threads = if ($cpu) { [int]$cpu.NumberOfLogicalProcessors } else { 0 }
    $tier = if (-not $cpu -or -not $cs) { 'Unknown' } elseif ($ram -le 8 -or $threads -le 4) { 'Entry-level' } elseif ($ram -ge 32 -and $threads -ge 12) { 'High-end' } else { 'Mid-range' }
    if (-not $cpu -or -not $cs -or -not $osInfo) { $script:HardwareNotice = 'Some PC details could not be read. SharkOptimizer started with conservative hardware matching.' }
    [pscustomobject]@{
        CPU=$cpuName; Cores=$cores; Threads=$threads
        Intel=($cpuName -match 'Intel'); AMD=($cpuName -match 'AMD')
        GPU=$gname; Nvidia=($gname -match 'NVIDIA'); AmdGpu=($gname -match 'Radeon|AMD'); IntelGpu=($gname -match 'Intel'); GpuCount=$gpus.Count
        RamGB=$ram; Laptop=$laptop; SSD=$ssd; Wifi=$wifi; Nics=@($nics | ForEach-Object Name)
        Build=$build; Win11=($build -ge 22000)
        OS=$(if ($osInfo) { [string]$osInfo.Caption } else { 'Windows (details unavailable)' }); Tier=$tier
    }
}
$Spec = $null
$specCache = Join-Path $DataDir 'specs-cache.json'
try {
    if (Test-Path $specCache) {
        $sc = Get-Content $specCache -Raw | ConvertFrom-Json
        $specFields = 'CPU','GpuCount','RamGB','Build','OS','Tier'
        $missingSpecFields = @($specFields | Where-Object { -not $sc.Spec.PSObject.Properties[$_] })
        $validSpec = ($null -ne $sc.Spec) -and ($missingSpecFields.Count -eq 0)
        if ($validSpec -and (((Get-Date) - [datetime]$sc.Saved).TotalHours -lt 12) -and ([int]$sc.Build -eq [Environment]::OSVersion.Version.Build)) { $Spec = $sc.Spec }
    }
} catch {}
if (-not $Spec) {
    $Spec = Get-Specs
    try { Write-JsonAtomic -Path $specCache -Value @{ Saved = (Get-Date).ToString('s'); Build = [int]$Spec.Build; Spec = $Spec } -Depth 4 } catch {}
}
if (($Spec.Tier -eq 'Unknown' -or [string]$Spec.OS -like '*details unavailable*') -and -not $script:HardwareNotice) { $script:HardwareNotice = 'Some PC details could not be read. SharkOptimizer started with conservative hardware matching.' }

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
function Test-Applicable($t) {
    if ($script:HardwareNotice -and $t.Req) { return $false }
    if ($t.Req) { [bool](& $t.Req) } else { $true }
}
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
    <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="#1E2E4B" BorderThickness="1" CornerRadius="12" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
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
     <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#5BE3FF"/><Setter TargetName="bd" Property="BorderThickness" Value="1"/></Trigger>
     <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.4"/></Trigger>
    </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style x:Key="NavBtn" TargetType="Button"><Setter Property="Foreground" Value="#C2CCDF"/><Setter Property="Background" Value="#0B1424"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Tag" Value=""/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
     <Grid>
     <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="12" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/></Border>
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
  <Style TargetType="TextBox"><Setter Property="Background" Value="#0F1A2C"/><Setter Property="Foreground" Value="#E8ECF4"/><Setter Property="BorderBrush" Value="#1E2E4B"/><Setter Property="CaretBrush" Value="White"/><Setter Property="Padding" Value="10,7"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox"><Border x:Name="tb" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="9"><ScrollViewer x:Name="PART_ContentHost" Margin="1"/></Border><ControlTemplate.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="tb" Property="BorderBrush" Value="#5BE3FF"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="tb" Property="Opacity" Value="0.5"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
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
      <TextBlock x:Name="txtDashTitle" Text="Welcome to SharkOptimizer" Foreground="White" FontSize="30" FontWeight="Bold"/>
      <TextBlock x:Name="txtTier" Foreground="#7F8FAE" Margin="0,2,0,14"/>
      <UniformGrid Columns="3" Margin="-6,0">
       <Border Margin="6" Padding="18" CornerRadius="14" Background="#0F1A2C" BorderBrush="#1A2943" BorderThickness="1"><StackPanel><TextBlock Text="CPU USAGE" Foreground="#7F8FAE" FontSize="11" FontWeight="SemiBold"/><TextBlock x:Name="txtCpu" Text="0%" Foreground="White" FontSize="34" FontWeight="Bold" Margin="0,2,0,8"/><ProgressBar x:Name="barCpu" Foreground="#35D07F"/></StackPanel></Border> <Border Margin="6" Padding="18" CornerRadius="14" Background="#0F1A2C" BorderBrush="#1A2943" BorderThickness="1"><StackPanel><TextBlock Text="GPU 3D USAGE" Foreground="#7F8FAE" FontSize="11" FontWeight="SemiBold"/><TextBlock x:Name="txtGpu" Text="0%" Foreground="White" FontSize="34" FontWeight="Bold" Margin="0,2,0,8"/><ProgressBar x:Name="barGpu" Foreground="#1FB6FF"/></StackPanel></Border> <Border Margin="6" Padding="18" CornerRadius="14" Background="#0F1A2C" BorderBrush="#1A2943" BorderThickness="1"><StackPanel><TextBlock Text="RAM USAGE" Foreground="#7F8FAE" FontSize="11" FontWeight="SemiBold"/><TextBlock x:Name="txtRam" Text="0%" Foreground="White" FontSize="34" FontWeight="Bold" Margin="0,2,0,8"/><ProgressBar x:Name="barRam" Foreground="#FFC857"/></StackPanel></Border>
      </UniformGrid>
      <UniformGrid Columns="4" Margin="-6,0">
       <Border Margin="6" Padding="16" CornerRadius="14" Background="#0F1A2C" BorderBrush="#1A2943" BorderThickness="1"><StackPanel><TextBlock x:Name="txtActive" Text="0" Foreground="#35D07F" FontSize="26" FontWeight="Bold"/><TextBlock Text="Optimizations active" Foreground="#7F8FAE" FontSize="12"/></StackPanel></Border> <Border Margin="6" Padding="16" CornerRadius="14" Background="#0F1A2C" BorderBrush="#1A2943" BorderThickness="1"><StackPanel><TextBlock x:Name="txtRecCnt" Text="0" Foreground="#FFC857" FontSize="26" FontWeight="Bold"/><TextBlock Text="Recommended pending" Foreground="#7F8FAE" FontSize="12"/></StackPanel></Border> <Border Margin="6" Padding="16" CornerRadius="14" Background="#0F1A2C" BorderBrush="#1A2943" BorderThickness="1"><StackPanel><TextBlock x:Name="txtTotal" Text="0" Foreground="#FFFFFF" FontSize="26" FontWeight="Bold"/><TextBlock Text="Tweaks available" Foreground="#7F8FAE" FontSize="12"/></StackPanel></Border>
       <Border Margin="6" Padding="16" CornerRadius="14" Background="#0F1A2C" BorderBrush="#1A2943" BorderThickness="1"><StackPanel><TextBlock x:Name="txtScore" Text="0%" Foreground="#1FB6FF" FontSize="26" FontWeight="Bold"/><TextBlock Text="Recommended tweaks applied" Foreground="#7F8FAE" FontSize="12" Margin="0,0,0,6"/><ProgressBar x:Name="barScore" Foreground="#1FB6FF"/></StackPanel></Border>
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
      <TextBlock x:Name="txtTweaksTitle" Text="Tweaks" Foreground="White" FontSize="28" FontWeight="Bold" DockPanel.Dock="Left"/>
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
      <TextBlock x:Name="txtGamesTitle" Text="Games" Foreground="White" FontSize="28" FontWeight="Bold"/>
      <DockPanel Margin="0,2,0,10"><Button x:Name="btnScan" Content="Scan for Games" DockPanel.Dock="Left" Margin="0,4,8,4"/><TextBlock x:Name="txtScan" Foreground="#7F8FAE" VerticalAlignment="Center" Text="Pick a game for a tuned profile. Scan to detect your installs."/></DockPanel>
     </StackPanel>
     <Grid Grid.Row="1"><Grid.ColumnDefinitions><ColumnDefinition Width="260"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="gameList"/></ScrollViewer>
      <ScrollViewer Grid.Column="1" Margin="16,0,0,0" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="gameDetail"/></ScrollViewer>
     </Grid>
    </Grid>

    <ScrollViewer x:Name="pgWin" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
     <StackPanel>
      <TextBlock x:Name="txtWinTitle" Text="Windows" Foreground="White" FontSize="28" FontWeight="Bold"/>
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
      <TextBlock x:Name="txtBoostTitle" Text="Boost-Up" Foreground="White" FontSize="28" FontWeight="Bold"/>
      <TextBlock Text="Routine cleanups. Run monthly or when your PC feels slow." Foreground="#7F8FAE" Margin="0,0,0,14"/>
      <ScrollViewer MaxHeight="520" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="lstBoost"/></ScrollViewer>
      <Button x:Name="btnBoostAll" Content="Run All" Background="#1FB6FF" Foreground="#06121F" HorizontalAlignment="Left" Margin="0,10"/>
     </StackPanel>
    </Grid>

    <Grid x:Name="pgNet" Visibility="Collapsed">
     <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
     <StackPanel>
      <TextBlock x:Name="txtNetTitle" Text="Network &amp; Ping" Foreground="White" FontSize="28" FontWeight="Bold"/>
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
      <TextBlock x:Name="txtRestoreTitle" Text="Restore" Foreground="White" FontSize="28" FontWeight="Bold"/>
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
foreach ($nm in 'navDash','navTweaks','navGames','navWin','navBoost','navNet','navRestore','txtSide','pgDash','pgTweaks','pgGames','pgWin','pgBoost','pgNet','pgRestore','txtDashTitle','txtTweaksTitle','txtGamesTitle','txtWinTitle','txtBoostTitle','txtNetTitle','txtRestoreTitle','txtTier','txtCpu','barCpu','txtGpu','barGpu','txtRam','barRam','txtActive','txtRecCnt','txtTotal','txtScore','barScore','pnlPresets','txtSpecs','btnDashApply','btnDashRP','chkRec','txtSearch','chips','wrap','txtSel','btnSelRec','btnSelAll','btnClear','btnUndo','btnApply','btnScan','txtScan','gameList','gameDetail','pnlTools','lstStartup','btnStartRef','lstBloat','btnBloatRef','btnBloat','lstProc','btnProcRef','btnProcClose','lstBoost','btnBoostAll','btnPing','txtHost','btnHost','btnDns','btnBestDns','btnFlush','txtNet','btnRP','btnUndoAll','btnLog','txtApplied','txtLog') {
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
if ($script:StateLoadNotice) { Log $script:StateLoadNotice }
if ($script:HardwareNotice) { Log $script:HardwareNotice }
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
$ui.txtTier.Text = if ($script:HardwareNotice) { 'PC details unavailable - hardware-matched tweaks are disabled for safety.' } else { "$($Spec.Tier) PC  -  tweaks matched to your hardware" }
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
    $visibleTweaks = @(Get-Visible)
    if (-not $visibleTweaks.Count) {
        $empty = New-Object Windows.Controls.Border; $empty.Width = 600; $empty.Padding = '22'; $empty.Margin = '4,12'; $empty.CornerRadius = 12
        $empty.Background = Brush '#0F1A2C'; $empty.BorderBrush = Brush '#1A2943'; $empty.BorderThickness = 1
        $message = switch ($script:Lang) {
            'nl' { 'Geen tweaks gevonden. Wis de zoekopdracht of kies een andere categorie.' }
            'es' { 'No hay ajustes que coincidan. Borra la búsqueda o elige otra categoría.' }
            'de' { 'Keine passenden Tweaks gefunden. Suche löschen oder eine andere Kategorie wählen.' }
            'fr' { 'Aucun réglage correspondant. Effacez la recherche ou choisissez une autre catégorie.' }
            'pt' { 'Nenhum ajuste encontrado. Limpe a pesquisa ou escolha outra categoria.' }
            'ru' { 'Подходящие настройки не найдены. Очистите поиск или выберите другую категорию.' }
            'zh' { '没有符合条件的调整。请清除搜索或选择其他类别。' }
            default { 'No tweaks match these filters. Clear the search or choose another category.' }
        }
        $empty.Child = (New-Text $message 13 '#7F8FAE')
        $ui.wrap.Children.Add($empty) | Out-Null
    }
    foreach ($tw in $visibleTweaks) { $cd = New-Card $tw; $ui.wrap.Children.Add($cd) | Out-Null; $tgt = $(if (Test-Applicable $tw) { 1 } else { 0.5 }); Animate-In $cd ([math]::Min($script:cardIdx * 16, 360)) 10 240 $tgt; $script:cardIdx++ }
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
    $review = @($list | ForEach-Object {
        $riskLabel = if ($_.Risk) { $_.Risk.ToUpper() } else { 'SAFE' }
        $line = "[$riskLabel] $($_.Name) — $($_.Desc)"
        if ($_.Warn) { $line += "`n   Caution: $($_.Warn)" }
        if ($_.Reboot) { $line += "`n   A restart is required." }
        $line
    })
    $warning = if ($risky.Count) { 'Some selected changes affect Windows behavior. Review their warnings below. A restore point will be attempted before changes are applied.' } else { 'Review the selected changes. You can undo tracked changes later from Restore.' }
    if (-not (Show-ActionPreview 'Review changes' ("$($list.Count) changes are ready to apply.") $review $warning 'Apply selected')) { return $false }
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
function Invoke-Undo($list, [bool]$skipReview = $false) {
    $list = @($list | Where-Object { $_ -and $State.ContainsKey($_.Id) })
    if (-not $list.Count) { return }
    if (-not $skipReview) {
        $review = @($list | ForEach-Object { "Undo: $($_.Name)" })
        if (-not (Show-ActionPreview 'Review undo' ("$($list.Count) tracked changes will be restored to their saved values.") $review 'Only changes with saved originals are reverted.' 'Undo selected')) { return }
    }
    foreach ($tw in $list) {
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
    $activeTweaks = @($Tweaks | Where-Object { $State.ContainsKey($_.Id) })
    $activeGames = @($State.Keys | Where-Object { $_ -like 'game_*' })
    $review = @($activeTweaks | ForEach-Object { "Tweak: $($_.Name)" }) + @($activeGames | ForEach-Object { "Game profile: $($_ -replace '^game_', '')" })
    if ($review.Count -and (Show-ActionPreview 'Review full restore' ("$($review.Count) applied items will be reverted to their saved values.") $review 'Undo only uses the originals SharkOptimizer recorded.' 'Undo all')) {
        Invoke-Undo $activeTweaks $true
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
$timer = New-Object Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({
    try {
        if ($ui.pgDash.Visibility -ne 'Visible') { return }
        $script:tick++
        if ($script:cpuC) { $cv = [math]::Round($script:cpuC.NextValue()); $ui.txtCpu.Text = "$cv%"; Set-Bar $ui.barCpu $cv }
        $rv = [math]::Round(100 * (1 - $ci.AvailablePhysicalMemory / $ci.TotalPhysicalMemory)); $ui.txtRam.Text = "$rv%"; Set-Bar $ui.barRam $rv
        $gv = 0; foreach ($pc in $script:gpuC) { try { $gv += $pc.NextValue() } catch {} }
        $gv = [math]::Min(100, [math]::Round($gv)); $ui.txtGpu.Text = "$gv%"; Set-Bar $ui.barGpu $gv
        if ($script:tick -eq 1 -or $script:tick % 15 -eq 0) { Refresh-GpuCounters }
    } catch {}
})
$timer.Start()


# ================================================================ SharkOptimizer Lab (added module)
$AppVersion = '2.0.2'
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
    Write-JsonAtomic -Path $BenchFile -Value $store -Depth 4
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
        [void]$pts.Add(([Windows.Point]::new(($startI + $i) * $stepX, $y)))
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
Refresh-GmProcs; Refresh-GmGames


# ================================================================ SharkOptimizer Pro UI (added module)
$ProVersion = '2.0.2'
function Has-Fn($n) { [bool](Get-Command $n -CommandType Function -ErrorAction SilentlyContinue) }
function Step($name, [scriptblock]$body) { try { & $body } catch { Log "UI step '$name' failed: $($_.Exception.Message)" } }
try { $window.Title = "SharkOptimizer v$ProVersion" } catch {}
$script:CurNav = 'navDash'
$script:QuickMode = $false
$script:LastRP = [datetime]::MinValue

# ---------------------------------------------------------------- 1. custom font (Poppins is bundled; startup works offline)
Step 'font' {
    $fontDir = Join-Path $PSScriptRoot 'fonts'
    $files = @('Poppins-Regular.ttf','Poppins-Bold.ttf')
    $ok = $true; foreach ($fn in $files) { $p = Join-Path $fontDir $fn; if (-not ((Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).Length -gt 50000)) { $ok = $false } }
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
$AppVer = '2.0.2'
try { $window.Title = "SharkOptimizer v$AppVer" } catch {}
function Has-Fn($n) { [bool](Get-Command $n -CommandType Function -ErrorAction SilentlyContinue) }
function Tn($en, $nl) { if ($script:Lang -eq 'nl') { $nl } else { $en } }

# ---------------------------------------------------------------- settings
$SettingsFile = Join-Path $DataDir 'settings.json'
$Settings = @{ Language = 'en'; AutoUpdate = $true; Toasts = $true; ShowLog = $true; ScanOnStart = $false
               UpdateUrl = 'https://raw.githubusercontent.com/Bas-Makes-Stuff/SharkOptimizer/main/version.json' }
try { if ((Get-UICulture).TwoLetterISOLanguageName -eq 'nl') { $Settings.Language = 'nl' } } catch {}
if (Test-Path $SettingsFile) {
    try {
        $so = Get-Content $SettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $so -or $so -is [string] -or $so -is [System.Array]) { throw 'Saved settings are not a JSON object.' }
        foreach ($spx in $so.PSObject.Properties) { $Settings[$spx.Name] = $spx.Value }
    }
    catch {
        try {
            $settingsBackup = $SettingsFile + '.bak'
            if (-not (Test-Path -LiteralPath $settingsBackup)) { throw 'No saved settings backup was found.' }
            $so = Get-Content $settingsBackup -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $so -or $so -is [string] -or $so -is [System.Array]) { throw 'Settings backup is not a JSON object.' }
            foreach ($spx in $so.PSObject.Properties) { $Settings[$spx.Name] = $spx.Value }
        }
        catch { $script:SettingsLoadNotice = 'Saved settings could not be read. SharkOptimizer started with default settings.' }
    }
}
function Save-Settings {
    try { Write-JsonAtomic $SettingsFile $Settings 6 }
    catch { if (Get-Command Log -ErrorAction SilentlyContinue) { Log "Could not save settings: $($_.Exception.Message)" } }
}
if ($script:SettingsLoadNotice) { Log $script:SettingsLoadNotice }
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
        Write-JsonAtomic -Path $GameCache -Value $out -Depth 4
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
Recommended tweaks applied => Aanbevolen tweaks toegepast
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


# ================================================================ SharkOptimizer Updater removed (added module)
try { $Settings.AutoUpdate = $false; Save-Settings } catch {}
foreach ($tn in 'UpdTimer', 'GhTimer') { try { (Get-Variable -Scope Script -Name $tn -ValueOnly -ErrorAction Stop).Stop() } catch {} }
function Start-UpdateCheck($manual = $false) { }
function Show-UpdateBanner { }
function Install-Update { }
try { $script:updBanner.Visibility = 'Collapsed' } catch {}
try {
    $kids = @($setPanel.Children)
    $start = -1; $end = -1
    for ($i = 0; $i -lt $kids.Count; $i++) {
        $k = $kids[$i]
        if ($k -is [Windows.Controls.TextBlock]) {
            if ($start -lt 0 -and $k.Text -eq 'Updates') { $start = $i }
            elseif ($start -ge 0 -and ($k.Text -eq 'Behaviour' -or $k.Text -eq 'Gedrag')) { $end = $i; break }
        }
    }
    if ($start -ge 0 -and $end -gt $start) { for ($i = $start; $i -lt $end; $i++) { $kids[$i].Visibility = 'Collapsed' } }
} catch {}


# ================================================================ SharkOptimizer Extras (added module): accent colours, weekly cleanup, Add Game, My Presets, system report
if (-not (Get-Command Step -CommandType Function -ErrorAction SilentlyContinue)) { function Step($name, [scriptblock]$body) { try { & $body } catch { Log "UI step '$name' failed: $($_.Exception.Message)" } } }

$extraNl = @{
    'Appearance' = 'Uiterlijk'; 'Choose the highlight colour of the app.' = 'Kies de accentkleur van de app.'
    'Blue' = 'Blauw'; 'Green' = 'Groen'; 'Purple' = 'Paars'; 'Orange' = 'Oranje'
    'Scheduled cleanup' = 'Geplande opruiming'
    'Cleans temp files, crash dumps and error reports once a week with Windows Task Scheduler. It never touches your documents or the Recycle Bin.' = 'Ruimt eenmaal per week tijdelijke bestanden, crashdumps en foutrapporten op met Windows Taakplanner. Het raakt je documenten of de Prullenbak nooit aan.'
    'Enable weekly cleanup' = 'Wekelijkse opruiming aanzetten'; 'Disable weekly cleanup' = 'Wekelijkse opruiming uitzetten'; 'Run it now' = 'Nu uitvoeren'
    'Monday' = 'Maandag'; 'Tuesday' = 'Dinsdag'; 'Wednesday' = 'Woensdag'; 'Thursday' = 'Donderdag'; 'Friday' = 'Vrijdag'; 'Saturday' = 'Zaterdag'; 'Sunday' = 'Zondag'
    'Add Game' = 'Game toevoegen'; 'Remove from list' = 'Uit lijst verwijderen'
    'My Presets' = 'Mijn voorinstellingen'; 'Save current selection' = 'Huidige selectie opslaan'; 'Import code' = 'Code importeren'
    'Use' = 'Gebruiken'; 'Copy code' = 'Code kopiëren'; 'Delete' = 'Verwijderen'; 'No presets yet.' = 'Nog geen voorinstellingen.'
    'Copy System Report' = 'Systeemrapport kopiëren'; 'OK' = 'OK'; 'Cancel' = 'Annuleren'
}
if ($NL) { foreach ($k in $extraNl.Keys) { $NL[$k] = $extraNl[$k] } }
function Tr($el) { if (Has-Fn 'Translate-Now') { Translate-Now $el } }
function Say($text) { if (Has-Fn 'Show-Toast') { Show-Toast $text } ; Log $text }

# ---------------------------------------------------------------- 1. accent colours
$AccentSets = [ordered]@{ 'blue' = '#1FB6FF'; 'green' = '#22D3A6'; 'purple' = '#A78BFA'; 'orange' = '#FF9F1A' }
$script:AccBase = @('#1FB6FF', '#10304A', '#0F2E45')
$script:AccCur  = @('#1FB6FF', '#10304A', '#0F2E45')
function Mix-Hex($a, $b, $t) {
    $ca = [Windows.Media.ColorConverter]::ConvertFromString($a); $cb = [Windows.Media.ColorConverter]::ConvertFromString($b)
    $r = [int]($ca.R * $t + $cb.R * (1 - $t)); $g = [int]($ca.G * $t + $cb.G * (1 - $t)); $bl = [int]($ca.B * $t + $cb.B * (1 - $t))
    '#{0:X2}{1:X2}{2:X2}' -f $r, $g, $bl
}
function Get-AccentTriple($name) {
    if ($name -eq 'blue') { return @('#1FB6FF', '#10304A', '#0F2E45') }
    $a = $AccentSets[$name]; @($a, (Mix-Hex $a '#0B1424' 0.20), (Mix-Hex $a '#0F1A2C' 0.22))
}
function Brush($hex) {
    $h = [string]$hex
    for ($i = 0; $i -lt 3; $i++) { if ($h -ieq $script:AccBase[$i]) { $h = $script:AccCur[$i]; break } }
    [Windows.Media.BrushConverter]::new().ConvertFromString($h)
}
function Remap-Brush($b, $from, $to) {
    if ($b -is [Windows.Media.SolidColorBrush]) {
        $c = $b.Color; $hex = '#{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B
        for ($i = 0; $i -lt 3; $i++) { if ($hex -ieq $from[$i]) { return [Windows.Media.BrushConverter]::new().ConvertFromString($to[$i]) } }
    }
    $null
}
function Recolor-El($el, $from, $to) {
    foreach ($pn in 'Background', 'Foreground', 'BorderBrush', 'Fill', 'Stroke') {
        try {
            $prop = $el.GetType().GetProperty($pn)
            if ($prop -and $prop.CanWrite) { $nb = Remap-Brush ($prop.GetValue($el)) $from $to; if ($nb) { $prop.SetValue($el, $nb) } }
        } catch {}
    }
}
function Walk-Recolor($o, $from, $to) {
    if ($null -eq $o) { return }
    Recolor-El $o $from $to
    try { foreach ($c in @([Windows.LogicalTreeHelper]::GetChildren($o))) { if ($c -is [Windows.DependencyObject]) { Walk-Recolor $c $from $to } } } catch {}
}
function Refresh-AccentButtons {
    foreach ($b in @($script:accButtons)) { $b.Opacity = $(if ($b.Tag -eq $Settings.Accent) { 1 } else { 0.5 }) }
}
function Set-Accent($name) {
    if (-not $AccentSets.Contains($name)) { $name = 'blue' }
    $to = Get-AccentTriple $name; $from = $script:AccCur
    if (($from -join ',') -ne ($to -join ',')) { Walk-Recolor $window $from $to }
    $script:AccCur = $to
    $Settings.Accent = $name; Save-Settings
    foreach ($k in @($pages.Keys)) {
        try { $nb = $ui[$k]; $ind = $nb.Template.FindName('ind', $nb); if ($ind) { $ind.Background = Brush '#1FB6FF' } } catch {}
    }
    try {
        if ($switchXaml) {
            $nsw = [Windows.Markup.XamlReader]::Parse(($switchXaml -replace '#1FB6FF', $to[0]))
            foreach ($x in @($setPanel.Children)) { if ($x -is [Windows.Controls.CheckBox]) { $x.Style = $nsw } }
        }
    } catch {}
    try { Refresh-AccentButtons } catch {}
}

function Insert-SettingsBefore($texts, $elements) {
    $idx = -1; $kids = @($setPanel.Children)
    for ($i = 0; $i -lt $kids.Count; $i++) { if ($kids[$i] -is [Windows.Controls.TextBlock] -and $texts -contains $kids[$i].Text) { $idx = $i; break } }
    if ($idx -lt 0) { $idx = $setPanel.Children.Count }
    foreach ($e in $elements) { $setPanel.Children.Insert($idx, $e); $idx++ }
}

Step 'accent-ui' {
    $title = New-Text 'Appearance' 17 '#FFFFFF' $true '4,24,0,2'
    $sub = New-Text 'Choose the highlight colour of the app.' 12 '#7F8FAE' $false '4,0,0,8'
    $row = New-Object Windows.Controls.WrapPanel; $row.Margin = '-4,0,0,0'
    $script:accButtons = @()
    $swatch = @{ 'blue' = '#1FB6FE'; 'green' = '#22D3A7'; 'purple' = '#A78BFB'; 'orange' = '#FF9F1B' }
    foreach ($nm in @($AccentSets.Keys)) {
        $b = New-Object Windows.Controls.Button; $b.Content = (Get-Culture).TextInfo.ToTitleCase($nm); $b.Tag = $nm; $b.Padding = '18,9'
        $b.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($swatch[$nm]); $b.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#06121F')
        $b.Add_Click({ Set-Accent $this.Tag })
        $row.Children.Add($b) | Out-Null; $script:accButtons += $b
    }
    Insert-SettingsBefore @('Behaviour', 'Gedrag') @($title, $sub, $row)
}

# ---------------------------------------------------------------- 2. weekly cleanup (Task Scheduler)
$TaskName = 'SharkOptimizer Weekly Cleanup'
$CleanupFile = Join-Path $DataDir 'weekly-cleanup.ps1'
$cleanupText = @'
$ErrorActionPreference = 'SilentlyContinue'
$log = Join-Path $env:ProgramData 'SharkOptimizer\scheduled-cleanup.log'
function Clean-Folder($path, $days) {
    $freed = 0; $limit = (Get-Date).AddDays(-$days)
    Get-ChildItem -LiteralPath $path -Force -Recurse -File | Where-Object { $_.LastWriteTime -lt $limit } | ForEach-Object {
        $len = $_.Length
        try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $freed += $len } catch {}
    }
    $freed
}
$total = 0
foreach ($p in @($env:TEMP, 'C:\Windows\Temp', "$env:LOCALAPPDATA\CrashDumps", 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive', 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue')) {
    if (Test-Path -LiteralPath $p) { $total += Clean-Folder $p 2 }
}
ipconfig /flushdns | Out-Null
Add-Content $log ("{0}  freed {1:N0} MB" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), ($total / 1MB))
'@
function Get-CleanupTask { try { Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch { $null } }
function Refresh-CleanupStatus {
    if (-not $script:txtCleanStatus) { return }
    $t = Get-CleanupTask
    if ($t) {
        $next = '-'
        try { $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop; if ($info.NextRunTime -gt [datetime]'2000-01-01') { $next = $info.NextRunTime.ToString('ddd dd MMM HH:mm') } } catch {}
        $script:txtCleanStatus.Text = (Tn 'Weekly cleanup is ON. Next run: ' 'Wekelijkse opruiming staat AAN. Volgende keer: ') + $next
    } else { $script:txtCleanStatus.Text = Tn 'Weekly cleanup is off.' 'Wekelijkse opruiming staat uit.' }
}
function Enable-WeeklyCleanup($day, $time) {
    if ($time -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { throw (Tn 'Enter the time like 20:00.' 'Vul de tijd in zoals 20:00.') }
    [IO.File]::WriteAllText($CleanupFile, $cleanupText, (New-Object Text.UTF8Encoding $true))
    $at = [datetime]::ParseExact($time, [string[]]@('H:mm', 'HH:mm'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$CleanupFile`""
    $trg = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At $at
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    $pr = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Settings $set -Principal $pr -Description 'SharkOptimizer weekly cleanup' -Force | Out-Null
}
Step 'cleanup-ui' {
    $title = New-Text 'Scheduled cleanup' 17 '#FFFFFF' $true '4,24,0,2'
    $sub = New-Text 'Cleans temp files, crash dumps and error reports once a week with Windows Task Scheduler. It never touches your documents or the Recycle Bin.' 12 '#7F8FAE' $false '4,0,0,8'
    $script:txtCleanStatus = New-Text '' 12 '#1FB6FF' $false '4,0,0,6'
    $row = New-Object Windows.Controls.WrapPanel; $row.Margin = '-4,0,0,0'
    $script:cmbCleanDay = New-Object Windows.Controls.ComboBox; $script:cmbCleanDay.Width = 130; $script:cmbCleanDay.Margin = '4'; $script:cmbCleanDay.VerticalAlignment = 'Center'
    foreach ($d in 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday') { $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = $d; $it.Tag = $d; [void]$script:cmbCleanDay.Items.Add($it) }
    $dayIdx = 6; $i = 0; foreach ($d in 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday') { if ($Settings.CleanDay -eq $d) { $dayIdx = $i }; $i++ }
    $script:cmbCleanDay.SelectedIndex = $dayIdx
    $script:txtCleanTime = New-Object Windows.Controls.TextBox; $script:txtCleanTime.Width = 70; $script:txtCleanTime.Margin = '4'; $script:txtCleanTime.VerticalAlignment = 'Center'
    $script:txtCleanTime.Text = $(if ($Settings.CleanTime) { [string]$Settings.CleanTime } else { '20:00' })
    $row.Children.Add($script:cmbCleanDay) | Out-Null; $row.Children.Add($script:txtCleanTime) | Out-Null
    $row.Children.Add((New-SetBtn 'Enable weekly cleanup' {
        try {
            $day = [string]$script:cmbCleanDay.SelectedItem.Tag; $tm = $script:txtCleanTime.Text.Trim()
            Enable-WeeklyCleanup $day $tm
            $Settings.CleanDay = $day; $Settings.CleanTime = $tm; Save-Settings
            Say (Tn 'Weekly cleanup scheduled.' 'Wekelijkse opruiming ingepland.')
        } catch { Log "Schedule failed: $($_.Exception.Message)"; [void][Windows.MessageBox]::Show($_.Exception.Message, 'SharkOptimizer', 'OK', 'Warning') }
        Refresh-CleanupStatus
    } $true)) | Out-Null
    $row.Children.Add((New-SetBtn 'Disable weekly cleanup' {
        try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; Say (Tn 'Weekly cleanup turned off.' 'Wekelijkse opruiming uitgezet.') } catch { Log "Could not remove the task: $($_.Exception.Message)" }
        Refresh-CleanupStatus
    })) | Out-Null
    $row.Children.Add((New-SetBtn 'Run it now' {
        if (Get-CleanupTask) { try { Start-ScheduledTask -TaskName $TaskName; Say (Tn 'Cleanup started.' 'Opruiming gestart.') } catch { Log "Could not start the task: $($_.Exception.Message)" } }
        else { Say (Tn 'Turn the weekly cleanup on first.' 'Zet eerst de wekelijkse opruiming aan.') }
    })) | Out-Null
    Insert-SettingsBefore @('Behaviour', 'Gedrag') @($title, $sub, $script:txtCleanStatus, $row)
    Refresh-CleanupStatus
}

# ---------------------------------------------------------------- 3. Add Game button
$AddedGamesFile = Join-Path $DataDir 'added-games.json'
$StdGameTweaks = @('f_gamemode', 'f_dvr', 'f_overlay', 'f_throttle', 'f_prio', 'f_mmcss', 'f_mouse', 'f_usb', 'n_nagle', 'n_throttle', 'n_dns')
function Save-AddedGames {
    try {
        $list = @($Games | Where-Object { $_.Id -like 'custom_*' } | ForEach-Object { @{ id = $_.Id; name = $_.Name; exe = [string]$_.Exes[0]; path = [string](@($script:GamePaths[$_.Id])[0]); ac = [string]$_.AC } })
        ConvertTo-Json -InputObject $list | Set-Content $AddedGamesFile -Encoding UTF8
    } catch {}
}
function Register-CustomGame($path, $name, $ac) {
    $id = 'custom_' + (($name.ToLower()) -replace '[^a-z0-9]', '')
    if ($id -eq 'custom_') { $id = 'custom_' + [guid]::NewGuid().ToString('N').Substring(0, 6) }
    $exe = [IO.Path]::GetFileName($path)
    $existing = $Games | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if (-not $existing) {
        $tip = 'Custom game. SharkOptimizer applies safe Windows tweaks and a GPU preference. In-game settings are up to you.'
        $g = @{ Id = $id; Name = $name; Exes = @($exe); AC = $ac; Tweaks = $StdGameTweaks; Tips = @($tip); Launch = ''; LaunchWhere = '' }
        $script:Games = @($Games) + $g
        if ($script:TipsEn) { $script:TipsEn[$id] = @($tip); $script:LwEn[$id] = '' }
        if ($TipsNl) { $TipsNl[$id] = @('Eigen game. SharkOptimizer past veilige Windows-tweaks en een GPU-voorkeur toe. De instellingen in de game zelf bepaal je zelf.') }
    }
    $script:GamePaths[$id] = @($path)
    $id
}
function Add-GameFromDialog {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog; $dlg.Filter = 'Programs (*.exe)|*.exe'; $dlg.Title = Tn 'Choose the game program (.exe)' 'Kies het gameprogramma (.exe)'
    if ($dlg.ShowDialog() -ne $true) { return }
    $path = $dlg.FileName
    $name = [IO.Path]::GetFileNameWithoutExtension($path)
    try { $pn = [Diagnostics.FileVersionInfo]::GetVersionInfo($path).ProductName; if ($pn -and $pn.Trim().Length -gt 1) { $name = $pn.Trim() } } catch {}
    $q = Tn "Does '$name' use anti-cheat (for example EasyAntiCheat, Vanguard or BattlEye)?`n`nChoose Yes if you are not sure. SharkOptimizer then only changes Windows settings and never sets process priority." "Gebruikt '$name' anti-cheat (bijvoorbeeld EasyAntiCheat, Vanguard of BattlEye)?`n`nKies Ja als je het niet zeker weet. SharkOptimizer wijzigt dan alleen Windows-instellingen en zet nooit de procesprioriteit."
    $ac = if ([Windows.MessageBox]::Show($q, 'SharkOptimizer', 'YesNo', 'Question') -eq 'Yes') { 'set by you' } else { '' }
    $id = Register-CustomGame $path $name $ac
    Save-AddedGames
    Render-GameList; Show-Game $id; Show-Page 'navGames'
    Say ((Tn 'Game added: ' 'Game toegevoegd: ') + $name)
}
if (Test-Path $AddedGamesFile) {
    try {
        $saved = Get-Content $AddedGamesFile -Raw | ConvertFrom-Json
        foreach ($sg in @($saved)) { if ($sg.path -and (Test-Path -LiteralPath ([string]$sg.path))) { [void](Register-CustomGame ([string]$sg.path) ([string]$sg.name) ([string]$sg.ac)) } }
    } catch {}
}
Step 'addgame-ui' {
    $host1 = $ui.btnScan.Parent
    $ab = New-Object Windows.Controls.Button; $ab.Content = 'Add Game'; $ab.Padding = '14,9'; $ab.Margin = '0,4,8,4'
    $ab.Add_Click({ try { Add-GameFromDialog } catch { Log "Add game failed: $($_.Exception.Message)" } })
    [Windows.Controls.DockPanel]::SetDock($ab, 'Left')
    $host1.Children.Insert($host1.Children.IndexOf($ui.btnScan) + 1, $ab)
}
$script:OrigShowGame2 = ${function:Show-Game}
function Show-Game($id) {
    & $script:OrigShowGame2 $id
    try {
        if ([string]$id -like 'custom_*') {
            $btns = $ui.gameDetail.Children[$ui.gameDetail.Children.Count - 1]
            if ($btns -is [Windows.Controls.WrapPanel]) {
                $rb = New-Object Windows.Controls.Button; $rb.Content = 'Remove from list'; $rb.Tag = $id; $rb.Background = Brush '#3A1F2B'
                $rb.Add_Click({
                    $gid = [string]$this.Tag
                    try { Undo-GameKey "game_$gid" } catch {}
                    $script:Games = @($Games | Where-Object { $_.Id -ne $gid }); $script:GamePaths.Remove($gid)
                    Save-State; Save-AddedGames; $script:CurGame = $null; $ui.gameDetail.Children.Clear(); Render-GameList; Update-Stats
                    Log 'Game removed from the list.'
                })
                $btns.Children.Add($rb) | Out-Null; Tr $rb
            }
        }
    } catch {}
}

# ---------------------------------------------------------------- 4. My Presets with share codes
$PresetsFile = Join-Path $DataDir 'presets.json'
$script:UserPresets = @()
if (Test-Path $PresetsFile) {
    try { $pj = Get-Content $PresetsFile -Raw | ConvertFrom-Json; foreach ($p in @($pj)) { if ($p.name) { $script:UserPresets += @{ name = [string]$p.name; ids = @($p.ids | ForEach-Object { [string]$_ }) } } } } catch {}
}
function Save-Presets { try { Write-JsonAtomic -Path $PresetsFile -Value @($script:UserPresets) -Depth 4 } catch { Log "Could not save presets: $($_.Exception.Message)" } }
function Encode-PresetCode($name, $ids) {
    $text = (($name -replace '[\|\r\n]', ' ')) + '|' + ($ids -join ',')
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $ms = New-Object IO.MemoryStream
    $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Compress)
    $ds.Write($bytes, 0, $bytes.Length); $ds.Close()
    'SHARK1-' + (([Convert]::ToBase64String($ms.ToArray())).TrimEnd('=') -replace '\+', '-' -replace '/', '_')
}
function Decode-PresetCode($code) {
    try {
        $c = ([string]$code).Trim()
        if ($c -notmatch '^SHARK1-([A-Za-z0-9_\-]+)$') { return $null }
        $b64 = ($Matches[1] -replace '-', '+') -replace '_', '/'
        while ($b64.Length % 4) { $b64 += '=' }
        $in = [IO.MemoryStream]::new([byte[]][Convert]::FromBase64String($b64))
        $ds = New-Object IO.Compression.DeflateStream($in, [IO.Compression.CompressionMode]::Decompress)
        $sr = New-Object IO.StreamReader($ds, [Text.Encoding]::UTF8)
        $buf = New-Object char[] 8001; $n = $sr.Read($buf, 0, 8001)
        if ($n -gt 8000 -or $n -lt 3) { return $null }
        $text = New-Object string($buf, 0, $n)
        $parts = $text.Split([char]'|')
        if ($parts.Count -ne 2) { return $null }
        $name = ($parts[0] -replace '[^\p{L}\p{N} _\-\.\(\)]', '').Trim(); if (-not $name) { $name = 'Imported' }; if ($name.Length -gt 40) { $name = $name.Substring(0, 40) }
        $all = @($parts[1].Split(',') | Where-Object { $_ -match '^[a-z]_[a-z0-9]+$' })
        $good = @($all | Where-Object { Get-Tweak $_ })
        return @{ name = $name; ids = $good; skipped = ($all.Count - $good.Count) }
    } catch { return $null }
}
function Read-Text($title, $prompt, $default = '') {
    $w = New-Object Windows.Window; $w.Title = $title; $w.Width = 480; $w.SizeToContent = 'Height'; $w.ResizeMode = 'NoResize'
    $w.Background = Brush '#0B1424'; $w.Owner = $window; $w.WindowStartupLocation = 'CenterOwner'
    $sp = New-Object Windows.Controls.StackPanel; $sp.Margin = '20'
    $sp.Children.Add((New-Text $prompt 13 '#C2CCDF' $false '0,0,0,8')) | Out-Null
    $script:rtBox = New-Object Windows.Controls.TextBox; $script:rtBox.Text = $default; $script:rtBox.Padding = '8,6'; $sp.Children.Add($script:rtBox) | Out-Null
    $row = New-Object Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'; $row.Margin = '0,12,0,0'
    $ok = New-Object Windows.Controls.Button; $ok.Content = 'OK'; $ok.Padding = '18,8'; $ok.Background = Brush '#1FB6FF'; $ok.Foreground = Brush '#06121F'
    $cancel = New-Object Windows.Controls.Button; $cancel.Content = 'Cancel'; $cancel.Padding = '18,8'
    $script:rtWin = $w; $script:rtResult = $null
    $ok.Add_Click({ $script:rtResult = $script:rtBox.Text; $script:rtWin.Close() }); $cancel.Add_Click({ $script:rtWin.Close() })
    $row.Children.Add($ok) | Out-Null; $row.Children.Add($cancel) | Out-Null; $sp.Children.Add($row) | Out-Null
    $w.Content = $sp; Tr $w
    $script:rtBox.Focus() | Out-Null
    [void]$w.ShowDialog()
    $script:rtResult
}
function Use-Preset($ids) {
    $script:Selected.Clear(); $n = 0
    foreach ($id in $ids) { $tw = Get-Tweak $id; if ($tw -and (Test-Applicable $tw) -and -not $State.ContainsKey($tw.Id)) { [void]$script:Selected.Add($tw.Id); $n++ } }
    $script:CatFilter = 'All'; $ui.chkRec.IsChecked = $false; $ui.txtSearch.Text = ''
    Render-Tweaks; Show-Page 'navTweaks'
    Log "Preset: $n tweaks selected. Review them, then click Apply Selected."
}
function Rebuild-PresetList {
    $script:pmList.Children.Clear()
    if (-not $script:UserPresets.Count) { $script:pmList.Children.Add((New-Text 'No presets yet.' 13 '#7F8FAE' $false '4,8,0,8')) | Out-Null }
    foreach ($p in $script:UserPresets) {
        $row = New-Object Windows.Controls.Border; $row.Background = Brush '#0F1A2C'; $row.BorderBrush = Brush '#1A2943'; $row.BorderThickness = 1; $row.CornerRadius = 10; $row.Padding = '14,10'; $row.Margin = '0,0,0,8'
        $dp = New-Object Windows.Controls.DockPanel
        $bp = New-Object Windows.Controls.StackPanel; $bp.Orientation = 'Horizontal'; [Windows.Controls.DockPanel]::SetDock($bp, 'Right')
        foreach ($spec in @(@('Use', 'use'), @('Copy code', 'copy'), @('Delete', 'del'))) {
            $b = New-Object Windows.Controls.Button; $b.Content = $spec[0]; $b.Tag = @{ n = $p.name; a = $spec[1] }; $b.Padding = '12,6'
            if ($spec[1] -eq 'use') { $b.Background = Brush '#1FB6FF'; $b.Foreground = Brush '#06121F' }
            if ($spec[1] -eq 'del') { $b.Background = Brush '#3A1F2B' }
            $b.Add_Click({
                $t = $this.Tag; $pr = $script:UserPresets | Where-Object { $_.name -eq $t.n } | Select-Object -First 1
                if (-not $pr) { return }
                switch ($t.a) {
                    'use'  { $script:pmWin.Close(); Use-Preset $pr.ids }
                    'copy' { [Windows.Clipboard]::SetText((Encode-PresetCode $pr.name $pr.ids)); Say (Tn 'Share code copied.' 'Deelcode gekopieerd.') }
                    'del'  { $script:UserPresets = @($script:UserPresets | Where-Object { $_.name -ne $t.n }); Save-Presets; Rebuild-PresetList }
                }
            })
            $bp.Children.Add($b) | Out-Null
        }
        $tx = New-Object Windows.Controls.StackPanel
        $tx.Children.Add((New-Text $p.name 14 '#FFFFFF' $true)) | Out-Null
        $tx.Children.Add((New-Text ("{0} tweaks" -f @($p.ids).Count) 11.5 '#7F8FAE')) | Out-Null
        $dp.Children.Add($bp) | Out-Null; $dp.Children.Add($tx) | Out-Null; $row.Child = $dp; $script:pmList.Children.Add($row) | Out-Null
    }
    Tr $script:pmWin
}
function Show-PresetManager {
    $w = New-Object Windows.Window; $w.Title = Tn 'My Presets' 'Mijn voorinstellingen'; $w.Width = 620; $w.Height = 520; $w.Background = Brush '#08101D'
    $w.Owner = $window; $w.WindowStartupLocation = 'CenterOwner'
    $grid = New-Object Windows.Controls.Grid; $grid.Margin = '18'
    foreach ($h in 'Auto', '*', 'Auto') { $r = New-Object Windows.Controls.RowDefinition; $r.Height = $h; $grid.RowDefinitions.Add($r) }
    $hd = New-Text 'My Presets' 22 '#FFFFFF' $true '0,0,0,10'; [Windows.Controls.Grid]::SetRow($hd, 0); $grid.Children.Add($hd) | Out-Null
    $sv = New-Object Windows.Controls.ScrollViewer; $sv.VerticalScrollBarVisibility = 'Auto'; $script:pmList = New-Object Windows.Controls.StackPanel; $sv.Content = $script:pmList
    [Windows.Controls.Grid]::SetRow($sv, 1); $grid.Children.Add($sv) | Out-Null
    $foot = New-Object Windows.Controls.WrapPanel; [Windows.Controls.Grid]::SetRow($foot, 2); $foot.Margin = '0,10,0,0'
    $save = New-Object Windows.Controls.Button; $save.Content = 'Save current selection'; $save.Padding = '14,9'; $save.Background = Brush '#1FB6FF'; $save.Foreground = Brush '#06121F'
    $save.Add_Click({
        $ids = @($script:Selected | Sort-Object)
        if (-not $ids.Count) { [void][Windows.MessageBox]::Show((Tn 'Tick some tweaks on the Tweaks page first, then save them as a preset.' 'Vink eerst tweaks aan op de Tweaks-pagina en sla ze daarna op als voorinstelling.'), 'SharkOptimizer'); return }
        $nm = Read-Text (Tn 'Save preset' 'Voorinstelling opslaan') (Tn 'Give your preset a name:' 'Geef je voorinstelling een naam:') ''
        if ($nm -and $nm.Trim()) {
            $nm = ($nm -replace '[\|\r\n]', ' ').Trim(); if ($nm.Length -gt 40) { $nm = $nm.Substring(0, 40) }
            $script:UserPresets = @($script:UserPresets | Where-Object { $_.name -ne $nm }) + @{ name = $nm; ids = $ids }
            Save-Presets; Rebuild-PresetList; Say ((Tn 'Preset saved: ' 'Voorinstelling opgeslagen: ') + $nm)
        }
    })
    $imp = New-Object Windows.Controls.Button; $imp.Content = 'Import code'; $imp.Padding = '14,9'
    $imp.Add_Click({
        $code = Read-Text (Tn 'Import preset' 'Voorinstelling importeren') (Tn 'Paste the share code (starts with SHARK1-):' 'Plak de deelcode (begint met SHARK1-):') ''
        if (-not $code) { return }
        $d = Decode-PresetCode $code
        if (-not $d -or -not $d.ids.Count) { [void][Windows.MessageBox]::Show((Tn 'That code is not valid.' 'Die code is niet geldig.'), 'SharkOptimizer', 'OK', 'Warning'); return }
        $nm = $d.name; $k = 2; while ($script:UserPresets | Where-Object { $_.name -eq $nm }) { $nm = "$($d.name) ($k)"; $k++ }
        $script:UserPresets = @($script:UserPresets) + @{ name = $nm; ids = $d.ids }
        Save-Presets; Rebuild-PresetList
        Say ((Tn 'Preset imported: ' 'Voorinstelling geïmporteerd: ') + $nm + $(if ($d.skipped) { " ($($d.skipped) unknown skipped)" } else { '' }))
    })
    $foot.Children.Add($save) | Out-Null; $foot.Children.Add($imp) | Out-Null; $grid.Children.Add($foot) | Out-Null
    $w.Content = $grid; $script:pmWin = $w
    Rebuild-PresetList; Tr $w
    $w.Show()
}
Step 'presets-ui' {
    $pb = New-Object Windows.Controls.Button; $pb.Content = 'My Presets'; $pb.Padding = '14,8'
    $pb.Add_Click({ if ($script:pmWin -and $script:pmWin.IsVisible) { $script:pmWin.Activate() } else { Show-PresetManager } })
    $ui.pnlPresets.Children.Add($pb) | Out-Null
}

# ---------------------------------------------------------------- 5. copy system report
function Get-SystemReport {
    $L = New-Object System.Collections.ArrayList
    $ver = if ($AppVer) { $AppVer } else { '?' }
    [void]$L.Add("SharkOptimizer system report"); [void]$L.Add("App version : $ver"); [void]$L.Add("Created     : $(Get-Date -Format 'yyyy-MM-dd HH:mm')"); [void]$L.Add("Language    : $($script:Lang)")
    $dv = ''; try { $dv = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).DisplayVersion } catch {}
    [void]$L.Add("Windows     : $($Spec.OS) build $($Spec.Build) $dv")
    [void]$L.Add("CPU         : $($Spec.CPU) [$($Spec.Cores)C/$($Spec.Threads)T]")
    try { foreach ($v in @(Get-CimInstance Win32_VideoController)) { [void]$L.Add("GPU         : $($v.Name)  driver $($v.DriverVersion)") } } catch { [void]$L.Add("GPU         : $($Spec.GPU)") }
    [void]$L.Add("RAM         : $($Spec.RamGB) GB"); [void]$L.Add("System disk : $(if ($Spec.SSD) { 'SSD' } else { 'HDD or unknown' })")
    [void]$L.Add("Type        : $(if ($Spec.Laptop) { 'Laptop' } else { 'Desktop' })"); [void]$L.Add("Network     : $(if ($Spec.Wifi) { 'Wi-Fi' } else { 'Ethernet' })")
    [void]$L.Add(''); [void]$L.Add('Applied tweaks:')
    $any = $false
    foreach ($t in $Tweaks) { if ($State.ContainsKey($t.Id)) { $nm = if ($script:TweakEn -and $script:TweakEn.ContainsKey($t.Id)) { $script:TweakEn[$t.Id].N } else { $t.Name }; [void]$L.Add("  $($t.Id)  $nm"); $any = $true } }
    if (-not $any) { [void]$L.Add('  (none)') }
    $gp = @($State.Keys | Where-Object { $_ -like 'game_*' })
    if ($gp.Count) { [void]$L.Add(''); [void]$L.Add('Game profiles: ' + (($gp | ForEach-Object { $_ -replace '^game_', '' }) -join ', ')) }
    [void]$L.Add(''); [void]$L.Add('Settings: accent=' + $Settings.Accent + ' toasts=' + $Settings.Toasts + ' showLog=' + $Settings.ShowLog)
    [void]$L.Add(''); [void]$L.Add('Recent log:')
    try { foreach ($ln in @(Get-Content $LogFile -Tail 40 -ErrorAction Stop)) { [void]$L.Add("  $ln") } } catch { [void]$L.Add('  (no log yet)') }
    $text = $L -join "`r`n"
    foreach ($secret in $env:USERNAME, $env:COMPUTERNAME) { if ($secret) { $text = $text -replace [regex]::Escape($secret), '<hidden>' } }
    $text
}
Step 'report-ui' {
    $rb = New-Object Windows.Controls.Button; $rb.Content = 'Copy System Report'; $rb.Padding = '14,9'
    $rb.Add_Click({ try { [Windows.Clipboard]::SetText((Get-SystemReport)); Say (Tn 'System report copied. Paste it into your message.' 'Systeemrapport gekopieerd. Plak het in je bericht.') } catch { Log "Report failed: $($_.Exception.Message)" } })
    $target = $null
    foreach ($pnl in @($setPanel.Children | Where-Object { $_ -is [Windows.Controls.WrapPanel] })) {
        foreach ($b in @($pnl.Children | Where-Object { $_ -is [Windows.Controls.Button] })) { if ($b.Content -eq 'Show the guide again' -or $b.Content -eq 'Toon de handleiding opnieuw') { $target = $pnl } }
    }
    if ($target) { $target.Children.Add($rb) | Out-Null } else { $setPanel.Children.Add($rb) | Out-Null }
    Tr $rb
}

# ---------------------------------------------------------------- start-up for the extras
try { Set-Accent $(if ($Settings.Accent) { [string]$Settings.Accent } else { 'blue' }) } catch {}
try { if ($script:Lang -eq 'nl') { Tr $window } } catch {}


# ================================================================ SharkOptimizer More Languages (added module): Spanish, German, French, Portuguese (Brazil), Russian, Simplified Chinese
$script:XLangs = [ordered]@{}
$script:XLang = $null
function Parse-Pairs($text) {
    $h = @{}
    foreach ($ln in ($text -split "`r?`n")) { $i = $ln.IndexOf(' => '); if ($i -gt 0) { $h[$ln.Substring(0, $i)] = $ln.Substring($i + 4) } }
    $h
}
function Add-XLang($code, $native, $uiText, $twText) { $script:XLangs[$code] = @{ Native = $native; UI = (Parse-Pairs $uiText); Tw = (Parse-Pairs $twText) } }
$xl_es_ui = @'
Dashboard => Panel
Tweaks => Ajustes
Games => Juegos
Windows => Windows
Lab => Laboratorio
Boost-Up => Boost-Up
Network => Red
Restore => Restaurar
Settings => Configuración
Welcome to SharkOptimizer => Bienvenido a SharkOptimizer
CPU USAGE => USO DE CPU
GPU 3D USAGE => USO DE GPU 3D
RAM USAGE => USO DE RAM
Optimizations active => Optimizaciones activas
Recommended pending => Recomendadas pendientes
Tweaks available => Ajustes disponibles
Recommended tweaks applied => Ajustes recomendados aplicados
Presets => Preajustes
Safe Essentials => Esenciales seguros
Competitive => Competitivo
Max Privacy => Máxima privacidad
Low-End PC => PC de gama baja
Laptop Safe => Seguro para portátil
Apply Recommended => Aplicar recomendados
Create Restore Point => Crear punto de restauración
Recommended only => Solo recomendados
All => Todos
Privacy & Security => Privacidad y seguridad
Quality of Life => Comodidad
FPS & Latency => FPS y latencia
Network & Ping => Red y ping
Windows Optimization => Optimización de Windows
Advanced => Avanzado
Select Recommended => Seleccionar recomendados
Select Visible => Seleccionar visibles
Clear => Borrar
Undo Selected => Deshacer seleccionados
Apply Selected => Aplicar seleccionados
SAFE => SEGURO
CAUTION => PRECAUCIÓN
CORE WINDOWS CHANGE => CAMBIO EN EL NÚCLEO DE WINDOWS
FOR YOUR PC => PARA TU PC
RESTART NEEDED => REQUIERE REINICIO
Select => Seleccionar
ACTIVE => ACTIVO
Inactive => Inactivo
Details => Detalles
Scan for Games => Buscar juegos
Installed => Instalado
Not detected => No detectado
Profile active => Perfil activo
INSTALLED => INSTALADO
NOT DETECTED => NO DETECTADO
PROFILE ACTIVE => PERFIL ACTIVO
Recommended Windows tweaks => Ajustes de Windows recomendados
In-game tips => Consejos en el juego
Launch options => Opciones de inicio
Copy => Copiar
Undo Game Settings => Deshacer ajustes del juego
Open Folder => Abrir carpeta
Add Game => Añadir juego
Remove from list => Quitar de la lista
Quick Tools => Herramientas rápidas
Startup Apps => Aplicaciones de inicio
Refresh => Actualizar
Remove Built-in Apps => Quitar aplicaciones integradas
Remove Selected => Quitar seleccionadas
Close Heavy Apps => Cerrar apps pesadas
Close Selected => Cerrar seleccionadas
System File Check => Comprobar archivos del sistema
DISM Repair => Reparación DISM
Check Disk (scan) => Comprobar disco (análisis)
Reset Windows Update => Restablecer Windows Update
Rebuild Icon Cache => Reconstruir caché de iconos
Restart Explorer => Reiniciar el Explorador
Disk Cleanup => Liberador de espacio
Power Options => Opciones de energía
Services => Servicios
Task Manager => Administrador de tareas
Run All => Ejecutar todo
Run => Ejecutar
Not run yet => Aún no ejecutado
Not needed on this PC => No necesario en este PC
Junk Cleaner => Limpiador de basura
Optimize Drives => Optimizar unidades
Clean Recent Documents => Borrar documentos recientes
Clean Thumbnail Cache => Borrar caché de miniaturas
Clean Font Cache => Borrar caché de fuentes
Clear Shader Caches => Borrar cachés de shaders
Clean Browser Caches => Borrar cachés del navegador
Trim Process RAM => Liberar RAM de procesos
Flush DNS Cache => Vaciar caché DNS
Test Regions => Probar regiones
Test Host => Probar host
DNS Benchmark => Prueba de DNS
Apply Best DNS => Aplicar el mejor DNS
Flush DNS => Vaciar DNS
Undo All Tweaks => Deshacer todos los ajustes
Open Log => Abrir registro
Currently applied => Aplicado actualmente
Nothing applied yet. => Aún no se ha aplicado nada.
Before and after benchmark => Prueba antes y después
Run BEFORE => Medir ANTES
Run AFTER => Medir DESPUÉS
Clear Results => Borrar resultados
Game Mode => Modo juego
Start Game Mode => Iniciar modo juego
End Game Mode => Terminar modo juego
Refresh Lists => Actualizar listas
Game Mode is off. => El modo juego está desactivado.
System check => Revisión del sistema
Run System Check => Revisar el sistema
Verify applied tweaks => Verificar ajustes aplicados
Verify Now => Verificar ahora
Re-apply Drifted => Reaplicar revertidos
Profiles and safe apply => Perfiles y aplicación segura
Export Profile => Exportar perfil
Import Profile => Importar perfil
Guided Apply (selected tweaks) => Aplicación guiada (seleccionados)
Reset to Windows Defaults => Restablecer valores de Windows
Network tools => Herramientas de red
Start Live Ping => Iniciar ping en vivo
Stop => Detener
Traceroute => Traceroute
Scan Wi-Fi Channels => Analizar canales Wi-Fi
Language => Idioma
Behaviour => Comportamiento
Show pop-up notifications => Mostrar notificaciones emergentes
Show the activity log => Mostrar el registro de actividad
Scan for games when SharkOptimizer starts => Buscar juegos al iniciar SharkOptimizer
Help and data => Ayuda y datos
Show the guide again => Mostrar la guía de nuevo
Open data folder => Abrir carpeta de datos
Open log file => Abrir archivo de registro
Clear saved game scan => Borrar búsqueda de juegos guardada
Reset settings => Restablecer configuración
About => Acerca de
Appearance => Apariencia
Blue => Azul
Green => Verde
Purple => Morado
Orange => Naranja
Scheduled cleanup => Limpieza programada
Enable weekly cleanup => Activar limpieza semanal
Disable weekly cleanup => Desactivar limpieza semanal
Run it now => Ejecutar ahora
My Presets => Mis preajustes
Save current selection => Guardar selección actual
Import code => Importar código
Use => Usar
Copy code => Copiar código
Delete => Eliminar
No presets yet. => Aún no hay preajustes.
Copy System Report => Copiar informe del sistema
Guide  (how to use) => Guía (cómo usar)
Close => Cerrar
Back => Atrás
Next => Siguiente
Finish => Finalizar
Save => Guardar
Check now => Comprobar ahora
Cancel => Cancelar
Monday => Lunes
Tuesday => Martes
Wednesday => Miércoles
Thursday => Jueves
Friday => Viernes
Saturday => Sábado
Sunday => Domingo
selected => seleccionados
Pending => Pendiente
Unavailable => No disponible
Optimize for => Optimizar para
'@
$xl_es_tw = @'
p_telemetry => Desactivar telemetría
p_tasks => Desactivar tareas de telemetría
p_adid => Desactivar ID de publicidad
p_bing => Desactivar búsqueda web en Inicio
p_cortana => Desactivar Cortana y búsqueda en la nube
p_activity => Desactivar historial de actividad
p_ads => Quitar anuncios de Windows
p_consumer => Bloquear funciones de consumo
p_copilot => Desactivar Copilot
p_recall => Desactivar análisis de datos con IA
p_widgets => Desactivar Widgets
p_wer => Desactivar informes de errores
p_feedback => Desactivar solicitudes de opinión
p_inventory => Desactivar inventario de apps y Grabador de pasos
p_ink => Detener recopilación de escritura y entintado
p_clip => Desactivar sincronización del portapapeles
p_location => Desactivar servicios de ubicación
p_llmnr => Desactivar LLMNR
p_remreg => Desactivar Registro remoto
p_remote => Desactivar Asistencia remota
p_nvtel => Desactivar telemetría de NVIDIA
p_do => Desactivar uso compartido de actualizaciones (P2P)
q_ext => Mostrar extensiones de archivo
q_hidden => Mostrar archivos ocultos
q_thispc => Abrir el Explorador en Este equipo
q_recent => Ocultar archivos recientes y frecuentes
q_shake => Desactivar sacudir ventanas
q_dark => Modo oscuro
q_taskbar => Barra de tareas limpia de Windows 11
q_classic => Menú contextual clásico
q_boot => Mensajes de arranque detallados
q_menu => Menús instantáneos
q_kb => Repetición rápida del teclado
q_shutdown => Apagado más rápido
q_startdelay => Quitar retraso de inicio
q_sticky => Desactivar avisos de teclas especiales
q_reboot => Bloquear reinicios forzados por actualizaciones
q_welcome => Omitir pantallas de bienvenida tras actualizar
q_visfx => Efectos visuales ligeros
q_bgapps => Bloquear apps en segundo plano
q_search => Desactivar indexado de búsqueda
f_gamemode => Activar Modo juego
f_dvr => Desactivar grabación en segundo plano
f_overlay => Desactivar superposición de Game Bar
f_power => Plan de energía Máximo rendimiento
f_usb => Desactivar suspensión selectiva de USB
f_pcie => Desactivar ahorro de energía PCIe
f_diskoff => Nunca suspender discos duros
f_cpumin => Estado mínimo de CPU al 100%
f_throttle => Desactivar limitación de energía
f_prio => Aumentar prioridad en primer plano
f_mmcss => Planificación de juegos (MMCSS)
f_fso => Desactivar optimizaciones de pantalla completa
f_mouse => Entrada de ratón sin procesar
f_hags => Planificación de GPU (HAGS)
f_mpo => Desactivar Multiplane Overlay (MPO)
f_fast => Desactivar inicio rápido
f_sysmain => Desactivar SysMain
f_timerreq => Resolución global del temporizador
n_nagle => Desactivar algoritmo de Nagle
n_throttle => Desactivar limitación de red
n_qos => Quitar reserva de ancho de banda QoS
n_ports => Reutilización más rápida de puertos TCP
n_heur => Desactivar heurística TCP
n_dns => DNS rápido (Cloudflare)
n_rsc => Desactivar coalescencia de paquetes (RSC)
n_lso => Desactivar Large Send Offload
n_nicpwr => Desactivar ahorro de energía del adaptador
n_eee => Desactivar Green Ethernet / EEE
n_flow => Desactivar control de flujo
n_intmod => Desactivar moderación de interrupciones
n_rss => Activar Receive Side Scaling
n_wifi => Wi-Fi a máximo rendimiento
n_netbios => Desactivar NetBIOS sobre TCP/IP
n_teredo => Desactivar túnel Teredo
w_edge => Detener actividad de Edge en segundo plano
w_services => Desactivar servicios no usados
w_chat => Quitar icono de Chat de Teams
w_lastaccess => Desactivar última hora de acceso NTFS
w_8dot3 => Desactivar nombres de archivo 8.3
w_svchost => Unir procesos de host de servicios
w_pagingexec => Mantener el kernel en RAM
w_memcomp => Desactivar compresión de memoria
w_prefetch => Desactivar Prefetcher
w_maint => Desactivar mantenimiento automático
w_onedrive => Desactivar sincronización de OneDrive
w_wudrv => Bloquear controladores de Windows Update
w_spooler => Desactivar cola de impresión
a_msi => Modo MSI de la GPU
a_tick => Desactivar tick dinámico
a_hyperv => Desactivar hipervisor
a_xbox => Desactivar servicios de Xbox
a_ipv6 => Desactivar IPv6
a_spectre => Desactivar mitigaciones de CPU
a_vbs => Desactivar VBS / Integridad de memoria
a_hib => Desactivar hibernación
'@
Add-XLang 'es' 'Español' $xl_es_ui $xl_es_tw

$xl_de_ui = @'
Dashboard => Übersicht
Tweaks => Tweaks
Games => Spiele
Windows => Windows
Lab => Labor
Boost-Up => Boost-Up
Network => Netzwerk
Restore => Wiederherstellen
Settings => Einstellungen
Welcome to SharkOptimizer => Willkommen bei SharkOptimizer
CPU USAGE => CPU-AUSLASTUNG
GPU 3D USAGE => GPU-3D-AUSLASTUNG
RAM USAGE => RAM-AUSLASTUNG
Optimizations active => Aktive Optimierungen
Recommended pending => Empfohlen, offen
Tweaks available => Verfügbare Tweaks
Recommended tweaks applied => Empfohlene Tweaks angewendet
Presets => Voreinstellungen
Safe Essentials => Sichere Basis
Competitive => Wettkampf
Max Privacy => Maximale Privatsphäre
Low-End PC => Schwacher PC
Laptop Safe => Laptop-sicher
Apply Recommended => Empfohlene anwenden
Create Restore Point => Wiederherstellungspunkt erstellen
Recommended only => Nur empfohlene
All => Alle
Privacy & Security => Datenschutz & Sicherheit
Quality of Life => Komfort
FPS & Latency => FPS & Latenz
Network & Ping => Netzwerk & Ping
Windows Optimization => Windows-Optimierung
Advanced => Erweitert
Select Recommended => Empfohlene auswählen
Select Visible => Sichtbare auswählen
Clear => Leeren
Undo Selected => Auswahl rückgängig
Apply Selected => Auswahl anwenden
SAFE => SICHER
CAUTION => VORSICHT
CORE WINDOWS CHANGE => EINGRIFF IN WINDOWS-KERN
FOR YOUR PC => FÜR DEINEN PC
RESTART NEEDED => NEUSTART NÖTIG
Select => Auswählen
ACTIVE => AKTIV
Inactive => Inaktiv
Details => Details
Scan for Games => Spiele suchen
Installed => Installiert
Not detected => Nicht gefunden
Profile active => Profil aktiv
INSTALLED => INSTALLIERT
NOT DETECTED => NICHT GEFUNDEN
PROFILE ACTIVE => PROFIL AKTIV
Recommended Windows tweaks => Empfohlene Windows-Tweaks
In-game tips => Tipps im Spiel
Launch options => Startoptionen
Copy => Kopieren
Undo Game Settings => Spieleinstellungen rückgängig
Open Folder => Ordner öffnen
Add Game => Spiel hinzufügen
Remove from list => Aus Liste entfernen
Quick Tools => Schnellwerkzeuge
Startup Apps => Autostart-Apps
Refresh => Aktualisieren
Remove Built-in Apps => Integrierte Apps entfernen
Remove Selected => Auswahl entfernen
Close Heavy Apps => Schwere Apps schließen
Close Selected => Auswahl schließen
System File Check => Systemdateien prüfen
DISM Repair => DISM-Reparatur
Check Disk (scan) => Datenträger prüfen (Scan)
Reset Windows Update => Windows Update zurücksetzen
Rebuild Icon Cache => Symbolcache neu aufbauen
Restart Explorer => Explorer neu starten
Disk Cleanup => Datenträgerbereinigung
Power Options => Energieoptionen
Services => Dienste
Task Manager => Task-Manager
Run All => Alle ausführen
Run => Ausführen
Not run yet => Noch nicht ausgeführt
Not needed on this PC => Auf diesem PC nicht nötig
Junk Cleaner => Datenmüll-Bereiniger
Optimize Drives => Laufwerke optimieren
Clean Recent Documents => Zuletzt verwendete Dokumente löschen
Clean Thumbnail Cache => Miniaturansicht-Cache leeren
Clean Font Cache => Schriftarten-Cache leeren
Clear Shader Caches => Shader-Caches leeren
Clean Browser Caches => Browser-Caches leeren
Trim Process RAM => Prozess-RAM freigeben
Flush DNS Cache => DNS-Cache leeren
Test Regions => Regionen testen
Test Host => Host testen
DNS Benchmark => DNS-Benchmark
Apply Best DNS => Besten DNS anwenden
Flush DNS => DNS leeren
Undo All Tweaks => Alle Tweaks rückgängig
Open Log => Protokoll öffnen
Currently applied => Aktuell angewendet
Nothing applied yet. => Noch nichts angewendet.
Before and after benchmark => Messung vorher und nachher
Run BEFORE => Messung VORHER
Run AFTER => Messung NACHHER
Clear Results => Ergebnisse löschen
Game Mode => Spielemodus
Start Game Mode => Spielemodus starten
End Game Mode => Spielemodus beenden
Refresh Lists => Listen aktualisieren
Game Mode is off. => Spielemodus ist aus.
System check => Systemprüfung
Run System Check => Systemprüfung starten
Verify applied tweaks => Angewendete Tweaks prüfen
Verify Now => Jetzt prüfen
Re-apply Drifted => Zurückgesetzte erneut anwenden
Profiles and safe apply => Profile und sicheres Anwenden
Export Profile => Profil exportieren
Import Profile => Profil importieren
Guided Apply (selected tweaks) => Schrittweise anwenden (Auswahl)
Reset to Windows Defaults => Auf Windows-Standard zurücksetzen
Network tools => Netzwerkwerkzeuge
Start Live Ping => Live-Ping starten
Stop => Stopp
Traceroute => Traceroute
Scan Wi-Fi Channels => WLAN-Kanäle scannen
Language => Sprache
Behaviour => Verhalten
Show pop-up notifications => Pop-up-Benachrichtigungen anzeigen
Show the activity log => Aktivitätsprotokoll anzeigen
Scan for games when SharkOptimizer starts => Beim Start nach Spielen suchen
Help and data => Hilfe und Daten
Show the guide again => Anleitung erneut anzeigen
Open data folder => Datenordner öffnen
Open log file => Protokolldatei öffnen
Clear saved game scan => Gespeicherte Spielesuche löschen
Reset settings => Einstellungen zurücksetzen
About => Info
Appearance => Darstellung
Blue => Blau
Green => Grün
Purple => Lila
Orange => Orange
Scheduled cleanup => Geplante Bereinigung
Enable weekly cleanup => Wöchentliche Bereinigung aktivieren
Disable weekly cleanup => Wöchentliche Bereinigung deaktivieren
Run it now => Jetzt ausführen
My Presets => Meine Voreinstellungen
Save current selection => Aktuelle Auswahl speichern
Import code => Code importieren
Use => Verwenden
Copy code => Code kopieren
Delete => Löschen
No presets yet. => Noch keine Voreinstellungen.
Copy System Report => Systembericht kopieren
Guide  (how to use) => Anleitung (so geht's)
Close => Schließen
Back => Zurück
Next => Weiter
Finish => Fertig
Save => Speichern
Check now => Jetzt prüfen
Cancel => Abbrechen
Monday => Montag
Tuesday => Dienstag
Wednesday => Mittwoch
Thursday => Donnerstag
Friday => Freitag
Saturday => Samstag
Sunday => Sonntag
selected => ausgewählt
Pending => Offen
Unavailable => Nicht verfügbar
Optimize for => Optimieren für
'@
$xl_de_tw = @'
p_telemetry => Telemetrie deaktivieren
p_tasks => Telemetrie-Aufgaben deaktivieren
p_adid => Werbe-ID deaktivieren
p_bing => Websuche im Startmenü deaktivieren
p_cortana => Cortana und Cloudsuche deaktivieren
p_activity => Aktivitätsverlauf deaktivieren
p_ads => Windows-Werbung entfernen
p_consumer => Verbraucherfunktionen blockieren
p_copilot => Copilot deaktivieren
p_recall => KI-Datenanalyse von Windows deaktivieren
p_widgets => Widgets deaktivieren
p_wer => Fehlerberichterstattung deaktivieren
p_feedback => Feedback-Abfragen deaktivieren
p_inventory => App-Inventar und Problemschritte-Recorder deaktivieren
p_ink => Sammeln von Tipp- und Handschriftdaten stoppen
p_clip => Zwischenablage-Cloudsync deaktivieren
p_location => Standortdienste deaktivieren
p_llmnr => LLMNR deaktivieren
p_remreg => Remoteregistrierung deaktivieren
p_remote => Remoteunterstützung deaktivieren
p_nvtel => NVIDIA-Telemetrie deaktivieren
p_do => Update-Freigabe (P2P) deaktivieren
q_ext => Dateiendungen anzeigen
q_hidden => Versteckte Dateien anzeigen
q_thispc => Explorer bei „Dieser PC“ öffnen
q_recent => Zuletzt und häufig verwendete Dateien ausblenden
q_shake => Fenster-Schütteln deaktivieren
q_dark => Dunkelmodus
q_taskbar => Aufgeräumte Windows-11-Taskleiste
q_classic => Klassisches Kontextmenü
q_boot => Ausführliche Startmeldungen
q_menu => Sofortige Menüs
q_kb => Schnelle Tastaturwiederholung
q_shutdown => Schnelleres Herunterfahren
q_startdelay => Startverzögerung entfernen
q_sticky => Einrastfunktions-Hinweise deaktivieren
q_reboot => Erzwungene Update-Neustarts blockieren
q_welcome => Willkommensseiten nach Updates überspringen
q_visfx => Schlanke visuelle Effekte
q_bgapps => Hintergrund-Apps blockieren
q_search => Suchindizierung deaktivieren
f_gamemode => Spielemodus aktivieren
f_dvr => Hintergrundaufnahme deaktivieren
f_overlay => Game-Bar-Overlay deaktivieren
f_power => Energiesparplan „Höchstleistung“
f_usb => USB-Selective-Suspend deaktivieren
f_pcie => PCIe-Energiesparen deaktivieren
f_diskoff => Festplatten nie in den Ruhezustand
f_cpumin => Minimaler Prozessorzustand 100 %
f_throttle => Energie-Drosselung deaktivieren
f_prio => Vordergrundpriorität erhöhen
f_mmcss => Spiele-Planung (MMCSS)
f_fso => Vollbildoptimierungen deaktivieren
f_mouse => Rohe Mauseingabe
f_hags => GPU-Planung (HAGS)
f_mpo => Multiplane Overlay (MPO) deaktivieren
f_fast => Schnellstart deaktivieren
f_sysmain => SysMain deaktivieren
f_timerreq => Globale Timer-Auflösung
n_nagle => Nagle-Algorithmus deaktivieren
n_throttle => Netzwerk-Drosselung deaktivieren
n_qos => QoS-Bandbreitenreserve entfernen
n_ports => Schnellere Wiederverwendung von TCP-Ports
n_heur => TCP-Heuristik deaktivieren
n_dns => Schneller DNS (Cloudflare)
n_rsc => Paketzusammenfassung (RSC) deaktivieren
n_lso => Large Send Offload deaktivieren
n_nicpwr => Adapter-Energiesparen deaktivieren
n_eee => Green Ethernet / EEE deaktivieren
n_flow => Flusssteuerung deaktivieren
n_intmod => Interrupt-Moderation deaktivieren
n_rss => Receive Side Scaling aktivieren
n_wifi => WLAN maximale Leistung
n_netbios => NetBIOS über TCP/IP deaktivieren
n_teredo => Teredo-Tunnel deaktivieren
w_edge => Edge-Hintergrundaktivität stoppen
w_services => Ungenutzte Dienste deaktivieren
w_chat => Teams-Chat-Symbol entfernen
w_lastaccess => NTFS-Zugriffszeit deaktivieren
w_8dot3 => 8.3-Dateinamen deaktivieren
w_svchost => Dienst-Hostprozesse zusammenführen
w_pagingexec => Kernel im RAM halten
w_memcomp => Speicherkomprimierung deaktivieren
w_prefetch => Prefetcher deaktivieren
w_maint => Automatische Wartung deaktivieren
w_onedrive => OneDrive-Synchronisierung deaktivieren
w_wudrv => Treiber über Windows Update blockieren
w_spooler => Druckwarteschlange deaktivieren
a_msi => GPU-MSI-Modus
a_tick => Dynamischen Tick deaktivieren
a_hyperv => Hypervisor ausschalten
a_xbox => Xbox-Dienste deaktivieren
a_ipv6 => IPv6 deaktivieren
a_spectre => CPU-Schutzmaßnahmen deaktivieren
a_vbs => VBS / Speicherintegrität deaktivieren
a_hib => Ruhezustand deaktivieren
'@
Add-XLang 'de' 'Deutsch' $xl_de_ui $xl_de_tw

$xl_fr_ui = @'
Dashboard => Tableau de bord
Tweaks => Réglages
Games => Jeux
Windows => Windows
Lab => Labo
Boost-Up => Boost-Up
Network => Réseau
Restore => Restauration
Settings => Paramètres
Welcome to SharkOptimizer => Bienvenue dans SharkOptimizer
CPU USAGE => UTILISATION CPU
GPU 3D USAGE => UTILISATION GPU 3D
RAM USAGE => UTILISATION RAM
Optimizations active => Optimisations actives
Recommended pending => Recommandées en attente
Tweaks available => Réglages disponibles
Recommended tweaks applied => Recommandations appliquées
Presets => Préréglages
Safe Essentials => Essentiels sûrs
Competitive => Compétitif
Max Privacy => Confidentialité max
Low-End PC => PC d'entrée de gamme
Laptop Safe => Sûr pour portable
Apply Recommended => Appliquer les recommandés
Create Restore Point => Créer un point de restauration
Recommended only => Recommandés seulement
All => Tous
Privacy & Security => Confidentialité et sécurité
Quality of Life => Confort
FPS & Latency => FPS et latence
Network & Ping => Réseau et ping
Windows Optimization => Optimisation de Windows
Advanced => Avancé
Select Recommended => Sélectionner les recommandés
Select Visible => Sélectionner les visibles
Clear => Effacer
Undo Selected => Annuler la sélection
Apply Selected => Appliquer la sélection
SAFE => SÛR
CAUTION => ATTENTION
CORE WINDOWS CHANGE => MODIFICATION DU CŒUR DE WINDOWS
FOR YOUR PC => POUR VOTRE PC
RESTART NEEDED => REDÉMARRAGE REQUIS
Select => Sélectionner
ACTIVE => ACTIF
Inactive => Inactif
Details => Détails
Scan for Games => Rechercher des jeux
Installed => Installé
Not detected => Non détecté
Profile active => Profil actif
INSTALLED => INSTALLÉ
NOT DETECTED => NON DÉTECTÉ
PROFILE ACTIVE => PROFIL ACTIF
Recommended Windows tweaks => Réglages Windows recommandés
In-game tips => Conseils en jeu
Launch options => Options de lancement
Copy => Copier
Undo Game Settings => Annuler les réglages du jeu
Open Folder => Ouvrir le dossier
Add Game => Ajouter un jeu
Remove from list => Retirer de la liste
Quick Tools => Outils rapides
Startup Apps => Applications au démarrage
Refresh => Actualiser
Remove Built-in Apps => Supprimer les applis intégrées
Remove Selected => Supprimer la sélection
Close Heavy Apps => Fermer les applis lourdes
Close Selected => Fermer la sélection
System File Check => Vérification des fichiers système
DISM Repair => Réparation DISM
Check Disk (scan) => Vérifier le disque (analyse)
Reset Windows Update => Réinitialiser Windows Update
Rebuild Icon Cache => Reconstruire le cache des icônes
Restart Explorer => Redémarrer l'Explorateur
Disk Cleanup => Nettoyage de disque
Power Options => Options d'alimentation
Services => Services
Task Manager => Gestionnaire des tâches
Run All => Tout exécuter
Run => Exécuter
Not run yet => Pas encore exécuté
Not needed on this PC => Inutile sur ce PC
Junk Cleaner => Nettoyeur de fichiers inutiles
Optimize Drives => Optimiser les lecteurs
Clean Recent Documents => Effacer les documents récents
Clean Thumbnail Cache => Vider le cache des miniatures
Clean Font Cache => Vider le cache des polices
Clear Shader Caches => Vider les caches de shaders
Clean Browser Caches => Vider les caches du navigateur
Trim Process RAM => Libérer la RAM des processus
Flush DNS Cache => Vider le cache DNS
Test Regions => Tester les régions
Test Host => Tester un hôte
DNS Benchmark => Benchmark DNS
Apply Best DNS => Appliquer le meilleur DNS
Flush DNS => Vider le DNS
Undo All Tweaks => Annuler tous les réglages
Open Log => Ouvrir le journal
Currently applied => Actuellement appliqué
Nothing applied yet. => Rien n'est encore appliqué.
Before and after benchmark => Mesure avant et après
Run BEFORE => Mesure AVANT
Run AFTER => Mesure APRÈS
Clear Results => Effacer les résultats
Game Mode => Mode jeu
Start Game Mode => Démarrer le mode jeu
End Game Mode => Arrêter le mode jeu
Refresh Lists => Actualiser les listes
Game Mode is off. => Le mode jeu est désactivé.
System check => Vérification du système
Run System Check => Lancer la vérification
Verify applied tweaks => Vérifier les réglages appliqués
Verify Now => Vérifier maintenant
Re-apply Drifted => Réappliquer les annulés
Profiles and safe apply => Profils et application sûre
Export Profile => Exporter le profil
Import Profile => Importer un profil
Guided Apply (selected tweaks) => Application guidée (sélection)
Reset to Windows Defaults => Rétablir les valeurs de Windows
Network tools => Outils réseau
Start Live Ping => Démarrer le ping en direct
Stop => Arrêter
Traceroute => Traceroute
Scan Wi-Fi Channels => Analyser les canaux Wi-Fi
Language => Langue
Behaviour => Comportement
Show pop-up notifications => Afficher les notifications
Show the activity log => Afficher le journal d'activité
Scan for games when SharkOptimizer starts => Rechercher des jeux au démarrage
Help and data => Aide et données
Show the guide again => Afficher le guide à nouveau
Open data folder => Ouvrir le dossier de données
Open log file => Ouvrir le fichier journal
Clear saved game scan => Effacer la recherche de jeux enregistrée
Reset settings => Réinitialiser les paramètres
About => À propos
Appearance => Apparence
Blue => Bleu
Green => Vert
Purple => Violet
Orange => Orange
Scheduled cleanup => Nettoyage planifié
Enable weekly cleanup => Activer le nettoyage hebdomadaire
Disable weekly cleanup => Désactiver le nettoyage hebdomadaire
Run it now => Exécuter maintenant
My Presets => Mes préréglages
Save current selection => Enregistrer la sélection actuelle
Import code => Importer un code
Use => Utiliser
Copy code => Copier le code
Delete => Supprimer
No presets yet. => Aucun préréglage pour l'instant.
Copy System Report => Copier le rapport système
Guide  (how to use) => Guide (mode d'emploi)
Close => Fermer
Back => Retour
Next => Suivant
Finish => Terminer
Save => Enregistrer
Check now => Vérifier maintenant
Cancel => Annuler
Monday => Lundi
Tuesday => Mardi
Wednesday => Mercredi
Thursday => Jeudi
Friday => Vendredi
Saturday => Samedi
Sunday => Dimanche
selected => sélectionnés
Pending => En attente
Unavailable => Indisponible
Optimize for => Optimiser pour
'@
$xl_fr_tw = @'
p_telemetry => Désactiver la télémétrie
p_tasks => Désactiver les tâches de télémétrie
p_adid => Désactiver l'identifiant publicitaire
p_bing => Désactiver la recherche web dans Démarrer
p_cortana => Désactiver Cortana et la recherche cloud
p_activity => Désactiver l'historique d'activité
p_ads => Supprimer les publicités de Windows
p_consumer => Bloquer les fonctions grand public
p_copilot => Désactiver Copilot
p_recall => Désactiver l'analyse de données par IA
p_widgets => Désactiver les widgets
p_wer => Désactiver le rapport d'erreurs
p_feedback => Désactiver les demandes d'avis
p_inventory => Désactiver l'inventaire d'applis et l'Enregistreur d'actions
p_ink => Arrêter la collecte de saisie et d'écriture
p_clip => Désactiver la synchro du presse-papiers cloud
p_location => Désactiver les services de localisation
p_llmnr => Désactiver LLMNR
p_remreg => Désactiver le Registre à distance
p_remote => Désactiver l'Assistance à distance
p_nvtel => Désactiver la télémétrie NVIDIA
p_do => Désactiver le partage de mises à jour (P2P)
q_ext => Afficher les extensions de fichiers
q_hidden => Afficher les fichiers cachés
q_thispc => Ouvrir l'Explorateur sur Ce PC
q_recent => Masquer les fichiers récents et fréquents
q_shake => Désactiver le secouement de fenêtre
q_dark => Mode sombre
q_taskbar => Barre des tâches épurée Windows 11
q_classic => Menu contextuel classique
q_boot => Messages de démarrage détaillés
q_menu => Menus instantanés
q_kb => Répétition rapide du clavier
q_shutdown => Arrêt plus rapide
q_startdelay => Supprimer le délai au démarrage
q_sticky => Désactiver les alertes de touches rémanentes
q_reboot => Bloquer les redémarrages forcés des mises à jour
q_welcome => Ignorer les écrans d'accueil après mise à jour
q_visfx => Effets visuels légers
q_bgapps => Bloquer les applis en arrière-plan
q_search => Désactiver l'indexation de la recherche
f_gamemode => Activer le mode jeu
f_dvr => Désactiver l'enregistrement en arrière-plan
f_overlay => Désactiver la superposition Game Bar
f_power => Mode d'alimentation Performances ultimes
f_usb => Désactiver la suspension sélective USB
f_pcie => Désactiver l'économie d'énergie PCIe
f_diskoff => Ne jamais mettre les disques en veille
f_cpumin => État minimal du processeur à 100 %
f_throttle => Désactiver le bridage énergétique
f_prio => Augmenter la priorité au premier plan
f_mmcss => Planification des jeux (MMCSS)
f_fso => Désactiver les optimisations plein écran
f_mouse => Entrée souris brute
f_hags => Planification GPU (HAGS)
f_mpo => Désactiver Multiplane Overlay (MPO)
f_fast => Désactiver le démarrage rapide
f_sysmain => Désactiver SysMain
f_timerreq => Résolution globale du minuteur
n_nagle => Désactiver l'algorithme de Nagle
n_throttle => Désactiver le bridage réseau
n_qos => Supprimer la réserve de bande passante QoS
n_ports => Réutilisation plus rapide des ports TCP
n_heur => Désactiver l'heuristique TCP
n_dns => DNS rapide (Cloudflare)
n_rsc => Désactiver la fusion de paquets (RSC)
n_lso => Désactiver Large Send Offload
n_nicpwr => Désactiver l'économie d'énergie de la carte réseau
n_eee => Désactiver Green Ethernet / EEE
n_flow => Désactiver le contrôle de flux
n_intmod => Désactiver la modération des interruptions
n_rss => Activer Receive Side Scaling
n_wifi => Wi-Fi en performances maximales
n_netbios => Désactiver NetBIOS sur TCP/IP
n_teredo => Désactiver le tunnel Teredo
w_edge => Arrêter l'activité d'Edge en arrière-plan
w_services => Désactiver les services inutilisés
w_chat => Supprimer l'icône Chat de Teams
w_lastaccess => Désactiver l'heure du dernier accès NTFS
w_8dot3 => Désactiver les noms de fichiers 8.3
w_svchost => Fusionner les processus hôtes de services
w_pagingexec => Garder le noyau en RAM
w_memcomp => Désactiver la compression mémoire
w_prefetch => Désactiver le préchargeur
w_maint => Désactiver la maintenance automatique
w_onedrive => Désactiver la synchronisation OneDrive
w_wudrv => Bloquer les pilotes via Windows Update
w_spooler => Désactiver le spouleur d'impression
a_msi => Mode MSI du GPU
a_tick => Désactiver le tick dynamique
a_hyperv => Désactiver l'hyperviseur
a_xbox => Désactiver les services Xbox
a_ipv6 => Désactiver IPv6
a_spectre => Désactiver les protections du processeur
a_vbs => Désactiver VBS / Intégrité de la mémoire
a_hib => Désactiver l'hibernation
'@
Add-XLang 'fr' 'Français' $xl_fr_ui $xl_fr_tw

$xl_pt_ui = @'
Dashboard => Painel
Tweaks => Ajustes
Games => Jogos
Windows => Windows
Lab => Laboratório
Boost-Up => Boost-Up
Network => Rede
Restore => Restauração
Settings => Configurações
Welcome to SharkOptimizer => Bem-vindo ao SharkOptimizer
CPU USAGE => USO DA CPU
GPU 3D USAGE => USO DA GPU 3D
RAM USAGE => USO DA RAM
Optimizations active => Otimizações ativas
Recommended pending => Recomendadas pendentes
Tweaks available => Ajustes disponíveis
Recommended tweaks applied => Ajustes recomendados aplicados
Presets => Predefinições
Safe Essentials => Essenciais seguros
Competitive => Competitivo
Max Privacy => Privacidade máxima
Low-End PC => PC fraco
Laptop Safe => Seguro para notebook
Apply Recommended => Aplicar recomendados
Create Restore Point => Criar ponto de restauração
Recommended only => Somente recomendados
All => Todos
Privacy & Security => Privacidade e segurança
Quality of Life => Praticidade
FPS & Latency => FPS e latência
Network & Ping => Rede e ping
Windows Optimization => Otimização do Windows
Advanced => Avançado
Select Recommended => Selecionar recomendados
Select Visible => Selecionar visíveis
Clear => Limpar
Undo Selected => Desfazer selecionados
Apply Selected => Aplicar selecionados
SAFE => SEGURO
CAUTION => CUIDADO
CORE WINDOWS CHANGE => ALTERAÇÃO NO NÚCLEO DO WINDOWS
FOR YOUR PC => PARA O SEU PC
RESTART NEEDED => REINÍCIO NECESSÁRIO
Select => Selecionar
ACTIVE => ATIVO
Inactive => Inativo
Details => Detalhes
Scan for Games => Procurar jogos
Installed => Instalado
Not detected => Não detectado
Profile active => Perfil ativo
INSTALLED => INSTALADO
NOT DETECTED => NÃO DETECTADO
PROFILE ACTIVE => PERFIL ATIVO
Recommended Windows tweaks => Ajustes do Windows recomendados
In-game tips => Dicas no jogo
Launch options => Opções de inicialização
Copy => Copiar
Undo Game Settings => Desfazer ajustes do jogo
Open Folder => Abrir pasta
Add Game => Adicionar jogo
Remove from list => Remover da lista
Quick Tools => Ferramentas rápidas
Startup Apps => Aplicativos de inicialização
Refresh => Atualizar
Remove Built-in Apps => Remover aplicativos integrados
Remove Selected => Remover selecionados
Close Heavy Apps => Fechar apps pesados
Close Selected => Fechar selecionados
System File Check => Verificar arquivos do sistema
DISM Repair => Reparo DISM
Check Disk (scan) => Verificar disco (varredura)
Reset Windows Update => Redefinir o Windows Update
Rebuild Icon Cache => Recriar cache de ícones
Restart Explorer => Reiniciar o Explorador
Disk Cleanup => Limpeza de disco
Power Options => Opções de energia
Services => Serviços
Task Manager => Gerenciador de tarefas
Run All => Executar tudo
Run => Executar
Not run yet => Ainda não executado
Not needed on this PC => Desnecessário neste PC
Junk Cleaner => Limpador de lixo
Optimize Drives => Otimizar unidades
Clean Recent Documents => Limpar documentos recentes
Clean Thumbnail Cache => Limpar cache de miniaturas
Clean Font Cache => Limpar cache de fontes
Clear Shader Caches => Limpar caches de shaders
Clean Browser Caches => Limpar caches do navegador
Trim Process RAM => Liberar RAM dos processos
Flush DNS Cache => Limpar cache DNS
Test Regions => Testar regiões
Test Host => Testar host
DNS Benchmark => Teste de DNS
Apply Best DNS => Aplicar o melhor DNS
Flush DNS => Limpar DNS
Undo All Tweaks => Desfazer todos os ajustes
Open Log => Abrir registro
Currently applied => Aplicado atualmente
Nothing applied yet. => Nada aplicado ainda.
Before and after benchmark => Medição antes e depois
Run BEFORE => Medir ANTES
Run AFTER => Medir DEPOIS
Clear Results => Limpar resultados
Game Mode => Modo jogo
Start Game Mode => Iniciar modo jogo
End Game Mode => Encerrar modo jogo
Refresh Lists => Atualizar listas
Game Mode is off. => O modo jogo está desligado.
System check => Verificação do sistema
Run System Check => Verificar o sistema
Verify applied tweaks => Verificar ajustes aplicados
Verify Now => Verificar agora
Re-apply Drifted => Reaplicar revertidos
Profiles and safe apply => Perfis e aplicação segura
Export Profile => Exportar perfil
Import Profile => Importar perfil
Guided Apply (selected tweaks) => Aplicação guiada (selecionados)
Reset to Windows Defaults => Restaurar padrões do Windows
Network tools => Ferramentas de rede
Start Live Ping => Iniciar ping ao vivo
Stop => Parar
Traceroute => Traceroute
Scan Wi-Fi Channels => Analisar canais Wi-Fi
Language => Idioma
Behaviour => Comportamento
Show pop-up notifications => Mostrar notificações pop-up
Show the activity log => Mostrar o registro de atividades
Scan for games when SharkOptimizer starts => Procurar jogos ao iniciar o SharkOptimizer
Help and data => Ajuda e dados
Show the guide again => Mostrar o guia novamente
Open data folder => Abrir pasta de dados
Open log file => Abrir arquivo de registro
Clear saved game scan => Limpar busca de jogos salva
Reset settings => Redefinir configurações
About => Sobre
Appearance => Aparência
Blue => Azul
Green => Verde
Purple => Roxo
Orange => Laranja
Scheduled cleanup => Limpeza agendada
Enable weekly cleanup => Ativar limpeza semanal
Disable weekly cleanup => Desativar limpeza semanal
Run it now => Executar agora
My Presets => Minhas predefinições
Save current selection => Salvar seleção atual
Import code => Importar código
Use => Usar
Copy code => Copiar código
Delete => Excluir
No presets yet. => Nenhuma predefinição ainda.
Copy System Report => Copiar relatório do sistema
Guide  (how to use) => Guia (como usar)
Close => Fechar
Back => Voltar
Next => Avançar
Finish => Concluir
Save => Salvar
Check now => Verificar agora
Cancel => Cancelar
Monday => Segunda-feira
Tuesday => Terça-feira
Wednesday => Quarta-feira
Thursday => Quinta-feira
Friday => Sexta-feira
Saturday => Sábado
Sunday => Domingo
selected => selecionados
Pending => Pendente
Unavailable => Indisponível
Optimize for => Otimizar para
'@
$xl_pt_tw = @'
p_telemetry => Desativar telemetria
p_tasks => Desativar tarefas de telemetria
p_adid => Desativar ID de publicidade
p_bing => Desativar pesquisa na web no Iniciar
p_cortana => Desativar Cortana e pesquisa na nuvem
p_activity => Desativar histórico de atividades
p_ads => Remover anúncios do Windows
p_consumer => Bloquear recursos de consumo
p_copilot => Desativar Copilot
p_recall => Desativar análise de dados por IA
p_widgets => Desativar Widgets
p_wer => Desativar relatório de erros
p_feedback => Desativar pedidos de feedback
p_inventory => Desativar inventário de apps e Gravador de passos
p_ink => Parar coleta de digitação e escrita à mão
p_clip => Desativar sincronização da área de transferência
p_location => Desativar serviços de localização
p_llmnr => Desativar LLMNR
p_remreg => Desativar Registro remoto
p_remote => Desativar Assistência remota
p_nvtel => Desativar telemetria da NVIDIA
p_do => Desativar compartilhamento de atualizações (P2P)
q_ext => Mostrar extensões de arquivo
q_hidden => Mostrar arquivos ocultos
q_thispc => Abrir o Explorador em Este Computador
q_recent => Ocultar arquivos recentes e frequentes
q_shake => Desativar agitar janelas
q_dark => Modo escuro
q_taskbar => Barra de tarefas limpa do Windows 11
q_classic => Menu de contexto clássico
q_boot => Mensagens de inicialização detalhadas
q_menu => Menus instantâneos
q_kb => Repetição rápida do teclado
q_shutdown => Desligamento mais rápido
q_startdelay => Remover atraso de inicialização
q_sticky => Desativar avisos de teclas de aderência
q_reboot => Bloquear reinícios forçados por atualizações
q_welcome => Pular telas de boas-vindas após atualizações
q_visfx => Efeitos visuais leves
q_bgapps => Bloquear apps em segundo plano
q_search => Desativar indexação de pesquisa
f_gamemode => Ativar Modo jogo
f_dvr => Desativar gravação em segundo plano
f_overlay => Desativar sobreposição da Game Bar
f_power => Plano de energia Desempenho máximo
f_usb => Desativar suspensão seletiva de USB
f_pcie => Desativar economia de energia PCIe
f_diskoff => Nunca suspender discos rígidos
f_cpumin => Estado mínimo da CPU em 100%
f_throttle => Desativar limitação de energia
f_prio => Aumentar prioridade em primeiro plano
f_mmcss => Agendamento de jogos (MMCSS)
f_fso => Desativar otimizações de tela cheia
f_mouse => Entrada bruta do mouse
f_hags => Agendamento da GPU (HAGS)
f_mpo => Desativar Multiplane Overlay (MPO)
f_fast => Desativar inicialização rápida
f_sysmain => Desativar SysMain
f_timerreq => Resolução global do temporizador
n_nagle => Desativar algoritmo de Nagle
n_throttle => Desativar limitação de rede
n_qos => Remover reserva de banda QoS
n_ports => Reutilização mais rápida de portas TCP
n_heur => Desativar heurística TCP
n_dns => DNS rápido (Cloudflare)
n_rsc => Desativar coalescência de pacotes (RSC)
n_lso => Desativar Large Send Offload
n_nicpwr => Desativar economia de energia do adaptador
n_eee => Desativar Green Ethernet / EEE
n_flow => Desativar controle de fluxo
n_intmod => Desativar moderação de interrupções
n_rss => Ativar Receive Side Scaling
n_wifi => Wi-Fi em desempenho máximo
n_netbios => Desativar NetBIOS sobre TCP/IP
n_teredo => Desativar túnel Teredo
w_edge => Parar atividade do Edge em segundo plano
w_services => Desativar serviços não usados
w_chat => Remover ícone do Chat do Teams
w_lastaccess => Desativar último acesso do NTFS
w_8dot3 => Desativar nomes de arquivo 8.3
w_svchost => Unir processos de host de serviços
w_pagingexec => Manter o kernel na RAM
w_memcomp => Desativar compressão de memória
w_prefetch => Desativar Prefetcher
w_maint => Desativar manutenção automática
w_onedrive => Desativar sincronização do OneDrive
w_wudrv => Bloquear drivers pelo Windows Update
w_spooler => Desativar spooler de impressão
a_msi => Modo MSI da GPU
a_tick => Desativar tick dinâmico
a_hyperv => Desativar hipervisor
a_xbox => Desativar serviços do Xbox
a_ipv6 => Desativar IPv6
a_spectre => Desativar mitigações da CPU
a_vbs => Desativar VBS / Integridade da memória
a_hib => Desativar hibernação
'@
Add-XLang 'pt' 'Português (Brasil)' $xl_pt_ui $xl_pt_tw

$xl_ru_ui = @'
Dashboard => Главная
Tweaks => Твики
Games => Игры
Windows => Windows
Lab => Лаборатория
Boost-Up => Boost-Up
Network => Сеть
Restore => Восстановление
Settings => Настройки
Welcome to SharkOptimizer => Добро пожаловать в SharkOptimizer
CPU USAGE => ЗАГРУЗКА ЦП
GPU 3D USAGE => ЗАГРУЗКА GPU 3D
RAM USAGE => ЗАГРУЗКА ОЗУ
Optimizations active => Активные оптимизации
Recommended pending => Рекомендуемых осталось
Tweaks available => Доступно твиков
Recommended tweaks applied => Применённые рекомендации
Presets => Пресеты
Safe Essentials => Безопасная база
Competitive => Соревновательный
Max Privacy => Макс. приватность
Low-End PC => Слабый ПК
Laptop Safe => Для ноутбуков
Apply Recommended => Применить рекомендуемые
Create Restore Point => Создать точку восстановления
Recommended only => Только рекомендуемые
All => Все
Privacy & Security => Приватность и безопасность
Quality of Life => Удобство
FPS & Latency => FPS и задержка
Network & Ping => Сеть и пинг
Windows Optimization => Оптимизация Windows
Advanced => Дополнительно
Select Recommended => Выбрать рекомендуемые
Select Visible => Выбрать видимые
Clear => Сбросить
Undo Selected => Отменить выбранные
Apply Selected => Применить выбранные
SAFE => БЕЗОПАСНО
CAUTION => ВНИМАНИЕ
CORE WINDOWS CHANGE => ИЗМЕНЕНИЕ ЯДРА WINDOWS
FOR YOUR PC => ДЛЯ ВАШЕГО ПК
RESTART NEEDED => НУЖНА ПЕРЕЗАГРУЗКА
Select => Выбрать
ACTIVE => АКТИВНО
Inactive => Неактивно
Details => Подробнее
Scan for Games => Найти игры
Installed => Установлена
Not detected => Не найдена
Profile active => Профиль активен
INSTALLED => УСТАНОВЛЕНА
NOT DETECTED => НЕ НАЙДЕНА
PROFILE ACTIVE => ПРОФИЛЬ АКТИВЕН
Recommended Windows tweaks => Рекомендуемые твики Windows
In-game tips => Советы для игры
Launch options => Параметры запуска
Copy => Копировать
Undo Game Settings => Отменить настройки игры
Open Folder => Открыть папку
Add Game => Добавить игру
Remove from list => Убрать из списка
Quick Tools => Быстрые инструменты
Startup Apps => Автозагрузка
Refresh => Обновить
Remove Built-in Apps => Удалить встроенные приложения
Remove Selected => Удалить выбранные
Close Heavy Apps => Закрыть тяжёлые приложения
Close Selected => Закрыть выбранные
System File Check => Проверка системных файлов
DISM Repair => Восстановление DISM
Check Disk (scan) => Проверка диска (сканирование)
Reset Windows Update => Сбросить Центр обновления
Rebuild Icon Cache => Пересоздать кэш значков
Restart Explorer => Перезапустить Проводник
Disk Cleanup => Очистка диска
Power Options => Электропитание
Services => Службы
Task Manager => Диспетчер задач
Run All => Запустить всё
Run => Запустить
Not run yet => Ещё не запускалось
Not needed on this PC => Не нужно на этом ПК
Junk Cleaner => Очистка мусора
Optimize Drives => Оптимизация дисков
Clean Recent Documents => Очистить недавние документы
Clean Thumbnail Cache => Очистить кэш эскизов
Clean Font Cache => Очистить кэш шрифтов
Clear Shader Caches => Очистить кэш шейдеров
Clean Browser Caches => Очистить кэш браузеров
Trim Process RAM => Освободить ОЗУ процессов
Flush DNS Cache => Очистить кэш DNS
Test Regions => Проверить регионы
Test Host => Проверить хост
DNS Benchmark => Тест DNS
Apply Best DNS => Применить лучший DNS
Flush DNS => Очистить DNS
Undo All Tweaks => Отменить все твики
Open Log => Открыть журнал
Currently applied => Сейчас применено
Nothing applied yet. => Пока ничего не применено.
Before and after benchmark => Замер до и после
Run BEFORE => Замер ДО
Run AFTER => Замер ПОСЛЕ
Clear Results => Очистить результаты
Game Mode => Игровой режим
Start Game Mode => Включить игровой режим
End Game Mode => Выключить игровой режим
Refresh Lists => Обновить списки
Game Mode is off. => Игровой режим выключен.
System check => Проверка системы
Run System Check => Проверить систему
Verify applied tweaks => Проверка применённых твиков
Verify Now => Проверить сейчас
Re-apply Drifted => Применить сброшенные снова
Profiles and safe apply => Профили и безопасное применение
Export Profile => Экспорт профиля
Import Profile => Импорт профиля
Guided Apply (selected tweaks) => Пошаговое применение (выбранные)
Reset to Windows Defaults => Вернуть настройки Windows
Network tools => Сетевые инструменты
Start Live Ping => Запустить живой пинг
Stop => Стоп
Traceroute => Трассировка
Scan Wi-Fi Channels => Сканировать каналы Wi-Fi
Language => Язык
Behaviour => Поведение
Show pop-up notifications => Показывать всплывающие уведомления
Show the activity log => Показывать журнал действий
Scan for games when SharkOptimizer starts => Искать игры при запуске SharkOptimizer
Help and data => Справка и данные
Show the guide again => Показать руководство снова
Open data folder => Открыть папку данных
Open log file => Открыть файл журнала
Clear saved game scan => Очистить сохранённый поиск игр
Reset settings => Сбросить настройки
About => О программе
Appearance => Оформление
Blue => Синий
Green => Зелёный
Purple => Фиолетовый
Orange => Оранжевый
Scheduled cleanup => Очистка по расписанию
Enable weekly cleanup => Включить еженедельную очистку
Disable weekly cleanup => Выключить еженедельную очистку
Run it now => Запустить сейчас
My Presets => Мои пресеты
Save current selection => Сохранить текущий выбор
Import code => Импорт кода
Use => Применить
Copy code => Копировать код
Delete => Удалить
No presets yet. => Пресетов пока нет.
Copy System Report => Копировать отчёт о системе
Guide  (how to use) => Руководство (как пользоваться)
Close => Закрыть
Back => Назад
Next => Далее
Finish => Готово
Save => Сохранить
Check now => Проверить сейчас
Cancel => Отмена
Monday => Понедельник
Tuesday => Вторник
Wednesday => Среда
Thursday => Четверг
Friday => Пятница
Saturday => Суббота
Sunday => Воскресенье
selected => выбрано
Pending => Ожидает
Unavailable => Недоступно
Optimize for => Оптимизировать для
'@
$xl_ru_tw = @'
p_telemetry => Отключить телеметрию
p_tasks => Отключить задачи телеметрии
p_adid => Отключить рекламный идентификатор
p_bing => Отключить веб-поиск в меню «Пуск»
p_cortana => Отключить Cortana и облачный поиск
p_activity => Отключить журнал действий
p_ads => Убрать рекламу Windows
p_consumer => Заблокировать потребительские функции
p_copilot => Отключить Copilot
p_recall => Отключить ИИ-анализ данных Windows
p_widgets => Отключить виджеты
p_wer => Отключить отчёты об ошибках
p_feedback => Отключить запросы отзывов
p_inventory => Отключить инвентаризацию приложений и запись действий
p_ink => Остановить сбор данных ввода и рукописного текста
p_clip => Отключить облачную синхронизацию буфера обмена
p_location => Отключить службы определения местоположения
p_llmnr => Отключить LLMNR
p_remreg => Отключить удалённый реестр
p_remote => Отключить удалённого помощника
p_nvtel => Отключить телеметрию NVIDIA
p_do => Отключить раздачу обновлений (P2P)
q_ext => Показывать расширения файлов
q_hidden => Показывать скрытые файлы
q_thispc => Открывать Проводник на «Этот компьютер»
q_recent => Скрыть недавние и частые файлы
q_shake => Отключить встряхивание окон
q_dark => Тёмная тема
q_taskbar => Чистая панель задач Windows 11
q_classic => Классическое контекстное меню
q_boot => Подробные сообщения при загрузке
q_menu => Мгновенные меню
q_kb => Быстрое повторение клавиш
q_shutdown => Быстрое завершение работы
q_startdelay => Убрать задержку автозапуска
q_sticky => Отключить окна залипания клавиш
q_reboot => Запретить принудительные перезагрузки для обновлений
q_welcome => Пропускать экраны приветствия после обновлений
q_visfx => Лёгкие визуальные эффекты
q_bgapps => Заблокировать фоновые приложения
q_search => Отключить индексацию поиска
f_gamemode => Включить игровой режим
f_dvr => Отключить фоновую запись
f_overlay => Отключить оверлей Game Bar
f_power => План питания «Максимальная производительность»
f_usb => Отключить выборочную приостановку USB
f_pcie => Отключить энергосбережение PCIe
f_diskoff => Никогда не отключать жёсткие диски
f_cpumin => Минимальное состояние ЦП 100%
f_throttle => Отключить энергетическое троттлинг
f_prio => Повысить приоритет переднего плана
f_mmcss => Планирование игр (MMCSS)
f_fso => Отключить оптимизацию полноэкранного режима
f_mouse => Необработанный ввод мыши
f_hags => Планирование GPU (HAGS)
f_mpo => Отключить Multiplane Overlay (MPO)
f_fast => Отключить быстрый запуск
f_sysmain => Отключить SysMain
f_timerreq => Глобальное разрешение таймера
n_nagle => Отключить алгоритм Нейгла
n_throttle => Отключить сетевой троттлинг
n_qos => Убрать резерв пропускной способности QoS
n_ports => Быстрое повторное использование TCP-портов
n_heur => Отключить эвристику TCP
n_dns => Быстрый DNS (Cloudflare)
n_rsc => Отключить объединение пакетов (RSC)
n_lso => Отключить Large Send Offload
n_nicpwr => Отключить энергосбережение адаптера
n_eee => Отключить Green Ethernet / EEE
n_flow => Отключить управление потоком
n_intmod => Отключить модерацию прерываний
n_rss => Включить Receive Side Scaling
n_wifi => Wi-Fi на максимальной производительности
n_netbios => Отключить NetBIOS через TCP/IP
n_teredo => Отключить туннель Teredo
w_edge => Остановить фоновую работу Edge
w_services => Отключить неиспользуемые службы
w_chat => Убрать значок чата Teams
w_lastaccess => Отключить обновление времени доступа NTFS
w_8dot3 => Отключить имена файлов 8.3
w_svchost => Объединить процессы-хосты служб
w_pagingexec => Держать ядро в ОЗУ
w_memcomp => Отключить сжатие памяти
w_prefetch => Отключить Prefetcher
w_maint => Отключить автоматическое обслуживание
w_onedrive => Отключить синхронизацию OneDrive
w_wudrv => Блокировать драйверы из Центра обновления
w_spooler => Отключить диспетчер печати
a_msi => Режим MSI для GPU
a_tick => Отключить динамический тик
a_hyperv => Выключить гипервизор
a_xbox => Отключить службы Xbox
a_ipv6 => Отключить IPv6
a_spectre => Отключить защиту ЦП от уязвимостей
a_vbs => Отключить VBS / Целостность памяти
a_hib => Отключить гибернацию
'@
Add-XLang 'ru' 'Русский' $xl_ru_ui $xl_ru_tw

$xl_zh_ui = @'
Dashboard => 仪表盘
Tweaks => 优化项
Games => 游戏
Windows => Windows
Lab => 实验室
Boost-Up => 加速清理
Network => 网络
Restore => 还原
Settings => 设置
Welcome to SharkOptimizer => 欢迎使用 SharkOptimizer
CPU USAGE => CPU 使用率
GPU 3D USAGE => GPU 3D 使用率
RAM USAGE => 内存使用率
Optimizations active => 已启用的优化
Recommended pending => 待应用的推荐项
Tweaks available => 可用优化项
Recommended tweaks applied => 已应用的推荐调整
Presets => 预设
Safe Essentials => 安全基础
Competitive => 竞技
Max Privacy => 最强隐私
Low-End PC => 低配电脑
Laptop Safe => 笔记本安全
Apply Recommended => 应用推荐项
Create Restore Point => 创建还原点
Recommended only => 仅推荐
All => 全部
Privacy & Security => 隐私与安全
Quality of Life => 使用便利
FPS & Latency => 帧率与延迟
Network & Ping => 网络与延迟
Windows Optimization => Windows 优化
Advanced => 高级
Select Recommended => 选择推荐项
Select Visible => 选择可见项
Clear => 清除
Undo Selected => 撤销所选
Apply Selected => 应用所选
SAFE => 安全
CAUTION => 注意
CORE WINDOWS CHANGE => 修改 WINDOWS 核心设置
FOR YOUR PC => 适合你的电脑
RESTART NEEDED => 需要重启
Select => 选择
ACTIVE => 已启用
Inactive => 未启用
Details => 详情
Scan for Games => 扫描游戏
Installed => 已安装
Not detected => 未检测到
Profile active => 配置已启用
INSTALLED => 已安装
NOT DETECTED => 未检测到
PROFILE ACTIVE => 配置已启用
Recommended Windows tweaks => 推荐的 Windows 优化项
In-game tips => 游戏内建议
Launch options => 启动选项
Copy => 复制
Undo Game Settings => 撤销游戏设置
Open Folder => 打开文件夹
Add Game => 添加游戏
Remove from list => 从列表移除
Quick Tools => 快捷工具
Startup Apps => 启动项
Refresh => 刷新
Remove Built-in Apps => 卸载内置应用
Remove Selected => 移除所选
Close Heavy Apps => 关闭高占用应用
Close Selected => 关闭所选
System File Check => 系统文件检查
DISM Repair => DISM 修复
Check Disk (scan) => 磁盘检查（扫描）
Reset Windows Update => 重置 Windows 更新
Rebuild Icon Cache => 重建图标缓存
Restart Explorer => 重启资源管理器
Disk Cleanup => 磁盘清理
Power Options => 电源选项
Services => 服务
Task Manager => 任务管理器
Run All => 全部运行
Run => 运行
Not run yet => 尚未运行
Not needed on this PC => 此电脑无需
Junk Cleaner => 垃圾清理
Optimize Drives => 优化驱动器
Clean Recent Documents => 清除最近文档
Clean Thumbnail Cache => 清除缩略图缓存
Clean Font Cache => 清除字体缓存
Clear Shader Caches => 清除着色器缓存
Clean Browser Caches => 清除浏览器缓存
Trim Process RAM => 释放进程内存
Flush DNS Cache => 清空 DNS 缓存
Test Regions => 测试区域
Test Host => 测试主机
DNS Benchmark => DNS 测速
Apply Best DNS => 应用最快 DNS
Flush DNS => 清空 DNS
Undo All Tweaks => 撤销全部优化
Open Log => 打开日志
Currently applied => 当前已应用
Nothing applied yet. => 尚未应用任何内容。
Before and after benchmark => 前后对比测试
Run BEFORE => 优化前测试
Run AFTER => 优化后测试
Clear Results => 清除结果
Game Mode => 游戏模式
Start Game Mode => 启动游戏模式
End Game Mode => 结束游戏模式
Refresh Lists => 刷新列表
Game Mode is off. => 游戏模式已关闭。
System check => 系统检查
Run System Check => 运行系统检查
Verify applied tweaks => 验证已应用的优化
Verify Now => 立即验证
Re-apply Drifted => 重新应用被还原项
Profiles and safe apply => 配置与安全应用
Export Profile => 导出配置
Import Profile => 导入配置
Guided Apply (selected tweaks) => 分步应用（所选）
Reset to Windows Defaults => 恢复 Windows 默认
Network tools => 网络工具
Start Live Ping => 开始实时 Ping
Stop => 停止
Traceroute => 路由追踪
Scan Wi-Fi Channels => 扫描 Wi-Fi 信道
Language => 语言
Behaviour => 行为
Show pop-up notifications => 显示弹出通知
Show the activity log => 显示活动日志
Scan for games when SharkOptimizer starts => 启动时扫描游戏
Help and data => 帮助与数据
Show the guide again => 再次显示指南
Open data folder => 打开数据文件夹
Open log file => 打开日志文件
Clear saved game scan => 清除已保存的游戏扫描
Reset settings => 重置设置
About => 关于
Appearance => 外观
Blue => 蓝色
Green => 绿色
Purple => 紫色
Orange => 橙色
Scheduled cleanup => 定时清理
Enable weekly cleanup => 启用每周清理
Disable weekly cleanup => 关闭每周清理
Run it now => 立即运行
My Presets => 我的预设
Save current selection => 保存当前选择
Import code => 导入代码
Use => 使用
Copy code => 复制代码
Delete => 删除
No presets yet. => 还没有预设。
Copy System Report => 复制系统报告
Guide  (how to use) => 指南（使用方法）
Close => 关闭
Back => 返回
Next => 下一步
Finish => 完成
Save => 保存
Check now => 立即检查
Cancel => 取消
Monday => 星期一
Tuesday => 星期二
Wednesday => 星期三
Thursday => 星期四
Friday => 星期五
Saturday => 星期六
Sunday => 星期日
selected => 已选择
Pending => 待处理
Unavailable => 不可用
Optimize for => 优化：
'@
$xl_zh_tw = @'
p_telemetry => 禁用遥测
p_tasks => 禁用遥测计划任务
p_adid => 禁用广告 ID
p_bing => 禁用开始菜单网页搜索
p_cortana => 禁用 Cortana 和云搜索
p_activity => 禁用活动历史记录
p_ads => 移除 Windows 广告
p_consumer => 阻止消费者体验功能
p_copilot => 禁用 Copilot
p_recall => 禁用 Windows AI 数据分析
p_widgets => 禁用小组件
p_wer => 禁用错误报告
p_feedback => 禁用反馈提示
p_inventory => 禁用应用清单与问题步骤记录器
p_ink => 停止收集键入和墨迹数据
p_clip => 禁用剪贴板云同步
p_location => 禁用位置服务
p_llmnr => 禁用 LLMNR
p_remreg => 禁用远程注册表
p_remote => 禁用远程协助
p_nvtel => 禁用 NVIDIA 遥测
p_do => 禁用更新共享（P2P）
q_ext => 显示文件扩展名
q_hidden => 显示隐藏文件
q_thispc => 资源管理器默认打开“此电脑”
q_recent => 隐藏最近和常用文件
q_shake => 禁用晃动窗口最小化
q_dark => 深色模式
q_taskbar => 简洁的 Windows 11 任务栏
q_classic => 经典右键菜单
q_boot => 详细启动信息
q_menu => 菜单即时弹出
q_kb => 快速键盘重复
q_shutdown => 更快关机
q_startdelay => 移除启动项延迟
q_sticky => 禁用粘滞键弹窗
q_reboot => 阻止更新强制重启
q_welcome => 跳过更新后的欢迎页面
q_visfx => 轻量视觉效果
q_bgapps => 阻止后台应用
q_search => 禁用搜索索引
f_gamemode => 启用游戏模式
f_dvr => 禁用后台录制
f_overlay => 禁用 Game Bar 悬浮窗
f_power => 卓越性能电源计划
f_usb => 禁用 USB 选择性暂停
f_pcie => 禁用 PCIe 节能
f_diskoff => 硬盘永不休眠
f_cpumin => CPU 最小状态 100%
f_throttle => 禁用电源节流
f_prio => 提高前台优先级
f_mmcss => 游戏调度（MMCSS）
f_fso => 禁用全屏优化
f_mouse => 原始鼠标输入
f_hags => GPU 硬件加速调度（HAGS）
f_mpo => 禁用多平面叠加（MPO）
f_fast => 禁用快速启动
f_sysmain => 禁用 SysMain
f_timerreq => 全局计时器分辨率
n_nagle => 禁用 Nagle 算法
n_throttle => 禁用网络节流
n_qos => 移除 QoS 带宽预留
n_ports => 更快复用 TCP 端口
n_heur => 禁用 TCP 启发式
n_dns => 快速 DNS（Cloudflare）
n_rsc => 禁用数据包合并（RSC）
n_lso => 禁用大型发送卸载
n_nicpwr => 禁用网卡节能
n_eee => 禁用绿色以太网 / EEE
n_flow => 禁用流量控制
n_intmod => 禁用中断调节
n_rss => 启用接收端缩放
n_wifi => Wi-Fi 最高性能
n_netbios => 禁用 TCP/IP 上的 NetBIOS
n_teredo => 禁用 Teredo 隧道
w_edge => 停止 Edge 后台活动
w_services => 禁用未使用的服务
w_chat => 移除 Teams 聊天图标
w_lastaccess => 禁用 NTFS 最后访问时间更新
w_8dot3 => 禁用 8.3 短文件名
w_svchost => 合并服务主机进程
w_pagingexec => 让内核常驻内存
w_memcomp => 禁用内存压缩
w_prefetch => 禁用预取
w_maint => 禁用自动维护
w_onedrive => 禁用 OneDrive 同步
w_wudrv => 阻止通过 Windows 更新安装驱动
w_spooler => 禁用打印后台处理程序
a_msi => GPU MSI 模式
a_tick => 禁用动态时钟
a_hyperv => 关闭虚拟机监控程序
a_xbox => 禁用 Xbox 服务
a_ipv6 => 禁用 IPv6
a_spectre => 禁用 CPU 安全缓解
a_vbs => 禁用 VBS / 内存完整性
a_hib => 禁用休眠
'@
Add-XLang 'zh' '简体中文' $xl_zh_ui $xl_zh_tw

# keep the Dutch dictionary so it can be restored
$script:NLBackup = @{}; foreach ($k in @($NL.Keys)) { $script:NLBackup[$k] = $NL[$k] }
$script:NLRulesBackup = $NLRules
function Restore-NlDict { $NL.Clear(); foreach ($k in @($script:NLBackup.Keys)) { $NL[$k] = $script:NLBackup[$k] }; $script:NLRules = $script:NLRulesBackup }

# translate whenever any language other than English is active
function Translate-Now($root) { if ($script:Lang -ne 'en' -and $root) { try { Walk-Tree $root } catch {} } }

function Build-XRules($u) {
    @(
        @('^(\d+) selected$', '$1 ' + $u['selected']),
        @('^Apply Selected \((\d+)\)$', $u['Apply Selected'] + ' ($1)'),
        @('^Optimize for (.+)$', $u['Optimize for'] + ' $1'),
        @('^ACTIVE(\s{5})(.+)$', $u['ACTIVE'] + '$1$2'),
        @('^Pending(\s{4})(.+)$', $u['Pending'] + '$1$2'),
        @('^Unavailable(\s{2})(.+)$', $u['Unavailable'] + '$1$2')
    )
}

$script:OrigSetLanguage2 = ${function:Set-Language}
function Set-Language($lang) {
    if ($lang -eq 'en' -or $lang -eq 'nl' -or -not $script:XLangs.Contains($lang)) {
        if ($script:XLang) { Restore-NlDict }
        $script:XLang = $null
        & $script:OrigSetLanguage2 $lang
        try { Refresh-LangButtons } catch {}
        return
    }
    & $script:OrigSetLanguage2 'en'
    $d = $script:XLangs[$lang]
    $script:XLang = $lang; $script:Lang = $lang; $Settings.Language = $lang; Save-Settings
    $NL.Clear(); foreach ($k in @($d.UI.Keys)) { $NL[$k] = $d.UI[$k] }
    $script:NLRules = Build-XRules $d.UI
    foreach ($t in $Tweaks) { if ($d.Tw.ContainsKey($t.Id)) { $t.Name = $d.Tw[$t.Id] } }
    if ($PageInfo -and $script:PageEn) {
        foreach ($k in @($script:PageEn.Keys)) {
            $en = $script:PageEn[$k]; $tr = $d.UI[[string]$en[0]]
            $PageInfo[$k] = @($(if ($tr) { $tr } else { $en[0] }), $en[1])
        }
    }
    try { Walk-Tree $window } catch {}
    try { Render-Tweaks } catch {}
    try { Render-GameList; if ($script:CurGame) { Show-Game $script:CurGame } } catch {}
    try { Update-Stats } catch {}
    try { if ($script:CurNav) { Update-ProChrome } } catch {}
    try { Refresh-LangButtons } catch {}
    if ($script:GuideWin -and $script:GuideWin.IsVisible) { try { Render-Slide; Translate-Now $script:GuideWin } catch {} }
}

$script:OrigUS4 = ${function:Update-Stats}
function Update-Stats {
    & $script:OrigUS4
    if ($script:XLang) {
        try {
            foreach ($tb in $ui.txtSel, $ui.txtApplied) { $nl = Get-Nl $tb.Text; if ($nl) { $tb.Text = $nl } }
            if ($script:hdrApply) { $nl = Get-Nl ([string]$script:hdrApply.Content); if ($nl) { $script:hdrApply.Content = $nl } }
        } catch {}
    }
}
$script:OrigShowPage3 = ${function:Show-Page}
function Show-Page($nav) {
    & $script:OrigShowPage3 $nav
    if ($script:XLang) { try { if ($script:hdrApply) { $nl = Get-Nl ([string]$script:hdrApply.Content); if ($nl) { $script:hdrApply.Content = $nl } } } catch {} }
}

# ---- language buttons in Settings, and a language picker in the header
$script:xLangBtns = @()
function Refresh-LangButtons {
    $cur = $script:Lang
    foreach ($pair in @(@($script:btnEn, 'en'), @($script:btnNl, 'nl'))) {
        $b = $pair[0]; if (-not $b) { continue }
        $on = ($cur -eq $pair[1])
        $b.Background = Brush $(if ($on) { '#1FB6FF' } else { '#16233A' }); $b.Foreground = Brush $(if ($on) { '#06121F' } else { '#E8ECF4' })
    }
    foreach ($b in @($script:xLangBtns)) {
        $on = ($cur -eq [string]$b.Tag)
        $b.Background = Brush $(if ($on) { '#1FB6FF' } else { '#16233A' }); $b.Foreground = Brush $(if ($on) { '#06121F' } else { '#E8ECF4' })
    }
    if ($script:hdrLang) { $script:hdrLang.Content = ([string]$cur).ToUpper() }
}
function Choose-Language($code) { $Settings.LangChosen = $true; Save-Settings; Set-Language $code }
try {
    if ($script:btnEn -and $script:btnEn.Parent) {
        $row = $script:btnEn.Parent
        foreach ($code in @($script:XLangs.Keys)) {
            $b = New-Object Windows.Controls.Button; $b.Content = $script:XLangs[$code].Native; $b.Tag = $code; $b.Padding = '18,9'
            $b.Add_Click({ Choose-Language ([string]$this.Tag) })
            $row.Children.Add($b) | Out-Null; $script:xLangBtns += $b
        }
        $script:btnEn.Add_Click({ $Settings.LangChosen = $true; Save-Settings })
        $script:btnNl.Add_Click({ $Settings.LangChosen = $true; Save-Settings })
    }
} catch {}

function Show-LangPicker($anchor) {
    $w = New-Object Windows.Window; $w.WindowStyle = 'None'; $w.ResizeMode = 'NoResize'; $w.ShowInTaskbar = $false; $w.Topmost = $true
    $w.SizeToContent = 'WidthAndHeight'; $w.Background = Brush '#0B1424'; $w.Owner = $window
    $border = New-Object Windows.Controls.Border; $border.BorderBrush = Brush '#1FB6FF'; $border.BorderThickness = 1; $border.Padding = '6'; $border.CornerRadius = 10
    $sp = New-Object Windows.Controls.StackPanel
    $items = @(@('en', 'English'), @('nl', 'Nederlands'))
    foreach ($code in @($script:XLangs.Keys)) { $items += , @($code, $script:XLangs[$code].Native) }
    foreach ($it in $items) {
        $b = New-Object Windows.Controls.Button; $b.Content = $it[1]; $b.Tag = $it[0]; $b.Padding = '16,8'; $b.Margin = '2'; $b.MinWidth = 170; $b.HorizontalContentAlignment = 'Left'
        if ($it[0] -eq $script:Lang) { $b.Background = Brush '#10304A'; $b.Foreground = Brush '#1FB6FF' }
        $b.Add_Click({ $c = [string]$this.Tag; $script:lpWin.Close(); Choose-Language $c })
        $sp.Children.Add($b) | Out-Null
    }
    $border.Child = $sp; $w.Content = $border; $script:lpWin = $w
    $w.WindowStartupLocation = 'Manual'
    try {
        $pt = $anchor.PointToScreen(([Windows.Point]::new(0, $anchor.ActualHeight + 4)))
        $src = [Windows.PresentationSource]::FromVisual($anchor)
        $dip = $src.CompositionTarget.TransformFromDevice.Transform($pt)
        $w.Left = [math]::Max(0, $dip.X - 110); $w.Top = $dip.Y
    } catch { $w.WindowStartupLocation = 'CenterOwner' }
    $w.Add_Deactivated({ try { $script:lpWin.Close() } catch {} })
    $w.Show()
}
try {
    if ($script:hdrLang -and $script:hdrLang.Parent) {
        $bar = $script:hdrLang.Parent; $i = $bar.Children.IndexOf($script:hdrLang)
        $new = New-Object Windows.Controls.Button; $new.Content = 'EN'; $new.FontSize = 11.5; $new.Padding = '10,6'; $new.Margin = '3,0'; $new.VerticalAlignment = 'Center'
        $new.Add_Click({ if ($script:lpWin -and $script:lpWin.IsVisible) { $script:lpWin.Close() } else { Show-LangPicker $this } })
        [System.Windows.Shell.WindowChrome]::SetIsHitTestVisibleInChrome($new, $true)
        $bar.Children.RemoveAt($i); $bar.Children.Insert($i, $new); $script:hdrLang = $new
    }
} catch {}

# ---- start-up language
$startCode = [string]$Settings.Language
if (-not $script:XLangs.Contains($startCode) -and -not $Settings.LangChosen) {
    try { $cc = (Get-UICulture).TwoLetterISOLanguageName; if ($script:XLangs.Contains($cc)) { $startCode = $cc } } catch {}
}
if ($script:XLangs.Contains($startCode)) { Set-Language $startCode } else { try { Refresh-LangButtons } catch {} }


# ================================================================ SharkOptimizer Speed (added module)
if (-not (Get-Command Has-Fn -CommandType Function -ErrorAction SilentlyContinue)) { function Has-Fn($n) { [bool](Get-Command $n -CommandType Function -ErrorAction SilentlyContinue) } }

# ---- 1. cached, frozen brushes (thousands of colour objects are created when cards are drawn)
$script:BrushCache = @{}
$script:BrushConv = [Windows.Media.BrushConverter]::new()
function Brush($hex) {
    $h = [string]$hex
    $b = $script:BrushCache[$h]; if ($b) { return $b }
    $m = $h
    if ($script:AccBase) { for ($i = 0; $i -lt 3; $i++) { if ($h -ieq $script:AccBase[$i]) { $m = $script:AccCur[$i]; break } } }
    $b = $script:BrushConv.ConvertFromString($m)
    try { $b.Freeze() } catch {}
    $script:BrushCache[$h] = $b; $b
}
if (Has-Fn 'Set-Accent') {
    $script:OrigSetAccent = ${function:Set-Accent}
    function Set-Accent($name) { $script:BrushCache.Clear(); & $script:OrigSetAccent $name; $script:BrushCache.Clear() }
}

# ---- 2. remember which tweaks fit this PC, and look tweaks up by id
$script:ApplCache = @{}
function Test-Applicable($t) {
    $id = [string]$t.Id
    if ($script:ApplCache.ContainsKey($id)) { return $script:ApplCache[$id] }
    $r = if ($script:HardwareNotice -and $t.Req) { $false } elseif ($t.Req) { [bool](& $t.Req) } else { $true }
    $script:ApplCache[$id] = $r; $r
}
$script:TweakIndex = @{}
function Get-Tweak($id) {
    if ($script:TweakIndex.Count -ne $Tweaks.Count) { $script:TweakIndex = @{}; foreach ($t in $Tweaks) { $script:TweakIndex[[string]$t.Id] = $t } }
    $script:TweakIndex[[string]$id]
}

# ---- 3. fewer animations on long lists, and a short wait while typing in the search box
if (Has-Fn 'Animate-In') {
    $script:OrigAnimate = ${function:Animate-In}
    function Animate-In($el, $delayMs = 0, $dist = 12, $ms = 280, $to = 1) {
        if ($delayMs -ge 240) { try { $el.Opacity = $to } catch {}; return }
        & $script:OrigAnimate $el $delayMs $dist $ms $to
    }
}
$script:OrigRenderT = ${function:Render-Tweaks}
$script:RenderTimer = New-Object Windows.Threading.DispatcherTimer; $script:RenderTimer.Interval = [TimeSpan]::FromMilliseconds(220)
$script:RenderTimer.Add_Tick({ $script:RenderTimer.Stop(); & $script:OrigRenderT })
function Render-Tweaks {
    if ($ui.txtSearch.IsKeyboardFocused) { $script:RenderTimer.Stop(); $script:RenderTimer.Start() }
    else { $script:RenderTimer.Stop(); & $script:OrigRenderT }
}

# ---- 4. translation lookups: remember strings that have no translation
if (Has-Fn 'Get-Nl') {
    $script:NlMiss = @{}
    $script:OrigGetNl = ${function:Get-Nl}
    function Get-Nl($txt) {
        if ($null -eq $txt -or $txt -eq '') { return $null }
        if ($script:NlMiss.ContainsKey($txt)) { return $null }
        $r = & $script:OrigGetNl $txt
        if (-not $r) { $script:NlMiss[$txt] = $true }
        $r
    }
    $script:OrigSetLang3 = ${function:Set-Language}
    function Set-Language($lang) { $script:NlMiss.Clear(); & $script:OrigSetLang3 $lang; $script:NlMiss.Clear() }
}

# ---- 5. live gauges: lighter GPU counters, slower refresh
$script:GpuStamp = [datetime]::MinValue
if (Has-Fn 'Refresh-GpuCounters') {
    $script:OrigRefreshGpu = ${function:Refresh-GpuCounters}
    function Refresh-GpuCounters {
        if (@($script:gpuC).Count -and ((Get-Date) - $script:GpuStamp).TotalMinutes -lt 5) { return }
        foreach ($c in @($script:gpuC)) { try { $c.Dispose() } catch {} }
        & $script:OrigRefreshGpu; $script:GpuStamp = Get-Date
    }
}
try { if ($timer) { $timer.Interval = [TimeSpan]::FromSeconds(3) } } catch {}

# ---- 6. restore points only when they are needed
$script:RPNeeded = $null
$script:RPStamp = [datetime]::MinValue
$script:OrigRP3 = ${function:New-RestorePoint}
function New-RestorePoint {
    if ($null -ne $script:RPNeeded) {
        if (-not $script:RPNeeded) { Log 'Only safe tweaks: restore point skipped (every change can be undone).'; return }
        if (((Get-Date) - $script:RPStamp).TotalMinutes -lt 30) { Log 'Using the restore point made a few minutes ago.'; return }
    }
    & $script:OrigRP3; $script:RPStamp = Get-Date
}
$script:OrigApply2 = ${function:Invoke-Apply}
function Invoke-Apply($list) {
    $l = @($list); $risky = @($l | Where-Object { $_.Risk -ne 'Safe' })
    $script:RPNeeded = (($risky.Count -gt 0) -or [bool]$Settings.AlwaysRestorePoint)
    try { & $script:OrigApply2 $list } finally { $script:RPNeeded = $null }
}
try {
    if ($NL) { $NL['Always create a restore point before applying'] = 'Maak altijd een herstelpunt voordat je toepast' }
    $cb = New-Object Windows.Controls.CheckBox; $cb.Content = 'Always create a restore point before applying'; $cb.Tag = 'AlwaysRestorePoint'; $cb.Margin = '4,7'
    $cb.IsChecked = [bool]$Settings.AlwaysRestorePoint
    if ($swStyle) { $cb.Style = $swStyle }
    $cb.Add_Click({ $Settings.AlwaysRestorePoint = [bool]$this.IsChecked; Save-Settings })
    $idx = -1; $kids = @($setPanel.Children)
    for ($i = 0; $i -lt $kids.Count; $i++) { if ($kids[$i] -is [Windows.Controls.CheckBox] -and [string]$kids[$i].Tag -eq 'ScanOnStart') { $idx = $i; break } }
    if ($idx -ge 0) { $setPanel.Children.Insert($idx + 1, $cb) } else { $setPanel.Children.Add($cb) | Out-Null }
    if (Has-Fn 'Translate-Now') { Translate-Now $cb }
} catch {}

# ---- 7. the built-in app list is loaded in the background
$script:BloatPs = $null; $script:BloatAsync = $null
$script:BloatTimer = New-Object Windows.Threading.DispatcherTimer; $script:BloatTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:BloatTimer.Add_Tick({
    if (-not $script:BloatAsync -or -not $script:BloatAsync.IsCompleted) { return }
    $script:BloatTimer.Stop()
    $installed = @()
    try { $installed = @($script:BloatPs.EndInvoke($script:BloatAsync)) } catch {}
    try { $script:BloatPs.Dispose() } catch {}
    $script:BloatPs = $null; $script:BloatAsync = $null
    $ui.lstBloat.Children.Clear()
    $n = 0
    foreach ($key in @($BloatApps.Keys)) {
        if ($installed -notcontains $key) { continue }
        $cb2 = New-Object Windows.Controls.CheckBox; $cb2.Content = $BloatApps[$key]; $cb2.Tag = $key; $cb2.Margin = '4,3,18,3'; $cb2.Width = 210
        $ui.lstBloat.Children.Add($cb2) | Out-Null; $n++
    }
    if (-not $n) { $ui.lstBloat.Children.Add((New-Text 'None of the listed apps are installed.' 12 '#7F8FAE' $false '4,0,0,6')) | Out-Null }
    if (Has-Fn 'Translate-Now') { Translate-Now $ui.lstBloat }
})
function Refresh-Bloat {
    if ($script:BloatAsync) { return }
    $ui.lstBloat.Children.Clear()
    $ui.lstBloat.Children.Add((New-Text 'Loading apps...' 12 '#7F8FAE' $false '4,0,0,6')) | Out-Null
    $ps = [powershell]::Create()
    [void]$ps.AddScript({ @(Get-AppxPackage -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) })
    $script:BloatPs = $ps; $script:BloatAsync = $ps.BeginInvoke(); $script:BloatTimer.Start()
}

# ---- 8. faster folder scanning and cleaning (.NET instead of Get-ChildItem)
$FastFindCs = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
public static class FastFind {
    public static List<string> Find(string root, int maxDepth, string[] patterns) {
        List<string> res = new List<string>(); List<Regex> rx = new List<Regex>();
        foreach (string p in patterns) rx.Add(new Regex("^" + Regex.Escape(p).Replace("\\*", ".*").Replace("\\?", ".") + "$", RegexOptions.IgnoreCase));
        Walk(root, 0, maxDepth, rx, res); return res;
    }
    static void Walk(string dir, int d, int max, List<Regex> rx, List<string> res) {
        try { foreach (string f in Directory.EnumerateFiles(dir)) { string n = Path.GetFileName(f); foreach (Regex r in rx) { if (r.IsMatch(n)) { res.Add(f); break; } } } } catch { }
        if (d >= max) return;
        try { foreach (string s in Directory.EnumerateDirectories(dir)) Walk(s, d + 1, max, rx, res); } catch { }
    }
}
'@
function Scan-Games {
    $ui.btnScan.IsEnabled = $false
    $n = 0
    try {
        if (-not ('FastFind' -as [type])) { Add-Type -TypeDefinition $FastFindCs }
        $patterns = [string[]]@($Games | ForEach-Object { $_.Exes } | Select-Object -Unique)
        $hits = New-Object System.Collections.ArrayList
        foreach ($root in @(Get-GameRoots)) {
            $ui.txtScan.Text = "Scanning $root ..."
            if ($script:Lang -ne 'en' -and (Has-Fn 'Get-Nl')) { $tr = Get-Nl $ui.txtScan.Text; if ($tr) { $ui.txtScan.Text = $tr } }
            Flush-UI
            foreach ($p in [FastFind]::Find($root, 5, $patterns)) { [void]$hits.Add($p) }
        }
        $old = $script:GamePaths
        $script:GamePaths = @{}
        foreach ($g in $Games) {
            $mine = @()
            foreach ($h in $hits) { $leaf = [IO.Path]::GetFileName($h); foreach ($pt in $g.Exes) { if ($leaf -like $pt) { $mine += $h; break } } }
            if ($g.Id -like 'custom_*' -and $old.ContainsKey($g.Id)) { $mine += @($old[$g.Id] | Where-Object { $_ -and (Test-Path -LiteralPath ([string]$_)) }) }
            $script:GamePaths[$g.Id] = @($mine | Select-Object -Unique)
        }
        $n = @($Games | Where-Object { @($script:GamePaths[$_.Id]).Count -gt 0 }).Count
        $msg = "Scan finished. Found $n of $($Games.Count) supported games."
        if ($script:Lang -ne 'en' -and (Has-Fn 'Get-Nl')) { $tr = Get-Nl $msg; if ($tr) { $msg = $tr } }
        $ui.txtScan.Text = $msg
        try {
            if ($GameCache) { $out = @{}; foreach ($g in $Games) { $out[$g.Id] = @($script:GamePaths[$g.Id] | Where-Object { $_ }) }; Write-JsonAtomic -Path $GameCache -Value $out -Depth 4 }
        } catch {}
    } finally { $ui.btnScan.IsEnabled = $true }
    Render-GameList
    if ($script:CurGame) { Show-Game $script:CurGame }
    Log "Game scan: $n games found."
}
$script:freedTmp = 0
function Remove-DirWalk($dir) {
    try { foreach ($f in [IO.Directory]::EnumerateFiles($dir)) { try { $len = (New-Object IO.FileInfo $f).Length; [IO.File]::Delete($f); $script:freedTmp += $len } catch {} } } catch {}
    try { foreach ($s in [IO.Directory]::EnumerateDirectories($dir)) { Remove-DirWalk $s } } catch {}
}
function Remove-Dir($path) {
    $script:freedTmp = 0
    if ([IO.Directory]::Exists($path)) { Remove-DirWalk $path }
    $script:freedTmp
}

# ---- 9. do slow things after the window is visible
$window.Add_ContentRendered({
    try { Set-Content (Join-Path $DataDir 'ready.flag') (Get-Date).ToString('s') -ErrorAction Stop } catch {}
    if (Has-Fn 'Update-RPLine') {
        $t = New-Object Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromSeconds(2.5)
        $script:rpTimer = $t
        $t.Add_Tick({ $script:rpTimer.Stop(); try { Update-RPLine } catch {} })
        $t.Start()
    }
})


# ================================================================ SharkOptimizer Complete Translations (added module): full German
$script:XExtra = @{}
function Add-XExtra($code, $descText, $warnText, $tipsText, $lwText, $slidesText, $hintsText, $uiText, $rules) {
    $tips = @{}
    foreach ($ln in ($tipsText -split "`r?`n")) { $i = $ln.IndexOf('|'); if ($i -gt 0) { $g = $ln.Substring(0, $i); if (-not $tips.ContainsKey($g)) { $tips[$g] = @() }; $tips[$g] += $ln.Substring($i + 1) } }
    $slides = @()
    foreach ($ln in ($slidesText -split "`r?`n")) { if (-not $ln.Trim()) { continue }; $f = $ln.Split('|'); $slides += , @{ T = $f[0]; B = ($f[1] -replace '\\n', "`n"); Btn = $f[2] } }
    $script:XExtra[$code] = @{ Desc = (Parse-Pairs $descText); Warn = (Parse-Pairs $warnText); Tips = $tips; LW = (Parse-Pairs $lwText); Slides = $slides; Hints = (Parse-Pairs $hintsText); Rules = $rules }
    $extraUi = Parse-Pairs $uiText
    foreach ($k in @($extraUi.Keys)) { $script:XLangs[$code].UI[$k] = $extraUi[$k] }
}
$de_desc = @'
p_telemetry => Setzt die Telemetrie auf das Minimum und stoppt den DiagTrack-Dienst. Weniger CPU-, Festplatten- und Netzwerklast im Hintergrund.
p_tasks => Schaltet die Aufgaben für Kompatibilitätsbewertung, CEIP und Datenträgerdiagnose ab, die im Hintergrund aufwachen.
p_adid => Verhindert, dass Apps eine eindeutige Werbe-ID nutzen, um dich zu profilieren.
p_bing => Die Suche im Startmenü durchsucht nur deinen PC, nicht Bing. Schnellere Ergebnisse, keine Suchanfragen nach außen.
p_cortana => Schaltet Cortana und die Cloudsuche per Richtlinie ab.
p_activity => Windows sammelt und lädt deinen Aktivitätsverlauf nicht mehr hoch.
p_ads => Schaltet Werbung im Startmenü, Tipps auf dem Sperrbildschirm, Werbung in den Einstellungen und stille App-Installationen ab.
p_consumer => Verhindert, dass Windows vorgeschlagene Apps, Spotlight-Inhalte und Werbeinstallationen aufdrängt.
p_copilot => Schaltet Copilot per Richtlinie ab, damit er nicht mehr im Hintergrund lädt.
p_recall => Blockiert Recall-ähnliche KI-Bildschirmaufnahmen und die Analyse deiner Aktivitäten.
p_widgets => Stoppt das Widgets-Fenster und den zugehörigen Webprozess.
p_wer => Windows erstellt und sendet keine Absturzberichte mehr.
p_feedback => Windows fragt dich nicht mehr nach Feedback.
p_inventory => Stoppt die App-Inventarisierung und die Datensammlung des Problemschritte-Recorders.
p_ink => Windows sammelt keine Handschrift- und Tippproben mehr, um Vorschläge zu verbessern.
p_clip => Dein Zwischenablageverlauf wird nicht mehr zwischen Geräten synchronisiert.
p_location => Schaltet die Windows-Standortermittlung für den ganzen PC ab.
p_llmnr => Schaltet ein veraltetes Namensauflösungsprotokoll ab, das Angreifer in gemeinsamen Netzwerken ausnutzen.
p_remreg => Stoppt den Dienst, über den andere PCs deine Registrierung im Netzwerk bearbeiten können.
p_remote => Schließt die Tür für die Remoteunterstützung und verkleinert deine Angriffsfläche.
p_nvtel => Stoppt den NVIDIA Telemetry Container. Treiber und Spiele funktionieren weiter.
p_do => Windows lädt keine Updates mehr mit deiner Bandbreite an andere PCs hoch.
q_ext => Zeigt immer .exe, .png, .txt und mehr an. Hilft, gefälschte Dateien zu erkennen.
q_hidden => Zeigt versteckte Dateien und Ordner im Explorer an.
q_thispc => Der Explorer öffnet „Dieser PC“ statt „Schnellzugriff“.
q_recent => Der Explorer listet zuletzt und häufig verwendete Dateien nicht mehr im Schnellzugriff auf.
q_shake => Ein Fenster zu schütteln minimiert die anderen nicht mehr.
q_dark => Stellt Windows und Apps auf das dunkle Design um.
q_taskbar => Richtet die Taskleiste links aus und blendet die Schaltflächen für Widgets, Aufgabenansicht und Suche aus.
q_classic => Bringt das vollständige Kontextmenü unter Windows 11 zurück.
q_boot => Zeigt ausführliche Meldungen beim Starten und Herunterfahren. Macht den Start nicht schneller, hilft aber bei der Fehlersuche.
q_menu => Menüs öffnen sich ohne Verzögerung.
q_kb => Kürzeste Wiederholungsverzögerung und schnellste Wiederholungsrate.
q_shutdown => Dienste und Apps haben 2 Sekunden zum Beenden. Hängende Apps werden automatisch beendet.
q_startdelay => Autostart-Apps starten sofort, statt etwa 10 Sekunden zu warten.
q_sticky => Kein Shift-x5-Fenster mehr mitten im Spiel.
q_reboot => Windows startet nicht mehr von selbst neu, während du angemeldet bist.
q_welcome => Blendet die Seiten „Lass uns dein Gerät fertig einrichten“ nach Updates aus.
q_visfx => Schaltet Animationen und Transparenz aus für einen flotteren Desktop und weniger GPU- und RAM-Verbrauch.
q_bgapps => Verhindert, dass Store-Apps im Hintergrund laufen. Spart RAM und CPU.
q_search => Stoppt den Indexdienst. Weniger Festplattenlast auf Systemen mit HDD.
f_gamemode => Sagt Windows, dein Spiel zu bevorzugen und Treiberupdates während des Spielens zu pausieren.
f_dvr => Stoppt die Xbox-Game-Bar-Aufnahme, eine bekannte Ursache für Frametime-Spitzen.
f_overlay => Entfernt die Game-Bar-Einblendung und die Controller-Tastenkürzel.
f_power => Aktiviert den Energiesparplan „Höchstleistung“: kein Core Parking, keine CPU-Taktverzögerungen.
f_usb => Verhindert, dass Windows USB-Anschlüsse abschaltet. Beugt Aussetzern bei Maus, Tastatur und Headset vor.
f_pcie => Hält die PCIe-Verbindung zu GPU und SSD auf voller Geschwindigkeit (ASPM aus).
f_diskoff => Festplatten bleiben im Netzbetrieb aktiv, das verhindert Ruckler, wenn ein Spiel nach Leerlauf Daten lädt.
f_cpumin => Die CPU taktet im Netzbetrieb nie herunter. Entfernt die Anlaufzeit in kompetitiven Spielen.
f_throttle => Verhindert, dass Windows Hintergrund-Apps wie Discord, OBS und Launcher ausbremst.
f_prio => Setzt Win32PrioritySeparation auf 0x26 (kurze Zeitscheiben, 3:1-Vordergrundbonus), eine Standardeinstellung für geringe Eingabeverzögerung.
f_mmcss => Gibt der Games-Aufgabe hohe GPU- und CPU-Priorität und senkt die Multimedia-Reserve.
f_fso => Nutzt echtes exklusives Vollbild. Kann die Eingabeverzögerung in älteren DX9- und DX11-Spielen senken.
f_mouse => Schaltet die Zeigerbeschleunigung für Zielen 1:1 aus. Abmelden ist nötig.
f_hags => Lässt die GPU ihre Planung selbst verwalten. Nötig für DLSS Frame Generation und kann die CPU-Last senken.
f_mpo => Kann Ruckeln, Flackern und schwarze Bildschirme auf manchen NVIDIA- und AMD-Systemen beheben.
f_fast => Erzwingt beim Herunterfahren einen echten Kaltstart. Behebt veraltete Treiberzustände und Ruckeln nach langer Laufzeit.
f_sysmain => SSDs brauchen kein Prefetching. Verringert zufällige Festplatten- und RAM-Aktivität.
f_timerreq => Stellt die prozessbezogene Timer-Auflösung unter Windows 11 wieder her, damit timerintensive Spiele gleichmäßig laufen.
n_nagle => Sendet kleine Pakete sofort. Ein klassischer Ping- und Jitter-Fix für Online-Spiele.
n_throttle => Entfernt die Netzwerkdrosselung für Multimedia.
n_qos => Gibt die 20 % Bandbreite frei, die Windows für QoS reservieren kann.
n_ports => Kürzeres TIME_WAIT (30 s) und 65.534 Benutzerports. Hilft bei Lobbys, die oft neu verbinden.
n_heur => Verhindert, dass Windows TCP-Fenstergrößen selbst überschreibt, was den Durchsatz stabil hält.
n_dns => Setzt 1.1.1.1 auf deinen aktiven Adaptern für schnellere Abfragen. Teste zuerst im Tab Netzwerk.
n_rsc => Stoppt das Bündeln eingehender Pakete durch den Adapter. Geringere Latenz, etwas mehr CPU-Last.
n_lso => Behebt Ruckeln beim Hochladen bei manchen Adaptern und Treibern.
n_nicpwr => Verhindert, dass Windows den Adapter abschaltet, was Lagspitzen und zufällige Verbindungsabbrüche vermeidet.
n_eee => Schaltet Energy-Efficient Ethernet und ähnliche Energiemodi aus, die Aufwachverzögerung verursachen.
n_flow => Verhindert, dass der Adapter Verkehr pausiert, wenn die Gegenstelle darum bittet. Kann Latenzspitzen glätten.
n_intmod => Liefert Pakete sofort an die CPU, statt sie zu bündeln. Niedrigerer Ping, höhere CPU-Last.
n_rss => Verteilt die Netzwerkverarbeitung auf mehrere CPU-Kerne.
n_wifi => Setzt das WLAN-Energiesparen auf maximale Leistung, im Netz- und Akkubetrieb.
n_netbios => Schaltet veraltete NetBIOS-Namensmeldungen ab. Weniger Hintergrundrauschen im Netzwerk.
n_teredo => Schaltet den IPv6-über-IPv4-Tunnel ab, der Overhead verursacht und Verbindungen verlangsamen kann.
w_edge => Schaltet Edge Startup Boost und den Hintergrundmodus aus, damit Edge im geschlossenen Zustand nicht weiterläuft.
w_services => Schaltet Fax, Retail Demo, Windows-Medienfreigabe und Maps Broker ab. Gibt RAM und Handles frei.
w_chat => Entfernt die Chat-Schaltfläche aus der Windows-11-Taskleiste.
w_lastaccess => Windows schreibt nicht mehr bei jedem Lesezugriff einen Zeitstempel. Weniger Festplattenaktivität.
w_8dot3 => Stoppt das Erzeugen veralteter kurzer Dateinamen für jede Datei. Schnelleres Anlegen von Dateien.
w_svchost => Fasst Dienste in weniger svchost.exe-Prozessen zusammen, wenn genug RAM vorhanden ist.
w_pagingexec => Verhindert, dass Windows Kernel und Treiber auf die Festplatte auslagert. Verbessert die Reaktionsfähigkeit auf PCs mit viel RAM.
w_memcomp => Überspringt das Komprimieren von RAM-Seiten, was etwas CPU spart, wenn du viel Speicher hast.
w_prefetch => Schaltet den Prefetcher und das Vorladen von Superfetch ab. Auf SSDs nicht nötig.
w_maint => Verhindert, dass Windows Wartungsaufgaben im Leerlauf nach eigenem Zeitplan ausführt.
w_onedrive => Schaltet die OneDrive-Dateisynchronisierung per Richtlinie ab.
w_wudrv => Windows Update ersetzt deine GPU- und Chipsatztreiber nicht mehr durch eigene Versionen.
w_spooler => Stoppt den Druckdienst. Spart RAM und schließt eine häufige Angriffsfläche.
a_msi => Stellt die GPU auf Message Signaled Interrupts für geringere DPC-Latenz.
a_tick => Konstante Timer-Interrupts für gleichmäßigere Frametimes (bcdedit).
a_hyperv => Verhindert, dass der Windows-Hypervisor beim Start geladen wird, wodurch der Virtualisierungs-Overhead entfällt.
a_xbox => Schaltet Xbox-Live-Anmeldung, Spielstände, Netzwerk und Zubehördienste ab.
a_ipv6 => Erzwingt nur IPv4. Kann seltsames Routing oder DNS-Verzögerungen bei manchen Anbietern beheben.
a_spectre => Schaltet Spectre- und Meltdown-Schutzmaßnahmen ab. Kann FPS auf älteren Intel-CPUs steigern.
a_vbs => Schaltet Virtualization-Based Security und HVCI ab, was auf manchen Systemen FPS kostet.
a_hib => Löscht hiberfil.sys und gibt einige GB auf dem Systemlaufwerk frei.
'@
$de_warn = @'
p_location => Karten, Wetter und „Mein Gerät suchen“ funktionieren nicht mehr.
q_shutdown => Apps mit ungespeicherter Arbeit können beim Herunterfahren geschlossen werden.
q_bgapps => Mail, Kalender und andere Store-Apps benachrichtigen dich nicht mehr, solange sie geschlossen sind.
q_search => Dateisuchen im Startmenü und im Explorer werden deutlich langsamer.
f_dvr => Aufnahmen mit Win+G und Win+Alt+R funktionieren nicht mehr.
f_power => Höherer Stromverbrauch und mehr Wärme. Leert Laptop-Akkus schnell.
f_cpumin => Höhere Leerlauftemperaturen und höherer Stromverbrauch. Nicht für Laptops im Akkubetrieb.
f_fso => Kann in manchen DX12-Spielen Tearing verursachen oder FPS senken.
f_hags => Kann bei älteren GPUs oder Treibern Ruckeln verursachen. Teste deine Spiele nach einem Neustart.
f_mpo => Nur verwenden, wenn du Flackern oder Ruckeln siehst. Der Stromverbrauch kann leicht steigen.
f_fast => Kaltstarts dauern ein paar Sekunden länger, vor allem auf Festplatten.
f_timerreq => Etwas höherer Stromverbrauch. Nur relevant für Spiele, die 0,5-ms-Timer anfordern.
n_lso => Kann die CPU-Last bei großen Uploads leicht erhöhen.
n_flow => Große lokale Dateiübertragungen können sich etwas anders verhalten.
n_intmod => Erhöht die CPU-Last bei viel Netzwerkverkehr. Schwache CPUs können FPS verlieren.
n_netbios => Sehr alte Dateifreigaben, die auf NetBIOS-Namen angewiesen sind, funktionieren nicht mehr.
n_teredo => Xbox-Live-Partychat und manche Peer-to-Peer-Spiele nutzen Teredo.
w_8dot3 => Sehr alte 16-Bit-Installationsprogramme können fehlschlagen. Vorhandene Kurznamen bleiben erhalten.
w_svchost => Wenn ein gruppierter Dienst abstürzt, können andere in derselben Gruppe mitstoppen.
w_pagingexec => Belegt dauerhaft etwas mehr RAM.
w_memcomp => Macht alles langsamer, wenn dein RAM voll läuft.
w_prefetch => Programme können auf Festplatten etwas langsamer starten.
w_maint => Geplante Defragmentierung und Diagnosen laufen nicht. Nutze stattdessen Boost-Up.
w_onedrive => Dateien bleiben auf deinem PC, werden aber nicht mehr mit der Cloud synchronisiert.
w_wudrv => Du musst Treiber selbst beim Hersteller aktualisieren.
w_spooler => Drucken und PDF-Drucker funktionieren nicht mehr.
a_msi => Eine nicht unterstützte GPU oder ein solcher Treiber kann schwarze Bildschirme verursachen. Halte einen Wiederherstellungspunkt bereit.
a_tick => Höherer Stromverbrauch und mehr Wärme im Leerlauf.
a_hyperv => WSL2, Docker, Windows Sandbox und Android-Emulatoren funktionieren nicht mehr, bis du das rückgängig machst.
a_xbox => Zerstört die Xbox-App, Game Pass auf dem PC, die Xbox-Anmeldung und Cloud-Spielstände.
a_ipv6 => Manche Spiele, Xbox Live und Anbieter, die auf IPv6 setzen, können ausfallen oder langsamer verbinden.
a_spectre => Sicherheitsrisiko: setzt deine CPU Angriffen über spekulative Ausführung aus. Vermeide das auf PCs für Banking oder Arbeit.
a_vbs => Senkt den Kernelschutz. Manche Anti-Cheats und Arbeitsrichtlinien erwarten, dass er aktiv ist.
a_hib => Ruhezustand und Schnellstart funktionieren nicht mehr.
'@
$de_tips = @'
valorant|Stelle Material, Textur, Detail und UI-Qualität auf Niedrig.
valorant|Schalte Vignette, Bloom, Verzerrung, Schattenwurf und V-Sync aus.
valorant|Nutze MSAA 2x mit anisotroper Filterung 1x und lass Multithreaded Rendering an.
valorant|Aktiviere NVIDIA Reflex Low Latency (An + Boost), wenn deine GPU es unterstützt.
valorant|Begrenze die FPS auf etwa 3 unter der Bildwiederholrate deines Monitors (Limit FPS Always).
valorant|Vanguard verlangt unter Windows 11 Secure Boot und TPM 2.0. Speicherintegrität (VBS) ist nicht erforderlich, das Abschalten ist also optional.
fortnite|Der Performance-Modus liefert auf den meisten PCs die stabilsten FPS. DX12 kann sich auf manchen neueren oder AMD-Systemen flüssiger anfühlen, teste also beides.
fortnite|Schatten aus bringt den größten FPS-Gewinn. Stelle Effekte und Nachbearbeitung auf Niedrig.
fortnite|Niedrige Texturen und Meshes senken den VRAM-Verbrauch und Streaming-Ruckler.
fortnite|Begrenze die FPS knapp unter der Bildwiederholrate deines Monitors.
cs2|Startoptionen helfen nur ein wenig. Die meisten Gewinne kommen von den Videoeinstellungen im Spiel und den GPU-Treibereinstellungen.
cs2|Setze ein FPS-Limit 10 über deiner Bildwiederholrate für stabile Frametimes (zum Beispiel +fps_max 250 bei 240 Hz).
cs2|Schalte V-Sync aus und nutze die rohe Mauseingabe im Spiel.
apex|Allgemeiner Tipp: Nutze exklusives Vollbild, schalte V-Sync aus und begrenze die FPS knapp unter deiner Bildwiederholrate.
apex|Senke das Texture Streaming Budget, wenn du wenig VRAM hast, um Ruckler zu vermeiden.
apex|Aktualisiere deinen GPU-Treiber, bevor du Einstellungen änderst.
warzone|Allgemeiner Tipp: Kompiliere Shader nach jedem Update neu und halte das Spiel auf einer SSD.
warzone|Begrenze die FPS knapp unter deiner Bildwiederholrate und nutze exklusives Vollbild.
warzone|Schließe Overlays und Launcher, die du beim Spielen nicht brauchst.
fivem|Drücke im Spiel F8 und gib cl_drawfps true ein, um die FPS anzuzeigen, oder cl_drawperf true für Ping, Paketverlust sowie CPU- und GPU-Last.
fivem|Schalte MSAA und Reflection MSAA aus, setze Grass Quality auf Normal und lass Extended Distance Scaling auf dem Minimum.
fivem|Senke str_maxVehicleTextureRes in der Konsole, um den VRAM-Verbrauch auf schweren Servern zu verringern.
fivem|Server-Skripte und gestreamte Assets verursachen oft mehr Lag als deine Grafikeinstellungen, teste also auf ein paar Servern.
roblox|Allgemeiner Tipp: Stelle die Grafikqualität in den Roblox-Einstellungen manuell niedriger.
roblox|Ändere keine Roblox-Dateien. Tweaks auf Windows-Ebene sind der sichere Weg.
roblox|Schließe zusätzliche Browser-Tabs und Launcher, denn Roblox belastet die CPU stark.
rocketleague|Allgemeiner Tipp: Schalte V-Sync aus und begrenze die FPS auf oder über deiner Bildwiederholrate für die geringste Eingabeverzögerung.
rocketleague|Senke Render- und Effektqualität, wenn du Frametime-Spitzen siehst.
overwatch|Allgemeiner Tipp: Aktiviere „Puffer reduzieren“, schalte V-Sync aus und begrenze die FPS knapp über deiner Bildwiederholrate.
overwatch|Nutze Niedrig oder Mittel bei Schatten- und Effektdetails für ein klareres Bild.
rust|Allgemeiner Tipp: Halte das Spiel auf einer SSD und senke Sichtweite und Schattenkaskaden.
rust|Rust braucht viel RAM, schließe also andere Apps, bevor du mit 16 GB oder weniger spielst.
'@
$de_lw = @'
fortnite => Epic Games Launcher > Profil > Einstellungen > Fortnite > Zusätzliche Befehlszeilenargumente. Von der Community gemeldet, teste es selbst.
cs2 => Steam > Rechtsklick auf CS2 > Eigenschaften > Startoptionen. Auf schwachen PCs nutze +fps_max 60 für Stabilität.
'@
$de_slides = @'
Willkommen bei SharkOptimizer|SharkOptimizer passt Tweaks an deinen PC an und protokolliert jede Änderung, sodass du alles jederzeit rückgängig machen kannst.\n\nErstelle zuerst einen Wiederherstellungspunkt. Du kannst diese Anleitung mit der ?-Schaltfläche oben oder über Anleitung in der Seitenleiste erneut öffnen.|Wiederherstellungspunkt erstellen
Übersicht|Oben siehst du CPU, GPU und RAM live.\n\nVoreinstellungen wählen eine fertige Zusammenstellung auf der Tweaks-Seite aus, die du prüfen kannst. Der Wert zeigt, wie viele empfohlene Tweaks du angewendet hast.|Zur Übersicht
Tweaks|Filtere mit den Tabs nach Kategorie. Die Marken zeigen das Risiko: SICHER, VORSICHT oder EINGRIFF IN WINDOWS-KERN.\n\nHake Tweaks an und klicke auf Auswahl anwenden (auch oben). Details zeigt genau, was ein Tweak ändert. Auswahl rückgängig macht es wieder rückgängig.|Zu den Tweaks
Spiele|Klicke auf Spiele suchen, wähle ein Spiel, lies die Tipps und klicke auf Optimieren.\n\nSpiele mit Anti-Cheat bekommen nur Änderungen auf Windows-Ebene. An Spieldateien wird nichts angefasst.|Zu den Spielen
Windows und Boost-Up|Windows bietet Reparaturwerkzeuge, Autostart-Verwaltung, das Entfernen integrierter Apps und einen Schließer für schwere Apps.\n\nBoost-Up führt Bereinigungen aus. Etwa einmal im Monat genügt.|Zu Windows
Labor: messen und prüfen|Führe die Messung VORHER aus, wende deine Tweaks an, starte bei Bedarf neu und führe dann die Messung NACHHER aus, um zu sehen, was sich geändert hat.\n\nDer Spielemodus schließt die Apps, die du wählst, und stellt alles wieder her, wenn dein Spiel endet. Jetzt prüfen kontrolliert, ob deine Tweaks noch aktiv sind.|Zum Labor
Netzwerk|Regionen testen und der DNS-Benchmark zeigen deinen Ping und den schnellsten DNS. Besten DNS anwenden nutzt ihn.\n\nEin Live-Ping-Diagramm und Traceroute findest du im Labor.|Zum Netzwerk
Sicher bleiben|Der Tab Wiederherstellen zeigt alles, was angewendet wurde, und lässt dich es rückgängig machen. Auf Windows-Standard zurücksetzen (im Labor) macht alles rückgängig.\n\nWenn ein Spiel oder eine App nach einer Änderung merkwürdig reagiert, mache zuerst den letzten Tweak rückgängig.|Zur Wiederherstellung
'@
$de_hints = @'
navDash => Dein PC auf einen Blick. Nutze Voreinstellungen für schnelle Ergebnisse.
navTweaks => Hake Tweaks an und wähle Auswahl anwenden. Die Marken zeigen, wie riskant jeder Tweak ist.
navGames => Suchen, Spiel wählen, dann Optimieren. Spiele mit Anti-Cheat erhalten nur sichere Änderungen auf Windows-Ebene.
navWin => Reparaturwerkzeuge, Autostart-Apps, integrierte Apps entfernen und schwere Apps schließen.
navLab => Messung vorher und nachher, Spielemodus, Systemprüfung, Prüfen und Profile.
navBoost => Routinebereinigung. Etwa einmal im Monat ausführen.
navNet => Ping, DNS-Benchmark und Servertests.
navRestore => Sieh nach, was angewendet wurde, und mache alles rückgängig.
navSettings => Sprache, Updates und Verhalten.
'@
$de_ui = @'
Pick a preset to select its tweaks. You review them on the Tweaks page before anything is applied. => Wähle eine Voreinstellung, um ihre Tweaks auszuwählen. Du prüfst sie auf der Tweaks-Seite, bevor etwas angewendet wird.
Recommended applies safe tweaks only. => „Empfohlene anwenden“ setzt nur sichere Tweaks um.
Pick a game for a tuned profile. Scan to detect your installs. => Wähle ein Spiel für ein abgestimmtes Profil. Suche, um deine Installationen zu finden.
This game uses anti-cheat, so SharkOptimizer only changes Windows settings. It does not touch the game process, its files or its priority. => Dieses Spiel nutzt Anti-Cheat, daher ändert SharkOptimizer nur Windows-Einstellungen. Spielprozess, Spieldateien und Priorität bleiben unangetastet.
Repair tools, startup control, built-in app removal and a heavy-app closer. More Windows tweaks are under Tweaks > Windows Optimization. => Reparaturwerkzeuge, Autostart-Verwaltung, Entfernen integrierter Apps und ein Schließer für schwere Apps. Weitere Windows-Tweaks findest du unter Tweaks > Windows-Optimierung.
Untick an app to stop it launching at sign-in. Changes apply immediately and can be reversed. => Entferne den Haken, damit eine App nicht beim Anmelden startet. Änderungen gelten sofort und lassen sich rückgängig machen.
Removes Microsoft apps you may not use. They can be reinstalled from the Microsoft Store, but this cannot be undone here. => Entfernt Microsoft-Apps, die du vielleicht nicht nutzt. Du kannst sie über den Microsoft Store neu installieren, aber hier lässt sich das nicht rückgängig machen.
Open apps using the most RAM. Closing asks each app to quit normally, so you can still save your work. => Geöffnete Apps mit dem höchsten RAM-Verbrauch. Beim Schließen wird jede App normal beendet, sodass du noch speichern kannst.
No registry startup entries found. => Keine Autostart-Einträge in der Registrierung gefunden.
None of the listed apps are installed. => Keine der aufgeführten Apps ist installiert.
No other app windows are open. => Es sind keine anderen App-Fenster geöffnet.
Routine cleanups. Run monthly or when your PC feels slow. => Routinebereinigungen. Monatlich ausführen oder wenn dein PC langsam wirkt.
Temp files, update download cache, crash dumps and the Recycle Bin. => Temporäre Dateien, Update-Downloadcache, Absturzabbilder und der Papierkorb.
TRIM on SSDs, defrag on HDDs (system drive). => TRIM auf SSDs, Defragmentierung auf Festplatten (Systemlaufwerk).
Clears your Explorer recent files history. => Löscht die Liste zuletzt verwendeter Dateien im Explorer.
Rebuilds Explorer thumbnails and fixes broken previews. => Baut die Miniaturansichten im Explorer neu auf und behebt defekte Vorschauen.
Resets the Windows font cache. => Setzt den Windows-Schriftartencache zurück.
DirectX, NVIDIA and AMD shader caches. Your first game launch afterwards may stutter while they rebuild. => DirectX-, NVIDIA- und AMD-Shader-Caches. Beim ersten Spielstart danach kann es ruckeln, während sie neu aufgebaut werden.
Cache folders for Chrome, Edge, Brave and Firefox. Logins and bookmarks are kept. => Cache-Ordner von Chrome, Edge, Brave und Firefox. Anmeldungen und Lesezeichen bleiben erhalten.
Trims background process memory. The effect is temporary. => Gibt Speicher von Hintergrundprozessen frei. Der Effekt ist nur vorübergehend.
Clears stale DNS entries. => Löscht veraltete DNS-Einträge.
Measures ping, jitter and packet loss. Region tests use cloud endpoints as a route-quality guide. Enter a game server host to test it directly. => Misst Ping, Jitter und Paketverlust. Regionstests nutzen Cloud-Endpunkte als Anhaltspunkt für die Routenqualität. Gib einen Spieleserver ein, um ihn direkt zu testen.
Every change is recorded, so you can revert it at any time. => Jede Änderung wird protokolliert, sodass du sie jederzeit zurücknehmen kannst.
Measure results, run Game Mode, check your hardware and manage your setup. => Miss Ergebnisse, starte den Spielemodus, prüfe deine Hardware und verwalte dein Setup.
Measures ping, jitter, DNS speed, idle CPU, RAM, process count and boot time, so you can see what your tweaks really changed. Takes about 20 seconds. => Misst Ping, Jitter, DNS-Geschwindigkeit, CPU im Leerlauf, RAM, Prozessanzahl und Startzeit, damit du siehst, was deine Tweaks wirklich verändert haben. Dauert etwa 20 Sekunden.
Switches to a performance power plan, pauses Windows Update, closes apps you pick and trims memory. Everything is restored when it ends. Run a scan on the Games tab to list your games here. => Wechselt zu einem Leistungs-Energiesparplan, pausiert Windows Update, schließt Apps, die du auswählst, und gibt Speicher frei. Alles wird wiederhergestellt, wenn es endet. Suche zuerst im Tab Spiele, damit deine Spiele hier erscheinen.
Looks at drivers, RAM speed, display refresh rate and security features that affect gaming. => Prüft Treiber, RAM-Geschwindigkeit, Bildwiederholrate und Sicherheitsfunktionen, die das Spielen beeinflussen.
Windows updates and driver installers sometimes undo tweaks. This re-reads every applied tweak and shows any that drifted. => Windows-Updates und Treiberinstallationen machen Tweaks manchmal rückgängig. Das liest jeden angewendeten Tweak neu aus und zeigt die zurückgesetzten.
Export what you applied, import it on another PC, apply selected tweaks in small batches you can test, or go back to Windows defaults. => Exportiere, was du angewendet hast, importiere es auf einem anderen PC, wende ausgewählte Tweaks in kleinen, testbaren Gruppen an oder kehre zu den Windows-Standardwerten zurück.
Live ping graph, traceroute and a Wi-Fi channel check. Use a game server address for the most useful graph. => Live-Ping-Diagramm, Traceroute und eine WLAN-Kanalprüfung. Nutze eine Spieleserver-Adresse für das aussagekräftigste Diagramm.
Choose the language of the app. It changes instantly. => Wähle die Sprache der App. Sie wechselt sofort.
Choose the highlight colour of the app. => Wähle die Akzentfarbe der App.
Cleans temp files, crash dumps and error reports once a week with Windows Task Scheduler. It never touches your documents or the Recycle Bin. => Bereinigt einmal pro Woche temporäre Dateien, Absturzabbilder und Fehlerberichte über die Windows-Aufgabenplanung. Deine Dokumente und der Papierkorb bleiben unberührt.
Made by Bas. Free to use. Every change can be undone. => Von Bas gemacht. Kostenlos nutzbar. Jede Änderung lässt sich rückgängig machen.
Language, updates and behaviour. => Sprache, Updates und Verhalten.
Always create a restore point before applying => Vor dem Anwenden immer einen Wiederherstellungspunkt erstellen
Loading apps... => Apps werden geladen...
Not needed on this PC => Auf diesem PC nicht nötig
'@
Add-XExtra 'de' $de_desc $de_warn $de_tips $de_lw $de_slides $de_hints $de_ui @(
    @('^STEP (\d+) OF (\d+)$', 'SCHRITT $1 VON $2'),
    @('^Scanning (.+) \.\.\.$', 'Suche in $1 ...'),
    @('^Scan finished\. Found (\d+) of (\d+) supported games\.$', 'Suche beendet. $1 von $2 unterstützten Spielen gefunden.')
)

function Apply-XExtra($code) {
    $x = $script:XExtra[$code]
    foreach ($t in $Tweaks) {
        if ($x.Desc.ContainsKey($t.Id)) { $t.Desc = $x.Desc[$t.Id] }
        if ($x.Warn.ContainsKey($t.Id)) { $t.Warn = $x.Warn[$t.Id] }
    }
    foreach ($g in $Games) {
        if ($x.Tips.ContainsKey($g.Id)) { $g.Tips = @($x.Tips[$g.Id]) }
        if ($x.LW.ContainsKey($g.Id)) { $g.LaunchWhere = $x.LW[$g.Id] }
    }
    if ($Slides) { for ($i = 0; $i -lt $Slides.Count -and $i -lt $x.Slides.Count; $i++) { $Slides[$i].T = $x.Slides[$i].T; $Slides[$i].B = $x.Slides[$i].B; $Slides[$i].Btn = $x.Slides[$i].Btn } }
    if ($PageInfo) { foreach ($k in @($x.Hints.Keys)) { if ($PageInfo.ContainsKey($k)) { $PageInfo[$k] = @($PageInfo[$k][0], $x.Hints[$k]) } } }
    $script:NLRules = @($script:NLRules) + @($x.Rules)
    if ($script:NlMiss) { $script:NlMiss.Clear() }
    try { Render-Tweaks } catch {}
    try { Render-GameList; if ($script:CurGame) { Show-Game $script:CurGame } } catch {}
    try { Update-Stats } catch {}
    try { if ($script:CurNav) { Update-ProChrome } } catch {}
    if ($script:GuideWin -and $script:GuideWin.IsVisible) { try { Render-Slide; Translate-Now $script:GuideWin } catch {} }
}
$script:OrigSetLang4 = ${function:Set-Language}
function Set-Language($lang) {
    & $script:OrigSetLang4 $lang
    if ($script:XLang -and $script:XExtra.ContainsKey($script:XLang)) {
        try { Apply-XExtra $script:XLang } catch { Log "Translation extras failed: $($_.Exception.Message)" }
    }
}
if ($script:XLang) { Set-Language $script:XLang }

# ---- consolidated navigation and page labels
function Set-NavCaption($button, $caption) {
    try { $button.Content.Children[1].Text = $caption } catch {}
}
function Set-NavLabels {
    $code = [string]$script:Lang
    if (-not $code) { $code = [string]$script:XLang }
    $labels = @{
        en = @('Home','Optimize','Games','Tools','Performance','Recovery','Cleanup','Network diagnostics')
        nl = @('Start','Optimaliseren','Games','Hulpmiddelen','Prestaties','Herstel','Opschonen','Netwerkdiagnose')
        es = @('Inicio','Optimizar','Juegos','Herramientas','Rendimiento','Recuperación','Limpieza','Diagnóstico de red')
        de = @('Start','Optimieren','Spiele','Werkzeuge','Leistung','Wiederherstellung','Bereinigung','Netzwerkdiagnose')
        fr = @('Accueil','Optimiser','Jeux','Outils','Performances','Récupération','Nettoyage','Diagnostic réseau')
        pt = @('Início','Otimizar','Jogos','Ferramentas','Desempenho','Recuperação','Limpeza','Diagnóstico de rede')
        ru = @('Главная','Оптимизация','Игры','Инструменты','Производительность','Восстановление','Очистка','Диагностика сети')
        zh = @('首页','优化','游戏','工具','性能','恢复','清理','网络诊断')
    }
    if (-not $labels.ContainsKey($code)) { $code = 'en' }
    $v = $labels[$code]
    Set-NavCaption $ui.navDash $v[0]; Set-NavCaption $ui.navTweaks $v[1]
    Set-NavCaption $ui.navGames $v[2]; Set-NavCaption $ui.navWin $v[3]
    Set-NavCaption $script:labNav $v[4]; Set-NavCaption $ui.navRestore $v[5]
    $ui.txtTweaksTitle.Text = $v[1]; $ui.txtGamesTitle.Text = $v[2]
    $ui.txtWinTitle.Text = $v[3]; $ui.txtBoostTitle.Text = $v[6]; $ui.txtNetTitle.Text = $v[7]
    if ($script:labTitle) { $script:labTitle.Text = $v[4] }
    if ($script:cleanupExpander) { $script:cleanupExpander.Header = $v[6] }
    if ($script:networkExpander) { $script:networkExpander.Header = $v[7] }
    if ($PageInfo) {
        $PageInfo.navDash = @($v[0], 'PC status, quick actions and recommended starting points.')
        $PageInfo.navTweaks = @($v[1], 'Review and apply PC optimizations.')
        $PageInfo.navGames = @($v[2], 'Find games and review their optimization profiles.')
        $PageInfo.navWin = @($v[3], 'Startup apps, Windows tools and routine cleanup.')
        $PageInfo.navLab = @($v[4], 'Benchmark, Game Mode, verification and network diagnostics.')
        $PageInfo.navRestore = @($v[5], 'Review active changes and undo them.')
    }
    try { if ($script:CurNav) { Update-ProChrome } } catch {}
}
$script:OrigConsolidatedSetLanguage = ${function:Set-Language}
function Set-Language($lang) {
    & $script:OrigConsolidatedSetLanguage $lang
    Set-NavLabels
}

# Put less-used maintenance and network controls behind expanders on their related pages.
try {
    $rootPages = $ui.pgDash.Parent
    [void]$rootPages.Children.Remove($ui.pgBoost)
    [void]$rootPages.Children.Remove($ui.pgNet)
    $ui.pgBoost.Visibility = 'Visible'
    $ui.pgNet.Visibility = 'Visible'

    $script:cleanupExpander = New-Object Windows.Controls.Expander
    $script:cleanupExpander.Header = 'Cleanup'; $script:cleanupExpander.IsExpanded = $false
    $script:cleanupExpander.Margin = '0,18,0,8'; $script:cleanupExpander.Padding = '12,8'
    $script:cleanupExpander.Foreground = Brush '#FFFFFF'; $script:cleanupExpander.Background = Brush '#0F1A2C'
    $script:cleanupExpander.BorderBrush = Brush '#1A2943'; $script:cleanupExpander.BorderThickness = 1
    $script:cleanupExpander.Content = $ui.pgBoost
    $ui.pgWin.Content.Children.Add($script:cleanupExpander) | Out-Null

    $script:networkExpander = New-Object Windows.Controls.Expander
    $script:networkExpander.Header = 'Network diagnostics'; $script:networkExpander.IsExpanded = $false
    $script:networkExpander.Margin = '0,18,0,12'; $script:networkExpander.Padding = '12,8'
    $script:networkExpander.Foreground = Brush '#FFFFFF'; $script:networkExpander.Background = Brush '#0F1A2C'
    $script:networkExpander.BorderBrush = Brush '#1A2943'; $script:networkExpander.BorderThickness = 1
    $ui.pgNet.Height = 430
    $script:networkExpander.Content = $ui.pgNet
    $lab.Children.Add($script:networkExpander) | Out-Null
    $script:labTitle = $lab.Children[0]
    $script:labNav = $ui.navLab

    # Remove old category captions and the now-redundant navigation buttons.
    $navStack = $ui.navDash.Parent
    foreach ($child in @($navStack.Children)) {
        if ($child -is [Windows.Controls.TextBlock] -and $child.Text -in @('OVERVIEW','TUNE','SYSTEM','MAINTAIN')) {
            [void]$navStack.Children.Remove($child)
        }
    }
    $ui.navBoost.Visibility = 'Collapsed'; $ui.navNet.Visibility = 'Collapsed'
    $pages.Remove('navBoost'); $pages.Remove('navNet')
} catch { Log "Navigation consolidation failed: $($_.Exception.Message)" }

# Older guide and in-app shortcuts still point at these internal page IDs.
$script:OrigConsolidatedShowPage = ${function:Show-Page}
function Show-Page($nav) {
    if ($nav -eq 'navBoost') { $nav = 'navWin' }
    elseif ($nav -eq 'navNet') { $nav = 'navLab' }
    & $script:OrigConsolidatedShowPage $nav
}
Set-NavLabels

# ---------------------------------------------------------------- Stage 1 preset editing, comparison, and portable files
$script:pmSelected = New-Object 'System.Collections.Generic.HashSet[string]'
$script:PresetEditingName = $null
$script:pmCancelEditButton = $null
function Reset-PresetEditing {
    $script:PresetEditingName = $null
    if ($script:pmSaveButton) { $script:pmSaveButton.Content = 'Save current selection' }
    if ($script:pmCancelEditButton) { $script:pmCancelEditButton.Visibility = 'Collapsed' }
}
function Get-UniquePresetName($baseName) {
    $name = ([string]$baseName -replace '[\|\r\n]', ' ').Trim(); if (-not $name) { $name = 'Preset' }
    if ($name.Length -gt 40) { $name = $name.Substring(0, 40) }
    $candidate = $name; $n = 2
    while (@($script:UserPresets | Where-Object { $_.name -ieq $candidate }).Count) {
        $suffix = " ($n)"; $candidate = $name.Substring(0, [Math]::Min($name.Length, 40 - $suffix.Length)) + $suffix; $n++
    }
    $candidate
}
function Compare-UserPresets {
    $chosen = @($script:UserPresets | Where-Object { $script:pmSelected.Contains($_.name) })
    if ($chosen.Count -lt 2 -or $chosen.Count -gt 4) { [void][Windows.MessageBox]::Show('Select 2 to 4 presets to compare.', 'SharkOptimizer'); return }
    $allIds = @($chosen | ForEach-Object { $_.ids } | Sort-Object -Unique); $lines = New-Object System.Collections.ArrayList
    foreach ($id in $allIds) {
        $tw = Get-Tweak $id; if (-not $tw) { continue }
        $flags = @($chosen | ForEach-Object { if (@($_.ids) -contains $id) { '✓' } else { '—' } })
        if (@($flags | Select-Object -Unique).Count -lt 2) { continue }
        $parts = for ($i=0; $i -lt $chosen.Count; $i++) { "$($chosen[$i].name): $($flags[$i])" }
        [void]$lines.Add("$($tw.Cat)  ·  $($tw.Name)  |  " + ($parts -join '   |   '))
    }
    if (-not $lines.Count) { [void]$lines.Add('These presets contain the same supported tweaks.') }
    $w = New-Object Windows.Window; $w.Title = 'Compare presets'; $w.Width = 760; $w.Height = 560; $w.Owner = $window; $w.Background = Brush '#08101D'; $w.WindowStartupLocation = 'CenterOwner'
    $sp = New-Object Windows.Controls.StackPanel; $sp.Margin = '20'; $sp.Children.Add((New-Text 'Preset comparison' 22 '#FFFFFF' $true '0,0,0,4')) | Out-Null
    $sp.Children.Add((New-Text (($chosen.name) -join '   vs   ') 12 '#7F8FAE' $false '0,0,0,10')) | Out-Null
    $box = New-Object Windows.Controls.TextBox; $box.IsReadOnly = $true; $box.AcceptsReturn = $true; $box.TextWrapping = 'Wrap'; $box.VerticalScrollBarVisibility = 'Auto'; $box.FontFamily = 'Consolas'; $box.FontSize = 12; $box.MinHeight = 340; $box.Text = $lines -join "`r`n`r`n"; $sp.Children.Add($box) | Out-Null
    $close = New-Object Windows.Controls.Button; $close.Content = 'Close'; $close.Padding = '18,8'; $close.HorizontalAlignment = 'Right'; $close.Margin = '0,12,0,0'; $close.Tag = $w; $close.Add_Click({ $this.Tag.Close() }); $sp.Children.Add($close) | Out-Null
    $w.Content = $sp; Tr $w; [void]$w.ShowDialog()
}
function Export-UserPresets {
    if (-not $script:UserPresets.Count) { [void][Windows.MessageBox]::Show('There are no saved presets to export.', 'SharkOptimizer'); return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog; $dlg.Title = 'Export SharkOptimizer presets'; $dlg.Filter = 'SharkOptimizer preset file (*.json)|*.json'; $dlg.FileName = 'SharkOptimizer-Presets.json'; $dlg.AddExtension = $true
    if ($dlg.ShowDialog($window) -ne $true) { return }
    try {
        $payload = [ordered]@{ format='SharkOptimizerPresets'; version=1; exported=(Get-Date).ToString('s'); presets=@($script:UserPresets | ForEach-Object { @{ name=$_.name; ids=@($_.ids) } }) }
        [IO.File]::WriteAllText($dlg.FileName, (ConvertTo-Json -InputObject $payload -Depth 5), (New-Object Text.UTF8Encoding $false)); Say ("Exported {0} presets." -f $script:UserPresets.Count)
    } catch { Log "Preset export failed: $($_.Exception.Message)"; [void][Windows.MessageBox]::Show($_.Exception.Message, 'Preset export failed', 'OK', 'Error') }
}
function Import-UserPresets {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog; $dlg.Title = 'Import SharkOptimizer presets'; $dlg.Filter = 'SharkOptimizer preset file (*.json)|*.json|All files (*.*)|*.*'; $dlg.Multiselect = $false
    if ($dlg.ShowDialog($window) -ne $true) { return }
    try {
        if ((Get-Item -LiteralPath $dlg.FileName).Length -gt 1MB) { throw 'Preset file is larger than 1 MB.' }
        $data = Get-Content -LiteralPath $dlg.FileName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $incoming = if ($data -is [System.Array]) { @($data) } elseif ($data.PSObject.Properties['presets']) { @($data.presets) } else { throw 'This file does not contain a preset list.' }
        if ($incoming.Count -gt 100) { throw 'A preset file can contain up to 100 presets.' }
        $valid = New-Object System.Collections.ArrayList; $skipped = 0
        foreach ($p in $incoming) {
            if (-not $p.name -or $p.name.ToString().Length -gt 80 -or $null -eq $p.ids) { $skipped++; continue }
            $ids = @($p.ids | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^[a-z]_[a-z0-9]+$' } | Where-Object { Get-Tweak $_ } | Sort-Object -Unique)
            if (-not $ids.Count) { $skipped++; continue }; [void]$valid.Add(@{ name=[string]$p.name; ids=$ids })
        }
        if (-not $valid.Count) { throw 'No presets with supported tweaks were found in this file.' }
        $preview = @($valid | ForEach-Object { "$(Get-UniquePresetName $_.name)  ·  $(@($_.ids).Count) supported tweaks" })
        $warning = if ($skipped) { "$skipped invalid or unsupported entries will be skipped." } else { 'Existing presets will be kept; duplicate names get a suffix.' }
        if (-not (Show-ActionPreview 'Review preset import' ("$($valid.Count) presets are ready to import.") $preview $warning 'Import presets')) { return }
        foreach ($p in $valid) { $nm=Get-UniquePresetName $p.name; $script:UserPresets += @{ name=$nm; ids=@($p.ids) } }
        Save-Presets; Rebuild-PresetList; Say ("Imported {0} presets." -f $valid.Count)
    } catch { Log "Preset import failed: $($_.Exception.Message)"; [void][Windows.MessageBox]::Show($_.Exception.Message, 'Preset import failed', 'OK', 'Warning') }
}
function Rebuild-PresetList {
    $script:pmList.Children.Clear()
    if (-not $script:UserPresets.Count) { $script:pmList.Children.Add((New-Text 'No presets yet. Save a selection from the Tweaks page.' 13 '#7F8FAE' $false '4,8,0,8')) | Out-Null }
    foreach ($p in $script:UserPresets) {
        $row=New-Object Windows.Controls.Border; $row.Background=Brush '#0F1A2C'; $row.BorderBrush=Brush '#1A2943'; $row.BorderThickness=1; $row.CornerRadius=10; $row.Padding='12,9'; $row.Margin='0,0,0,8'
        $dp=New-Object Windows.Controls.DockPanel; $actions=New-Object Windows.Controls.WrapPanel; $actions.HorizontalAlignment='Right'; [Windows.Controls.DockPanel]::SetDock($actions,'Right')
        foreach ($spec in @(@('Use','use'),@('Edit selection','edit'),@('Rename','rename'),@('Duplicate','duplicate'),@('Copy code','copy'),@('Delete','delete'))) {
            $b=New-Object Windows.Controls.Button; $b.Content=$spec[0]; $b.Tag=@{ n=[string]$p.name; a=[string]$spec[1] }; $b.Padding='9,5'; $b.Margin='2'
            if ($spec[1] -eq 'use') { $b.Background=Brush '#1FB6FF'; $b.Foreground=Brush '#06121F' }; if ($spec[1] -eq 'delete') { $b.Background=Brush '#3A1F2B' }
            $b.Add_Click({
                $t=$this.Tag; $pr=$script:UserPresets | Where-Object { $_.name -eq $t.n } | Select-Object -First 1; if (-not $pr) { return }
                switch ($t.a) {
                    'use' { Reset-PresetEditing; $script:pmWin.Close(); Use-Preset $pr.ids }
                    'edit' { $script:PresetEditingName=$pr.name; $script:Selected.Clear(); foreach($id in $pr.ids) { $tw=Get-Tweak $id; if($tw -and (Test-Applicable $tw)) { [void]$script:Selected.Add($id) } }; $script:CatFilter='All'; $ui.chkRec.IsChecked=$false; $ui.txtSearch.Text=''; Render-Tweaks; Show-Page 'navTweaks'; if($script:pmSaveButton){$script:pmSaveButton.Content='Save changes to preset'}; if($script:pmCancelEditButton){$script:pmCancelEditButton.Visibility='Visible'}; Say ("Editing preset: $($pr.name). Adjust the selection in Optimize, then save it here.") }
                    'rename' { $newName=Read-Text 'Rename preset' 'Preset name:' $pr.name; if($newName -and $newName.Trim()) { $newName=($newName -replace '[\|\r\n]',' ').Trim(); if($newName.Length -gt 40){$newName=$newName.Substring(0,40)}; if(@($script:UserPresets | Where-Object {$_.name -ieq $newName -and $_.name -ne $pr.name}).Count){[void][Windows.MessageBox]::Show('A preset with that name already exists.','SharkOptimizer');return}; $pr.name=$newName; Save-Presets; Rebuild-PresetList } }
                    'duplicate' { $nm=Get-UniquePresetName ($pr.name+' copy'); $script:UserPresets+=@{name=$nm;ids=@($pr.ids)}; Save-Presets; Rebuild-PresetList; Say ("Preset duplicated: $nm") }
                    'copy' { [Windows.Clipboard]::SetText((Encode-PresetCode $pr.name $pr.ids)); Say (Tn 'Share code copied.' 'Deelcode gekopieerd.') }
                    'delete' { if(Show-ActionPreview 'Delete preset' "Delete '$($pr.name)'? This removes only the saved preset, not applied Windows changes." @("$($pr.name) · $(@($pr.ids).Count) tweaks") '' 'Delete preset') { $script:UserPresets=@($script:UserPresets | Where-Object {$_.name -ne $t.n}); [void]$script:pmSelected.Remove($t.n); if ($script:PresetEditingName -eq $t.n) { Reset-PresetEditing }; Save-Presets; Rebuild-PresetList } }
                }
            }); $actions.Children.Add($b)|Out-Null
        }
        $left=New-Object Windows.Controls.StackPanel; $left.Orientation='Horizontal'; $choose=New-Object Windows.Controls.CheckBox; $choose.Tag=[string]$p.name; $choose.IsChecked=$script:pmSelected.Contains([string]$p.name); $choose.VerticalAlignment='Center'; $choose.Margin='0,0,8,0'
        $choose.Add_Click({ if($this.IsChecked){[void]$script:pmSelected.Add($this.Tag)}else{[void]$script:pmSelected.Remove($this.Tag)} })
        $info=New-Object Windows.Controls.StackPanel; $info.Children.Add((New-Text $p.name 14 '#FFFFFF' $true))|Out-Null; $info.Children.Add((New-Text ("{0} tweaks" -f @($p.ids).Count) 11.5 '#7F8FAE'))|Out-Null
        $left.Children.Add($choose)|Out-Null; $left.Children.Add($info)|Out-Null; $dp.Children.Add($actions)|Out-Null; $dp.Children.Add($left)|Out-Null; $row.Child=$dp; $script:pmList.Children.Add($row)|Out-Null
    }; Tr $script:pmWin
}
function Show-PresetManager {
    if($script:pmWin -and $script:pmWin.IsVisible){$script:pmWin.Activate();return}
    $w=New-Object Windows.Window; $w.Title=Tn 'My Presets' 'Mijn voorinstellingen'; $w.Width=900; $w.Height=620; $w.MinWidth=680; $w.Background=Brush '#08101D'; $w.Owner=$window; $w.WindowStartupLocation='CenterOwner'
    $grid=New-Object Windows.Controls.Grid; $grid.Margin='18'; foreach($h in 'Auto','*','Auto'){ $r=New-Object Windows.Controls.RowDefinition; $r.Height=$h; $grid.RowDefinitions.Add($r) }
    $head=New-Object Windows.Controls.StackPanel; $head.Children.Add((New-Text 'My Presets' 22 '#FFFFFF' $true '0,0,0,3'))|Out-Null; $head.Children.Add((New-Text 'Select presets to compare. Edit one by adjusting its tweak selection.' 12 '#7F8FAE' $false '0,0,0,10'))|Out-Null
    [Windows.Controls.Grid]::SetRow($head,0); $grid.Children.Add($head)|Out-Null
    $sv=New-Object Windows.Controls.ScrollViewer; $sv.VerticalScrollBarVisibility='Auto'; $script:pmList=New-Object Windows.Controls.StackPanel; $sv.Content=$script:pmList; [Windows.Controls.Grid]::SetRow($sv,1); $grid.Children.Add($sv)|Out-Null
    $foot=New-Object Windows.Controls.WrapPanel; [Windows.Controls.Grid]::SetRow($foot,2); $foot.Margin='0,10,0,0'
    $save=New-Object Windows.Controls.Button; $save.Content=if($script:PresetEditingName){'Save changes to preset'}else{'Save current selection'}; $save.Padding='12,8'; $save.Background=Brush '#1FB6FF'; $save.Foreground=Brush '#06121F'; $script:pmSaveButton=$save
    $cancelEdit=New-Object Windows.Controls.Button; $cancelEdit.Content='Cancel edit'; $cancelEdit.Padding='12,8'; $cancelEdit.Visibility=if($script:PresetEditingName){'Visible'}else{'Collapsed'}; $script:pmCancelEditButton=$cancelEdit
    $cancelEdit.Add_Click({ Reset-PresetEditing; Say 'Preset editing cancelled.' })
    $save.Add_Click({
        $ids=@($script:Selected|Sort-Object); if(-not $ids.Count){[void][Windows.MessageBox]::Show('Select at least one tweak on the Tweaks page first.','SharkOptimizer');return}
        if($script:PresetEditingName){$target=$script:UserPresets|Where-Object{$_.name -eq $script:PresetEditingName}|Select-Object -First 1; if($target){$target.ids=$ids;Save-Presets;Reset-PresetEditing;Rebuild-PresetList;Say 'Preset changes saved.';return};Reset-PresetEditing}
        $nm=Read-Text 'Save preset' 'Give your preset a name:' ''; if($nm -and $nm.Trim()){$nm=Get-UniquePresetName $nm;$script:UserPresets+=@{name=$nm;ids=$ids};Save-Presets;Rebuild-PresetList;Say ("Preset saved: $nm")}
    })
    $impCode=New-Object Windows.Controls.Button;$impCode.Content='Import code';$impCode.Padding='12,8';$impCode.Add_Click({$code=Read-Text 'Import preset' 'Paste the share code (starts with SHARK1-):' '';if(-not $code){return};$d=Decode-PresetCode $code;if(-not $d -or -not $d.ids.Count){[void][Windows.MessageBox]::Show('That code is not valid or contains no supported tweaks.','SharkOptimizer','OK','Warning');return};$nm=Get-UniquePresetName $d.name;$script:UserPresets+=@{name=$nm;ids=@($d.ids)};Save-Presets;Rebuild-PresetList;Say ("Preset imported: $nm")})
    $compare=New-Object Windows.Controls.Button;$compare.Content='Compare selected';$compare.Padding='12,8';$compare.Add_Click({Compare-UserPresets})
    $export=New-Object Windows.Controls.Button;$export.Content='Export file';$export.Padding='12,8';$export.Add_Click({Export-UserPresets})
    $import=New-Object Windows.Controls.Button;$import.Content='Import file';$import.Padding='12,8';$import.Add_Click({Import-UserPresets})
    foreach($b in $save,$cancelEdit,$impCode,$compare,$export,$import){$b.Margin='0,0,6,0';$foot.Children.Add($b)|Out-Null}
    $grid.Children.Add($foot)|Out-Null;$w.Content=$grid;$script:pmWin=$w;Rebuild-PresetList;Tr $w;$w.Show()
}

# ---------------------------------------------------------------- Stage 1 Boost-Up filtering, preview, progress, and history
$script:BoostHistoryFile=Join-Path $DataDir 'boost-history.json';$script:BoostHistory=@();$script:BoostSelected=New-Object 'System.Collections.Generic.HashSet[string]'
try{if(Test-Path $script:BoostHistoryFile){$script:BoostHistory=@(Get-Content $script:BoostHistoryFile -Raw|ConvertFrom-Json|Select-Object -First 50)}}catch{$script:BoostHistory=@()}
$boostCategoryMap=@{'Junk Cleaner'='Storage cleanup';'Optimize Drives'='Drive maintenance';'Clean Recent Documents'='Privacy';'Clean Thumbnail Cache'='Windows cache';'Clean Font Cache'='Windows cache';'Clear Shader Caches'='Game caches';'Clean Browser Caches'='Browser caches';'Trim Process RAM'='Memory';'Flush DNS Cache'='Network'}
$boostEstimatePaths=@{
 'Junk Cleaner'=@($env:TEMP,'C:\Windows\Temp',"$env:LOCALAPPDATA\CrashDumps",'C:\ProgramData\Microsoft\Windows\WER\ReportArchive','C:\Windows\SoftwareDistribution\Download')
 'Clean Recent Documents'=@("$env:APPDATA\Microsoft\Windows\Recent");'Clean Thumbnail Cache'=@("$env:LOCALAPPDATA\Microsoft\Windows\Explorer")
 'Clean Font Cache'=@('C:\Windows\ServiceProfiles\LocalService\AppData\Local\FontCache')
 'Clear Shader Caches'=@("$env:LOCALAPPDATA\D3DSCache","$env:LOCALAPPDATA\NVIDIA\DXCache","$env:LOCALAPPDATA\NVIDIA\GLCache","$env:LOCALAPPDATA\AMD\DxCache")
 'Clean Browser Caches'=@("$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache","$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache","$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache","$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache","$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache")
}
$boostWarnings=@{
 'Junk Cleaner'='Empties the Recycle Bin. Review its contents first; this part cannot be undone.'
 'Optimize Drives'=$(if($Spec.SSD){'Runs TRIM on the system SSD.'}else{'Runs drive optimization on the system drive.'})
 'Clean Recent Documents'='Clears the Windows Recent files list.';'Clean Thumbnail Cache'='Windows rebuilds thumbnails as you browse folders.'
 'Clean Font Cache'='Restarts the font cache service; Windows recreates the cache.'
 'Clear Shader Caches'='Games may stutter briefly on the first launch while shaders rebuild.'
 'Clean Browser Caches'='Removes cached web resources from the listed browser cache folders.'
 'Trim Process RAM'='Temporary working-set trim; Windows and apps may refill memory immediately.'
 'Flush DNS Cache'='Clears local DNS lookup entries; it does not change your DNS provider.'
}
$script:boostSearch=New-Object Windows.Controls.TextBox;$script:boostSearch.Width=210;$script:boostSearch.Margin='3';$script:boostSearch.Padding='8,5';$script:boostSearch.ToolTip='Search Boost-Ups'
$script:boostCategory=New-Object Windows.Controls.ComboBox;$script:boostCategory.Width=165;$script:boostCategory.Margin='3';$script:boostCategory.Padding='6,4'
foreach($cat in (@('All categories')+@($boostCategoryMap.Values|Sort-Object -Unique))){[void]$script:boostCategory.Items.Add($cat)};$script:boostCategory.SelectedIndex=0
$script:boostSelectionText=New-Text '0 selected' 11.5 '#7F8FAE' $false '8,5,6,0'
$script:boostProgressText=New-Text 'Ready' 11.5 '#7F8FAE' $false '4,4,0,2'
$script:boostProgress=New-Object Windows.Controls.ProgressBar;$script:boostProgress.Height=7;$script:boostProgress.Minimum=0;$script:boostProgress.Maximum=1;$script:boostProgress.Value=0;$script:boostProgress.Margin='4,2,4,8'
$boostPage=$ui.pgBoost.Children[0];$boostTools=New-Object Windows.Controls.StackPanel;$filterRow=New-Object Windows.Controls.WrapPanel
$filterRow.Children.Add($script:boostSearch)|Out-Null;$filterRow.Children.Add($script:boostCategory)|Out-Null;$buttonRow=New-Object Windows.Controls.WrapPanel
$script:boostSelectVisible=New-Object Windows.Controls.Button;$script:boostSelectVisible.Content='Select visible';$script:boostSelectVisible.Padding='10,6'
$script:boostClearSelection=New-Object Windows.Controls.Button;$script:boostClearSelection.Content='Clear selection';$script:boostClearSelection.Padding='10,6'
$script:boostRunSelected=New-Object Windows.Controls.Button;$script:boostRunSelected.Content='Review & Run selected';$script:boostRunSelected.Padding='12,7';$script:boostRunSelected.Background=Brush '#1FB6FF';$script:boostRunSelected.Foreground=Brush '#06121F'
$script:boostHistoryButton=New-Object Windows.Controls.Button;$script:boostHistoryButton.Content='Run history';$script:boostHistoryButton.Padding='10,6'
foreach($b in $script:boostSelectVisible,$script:boostClearSelection,$script:boostRunSelected,$script:boostHistoryButton){$b.Margin='2';$buttonRow.Children.Add($b)|Out-Null}
foreach($c in $filterRow,$buttonRow,$script:boostSelectionText,$script:boostProgressText,$script:boostProgress){$boostTools.Children.Add($c)|Out-Null}
$boostPage.Children.Insert(2,$boostTools);$ui.btnBoostAll.Visibility='Collapsed'
function Save-BoostHistory {try{$script:BoostHistory=@($script:BoostHistory|Select-Object -First 50);Write-JsonAtomic -Path $script:BoostHistoryFile -Value $script:BoostHistory -Depth 4}catch{Log "Boost-Up history save failed: $($_.Exception.Message)"}}
function Get-BoostEstimate($items){
    $bytes=[long]0;$scan=[Diagnostics.Stopwatch]::StartNew();$fileLimit=2500;$filesSeen=0
    foreach($item in @($items)){
        foreach($path in @($boostEstimatePaths[$item.Name])){
            if(-not $path -or -not [IO.Directory]::Exists($path)){continue}
            try{
                foreach($file in [IO.Directory]::EnumerateFiles($path,'*',[IO.SearchOption]::AllDirectories)){
                    if($filesSeen -ge $fileLimit -or $scan.Elapsed.TotalMilliseconds -ge 1200){return $bytes}
                    $filesSeen++;try{$bytes+=(New-Object IO.FileInfo $file).Length}catch{}
                }
            }catch{}
        }
    }
    $bytes
}
function Update-BoostSelection {$script:boostSelectionText.Text=("{0} selected" -f $script:BoostSelected.Count);$script:boostRunSelected.IsEnabled=($script:BoostSelected.Count -gt 0)}
function Render-BoostItems {
    $script:boostChecks=@{};$script:boostStatus=@{};$ui.lstBoost.Children.Clear();$query=$script:boostSearch.Text.Trim();$category=[string]$script:boostCategory.SelectedItem
    foreach($item in $BoostItems){$cat=[string]$boostCategoryMap[$item.Name];$label="$($item.Name) $($item.Desc) $cat";if(($category -ne 'All categories' -and $category -ne $cat)-or($query -and $label -notlike "*$query*")){continue}
        $border=New-Object Windows.Controls.Border;$border.Background=Brush '#0F1A2C';$border.BorderBrush=Brush '#1A2943';$border.BorderThickness=1;$border.CornerRadius=12;$border.Padding='12,9';$border.Margin='0,0,0,7';$dock=New-Object Windows.Controls.DockPanel
        $actions=New-Object Windows.Controls.StackPanel;$actions.Orientation='Horizontal';[Windows.Controls.DockPanel]::SetDock($actions,'Right')
        $status=New-Text 'Not run yet' 11 '#7F8FAE' $false '0,0,6,0';$script:boostStatus[$item.Name]=$status
        $previous=$script:BoostHistory|Where-Object{$_.name -eq $item.Name}|Select-Object -First 1;if($previous){$status.Text="$($previous.result) · $($previous.time)";$status.Foreground=Brush $(if($previous.ok){'#35D07F'}else{'#FF6B6B'})}
        $run=New-Object Windows.Controls.Button;$run.Content='Review & Run';$run.Tag=$item.Name;$run.Padding='10,5';$run.Add_Click({Request-BoostRun @([string]$this.Tag)})
        $actions.Children.Add($status)|Out-Null;$actions.Children.Add($run)|Out-Null;$left=New-Object Windows.Controls.StackPanel;$left.Orientation='Horizontal'
        $check=New-Object Windows.Controls.CheckBox;$check.Tag=$item.Name;$check.IsChecked=$script:BoostSelected.Contains($item.Name);$check.VerticalAlignment='Center';$check.Margin='0,0,10,0'
        $check.Add_Click({if($this.IsChecked){[void]$script:BoostSelected.Add($this.Tag)}else{[void]$script:BoostSelected.Remove($this.Tag)};Update-BoostSelection})
        $copy=New-Object Windows.Controls.StackPanel;$copy.Children.Add((New-Text $item.Name 14 '#FFFFFF' $true))|Out-Null;$copy.Children.Add((New-Text $item.Desc 11.5 '#7F8FAE' $false '0,2,0,0'))|Out-Null;$copy.Children.Add((New-Text $cat 10.5 '#1FB6FF' $true '0,3,0,0'))|Out-Null
        $left.Children.Add($check)|Out-Null;$left.Children.Add($copy)|Out-Null;$dock.Children.Add($actions)|Out-Null;$dock.Children.Add($left)|Out-Null;$border.Child=$dock;$ui.lstBoost.Children.Add($border)|Out-Null
    }
    if(-not $ui.lstBoost.Children.Count){$ui.lstBoost.Children.Add((New-Text 'No Boost-Ups match these filters.' 12 '#7F8FAE' $false '8,10'))|Out-Null};Update-BoostSelection;if(Has-Fn 'Translate-Now'){Translate-Now $ui.lstBoost}
}
function Show-BoostHistory {
    $w=New-Object Windows.Window;$w.Title='Boost-Up history';$w.Width=680;$w.Height=520;$w.Owner=$window;$w.Background=Brush '#08101D';$w.WindowStartupLocation='CenterOwner';$grid=New-Object Windows.Controls.Grid;$grid.Margin='18'
    foreach($h in 'Auto','*','Auto'){$r=New-Object Windows.Controls.RowDefinition;$r.Height=$h;$grid.RowDefinitions.Add($r)};$grid.Children.Add((New-Text 'Recent Boost-Ups' 21 '#FFFFFF' $true '0,0,0,10'))|Out-Null
    $sv=New-Object Windows.Controls.ScrollViewer;$sv.VerticalScrollBarVisibility='Auto';$list=New-Object Windows.Controls.StackPanel
    if(-not $script:BoostHistory.Count){$list.Children.Add((New-Text 'No Boost-Ups have been run yet.' 12 '#7F8FAE'))|Out-Null}
    foreach($entry in @($script:BoostHistory|Select-Object -First 50)){$txt="{0} · {1} · {2}" -f $entry.time,$entry.name,$entry.result;$list.Children.Add((New-Text $txt 11.5 $(if($entry.ok){'#C2CCDF'}else{'#FF8A8A'}) $false '0,0,0,7'))|Out-Null}
    $sv.Content=$list;[Windows.Controls.Grid]::SetRow($sv,1);$grid.Children.Add($sv)|Out-Null;$foot=New-Object Windows.Controls.StackPanel;$foot.Orientation='Horizontal';$foot.HorizontalAlignment='Right';$foot.Margin='0,10,0,0'
    $clear=New-Object Windows.Controls.Button;$clear.Content='Clear history';$clear.Padding='12,7';$clear.Margin='0,0,8,0';$clear.Add_Click({if(Show-ActionPreview 'Clear Boost-Up history' 'Remove saved run records from this PC?' @("$($script:BoostHistory.Count) history entries") '' 'Clear history'){$script:BoostHistory=@();Save-BoostHistory;$script:historyWin.Close();Show-BoostHistory}})
    $close=New-Object Windows.Controls.Button;$close.Content='Close';$close.Padding='14,7';$close.Tag=$w;$close.Add_Click({$this.Tag.Close()});$foot.Children.Add($clear)|Out-Null;$foot.Children.Add($close)|Out-Null
    [Windows.Controls.Grid]::SetRow($foot,2);$grid.Children.Add($foot)|Out-Null;$w.Content=$grid;$script:historyWin=$w;Tr $w;[void]$w.ShowDialog()
}
function Run-Boost($name,[bool]$approved=$false,[int]$index=1,[int]$total=1){
    if(-not $approved){Request-BoostRun @([string]$name);return};$item=$BoostItems|Where-Object{$_.Name -eq $name}|Select-Object -First 1;if(-not $item){return}
    $status=$script:boostStatus[$name];if($status){$status.Text='Running…';$status.Foreground=Brush '#FFC857'};$script:boostProgressText.Text=('Running {0} of {1}: {2}' -f $index,$total,$name);$script:boostProgress.IsIndeterminate=$true;$script:boostProgress.Value=[Math]::Max(0,$index-1);Flush-UI
    $started=Get-Date;$ok=$true;try{$result=[string](& $item.Run);if(-not $result){$result='Completed'};if($status){$status.Text="$result · $(Get-Date -Format HH:mm)";$status.Foreground=Brush '#35D07F'};Log "Boost: $name - $result"}catch{$ok=$false;$result=$_.Exception.Message;if($status){$status.Text='Failed';$status.Foreground=Brush '#FF6B6B'};Log "Boost: $name failed - $result"}
    $script:BoostHistory=@(@{time=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss');name=$name;ok=$ok;result=$result;durationSeconds=[math]::Round(((Get-Date)-$started).TotalSeconds,1)})+@($script:BoostHistory);Save-BoostHistory;$script:boostProgress.IsIndeterminate=$false;$script:boostProgress.Value=$index;Flush-UI;$ok
}
function Request-BoostRun($names){
    $selected=@($BoostItems|Where-Object{@($names)-contains $_.Name});if(-not $selected.Count){return};$bytes=Get-BoostEstimate $selected
    $estimate=if($bytes -gt 0){"Quick estimate (bounded scan; may be low): about {0:N1} MB. In-use files may not be removable." -f ($bytes/1MB)}else{''}
    if(@($selected|Where-Object{$_.Name -eq 'Junk Cleaner'}).Count){$estimate="Recycle Bin contents are not included in the estimate.`n$estimate"}
    $items=@($selected|ForEach-Object{"[$($boostCategoryMap[$_.Name])] $($_.Name)`n$($_.Desc)`nImpact: $($boostWarnings[$_.Name])"})
    $warning=@($selected|ForEach-Object{$boostWarnings[$_.Name]}|Sort-Object -Unique)-join "`n";if($estimate){$warning="$estimate`n`n$warning"}
    if(-not(Show-ActionPreview 'Review Boost-Ups' ("$($selected.Count) selected actions will run in order. Estimated time depends on the files and devices involved.") $items $warning 'Run selected')){return}
    $script:boostProgress.Minimum=0;$script:boostProgress.Maximum=$selected.Count;$script:boostProgress.Value=0;$script:boostProgressText.Text='Starting…';Flush-UI
    $i=0;foreach($item in $selected){$i++;[void](Run-Boost $item.Name $true $i $selected.Count)};$script:boostProgressText.Text="Finished $($selected.Count) action(s).";$script:boostProgress.Value=$selected.Count;Flush-UI
}
$script:boostSearch.Add_TextChanged({Render-BoostItems});$script:boostCategory.Add_SelectionChanged({Render-BoostItems})
$script:boostSelectVisible.Add_Click({$q=$script:boostSearch.Text.Trim();foreach($item in $BoostItems){$cat=[string]$boostCategoryMap[$item.Name];$label="$($item.Name) $($item.Desc) $cat";if(($script:boostCategory.SelectedItem -eq 'All categories' -or $script:boostCategory.SelectedItem -eq $cat)-and(-not $q -or $label -like "*$q*")){[void]$script:BoostSelected.Add($item.Name)}};Render-BoostItems})
$script:boostClearSelection.Add_Click({$script:BoostSelected.Clear();Render-BoostItems})
$script:boostRunSelected.Add_Click({$names=@($BoostItems|Where-Object{$script:BoostSelected.Contains($_.Name)}|ForEach-Object{$_.Name});Request-BoostRun $names})
$script:boostHistoryButton.Add_Click({Show-BoostHistory});Render-BoostItems

# ---------------------------------------------------------------- Stage 1 review dialog and individual restore controls
function Show-ActionPreview($title, $summary, $items, $warning = '', $confirmText = 'Continue') {
    $w = New-Object Windows.Window; $w.Title = $title; $w.Width = 700; $w.Height = 560
    $w.MinWidth = 520; $w.MinHeight = 400; $w.Background = Brush '#08101D'
    $ownerWindow = if ($script:historyWin -and $script:historyWin.IsActive) { $script:historyWin } else { $window }
    $w.Owner = $ownerWindow; $w.WindowStartupLocation = 'CenterOwner'; $w.ResizeMode = 'CanResize'
    $grid = New-Object Windows.Controls.Grid; $grid.Margin = '20'
    foreach ($h in 'Auto', '*', 'Auto') { $r = New-Object Windows.Controls.RowDefinition; $r.Height = $h; $grid.RowDefinitions.Add($r) }
    $head = New-Object Windows.Controls.StackPanel
    $head.Children.Add((New-Text $title 22 '#FFFFFF' $true '0,0,0,4')) | Out-Null
    $head.Children.Add((New-Text $summary 13 '#C2CCDF' $false '0,0,0,8')) | Out-Null
    if ($warning) { $head.Children.Add((New-Text $warning 12 '#FFC857' $false '0,0,0,12')) | Out-Null }
    [Windows.Controls.Grid]::SetRow($head, 0); $grid.Children.Add($head) | Out-Null
    $sv = New-Object Windows.Controls.ScrollViewer; $sv.VerticalScrollBarVisibility = 'Auto'; $list = New-Object Windows.Controls.StackPanel
    foreach ($item in @($items)) {
        $card = New-Object Windows.Controls.Border; $card.Background = Brush '#0F1A2C'; $card.BorderBrush = Brush '#1A2943'
        $card.BorderThickness = 1; $card.CornerRadius = 8; $card.Padding = '12,9'; $card.Margin = '0,0,0,6'
        $card.Child = New-Text ([string]$item) 12 '#C2CCDF' $false; $list.Children.Add($card) | Out-Null
    }
    $sv.Content = $list; [Windows.Controls.Grid]::SetRow($sv, 1); $grid.Children.Add($sv) | Out-Null
    $foot = New-Object Windows.Controls.StackPanel; $foot.Orientation = 'Horizontal'; $foot.HorizontalAlignment = 'Right'; $foot.Margin = '0,12,0,0'
    $cancel = New-Object Windows.Controls.Button; $cancel.Content = 'Cancel'; $cancel.Padding = '16,8'; $cancel.Margin = '0,0,8,0'
    $ok = New-Object Windows.Controls.Button; $ok.Content = $confirmText; $ok.Padding = '16,8'; $ok.Background = Brush '#1FB6FF'; $ok.Foreground = Brush '#06121F'
    $script:Stage1ReviewResult = $false; $script:Stage1ReviewWindow = $w
    $cancel.Add_Click({ $script:Stage1ReviewWindow.Close() }); $ok.Add_Click({ $script:Stage1ReviewResult = $true; $script:Stage1ReviewWindow.Close() })
    $foot.Children.Add($cancel) | Out-Null; $foot.Children.Add($ok) | Out-Null
    [Windows.Controls.Grid]::SetRow($foot, 2); $grid.Children.Add($foot) | Out-Null
    $w.Content = $grid; Tr $w; [void]$w.ShowDialog(); [bool]$script:Stage1ReviewResult
}

$script:restoreList = New-Object Windows.Controls.StackPanel
$script:restoreSignature = $null
$restoreHost = $ui.txtApplied.Parent; $restoreAt = $restoreHost.Children.IndexOf($ui.txtApplied)
$restoreHost.Children.Insert($restoreAt + 1, (New-Text 'Undo individual changes' 14 '#FFFFFF' $true '4,14,0,6'))
$restoreHost.Children.Insert($restoreAt + 2, $script:restoreList)
function Render-ActiveChanges {
    if (-not $script:restoreList) { return }
    $active = @($State.Keys | Sort-Object); $signature = $active -join '|'
    if ($script:restoreSignature -eq $signature -and $script:restoreList.Children.Count) { return }
    $script:restoreSignature = $signature; $script:restoreList.Children.Clear()
    if (-not $active.Count) { $script:restoreList.Children.Add((New-Text 'No tracked changes are currently active.' 12 '#7F8FAE' $false '4,2,0,8')) | Out-Null; return }
    foreach ($id in $active) {
        $tw = Get-Tweak $id; $game = $null
        if ($id -like 'game_*') { $gid = $id -replace '^game_', ''; $game = $Games | Where-Object { $_.Id -eq $gid } | Select-Object -First 1 }
        $name = if ($tw) { $tw.Name } elseif ($game) { "$($game.Name) profile" } else { "Saved change ($id)" }
        $row = New-Object Windows.Controls.Border; $row.Background = Brush '#0F1A2C'; $row.BorderBrush = Brush '#1A2943'; $row.BorderThickness = 1
        $row.CornerRadius = 8; $row.Padding = '10,7'; $row.Margin = '0,0,0,5'; $dock = New-Object Windows.Controls.DockPanel
        $b = New-Object Windows.Controls.Button; $b.Content = 'Undo'; $b.Tag = @{ id = $id; game = [bool]$game }; $b.Padding = '12,5'; $b.Background = Brush '#3A1F2B'
        [Windows.Controls.DockPanel]::SetDock($b, 'Right')
        $b.Add_Click({
            $item = $this.Tag
            if ($item.game) {
                $gid = [string]$item.id -replace '^game_', ''; $g = $Games | Where-Object { $_.Id -eq $gid } | Select-Object -First 1; $label = if ($g) { $g.Name } else { $gid }
                if (Show-ActionPreview 'Review undo' "Restore the saved values for the $label game profile?" @("Game profile: $label") 'Only recorded settings will be restored.' 'Undo profile') { Undo-GameKey ([string]$item.id); Save-State; Render-Tweaks; Update-Stats }
            } else { $t = Get-Tweak ([string]$item.id); if ($t) { Invoke-Undo @($t) } }
        })
        $dock.Children.Add($b) | Out-Null; $dock.Children.Add((New-Text $name 12.5 '#C2CCDF' $false '4,0')) | Out-Null
        $row.Child = $dock; $script:restoreList.Children.Add($row) | Out-Null
    }
}
$script:Stage1BaseStats = ${function:Update-Stats}
function Update-Stats { & $script:Stage1BaseStats; Render-ActiveChanges }
Render-ActiveChanges

# ---------------------------------------------------------------- Stage 2 + 4: game sessions, repeatable measurement, backups, accessibility
$script:GameSessionFile = Join-Path $DataDir 'game-sessions.json'
$script:GameSessionHistoryFile = Join-Path $DataDir 'game-session-history.json'
$script:GameSessionStore = @{ version=1; alwaysKeep=@(); profiles=@{} }
$script:GameSessionHistory = @()
$script:GMProfileKey = '_manual'
try {
    if (Test-Path -LiteralPath $script:GameSessionFile) {
        $saved = Get-Content -LiteralPath $script:GameSessionFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($saved.alwaysKeep) { $script:GameSessionStore.alwaysKeep = @($saved.alwaysKeep | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ -match '^[a-z0-9_.-]+$' } | Select-Object -Unique) }
        if ($saved.profiles) { foreach ($pr in $saved.profiles.PSObject.Properties) { $script:GameSessionStore.profiles[$pr.Name] = $pr.Value } }
    }
    if (Test-Path -LiteralPath $script:GameSessionHistoryFile) { $script:GameSessionHistory = @(Get-Content -LiteralPath $script:GameSessionHistoryFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop | Select-Object -First 50) }
} catch { Log "Game Session settings could not be loaded: $($_.Exception.Message)" }
$script:GM.PriorityChanges = @(); $script:GM.CurrentSession = $null; $script:GM.LastReport = $null
$script:GMProfileLoading = $false
function Get-GMProfileKey {
    $item = $script:cmbGm.SelectedItem
    if ($item -and $item.Uid) { return [string]$item.Uid }
    '_manual'
}
function Get-GMAllowlist {
    $raw = if ($script:txtGmAllowlist) { [string]$script:txtGmAllowlist.Text } else { @($script:GameSessionStore.alwaysKeep) -join ', ' }
    @($raw -split '[,;\r\n]+' | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() -replace '\.exe$','' } | Where-Object { $_ -match '^[a-z0-9_.-]+$' } | Select-Object -Unique)
}
function Save-GameSessionStore {
    try {
        $payload = [ordered]@{ version=1; alwaysKeep=@(Get-GMAllowlist); profiles=$script:GameSessionStore.profiles }
        Write-JsonAtomic -Path $script:GameSessionFile -Value $payload -Depth 8
        $script:GameSessionStore.alwaysKeep = @($payload.alwaysKeep)
    } catch { Log "Game Session settings could not be saved: $($_.Exception.Message)" }
}
function Save-GameModeProfile {
    if ($script:GMProfileLoading -or -not $script:lstGm) { return }
    $key = if ($script:GMProfileKey) { [string]$script:GMProfileKey } else { Get-GMProfileKey }
    $selected = @($script:lstGm.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] -and $_.IsChecked } | ForEach-Object { [string]$_.Tag } | Sort-Object -Unique)
    $mode = if ($script:cmbGmAction.SelectedIndex -eq 1) { 'LowerPriority' } else { 'AskToClose' }
    $script:GameSessionStore.profiles[$key] = @{ selectedProcesses=$selected; processMode=$mode; powerPlan=[bool]$script:chkGmPlan.IsChecked; pauseUpdate=[bool]$script:chkGmWU.IsChecked; trimMemory=[bool]$script:chkGmTrim.IsChecked }
    Save-GameSessionStore
}
function Load-GameModeProfile {
    $script:GMProfileLoading = $true
    try {
        $key = Get-GMProfileKey; $script:GMProfileKey=$key; $profile = $script:GameSessionStore.profiles[$key]
        $script:chkGmPlan.IsChecked = if ($null -ne $profile -and $null -ne $profile.powerPlan) { [bool]$profile.powerPlan } else { $true }
        $script:chkGmWU.IsChecked = if ($null -ne $profile -and $null -ne $profile.pauseUpdate) { [bool]$profile.pauseUpdate } else { $false }
        $script:chkGmTrim.IsChecked = if ($null -ne $profile -and $null -ne $profile.trimMemory) { [bool]$profile.trimMemory } else { $false }
        $script:cmbGmAction.SelectedIndex = if ($profile -and $profile.processMode -eq 'LowerPriority') { 1 } else { 0 }
        if ($script:txtGmAllowlist) { $script:txtGmAllowlist.Text = @($script:GameSessionStore.alwaysKeep) -join ', ' }
        Refresh-GmProcs
        if ($script:gmProfileStatus) { $script:gmProfileStatus.Text = "Rules saved for $key" }
    } finally { $script:GMProfileLoading = $false }
}
function Refresh-GmGames {
    if (-not $script:GMProfileLoading) { Save-GameModeProfile }
    $previous = Get-GMProfileKey; $script:GMProfileLoading = $true
    try {
        $script:cmbGm.Items.Clear()
        $none = New-Object Windows.Controls.ComboBoxItem; $none.Content = 'Manual session'; $none.Uid = '_manual'; $none.Tag = $null; [void]$script:cmbGm.Items.Add($none)
        foreach ($g in $Games) {
            $paths = @($script:GamePaths[$g.Id] | Where-Object { $_ -and (Test-Path -LiteralPath ([string]$_)) })
            if ($paths.Count) { $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = $g.Name; $it.Uid = [string]$g.Id; $it.Tag = [string]$paths[0]; [void]$script:cmbGm.Items.Add($it) }
        }
        $match = @($script:cmbGm.Items | Where-Object { $_.Uid -eq $previous } | Select-Object -First 1)
        $script:cmbGm.SelectedItem = if ($match.Count) { $match[0] } else { $script:cmbGm.Items[0] }
    } finally { $script:GMProfileLoading = $false }
    Load-GameModeProfile
}
function Refresh-GmProcs {
    if (-not $script:lstGm) { return }
    $script:lstGm.Children.Clear(); $keep = @(Get-GMAllowlist)
    $profile = $script:GameSessionStore.profiles[(Get-GMProfileKey)]; $selectedNames = if ($profile) { @($profile.selectedProcesses) } else { @() }
    $list = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.Id -ne $PID -and $ProtectedProcs -notcontains $_.ProcessName } | Group-Object ProcessName | ForEach-Object {
        $group = $_; $first = $group.Group | Select-Object -First 1
        [pscustomobject]@{ Name=$first.ProcessName; Memory=($group.Group | Measure-Object WorkingSet64 -Sum).Sum; Count=$group.Count }
    } | Sort-Object Memory -Descending | Select-Object -First 16)
    foreach ($pr in $list) {
        $name = [string]$pr.Name; $cb = New-Object Windows.Controls.CheckBox; $cb.Tag = $name; $cb.Margin = '5,3'; $cb.Padding = '2,2'; $cb.IsChecked = ($selectedNames -contains $name)
        if ($keep -contains $name.ToLowerInvariant()) { $cb.IsChecked = $false; $cb.IsEnabled = $false; $cb.ToolTip = 'This app is protected by your always-keep list.' }
        $countText = if ($pr.Count -gt 1) { " · $($pr.Count) instances" } else { '' }
        $cb.Content = New-Text ("{0}   {1:N0} MB{2}" -f $name, ($pr.Memory / 1MB), $countText) 12.5 '#C2CCDF'
        $cb.Add_Click({ Save-GameModeProfile })
        $script:lstGm.Children.Add($cb) | Out-Null
    }
    if (-not $list.Count) { $script:lstGm.Children.Add((New-Text 'No other app windows are open.' 12 '#7F8FAE' $false '4,0,0,4')) | Out-Null }
}
function Save-GameSessionHistory {
    try { $script:GameSessionHistory = @($script:GameSessionHistory | Select-Object -First 50); Write-JsonAtomic -Path $script:GameSessionHistoryFile -Value $script:GameSessionHistory -Depth 8 }
    catch { Log "Game Session history could not be saved: $($_.Exception.Message)" }
}
function Show-GameSessionReport {
    $w = New-Object Windows.Window; $w.Title = 'Game Session report'; $w.Width = 720; $w.Height = 560; $w.MinWidth = 540; $w.Background = Brush '#08101D'; $w.Owner = $window; $w.WindowStartupLocation = 'CenterOwner'
    $grid = New-Object Windows.Controls.Grid; $grid.Margin = '20'; foreach ($h in 'Auto','*','Auto') { $r=New-Object Windows.Controls.RowDefinition; $r.Height=$h; $grid.RowDefinitions.Add($r) }
    $grid.Children.Add((New-Text 'Recent sessions' 22 '#FFFFFF' $true '0,0,0,10')) | Out-Null
    $sv=New-Object Windows.Controls.ScrollViewer; $sv.VerticalScrollBarVisibility='Auto'; $body=New-Object Windows.Controls.StackPanel
    if (-not $script:GameSessionHistory.Count) { $body.Children.Add((New-Text 'No Game Sessions have been recorded yet.' 12 '#7F8FAE')) | Out-Null }
    foreach ($report in @($script:GameSessionHistory | Select-Object -First 25)) {
        $card=New-Object Windows.Controls.Border; $card.Background=Brush '#0F1A2C'; $card.BorderBrush=Brush '#1A2943'; $card.BorderThickness=1; $card.CornerRadius=12; $card.Padding='12,10'; $card.Margin='0,0,0,7'
        $stack=New-Object Windows.Controls.StackPanel; $start=[string]$report.started; $mins=[int][math]::Round([double]$report.durationSeconds/60)
        $stack.Children.Add((New-Text ("{0} · {1} min · {2}" -f $report.game,$mins,$start) 13 '#FFFFFF' $true '0,0,0,5')) | Out-Null
        foreach ($check in @($report.checklist)) { $stack.Children.Add((New-Text ([string]$check) 11.5 '#C2CCDF' $false '0,1,0,1')) | Out-Null }
        $card.Child=$stack; $body.Children.Add($card) | Out-Null
    }
    $sv.Content=$body; [Windows.Controls.Grid]::SetRow($sv,1); $grid.Children.Add($sv) | Out-Null
    $close=New-Object Windows.Controls.Button; $close.Content='Close'; $close.Padding='14,8'; $close.HorizontalAlignment='Right'; $close.Tag=$w; $close.Add_Click({$this.Tag.Close()}); [Windows.Controls.Grid]::SetRow($close,2); $grid.Children.Add($close)|Out-Null
    $w.Content=$grid; Tr $w; [void]$w.ShowDialog()
}
function End-GameMode {
    if (-not $script:GM.Active) { return }
    try { if ($script:GM.Timer) { $script:GM.Timer.Stop() } } catch {}
    $checks = New-Object System.Collections.ArrayList
    foreach ($change in @($script:GM.PriorityChanges)) {
        try { $p=Get-Process -Id ([int]$change.id) -ErrorAction Stop; if ($p.ProcessName -eq $change.name) { $p.PriorityClass=[Enum]::Parse([Diagnostics.ProcessPriorityClass],[string]$change.original); [void]$checks.Add("Restored priority: $($change.name)") } else { [void]$checks.Add("Priority restore skipped: process ID changed for $($change.name)") } }
        catch { $still=Get-Process -Id ([int]$change.id) -ErrorAction SilentlyContinue;if($still){[void]$checks.Add("Could not restore priority: $($change.name)")}else{[void]$checks.Add("Priority restore skipped: $($change.name) is no longer running")} }
    }
    if ($script:GM.Plan) { try { powercfg /setactive $script:GM.Plan 2>&1 | Out-Null; [void]$checks.Add('Restored the previous power plan'); Log 'Power plan restored.' } catch { [void]$checks.Add('Could not restore the previous power plan') } }
    if ($script:GM.WUStopped) { try { Start-Service wuauserv -ErrorAction Stop; [void]$checks.Add('Resumed Windows Update'); Log 'Windows Update service resumed.' } catch { [void]$checks.Add('Could not resume Windows Update') } }
    $script:GM.Active = $false; $script:GM.PriorityChanges=@(); $script:GM.Timer=$null
    $script:txtGm.Text = 'Game Session is off.'
    $session=$script:GM.CurrentSession
    if ($session) {
        foreach ($check in $checks) { [void]$session.checklist.Add([string]$check) }
        $ended=Get-Date; $report=[ordered]@{game=$session.game;started=$session.started.ToString('s');ended=$ended.ToString('s');durationSeconds=[math]::Round(($ended-$session.started).TotalSeconds);mode=$session.mode;checklist=@($session.checklist)}
        $script:GameSessionHistory=@($report)+@($script:GameSessionHistory|Select-Object -First 49);$script:GM.LastReport=$report;$script:GM.CurrentSession=$null;Save-GameSessionHistory
        if ($script:gmReportStatus) { $restoreIssue=@($report.checklist|Where-Object{$_ -like 'Could not*'}).Count;$stateLabel=if($restoreIssue){'check report'}else{'restored'};$script:gmReportStatus.Text="Last session: $($report.game) · $([int][math]::Round($report.durationSeconds/60)) min · $stateLabel" }
    }
    Log 'Game Session ended.'; Say 'Game Session ended and saved.'; try { Update-ProChrome } catch {}
}
function Start-GameMode {
    if ($script:GM.Active) { Log 'Game Session is already active.'; return }
    Save-GameModeProfile
    $sel=$script:cmbGm.SelectedItem; $exe=if($sel -and $sel.Tag){[string]$sel.Tag}else{$null}
    if ($exe -and -not (Test-Path -LiteralPath $exe)) { [void][Windows.MessageBox]::Show('The selected game executable is missing. Refresh the game scan and choose it again.','SharkOptimizer'); return }
    $processNames=@($script:lstGm.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] -and $_.IsChecked -and $_.IsEnabled } | ForEach-Object { [string]$_.Tag } | Sort-Object -Unique)
    $mode=if($script:cmbGmAction.SelectedIndex -eq 1){'LowerPriority'}else{'AskToClose'}
    $gameName=if($sel -and $sel.Tag){[string]$sel.Content}else{'Manual session'}
    $preview=@("Game: $gameName","Selected apps: $(if($processNames.Count){$processNames -join ', '}else{'none'})","App action: $(if($mode -eq 'LowerPriority'){'lower priority temporarily'}else{'ask apps to close normally'})")
    if($script:chkGmPlan.IsChecked){$preview+='Switch to the performance power plan; restore the previous plan when the session ends.'}
    if($script:chkGmWU.IsChecked){$preview+='Pause Windows Update only while this session runs; resume it when the session ends.'}
    if($script:chkGmTrim.IsChecked){$preview+='Trim process working sets; memory may refill as apps run.'}
    $warning=if($mode -eq 'AskToClose'){'Selected apps receive a normal close request and can prompt you to save. SharkOptimizer will not force-close them.'}else{'Priority is lowered temporarily and restored when the session ends. The always-keep list is never changed.'}
    if(-not (Show-ActionPreview 'Review Game Session' 'Check which temporary actions will run.' $preview $warning 'Start session')){return}
    $script:GM.Plan=if($script:chkGmPlan.IsChecked){Get-ActivePlan}else{$null}; $script:GM.WUStopped=$false; $script:GM.PriorityChanges=@()
    $session=[ordered]@{game=$gameName;started=(Get-Date);mode=$mode;checklist=(New-Object System.Collections.ArrayList)}
    [void]$session.checklist.Add("Loaded profile: $(Get-GMProfileKey)")
    $script:GM.CurrentSession=$session; $script:GM.Active=$true; $script:GM.Seen=$false; $script:GM.Misses=0; $script:GM.Started=$session.started
    try {
        if($script:chkGmPlan.IsChecked -and -not $script:GM.Plan){[void]$session.checklist.Add('Could not read the current power plan; skipped the plan change')}
        elseif($script:chkGmPlan.IsChecked){
            $target='8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c';$plans=(powercfg /list) -join "`n"
            if($plans -match '99999999-9999-9999-9999-999999999999'){$target='99999999-9999-9999-9999-999999999999'}
            powercfg /setactive $target 2>&1 | Out-Null
            if($LASTEXITCODE -eq 0){[void]$session.checklist.Add('Applied performance power plan');Log "Power plan set to performance ($target)."}else{[void]$session.checklist.Add('Performance power plan unavailable')}
        }
        if($script:chkGmWU.IsChecked){$svc=Get-Service wuauserv -ErrorAction SilentlyContinue;if($svc -and $svc.Status -eq 'Running'){Stop-Service wuauserv -ErrorAction Stop;$script:GM.WUStopped=$true;[void]$session.checklist.Add('Paused Windows Update temporarily')}}
        foreach($name in $processNames){
            if((Get-GMAllowlist) -contains $name.ToLowerInvariant()){[void]$session.checklist.Add("Kept allowlisted app: $name");continue}
            foreach($pr in @(Get-Process -Name $name -ErrorAction SilentlyContinue)){
                if($mode -eq 'LowerPriority'){
                    try{$original=$pr.PriorityClass.ToString();if($original -ne 'Idle' -and $original -ne 'BelowNormal'){$script:GM.PriorityChanges+=@{id=$pr.Id;name=$pr.ProcessName;original=$original};$pr.PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal;[void]$session.checklist.Add("Lowered priority: $($pr.ProcessName)")}}catch{[void]$session.checklist.Add("Could not lower priority: $($pr.ProcessName)")}
                }else{try{if($pr.CloseMainWindow()){[void]$session.checklist.Add("Asked app to close: $($pr.ProcessName)")}else{[void]$session.checklist.Add("App stayed open: $($pr.ProcessName)")}}catch{[void]$session.checklist.Add("Close request failed: $($pr.ProcessName)")}}
            }
        }
        if($script:chkGmTrim.IsChecked){Get-Process -ErrorAction SilentlyContinue|ForEach-Object{try{[void][Boost.Mem]::EmptyWorkingSet($_.Handle)}catch{}};[void]$session.checklist.Add('Trimmed working sets')}
        if($exe){
            $script:GM.ProcName=[IO.Path]::GetFileNameWithoutExtension($exe)
            try{Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -ErrorAction Stop|Out-Null;[void]$session.checklist.Add("Launched game: $gameName")}catch{Log "Could not launch the game: $($_.Exception.Message)";throw}
            $script:txtGm.Text="Game Session is active · $gameName"
            $tm=New-Object Windows.Threading.DispatcherTimer;$tm.Interval=[TimeSpan]::FromSeconds(5)
            $tm.Add_Tick({$running=[bool](Get-Process -Name $script:GM.ProcName -ErrorAction SilentlyContinue);if($running){$script:GM.Seen=$true;$script:GM.Misses=0}else{$script:GM.Misses++;if(($script:GM.Seen -and $script:GM.Misses -ge 2)-or(-not $script:GM.Seen -and ((Get-Date)-$script:GM.Started).TotalSeconds -gt 180)){End-GameMode}}})
            $script:GM.Timer=$tm;$tm.Start()
        }else{$script:GM.ProcName=$null;$script:txtGm.Text='Game Session is active · end it manually when you are done.'}
        Log "Game Session started for $gameName."; Say 'Game Session started.'; try { Update-ProChrome } catch {}
    } catch { Log "Game Session could not start: $($_.Exception.Message)"; End-GameMode; [void][Windows.MessageBox]::Show($_.Exception.Message,'Game Session could not start','OK','Warning') }
}

# Game Session controls: per-game rules, explicit allowlist, manual report access.
$script:chkGmWU.IsChecked=$false; $script:chkGmTrim.IsChecked=$false
$script:chkGmWU.Content='Pause Windows Update during the session (optional)'
$gmIndex=$lab.Children.IndexOf($script:lstGm)
$gmActionLabel=New-Text 'Selected app action' 12 '#C2CCDF' $false '4,8,0,2'
$script:cmbGmAction=New-Object Windows.Controls.ComboBox;$script:cmbGmAction.Width=300;$script:cmbGmAction.Margin='4,0,0,6'
[void]$script:cmbGmAction.Items.Add('Ask selected apps to close normally');[void]$script:cmbGmAction.Items.Add('Lower priority temporarily');$script:cmbGmAction.SelectedIndex=0
$gmAllowLabel=New-Text 'Always keep these apps (process names, comma-separated)' 12 '#C2CCDF' $false '4,6,0,2'
$script:txtGmAllowlist=New-Object Windows.Controls.TextBox;$script:txtGmAllowlist.Width=500;$script:txtGmAllowlist.HorizontalAlignment='Left';$script:txtGmAllowlist.Text=@($script:GameSessionStore.alwaysKeep)-join ', '
$script:gmProfileStatus=New-Text 'Rules are saved separately for each game.' 11.5 '#7F8FAE' $false '4,4,0,4'
$gmProfileRow=New-Object Windows.Controls.WrapPanel
$gmSaveProfile=New-Object Windows.Controls.Button;$gmSaveProfile.Content='Save game rules';$gmSaveProfile.Padding='11,6';$gmSaveProfile.Add_Click({Save-GameModeProfile;Say 'Game Session rules saved.'})
$gmSaveAllow=New-Object Windows.Controls.Button;$gmSaveAllow.Content='Save allowlist';$gmSaveAllow.Padding='11,6';$gmSaveAllow.Add_Click({$script:GameSessionStore.alwaysKeep=@(Get-GMAllowlist);Refresh-GmProcs;Save-GameSessionStore;Save-GameModeProfile;Say 'Always-keep apps saved.'})
$gmReportButton=New-Object Windows.Controls.Button;$gmReportButton.Content='Session report';$gmReportButton.Padding='11,6';$gmReportButton.Add_Click({Show-GameSessionReport})
foreach($b in $gmSaveProfile,$gmSaveAllow,$gmReportButton){$gmProfileRow.Children.Add($b)|Out-Null}
$script:gmReportStatus=New-Text 'No sessions recorded yet.' 11.5 '#7F8FAE' $false '4,6,0,4'
if($script:GameSessionHistory.Count){$last=$script:GameSessionHistory[0];$script:gmReportStatus.Text="Last session: $($last.game) · $([int][math]::Round([double]$last.durationSeconds/60)) min · saved report available"}
if($gmIndex -ge 0){$insertAt=$gmIndex;foreach($element in @($script:gmProfileStatus,$gmProfileRow,$gmActionLabel,$script:cmbGmAction,$gmAllowLabel,$script:txtGmAllowlist)){$lab.Children.Insert($insertAt,$element);$insertAt++}}
$closeAppsLabel=$lab.Children|Where-Object{$_ -is [Windows.Controls.TextBlock] -and $_.Text -eq 'Close these apps first:'}|Select-Object -First 1;if($closeAppsLabel){$closeAppsLabel.Text='Apps to manage during this session:'}
$gmStatusAt=$lab.Children.IndexOf($script:txtGm);if($gmStatusAt -ge 0){$lab.Children.Insert($gmStatusAt+1,$script:gmReportStatus)}
function Wrap-LabSection($startTitle,$endTitle){
    $start=-1;$end=$lab.Children.Count
    for($i=0;$i -lt $lab.Children.Count;$i++){ $child=$lab.Children[$i];if($child -is [Windows.Controls.TextBlock] -and $child.Text -eq $startTitle){$start=$i;break} }
    if($start -lt 0){return}
    for($i=$start+1;$i -lt $lab.Children.Count;$i++){ $child=$lab.Children[$i];if($child -is [Windows.Controls.TextBlock] -and $child.Text -eq $endTitle){$end=$i;break} }
    $content=New-Object Windows.Controls.StackPanel
    for($i=$start;$i -lt $end;$i++){ $element=$lab.Children[$start];$lab.Children.RemoveAt($start);$content.Children.Add($element)|Out-Null }
    $card=New-Object Windows.Controls.Border;$card.Background=Brush '#0F1A2C';$card.BorderBrush=Brush '#1A2943';$card.BorderThickness=1;$card.CornerRadius=16;$card.Padding='16,12';$card.Margin='0,10,0,10';$card.Child=$content;$lab.Children.Insert($start,$card)
}
Wrap-LabSection 'Before and after benchmark' 'Game Mode';Wrap-LabSection 'Game Mode' 'System check'
$script:cmbGm.Add_SelectionChanged({if(-not $script:GMProfileLoading){Save-GameModeProfile;Load-GameModeProfile}})
$script:cmbGmAction.Add_SelectionChanged({Save-GameModeProfile})
foreach($cb in $script:chkGmPlan,$script:chkGmWU,$script:chkGmTrim){$cb.Add_Click({Save-GameModeProfile})}
Refresh-GmGames;Refresh-GmProcs

# Repeatable before/after benchmark history. Show medians across the latest three samples.
$script:BenchProgress=New-Object Windows.Controls.ProgressBar;$script:BenchProgress.IsIndeterminate=$false;$script:BenchProgress.Value=0;$script:BenchProgress.Visibility='Collapsed';$script:BenchProgress.Margin='4,6,0,2'
$lab.Children.Insert([Math]::Max(0,$lab.Children.IndexOf($script:txtBenchStatus)+1),$script:BenchProgress)
$script:OriginalGetBench=${function:Get-Bench}
function Get-Bench {$script:BenchProgress.Visibility='Visible';$script:BenchProgress.IsIndeterminate=$true;$script:txtBenchStatus.Text='Running benchmark samples…';Flush-UI;try{& $script:OriginalGetBench}finally{$script:BenchProgress.IsIndeterminate=$false;$script:BenchProgress.Value=100;$script:BenchProgress.Visibility='Collapsed'}}
function Save-Bench($slot,$res){
    $store=@{};if(Test-Path -LiteralPath $BenchFile){try{$old=Get-Content -LiteralPath $BenchFile -Raw|ConvertFrom-Json;foreach($prop in $old.PSObject.Properties){$store[$prop.Name]=$prop.Value}}catch{}}
    $runs=@($store.Runs|Where-Object{$_});$runs=@(@{slot=$slot;time=(Get-Date).ToString('s');data=$res})+@($runs|Select-Object -First 59)
    $store[$slot]=$res;$store["${slot}Time"]=(Get-Date).ToString('s');$store.Runs=$runs
    Write-JsonAtomic -Path $BenchFile -Value $store -Depth 8
}
function Get-BenchSampleCount($doc,$slot){$n=@($doc.Runs|Where-Object{$_.slot -eq $slot}).Count;if(-not $n -and $doc.$slot){$n=1};$n}
function Get-BenchMedian($runs,$key){
    $values=@($runs|ForEach-Object{if($_.data){$v=$_.data.$key}else{$v=$_.Value};if($null -ne $v){try{[double]$v}catch{}}}|Sort-Object)
    if(-not $values.Count){return $null};$mid=[int][math]::Floor($values.Count/2);if($values.Count%2){return $values[$mid]};(($values[$mid-1]+$values[$mid])/2)
}
function Format-Bench {
    if(-not(Test-Path -LiteralPath $BenchFile)){return 'No results yet. Save several BEFORE samples, apply tweaks, then save matching AFTER samples.'}
    try{$d=Get-Content -LiteralPath $BenchFile -Raw|ConvertFrom-Json}catch{return 'Benchmark history could not be read.'}
    $labels=[ordered]@{PingMs='Ping (ms)';JitterMs='Jitter (ms)';DnsMs='DNS lookup (ms)';CpuIdlePct='CPU idle (%)';RamUsedPct='RAM used (%)';Processes='Processes';Services='Running services';BootSec='Last boot (s)'}
    $before=@($d.Runs|Where-Object{$_.slot -eq 'Before'}|Sort-Object time -Descending|Select-Object -First 3);$after=@($d.Runs|Where-Object{$_.slot -eq 'After'}|Sort-Object time -Descending|Select-Object -First 3)
    if(-not $before.Count -and $d.Before){$before=@(@{data=$d.Before})};if(-not $after.Count -and $d.After){$after=@(@{data=$d.After})}
    $out=New-Object System.Collections.ArrayList;[void]$out.Add(("Before: {0} sample(s) · After: {1} sample(s) · median of up to 3" -f $before.Count,$after.Count));[void]$out.Add('')
    [void]$out.Add(("{0,-22}{1,12}{2,12}   {3}" -f 'Metric','Before','After','Result'));[void]$out.Add('-'*67)
    foreach($key in $labels.Keys){$b=Get-BenchMedian $before $key;$a=Get-BenchMedian $after $key;$bs=if($null -ne $b){'{0:N1}' -f $b}else{'—'};$as=if($null -ne $a){'{0:N1}' -f $a}else{'—'};$result=''
        if($null -ne $b -and $null -ne $a){$diff=[double]$a-[double]$b;if($key -in @('Processes','Services')){$result=('{0:+0.0;-0.0;0.0} · context' -f $diff)}elseif([math]::Abs($diff)-lt 0.05){$result='No clear change'}else{$better=if($key -eq 'CpuIdlePct'){$diff -gt 0}else{$diff -lt 0};$result=('{0:+0.0;-0.0;0.0} · {1}' -f $diff,$(if($better){'better'}else{'worse'}))}}
        [void]$out.Add(("{0,-22}{1,12}{2,12}   {3}" -f $labels[$key],$bs,$as,$result))
    }
    [void]$out.Add('');[void]$out.Add('Latency, RAM use and boot time: lower is better. CPU idle: higher is better. Process and service counts are context, not a score. Repeat samples under similar conditions for a steadier comparison.')
    $out -join "`r`n"
}
foreach($wrap in @($lab.Children|Where-Object{$_ -is [Windows.Controls.Panel]})){foreach($button in @($wrap.Children|Where-Object{$_ -is [Windows.Controls.Button] -and $_.Content -in @('Run BEFORE','Run AFTER')})){$slot=if($button.Content -eq 'Run BEFORE'){'Before'}else{'After'};$button.Tag=$slot;$button.Add_Click({$which=[string]$this.Tag;$doc=$null;try{$doc=Get-Content -LiteralPath $BenchFile -Raw|ConvertFrom-Json}catch{};$n=if($doc){Get-BenchSampleCount $doc $which}else{0};$script:txtBenchStatus.Text="Saved $which sample $n. Repeat up to three times for a steadier comparison.";$script:txtBench.Text=Format-Bench})}}
$script:txtBench.Text=Format-Bench

# Settings and profile backup. Windows tweak/undo state is deliberately not imported.
$script:BackupPaths=[ordered]@{'settings.json'=$SettingsFile;'presets.json'=$PresetsFile;'games-cache.json'=$GameCache;'custom-games.json'=$CustomGamesFile;'custom-tweaks.json'=$CustomTweaksFile;'game-sessions.json'=$script:GameSessionFile;'bench.json'=$BenchFile}
function Export-AppBackup {
    $dlg=New-Object Microsoft.Win32.SaveFileDialog;$dlg.Title='Export SharkOptimizer backup';$dlg.Filter='SharkOptimizer backup (*.json)|*.json';$dlg.FileName='SharkOptimizer-Backup.json';$dlg.AddExtension=$true
    if($dlg.ShowDialog($window)-ne $true){return};$files=@{}
    try{foreach($name in $script:BackupPaths.Keys){$path=$script:BackupPaths[$name];if(Test-Path -LiteralPath $path){$raw=[IO.File]::ReadAllText($path);$null=$raw|ConvertFrom-Json -ErrorAction Stop;$files[$name]=$raw}};$payload=[ordered]@{format='SharkOptimizerBackup';version=1;created=(Get-Date).ToString('s');files=$files};[IO.File]::WriteAllText($dlg.FileName,(ConvertTo-Json -InputObject $payload -Depth 16),(New-Object Text.UTF8Encoding $false));Say ("Backup exported with {0} data files." -f $files.Count)}catch{Log "Backup export failed: $($_.Exception.Message)";[void][Windows.MessageBox]::Show($_.Exception.Message,'Backup export failed','OK','Warning')}
}
function Import-AppBackup {
    $dlg=New-Object Microsoft.Win32.OpenFileDialog;$dlg.Title='Import SharkOptimizer backup';$dlg.Filter='SharkOptimizer backup (*.json)|*.json|All files (*.*)|*.*';$dlg.Multiselect=$false
    if($dlg.ShowDialog($window)-ne $true){return}
    try{$file=Get-Item -LiteralPath $dlg.FileName;if($file.Length -gt 4MB){throw 'Backup is larger than 4 MB.'};$data=Get-Content -LiteralPath $dlg.FileName -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop;if($data.format -ne 'SharkOptimizerBackup' -or [int]$data.version -ne 1){throw 'This is not a supported SharkOptimizer backup.'};$valid=@{}
        foreach($prop in $data.files.PSObject.Properties){if(-not $script:BackupPaths.Contains($prop.Name)){continue};$raw=[string]$prop.Value;if($raw.Length -gt 2MB){throw "Backup entry '$($prop.Name)' is too large."};$obj=$raw|ConvertFrom-Json -ErrorAction Stop;if($null -eq $obj){throw "Backup entry '$($prop.Name)' is empty."};$valid[$prop.Name]=$obj}
        if(-not $valid.Count){throw 'No supported settings or profiles were found in the backup.'};$preview=@($valid.Keys|Sort-Object|ForEach-Object{"$($_) will be replaced; the current file is backed up first."})
        if(-not(Show-ActionPreview 'Review settings backup' 'Import app preferences and profiles. Windows changes and undo history are not included.' $preview 'Existing app settings will be backed up beside each file. Restart SharkOptimizer after importing.' 'Import backup')){return}
        foreach($name in $valid.Keys){Write-JsonAtomic -Path $script:BackupPaths[$name] -Value $valid[$name] -Depth 16};[void][Windows.MessageBox]::Show('Backup imported. Restart SharkOptimizer to load the restored settings and profiles.','Backup imported','OK','Information')
    }catch{Log "Backup import failed: $($_.Exception.Message)";[void][Windows.MessageBox]::Show($_.Exception.Message,'Backup import failed','OK','Warning')}
}
Add-SetSection 'Backup and accessibility' 'Export your preferences and profiles, or enlarge text for easier reading.'
$backupRow=New-Object Windows.Controls.WrapPanel
$exportBackup=New-Object Windows.Controls.Button;$exportBackup.Content='Export setup backup';$exportBackup.Padding='12,8';$exportBackup.Add_Click({Export-AppBackup})
$importBackup=New-Object Windows.Controls.Button;$importBackup.Content='Import setup backup';$importBackup.Padding='12,8';$importBackup.Add_Click({Import-AppBackup})
$backupRow.Children.Add($exportBackup)|Out-Null;$backupRow.Children.Add($importBackup)|Out-Null;$setPanel.Children.Add($backupRow)|Out-Null
$scaleLabel=New-Text 'Text size' 12 '#C2CCDF' $false '4,8,0,3';$setPanel.Children.Add($scaleLabel)|Out-Null
$script:scaleCombo=New-Object Windows.Controls.ComboBox;$script:scaleCombo.Width=180;$script:scaleCombo.HorizontalAlignment='Left';$script:scaleCombo.Margin='4,0,0,8'
foreach($option in @(@('90%','0.9'),@('100%','1'),@('110%','1.1'),@('125%','1.25'))){$item=New-Object Windows.Controls.ComboBoxItem;$item.Content=$option[0];$item.Tag=[double]::Parse($option[1],[Globalization.CultureInfo]::InvariantCulture);[void]$script:scaleCombo.Items.Add($item)}
$script:TextScale=if($Settings.TextScale){[double]$Settings.TextScale}else{1.0};if($script:TextScale -notin @(0.9,1.0,1.1,1.25)){$script:TextScale=1.0};$script:scaleCombo.SelectedItem=@($script:scaleCombo.Items|Where-Object{[double]$_.Tag -eq $script:TextScale}|Select-Object -First 1)[0];$setPanel.Children.Add($script:scaleCombo)|Out-Null
$script:FontScaleEntries=@{}
function Register-FontScaleElement($element,[double]$baseSize){if(-not $element){return};$id=[Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($element).ToString();if(-not $script:FontScaleEntries.ContainsKey($id)){$script:FontScaleEntries[$id]=New-Object System.Collections.ArrayList};foreach($entry in @($script:FontScaleEntries[$id])){if($entry.reference.IsAlive -and [object]::ReferenceEquals($entry.reference.Target,$element)){return}};[void]$script:FontScaleEntries[$id].Add(@{reference=[System.WeakReference]::new($element);base=$baseSize})}
$script:OriginalNewText24=${function:New-Text}
function New-Text($text,$size=12,$color='#C2CCDF',$bold=$false,$margin='0'){$tb=& $script:OriginalNewText24 $text $size $color $bold $margin;Register-FontScaleElement $tb ([double]$size);$tb.FontSize=[math]::Round(([double]$size*$script:TextScale),1);$tb}
function Apply-AccessibilityScale([bool]$discover=$false) {
    if($discover){$walk=New-Object System.Collections.Stack;$walk.Push($window);while($walk.Count){$el=$walk.Pop();if($el -is [Windows.Controls.Control] -or $el -is [Windows.Controls.TextBlock]){Register-FontScaleElement $el ([double]$el.FontSize)};try{foreach($child in @([Windows.LogicalTreeHelper]::GetChildren($el))){if($child -is [Windows.DependencyObject]){$walk.Push($child)}}}catch{}}}
    foreach($bucket in @($script:FontScaleEntries.Values)){foreach($entry in @($bucket)){if($entry.reference.IsAlive){try{$entry.reference.Target.FontSize=[math]::Round(([double]$entry.base*$script:TextScale),1)}catch{}}else{[void]$bucket.Remove($entry)}}}
}
$script:scaleCombo.Add_SelectionChanged({if($this.SelectedItem){$script:TextScale=[double]$this.SelectedItem.Tag;$Settings.TextScale=$script:TextScale;Save-Settings;Apply-AccessibilityScale $false}})
$script:OriginalStage24ShowPage=${function:Show-Page}
function Show-Page($nav){& $script:OriginalStage24ShowPage $nav;Apply-AccessibilityScale $false}
Apply-AccessibilityScale $true

# ---------------------------------------------------------------- start
Log "Loaded $($Tweaks.Count) tweaks and $($Games.Count) game profiles. Detected: $($Spec.Tier) PC, $($Spec.RamGB) GB RAM, $($Spec.GPU)."
Render-Tweaks
Render-GameList
Show-Page 'navDash'
$window.Add_ContentRendered({
    try { Animate-In $window.Content 0 0 450 } catch {}
    $script:startupTimer = New-Object Windows.Threading.DispatcherTimer
    $script:startupTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:startupTimer.Add_Tick({
        $script:startupTimer.Stop()
        try { Refresh-Startup } catch { Log "Startup list refresh failed: $($_.Exception.Message)" }
        try { Refresh-Procs } catch { Log "Process list refresh failed: $($_.Exception.Message)" }
        try { Refresh-Bloat } catch { Log "Built-in app scan failed: $($_.Exception.Message)" }
    })
    $script:startupTimer.Start()
})
[void]$window.ShowDialog()
Save-State
