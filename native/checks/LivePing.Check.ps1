param([string]$AppPath)
$ErrorActionPreference = 'Stop'
if (-not $AppPath) { $AppPath = Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
Add-Type -AssemblyName PresentationFramework
[Environment]::CurrentDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$historyType = $assembly.GetType('SharkOptimizer.NativeApp.LivePingHistory')
$constructor = $historyType.GetConstructor(@([string]))
$history = $constructor.Invoke(@('LOCALHOST'))
$time = [DateTime]::UtcNow
foreach ($latency in @(10,20,40,$null)) { $history.Add($time,$latency); $time = $time.AddSeconds(1) }
if ([Math]::Abs($history.Average - (70.0/3)) -gt .001 -or $history.Minimum -ne 10 -or $history.Maximum -ne 40 -or $history.Jitter -ne 15 -or $history.LossPercent -ne 25) { throw 'Latency/loss/jitter statistics failed.' }
$rolling = $constructor.Invoke(@('127.0.0.1'))
for ($i=0; $i -lt 70; $i++) { $rolling.Add($time.AddSeconds($i),$i) }
if ($rolling.Samples.Length -ne 60 -or $rolling.Completed -ne 70 -or $rolling.Minimum -ne 10 -or $rolling.Average -ne 39.5 -or $rolling.Jitter -ne 1) { throw 'Rolling history did not stay bounded to 60 samples.' }
if (($rolling.Csv() -split "`r`n" | Where-Object { $_ }).Count -ne 61) { throw 'CSV export did not include exactly the rolling window.' }
$normalizer = $historyType.GetMethod('NormalizeHost',[Reflection.BindingFlags]'Static,NonPublic')
if ($normalizer.Invoke($null,@('[::1]')) -ne '::1' -or $normalizer.Invoke($null,@('EXAMPLE.COM.')) -ne 'example.com') { throw 'IP/host normalization failed.' }
foreach ($bad in @('https://example.com','example.com:443','example.com & calc','bad host','-bad.example')) { $rejected=$false; try { $null=$normalizer.Invoke($null,@($bad)) } catch { $rejected=$true }; if (!$rejected) { throw ('Invalid host accepted: ' + $bad) } }
$windowType = $assembly.GetType('SharkOptimizer.NativeApp.MainWindow')
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$window = $windowType.GetConstructor($flags,$null,[Type[]]@([bool]),$null).Invoke(@($true))
$windowType.GetMethod('ShowPage',$flags).Invoke($window,@('Network'))
$windowType.GetField('_livePingHost',$flags).GetValue($window).Text = '127.0.0.1'
$dispatcher = [Windows.Threading.Dispatcher]::CurrentDispatcher
$oldContext = [Threading.SynchronizationContext]::Current
[Threading.SynchronizationContext]::SetSynchronizationContext((New-Object Windows.Threading.DispatcherSynchronizationContext $dispatcher))
try {
 $task = $windowType.GetMethod('StartLivePing',$flags).Invoke($window,@())
 $frame = New-Object Windows.Threading.DispatcherFrame
 $timer = New-Object Windows.Threading.DispatcherTimer
 $timer.Interval = [TimeSpan]::FromMilliseconds(15)
 $watch = [Diagnostics.Stopwatch]::StartNew()
 $timer.Add_Tick({ if ($task.IsCompleted -or $watch.ElapsedMilliseconds -gt 5000) { $timer.Stop(); $frame.Continue=$false } })
 $timer.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
 if (!$task.IsCompleted) { throw 'The first live sample exceeded five seconds.' }
 $null = $task.GetAwaiter().GetResult()
 $live = $windowType.GetField('_liveHistory',$flags).GetValue($window)
 if ($live.Completed -lt 1 -or $null -eq $live.Samples[0].LatencyMs) { throw 'Loopback did not produce a successful actual sample.' }
 $generation = $windowType.GetField('_livePingGeneration',$flags).GetValue($window)
 $windowType.GetMethod('StopLivePing',$flags).Invoke($window,@())
 $count = $live.Completed
 $stale = $windowType.GetMethod('SampleLivePing',$flags).Invoke($window,@($generation))
 $null = $stale.GetAwaiter().GetResult()
 if ($live.Completed -ne $count -or $windowType.GetField('_livePingStop',$flags).GetValue($window).IsEnabled) { throw 'Stopped/stale sampling altered the run.' }
 'Rolling statistics, jitter/loss, CSV bounds, IPv6/host validation, actual loopback sample, and stopped-generation checks passed.'
} finally {
 [Threading.SynchronizationContext]::SetSynchronizationContext($oldContext)
 $windowType.GetMethod('StopLivePing',$flags).Invoke($window,@())
 $window.Close()
}
