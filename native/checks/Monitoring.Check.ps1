param([string]$AppPath)
$ErrorActionPreference = 'Stop'
if (!$AppPath) { $AppPath = Join-Path $PSScriptRoot '..\out\SharkOptimizer.Native.exe' }
Add-Type -AssemblyName PresentationFramework
[Environment]::CurrentDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AppPath))
$type = $assembly.GetType('SharkOptimizer.NativeApp.MainWindow'); $flags = [Reflection.BindingFlags]'Instance,NonPublic'
$window = $type.GetConstructor($flags,$null,[Type[]]@([bool]),$null).Invoke(@($true))
# Preview construction prevents startup scans, tray registration, recovery, and saved-state writes.
# Enable only the monitoring visibility gate after that construction.
$type.GetField('_previewMode',$flags).SetValue($window,$false)
$window.ShowInTaskbar = $false; $window.ShowActivated = $false; $window.Left = -32000; $window.Top = -32000; $window.Opacity = 0
$previous = [Threading.SynchronizationContext]::Current
[Threading.SynchronizationContext]::SetSynchronizationContext((New-Object Windows.Threading.DispatcherSynchronizationContext))
function Wait-ForCpu {
 $frame = New-Object Windows.Threading.DispatcherFrame; $poll = New-Object Windows.Threading.DispatcherTimer
 $deadline = [DateTime]::UtcNow.AddSeconds(12); $poll.Interval = [TimeSpan]::FromMilliseconds(50)
 $poll.Add_Tick({ $text = $type.GetField('_cpuReading',$flags).GetValue($window).Text; if ($text -match '^\d+%$' -or [DateTime]::UtcNow -ge $deadline) { $poll.Stop(); $frame.Continue = $false } })
 $poll.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
 if ($type.GetField('_cpuReading',$flags).GetValue($window).Text -notmatch '^\d+%$') { throw 'Visible dashboard never received a CPU percentage.' }
}
try {
 $window.Show(); $window.UpdateLayout(); Wait-ForCpu
 $type.GetMethod('ShowPage',$flags).Invoke($window,@('Optimize'))
 if ($type.GetField('_monitorTimer',$flags).GetValue($window).IsEnabled) { throw 'Monitoring continued on another tab.' }
 $type.GetMethod('ShowPage',$flags).Invoke($window,@('Dashboard')); Wait-ForCpu
 $window.Hide()
 if ($type.GetField('_monitorTimer',$flags).GetValue($window).IsEnabled) { throw 'Monitoring continued while hidden.' }
 $window.Show(); Wait-ForCpu
 if ($type.GetField('_dashboardCpuHistory',$flags).GetValue($window).Count -lt 1) { throw 'CPU percentage did not feed the chart.' }
 'PASS: Live CPU percentage and history, dashboard return, hidden-window pause, and reopen. Preview state only; no saved user settings changed.'
} finally {
 $timer = $type.GetField('_monitorTimer',$flags).GetValue($window); if ($timer) { $timer.Stop() }
 $type.GetField('_previewMode',$flags).SetValue($window,$true); $window.Close()
 [Threading.SynchronizationContext]::SetSynchronizationContext($previous)
}
