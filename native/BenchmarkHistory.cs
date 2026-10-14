using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace SharkOptimizer.NativeApp
{
    internal sealed class BenchmarkRun
    {
        public string Id { get; set; }
        public string Slot { get; set; }
        public BenchSnapshot Data { get; set; }
    }
    internal static class BenchmarkHistory
    {
        internal static double Median(IEnumerable<double> source)
        {
            double[] values = source.Where(x => x >= 0 && !Double.IsNaN(x) && !Double.IsInfinity(x)).OrderBy(x => x).ToArray();
            if (values.Length == 0) return -1; int mid = values.Length / 2;
            return values.Length % 2 == 1 ? values[mid] : values[mid - 1] / 2 + values[mid] / 2;
        }
        internal static BenchSnapshot Summarize(IEnumerable<BenchmarkRun> history, string slot)
        {
            var samples = history.Where(x => x != null && x.Slot == slot && x.Data != null).Take(3).Select(x => x.Data).ToArray();
            if (samples.Length == 0) return null;
            return new BenchSnapshot { CapturedAt = samples[0].CapturedAt, PingMs = Median(samples.Select(x => x.PingMs)), JitterMs = Median(samples.Select(x => x.JitterMs)), DnsMs = Median(samples.Select(x => x.DnsMs)), CpuUse = Median(samples.Select(x => x.CpuUse)), FreeMemoryMb = Median(samples.Select(x => x.FreeMemoryMb)), RamUsedPercent = Median(samples.Select(x => x.RamUsedPercent)), ProcessCount = (int)Median(samples.Select(x => (double)x.ProcessCount)), ServicesRunning = (int)Median(samples.Select(x => (double)x.ServicesRunning)), BootSeconds = Median(samples.Select(x => x.BootSeconds)) };
        }
        internal static List<BenchmarkRun> Legacy(string json)
        {
            var serializer = new JavaScriptSerializer { MaxJsonLength = 2 * 1024 * 1024 };
            var document = serializer.DeserializeObject(json) as IDictionary<string, object>; if (document == null) throw new InvalidDataException("The previous benchmark data is invalid.");
            var result = new List<BenchmarkRun>(); object rows;
            if (document.TryGetValue("Runs", out rows) && rows is object[]) foreach (var value in (object[])rows) {
                var entry = value as IDictionary<string, object>; object slot, data;
                if (entry == null || !entry.TryGetValue("slot", out slot) || !entry.TryGetValue("data", out data)) continue;
                string which = Convert.ToString(slot); if (which != "Before" && which != "After") continue;
                var snapshot = SetupBackupCodec.LegacyBenchmark(data as IDictionary<string, object>); if (snapshot == null) continue;
                object time; DateTime captured; if (snapshot.CapturedAt == default(DateTime) && entry.TryGetValue("time", out time) && DateTime.TryParse(Convert.ToString(time), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out captured)) snapshot.CapturedAt = captured;
                result.Add(new BenchmarkRun { Id = Guid.NewGuid().ToString("N"), Slot = which, Data = snapshot }); if (result.Count >= 60) break;
            }
            foreach (string slot in new[] { "Before", "After" }) if (!result.Any(x => x.Slot == slot)) {
                object value; if (!document.TryGetValue(slot, out value)) continue;
                var snapshot = SetupBackupCodec.LegacyBenchmark(value as IDictionary<string, object>); if (snapshot != null) result.Add(new BenchmarkRun { Id = Guid.NewGuid().ToString("N"), Slot = slot, Data = snapshot });
            }
            return result.Take(60).ToList();
        }
        internal static double CountMedian(IEnumerable<BenchmarkRun> runs, string slot, bool services)
        { return Median(runs.Where(x => x != null && x.Data != null && x.Slot == slot).Take(3).Select(x => services ? (double)x.Data.ServicesRunning : x.Data.ProcessCount)); }
        internal static string Csv(IEnumerable<BenchmarkRun> runs)
        {
            var text = new StringBuilder("slot,captured_at,ping_ms,jitter_ms,dns_ms,cpu_use_percent,ram_used_percent,free_ram_mb,processes,services,boot_seconds\r\n");
            foreach (var run in runs.Take(60)) {
                var s = run.Data; text.Append(run.Slot).Append(',').Append(s.CapturedAt.ToString("o", CultureInfo.InvariantCulture));
                foreach (double value in new[] { s.PingMs, s.JitterMs, s.DnsMs, s.CpuUse, s.RamUsedPercent, s.FreeMemoryMb, (double)s.ProcessCount, s.ServicesRunning, s.BootSeconds }) text.Append(',').Append(value >= 0 && !Double.IsNaN(value) && !Double.IsInfinity(value) ? value.ToString("0.###", CultureInfo.InvariantCulture) : "");
                text.Append("\r\n");
            }
            return text.ToString();
        }
    }
    internal sealed partial class MainWindow
    {
        private bool _benchmarkBusy;
        private StackPanel _benchmarkHistoryBody;
        private void ImportLegacyBenchmarks()
        {
            if (_state.LegacyBenchmarksImported) return;
            try {
                string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SharkOptimizer", "bench.json"), json = null;
                if (_state.LegacyBackupFiles.ContainsKey("bench.json")) json = _state.LegacyBackupFiles["bench.json"];
                else if (File.Exists(path)) { if (new FileInfo(path).Length > 2 * 1024 * 1024) throw new InvalidDataException("The previous benchmark file exceeds 2 MB."); json = File.ReadAllText(path); }
                if (json != null && _state.BenchmarkRuns.Count == 0) _state.BenchmarkRuns = BenchmarkHistory.Legacy(json);
                foreach (string slot in new[] { "Before", "After" }) {
                    var snapshot = slot == "Before" ? _state.BenchBefore : _state.BenchAfter;
                    if (snapshot != null && !_state.BenchmarkRuns.Any(x => x.Slot == slot)) _state.BenchmarkRuns.Add(new BenchmarkRun { Id = Guid.NewGuid().ToString("N"), Slot = slot, Data = snapshot });
                }
                _state.BenchmarkRuns = _state.BenchmarkRuns.Take(60).ToList(); _state.LegacyBenchmarksImported = true; _legacyStateMigrated = true;
            } catch (Exception ex) { _benchmarkImportNotice = "Previous benchmark history could not be imported: " + ex.Message; }
        }
        private string _benchmarkImportNotice;
        private UIElement BuildBenchmarkHistoryCard()
        {
            var card = Card(); var body = new StackPanel(); body.Children.Add(Text("Benchmark history", 15, Brushes.White, true));
            body.Children.Add(Text("Keep up to 60 runs. Compare uses the median of the latest three BEFORE and AFTER samples, ignoring unavailable measurements.", 11, Brush(MutedColor), false, 0, 5));
            if (_benchmarkImportNotice != null) body.Children.Add(Text(_benchmarkImportNotice, 10, Brush(MutedColor), false, 0, 8));
            var export = ActionButton("Export history CSV", false); export.HorizontalAlignment = HorizontalAlignment.Left; export.Margin = new Thickness(0, 10, 0, 6);
            export.Click += delegate { var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "CSV (*.csv)|*.csv", FileName = "SharkOptimizer-Benchmarks.csv" }; if (LocalizedFileDialog.Show(dialog, this) == true) try { File.WriteAllText(dialog.FileName, BenchmarkHistory.Csv(_state.BenchmarkRuns), new UTF8Encoding(false)); _labStatus.Text = "Benchmark history exported."; } catch (Exception ex) { _labStatus.Text = "Export failed: " + ex.Message; } }; body.Children.Add(export);
            _benchmarkHistoryBody = new StackPanel(); body.Children.Add(_benchmarkHistoryBody); RenderBenchmarkHistory(); card.Child = body; return card;
        }
        private void RenderBenchmarkHistory()
        {
            if (_benchmarkHistoryBody == null) return; _benchmarkHistoryBody.Children.Clear();
            if (_state.BenchmarkRuns.Count == 0) { _benchmarkHistoryBody.Children.Add(Text("No recorded samples yet.", 10, Brush(MutedColor), false)); return; }
            foreach (var run in _state.BenchmarkRuns.Take(60)) {
                var details = new Expander { Header = run.Slot.ToUpperInvariant() + " · " + run.Data.CapturedAt.ToString("g") + " · ping " + Metric(run.Data.PingMs, " ms"), Margin = new Thickness(0, 5, 0, 5) };
                details.Content = Text("Jitter " + Metric(run.Data.JitterMs, " ms") + " · DNS " + Metric(run.Data.DnsMs, " ms") + " · CPU use " + Metric(run.Data.CpuUse, "%") + " · RAM used " + Metric(run.Data.RamUsedPercent, "%") + "\nProcesses " + Metric(run.Data.ProcessCount, "") + " · Services " + Metric(run.Data.ServicesRunning, "") + " · Last boot " + Metric(run.Data.BootSeconds, " s"), 10, Brush(MutedColor), false, 0, 8);
                _benchmarkHistoryBody.Children.Add(details);
            }
            Localization.Apply(_benchmarkHistoryBody);
        }
    }
}
