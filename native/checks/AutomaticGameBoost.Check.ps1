param([string]$AppPath)
$ErrorActionPreference='Stop'
if (!$AppPath) { $AppPath=Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
Add-Type -AssemblyName PresentationFramework
$assembly=[Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$flags=[Reflection.BindingFlags]'Instance,NonPublic'
$type=$assembly.GetType('SharkOptimizer.NativeApp.MainWindow')
$window=$type.GetConstructor($flags,$null,[Type[]]@([bool]),$null).Invoke(@($true))
$state=$type.GetField('_state',$flags).GetValue($window)
$previous=[Threading.SynchronizationContext]::Current
[Threading.SynchronizationContext]::SetSynchronizationContext((New-Object Windows.Threading.DispatcherSynchronizationContext))
function Await-Work($task) {
 $frame=New-Object Windows.Threading.DispatcherFrame
 $timer=New-Object Windows.Threading.DispatcherTimer
 $deadline=[DateTime]::UtcNow.AddSeconds(12)
 $timer.Interval=[TimeSpan]::FromMilliseconds(20)
 $timer.Add_Tick({if($task.IsCompleted -or [DateTime]::UtcNow -gt $deadline){$timer.Stop();$frame.Continue=$false}})
 $timer.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
 if(!$task.IsCompleted){throw 'Automatic session check timed out.'}
 $null=$task.GetAwaiter().GetResult()
}
function Poll { Await-Work ($type.GetMethod('PollAutomaticSessions',$flags).Invoke($window,@())) }
function Wait-ForSession {
 $deadline=[DateTime]::UtcNow.AddSeconds(6)
 do { Poll; if($state.ActiveSessionReport){return}; Start-Sleep -Milliseconds 100 } while([DateTime]::UtcNow -lt $deadline)
 $probe=[Activator]::CreateInstance($assembly.GetType('SharkOptimizer.NativeApp.AutomaticGameProbe'),$true)
 $probe.Paths=$paths
 $probe=$type.GetMethod('ReadAutomaticGame',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,@($probe))
 $child.Refresh()
 throw ('External game detection failed. Running='+$probe.Running+'; uncertain='+$probe.Uncertain+'; childName='+$child.ProcessName+'; childExited='+$child.HasExited+'; notes='+($type.GetField('_sessionActionNotes',$flags).GetValue($window) -join '; '))
}
function Start-Fixture($path) {
 $process=New-Object Diagnostics.Process
 $process.StartInfo=New-Object Diagnostics.ProcessStartInfo $path
 $process.StartInfo.UseShellExecute=$false; $process.StartInfo.CreateNoWindow=$true; $process.StartInfo.RedirectStandardInput=$true
 $null=$process.Start(); return $process
}
$fixtureDir=Join-Path $env:TEMP ('SharkAutoCheck-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixtureDir
$fixture=Join-Path $fixtureDir 'SharkGameFixture.exe'
$otherDir=Join-Path $fixtureDir 'other'; $null=New-Item -ItemType Directory -Path $otherDir
$otherFixture=Join-Path $otherDir 'SharkGameFixture.exe'
Add-Type -TypeDefinition 'public static class SharkAutoFixture { public static void Main() { System.Console.ReadLine(); } }' -OutputAssembly $fixture -OutputType ConsoleApplication
Copy-Item -LiteralPath $fixture -Destination $otherFixture
$backgroundFixture=Join-Path $fixtureDir 'AutoBackground.exe'; Copy-Item -LiteralPath $fixture -Destination $backgroundFixture
$child=$null; $other=$null; $background=$null
try {
 $type.GetMethod('ShowPage',$flags).Invoke($window,@('Games'))
 $type.GetField('_selectedGameId',$flags).SetValue($window,'cs2')
 $existing=$type.GetField('_existingTweakResults',$flags).GetValue($window)
 foreach($id in @('game-mode','game-capture','gamebar-overlay','raw-mouse','fullscreen-optimizations')){$existing[$id]=$true}
 $type.GetMethod('RenderGameDetail',$flags).Invoke($window,@())
 function Read-Labels($node) {
  if($node -is [Windows.Controls.TextBlock]){return $node.Text}
  foreach($childNode in [Windows.LogicalTreeHelper]::GetChildren($node)){if($childNode -is [Windows.DependencyObject]){Read-Labels $childNode}}
 }
 $labels=@(Read-Labels ($type.GetField('_gameDetail',$flags).GetValue($window)))
 if($labels -contains 'No available options match this profile.' -or @($labels | Where-Object{$_ -eq 'Already enabled'}).Count -ne 5){throw 'Detected game recommendations disappeared instead of showing enabled status.'}
 $game=[Activator]::CreateInstance($assembly.GetType('SharkOptimizer.NativeApp.GameDefinition'),$true)
 $game.Id='auto-fixture'; $game.Name='Automatic fixture'; $game.IsCustom=$true
 $game.Executables=New-Object 'Collections.Generic.List[string]'; $game.Executables.Add('SharkGameFixture.exe')
 $state.CustomGames.Add($game)
 $paths=New-Object 'Collections.Generic.List[string]'; $paths.Add($fixture); $state.GamePaths.Add($game.Id,$paths)
 $profile=[Activator]::CreateInstance($assembly.GetType('SharkOptimizer.NativeApp.GameSessionProfile'),$true)
 if($profile.Automatic -or $profile.AutomaticCloseApps){throw 'Automatic actions were enabled by default.'}
 $state.GameSessions.Profiles.Add($game.Id,$profile)
 $background=Start-Fixture $backgroundFixture; $originalPriority=$background.PriorityClass
 $profile.ProcessMode='LowerPriority'; $profile.SelectedProcesses.Add('autobackground')
 $child=Start-Fixture $fixture
 Poll
 if($state.ActiveSessionReport){throw 'Disabled profile started automatically.'}
 $child.StandardInput.WriteLine(); $null=$child.WaitForExit(5000); $child.Dispose(); $child=$null
 $other=Start-Fixture $otherFixture; $profile.Automatic=$true
 Poll
 if($state.ActiveSessionReport){throw 'A process with the same name but a different path triggered Game Boost.'}
 $child=Start-Fixture $fixture
 Write-Output ('Fixture reported process name: '+$child.ProcessName)
 Wait-ForSession
 if(!$state.ActiveSessionReport -or $state.ActiveSessionReport.Mode -ne 'Automatic'){throw 'Detected external game did not start a session.'}
 $type.GetMethod('ShowPage',$flags).Invoke($window,@('Game Session'))
 if(!$type.GetField('_sessionEndButton',$flags).GetValue($window).IsEnabled -or $type.GetField('_sessionStartButton',$flags).GetValue($window).IsEnabled){throw 'Opening Game Boost did not show the active session controls.'}
 $background.Refresh(); if($background.PriorityClass -ne 'BelowNormal' -or $state.SessionPriorities.Count -ne 1){throw 'Saved automatic app action did not capture and lower fixture priority.'}
 $id=$state.ActiveSessionReport.Id; Poll
 if($state.ActiveSessionReport.Id -ne $id -or $state.SessionHistory.Count -ne 0){throw 'Polling duplicated the session.'}
 Await-Work ($type.GetMethod('EndGameSession',$flags).Invoke($window,@($true)))
 $background.Refresh(); if($background.PriorityClass -ne $originalPriority -or $state.SessionPriorities.Count -ne 0){throw 'Automatic session did not restore fixture priority.'}
 Poll
 if($state.ActiveSessionReport -or $state.SessionHistory.Count -ne 1){throw 'Manually stopped game was immediately reboosted.'}
 $child.StandardInput.WriteLine(); $null=$child.WaitForExit(5000); $child.Dispose(); $child=$null
 Poll
 $child=Start-Fixture $fixture; Wait-ForSession
 if(!$state.ActiveSessionReport){throw 'A later game launch did not start a new session.'}
 $child.StandardInput.WriteLine(); $null=$child.WaitForExit(5000); $child.Dispose(); $child=$null
 Poll
 if(!$state.ActiveSessionReport){throw 'Handoff grace ended the session too early.'}
 $type.GetField('_automaticMissingSince',$flags).SetValue($window,[DateTime]::UtcNow.AddSeconds(-16))
 Poll
 if($state.ActiveSessionReport -or $state.SessionHistory.Count -ne 2 -or $state.SessionHistory[0].RecoveryPending){throw 'Game exit did not produce a completed recap.'}
 $serializer=New-Object Web.Script.Serialization.JavaScriptSerializer
 $codec=$assembly.GetType('SharkOptimizer.NativeApp.GameSessionCodec')
 $reloaded=$codec.GetMethod('Read',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,@($serializer.Serialize($state.GameSessions)))
 if(!$reloaded.Profiles[$game.Id].Automatic -or $reloaded.Profiles[$game.Id].AutomaticCloseApps){throw 'Automatic opt-in did not survive profile serialization.'}
 'PASS: Opt-in default, full-path detection, external launch, duplicate guards, manual-stop suppression, handoff grace, exit recap and profile persistence. Preview state; no Windows tweaks applied.'
} finally {
 foreach($process in @($child,$other,$background)){if($process){try{$process.StandardInput.WriteLine();$null=$process.WaitForExit(5000)}finally{$process.Dispose()}}}
 $type.GetMethod('StopAutomaticSessionWatcher',$flags).Invoke($window,@())
 $window.Close(); [Threading.SynchronizationContext]::SetSynchronizationContext($previous)
 foreach($path in @($fixture,$otherFixture,$backgroundFixture)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
 Remove-Item -LiteralPath $otherDir; Remove-Item -LiteralPath $fixtureDir
}
