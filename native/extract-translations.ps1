$ErrorActionPreference='Stop'
$legacy=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\legacy\SharkOptimizer.ps1'))
function Get-Block([string]$name) {
 $pattern='(?ms)^\$'+[regex]::Escape($name)+'\s*=\s*@''\r?\n(.*?)\r?\n''@'
 $match=[regex]::Match($legacy,$pattern)
 if(!$match.Success) { throw ('Missing translation block: '+$name) }
 $match.Groups[1].Value
}
function Get-Pairs([string]$block) {
 $pairs=@{}
 foreach($line in ($block -split '\r?\n')) { $at=$line.IndexOf(' => '); if($at -gt 0) { $pairs[$line.Substring(0,$at)]=$line.Substring($at+4) } }
 $pairs
}
$packs=@{}
$nlNames=@{}; $nlDescriptions=@{}
foreach($line in ((Get-Block 'tweakText') -split '\r?\n')) { $parts=$line.Split('|'); if($parts.Length -ge 3) { $nlNames[$parts[0]]=$parts[1]; $nlDescriptions[$parts[0]]=$parts[2] } }
$packs['nl']=@{UI=(Get-Pairs (Get-Block 'nlText'));Tweaks=$nlNames;Descriptions=$nlDescriptions}
foreach($code in @('es','de','fr','pt','ru','zh')) { $packs[$code]=@{UI=(Get-Pairs (Get-Block ('xl_'+$code+'_ui')));Tweaks=(Get-Pairs (Get-Block ('xl_'+$code+'_tw')));Descriptions=@{}} }
$keys=@('Optimize','Game Library','Game Boost','Windows Tools','Cleanup','System Lab','Guide','HOME','GAMING','TOOLS','MANAGE','Language','App behavior','Live system','Activity log')
$labels=@{
 nl=@('Optimaliseren','Gamebibliotheek','Gameboost','Windows-tools','Opruimen','Systeemlab','Handleiding','START','GAMING','HULPMIDDELEN','BEHEER','Taal','Appgedrag','Live systeem','Activiteitenlog')
 es=@('Optimizar','Biblioteca de juegos','Modo de juego','Herramientas de Windows','Limpieza','Laboratorio del sistema','Guía','INICIO','JUEGOS','HERRAMIENTAS','GESTIÓN','Idioma','Comportamiento de la aplicación','Sistema en vivo','Registro de actividad')
 de=@('Optimieren','Spielebibliothek','Spielmodus','Windows-Tools','Bereinigung','Systemlabor','Anleitung','START','GAMING','WERKZEUGE','VERWALTUNG','Sprache','App-Verhalten','Live-System','Aktivitätsprotokoll')
 fr=@('Optimiser','Bibliothèque de jeux','Mode jeu','Outils Windows','Nettoyage','Laboratoire système','Guide','ACCUEIL','JEUX','OUTILS','GESTION','Langue',"Comportement de l'application",'Système en direct',"Journal d'activité")
 pt=@('Otimizar','Biblioteca de jogos','Modo de jogo','Ferramentas do Windows','Limpeza','Laboratório do sistema','Guia','INÍCIO','JOGOS','FERRAMENTAS','GERENCIAR','Idioma','Comportamento do aplicativo','Sistema ao vivo','Registro de atividades')
 ru=@('Оптимизация','Библиотека игр','Игровой режим','Инструменты Windows','Очистка','Системная лаборатория','Руководство','ГЛАВНАЯ','ИГРЫ','ИНСТРУМЕНТЫ','УПРАВЛЕНИЕ','Язык','Поведение приложения','Система в реальном времени','Журнал действий')
 zh=@('优化','游戏库','游戏模式','Windows 工具','清理','系统实验室','使用指南','主页','游戏','工具','管理','语言','应用行为','实时系统','活动日志')
}
foreach($code in $labels.Keys) { if($labels[$code].Count -ne $keys.Count) { throw 'Invalid native-label count.' }; for($i=0;$i -lt $keys.Count;$i++) { $packs[$code].UI[$keys[$i]]=$labels[$code][$i] } }
$supplements=@((Join-Path $PSScriptRoot 'native-translations.json'))
$localeFolder=Join-Path $PSScriptRoot 'locales'
if(Test-Path -LiteralPath $localeFolder) { $supplements+=@(Get-ChildItem -LiteralPath $localeFolder -Filter '*.json' -File | Sort-Object Name | ForEach-Object { $_.FullName }) }
foreach($file in $supplements) {
 $supplement=[IO.File]::ReadAllText($file) | ConvertFrom-Json
 foreach($phrase in $supplement.PSObject.Properties) { foreach($translation in $phrase.Value.PSObject.Properties) { if($packs.ContainsKey($translation.Name)) { $packs[$translation.Name].UI[$phrase.Name]=$translation.Value } } }
}
$json=$packs | ConvertTo-Json -Depth 8 -Compress
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'translations.json'),$json,[Text.UTF8Encoding]::new($false))
$packs.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}: {1} UI labels, {2} tweak names' -f $_.Name,$_.Value.UI.Count,$_.Value.Tweaks.Count }
