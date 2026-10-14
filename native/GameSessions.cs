using System;
using System.Diagnostics;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace SharkOptimizer.NativeApp
{
    internal sealed class GameSessionProfile
    {
        public List<string> SelectedProcesses { get; set; }
        public string ProcessMode { get; set; }
        public bool PowerPlan { get; set; }
        public bool PauseUpdate { get; set; }
        public bool TrimMemory { get; set; }
        public bool Automatic { get; set; }
        public bool AutomaticCloseApps { get; set; }
        public GameSessionProfile() { SelectedProcesses = new List<string>(); ProcessMode = "AskToClose"; }
    }

    internal sealed class GameSessionStore
    {
        public int Version { get; set; }
        public List<string> AlwaysKeep { get; set; }
        public Dictionary<string, GameSessionProfile> Profiles { get; set; }
        public GameSessionStore() { Version = 1; AlwaysKeep = new List<string>(); Profiles = new Dictionary<string, GameSessionProfile>(); }
    }

    internal static class GameSessionCodec
    {
        internal static List<string> Names(IEnumerable<string> values)
        {
            if (values == null) return new List<string>(); var result = new List<string>();
            foreach (string value in values) {
                string name = (value ?? "").Trim().ToLowerInvariant(); if (name.EndsWith(".exe", StringComparison.Ordinal)) name = name.Substring(0, name.Length - 4);
                if (!Regex.IsMatch(name, @"^[a-z0-9_.-]{1,120}$")) throw new InvalidDataException("Use process names such as discord or steam, without paths.");
                if (!result.Contains(name)) result.Add(name); if (result.Count > 100) throw new InvalidDataException("A session list can contain up to 100 process names.");
            }
            return result;
        }
        internal static void Validate(GameSessionStore store)
        {
            if (store == null || store.Version != 1 || store.Profiles == null || store.Profiles.Count > 200) throw new InvalidDataException("The game-session settings are invalid.");
            store.AlwaysKeep = Names(store.AlwaysKeep);
            foreach (var entry in store.Profiles) {
                if (!Regex.IsMatch(entry.Key, @"^[A-Za-z0-9_.-]{1,100}$") || entry.Value == null) throw new InvalidDataException("A game-session profile is invalid.");
                var profile = entry.Value; profile.SelectedProcesses = Names(profile.SelectedProcesses);
                if (profile.ProcessMode != "AskToClose" && profile.ProcessMode != "LowerPriority") throw new InvalidDataException("The game-session app action is unsupported.");
            }
        }
        internal static GameSessionStore Read(string json)
        {
            if (json == null || json.Length > 1024 * 1024) throw new InvalidDataException("Game-session settings must be smaller than 1 MB.");
            var store = new JavaScriptSerializer { MaxJsonLength = 1024 * 1024 }.Deserialize<GameSessionStore>(json); Validate(store); return store;
        }
    }

    internal sealed class SessionPriorityChange
    {
        public SessionProcessIdentity Process { get; set; }
        public string Original { get; set; }
    }

    internal sealed class SessionProcessIdentity
    {
        public int Id;
        public string Name;
        public DateTime StartedUtc;
        public long StartedTicks;
        internal bool Matches(Process process)
        {
            return !process.HasExited && process.Id == Id && String.Equals(process.ProcessName, Name, StringComparison.OrdinalIgnoreCase) && process.StartTime.ToUniversalTime().Ticks == (StartedTicks == 0 ? StartedUtc.Ticks : StartedTicks);
        }
    }

    internal sealed partial class MainWindow
    {
        private TextBox _sessionKeepNames;
        private TextBlock _sessionProfileStatus;
        private string _sessionSettingsNotice;
        private ComboBox _sessionAppAction;
        private readonly List<string> _sessionActionNotes = new List<string>();
        private bool SessionLowersPriority { get { return _sessionAppAction != null && _sessionAppAction.SelectedIndex == 1; } }
        private string SessionProfileKey() { var item = _sessionGamePicker == null ? null : _sessionGamePicker.SelectedItem as ComboBoxItem; return item == null || String.IsNullOrWhiteSpace(item.Uid) ? "_manual" : item.Uid; }
        private bool IsKeptSessionProcess(string name) { return IsProtectedSessionProcess(name) || _state.GameSessions.AlwaysKeep.Contains((name ?? "").ToLowerInvariant()) || AllGames().Any(game => (game.Executables ?? new List<string>()).Any(exe => String.Equals(Path.GetFileNameWithoutExtension(exe), name, StringComparison.OrdinalIgnoreCase))); }

        private static bool GameProcessRunning(string name)
        {
            Process[] matches = Process.GetProcessesByName(name);
            try { return matches.Length > 0; } finally { foreach (Process process in matches) process.Dispose(); }
        }

        private void ImportLegacyGameSessions()
        {
            if (_state.LegacyGameSessionsImported) return;
            try {
                string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SharkOptimizer", "game-sessions.json"), json = null;
                if (_state.LegacyBackupFiles.ContainsKey("game-sessions.json")) json = _state.LegacyBackupFiles["game-sessions.json"];
                else if (File.Exists(path)) { if (new FileInfo(path).Length > 1024 * 1024) throw new InvalidDataException("The previous session settings exceed 1 MB."); json = File.ReadAllText(path); }
                if (json != null) { _state.GameSessions = GameSessionCodec.Read(json); _sessionSettingsNotice = "Imported your previous game-session profiles and protected-app list."; }
                _state.LegacyGameSessionsImported = true; _legacyStateMigrated = true;
            } catch (Exception ex) { _sessionSettingsNotice = "Previous session settings could not be loaded: " + ex.Message; }
        }

        private void AddSessionProfileControls(StackPanel panel)
        {
            panel.Children.Add(Text("Selected app action", 12, Brushes.White, true, 0, 12));
            _sessionAppAction = new ComboBox { MinHeight = 36, Margin = new Thickness(0, 6, 0, 3) };
            _sessionAppAction.Items.Add(new ComboBoxItem { Content = "Ask apps to close normally" });
            _sessionAppAction.Items.Add(new ComboBoxItem { Content = "Lower app priority temporarily" });
            _sessionAppAction.SelectedIndex = 0; panel.Children.Add(_sessionAppAction);
            panel.Children.Add(Text("Lower priority keeps apps open and restores their original priority when the session ends. Games and protected apps are excluded.", 10, Brush(MutedColor), false, 0, 4));
            AddSessionExtras(panel);
            var keep = new Expander { Header = "Protected apps & saved profile", Margin = new Thickness(0, 12, 0, 4) }; var body = new StackPanel();
            body.Children.Add(Text("Always keep these apps running", 12, Brushes.White, true, 0, 8));
            body.Children.Add(Text("Enter process names separated by commas. These apps are excluded from every Game Boost profile.", 10, Brush(MutedColor), false, 0, 5));
            _sessionKeepNames = new TextBox { Text = String.Join(", ", _state.GameSessions.AlwaysKeep), MinHeight = 36, Padding = new Thickness(9, 7, 9, 7), Margin = new Thickness(0, 7, 0, 8) }; body.Children.Add(_sessionKeepNames);
            Localization.KeepData(_sessionKeepNames);
            var save = ActionButton("Save profile & protected apps", false); save.HorizontalAlignment = HorizontalAlignment.Left; save.Click += delegate { SaveSessionProfile(); }; body.Children.Add(save);
            _sessionProfileStatus = Text(_sessionSettingsNotice ?? "Save the selected apps and power-plan choice for this game.", 10, Brush(MutedColor), false, 0, 7); body.Children.Add(_sessionProfileStatus); keep.Content = body; panel.Children.Add(keep);
            _sessionGamePicker.SelectionChanged += delegate { LoadSessionProfile(); };
        }

        private void SaveSessionProfile()
        {
            if (_sessionStarting || (_sessionEndingTask != null && !_sessionEndingTask.IsCompleted) || (_sessionTimer != null && _sessionTimer.IsEnabled)) { _sessionProfileStatus.Text = "End the current session before editing its profile."; return; }
            var previous = _state.GameSessions;
            try {
                var next = GameSessionCodec.Read(_json.Serialize(previous));
                next.AlwaysKeep = GameSessionCodec.Names(Regex.Split(_sessionKeepNames.Text, @"[,;\r\n]+").Where(x => !String.IsNullOrWhiteSpace(x)));
                string key = SessionProfileKey(); GameSessionProfile profile;
                if (!next.Profiles.TryGetValue(key, out profile)) profile = new GameSessionProfile();
                profile.PowerPlan = _sessionUsePerformancePlan.IsChecked == true;
                profile.ProcessMode = SessionLowersPriority ? "LowerPriority" : "AskToClose";
                profile.PauseUpdate = _sessionPauseUpdate.IsChecked == true; profile.TrimMemory = _sessionTrimMemory.IsChecked == true;
                profile.Automatic = _automaticSessionCheck.IsChecked == true;
                profile.AutomaticCloseApps = _automaticCloseAppsCheck.IsChecked == true;
                profile.SelectedProcesses = _sessionProcessChecks.Where(x => x.IsChecked == true).Select(x => x.Tag as SessionProcessIdentity).Where(x => x != null && !IsProtectedSessionProcess(x.Name) && !next.AlwaysKeep.Contains(x.Name.ToLowerInvariant())).Select(x => x.Name.ToLowerInvariant()).Distinct().ToList();
                if (profile.Automatic && key == "_manual") throw new InvalidDataException("Choose a detected game before enabling automatic Game Boost.");
                if (profile.Automatic && !ConfirmAutomaticProfile(key, profile)) return;
                next.Profiles[key] = profile; GameSessionCodec.Validate(next); _state.GameSessions = next; SaveState();
                LoadSessionProfile(); _sessionProfileStatus.Text = "Profile saved for " + key + ". Protected apps apply to every profile.";
            } catch (Exception ex) { _state.GameSessions = previous; _sessionProfileStatus.Text = "Could not save profile: " + ex.Message; }
        }

        private void LoadSessionProfile()
        {
            GameSessionProfile profile; _state.GameSessions.Profiles.TryGetValue(SessionProfileKey(), out profile);
            if (_sessionUsePerformancePlan != null) _sessionUsePerformancePlan.IsChecked = profile != null && profile.PowerPlan;
            if (_sessionAppAction != null) _sessionAppAction.SelectedIndex = profile != null && profile.ProcessMode == "LowerPriority" ? 1 : 0;
            if (_sessionPauseUpdate != null) _sessionPauseUpdate.IsChecked = profile != null && profile.PauseUpdate;
            if (_sessionTrimMemory != null) _sessionTrimMemory.IsChecked = profile != null && profile.TrimMemory;
            if (_automaticSessionCheck != null) _automaticSessionCheck.IsChecked = profile != null && profile.Automatic;
            if (_automaticCloseAppsCheck != null) _automaticCloseAppsCheck.IsChecked = profile != null && profile.AutomaticCloseApps;
            RefreshSessionProcesses();
            if (_sessionProfileStatus != null) _sessionProfileStatus.Text = profile == null ? "No saved profile for this game yet." : "Loaded profile for " + SessionProfileKey() + ".";
        }

        private void ApplySessionProcessSelection(CheckBox check, SessionProcessIdentity identity)
        {
            bool kept = IsKeptSessionProcess(identity.Name); GameSessionProfile profile; _state.GameSessions.Profiles.TryGetValue(SessionProfileKey(), out profile);
            check.IsEnabled = !kept; check.IsChecked = !kept && profile != null && profile.SelectedProcesses.Contains(identity.Name.ToLowerInvariant());
            if (kept) check.ToolTip = "Protected by your always-keep list.";
        }

        private void LowerSessionPriority(SessionProcessIdentity identity)
        {
            if (IsKeptSessionProcess(identity.Name)) return;
            try {
                using (Process process = Process.GetProcessById(identity.Id)) {
                    if (!identity.Matches(process)) { _sessionActionNotes.Add("Skipped changed app: " + identity.Name); return; }
                    ProcessPriorityClass original = process.PriorityClass;
                    if (original == ProcessPriorityClass.Idle || original == ProcessPriorityClass.BelowNormal) { _sessionActionNotes.Add("Already at low priority: " + identity.Name); return; }
                    var change = new SessionPriorityChange { Process = identity, Original = original.ToString() };
                    _state.SessionPriorities.Add(change);
                    try { SaveState(); } catch { _state.SessionPriorities.Remove(change); throw new IOException("Could not save the priority recovery record."); }
                    process.PriorityClass = ProcessPriorityClass.BelowNormal;
                    _sessionActionNotes.Add("Lowered priority: " + identity.Name);
                }
            } catch (Exception ex) { _sessionActionNotes.Add("Could not lower " + identity.Name + ": " + ex.Message); }
        }

        private void RestoreSessionPriorities()
        {
            foreach (SessionPriorityChange change in _state.SessionPriorities.ToArray()) {
                try {
                    if (change == null || change.Process == null || change.Process.Id <= 0) throw new InvalidDataException("The saved app identity is invalid.");
                    ProcessPriorityClass original;
                    if (!Enum.TryParse<ProcessPriorityClass>(change.Original, out original) || !Enum.IsDefined(typeof(ProcessPriorityClass), original)) throw new InvalidDataException("The saved original priority is invalid.");
                    Process process;
                    try { process = Process.GetProcessById(change.Process.Id); }
                    catch (ArgumentException) { _state.SessionPriorities.Remove(change); _sessionActionNotes.Add("App already exited: " + change.Process.Name); continue; }
                    using (process) {
                        if (!change.Process.Matches(process)) { _state.SessionPriorities.Remove(change); _sessionActionNotes.Add("Skipped replaced app: " + change.Process.Name); continue; }
                        process.PriorityClass = original;
                        _sessionActionNotes.Add("Restored priority: " + change.Process.Name); _state.SessionPriorities.Remove(change);
                    }
                } catch (Exception ex) { _sessionActionNotes.Add("Could not restore app priority: " + ex.Message); }
            }
            try { SaveState(); } catch (Exception ex) { _sessionActionNotes.Add("Could not save session recovery: " + ex.Message); }
        }

        private void SetSessionControlsEnabled(bool enabled)
        {
            if (_sessionGamePicker != null) _sessionGamePicker.IsEnabled = enabled;
            if (_sessionUsePerformancePlan != null) _sessionUsePerformancePlan.IsEnabled = enabled;
            if (_sessionAppAction != null) _sessionAppAction.IsEnabled = enabled;
            if (_sessionPauseUpdate != null) _sessionPauseUpdate.IsEnabled = enabled;
            if (_sessionTrimMemory != null) _sessionTrimMemory.IsEnabled = enabled;
            if (_sessionKeepNames != null) _sessionKeepNames.IsEnabled = enabled;
            if (_automaticSessionCheck != null) _automaticSessionCheck.IsEnabled = enabled;
            if (_automaticCloseAppsCheck != null) _automaticCloseAppsCheck.IsEnabled = enabled;
        }

        private static bool IsProtectedSessionProcess(string name)
        {
            if (String.IsNullOrWhiteSpace(name) || name.IndexOf("SharkOptimizer", StringComparison.OrdinalIgnoreCase) >= 0) return true;
            foreach (string core in new[] { "explorer", "dwm", "ShellExperienceHost", "SearchHost", "StartMenuExperienceHost", "TextInputHost", "SystemSettings", "ApplicationFrameHost", "powershell", "pwsh", "WindowsTerminal", "taskmgr", "csrss", "winlogon", "LockApp" })
                if (String.Equals(core, name, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }
    }
}
