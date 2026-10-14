param([string]$AppPath, [switch]$LiveRead)
$ErrorActionPreference = 'Stop'
if (!$AppPath) { $AppPath = Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
Add-Type -AssemblyName PresentationFramework
[Environment]::CurrentDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$type = $assembly.GetType('SharkOptimizer.NativeApp.MainWindow')
$flags = [Reflection.BindingFlags]'Instance,NonPublic'; $static = [Reflection.BindingFlags]'Static,NonPublic'
$window = $type.GetConstructor($flags,$null,[Type[]]@([bool]),$null).Invoke(@($true))
try {
 $state = $type.GetField('_state',$flags).GetValue($window)
 $definitions = $type.GetField('Definitions',$static).GetValue($null)
 $scan = $type.GetMethod('ReadExistingTweakState',$static)
 $ultimate = @($definitions | Where-Object { $_.Id -eq 'ultimate-performance-plan' })[0]
 if ($null -ne $scan.Invoke($null,@($ultimate.PSObject.BaseObject))) { throw 'A cloned power plan was guessed as active/inactive.' }
 $results = $type.GetField('_existingTweakResults',$flags).GetValue($window)
 $results['game-mode'] = $true; $results['game-capture'] = $null
 $type.GetMethod('ShowPage',$flags).Invoke($window,@('Optimize'))
 $checks = $type.GetField('_checks',$flags).GetValue($window)
 $gameMode = @($checks | Where-Object { $_.Tag.Id -eq 'game-mode' })[0]
 if (!$gameMode -or $gameMode.IsEnabled) { throw 'Already enabled setting remained selectable.' }
 if ($state.Applied.Count -ne 0) { throw 'Existing setting became a tracked undo record.' }
 if ($type.GetMethod('CanSelectTweak',$flags).Invoke($window,@('game-mode'))) { throw 'Preset selection can reapply a detected setting.' }
 $results['game-mode'] = $false
 $type.GetMethod('RenderTweakCards',$flags).Invoke($window,@())
 if (!$type.GetMethod('CanSelectTweak',$flags).Invoke($window,@('game-mode'))) { throw 'Rescanned inactive setting remained locked.' }
 if ($LiveRead) {
  $counts = @{Enabled=0;Different=0;Unverified=0}; $clock = [Diagnostics.Stopwatch]::StartNew()
  foreach ($definition in $definitions) {
   if ($clock.Elapsed.TotalSeconds -ge 120) { throw 'Live read check exceeded its overall budget.' }
   $value = $scan.Invoke($null,@($definition.PSObject.BaseObject))
   if ($null -eq $value) { $counts.Unverified++ } elseif ($value) { $counts.Enabled++ } else { $counts.Different++ }
  }
  if ($state.Applied.Count -ne 0) { throw 'Live scan created undo records.' }
  $counts | ConvertTo-Json -Compress
 }
 'PASS: Existing-setting selection guard, refresh, unknown cloned-plan status, and empty undo history. Optional live mode reads Windows settings without applying changes.'
} finally { $window.Close() }
