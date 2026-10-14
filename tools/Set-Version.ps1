param([Parameter(Mandatory=$true)][string]$Version)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$versionPath = Join-Path $projectRoot 'VERSION'
$previous = [IO.File]::ReadAllText($versionPath).Trim()
if ($Version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw 'Use major.minor.patch, such as 2.1.2.' }
foreach ($part in $Version.Split('.')) { if ([long]$part -gt 65534) { throw 'Assembly version components must be at most 65534.' } }
if ([version]$Version -lt [version]$previous) { throw 'Choose a version at least as new as the current version.' }
if ($Version -eq $previous) { & (Join-Path $PSScriptRoot 'Assert-ReleaseVersion.ps1'); return }
$sources = @()
foreach ($folder in @('native','installer','shared')) {
 $sourceRoot = Join-Path $projectRoot $folder
 $sources += @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | Where-Object { $_.Extension -in @('.cs','.json') -and $_.FullName.Substring($sourceRoot.Length) -notmatch '[\\/]out[\\/]' })
}
$sources += @(Get-Item -LiteralPath (Join-Path $projectRoot 'README.md'),(Join-Path $projectRoot 'native\README.md'))
$changes = @(); $pattern = '(?<![0-9])' + [regex]::Escape($previous) + '(?![0-9])'
foreach ($file in $sources) {
 $original = [IO.File]::ReadAllText($file.FullName); $updated = [regex]::Replace($original,$pattern,$Version)
 if ($file.Name -eq 'SharkOptimizer.cs') {
  $oldTuple = 'CurrentAppVersion = new Version(' + ($previous.Split('.') -join ', ') + ')'
  $newTuple = 'CurrentAppVersion = new Version(' + ($Version.Split('.') -join ', ') + ')'
  if (!$updated.Contains($oldTuple)) { throw 'Updater version constant was not found.' }
  $updated = $updated.Replace($oldTuple,$newTuple)
 }
 if ($updated -ne $original) { $changes += @{Path=$file.FullName;Original=$original;Updated=$updated} }
}
try {
 foreach ($change in $changes) { [IO.File]::WriteAllText($change.Path,$change.Updated,[Text.UTF8Encoding]::new($false)) }
 [IO.File]::WriteAllText($versionPath,$Version + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
 & (Join-Path $PSScriptRoot 'Assert-ReleaseVersion.ps1')
} catch {
 foreach ($change in $changes) { [IO.File]::WriteAllText($change.Path,$change.Original,[Text.UTF8Encoding]::new($false)) }
 [IO.File]::WriteAllText($versionPath,$previous + [Environment]::NewLine,[Text.UTF8Encoding]::new($false)); throw
}
'Updated source and language resources to ' + $Version + '. Rebuild before release.'
