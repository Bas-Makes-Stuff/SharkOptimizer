param([string]$OutputPath, [string]$NativeAppPath)
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputFile = if ([string]::IsNullOrWhiteSpace($OutputPath)) { Join-Path $ProjectRoot 'SharkOptimizer-Setup.exe' } else { [System.IO.Path]::GetFullPath($OutputPath) }
$BuildStageDirectory = Join-Path (Split-Path -Parent $OutputFile) ('.shark-setup-build-' + [Guid]::NewGuid().ToString('N'))
$BuildOutputFile = Join-Path $BuildStageDirectory ([IO.Path]::GetFileName($OutputFile))
$PreviousOutputBackup = Join-Path $BuildStageDirectory 'previous-output.exe'
$PublishedBuild = $false
if ([string]::IsNullOrWhiteSpace($NativeAppPath)) {
    $NativeBuild = Join-Path $ProjectRoot 'native\build.ps1'
    & $NativeBuild
    $NativeApp = Join-Path $ProjectRoot 'native\out\SharkOptimizer.Native.exe'
} else { $NativeApp = [System.IO.Path]::GetFullPath($NativeAppPath) }
if (-not (Test-Path -LiteralPath $NativeApp)) { throw 'The native SharkOptimizer executable was not built.' }
$Compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $Compiler)) { $Compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $Compiler)) { throw 'The .NET Framework C# compiler was not found.' }

$Sources = [ordered]@{
    'SharkOptimizer.Payload.SharkOptimizer.Native.exe' = $NativeApp
    'SharkOptimizer.Payload.shark.ico' = Join-Path $ProjectRoot 'legacy\shark.ico'
}
foreach ($resource in $Sources.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $resource.Value)) { throw "Build input missing: $($resource.Value)" }
}

$Manifest = Join-Path $PSScriptRoot 'app.manifest'
$SourceFile = Join-Path $PSScriptRoot 'SharkOptimizerSetup.cs'
$Arguments = @(
    '/nologo','/target:winexe','/platform:anycpu','/optimize+','/codepage:65001',
    "/out:$BuildOutputFile", "/win32icon:$(Join-Path $ProjectRoot 'legacy\shark.ico')", "/win32manifest:$Manifest",
    '/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:Microsoft.CSharp.dll'
)
foreach ($resource in $Sources.GetEnumerator()) {
    $Arguments += "/resource:$($resource.Value),$($resource.Key)"
}
$Arguments += $SourceFile
$Arguments += (Join-Path $PSScriptRoot 'InstallTransaction.cs')
$Arguments += (Join-Path $PSScriptRoot 'UninstallCleanup.cs')
$Arguments += (Join-Path $ProjectRoot 'shared\StartupRegistration.cs')

New-Item -ItemType Directory -Path (Split-Path -Parent $OutputFile) -Force | Out-Null
New-Item -ItemType Directory -Path $BuildStageDirectory | Out-Null
try {
    & $Compiler @Arguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $BuildOutputFile)) {
        throw "The setup executable could not be compiled (exit code $LASTEXITCODE)."
    }
    if (Test-Path -LiteralPath $OutputFile) { [IO.File]::Replace($BuildOutputFile, $OutputFile, $PreviousOutputBackup) }
    else { [IO.File]::Move($BuildOutputFile, $OutputFile) }
    $PublishedBuild = $true
} finally {
    if (Test-Path -LiteralPath $BuildOutputFile) { Remove-Item -LiteralPath $BuildOutputFile -Force }
    if ($PublishedBuild -and (Test-Path -LiteralPath $PreviousOutputBackup)) { Remove-Item -LiteralPath $PreviousOutputBackup -Force }
    try { [IO.Directory]::Delete($BuildStageDirectory, $false) } catch { }
}
$result = Get-Item -LiteralPath $OutputFile
Write-Output "Built $($result.FullName) ($([math]::Round($result.Length / 1MB, 2)) MB)"
