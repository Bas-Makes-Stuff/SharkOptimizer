using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace SharkOptimizer.NativeApp
{
    internal sealed class CleanupRun
    {
        public DateTime TimeUtc { get; set; }
        public string Name { get; set; }
        public string Result { get; set; }
        public bool Success { get; set; }
        public double DurationSeconds { get; set; }
    }

    internal sealed partial class MainWindow
    {
        private StackPanel _cleanupHistoryBody;
        private string _cleanupHistoryNotice;

        private void ImportLegacyCleanupHistory()
        {
            if (_state.LegacyCleanupHistoryImported) return;
            try
            {
                string json;
                if (!_state.LegacyBackupFiles.TryGetValue("boost-history.json", out json))
                {
                    string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SharkOptimizer", "boost-history.json");
                    if (File.Exists(path)) { if (new FileInfo(path).Length > 2 * 1024 * 1024) throw new InvalidDataException("Previous cleanup history exceeds 2 MB."); json = File.ReadAllText(path); }
                }
                if (json != null)
                {
                    object decoded = _json.DeserializeObject(json);
                    object[] rows = decoded as object[];
                    if (rows == null && decoded is IDictionary<string, object>) rows = new[] { decoded };
                    if (rows == null || rows.Length > 50) throw new InvalidDataException("Cleanup history must contain no more than 50 entries.");
                    var imported = new List<CleanupRun>();
                    foreach (object row in rows)
                    {
                        var data = row as IDictionary<string, object>; if (data == null) throw new InvalidDataException("Invalid cleanup history entry.");
                        Func<string, object> get = name => data.Where(x => String.Equals(x.Key, name, StringComparison.OrdinalIgnoreCase)).Select(x => x.Value).FirstOrDefault();
                        DateTime time;
                        if (!DateTime.TryParse(Convert.ToString(get("time")), CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal | DateTimeStyles.AdjustToUniversal, out time)) throw new InvalidDataException("Invalid cleanup history entry.");
                        double duration = 0; object oldDuration = get("durationSeconds"); if (oldDuration != null) duration = Convert.ToDouble(oldDuration, CultureInfo.InvariantCulture);
                        var entry = new CleanupRun { TimeUtc = time, Name = Convert.ToString(get("name")), Result = Convert.ToString(get("result")), Success = get("ok") is bool && (bool)get("ok"), DurationSeconds = duration };
                        ValidateCleanupRun(entry); imported.Add(entry);
                    }
                    _state.CleanupHistory = _state.CleanupHistory.Concat(imported).OrderByDescending(x => x.TimeUtc).Take(50).ToList();
                    _state.LegacyBackupFiles["boost-history.json"] = json;
                }
                _state.LegacyCleanupHistoryImported = true; _legacyStateMigrated = true;
            }
            catch (Exception ex) { _cleanupHistoryNotice = "Previous cleanup history could not be imported: " + ex.Message; }
        }

        internal static void ValidateCleanupRun(CleanupRun run)
        {
            if (run == null || run.TimeUtc == DateTime.MinValue || String.IsNullOrWhiteSpace(run.Name) || run.Name.Length > 160 || run.Result == null || run.Result.Length > 32768 || Double.IsNaN(run.DurationSeconds) || Double.IsInfinity(run.DurationSeconds) || run.DurationSeconds < 0 || run.DurationSeconds > 31622400) throw new InvalidDataException("Invalid cleanup history entry.");
        }

        private void RecordCleanupRun(string name, string result, bool success, DateTime started)
        {
            var previous = _state.CleanupHistory;
            try
            {
                var entry = new CleanupRun { TimeUtc = DateTime.UtcNow, Name = name, Result = result.Length > 32768 ? result.Substring(0, 32768) : result, Success = success, DurationSeconds = Math.Max(0, (DateTime.UtcNow - started).TotalSeconds) };
                _state.CleanupHistory = new[] { entry }.Concat(previous).Take(50).ToList();
                SaveState();
            }
            catch (Exception ex) { _state.CleanupHistory = previous; MessageBox.Show(this, "The action finished, but its history could not be saved: " + ex.Message, "Boost-Up", MessageBoxButton.OK, MessageBoxImage.Warning); }
            RefreshCleanupHistory();
        }

        private UIElement BuildCleanupHistory()
        {
            _cleanupHistoryBody = new StackPanel();
            RefreshCleanupHistory();
            return new Expander { Header = "Boost-Up history", Content = _cleanupHistoryBody, Foreground = Brush(MutedColor), Margin = new Thickness(0, 12, 0, 8) };
        }

        private void RefreshCleanupHistory()
        {
            if (_cleanupHistoryBody == null) return;
            _cleanupHistoryBody.Children.Clear();
            if (_cleanupHistoryNotice != null) _cleanupHistoryBody.Children.Add(Text(_cleanupHistoryNotice, 10, Brush(MutedColor), false, 0, 8));
            if (_state.CleanupHistory.Count == 0) _cleanupHistoryBody.Children.Add(Text("No Boost-Ups have been run yet.", 11, Brush(MutedColor), false, 0, 8));
            foreach (CleanupRun run in _state.CleanupHistory.OrderByDescending(x => x.TimeUtc).Take(50))
            {
                var card = Card(); var body = new StackPanel();
                var time = Text(run.TimeUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss"), 9, Brush(MutedColor), false); Localization.KeepData(time); body.Children.Add(time);
                body.Children.Add(Text(run.Name, 12, run.Success ? Brushes.White : Brush(Color.FromRgb(255, 190, 96)), true, 0, 3));
                body.Children.Add(Text(run.Result, 10.5, Brush(MutedColor), false, 0, 4)); card.Child = body; _cleanupHistoryBody.Children.Add(card);
            }
            if (_state.CleanupHistory.Count > 0)
            {
                var clear = ActionButton("Clear history", false); clear.HorizontalAlignment = HorizontalAlignment.Left;
                clear.Click += delegate {
                    if (MessageBox.Show(this, "Remove saved run records from this PC?", "Clear Boost-Up history", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
                    var previous = _state.CleanupHistory;
                    bool previousImported = _state.LegacyCleanupHistoryImported;
                    try { _state.CleanupHistory = new List<CleanupRun>(); _state.LegacyCleanupHistoryImported = true; SaveState(); RefreshCleanupHistory(); }
                    catch (Exception ex) { _state.CleanupHistory = previous; _state.LegacyCleanupHistoryImported = previousImported; MessageBox.Show(this, ex.Message, "Boost-Up", MessageBoxButton.OK, MessageBoxImage.Warning); }
                };
                _cleanupHistoryBody.Children.Add(clear);
            }
            Localization.Apply(_cleanupHistoryBody);
        }
    }
}
