param([string]$OutputPath)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$version = [IO.File]::ReadAllText((Join-Path $projectRoot 'VERSION')).Trim()
& (Join-Path $PSScriptRoot 'Assert-ReleaseVersion.ps1')
if (!$OutputPath) { $OutputPath = Join-Path $projectRoot ('release\' + $version + '\SharkOptimizer-Source.zip') }
$outputFile = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory((Split-Path -Parent $outputFile)) | Out-Null
$stage = Join-Path (Split-Path -Parent $outputFile) ('.source-package-' + [Guid]::NewGuid().ToString('N'))
if (!$stage.StartsWith([IO.Path]::GetFullPath((Split-Path -Parent $outputFile)) + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid staging path.' }
[IO.Directory]::CreateDirectory($stage) | Out-Null
$files = @('VERSION','README.md','RELEASE-GUIDE.md','Start-SharkOptimizer.bat','.github\workflows\release.yml',('release-notes\' + $version + '.md'))
foreach ($folder in @('native','installer','shared','tools','legacy')) {
 $sourceRoot = Join-Path $projectRoot $folder
 foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File) {
  $relative = $file.FullName.Substring($projectRoot.Length + 1)
  if ($file.FullName.Substring($sourceRoot.Length) -match '[\\/](out|\.git)[\\/]') { continue }
  if ($file.Extension -notin @('.cs','.ps1','.json','.manifest','.md','.txt','.svg','.ico','.ttf')) { continue }
  $files += $relative
 }
}
$files = @($files | Sort-Object -Unique)
$stagedZip = $stage + '.zip'
$backupZip = $stage + '.previous.zip'
try {
 foreach ($relative in $files) {
  $source = Join-Path $projectRoot $relative; $destination = Join-Path $stage $relative
  if (!(Test-Path -LiteralPath $source -PathType Leaf)) { throw ('Source package input missing: ' + $relative) }
  [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
  [IO.File]::Copy($source,$destination)
 }
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 [IO.Compression.ZipFile]::CreateFromDirectory($stage,$stagedZip,[IO.Compression.CompressionLevel]::Optimal,$false)
 if ([IO.File]::Exists($outputFile)) { [IO.File]::Replace($stagedZip,$outputFile,$backupZip) } else { [IO.File]::Move($stagedZip,$outputFile) }
 [ordered]@{Version=$version;Files=$files.Count;Path=$outputFile;SHA256=(Get-FileHash -LiteralPath $outputFile).Hash} | ConvertTo-Json -Compress
} finally {
 foreach ($path in @($stagedZip,$backupZip)) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
 # Only this newly created, verified staging folder is removed.
 if ([IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage,$true) }
}
