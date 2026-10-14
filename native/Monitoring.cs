using System;
using System.Collections.Generic;
using System.Management;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace SharkOptimizer.NativeApp
{
    internal sealed class SystemSample
    {
        public double Cpu = -1, Ram = -1, Gpu = -1;
        public ulong TotalRam, AvailableRam;
    }
    internal sealed class SystemSampler
    {
        [StructLayout(LayoutKind.Sequential)] private struct MemoryStatus {
            public uint Length, Load;
            public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile, TotalVirtual, AvailableVirtual, AvailableExtended;
        }
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetSystemTimes(out ulong idle, out ulong kernel, out ulong user);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
        private ulong _idle, _kernel, _user;
        private bool _hasCpu;
        internal SystemSample Read()
        {
            var result = new SystemSample(); ulong idle, kernel, user;
            if (GetSystemTimes(out idle, out kernel, out user)) {
                if (_hasCpu && kernel >= _kernel && user >= _user && idle >= _idle) {
                    ulong total = kernel - _kernel + user - _user, idleDelta = idle - _idle;
                    if (total > 0 && idleDelta <= total) result.Cpu = 100.0 * (total - idleDelta) / total;
                }
                _hasCpu = true; _idle = idle; _kernel = kernel; _user = user;
            }
            var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf(typeof(MemoryStatus)) };
            if (GlobalMemoryStatusEx(ref memory) && memory.TotalPhysical > 0) {
                result.TotalRam = memory.TotalPhysical; result.AvailableRam = memory.AvailablePhysical;
                result.Ram = 100.0 * (memory.TotalPhysical - Math.Min(memory.AvailablePhysical, memory.TotalPhysical)) / memory.TotalPhysical;
            }
            try {
                var options = new EnumerationOptions { Timeout = TimeSpan.FromSeconds(2), ReturnImmediately = false };
                using (var query = new ManagementObjectSearcher("root\\cimv2", "SELECT Name,UtilizationPercentage FROM Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine", options))
                using (ManagementObjectCollection rows = query.Get()) {
                    var engines = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase); int count = 0;
                    foreach (ManagementObject row in rows) using (row) {
                        if (++count > 2048) { engines.Clear(); break; }
                        string name = Convert.ToString(row["Name"]); int adapter = name.IndexOf("luid_", StringComparison.OrdinalIgnoreCase);
                        if (adapter < 0) continue;
                        string engine = name.Substring(adapter); double value = Convert.ToDouble(row["UtilizationPercentage"]);
                        if (Double.IsNaN(value) || Double.IsInfinity(value) || value < 0) continue;
                        double prior; engines.TryGetValue(engine, out prior); engines[engine] = prior + value;
                    }
                    if (engines.Count > 0) result.Gpu = Math.Min(100, engines.Values.Max());
                }
            } catch { }
            return result;
        }
    }
    internal sealed partial class MainWindow
    {
        private DispatcherTimer _monitorTimer;
        private SystemSampler _systemSampler;
        private bool _monitorBusy;
        private int _monitorGeneration;
        private TextBlock _cpuReading, _ramReading, _gpuReading, _ramDetail, _monitorStatus;
        private UIElement BuildMonitoringCard()
        {
            return BuildDashboardMonitoring();
        }
        private void RefreshMonitoringVisibility()
        {
            bool visible = !_previewMode && IsVisible && _pages.ContainsKey("Dashboard") && _pages["Dashboard"].IsVisible && _cpuReading != null;
            if (!visible) { if (_monitorTimer != null) _monitorTimer.Stop(); _monitorGeneration++; _systemSampler = null; return; }
            if (_monitorTimer == null) { _monitorTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) }; _monitorTimer.Tick += async delegate { await SampleDashboard(); }; }
            if (!_monitorTimer.IsEnabled) { _systemSampler = new SystemSampler(); _monitorTimer.Start(); Dispatcher.BeginInvoke(new Action(async delegate { await SampleDashboard(); })); }
        }
        private async Task SampleDashboard()
        {
            if (_monitorBusy || _systemSampler == null || !IsVisible) return;
            _monitorBusy = true; int generation = _monitorGeneration; SystemSampler sampler = _systemSampler;
            try {
                var sample = await Task.Run(new Func<SystemSample>(sampler.Read));
                if (generation != _monitorGeneration || !IsVisible) return;
                RenderMonitoringValue(_cpuReading, sample.Cpu); RenderMonitoringValue(_ramReading, sample.Ram); RenderMonitoringValue(_gpuReading, sample.Gpu);
                UpdateDashboardGauges(sample);
                _ramDetail.Text = sample.TotalRam == 0 ? "Memory data unavailable" : FormatBytes((long)(sample.TotalRam - Math.Min(sample.AvailableRam, sample.TotalRam))) + " / " + FormatBytes((long)sample.TotalRam);
                _monitorStatus.Text = "Updated " + DateTime.Now.ToString("T");
            } catch { if (generation == _monitorGeneration) _monitorStatus.Text = "Readings temporarily unavailable"; }
            finally { _monitorBusy = false; }
        }
        private static void RenderMonitoringValue(TextBlock text, double value)
        {
            bool available = !Double.IsNaN(value) && !Double.IsInfinity(value) && value >= 0 && value <= 100;
            text.Text = available ? value.ToString("0") + "%" : "—";
        }
    }
}
