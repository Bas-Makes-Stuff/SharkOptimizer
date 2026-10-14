param([string]$AppPath)
$ErrorActionPreference = 'Stop'
if (!$AppPath) { $AppPath = Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
Add-Type -AssemblyName PresentationFramework
[Environment]::CurrentDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$type = $assembly.GetType('SharkOptimizer.NativeApp.MainWindow')
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$static = [Reflection.BindingFlags]'Static,NonPublic'
$window = $type.GetConstructor($flags,$null,[Type[]]@([bool]),$null).Invoke(@($true))
try {
 $definitions = $type.GetField('Definitions',$static).GetValue($null)
 $safe = @($definitions | Where-Object { $_.Risk -eq 'Recommended' })[0]
 $caution = @($definitions | Where-Object { $_.Risk -eq 'Caution' })[0]
 if (!$safe -or !$caution) { throw 'Missing policy examples.' }
 $policy = $type.GetMethod('ShouldRequestRestorePoint',$static)
 foreach ($scenario in @(
  @{Items=@();Always=$false;Expected=$false},
  @{Items=@();Always=$true;Expected=$false},
  @{Items=@($safe);Always=$false;Expected=$false},
  @{Items=@($safe);Always=$true;Expected=$true},
  @{Items=@($caution);Always=$false;Expected=$true},
  @{Items=@($safe,$caution);Always=$false;Expected=$true}
 )) {
  $items = [Array]::CreateInstance($assembly.GetType('SharkOptimizer.NativeApp.TweakDefinition'),$scenario.Items.Count)
  for ($i=0; $i -lt $scenario.Items.Count; $i++) { $items.SetValue($scenario.Items[$i],$i) }
  if ($policy.Invoke($null,@($items,[bool]$scenario.Always)) -ne $scenario.Expected) { throw 'Restore-point decision is incorrect.' }
 }
 $state = $type.GetField('_state',$flags).GetValue($window)
 $state.LegacyBehaviorImported = $true
 $state.LegacyRestorePointImported = $false
 $state.Toasts = $false
 $state.LegacyBackupFiles['settings.json'] = '{"AlwaysRestorePoint":true,"Toasts":true}'
 $type.GetMethod('ImportLegacyBehavior',$flags).Invoke($window,@())
 if (!$state.AlwaysRestorePoint -or !$state.LegacyRestorePointImported -or $state.Toasts) { throw 'New preference migration changed previously migrated behavior.' }
 $state.AlwaysRestorePoint = $false
 $type.GetMethod('ImportLegacyBehavior',$flags).Invoke($window,@())
 if ($state.AlwaysRestorePoint) { throw 'Migration overwrote an explicit native choice.' }
 'PASS: Safe/caution/always/empty selection policy and one-time migration without overwriting native behavior. No Windows restore point was requested.'
} finally { $window.Close() }
