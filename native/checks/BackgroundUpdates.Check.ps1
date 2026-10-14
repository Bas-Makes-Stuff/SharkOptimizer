param([string]$AppPath, [string]$SetupPath)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (!$AppPath) { $AppPath = Join-Path $projectRoot 'native\out\SharkOptimizer.Native.exe' }
if (!$SetupPath) { $version = [IO.File]::ReadAllText((Join-Path $projectRoot 'VERSION')).Trim(); $SetupPath = Join-Path $projectRoot ('release\' + $version + '\SharkOptimizer-Setup.exe') }
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Web.Extensions
[Environment]::CurrentDirectory = $projectRoot
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$type = $assembly.GetType('SharkOptimizer.NativeApp.MainWindow')
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$static = [Reflection.BindingFlags]'Static,NonPublic'
$window = $type.GetConstructor($flags,$null,[Type[]]@([bool]),$null).Invoke(@($true))
[string]$folder = Join-Path $projectRoot ('native\out\update-check-' + [Guid]::NewGuid().ToString('N'))
if (![IO.Path]::GetFullPath($folder).StartsWith($projectRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture outside workspace.' }
[IO.Directory]::CreateDirectory($folder) | Out-Null
[string]$file = Join-Path $folder 'setup.exe'
$previousContext = [Threading.SynchronizationContext]::Current
[Threading.SynchronizationContext]::SetSynchronizationContext((New-Object Windows.Threading.DispatcherSynchronizationContext))
$cancellation = $null
try {
 $state = $type.GetField('_state',$flags).GetValue($window)
 if (!$state.AutoDownloadUpdates) { throw 'New app state does not enable approved background downloads by default.' }
 $oldState = (New-Object Web.Script.Serialization.JavaScriptSerializer).Deserialize('{"Schema":1,"Applied":[]}', $assembly.GetType('SharkOptimizer.NativeApp.AppState'))
 if (!$oldState.AutoDownloadUpdates) { throw 'Existing state without the new preference loses its default.' }
 [IO.File]::Copy($SetupPath,$file)
 $release = [Activator]::CreateInstance($assembly.GetType('SharkOptimizer.NativeApp.UpdateReleaseInfo'))
 $release.Version = [Version]([IO.File]::ReadAllText((Join-Path $projectRoot 'VERSION')).Trim())
 $release.AssetSize = (Get-Item -LiteralPath $file).Length
 $release.AssetDigest = 'sha256:' + (Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant()
 $type.GetMethod('ValidateDownloadedSetup',$static).Invoke($null,@($file,$release))
 $stream = [IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try { $originalByte = $stream.ReadByte(); $stream.Position = 0; $stream.WriteByte([byte]($originalByte -bxor 1)) } finally { $stream.Dispose() }
 $rejected = $false
 try { $type.GetMethod('ValidateDownloadedSetup',$static).Invoke($null,@($file,$release)) } catch { $rejected = $true }
 if (!$rejected) { throw 'A changed cached installer passed digest verification.' }
 $stream = [IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try { $stream.WriteByte([byte]$originalByte) } finally { $stream.Dispose() }
 $type.GetMethod('ValidateDownloadedSetup',$static).Invoke($null,@($file,$release))
 $type.GetField('_pendingUpdatePath',$flags).SetValue($window,$file)
 $type.GetField('_pendingUpdateRelease',$flags).SetValue($window,$release)
 $type.GetMethod('ShowPage',$flags).Invoke($window,@('Settings'))
 $type.GetField('_selectSettingsSection',$flags).GetValue($window).Invoke(1)
 $type.GetMethod('RefreshUpdateControls',$flags).Invoke($window,@())
 if ($type.GetField('_updateReadyButton',$flags).GetValue($window).Visibility -ne 'Visible') { throw 'Ready update has no header action.' }
 if ($type.GetField('_updateButton',$flags).GetValue($window).Content -ne 'Install downloaded update') { throw 'Ready update did not change the install action.' }
 $cancellation = New-Object Threading.CancellationTokenSource
 $worker = [Threading.Tasks.Task]::Delay(10000,$cancellation.Token)
 $type.GetField('_updateDownloadCancellation',$flags).SetValue($window,$cancellation.PSObject.BaseObject)
 $type.GetField('_updateWorkTask',$flags).SetValue($window,$worker.PSObject.BaseObject)
 $task = $type.GetMethod('StopBackgroundUpdateDownloads',$flags).Invoke($window,@())
 $frame = New-Object Windows.Threading.DispatcherFrame; $poll = New-Object Windows.Threading.DispatcherTimer
 $deadline = [DateTime]::UtcNow.AddSeconds(5); $poll.Interval = [TimeSpan]::FromMilliseconds(10)
 $poll.Add_Tick({ if ($task.IsCompleted -or [DateTime]::UtcNow -ge $deadline) { $poll.Stop(); $frame.Continue = $false } })
 $poll.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
 if (!$task.IsCompleted) { throw 'Update shutdown did not finish promptly.' }
 $null = $task.GetAwaiter().GetResult()
 if (!$worker.IsCanceled -or [IO.File]::Exists($file) -or $type.GetMethod('HasPendingUpdate',$flags).Invoke($window,@())) { throw 'Exit did not cancel work and clean its owned update.' }
 'PASS: Saved-state defaults, valid setup verification, changed-cache rejection, update-ready controls, cancelled background work, and owned-cache cleanup. No installer was executed.'
} finally {
 [Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
 if ($cancellation) { $cancellation.Dispose() }
 if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
 [IO.Directory]::Delete($folder,$false)
 $window.Close()
}
