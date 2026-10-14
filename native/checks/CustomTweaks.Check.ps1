param([string]$AppPath)
$ErrorActionPreference = 'Stop'
if (-not $AppPath) { $AppPath = Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Web.Extensions
[Environment]::CurrentDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$codec = $assembly.GetType('SharkOptimizer.NativeApp.CustomTweakCodec')
$dataType = $assembly.GetType('SharkOptimizer.NativeApp.RegistryData')
$windowType = $assembly.GetType('SharkOptimizer.NativeApp.MainWindow')
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$testPath = 'Software\SharkOptimizer\NativeChecks\' + [Guid]::NewGuid().ToString('N')
[byte[]]$largeBytes = New-Object byte[] 65537
$largeBytes[0] = 17; $largeBytes[$largeBytes.Length - 1] = 255
$cases = @(
 @{name='Dword';type='DWord';old=7;value='0xFFFFFFFF'},
 @{name='Qword';type='QWord';old=[long]99;value='0xFFFFFFFFFFFFFFFF'},
 @{name='Text';type='String';old='original';value='updated'},
 @{name='Expanded';type='ExpandString';old='%TEMP%\original';value='%TEMP%\updated'},
 @{name='Strings';type='MultiString';old=[string[]]@('alpha','beta');value=@('gamma','delta')},
 @{name='Bytes';type='Binary';old=$largeBytes;value=@(4,5,6,254)},
 @{name='Opaque';type='None';old=[byte[]]@(1,7,255);value=@(3,8,254)}
)
$raw = $serializer.Serialize(@(@{id='c_native_check';name='Temporary native registry fixture';cat='Custom';enabled=$true;reg=@($cases | ForEach-Object { @{path='HKCU:\' + $testPath;name=$_.name;type=$_.type;value=$_.value} })}))
$parsed = $codec.GetMethod('ReadJson',$flags).Invoke($null,@($raw))
if ($parsed.Count -ne 1 -or $parsed[0].Registry.Count -ne 7) { throw 'Custom definition parsing failed.' }
$exportedJson = $codec.GetMethod('WriteJson',$flags).Invoke($null,(,$parsed))
$roundTrip = $codec.GetMethod('ReadJson',$flags).Invoke($null,@($exportedJson))
if ($roundTrip[0].Registry.Count -ne 7) { throw 'Definition export/import failed.' }
$bad = @(
 '[{"id":"game-mode","name":"Override","reg":[{"path":"HKCU:\\Software\\Example","name":"Value","type":"DWord","value":1}]}]',
 '[{"id":"f_gamemode","name":"Alias override","reg":[{"path":"HKCU:\\Software\\Example","name":"Value","type":"DWord","value":1}]}]',
 '[{"id":"c_bad","name":"Bad path","reg":[{"path":"C:\\Windows","name":"Value","type":"DWord","value":1}]}]',
 '[{"id":"c_bad","name":"Bad type","reg":[{"path":"HKCU:\\Software\\Example","name":"Value","type":"Unknown","value":1}]}]',
 '[{"id":"c_bad","name":"Bad number","reg":[{"path":"HKCU:\\Software\\Example","name":"Value","type":"DWord","value":1.5}]}]',
 '[{"id":"c_bad","name":"Bad byte","reg":[{"path":"HKCU:\\Software\\Example","name":"Value","type":"Binary","value":[256]}]}]'
)
foreach ($json in $bad) { $rejected = $false; try { $null = $codec.GetMethod('ReadJson',$flags).Invoke($null,@($json)) } catch { $rejected = $true }; if (!$rejected) { throw 'An invalid definition was accepted.' } }
$constructor = $windowType.GetConstructor([Reflection.BindingFlags]'Instance,NonPublic',$null,[Type[]]@([bool]),$null)
$window = $constructor.Invoke(@($true))
$instanceFlags = [Reflection.BindingFlags]'Instance,NonPublic'
$state = $windowType.GetField('_state',$instanceFlags).GetValue($window)
$previousContext = [Threading.SynchronizationContext]::Current
[Threading.SynchronizationContext]::SetSynchronizationContext((New-Object Windows.Threading.DispatcherSynchronizationContext))
Add-Type -TypeDefinition @'
using System.Reflection;
using System.Threading.Tasks;
public static class SharkApplyCheckBridge {
 public static Task Invoke(MethodInfo method, object window, object definition) {
  return Task.Run(() => method.Invoke(window, new object[] { definition }));
 }
}
'@
function Wait-NativeTask($task) {
 if ($task -isnot [Threading.Tasks.Task]) { throw 'The background check did not return a Task.' }
 $frame = New-Object Windows.Threading.DispatcherFrame
 $poll = New-Object Windows.Threading.DispatcherTimer
 $deadline = [DateTime]::UtcNow.AddSeconds(30)
 $poll.Interval = [TimeSpan]::FromMilliseconds(10)
 $poll.Add_Tick({ if ($task.IsCompleted -or [DateTime]::UtcNow -ge $deadline) { $poll.Stop(); $frame.Continue = $false } })
 $poll.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
 if (!$task.IsCompleted) { throw 'The isolated apply did not finish within thirty seconds.' }
 $null = $task.GetAwaiter().GetResult()
}
$key = $null
try {
 $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($testPath)
 foreach ($case in $cases) { $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind],$case.type); $key.SetValue($case.name,$case.old,$kind) }
 $definition = $codec.GetMethod('Build',$flags).Invoke($null,@($parsed[0]))
 $scan = $windowType.GetMethod('ReadExistingTweakState',$flags)
 if ($scan.Invoke($null,@($definition)) -ne $false) { throw 'Existing-setting scan marked different registry data as enabled.' }
 $windowType.GetField('_catalogue',$instanceFlags).GetValue($window).Add($definition)
 Wait-NativeTask ([SharkApplyCheckBridge]::Invoke($windowType.GetMethod('ApplyOne',$instanceFlags),$window,$definition))
 $undoCountBeforeScan = $windowType.GetField('_state',$instanceFlags).GetValue($window).Applied.Count
 if ($scan.Invoke($null,@($definition)) -ne $true) { throw 'Existing-setting scan missed matching registry data.' }
 if ($windowType.GetField('_state',$instanceFlags).GetValue($window).Applied.Count -ne $undoCountBeforeScan) { throw 'Read-only scan changed undo history.' }
 if ($state.Applied.Count -ne 1) { throw 'The native apply engine did not track the fixture.' }
 $record = $state.Applied[0]
 foreach ($change in $record.Values) {
  $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind],$change.TargetKind)
  $actual = $key.GetValue($change.Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  if (!$dataType.GetMethod('Equal',$flags).Invoke($null,@($actual,$change.TargetValue,$kind))) { throw ('Applied value mismatch: ' + $change.Name) }
 }
 $recordType = $assembly.GetType('SharkOptimizer.NativeApp.AppliedTweak')
 $reloadedRecord = $serializer.Deserialize($serializer.Serialize($record),$recordType)
 $state.Applied.Clear(); $state.Applied.Add($reloadedRecord)
 [Windows.Controls.TextBlock]$verificationStatus = New-Object Windows.Controls.TextBlock
 $windowType.GetField('_labStatus',$instanceFlags).SetValue($window,$verificationStatus)
 $windowType.GetMethod('VerifyTweaks',$instanceFlags).Invoke($window,@())
 if ($verificationStatus.Text -notmatch '0 need review') { throw 'Reloaded registry targets failed verification.' }
 $key.SetValue('Bytes',[byte[]]@(9,9,9,9),[Microsoft.Win32.RegistryValueKind]::Binary)
 if ($scan.Invoke($null,@($definition)) -ne $false) { throw 'Existing-setting scan missed binary drift.' }
 $windowType.GetMethod('VerifyTweaks',$instanceFlags).Invoke($window,@())
 if ($verificationStatus.Text -notmatch '1 need review') { throw 'Verification did not detect binary value drift.' }
 Wait-NativeTask ($windowType.GetMethod('RestoreAndSave',$instanceFlags).Invoke($window,@($reloadedRecord)))
 if ($state.Applied.Count -ne 0) { throw 'Undo did not remove the completed restore record.' }
 foreach ($case in $cases) {
  $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind],$case.type)
  $actual = $key.GetValue($case.name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  if ($key.GetValueKind($case.name) -ne $kind -or !$dataType.GetMethod('Equal',$flags).Invoke($null,@($actual,$case.old,$kind))) { throw ('Restored value mismatch after JSON reload: ' + $case.name) }
 }
 'Custom definitions, reserved IDs, invalid paths/types/data, seven live registry types, JSON-reloaded verification/undo, binary drift detection, and large existing binary restoration passed.'
} finally {
 [Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
 if ($key) { $key.Dispose() }
 [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($testPath,$false)
 $window.Close()
}
