param([string]$AppPath, [string]$OutputDirectory, [int]$Width = 1240, [int]$Height = 800, [double]$Scale = 1, [string]$Language='en', [ValidateRange(0,3)][int]$SettingsSection=0, [switch]$RenderOnly)
$ErrorActionPreference = 'Stop'
if (-not $AppPath) { $AppPath = Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot '..\out\previews' }
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
[Environment]::CurrentDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$type = $assembly.GetType('SharkOptimizer.NativeApp.MainWindow')
$constructor = $type.GetConstructor([Reflection.BindingFlags]'Instance,NonPublic', $null, [Type[]]@([bool]), $null)
$window = $constructor.Invoke(@($true))
$type.GetField('_state',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($window).Language=$Language
$assembly.GetType('SharkOptimizer.NativeApp.Localization').GetMethod('SetLanguage',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,@($Language))
$window.WindowStartupLocation = [Windows.WindowStartupLocation]::Manual
$window.Left = -32000; $window.Top = -32000
$window.Width = $Width; $window.Height = $Height
$window.ShowInTaskbar = $false; $window.ShowActivated = $false; $window.Opacity = 0
$window.Show()
$showPage = $type.GetMethod('ShowPage',[Reflection.BindingFlags]'Instance,NonPublic')
$root = $window.Content
$root.LayoutTransform = New-Object Windows.Media.ScaleTransform $Scale,$Scale
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
foreach ($page in @('Dashboard','Optimize','Games','Guide','Network','Game Session','Windows','Boost-Up','Lab','Restore','Settings')) {
 $showPage.Invoke($window,@($page))
 if ($page -eq 'Settings') { $type.GetField('_selectSettingsSection',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($window).Invoke($SettingsSection) }
 $root.Measure((New-Object Windows.Size $Width,$Height))
 $root.Arrange((New-Object Windows.Rect 0,0,$Width,$Height))
 $root.UpdateLayout()
 [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Windows.Threading.DispatcherPriority]::Render,[Action]{})
 $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap $Width,$Height,96,96,([Windows.Media.PixelFormats]::Pbgra32)
 $bitmap.Render($root)
 $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
 $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
 $destination = Join-Path $OutputDirectory ($page + '.png')
 $file = [IO.File]::Open($destination,[IO.FileMode]::Create)
 try { $encoder.Save($file) } finally { $file.Dispose() }
 Write-Output ('Rendered ' + [IO.Path]::GetFullPath($destination))
}
if($RenderOnly) { $window.Close(); return }
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$showPage.Invoke($window,@('Optimize'))
$checks = $type.GetField('_checks',$flags).GetValue($window)
$apply = $type.GetField('_applyButton',$flags).GetValue($window)
$checks[0].IsChecked = $true
if (!$apply.IsEnabled -or $apply.Visibility -ne [Windows.Visibility]::Visible) { throw 'The persistent Apply action did not follow selection.' }
$checks[0].IsChecked = $false
if ($apply.IsEnabled) { throw 'Apply remained enabled with no selected options.' }
$paletteMethod = $type.GetMethod('SetAccentBrushes',[Reflection.BindingFlags]'Static,NonPublic')
foreach ($accent in @('green','purple','orange','blue')) {
 $paletteMethod.Invoke($null,@($accent))
 [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Windows.Threading.DispatcherPriority]::DataBind,[Action]{})
 foreach ($field in @('LiveAccentBrush','LiveNavFill','LiveNavBorder')) {
  if ($type.GetField($field,[Reflection.BindingFlags]'Static,NonPublic').GetValue($null).IsFrozen) { throw 'A rendered control froze the live palette.' }
 }
}
'Rendered selection controls and all live accents passed.'
$window.Close()
