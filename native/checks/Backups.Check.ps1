param([string]$AppPath)
$ErrorActionPreference = 'Stop'
if (-not $AppPath) { $AppPath = Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Web.Extensions
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$windowType = $assembly.GetType('SharkOptimizer.NativeApp.MainWindow')
$codec = $assembly.GetType('SharkOptimizer.NativeApp.SetupBackupCodec')
$stateType = $assembly.GetType('SharkOptimizer.NativeApp.AppState')
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$aliases = $windowType.GetField('LegacyTweakAliases',$flags).GetValue($null)
$definitions = $windowType.GetField('Definitions',$flags).GetValue($null)
$nativeIds = @($definitions | ForEach-Object { $_.GetType().GetField('Id').GetValue($_) })
$map = [Func[string,string]] { param($id) if ($aliases.ContainsKey($id)) { return $aliases[$id] }; if ($nativeIds -contains $id) { return $id }; return $null }
$export = [Func[string,string]] { param($id) foreach ($pair in $aliases.GetEnumerator()) { if ($pair.Value -eq $id) { return $pair.Key } }; return $id }
$serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$serializer.MaxJsonLength = 4MB
$state = [Activator]::CreateInstance($stateType)
$state.Accent = 'purple'; $state.InterfaceScale = 1.25; $state.AutoCheckUpdates = $false
$state.AutoDownloadUpdates = $false
$state.AlwaysRestorePoint = $true
$state.Toasts=$false; $state.ShowLog=$false; $state.ScanOnStart=$true; $state.ReduceMotion=$true
$state.Language='de'
$preset = [Activator]::CreateInstance($assembly.GetType('SharkOptimizer.NativeApp.UserPreset'))
$preset.Name = 'Portable gaming'; $preset.Ids.Add('game-mode'); $state.SavedPresets.Add($preset)
$undo = [Activator]::CreateInstance($assembly.GetType('SharkOptimizer.NativeApp.AppliedTweak'))
$undo.Id = 'undo-sentinel'; $undo.Name = 'Tracked change'; $state.Applied.Add($undo)
$state.SessionPreviousPlan = '381b4222-f694-41f0-9685-ff5bb260df2e'
$captured = $codec.GetMethod('Capture',$flags).Invoke($null,@($state))
$json = $codec.GetMethod('Encode',$flags).Invoke($null,@($captured,$export))
$root = $serializer.DeserializeObject($json)
$portable = $serializer.DeserializeObject($root.files['native-setup.json'])
if ($portable.ContainsKey('Applied') -or $portable.ContainsKey('SessionPreviousPlan')) { throw 'Undo or session recovery leaked into the portable data.' }
$decoded = $codec.GetMethod('Decode',$flags).Invoke($null,@($json,$map))
if ($decoded.Preferences.Accent -ne 'purple' -or $decoded.Presets[0].Ids[0] -ne 'game-mode') { throw 'Native backup round-trip failed.' }
$target = [Activator]::CreateInstance($stateType); $target.Applied.Add($undo); $target.SessionPreviousPlan = $state.SessionPreviousPlan
$undoList = $target.Applied
$codec.GetMethod('Apply',$flags).Invoke($null,@($target,$decoded))
if (![Object]::ReferenceEquals($undoList,$target.Applied) -or $target.Applied[0].Id -ne 'undo-sentinel' -or $target.SessionPreviousPlan -ne $state.SessionPreviousPlan) { throw 'Applying a backup changed undo or session recovery.' }
if ($target.Accent -ne 'purple' -or $target.InterfaceScale -ne 1.25 -or $target.AutoCheckUpdates -ne $false) { throw 'Imported preferences did not apply.' }
if ($target.AutoDownloadUpdates) { throw 'The automatic-download preference did not survive the backup round-trip.' }
if (!$target.AlwaysRestorePoint) { throw 'The restore-point preference did not survive the backup round-trip.' }
if ($target.Toasts -or $target.ShowLog -or !$target.ScanOnStart -or !$target.ReduceMotion) { throw 'Behavior preferences did not survive the backup round-trip.' }
if ($target.Language -ne 'de') { throw 'Language did not survive the backup round-trip.' }
$legacyFiles = @{
 'settings.json'='{"Accent":"green","AutoUpdate":false,"TextScale":1.1,"Language":"nl","AlwaysRestorePoint":true,"CleanDay":"Friday","CleanTime":"9:30"}'
 'presets.json'='[{"name":"Legacy preset","ids":["f_gamemode"]},{"name":"Legacy custom preset","ids":["c_example"]}]'
 'games-cache.json'='{"valorant":["C:\\Games\\VALORANT.exe"]}'
 'custom-games.json'='[{"id":"mygame","name":"My game","exes":["mygame.exe"],"tweaks":["f_gamemode"],"tips":["My tip"],"enabled":true}]'
 'custom-tweaks.json'='[{"id":"c_example","name":"Example","enabled":false,"reg":[{"path":"HKCU:\\Software\\Example","name":"Value","value":1,"type":"DWord"}]}]'
 'game-sessions.json'='{"version":1,"alwaysKeep":["discord"],"profiles":{}}'
 'bench.json'='{"Before":{"PingMs":20,"JitterMs":2,"DnsMs":5,"CpuIdlePct":4,"RamUsedPct":40,"Processes":80,"Services":100,"BootSec":15}}'
}
$legacyJson = $serializer.Serialize(@{format='SharkOptimizerBackup';version=1;files=$legacyFiles})
$legacy = $codec.GetMethod('Decode',$flags).Invoke($null,@($legacyJson,$map))
if ($legacy.Preferences.Accent -ne 'green' -or $legacy.Presets[0].Ids[0] -ne 'game-mode' -or $legacy.CustomGames.Count -ne 1 -or $legacy.BenchBefore.PingMs -ne 20) { throw 'Legacy backup conversion failed.' }
if ($legacy.LegacyFiles.Count -ne 7) { throw 'Legacy files were not preserved.' }
if (!$legacy.Preferences.AlwaysRestorePoint) { throw 'Legacy restore-point preference was lost.' }
if ($legacy.Preferences.CleanupDay -ne 'FRI' -or $legacy.Preferences.CleanupTime -ne '09:30') { throw 'Legacy cleanup schedule preferences were lost.' }
if ($legacy.CustomTweaks.Count -ne 1 -or $legacy.Presets[1].Ids[0] -ne 'c_example') { throw 'A custom definition or dependent preset was lost.' }
$legacyRoundTrip = $serializer.DeserializeObject($codec.GetMethod('Encode',$flags).Invoke($null,@($legacy,$export)))
if (($serializer.DeserializeObject($legacyRoundTrip.files['settings.json'])).CleanDay -ne 'Friday' -or ($serializer.DeserializeObject($legacyRoundTrip.files['settings.json'])).CleanTime -ne '09:30') { throw 'Cleanup preferences were not exported in legacy form.' }
if (!$legacyRoundTrip.files.ContainsKey('custom-tweaks.json') -or !$legacyRoundTrip.files.ContainsKey('game-sessions.json') -or ($serializer.DeserializeObject($legacyRoundTrip.files['settings.json'])).Language -ne 'nl') { throw 'Unported legacy data was lost on export.' }
$partialJson = $serializer.Serialize(@{format='SharkOptimizerBackup';version=1;files=@{'presets.json'='[]'}})
$partial = $codec.GetMethod('Decode',$flags).Invoke($null,@($partialJson,$map))
$codec.GetMethod('Apply',$flags).Invoke($null,@($target,$partial))
if ($target.SavedPresets.Count -ne 0 -or $target.Accent -ne 'purple' -or $target.Applied.Count -ne 1) { throw 'Partial import replaced unrelated data.' }
$rejected = 0
$badFiles = @(
 '{"format":"other","version":1,"files":{}}',
 '{"format":"SharkOptimizerBackup","version":2,"files":{}}',
 '{"format":"SharkOptimizerBackup","version":1,"files":{"state.json":"{}"}}',
 '{"format":"SharkOptimizerBackup","version":1,"files":{"native-setup.json":"{\"Preferences\":{\"Accent\":\"invalid\"}}"}}'
)
foreach ($bad in $badFiles) { try { $null = $codec.GetMethod('Decode',$flags).Invoke($null,@($bad,$map)) } catch { $rejected++ } }
if ($rejected -ne $badFiles.Count) { throw 'Invalid backup input was accepted.' }
'Native and legacy backups, preserved legacy files, preference restoration, partial imports, undo/session preservation, and invalid-input checks passed.'
