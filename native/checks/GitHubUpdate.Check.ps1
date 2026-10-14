param([string]$AppPath)
$ErrorActionPreference = 'Stop'
if (!$AppPath) { $AppPath = Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
Add-Type -AssemblyName PresentationFramework
[Environment]::CurrentDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$type = $assembly.GetType('SharkOptimizer.NativeApp.MainWindow')
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$window = $type.GetConstructor($flags,$null,[Type[]]@([bool]),$null).Invoke(@($true))
$download = $null
try {
 $release = $type.GetMethod('FetchLatestRelease',$flags).Invoke($window,@())
 if (!$release.AssetUrl -or !$release.AssetDigest.StartsWith('sha256:')) { throw 'The published installer asset or digest is missing.' }
 $download = $type.GetMethod('DownloadAndVerifySetup',$flags).Invoke($window,@($release))
 $hash = (Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash
 if ($hash -ne $release.AssetDigest.Substring(7)) { throw 'The real downloaded release did not match its digest.' }
 @{Result='Passed';Release=$release.Version.ToString();DownloadedBytes=(Get-Item -LiteralPath $download).Length;ProductVersion=(Get-Item -LiteralPath $download).VersionInfo.ProductVersion;SHA256Matches=$true;InstallerExecuted=$false} | ConvertTo-Json -Compress
} finally {
 if ($download -and [IO.File]::Exists($download)) { [IO.File]::Delete($download) }
 $window.Close()
}
