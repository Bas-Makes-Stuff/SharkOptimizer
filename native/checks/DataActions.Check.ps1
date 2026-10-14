param([string]$AppPath)
$ErrorActionPreference = 'Stop'
if (!$AppPath) { $AppPath = Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$type = $assembly.GetType('SharkOptimizer.NativeApp.MainWindow')
$state = [Activator]::CreateInstance($assembly.GetType('SharkOptimizer.NativeApp.AppState'))
$state.Accent = 'purple'; $state.InterfaceScale = 1.25; $state.AutoCheckUpdates = $false
$state.AutoDownloadUpdates = $false; $state.AlwaysRestorePoint = $true; $state.ReduceMotion = $true
$state.CleanupDay = 'FRI'; $state.CleanupTime = '19:30'; $state.SessionPreviousPlan = 'sentinel'
$state.GamePaths['test'] = New-Object 'Collections.Generic.List[string]'
$state.GamePaths['test'].Add('C:\Games\test.exe')
$paths = $state.GamePaths; $undo = $state.Applied; $presets = $state.SavedPresets; $games = $state.CustomGames
$reset = $type.GetMethod('ResetAppPreferences',[Reflection.BindingFlags]'Static,NonPublic')
$reset.Invoke($null,@($state,'nl'))
if ($state.Accent -ne 'blue' -or $state.InterfaceScale -ne 1 -or !$state.AutoCheckUpdates -or !$state.AutoDownloadUpdates -or $state.AlwaysRestorePoint -or $state.ReduceMotion -or $state.Language -ne 'nl') { throw 'Reset defaults are incorrect.' }
if (![Object]::ReferenceEquals($paths,$state.GamePaths) -or ![Object]::ReferenceEquals($undo,$state.Applied) -or ![Object]::ReferenceEquals($presets,$state.SavedPresets) -or ![Object]::ReferenceEquals($games,$state.CustomGames) -or $state.GamePaths['test'][0] -ne 'C:\Games\test.exe' -or $state.CleanupDay -ne 'FRI' -or $state.CleanupTime -ne '19:30' -or $state.SessionPreviousPlan -ne 'sentinel') { throw 'Reset changed profiles, recovery state, or schedule preferences.' }
$reset.Invoke($null,@($state,'unsupported'))
if ($state.Language -ne 'en') { throw 'Unsupported Windows language did not fall back to English.' }
Add-Type -AssemblyName System.Web.Extensions
$serializer = New-Object Web.Script.Serialization.JavaScriptSerializer
$reloaded = $serializer.Deserialize($serializer.Serialize($state),$state.GetType())
if ($reloaded.Language -ne 'en' -or !$reloaded.LegacyLanguageImported -or !$reloaded.LegacyRestorePointImported) { throw 'Reset preferences did not survive serialization.' }
'PASS: Preference defaults, language fallback, persisted migration flags, and preservation of profiles, undo, session recovery, and schedule preferences. No user settings were changed.'
