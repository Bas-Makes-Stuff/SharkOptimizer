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
function Find-Buttons($root) {
 if ($root -is [Windows.Controls.Button]) { $root }
 foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($root)) { if ($child -is [Windows.DependencyObject]) { Find-Buttons $child } }
}
try {
 $window.WindowStartupLocation = 'Manual'; $window.Left = -32000; $window.Top = -32000; $window.ShowInTaskbar = $false; $window.Opacity = 0; $window.Show(); $window.UpdateLayout()
 $pages = $type.GetField('_pages',$flags).GetValue($window)
 $buttons = @(Find-Buttons $pages['Dashboard'])
 $visualCards = @($buttons | Where-Object { $_.Content -is [Windows.DependencyObject] })
 if ($visualCards.Count -lt 12) { throw 'Dashboard visual cards lost their structured content.' }
 $locale = $assembly.GetType('SharkOptimizer.NativeApp.Localization')
 $locale.GetMethod('SetLanguage',$static).Invoke($null,@('nl')); $locale.GetMethod('Apply',$static).Invoke($null,@($window.Content.PSObject.BaseObject))
 if (@($visualCards | Where-Object { $_.Content -isnot [Windows.DependencyObject] }).Count) { throw 'Language switching replaced card visuals.' }
 $locale.GetMethod('SetLanguage',$static).Invoke($null,@('en'))
 $sampler = [Activator]::CreateInstance($assembly.GetType('SharkOptimizer.NativeApp.SystemSampler'),$true)
 $read = $sampler.GetType().GetMethod('Read',$flags)
 $sample = $read.Invoke($sampler,@()); Start-Sleep -Milliseconds 100; $sample = $read.Invoke($sampler,@())
 if ($sample.Ram -lt 0 -or $sample.Ram -gt 100) { throw 'Live memory sample is invalid.' }
 $type.GetMethod('UpdateDashboardGauges',$flags).Invoke($window,@($sample))
 $ramArc = $type.GetField('_ramArc',$flags).GetValue($window)
 if ($sample.Ram -gt 0 -and $null -eq $ramArc.Data) { throw 'Live memory sample did not reach its gauge.' }
 $nav = $type.GetField('_navButtons',$flags).GetValue($window)
 if ($nav.Count -ne 5 -or @('Dashboard','Optimize','Games','Tools','Settings' | Where-Object {!$nav.ContainsKey($_)}).Count) { throw 'The five primary sidebar routes are incomplete.' }
 foreach ($button in $nav.Values) { if ($button.Margin.Top -ne 0 -or $button.Margin.Bottom -ne 0) { throw 'Sidebar buttons have gaps.' } }
 $icons = $type.GetField('_navIcons',$flags).GetValue($window)
 foreach ($icon in $icons.Values) { if ($null -eq $icon.Data -or !$icon.Data.IsFrozen) { throw 'A vector sidebar icon is missing or mutable.' } }
 $optimization = $visualCards | Where-Object { [string]$_.ToolTip -eq 'Review optimization' } | Select-Object -First 1
 $type.GetField('_recommendedOnlyActive',$flags).SetValue($window,$true)
 $type.GetField('_optimizationGroup',$flags).SetValue($window,'Network & Ping')
 $optimization.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
 if ($pages['Optimize'].Visibility -ne 'Visible' -or $pages['Dashboard'].Visibility -ne 'Collapsed') { throw 'Optimization card did not open its review page.' }
 $state = $type.GetField('_state',$flags).GetValue($window)
 if ($state.Applied.Count -ne 0) { throw 'Review navigation applied a change.' }
 if ($type.GetField('_recommendedOnlyActive',$flags).GetValue($window) -or $type.GetField('_recommendedOnlyFilter',$flags).GetValue($window).IsChecked) { throw 'A previous recommendation filter hid the requested optimization.' }
 if($type.GetField('_checks',$flags).GetValue($window).Count -eq 0){throw 'A previous group filter hid the requested optimization.'}
 'PASS: Structured cards survive language switching, actual RAM feeds its gauge, five vector routes have no gaps, and review navigation applies no settings.'
} finally { $window.Close() }
