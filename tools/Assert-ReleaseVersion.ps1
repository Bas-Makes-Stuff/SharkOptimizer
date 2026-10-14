param([string]$Tag, [string]$AppPath, [string]$SetupPath)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$releaseVersion = [IO.File]::ReadAllText((Join-Path $projectRoot 'VERSION')).Trim()
if ($releaseVersion -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw 'VERSION must contain major.minor.patch.' }
$parts = $releaseVersion.Split('.')
foreach ($part in $parts) { if ([long]$part -gt 65534) { throw 'Assembly version components must be at most 65534.' } }
if ($Tag -and $Tag -ne ('v' + $releaseVersion) -and $Tag -ne $releaseVersion) { throw 'The release tag does not match VERSION.' }
$native = [IO.File]::ReadAllText((Join-Path $projectRoot 'native\SharkOptimizer.cs'))
$setup = [IO.File]::ReadAllText((Join-Path $projectRoot 'installer\SharkOptimizerSetup.cs'))
foreach ($text in @($native,$setup)) {
 foreach ($attribute in @('AssemblyVersion','AssemblyFileVersion')) {
  $expected = $attribute + '("' + $releaseVersion + '.0")'
  if (!$text.Contains($expected)) { throw ($attribute + ' does not match VERSION.') }
 }
}
if (!$setup.Contains('internal const string Version = "' + $releaseVersion + '";')) { throw 'Installer version constant does not match VERSION.' }
$tuple = 'new Version(' + ($parts -join ', ') + ')'
if (!$native.Contains('CurrentAppVersion = ' + $tuple)) { throw 'Updater version comparison does not match VERSION.' }
foreach ($path in @($AppPath,$SetupPath) | Where-Object { $_ }) {
 $file = Get-Item -LiteralPath $path
 if ($file.VersionInfo.FileVersion -ne ($releaseVersion + '.0')) { throw ('Compiled version mismatch: ' + $file.FullName) }
}
'Validated release version ' + $releaseVersion
