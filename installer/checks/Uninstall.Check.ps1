param([string]$SetupPath, [string]$AppPath)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (!$SetupPath) { $SetupPath = Join-Path $projectRoot 'release\2.0.0\SharkOptimizer-Setup.exe' }
if (!$AppPath) { $AppPath = Join-Path $projectRoot 'native\out\SharkOptimizer.Native.exe' }
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($SetupPath))
$type = $assembly.GetType('UninstallCleanup', $true)
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$unicodeSuffix = '-' + [char]0x00E9 + '-' + [char]0x4E2D + [char]0x6587 + '-&-%'
[string]$fixture = Join-Path $projectRoot ('native\out\uninstall-fixture-' + [Guid]::NewGuid().ToString('N') + $unicodeSuffix)
if (![IO.Path]::GetFullPath($fixture).StartsWith($projectRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture outside workspace.' }
[IO.Directory]::CreateDirectory((Join-Path $fixture 'data')) | Out-Null
try {
 [IO.File]::Copy($SetupPath, (Join-Path $fixture 'Uninstall-SharkOptimizer.exe'))
 [IO.File]::Copy($AppPath, (Join-Path $fixture 'SharkOptimizer.exe'))
 [IO.File]::Copy((Join-Path $projectRoot 'legacy\shark.ico'), (Join-Path $fixture 'data\shark.ico'))
 $retained = Join-Path $fixture 'data\keep.txt'
 [IO.File]::WriteAllText($retained, 'User-owned file')
 $type.GetMethod('ValidateRoot', $flags).Invoke($null, @($fixture)) | Out-Null
 $type.GetMethod('RequireAppClosed', $flags).Invoke($null, @($fixture)) | Out-Null
 $lock = [IO.File]::Open((Join-Path $fixture 'SharkOptimizer.exe'), 'Open', 'Read', 'None')
 try {
  $rejected = $false
  try { $type.GetMethod('RequireAppClosed', $flags).Invoke($null, @($fixture)) | Out-Null } catch { $rejected = $true }
  if (!$rejected) { throw 'A locked app was accepted for uninstall.' }
 } finally { $lock.Dispose() }
 $type.GetMethod('DeletePayload', $flags).Invoke($null, @($fixture)) | Out-Null
 foreach ($name in @('SharkOptimizer.exe', 'Uninstall-SharkOptimizer.exe', 'data\shark.ico')) {
  if ([IO.File]::Exists((Join-Path $fixture $name))) { throw ('Installer-owned payload retained: ' + $name) }
 }
 if ([IO.File]::ReadAllText($retained) -ne 'User-owned file') { throw 'User-owned file changed.' }
 $type.GetMethod('RemoveEmptyDirectory', $flags).Invoke($null, @($fixture)) | Out-Null
 if (![IO.Directory]::Exists($fixture)) { throw 'Non-empty folder was removed.' }
 'PASS: Unicode and shell-special paths, locked-app rejection, exact payload deletion, and unrelated-file retention.'
} finally {
 foreach ($name in @('SharkOptimizer.exe', 'Uninstall-SharkOptimizer.exe', 'data\shark.ico', 'data\keep.txt')) {
  $file = Join-Path $fixture $name; if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
 }
 $data = Join-Path $fixture 'data'; if ([IO.Directory]::Exists($data)) { [IO.Directory]::Delete($data, $false) }
 if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture, $false) }
}
