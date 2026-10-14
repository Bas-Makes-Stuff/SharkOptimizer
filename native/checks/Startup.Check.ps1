param([string]$AppPath)
$ErrorActionPreference = 'Stop'
if (!$AppPath) { $AppPath = Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
Add-Type -AssemblyName PresentationFramework
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$type = $assembly.GetType('SharkOptimizer.NativeApp.StartupWindow')
$locale = $assembly.GetType('SharkOptimizer.NativeApp.Localization')
$instance = [Reflection.BindingFlags]'Instance,NonPublic'
$static = [Reflection.BindingFlags]'Static,NonPublic'
$tipList = $type.GetField('Tips', $static).GetValue($null)
if ($tipList.Length -ne 6) { throw 'Six loading tips are required.' }
foreach ($language in @('en','nl','de','es','fr','pt','ru','zh')) {
 $locale.GetMethod('SetLanguage', $static).Invoke($null, @($language))
 $window = [Activator]::CreateInstance($type)
 try {
  $timer = $type.GetField('_tipTimer', $instance).GetValue($window)
  $label = $type.GetField('_tipText', $instance).GetValue($window)
  if ($timer.Interval.TotalSeconds -ne 5) { throw 'Tip interval is not five seconds.' }
  for ($i = 0; $i -lt 6; $i++) {
   $expected = $locale.GetMethod('Translate', $static).Invoke($null, @($tipList[$i]))
   if ($label.Text -ne $expected -or ($language -ne 'en' -and $label.Text -eq $tipList[$i])) { throw ('Tip translation failed: ' + $language + ' / ' + $i) }
   $type.GetMethod('AdvanceTip', $instance).Invoke($window, @())
  }
  if ($type.GetField('_tipIndex', $instance).GetValue($window) -ne 0) { throw 'Tip cycle did not wrap.' }
 } finally { $window.Close() }
}
$locale.GetMethod('SetLanguage', $static).Invoke($null, @('en'))
$window = [Activator]::CreateInstance($type)
try {
 $window.WindowStartupLocation = 'Manual'; $window.Left = -32000; $window.Top = -32000
 $window.Show(); $window.Opacity = 0
 $timer = $type.GetField('_tipTimer', $instance).GetValue($window)
 if (!$timer.IsEnabled) { throw 'Loading tips did not start on Loaded.' }
 $frame = New-Object Windows.Threading.DispatcherFrame
 $finish = New-Object Windows.Threading.DispatcherTimer
 $finish.Interval = [TimeSpan]::FromMilliseconds(5250)
 $finish.Add_Tick({ $finish.Stop(); $frame.Continue = $false })
 $finish.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
 if ($type.GetField('_tipIndex', $instance).GetValue($window) -ne 1) { throw 'The live five-second tip timer did not advance.' }
 $root = $window.Content; $root.UpdateLayout()
 $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap 440,286,96,96,([Windows.Media.PixelFormats]::Pbgra32)
 $bitmap.Render($root)
 $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
 $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
 $path = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\out\startup-preview.png'))
 $file = [IO.File]::Create($path); try { $encoder.Save($file) } finally { $file.Dispose() }
} finally { $window.Close() }
if ($timer.IsEnabled) { throw 'Tip timer remained active after closing.' }
'PASS: Six tips, all eight languages, five-second runtime cycling, close cleanup, and splash render.'
