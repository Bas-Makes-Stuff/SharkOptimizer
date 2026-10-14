$ErrorActionPreference='Stop'
$packs=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'translations.json') -Raw | ConvertFrom-Json -AsHashtable
$catalog=@{}
$literalPattern='(?s)//[^\r\n]*|/\*.*?\*/|''(?:\\.|[^''\\\r\n])*''|@"(?:""|[^"])*"|"(?:\\.|[^"\\\r\n])*"'
foreach($file in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.cs')) {
 $source=[IO.File]::ReadAllText($file.FullName)
 foreach($match in [regex]::Matches($source,$literalPattern)) {
  $raw=$match.Value
  if(!$raw.StartsWith('"') -and !$raw.StartsWith('@"')) { continue }
  if($raw.StartsWith('@')) { $value=$raw.Substring(2,$raw.Length-3).Replace('""','"') }
  else { try { $value=[regex]::Unescape($raw.Substring(1,$raw.Length-2)) } catch { continue } }
  if($value.Length -lt 2 -or $value -notmatch '[A-Za-z]' -or $value -notmatch '[a-z]') { continue }
  if($value -notmatch '\s' -and $value -notmatch '^[A-Z][a-z]+$') { continue }
  if($value -match '^(SELECT |root\\|SYSTEM\\|SOFTWARE\\|HK[A-Z]|https?://|<|--|[A-Z]:\\)' -or $value -match '^\^|\[A-Za-z|TemplateBinding|Binding Path|TargetType=') { continue }
  if($value.Contains('\') -and $value -notmatch '\s') { continue }
  if(!$catalog.ContainsKey($value)) { $catalog[$value]=[Collections.Generic.List[string]]::new() }
  $line=1+([regex]::Matches($source.Substring(0,$match.Index),'\n')).Count
  $catalog[$value].Add($file.Name+':'+$line)
 }
}
$reportFolder=Join-Path $PSScriptRoot 'out\localization'
$null=New-Item -ItemType Directory -Path $reportFolder -Force
$output=Join-Path $reportFolder 'translation-catalog.json'
$rows=@($catalog.Keys | Sort-Object | ForEach-Object { @{Text=$_;Sources=@($catalog[$_])} })
[IO.File]::WriteAllText($output,($rows | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
foreach($code in ($packs.Keys | Sort-Object)) {
 $known=@{}; foreach($key in $packs[$code].UI.Keys) { $known[$key]=$true }
 $missing=@($catalog.Keys | Where-Object { !$known.ContainsKey($_.Trim()) } | Sort-Object)
 [IO.File]::WriteAllText((Join-Path $reportFolder ('translations-missing-'+$code+'.json')),($missing | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 '{0}: {1} source phrases need translation/review' -f $code,$missing.Count
}
