param([string]$Configuration = 'Debug', [string]$OutputPath)
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OutputDir = Join-Path $PSScriptRoot 'out'
$OutputFile = if ([string]::IsNullOrWhiteSpace($OutputPath)) { Join-Path $OutputDir 'SharkOptimizer.Native.exe' } else { [System.IO.Path]::GetFullPath($OutputPath) }
$BuildStageDirectory = Join-Path (Split-Path -Parent $OutputFile) ('.shark-build-' + [Guid]::NewGuid().ToString('N'))
$BuildOutputFile = Join-Path $BuildStageDirectory ([IO.Path]::GetFileName($OutputFile))
$PreviousOutputBackup = Join-Path $BuildStageDirectory 'previous-output.exe'
$PublishedBuild = $false
$Compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $Compiler)) { $Compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $Compiler)) { throw 'The Windows .NET Framework C# compiler was not found.' }
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $OutputFile) -Force | Out-Null
$FrameworkRoot = if ($env:PROCESSOR_ARCHITECTURE -eq 'x86') { Join-Path $env:SystemRoot 'Microsoft.NET\Framework' } else { Join-Path $env:SystemRoot 'Microsoft.NET\Framework64' }
$GacRoot = Join-Path $env:SystemRoot 'Microsoft.NET\assembly'
$GacArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'x86') { 'GAC_32' } else { 'GAC_64' }
$WpfFramework = Join-Path $GacRoot 'GAC_MSIL\PresentationFramework\v4.0_4.0.0.0__31bf3856ad364e35\PresentationFramework.dll'
$WpfCore = Join-Path $GacRoot "$GacArch\PresentationCore\v4.0_4.0.0.0__31bf3856ad364e35\PresentationCore.dll"
$WpfBase = Join-Path $GacRoot 'GAC_MSIL\WindowsBase\v4.0_4.0.0.0__31bf3856ad364e35\WindowsBase.dll'
$WpfXaml = Join-Path $GacRoot 'GAC_MSIL\System.Xaml\v4.0_4.0.0.0__b77a5c561934e089\System.Xaml.dll'
$WebExtensions = Join-Path $FrameworkRoot 'v4.0.30319\System.Web.Extensions.dll'
$Management = Join-Path $FrameworkRoot 'v4.0.30319\System.Management.dll'
$ServiceProcess = Join-Path $FrameworkRoot 'v4.0.30319\System.ServiceProcess.dll'
$WinForms = Join-Path $FrameworkRoot 'v4.0.30319\System.Windows.Forms.dll'
$Drawing = Join-Path $FrameworkRoot 'v4.0.30319\System.Drawing.dll'
$RuntimeFacade = Join-Path $GacRoot 'GAC_MSIL\System.Runtime\v4.0_4.0.0.0__b03f5f7f11d50a3a\System.Runtime.dll'
$CollectionsFacade = Join-Path $GacRoot 'GAC_MSIL\System.Collections\v4.0_4.0.0.0__b03f5f7f11d50a3a\System.Collections.dll'
$WinMetadata = Join-Path $env:SystemRoot 'System32\WinMetadata'
$References = @($WpfFramework, $WpfCore, $WpfBase, $WpfXaml, $WebExtensions, $Management, $ServiceProcess, $WinForms, $Drawing, $RuntimeFacade, $CollectionsFacade,
    (Join-Path $WinMetadata 'Windows.Foundation.winmd'), (Join-Path $WinMetadata 'Windows.ApplicationModel.winmd'), (Join-Path $WinMetadata 'Windows.Management.winmd'))
foreach ($reference in $References) { if (-not (Test-Path -LiteralPath $reference)) { throw "Required .NET Framework reference not found: $reference" } }
$args = @(
    '/nologo','/target:winexe','/platform:anycpu','/optimize+',
    "/out:$BuildOutputFile", "/win32icon:$(Join-Path $ProjectRoot 'legacy\shark.ico')", "/win32manifest:$(Join-Path $PSScriptRoot 'app.manifest')",
    "/resource:$(Join-Path $ProjectRoot 'legacy\fonts\Poppins-Regular.ttf'),SharkOptimizer.Fonts.Poppins-Regular.ttf",
    "/resource:$(Join-Path $ProjectRoot 'legacy\fonts\Poppins-Bold.ttf'),SharkOptimizer.Fonts.Poppins-Bold.ttf",
    (Join-Path $PSScriptRoot 'SharkOptimizer.cs'), (Join-Path $PSScriptRoot 'Presets.cs'), (Join-Path $PSScriptRoot 'UiPolish.cs'), (Join-Path $PSScriptRoot 'ControlStyles.cs'), (Join-Path $PSScriptRoot 'Backups.cs'), (Join-Path $PSScriptRoot 'CustomTweaks.cs'), (Join-Path $PSScriptRoot 'LivePing.cs'), (Join-Path $PSScriptRoot 'Guide.cs'), (Join-Path $PSScriptRoot 'NetworkCommands.cs'), (Join-Path $PSScriptRoot 'GameSessions.cs'), (Join-Path $PSScriptRoot 'SessionExtras.cs')
)
$args += (Join-Path $ProjectRoot 'shared\StartupRegistration.cs')
$args += (Join-Path $PSScriptRoot 'StartupIntegration.cs')
$args += (Join-Path $PSScriptRoot 'Monitoring.cs')
$args += (Join-Path $PSScriptRoot 'DashboardLayout.cs')
$args += (Join-Path $PSScriptRoot 'DashboardMonitoring.cs')
$args += (Join-Path $PSScriptRoot 'Applicability.cs')
$args += (Join-Path $PSScriptRoot 'SystemOperations.cs')
$args += (Join-Path $PSScriptRoot 'Maintenance.cs')
$args += (Join-Path $PSScriptRoot 'CleanupHistory.cs')
$args += (Join-Path $PSScriptRoot 'CleanupFilters.cs')
$args += (Join-Path $PSScriptRoot 'Recommendations.cs')
$args += (Join-Path $PSScriptRoot 'BenchmarkHistory.cs')
$args += (Join-Path $PSScriptRoot 'BehaviorSettings.cs')
$args += (Join-Path $PSScriptRoot 'BrandAssets.cs')
$args += (Join-Path $PSScriptRoot 'FluentIcons.cs')
$args += (Join-Path $PSScriptRoot 'UpdateTransport.cs')
$args += (Join-Path $PSScriptRoot 'BackgroundUpdates.cs')
$args += (Join-Path $PSScriptRoot 'ExistingTweaks.cs')
$args += (Join-Path $PSScriptRoot 'AutomaticGameBoost.cs')
$args += "/resource:$(Join-Path $PSScriptRoot 'assets\fluent-icons\icons.json'),SharkOptimizer.Icons.json"
$args += "/resource:$(Join-Path $PSScriptRoot 'assets\fluent-icons\LICENSE.txt'),SharkOptimizer.Icons.License"
$args += "/resource:$(Join-Path $PSScriptRoot 'assets\fluent-icons\NOTICE.txt'),SharkOptimizer.Icons.Notice"
$args += "/resource:$(Join-Path $PSScriptRoot 'assets\fluent-icons\SOURCE.txt'),SharkOptimizer.Icons.Source"
$args += "/resource:$(Join-Path $PSScriptRoot 'assets\Poppins-OFL.txt'),SharkOptimizer.Fonts.License"
$args += (Join-Path $PSScriptRoot 'Localization.cs')
$args += (Join-Path $PSScriptRoot 'LocalizedDialogs.cs')
$args += "/resource:$(Join-Path $PSScriptRoot 'translations.json'),SharkOptimizer.Translations.json"
$args += "/resource:$(Join-Path $ProjectRoot 'legacy\shark.ico'),SharkOptimizer.Brand.shark.ico"
foreach ($reference in $References) { $args += "/reference:$reference" }
try {
    New-Item -ItemType Directory -Path $BuildStageDirectory | Out-Null
    & $Compiler @args
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $BuildOutputFile)) { throw "Native application build failed with exit code $LASTEXITCODE." }
    if (Test-Path -LiteralPath $OutputFile) { [IO.File]::Replace($BuildOutputFile, $OutputFile, $PreviousOutputBackup) }
    else { [IO.File]::Move($BuildOutputFile, $OutputFile) }
    $PublishedBuild = $true
} finally {
    if (Test-Path -LiteralPath $BuildOutputFile) { Remove-Item -LiteralPath $BuildOutputFile -Force }
    if ($PublishedBuild -and (Test-Path -LiteralPath $PreviousOutputBackup)) { Remove-Item -LiteralPath $PreviousOutputBackup -Force }
    try { [IO.Directory]::Delete($BuildStageDirectory, $false) } catch { }
}
Write-Output "Built $OutputFile"
