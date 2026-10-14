param([string]$AppPath)
$ErrorActionPreference='Stop'
if (!$AppPath) { $AppPath=Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
Add-Type -AssemblyName PresentationFramework
[Environment]::CurrentDirectory=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$assembly=[Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$type=$assembly.GetType('SharkOptimizer.NativeApp.MainWindow')
$flags=[Reflection.BindingFlags]'Instance,NonPublic'
$window=$type.GetConstructor($flags,$null,[Type[]]@([bool]),$null).Invoke(@($true))
$state=$type.GetField('_state',$flags).GetValue($window)
Add-Type -TypeDefinition @'
public static class SessionActionsFixture {
 public static object State;
 public static bool Running, FailStop, FailResume, MarkerAtStop;
 public static int Stops, Resumes;
 public static bool IsRunning() { return Running; }
 public static void Stop() { Stops++; MarkerAtStop=(bool)State.GetType().GetProperty("SessionUpdateResume").GetValue(State,null); if(FailStop) throw new System.Exception("Fixture stop failed"); Running=false; }
 public static void Resume() { Resumes++; if(FailResume) throw new System.Exception("Fixture resume failed"); Running=true; }
}
'@
[SessionActionsFixture]::State=$state
$fixtureType=[SessionActionsFixture]
$type.GetField('_sessionUpdateRunning',$flags).SetValue($window,[Delegate]::CreateDelegate([Func[bool]],$fixtureType.GetMethod('IsRunning')))
$type.GetField('_sessionStopUpdate',$flags).SetValue($window,[Delegate]::CreateDelegate([Action],$fixtureType.GetMethod('Stop')))
$type.GetField('_sessionResumeUpdate',$flags).SetValue($window,[Delegate]::CreateDelegate([Action],$fixtureType.GetMethod('Resume')))
$dispatcher=[Windows.Threading.Dispatcher]::CurrentDispatcher
$oldContext=[Threading.SynchronizationContext]::Current
[Threading.SynchronizationContext]::SetSynchronizationContext((New-Object Windows.Threading.DispatcherSynchronizationContext $dispatcher))
function Wait-Task($task) {
 if (!$task.IsCompleted) {
  $frame=New-Object Windows.Threading.DispatcherFrame
  $timer=New-Object Windows.Threading.DispatcherTimer
  $timer.Interval=[TimeSpan]::FromMilliseconds(10)
  $watch=[Diagnostics.Stopwatch]::StartNew()
  $timer.Add_Tick({ if($task.IsCompleted -or $watch.ElapsedMilliseconds -gt 5000) { $timer.Stop(); $frame.Continue=$false } })
  $timer.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
 }
 if(!$task.IsCompleted) { throw 'Fixture task did not finish.' }
 $null=$task.GetAwaiter().GetResult()
}
try {
 $pause=$type.GetMethod('PauseSessionUpdates',$flags); $resume=$type.GetMethod('RestoreSessionUpdates',$flags)
 [SessionActionsFixture]::Running=$false
 Wait-Task ($pause.Invoke($window,@()))
 if($state.SessionUpdateResume -or [SessionActionsFixture]::Stops -ne 0) { throw 'An originally stopped service was changed.' }
 [SessionActionsFixture]::Running=$true
 Wait-Task ($pause.Invoke($window,@()))
 if(!$state.SessionUpdateResume -or ![SessionActionsFixture]::MarkerAtStop -or [SessionActionsFixture]::Running) { throw 'Recovery marker was not recorded before stopping.' }
 Wait-Task ($resume.Invoke($window,@()))
 if($state.SessionUpdateResume -or ![SessionActionsFixture]::Running) { throw 'Service resume failed.' }
 [SessionActionsFixture]::FailStop=$true
 Wait-Task ($pause.Invoke($window,@()))
 if(!$state.SessionUpdateResume) { throw 'Failed stop lost its recovery record.' }
 [SessionActionsFixture]::FailResume=$true
 Wait-Task ($resume.Invoke($window,@()))
 if(!$state.SessionUpdateResume) { throw 'Failed resume lost its recovery record.' }
 [SessionActionsFixture]::FailStop=$false; [SessionActionsFixture]::FailResume=$false
 Wait-Task ($resume.Invoke($window,@()))
 if($state.SessionUpdateResume) { throw 'Retry did not clear recovered service state.' }
 $begin=$type.GetMethod('BeginSessionReport',$flags); $finish=$type.GetMethod('FinishSessionReport',$flags)
 for($i=0;$i -lt 55;$i++) { $null=$begin.Invoke($window,@('Fixture game')); $null=$finish.Invoke($window,@($false)) }
 if($state.SessionHistory.Count -ne 50 -or $null -ne $state.ActiveSessionReport) { throw 'Completed session report bounds failed.' }
 $null=$begin.Invoke($window,@('Interrupted fixture')); $state.SessionUpdateResume=$true
 $id=$state.ActiveSessionReport.Id; $null=$finish.Invoke($window,@($true))
 if(!$state.SessionHistory[0].RecoveryPending -or !$state.SessionHistory[0].Interrupted) { throw 'Pending/interrupted report failed.' }
 $state.SessionUpdateResume=$false; $null=$finish.Invoke($window,@($false))
 if(@($state.SessionHistory | Where-Object { $_.Id -eq $id }).Count -ne 1 -or $state.SessionHistory[0].RecoveryPending) { throw 'Recovery retry duplicated or failed to update the report.' }
 $median=$assembly.GetType('SharkOptimizer.NativeApp.BenchmarkHistory').GetMethod('Median',[Reflection.BindingFlags]'Static,NonPublic')
 $numbers=[Collections.Generic.List[double]]::new(); foreach($value in @(10,20,30,-1,[double]::NaN)) { $numbers.Add($value) }
 $medianArgs=New-Object object[] 1; $medianArgs[0]=$numbers.PSObject.BaseObject
 if($median.Invoke($null,$medianArgs) -ne 20) { throw 'Median did not ignore unavailable values.' }
 $sampler=[Activator]::CreateInstance($assembly.GetType('SharkOptimizer.NativeApp.SystemSampler'),$true)
 $read=$sampler.GetType().GetMethod('Read',$flags); $sample=$read.Invoke($sampler,@())
 if($sample.TotalRam -eq 0 -or $sample.Ram -lt 0 -or $sample.Ram -gt 100) { throw 'Actual memory sampling failed.' }
 $null=$type.GetMethod('ShowPage',$flags).Invoke($window,@('Settings'))
 $toggleBody=New-Object Windows.Controls.StackPanel
 $getter=[Func[bool]] { $state.ShowLog }; $setter=[Action[bool]] { param($enabled) $state.ShowLog=$enabled }
 $null=$type.GetMethod('AddBehaviorToggle',$flags).Invoke($window,@($toggleBody.PSObject.BaseObject,'Fixture preference',$getter,$setter))
 $toggle=$toggleBody.Children[0]; $toggle.IsChecked=$false; $toggle.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.CheckBox]::ClickEvent)))
 if($state.ShowLog) { throw 'Behavior control did not apply its setting.' }
 $registration=$assembly.GetType('SharkOptimizer.Platform.StartupRegistration')
 $xml=[xml]$registration.GetMethod('BuildXml',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,@('C:\Program Files\Shark & Optimizer\SharkOptimizer.exe','S-1-5-21-1-2-3-1001'))
 if($xml.Task.Actions.Exec.Arguments -ne '--tray' -or $xml.Task.Triggers.LogonTrigger.UserId -ne 'S-1-5-21-1-2-3-1001' -or $xml.Task.Actions.Exec.Command -notlike '*Shark & Optimizer*') { throw 'Startup XML path/account/tray arguments failed.' }
 'Service-state fixtures, stop-before-change recovery marker, retry behavior, 50-report bounds, interrupted report update, median handling, and actual memory sampling passed. Windows Update was not changed.'
} finally { [Threading.SynchronizationContext]::SetSynchronizationContext($oldContext); $window.Close() }
