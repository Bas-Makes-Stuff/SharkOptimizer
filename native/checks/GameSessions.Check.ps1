param([string]$AppPath)
$ErrorActionPreference = 'Stop'
if (-not $AppPath) { $AppPath = Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$type = $assembly.GetType('SharkOptimizer.NativeApp.SessionProcessIdentity')
$identity = [Activator]::CreateInstance($type,$true)
$process = [Diagnostics.Process]::GetCurrentProcess()
$identity.Id = $process.Id
$identity.Name = $process.ProcessName
$identity.StartedUtc = $process.StartTime.ToUniversalTime()
$matches = $type.GetMethod('Matches',[Reflection.BindingFlags]'Instance,NonPublic')
if (!$matches.Invoke($identity,@($process))) { throw 'A valid process identity did not match.' }
$identity.StartedUtc = $identity.StartedUtc.AddSeconds(-1)
if ($matches.Invoke($identity,@($process))) { throw 'A reused process ID could match a different start time.' }
$identity.StartedUtc = $process.StartTime.ToUniversalTime()
$identity.Name = 'DifferentProcess'
if ($matches.Invoke($identity,@($process))) { throw 'A changed process name was accepted.' }
$windowType = $assembly.GetType('SharkOptimizer.NativeApp.MainWindow')
$protected = $windowType.GetMethod('IsProtectedSessionProcess',[Reflection.BindingFlags]'Static,NonPublic')
foreach ($name in @('explorer','DWM','powershell','SharkOptimizer.Native','csrss','winlogon')) {
 if (!$protected.Invoke($null,@($name))) { throw ('Core process was not protected: ' + $name) }
}
if ($protected.Invoke($null,@('OrdinarySampleApp'))) { throw 'An ordinary app was falsely excluded.' }
$process.Dispose()
'Current-process identity, changed start time/name rejection, and core app protection checks passed. No apps were closed.'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Web.Extensions
[Environment]::CurrentDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$codec = $assembly.GetType('SharkOptimizer.NativeApp.GameSessionCodec')
$staticFlags = [Reflection.BindingFlags]'Static,NonPublic'
$read = $codec.GetMethod('Read',$staticFlags)
$store = $read.Invoke($null,@('{"version":1,"alwaysKeep":["Discord.EXE","discord"],"profiles":{"_manual":{"selectedProcesses":["STEAM.exe"],"processMode":"LowerPriority","powerPlan":true,"pauseUpdate":true,"trimMemory":true}}}'))
if ($store.AlwaysKeep.Count -ne 1 -or $store.AlwaysKeep[0] -ne 'discord' -or $store.Profiles['_manual'].SelectedProcesses[0] -ne 'steam' -or !$store.Profiles['_manual'].PauseUpdate -or !$store.Profiles['_manual'].TrimMemory) { throw 'Legacy profile names/options were not preserved.' }
foreach ($bad in @('{"version":2,"profiles":{}}','{"version":1,"alwaysKeep":["C:\\app.exe"],"profiles":{}}','{"version":1,"profiles":{"_manual":{"processMode":"Kill"}}}')) {
 $rejected=$false; try { $null=$read.Invoke($null,@($bad)) } catch { $rejected=$true }; if (!$rejected) { throw 'Invalid session settings were accepted.' }
}
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$window = $windowType.GetConstructor($flags,$null,[Type[]]@([bool]),$null).Invoke(@($true))
$state = $windowType.GetField('_state',$flags).GetValue($window)
$state.GameSessions = $store
$null=$windowType.GetMethod('ShowPage',$flags).Invoke($window,@('Game Session'))
if ($windowType.GetField('_sessionAppAction',$flags).GetValue($window).SelectedIndex -ne 1 -or !$windowType.GetField('_sessionUsePerformancePlan',$flags).GetValue($window).IsChecked) { throw 'Saved profile controls did not load.' }
$selected = New-Object Windows.Controls.CheckBox
$keptIdentity = [Activator]::CreateInstance($type,$true); $keptIdentity.Name='discord'
$null=$windowType.GetMethod('ApplySessionProcessSelection',$flags).Invoke($window,@($selected.PSObject.BaseObject,$keptIdentity))
if ($selected.IsEnabled -or $selected.IsChecked) { throw 'Protected app remained selectable.' }
if (!$windowType.GetMethod('IsKeptSessionProcess',$flags).Invoke($window,@('VALORANT-Win64-Shipping'))) { throw 'A known game was not excluded from session app actions.' }
$fixtureDir=Join-Path $env:TEMP ('SharkSessionCheck-' + [Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixtureDir
$fixture=Join-Path $fixtureDir 'SessionFixture.exe'
Add-Type -TypeDefinition 'public static class SessionCheckFixture { public static void Main() { System.Console.ReadLine(); } }' -OutputAssembly $fixture -OutputType ConsoleApplication
$child=New-Object Diagnostics.Process
$child.StartInfo=New-Object Diagnostics.ProcessStartInfo $fixture
$child.StartInfo.UseShellExecute=$false; $child.StartInfo.CreateNoWindow=$true; $child.StartInfo.RedirectStandardInput=$true
$null=$child.Start()
try {
 $childIdentity=[Activator]::CreateInstance($type,$true)
 $childIdentity.Id=$child.Id; $childIdentity.Name=$child.ProcessName; $childIdentity.StartedUtc=$child.StartTime.ToUniversalTime(); $childIdentity.StartedTicks=$childIdentity.StartedUtc.Ticks
 $original=$child.PriorityClass
 $null=$windowType.GetMethod('LowerSessionPriority',$flags).Invoke($window,@($childIdentity))
 $child.Refresh()
 if ($child.PriorityClass -ne 'BelowNormal' -or $state.SessionPriorities.Count -ne 1) { throw 'Fixture priority was not lowered with a recovery record.' }
 $serializer=New-Object System.Web.Script.Serialization.JavaScriptSerializer
 $json=$serializer.Serialize($state)
 $restored=$serializer.Deserialize($json,$assembly.GetType('SharkOptimizer.NativeApp.AppState'))
 if (!$matches.Invoke($restored.SessionPriorities[0].Process,@($child.PSObject.BaseObject))) { throw 'JSON reload changed the exact process start-time identity.' }
 $windowType.GetField('_state',$flags).SetValue($window,$restored)
 $null=$windowType.GetMethod('RestoreSessionPriorities',$flags).Invoke($window,@())
 $child.Refresh()
 if ($child.PriorityClass -ne $original -or $restored.SessionPriorities.Count -ne 0) { throw 'Original fixture priority was not restored after JSON reload.' }
 'Legacy session profiles, input validation, loaded controls, protected-app exclusion, and actual isolated-child priority restoration after JSON reload passed.'
} finally {
 if (!$child.HasExited) { $child.StandardInput.WriteLine(''); $child.StandardInput.Close(); $null=$child.WaitForExit(5000) }
 $child.Dispose(); $window.Close()
 $resolved=[IO.Path]::GetFullPath($fixtureDir)
 if ($resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'SharkSessionCheck-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
