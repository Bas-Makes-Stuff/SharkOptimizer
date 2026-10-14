param([string]$AppPath)
$ErrorActionPreference='Stop'
if(!$AppPath) { $AppPath=Join-Path $PSScriptRoot 'out\SharkOptimizer.Native.exe' }
Add-Type -AssemblyName PresentationFramework
$assembly=[Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$type=$assembly.GetType('SharkOptimizer.NativeApp.MainWindow')
$definitions=$type.GetField('Definitions',[Reflection.BindingFlags]'Static,NonPublic').GetValue($null)
$rows=@($definitions | ForEach-Object { @{Id=$_.Id;Name=$_.Name;Category=$_.Category;Description=$_.Description;Risk=$_.Risk;Warning=$_.Warning} })
$folder=Join-Path $PSScriptRoot 'out\localization'
$null=New-Item -ItemType Directory -Path $folder -Force
[IO.File]::WriteAllText((Join-Path $folder 'tweak-text.json'),($rows | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
'Exported {0} native definitions without resolving or applying their targets.' -f $rows.Count
$localization=$assembly.GetType('SharkOptimizer.NativeApp.Localization')
$flags=[Reflection.BindingFlags]'Static,NonPublic'
$aliases=$type.GetField('LegacyTweakAliases',$flags).GetValue($null)
$null=$localization.GetMethod('AddTweakLabels',$flags).Invoke($null,@($definitions,$aliases))
$packs=$localization.GetField('Packs',$flags).GetValue($null)
foreach($code in @('nl','es','de','fr','pt','ru','zh')) {
 $missing=@($definitions | Where-Object { !$packs[$code].UI.ContainsKey($_.Name) } | ForEach-Object { $_.Name })
 [IO.File]::WriteAllText((Join-Path $folder ('tweak-titles-missing-'+$code+'.json')),($missing | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 '{0}: {1} built-in titles need translation' -f $code,$missing.Count
}
