$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixture = Join-Path $projectRoot ('native\out\version-check-' + [Guid]::NewGuid().ToString('N'))
if (!$fixture.StartsWith($projectRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture outside workspace.' }
$files = @('VERSION','README.md','native\README.md','native\SharkOptimizer.cs','native\UpdateTransport.cs','installer\SharkOptimizerSetup.cs','tools\Set-Version.ps1','tools\Assert-ReleaseVersion.ps1')
$originalVersion = [IO.File]::ReadAllText((Join-Path $projectRoot 'VERSION'))
try {
 foreach ($relative in $files) {
  $destination = Join-Path $fixture $relative
  [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
  [IO.File]::Copy((Join-Path $projectRoot $relative),$destination)
 }
 [IO.Directory]::CreateDirectory((Join-Path $fixture 'shared')) | Out-Null
 $current = [Version]$originalVersion.Trim()
 $next = '{0}.{1}.{2}' -f $current.Major,$current.Minor,($current.Build + 1)
 & (Join-Path $fixture 'tools\Set-Version.ps1') -Version $next
 & (Join-Path $fixture 'tools\Assert-ReleaseVersion.ps1') -Tag ('v' + $next)
 $transport = [IO.File]::ReadAllText((Join-Path $fixture 'native\UpdateTransport.cs'))
 if (!$transport.Contains('SharkOptimizer/' + $next + ' (Windows updater)')) { throw 'Updater user agent did not change.' }
 $rejected = $false
 try { & (Join-Path $fixture 'tools\Set-Version.ps1') -Version $current.ToString(3) } catch { $rejected = $true }
 if (!$rejected) { throw 'Version downgrade was accepted.' }
 $nativePath = Join-Path $fixture 'native\SharkOptimizer.cs'
 $native = [IO.File]::ReadAllText($nativePath)
 $broken = $native.Replace('AssemblyFileVersion("' + $next + '.0")','AssemblyFileVersion("0.0.0.0")')
 [IO.File]::WriteAllText($nativePath,$broken)
 $further = '{0}.{1}.{2}' -f $current.Major,$current.Minor,($current.Build + 2)
 $rejected = $false
 try { & (Join-Path $fixture 'tools\Set-Version.ps1') -Version $further } catch { $rejected = $true }
 if (!$rejected -or [IO.File]::ReadAllText($nativePath) -ne $broken -or [IO.File]::ReadAllText((Join-Path $fixture 'VERSION')).Trim() -ne $next) { throw 'Failed version validation did not restore the fixture.' }
 if ([IO.File]::ReadAllText((Join-Path $projectRoot 'VERSION')) -ne $originalVersion) { throw 'Real project version changed.' }
 'PASS: Isolated version bump, updater alignment, tag validation, downgrade rejection, and failed-change rollback. Real project version unchanged.'
} finally {
 foreach ($relative in $files) { $path = Join-Path $fixture $relative; if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
 foreach ($relative in @('tools','shared','installer','native')) { $path = Join-Path $fixture $relative; if ([IO.Directory]::Exists($path)) { [IO.Directory]::Delete($path,$false) } }
 if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture,$false) }
}
