param([string]$Version = '1.5.1')
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputFile = Join-Path $ProjectRoot 'SharkOptimizer-Setup.exe'
$Compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $Compiler)) { $Compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $Compiler)) { throw 'The .NET Framework C# compiler was not found.' }

$Sources = [ordered]@{
    'SharkOptimizer.Payload.Start-SharkOptimizer.bat' = Join-Path $ProjectRoot 'Start-SharkOptimizer.bat'
    'SharkOptimizer.Payload.SharkOptimizer.ps1' = Join-Path $ProjectRoot 'data\SharkOptimizer.ps1'
    'SharkOptimizer.Payload.SharkOptimizer-Launcher.ps1' = Join-Path $ProjectRoot 'data\SharkOptimizer-Launcher.ps1'
    'SharkOptimizer.Payload.Poppins-Regular.ttf' = Join-Path $ProjectRoot 'data\fonts\Poppins-Regular.ttf'
    'SharkOptimizer.Payload.Poppins-Bold.ttf' = Join-Path $ProjectRoot 'data\fonts\Poppins-Bold.ttf'
    'SharkOptimizer.Payload.shark.ico' = Join-Path $ProjectRoot 'data\shark.ico'
}
foreach ($resource in $Sources.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $resource.Value)) { throw "Build input missing: $($resource.Value)" }
}

$Manifest = Join-Path $PSScriptRoot 'app.manifest'
$SourceFile = Join-Path $PSScriptRoot 'SharkOptimizerSetup.cs'
$Arguments = @(
    '/nologo','/target:winexe','/platform:anycpu','/optimize+','/codepage:65001',
    "/out:$OutputFile", "/win32icon:$(Join-Path $ProjectRoot 'data\shark.ico')", "/win32manifest:$Manifest",
    '/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:Microsoft.CSharp.dll'
)
foreach ($resource in $Sources.GetEnumerator()) {
    $Arguments += "/resource:$($resource.Value),$($resource.Key)"
}
$Arguments += $SourceFile

if (Test-Path -LiteralPath $OutputFile) { Remove-Item -LiteralPath $OutputFile -Force }
& $Compiler @Arguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputFile)) {
    throw "The setup executable could not be compiled (exit code $LASTEXITCODE)."
}
$result = Get-Item -LiteralPath $OutputFile
Write-Output "Built $($result.FullName) ($([math]::Round($result.Length / 1MB, 2)) MB)"
