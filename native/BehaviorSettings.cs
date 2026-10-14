using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private readonly List<string> _activityLines = new List<string>();
        private readonly object _activityFileLock = new object();
        private Expander _activityPanel;
        private TextBox _activityText;
        private bool _gameScanBusy;

        internal static bool PreferReducedMotion()
        {
            var data = ReadStartupPreferences();
            return data != null && data.ReduceMotion;
        }
        internal static string SavedLanguagePreference()
        {
            var data = ReadStartupPreferences();
            if (data != null && Localization.Languages.ContainsKey(data.Language ?? "")) return data.Language;
            string legacy = null;
            string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SharkOptimizer", "settings.json");
            foreach (string candidate in new[] { path, path + ".bak" }) {
                try {
                    if (!File.Exists(candidate) || new FileInfo(candidate).Length > 1024 * 1024) continue;
                    var values = new JavaScriptSerializer { MaxJsonLength = 1024 * 1024 }.DeserializeObject(File.ReadAllText(candidate)) as IDictionary<string, object>;
                    object value; if (values != null && values.TryGetValue("Language", out value) && value is string && Localization.Languages.ContainsKey((string)value)) { legacy = (string)value; break; }
                } catch { }
            }
            return Localization.ResolveStartupLanguage(null, legacy, System.Globalization.CultureInfo.CurrentUICulture.Name);
        }

        private static AppState ReadStartupPreferences()
        {
            string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SharkOptimizer", "native-state.json");
            foreach (string candidate in new[] { path, path + ".bak" })
            {
                try {
                    if (!File.Exists(candidate) || new FileInfo(candidate).Length > 16 * 1024 * 1024) continue;
                    var parser = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024, RecursionLimit = 64 };
                    var data = parser.Deserialize<AppState>(File.ReadAllText(candidate));
                    if (data != null && data.Applied != null && !data.Applied.Any(x => x == null)) return data;
                } catch { }
            }
            return null;
        }

        private void ImportLegacyBehavior()
        {
            if (_state.LegacyBehaviorImported && _state.LegacyRestorePointImported) return;
            try {
                string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SharkOptimizer", "settings.json"), json = null;
                if (_state.LegacyBackupFiles.ContainsKey("settings.json")) json = _state.LegacyBackupFiles["settings.json"];
                else if (File.Exists(path) && new FileInfo(path).Length < 1024 * 1024) json = File.ReadAllText(path);
                if (json != null) { var data = _json.DeserializeObject(json) as IDictionary<string, object>; if (data == null) throw new InvalidDataException("Previous preferences must be an object.");
                    object value;
                    if (!_state.LegacyBehaviorImported) {
                        if (data.TryGetValue("Toasts", out value) && value is bool) _state.Toasts = (bool)value;
                        if (data.TryGetValue("ShowLog", out value) && value is bool) _state.ShowLog = (bool)value;
                        if (data.TryGetValue("ScanOnStart", out value) && value is bool) _state.ScanOnStart = (bool)value;
                    }
                    if (!_state.LegacyRestorePointImported && data.TryGetValue("AlwaysRestorePoint", out value) && value is bool) _state.AlwaysRestorePoint = (bool)value;
                }
                _state.LegacyBehaviorImported = true; _state.LegacyRestorePointImported = true; _legacyStateMigrated = true;
            } catch (Exception ex) { LogActivity("Previous behavior preferences could not be imported: " + ex.Message, true, false); }
        }

        private UIElement BuildBehaviorCard()
        {
            var card = Card(); var body = new StackPanel(); body.Children.Add(Text("App behavior", 15, Brushes.White, true));
            body.Children.Add(Text("Choose how SharkOptimizer behaves while you work and play.", 11, Brush(MutedColor), false, 0, 5));
            AddBehaviorToggle(body, "Show completion notifications while in the tray", delegate { return _state.Toasts; }, delegate(bool value) { _state.Toasts = value; });
            AddBehaviorToggle(body, "Show the activity log", delegate { return _state.ShowLog; }, delegate(bool value) { _state.ShowLog = value; if (_activityPanel != null) _activityPanel.Visibility = value ? Visibility.Visible : Visibility.Collapsed; });
            AddBehaviorToggle(body, "Scan for games when SharkOptimizer starts", delegate { return _state.ScanOnStart; }, delegate(bool value) { _state.ScanOnStart = value; });
            AddBehaviorToggle(body, "Reduce interface motion", delegate { return _state.ReduceMotion; }, delegate(bool value) { _state.ReduceMotion = value; });
            AddBehaviorToggle(body, "Always create a restore point before applying", delegate { return _state.AlwaysRestorePoint; }, delegate(bool value) { _state.AlwaysRestorePoint = value; });
            body.Children.Add(Text("Reduced motion also skips the animated startup screen on your next launch. Startup scans run in the background.", 10, Brush(MutedColor), false, 0, 8));
            var export = ActionButton("Export activity log", false); export.HorizontalAlignment = HorizontalAlignment.Left; export.Margin = new Thickness(0, 10, 0, 0);
            export.Click += delegate { var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "Text file (*.txt)|*.txt", FileName = "SharkOptimizer-Activity.txt" }; if (LocalizedFileDialog.Show(dialog, this) == true) try { File.WriteAllLines(dialog.FileName, _activityLines, new UTF8Encoding(false)); } catch (Exception ex) { MessageBox.Show(this, ex.Message, "Log export", MessageBoxButton.OK, MessageBoxImage.Warning); } }; body.Children.Add(export); card.Child = body; return card;
        }

        private void AddBehaviorToggle(StackPanel body, string text, Func<bool> read, Action<bool> set)
        {
            var check = new CheckBox { Content = text, IsChecked = read(), Foreground = Brush(MutedColor), Margin = new Thickness(0, 11, 0, 0) };
            check.Click += delegate { bool previous = read(); try { set(check.IsChecked == true); SaveState(); } catch (Exception ex) { set(previous); check.IsChecked = previous; MessageBox.Show(this, "Could not save preference: " + ex.Message, "Settings", MessageBoxButton.OK, MessageBoxImage.Warning); } }; body.Children.Add(check);
        }

        private static bool ShouldRequestRestorePoint(IEnumerable<TweakDefinition> selected, bool always)
        {
            return selected.Any(tweak => always || !(String.Equals(tweak.Risk, "Safe", StringComparison.OrdinalIgnoreCase) || String.Equals(tweak.Risk, "Recommended", StringComparison.OrdinalIgnoreCase)));
        }

        private UIElement BuildActivityPanel()
        {
            _activityText = new TextBox { IsReadOnly = true, TextWrapping = TextWrapping.Wrap, MinHeight = 52, MaxHeight = 100, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(8), FontSize = 10, Text = String.Join(Environment.NewLine, _activityLines) };
            _activityPanel = new Expander { Header = "Activity log", Content = _activityText, Margin = new Thickness(28, 0, 28, 10), Visibility = _state.ShowLog ? Visibility.Visible : Visibility.Collapsed }; return _activityPanel;
        }

        private UIElement BuildDataActionsCard()
        {
            var card = Card(); var body = new StackPanel(); body.Children.Add(Text("App data", 15, Brushes.White, true));
            var actions = new WrapPanel { Margin = new Thickness(-5, 10, 0, 0) };
            var clear = ActionButton("Clear saved game scan", false);
            clear.Click += delegate {
                if (_gameScanBusy || _sessionStarting || _tweakOperationBusy) return;
                if (MessageBox.Show(this, "Clear saved game locations? Your custom game profiles are kept. You can scan again later.", "Clear saved game scan", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
                var previous = _state.GamePaths; _state.GamePaths = new Dictionary<string, List<string>>();
                try { SaveState(); }
                catch (Exception ex) { _state.GamePaths = previous; MessageBox.Show(this, ex.Message, "Settings", MessageBoxButton.OK, MessageBoxImage.Warning); return; }
                if (_loadedPages.Contains("Games")) { RenderGameList(); RenderGameDetail(); }
                RefreshSessionGames(); LogActivity("Saved game scan cleared.");
            }; actions.Children.Add(clear);
            var reset = ActionButton("Reset settings", false);
            reset.Click += delegate {
                if (_tweakOperationBusy || _checkingUpdates || _updateInstallPreparing) return;
                if (MessageBox.Show(this, "Reset app preferences to their defaults? Presets, game profiles, undo history, and scheduled tasks are kept. Restart SharkOptimizer afterwards.", "Reset settings", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
                var previous = new PortableSetup { Preferences = SetupBackupCodec.Capture(_state).Preferences };
                try { ResetAppPreferences(_state, Localization.DefaultWindowsLanguage()); SaveState(); }
                catch (Exception ex) { SetupBackupCodec.Apply(_state, previous); MessageBox.Show(this, ex.Message, "Settings", MessageBoxButton.OK, MessageBoxImage.Warning); return; }
                if (_updateCheckTimer != null && !_previewMode) { _updateCheckTimer.Interval = TimeSpan.FromSeconds(8); _updateCheckTimer.Start(); }
                _pages["Settings"].Child = PageScroll(BuildSettings()); Localization.Apply(_pages["Settings"]); _selectSettingsSection(2);
                MessageBox.Show(this, "Settings reset. Exit from the tray menu and reopen SharkOptimizer to load the default appearance and language.", "Settings", MessageBoxButton.OK, MessageBoxImage.Information);
            }; actions.Children.Add(reset); body.Children.Add(actions); card.Child = body; return card;
        }

        private static void ResetAppPreferences(AppState state, string windowsLanguage)
        {
            var defaults = new AppState();
            state.Accent = defaults.Accent; state.UiFont = defaults.UiFont; state.InterfaceScale = defaults.InterfaceScale;
            state.AutoCheckUpdates = defaults.AutoCheckUpdates; state.AutoDownloadUpdates = defaults.AutoDownloadUpdates;
            state.Toasts = defaults.Toasts; state.ShowLog = defaults.ShowLog; state.ScanOnStart = defaults.ScanOnStart;
            state.ReduceMotion = defaults.ReduceMotion; state.AlwaysRestorePoint = defaults.AlwaysRestorePoint;
            state.Language = Localization.Languages.ContainsKey(windowsLanguage ?? "") ? windowsLanguage : "en";
            state.LegacyBehaviorImported = true; state.LegacyRestorePointImported = true; state.LegacyLanguageImported = true;
        }

        private void LogActivity(string message, bool error = false, bool notify = true)
        {
            string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " · " + (error ? "ERROR · " : "") + message.Replace('\r', ' ').Replace('\n', ' ');
            _activityLines.Add(line); if (_activityLines.Count > 1000) _activityLines.RemoveAt(0);
            if (_activityText != null) { _activityText.Text = String.Join(Environment.NewLine, _activityLines.TakeLastCompat(25)); _activityText.ScrollToEnd(); }
            if (!_previewMode) { string path = Path.Combine(Path.GetDirectoryName(_dataPath), "native-activity.log"); Task.Run(delegate { try { lock (_activityFileLock) { Directory.CreateDirectory(Path.GetDirectoryName(path)); if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024) File.WriteAllText(path, "", new UTF8Encoding(false)); File.AppendAllText(path, line + Environment.NewLine, new UTF8Encoding(false)); } } catch { } }); }
            if (notify && !_previewMode && _state.Toasts && !IsVisible && _trayIcon != null) {
                string notification = Localization.Translate(message);
                _trayIcon.ShowBalloonTip(4000, "SharkOptimizer", notification.Length > 240 ? notification.Substring(0, 240) : notification, error ? System.Windows.Forms.ToolTipIcon.Warning : System.Windows.Forms.ToolTipIcon.Info);
            }
        }

        private async Task ScanGamesAsync(bool startup)
        {
            if (_gameScanBusy || _previewMode) return; _gameScanBusy = true;
            if (_scanGamesButton != null) _scanGamesButton.IsEnabled = false;
            if (_gameStatus != null) _gameStatus.Text = "Scanning common game folders…";
            try {
                var found = await Task.Run(new Func<Dictionary<string, List<string>>>(FindInstalledGames));
                var previous = _state.GamePaths; var merged = new Dictionary<string, List<string>>(previous);
                foreach (var pair in found) { List<string> old; merged.TryGetValue(pair.Key, out old); merged[pair.Key] = (old ?? new List<string>()).Concat(pair.Value).Distinct(StringComparer.OrdinalIgnoreCase).ToList(); }
                _state.GamePaths = merged; try { SaveState(); } catch { _state.GamePaths = previous; throw; }
                string message = "Game scan complete · found " + AllGames().Count(x => PathsFor(x).Any(File.Exists)) + " supported profiles.";
                if (_gameStatus != null) _gameStatus.Text = message;
                if (_loadedPages.Contains("Games")) { RenderGameList(); RenderGameDetail(); } RefreshSessionGames(); LogActivity(message, false, !startup);
            } catch (Exception ex) { if (_gameStatus != null) _gameStatus.Text = "Scan failed: " + ex.Message; LogActivity("Game scan failed: " + ex.Message, true, !startup); }
            finally { _gameScanBusy = false; if (_scanGamesButton != null) _scanGamesButton.IsEnabled = true; }
        }
    }
    internal static class CollectionTail
    {
        internal static IEnumerable<T> TakeLastCompat<T>(this IList<T> source, int count) { return source.Skip(Math.Max(0, source.Count - count)); }
    }
}
