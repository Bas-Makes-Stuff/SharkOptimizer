using System;
using System.Collections.Generic;
using System.IO;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private int _cleanupQueryVersion;
        internal static string CleanupDayCode(string value)
        {
            string[] names = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
            string[] codes = { "MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN" };
            for (int i = 0; i < names.Length; i++) if (String.Equals(value, names[i], StringComparison.OrdinalIgnoreCase) || String.Equals(value, codes[i], StringComparison.OrdinalIgnoreCase)) return codes[i];
            return null;
        }

        internal static string CleanupDayName(string code)
        {
            string[] names = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
            string[] codes = { "MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN" };
            int index = Array.IndexOf(codes, code); return index < 0 ? null : names[index];
        }

        private void ImportLegacyCleanupPreferences()
        {
            if (_state.LegacyCleanupPreferencesImported) return;
            if (File.Exists(_dataPath)) { _state.LegacyCleanupPreferencesImported = true; _legacyStateMigrated = true; return; }
            try {
                string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SharkOptimizer", "settings.json"), json = null;
                if (_state.LegacyBackupFiles.ContainsKey("settings.json")) json = _state.LegacyBackupFiles["settings.json"];
                else if (File.Exists(path) && new FileInfo(path).Length <= 1024 * 1024) json = File.ReadAllText(path);
                if (json != null) {
                    var values = _json.DeserializeObject(json) as IDictionary<string, object>;
                    if (values == null) throw new InvalidDataException("Previous preferences must be an object.");
                    object value; if (values.TryGetValue("CleanDay", out value)) { string day = CleanupDayCode(Convert.ToString(value)); if (day != null) _state.CleanupDay = day; }
                    DateTime time; if (values.TryGetValue("CleanTime", out value) && DateTime.TryParseExact(Convert.ToString(value), new[] { "H:mm", "HH:mm" }, CultureInfo.InvariantCulture, DateTimeStyles.None, out time)) _state.CleanupTime = time.ToString("HH:mm", CultureInfo.InvariantCulture);
                }
                _state.LegacyCleanupPreferencesImported = true; _legacyStateMigrated = true;
            } catch (Exception ex) { LogActivity("Previous cleanup preferences could not be imported: " + ex.Message, true, false); }
        }

        private sealed class MaintenanceJob
        {
            internal string Title, Note;
            internal Func<string> Run;
            internal Border Card;
            internal CheckBox Check;
        }
        private readonly List<MaintenanceJob> _maintenanceJobs = new List<MaintenanceJob>();
        private UIElement BuildMaintenanceTools()
        {
            _maintenanceJobs.Clear();
            var tools = new StackPanel();
            AddMaintenanceAction(tools, "Optimize Drives", "Windows chooses TRIM for SSDs and defragmentation for hard disks. This can take several minutes.", delegate {
                string drive = Path.GetPathRoot(Environment.SystemDirectory).TrimEnd(Path.DirectorySeparatorChar);
                int exit; string output = RunCapturedSystemTool("defrag.exe", drive + " /O", 1800000, out exit);
                if (exit != 0) throw new InvalidOperationException(output);
                return "Drive optimization completed.";
            });
            AddMaintenanceAction(tools, "Clean Thumbnail Cache", "Close File Explorer first. Windows rebuilds thumbnail previews when needed.", delegate {
                return RemoveMaintenanceFiles(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "Windows", "Explorer"), "thumbcache_", 0);
            });
            AddMaintenanceAction(tools, "Clean Font Cache", "Temporarily stops the font cache service and restores it after cleaning. Locked files are skipped.", delegate {
                return WithMaintenanceServices(new[] { "FontCache" }, () => RemoveMaintenanceFiles(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "ServiceProfiles", "LocalService", "AppData", "Local", "FontCache"), null, 0));
            });
            AddMaintenanceAction(tools, "Clean Windows Update Downloads", "Pauses Windows Update and BITS while clearing downloads older than seven days. Missing files may be downloaded again. Skip this while Windows is installing updates.", delegate {
                return WithMaintenanceServices(new[] { "wuauserv", "BITS" }, () => RemoveMaintenanceFiles(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "SoftwareDistribution", "Download"), null, 7));
            });
            AddMaintenanceAction(tools, "Trim Process RAM", "Windows may reload trimmed memory, which can briefly slow background apps. Games and protected apps are skipped; this is optional and does not increase installed RAM.", TrimSessionMemory);
            AddMaintenanceAction(tools, "Flush DNS Cache", "Clears stale DNS entries.", delegate {
                int exit; string output = RunCapturedSystemTool("ipconfig.exe", "/flushdns", 10000, out exit);
                if (exit != 0) throw new InvalidOperationException(output);
                return "DNS cache flushed.";
            });
            return new Expander { Header = "Maintenance tools", Content = tools, Foreground = Brush(MutedColor), Margin = new Thickness(0, 14, 0, 8) };
        }

        private void AddMaintenanceAction(StackPanel parent, string title, string note, Func<string> run)
        {
            var card = Card(); var body = new StackPanel();
            var check = new CheckBox { Content = title, Foreground = Brushes.White, FontSize = 13, FontWeight = FontWeights.SemiBold };
            body.Children.Add(check);
            _maintenanceJobs.Add(new MaintenanceJob { Title = title, Note = note, Run = run, Card = card, Check = check });
            body.Children.Add(Text(note, 10.5, Brush(MutedColor), false, 0, 5));
            var button = ActionButton("Run", false); button.HorizontalAlignment = HorizontalAlignment.Left; button.Margin = new Thickness(-4, 8, 0, 0);
            button.Click += async delegate {
                if (_tweakOperationBusy) return;
                string review = Localization.Translate(title) + Environment.NewLine + Environment.NewLine + Localization.Translate(note) + Environment.NewLine + Environment.NewLine + Localization.Translate("Continue?");
                if (System.Windows.MessageBox.Show(this, review, Localization.Translate("Review changes"), MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
                if (!BeginTweakOperation("Maintenance is running…")) return;
                DateTime started = DateTime.UtcNow;
                try {
                    string result = await Task.Run(run);
                    if (_cleanupStatus != null) _cleanupStatus.Text = result;
                    LogActivity(result);
                    RecordCleanupRun(title, result, true, started);
                } catch (Exception ex) {
                    if (_cleanupStatus != null) _cleanupStatus.Text = "Maintenance failed: " + ex.Message;
                    MessageBox.Show(this, "Maintenance failed: " + ex.Message, "Boost-Up", MessageBoxButton.OK, MessageBoxImage.Warning);
                    LogActivity("Maintenance failed: " + ex.Message, true);
                    RecordCleanupRun(title, ex.Message, false, started);
                } finally { EndTweakOperation(); }
            };
            body.Children.Add(button); card.Child = body; parent.Children.Add(card);
        }

        private async Task RunSelectedMaintenanceJobs(List<MaintenanceJob> jobs)
        {
            for (int index = 0; index < jobs.Count; index++)
            {
                MaintenanceJob job = jobs[index]; DateTime started = DateTime.UtcNow;
                _pageSubtitle.Text = String.Format("Running {0} of {1}: {2}", index + 1, jobs.Count, Localization.Translate(job.Title));
                try {
                    string result = await Task.Run(job.Run); _cleanupStatus.Text = result;
                    RecordCleanupRun(job.Title, result, true, started); LogActivity(result);
                } catch (Exception ex) {
                    _cleanupStatus.Text = "Maintenance failed: " + ex.Message;
                    RecordCleanupRun(job.Title, ex.Message, false, started); LogActivity("Maintenance failed: " + ex.Message, true);
                }
                if (_state.MaintenanceServices.Count > 0) { MessageBox.Show(this, "Maintenance services need recovery", "Restore", MessageBoxButton.OK, MessageBoxImage.Warning); break; }
            }
        }

        private static string RemoveMaintenanceFiles(string folder, string prefix, int minimumAgeDays)
        {
            int removed = 0; long freed = 0;
            WalkFilesSafe(folder, delegate(string file) {
                try {
                    var info = new FileInfo(file);
                    if (prefix != null && (!info.Name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) || !info.Name.EndsWith(".db", StringComparison.OrdinalIgnoreCase))) return;
                    if (minimumAgeDays > 0 && info.LastWriteTimeUtc >= DateTime.UtcNow.AddDays(-minimumAgeDays)) return;
                    long bytes = info.Length; File.Delete(file); removed++; freed += bytes;
                } catch { }
            });
            return "Removed " + removed + " files · " + FormatBytes(freed) + " freed. Some files may have been in use.";
        }

        private string WithMaintenanceServices(string[] names, Func<string> work)
        {
            try
            {
                foreach (string name in names)
                {
                    ServiceChange service = ReadServiceState(name);
                    if (service == null) throw new InvalidOperationException("Windows service is unavailable: " + name);
                    if (!service.WasRunning) continue;
                    OnStateThread(delegate { if (!_state.MaintenanceServices.Contains(name)) _state.MaintenanceServices.Add(name); SaveState(); });
                    SetServiceRunning(name, false);
                }
                return work();
            }
            finally { ResumeMaintenanceServices(); }
        }

        private void ResumeMaintenanceServices()
        {
            string[] pending = null;
            OnStateThread(delegate { pending = _state.MaintenanceServices.ToArray(); });
            var errors = new List<string>();
            foreach (string name in pending)
            {
                try
                {
                    if (name != "FontCache" && name != "wuauserv" && name != "BITS") throw new InvalidDataException("Invalid maintenance recovery service.");
                    SetServiceRunning(name, true);
                    OnStateThread(delegate {
                        _state.MaintenanceServices.Remove(name);
                        try { SaveState(); } catch { _state.MaintenanceServices.Add(name); throw; }
                    });
                }
                catch (Exception ex) { errors.Add(name + ": " + ex.Message); }
            }
            if (errors.Count > 0) throw new InvalidOperationException("Maintenance service recovery is incomplete:" + Environment.NewLine + String.Join(Environment.NewLine, errors.ToArray()));
        }

        private Task _maintenanceRecoveryTask;
        private Task RecoverMaintenanceServices()
        {
            if (_maintenanceRecoveryTask != null && !_maintenanceRecoveryTask.IsCompleted) return _maintenanceRecoveryTask;
            return _maintenanceRecoveryTask = RecoverMaintenanceServicesCore();
        }

        private async Task RecoverMaintenanceServicesCore()
        {
            if (_state.MaintenanceServices.Count == 0) return;
            try { await Task.Run(() => ResumeMaintenanceServices()); }
            catch (Exception ex) { LogActivity("Maintenance failed: " + ex.Message, true); }
        }

        private UIElement MaintenanceRecoveryCard()
        {
            var card = Card(); var body = new StackPanel();
            body.Children.Add(Text("Maintenance services need recovery", 13, Brushes.White, true));
            body.Children.Add(Text("Retry restarting services that were running before maintenance. Other optimizations are blocked until recovery succeeds.", 11, Brush(MutedColor), false, 0, 5));
            var retry = ActionButton("Retry recovery", true);
            retry.Click += async delegate {
                if (!BeginTweakOperation("Restoring changes…", true)) return;
                try { await RecoverMaintenanceServices(); } finally { EndTweakOperation(); }
            };
            body.Children.Add(retry); card.Child = body; return card;
        }
    }
}
