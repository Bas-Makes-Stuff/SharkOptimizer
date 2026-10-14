using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace SharkOptimizer.NativeApp
{
    internal sealed class GameSessionReport
    {
        public string Id { get; set; }
        public string Game { get; set; }
        public string Mode { get; set; }
        public DateTime StartedUtc { get; set; }
        public DateTime EndedUtc { get; set; }
        public bool Interrupted { get; set; }
        public bool RecoveryPending { get; set; }
        public bool ImportedFromLegacy { get; set; }
        public List<string> Checklist { get; set; }
        public GameSessionReport() { Checklist = new List<string>(); }
    }

    internal static class GameSessionHistoryCodec
    {
        private static object Member(IDictionary<string, object> row, string key)
        { return row.FirstOrDefault(x => String.Equals(x.Key, key, StringComparison.OrdinalIgnoreCase)).Value; }

        internal static List<GameSessionReport> ReadLegacy(string json)
        {
            if (System.Text.Encoding.UTF8.GetByteCount(json) > 2 * 1024 * 1024) throw new InvalidDataException("Previous session history exceeds 2 MB.");
            var serializer = new JavaScriptSerializer { MaxJsonLength = 2 * 1024 * 1024 };
            object parsed = serializer.DeserializeObject(json); var rows = parsed as object[];
            if (rows == null) { var single = parsed as IDictionary<string, object>; if (single != null) rows = new object[] { single }; }
            if (rows == null || rows.Length > 50) throw new InvalidDataException("Previous session history must contain up to 50 reports.");
            var reports = new List<GameSessionReport>();
            foreach (object entry in rows) {
                var row = entry as IDictionary<string, object>; if (row == null) throw new InvalidDataException("A previous session report is invalid.");
                string game = Convert.ToString(Member(row, "game")), startText = Convert.ToString(Member(row, "started")), endText = Convert.ToString(Member(row, "ended"));
                DateTime start, end;
                if (String.IsNullOrWhiteSpace(game) || game.Length > 120 || !DateTime.TryParse(startText, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal | DateTimeStyles.AdjustToUniversal, out start)) throw new InvalidDataException("A previous session report is invalid.");
                if (!DateTime.TryParse(endText, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal | DateTimeStyles.AdjustToUniversal, out end)) {
                    double seconds = Convert.ToDouble(Member(row, "durationSeconds"), CultureInfo.InvariantCulture);
                    if (Double.IsNaN(seconds) || Double.IsInfinity(seconds) || seconds < 0 || seconds > 366 * 86400) throw new InvalidDataException("A previous session duration is invalid.");
                    end = start.AddSeconds(seconds);
                }
                if (end < start) throw new InvalidDataException("A previous session duration is invalid.");
                var checklist = Member(row, "checklist") as object[];
                if (checklist == null || checklist.Length > 300 || checklist.Any(x => !(x is string) || ((string)x).Length > 8192)) throw new InvalidDataException("A previous session checklist is invalid.");
                string mode = Convert.ToString(Member(row, "mode")); if (mode.Length > 120) throw new InvalidDataException("A previous session report is invalid.");
                string identity = game + "\n" + startText + "\n" + endText + "\n" + mode + "\n" + String.Join("\n", checklist.Cast<string>().ToArray());
                string id; using (var hash = System.Security.Cryptography.SHA256.Create()) id = "legacy-" + String.Concat(hash.ComputeHash(System.Text.Encoding.UTF8.GetBytes(identity)).Select(x => x.ToString("x2", CultureInfo.InvariantCulture)).ToArray());
                reports.Add(new GameSessionReport { Id = id, Game = game, Mode = mode, StartedUtc = start, EndedUtc = end, ImportedFromLegacy = true, Checklist = checklist.Cast<string>().ToList() });
            }
            return reports.GroupBy(x => x.Id).Select(x => x.First()).OrderByDescending(x => x.StartedUtc).Take(50).ToList();
        }
    }

    internal sealed partial class MainWindow
    {
        private void ImportLegacySessionHistory()
        {
            if (_state.LegacySessionHistoryImported) return;
            try {
                const string file = "game-session-history.json"; string json;
                if (!_state.LegacyBackupFiles.TryGetValue(file, out json)) {
                    string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SharkOptimizer", file);
                    if (File.Exists(path)) { if (new FileInfo(path).Length > 2 * 1024 * 1024) throw new InvalidDataException("Previous session history exceeds 2 MB."); json = File.ReadAllText(path); }
                }
                if (json != null) {
                    var reports = GameSessionHistoryCodec.ReadLegacy(json);
                    _state.SessionHistory = _state.SessionHistory.Concat(reports).GroupBy(x => x.Id).Select(x => x.First()).OrderByDescending(x => x.StartedUtc).Take(50).ToList();
                    _state.LegacyBackupFiles[file] = json;
                }
                _state.LegacySessionHistoryImported = true; _legacyStateMigrated = true;
            } catch (Exception ex) { _sessionSettingsNotice = "Previous session history could not be imported: " + ex.Message; }
        }
        private CheckBox _sessionPauseUpdate, _sessionTrimMemory;
        private StackPanel _sessionReportsBody;
        private bool _sessionStarting, _sessionExitAfterStart;
        private bool _sessionExitReady;
        private bool _sessionExitInProgress;
        private Task _sessionEndingTask;
        private Func<bool> _sessionUpdateRunning = UpdateServiceRunning;
        private Action _sessionStopUpdate = StopUpdateService;
        private Action _sessionResumeUpdate = ResumeUpdateService;
        [DllImport("psapi.dll", SetLastError = true)] private static extern bool EmptyWorkingSet(IntPtr process);
        private bool SessionRecoveryPending { get { return _state.SessionUpdateResume || _state.SessionPriorities.Count > 0 || !String.IsNullOrEmpty(_state.SessionPreviousPlan); } }

        private static bool UpdateServiceRunning()
        { using (var service = new ServiceController("wuauserv")) { service.Refresh(); return service.Status == ServiceControllerStatus.Running; } }
        private static void StopUpdateService()
        {
            using (var service = new ServiceController("wuauserv")) {
                service.Refresh(); if (service.Status == ServiceControllerStatus.Stopped) return;
                if (service.Status != ServiceControllerStatus.StopPending) service.Stop();
                service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(8));
            }
        }
        private static void ResumeUpdateService()
        {
            using (var service = new ServiceController("wuauserv")) {
                service.Refresh(); if (service.Status == ServiceControllerStatus.Running) return;
                if (service.Status == ServiceControllerStatus.StopPending) service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(8));
                service.Refresh(); if (service.Status != ServiceControllerStatus.StartPending) service.Start();
                service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(8));
            }
        }

        private async Task PauseSessionUpdates()
        {
            try {
                bool wasRunning = await Task.Run(_sessionUpdateRunning);
                if (!wasRunning) { _sessionActionNotes.Add("Windows Update service was not running; left unchanged."); return; }
                _state.SessionUpdateResume = true;
                try { SaveState(); } catch { _state.SessionUpdateResume = false; throw new IOException("Could not save Windows Update recovery; the service was left unchanged."); }
                await Task.Run(_sessionStopUpdate);
                _sessionActionNotes.Add("Stopped Windows Update service temporarily.");
            } catch (Exception ex) { _sessionActionNotes.Add("Could not pause Windows Update service: " + ex.Message); }
        }

        private async Task RestoreSessionUpdates()
        {
            if (!_state.SessionUpdateResume) return;
            try { await Task.Run(_sessionResumeUpdate); _state.SessionUpdateResume = false; SaveState(); _sessionActionNotes.Add("Resumed Windows Update service."); }
            catch (Exception ex) { _state.SessionUpdateResume = true; _sessionActionNotes.Add("Could not resume Windows Update service: " + ex.Message); }
        }

        private string TrimSessionMemory()
        {
            int trimmed = 0, skipped = 0;
            foreach (Process process in Process.GetProcesses()) {
                try {
                    if (IsKeptSessionProcess(process.ProcessName) || process.Id == Process.GetCurrentProcess().Id) { skipped++; continue; }
                    if (EmptyWorkingSet(process.Handle)) trimmed++; else skipped++;
                } catch { skipped++; } finally { process.Dispose(); }
            }
            return "Trimmed working sets: " + trimmed + " apps; skipped: " + skipped + ". Windows can reload memory as needed.";
        }

        private void AddSessionExtras(StackPanel body)
        {
            var advanced = new Expander { Header = "Optional session actions", Margin = new Thickness(0, 10, 0, 0) }; var options = new StackPanel();
            _sessionPauseUpdate = new CheckBox { Content = "Pause Windows Update service for this session", Margin = new Thickness(0, 10, 0, 4), Foreground = Brush(MutedColor) }; options.Children.Add(_sessionPauseUpdate);
            options.Children.Add(Text("Stops the service only if it is running, then restarts it when the session ends. This does not change update policy or cancel an update already installing.", 10, Brush(MutedColor), false, 0, 3));
            _sessionTrimMemory = new CheckBox { Content = "Trim background app working sets once", Margin = new Thickness(0, 12, 0, 4), Foreground = Brush(MutedColor) }; options.Children.Add(_sessionTrimMemory);
            options.Children.Add(Text("Windows may reload trimmed memory, which can briefly slow background apps. Games and protected apps are skipped; this is optional and does not increase installed RAM.", 10, Brush(MutedColor), false, 0, 3));
            advanced.Content = options; body.Children.Add(advanced);
        }

        private void BeginSessionReport(string game)
        {
            _state.ActiveSessionReport = new GameSessionReport { Id = Guid.NewGuid().ToString("N"), Game = game, Mode = SessionLowersPriority ? "LowerPriority" : "AskToClose", StartedUtc = DateTime.UtcNow };
            try { SaveState(); } catch { _state.ActiveSessionReport = null; throw; }
        }

        private void CheckpointSessionReport()
        { if (_state.ActiveSessionReport != null) { _state.ActiveSessionReport.Checklist = new List<string>(_sessionActionNotes); SaveState(); } }

        private void FinishSessionReport(bool interrupted)
        {
            var report = _state.ActiveSessionReport; if (report == null) return;
            report.Interrupted |= interrupted; report.RecoveryPending = SessionRecoveryPending; report.EndedUtc = DateTime.UtcNow;
            report.Checklist = (report.Checklist ?? new List<string>()).Concat(_sessionActionNotes).Distinct().Take(300).ToList();
            _state.SessionHistory.RemoveAll(x => x.Id == report.Id); _state.SessionHistory.Insert(0, report); _state.SessionHistory = _state.SessionHistory.Take(50).ToList();
            if (!report.RecoveryPending) _state.ActiveSessionReport = null;
            try { SaveState(); } catch (Exception ex) { _sessionActionNotes.Add("Could not save session report: " + ex.Message); }
            RenderSessionReports();
            LogActivity("Game Boost ended · " + report.Game + (report.RecoveryPending ? " · restoration pending" : " · temporary settings restored"), report.RecoveryPending, false);
            if (!_previewMode && _state.Toasts && !IsVisible && _trayIcon != null && !_sessionExitInProgress) {
                _sessionRecapReady = true;
                string recap = report.Game + " · " + Math.Max(0, (report.EndedUtc - report.StartedUtc).TotalMinutes).ToString("0", CultureInfo.CurrentCulture) + " " + Localization.Translate("min") + "\n" + Localization.Translate(report.RecoveryPending ? "Restoration pending" : "Temporary settings restored") + "\n" + Localization.Translate("Click to view your session recap.");
                _trayIcon.ShowBalloonTip(6000, "SharkOptimizer", recap, report.RecoveryPending ? System.Windows.Forms.ToolTipIcon.Warning : System.Windows.Forms.ToolTipIcon.Info);
            }
        }

        private UIElement BuildSessionReports()
        {
            var card = Card(); var body = new StackPanel(); body.Children.Add(Text("Recent sessions", 15, Brushes.White, true));
            body.Children.Add(Text("Review what ran and whether temporary settings were restored. The latest 50 sessions are kept.", 10, Brush(MutedColor), false, 0, 5));
            _sessionReportsBody = new StackPanel { Margin = new Thickness(0, 12, 0, 0) }; body.Children.Add(_sessionReportsBody); RenderSessionReports(); card.Child = body; return card;
        }

        private void RenderSessionReports()
        {
            if (_sessionReportsBody == null) return; _sessionReportsBody.Children.Clear();
            if (_state.SessionHistory.Count == 0) { _sessionReportsBody.Children.Add(Text("No sessions recorded yet.", 10, Brush(MutedColor), false)); return; }
            foreach (var report in _state.SessionHistory.Take(50)) {
                double minutes = Math.Max(0, (report.EndedUtc - report.StartedUtc).TotalMinutes);
                var details = new Expander { Header = report.Game + " · " + minutes.ToString("0", CultureInfo.CurrentCulture) + " min · " + (report.RecoveryPending ? "restoration pending" : "ended") + " · " + report.StartedUtc.ToLocalTime().ToString("g"), Margin = new Thickness(0, 0, 0, 8) };
                var notes = new StackPanel(); if (report.Interrupted) notes.Children.Add(Text("Recovered after an interrupted session.", 10, Brush(MutedColor), false, 0, 8));
                if (report.ImportedFromLegacy) notes.Children.Add(Text("Previous-app report. Its timestamps use this PC's local time zone; this report does not start recovery actions.", 10, Brush(MutedColor), false, 0, 8));
                foreach (string note in report.Checklist ?? new List<string>()) notes.Children.Add(Text(note, 10, Brush(MutedColor), false, 0, 5)); details.Content = notes; _sessionReportsBody.Children.Add(details);
            }
            Localization.Apply(_sessionReportsBody);
        }
    }
}
