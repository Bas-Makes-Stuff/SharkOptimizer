param([string]$AppPath)
$ErrorActionPreference='Stop'
if (!$AppPath) { $AppPath=Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
Add-Type -AssemblyName PresentationFramework
[Environment]::CurrentDirectory=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$assembly=[Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$type=$assembly.GetType('SharkOptimizer.NativeApp.MainWindow'); $flags=[Reflection.BindingFlags]'Instance,NonPublic'
$window=$type.GetConstructor($flags,$null,[Type[]]@([bool]),$null).Invoke(@($true))
$locale=$assembly.GetType('SharkOptimizer.NativeApp.Localization'); $static=[Reflection.BindingFlags]'Static,NonPublic'
$set=$locale.GetMethod('SetLanguage',$static); $translate=$locale.GetMethod('Translate',$static); $apply=$locale.GetMethod('Apply',$static)
$languages=$locale.GetField('Languages',$static).GetValue($null)
try {
 if($languages.Count -ne 8) { throw 'The language selector does not contain eight languages.' }
 $windowsLanguage=$locale.GetMethod('LanguageForWindows',$static)
 foreach($pair in @(@('nl-NL','nl'),@('de-DE','de'),@('pt-BR','pt'),@('zh-CN','zh'),@('fr-CA','fr'),@('ja-JP','en'),@('','en'))) {
  if($windowsLanguage.Invoke($null,@($pair[0])) -ne $pair[1]) { throw ('Windows display-language matching failed: '+$pair[0]) }
 }
 $resolve=$locale.GetMethod('ResolveStartupLanguage',$static)
 foreach($scenario in @(@('de','nl','fr-FR','de'),@('','nl','fr-FR','nl'),@('invalid','invalid','fr-FR','fr'),@('','','ja-JP','en'))) {
  if($resolve.Invoke($null,@($scenario[0],$scenario[1],$scenario[2])) -ne $scenario[3]) { throw 'Startup language preference order failed.' }
 }
 $state=$type.GetField('_state',$flags).GetValue($window)
 $state.Language='de'; $state.LegacyLanguageImported=$false; $state.LegacyBackupFiles['settings.json']='{"Language":"nl"}'
 $type.GetMethod('ImportLegacyLanguage',$flags).Invoke($window,@())
 if($state.Language -ne 'de') { throw 'Legacy migration overwrote the native language.' }
 $null=$type.GetMethod('ShowPage',$flags).Invoke($window,@('Optimize'))
 $checks=$type.GetField('_checks',$flags).GetValue($window); $checks[0].IsChecked=$true
 $selectedId=$checks[0].Tag
 foreach($code in @('nl','es','de','fr','pt','ru','zh','en','de','en')) {
  $null=$set.Invoke($null,@($code))
  $translated=$translate.Invoke($null,@('Game Library'))
  if($code -ne 'en' -and $translated -eq 'Game Library') { throw ('Missing navigation translation: '+$code) }
  $dynamic=$translate.Invoke($null,@('Could not enable startup: Error 123 {raw-data}'))
  if($code -ne 'en' -and ($dynamic.StartsWith('Could not enable startup:') -or !$dynamic.EndsWith('Error 123 {raw-data}'))) { throw ('Dynamic translation lost variable data: '+$code) }
  if(!$checks[0].IsChecked -or $checks[0].Tag -ne $selectedId) { throw 'Language switching altered selected options.' }
 }
 $root=New-Object Windows.Controls.StackPanel
 $label=New-Object Windows.Controls.TextBlock; $label.Text='Settings'
 $entry=New-Object Windows.Controls.TextBox; $entry.Text='Settings'
 $null=$root.Children.Add($label); $null=$root.Children.Add($entry)
 $null=$apply.Invoke($null,@($root.PSObject.BaseObject)); $null=$set.Invoke($null,@('de'))
 if($label.Text -ne 'Einstellungen' -or $entry.Text -ne 'Settings') { throw 'Label translation changed editable user data or failed.' }
 $label.Text='Network'; $null=$apply.Invoke($null,@($root.PSObject.BaseObject))
 if($label.Text -ne 'Netzwerk') { throw 'A live label update was not translated.' }
 $dataLabel=New-Object Windows.Controls.TextBlock; $dataLabel.Text='Settings'; $null=$apply.Invoke($null,@($dataLabel.PSObject.BaseObject))
 $null=$locale.GetMethod('KeepData',$static).Invoke($null,@($dataLabel.PSObject.BaseObject))
 if($dataLabel.Text -ne 'Settings') { throw 'Marking previously translated user data did not restore its original value.' }
 $null=$type.GetMethod('ShowPage',$flags).Invoke($window,@('Network'))
 $hostEntry=$type.GetField('_livePingHost',$flags).GetValue($window); $hostEntry.Text='Settings'; $hostEntry.IsReadOnly=$true
 $null=$apply.Invoke($null,@($window.Content.PSObject.BaseObject))
 if($hostEntry.Text -ne 'Settings') { throw 'Temporarily read-only host data was translated.' }
 $multi=$translate.Invoke($null,@("Reply from 127.0.0.1: time=2ms`r`nReply from 127.0.0.2: time=3ms"))
 if($multi -notlike '*127.0.0.1*2ms*127.0.0.2*3ms*' -or $multi.Contains('Reply from')) { throw 'Multiline diagnostic translation failed or changed measurements.' }
 foreach($code in @('nl','es','de','fr','pt','ru','zh')) {
  $null=$set.Invoke($null,@($code)); $liveText='Live '+[char]0xB7+' host.example '+[char]0x2192+' 127.0.0.1 '+[char]0xB7+' 42 completed samples '+[char]0xB7+' latest 60 plotted '+[char]0xB7+' loss across this run'; $live=$translate.Invoke($null,@($liveText))
  if(!$live.Contains('host.example') -or !$live.Contains('127.0.0.1') -or !$live.Contains('42') -or $live.Contains('completed samples')) { throw ('Live counter translation failed: '+$code) }
  $steps=$type.GetField('GuideSteps',$static).GetValue($null)
  foreach($step in $steps) { foreach($field in @('Title','Body','Action')) {
   $english=$step.GetType().GetField($field).GetValue($step)
   if($translate.Invoke($null,@($english)) -eq $english) { throw ('Missing guide '+$field+' translation: '+$code+' / '+$step.Title) }
  } }
 }
 $null=$set.Invoke($null,@('en'))
 if($label.Text -ne 'Network') { throw 'Switching back lost the newest original text.' }
 $null=$type.GetMethod('ShowPage',$flags).Invoke($window,@('Settings')); $null=$set.Invoke($null,@('zh'))
 $expectedHeading=-join [char[]]@(0x8BBE,0x7F6E)
 if($type.GetField('_pageTitle',$flags).GetValue($window).Text -ne $expectedHeading) { throw ('The page heading did not follow language changes: '+$type.GetField('_pageTitle',$flags).GetValue($window).Text) }
 'Eight language dictionaries, repeated switching, selection preservation, editable-data exclusion, dynamic label updates, English restoration, and localized headings passed.'
} finally { $null=$set.Invoke($null,@('en')); $window.Close() }
