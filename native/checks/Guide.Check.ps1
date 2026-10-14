param([string]$AppPath)
$ErrorActionPreference = 'Stop'
if (-not $AppPath) { $AppPath = Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
Add-Type -AssemblyName PresentationFramework
[Environment]::CurrentDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$type = $assembly.GetType('SharkOptimizer.NativeApp.MainWindow')
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$window = $type.GetConstructor($flags,$null,[Type[]]@([bool]),$null).Invoke(@($true))
function Find-Buttons($element) {
 if ($element -is [Windows.Controls.Button]) { $element }
 foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($element)) {
  if ($child -is [Windows.DependencyObject]) { Find-Buttons $child }
 }
}
try {
 $show = $type.GetMethod('ShowPage',$flags)
 $null = $show.Invoke($window,@('Guide'))
 $state = $type.GetField('_state',$flags).GetValue($window)
 if (!$state.GuideSeen -or $type.GetField('_welcomeGuideCard',$flags).GetValue($window).Visibility -ne 'Collapsed') { throw 'Guide marker/welcome dismissal failed.' }
 $pages = $type.GetField('_pages',$flags).GetValue($window)
 $steps = $type.GetField('GuideSteps',[Reflection.BindingFlags]'Static,NonPublic').GetValue($null)
 foreach ($step in $steps) { if ($step.Route -and !$pages.ContainsKey($step.Route)) { throw ('Guide route is missing: ' + $step.Route) } }
 $buttons = @(Find-Buttons $pages['Guide'])
 $previous = $buttons | Where-Object { [string]$_.Content -like '*Previous' }
 $next = $buttons | Where-Object { [string]$_.Content -like 'Next*' }
 $index = $type.GetField('_guideIndex',$flags)
 if ($previous.IsEnabled -or !$next.IsEnabled) { throw 'First-step boundaries failed.' }
 for ($i=1; $i -lt $steps.Length; $i++) {
  $next.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
  if ($index.GetValue($window) -ne $i) { throw 'Next did not advance exactly one step.' }
 }
 if ($next.IsEnabled -or !$previous.IsEnabled) { throw 'Last-step boundaries failed.' }
 for ($i=$steps.Length-2; $i -ge 0; $i--) {
  $previous.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
  if ($index.GetValue($window) -ne $i) { throw 'Previous did not return exactly one step.' }
 }
 if ($previous.IsEnabled) { throw 'Previous crossed the first-step boundary.' }
 $open = $buttons | Where-Object { [string]$_.Content -eq 'Optimize' }
 $open.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
 if ($pages['Optimize'].Visibility -ne 'Visible' -or $pages['Guide'].Visibility -ne 'Collapsed') { throw 'Guide shortcut did not navigate.' }
 $runner = $type.GetMethod('RunNetworkCommand',[Reflection.BindingFlags]'Static,NonPublic')
 $output = $runner.Invoke($null,@('ipconfig.exe','/?',5000))
 if ([string]::IsNullOrWhiteSpace($output) -or $output -match 'time limit|could not be closed') { throw 'Read-only network command did not finish.' }
 $rejected = $false
 try { $null=$runner.Invoke($null,@('cmd.exe','/c echo unexpected',5000)) } catch { $rejected=$true }
 if (!$rejected) { throw 'Network command allowlist failed.' }
 'All eight guide steps, boundaries, welcome marker, routes, shortcut, read-only network process, and command allowlist passed.'
} finally { $window.Close() }
