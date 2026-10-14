using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace SharkOptimizer.NativeApp
{
    // A snapshot contains paths approved by the saved game profile, never process names alone.
    internal sealed class AutomaticGameProbe
    {
        public string Id, Name;
        public List<string> Paths;
        public bool Running, Uncertain;
    }

    internal sealed partial class MainWindow
    {
        [DllImport("kernel32.dll", EntryPoint = "OpenProcess", SetLastError = true)]
        private static extern IntPtr OpenAutomaticProcess(uint access, bool inherit, int processId);
        [DllImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool QueryAutomaticProcessImage(IntPtr process, uint flags, StringBuilder path, ref uint size);
        [DllImport("kernel32.dll", EntryPoint = "CloseHandle")]
        private static extern bool CloseAutomaticProcess(IntPtr process);
        private static string AutomaticProcessPath(int processId)
        {
            IntPtr handle = OpenAutomaticProcess(0x1000, false, processId);
            if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                var path = new StringBuilder(32768); uint size = (uint)path.Capacity;
                if (!QueryAutomaticProcessImage(handle, 0, path, ref size)) throw new Win32Exception(Marshal.GetLastWin32Error());
                return path.ToString();
            } finally { CloseAutomaticProcess(handle); }
        }
        private CheckBox _automaticSessionCheck, _automaticCloseAppsCheck;
        private DispatcherTimer _automaticSessionTimer;
        private bool _automaticProbeBusy;
        private string _automaticSessionGameId;
        private DateTime? _automaticMissingSince;
        private AutomaticGameProbe _automaticActiveProbe;
        private bool _sessionRecapReady;
        private readonly HashSet<string> _automaticSuppressed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        private void AddAutomaticSessionControls(StackPanel panel)
        {
            _automaticSessionCheck = new CheckBox { Content = "Automatic Game Boost for this game", Margin = new Thickness(0, 12, 0, 5) };
            _automaticCloseAppsCheck = new CheckBox { Content = "Allow automatic close requests for selected apps", Margin = new Thickness(0, 4, 0, 5) };
            panel.Children.Add(_automaticSessionCheck);
            panel.Children.Add(_automaticCloseAppsCheck);
            panel.Children.Add(Text("Save the profile to enable it. SharkOptimizer must be running, including in the tray. Only detected game paths are monitored.", 10, Brush(MutedColor), false, 0, 4));
        }

        private bool ConfirmAutomaticProfile(string key, GameSessionProfile profile)
        {
            var game = AllGames().FirstOrDefault(x => x.Id == key);
            if (game == null || PathsFor(game).Count == 0) throw new InvalidDataException("Choose a detected game before enabling automatic Game Boost.");
            string review = Localization.Translate("Automatic Game Boost for this game") + ": " + game.Name + "\n\n";
            review += Localization.Translate("Power plan") + ": " + Localization.Translate(profile.PowerPlan ? "On" : "Off") + "\n";
            review += Localization.Translate("Pause Windows Update service") + ": " + Localization.Translate(profile.PauseUpdate ? "On" : "Off") + "\n";
            review += Localization.Translate("Trim background app memory") + ": " + Localization.Translate(profile.TrimMemory ? "On" : "Off") + "\n";
            review += Localization.Translate("Selected apps") + ": " + (profile.SelectedProcesses.Count == 0 ? Localization.Translate("None") : String.Join(", ", profile.SelectedProcesses)) + "\n";
            review += Localization.Translate(profile.ProcessMode == "LowerPriority" ? "Lower app priority temporarily" : profile.AutomaticCloseApps ? "Allow automatic close requests for selected apps" : "Automatic close requests are disabled.") + "\n\n";
            review += Localization.Translate("These actions will run without a prompt when this game starts. Temporary settings are restored after it exits. Closed apps are not reopened.");
            return MessageBox.Show(this, review, Localization.Translate("Review automatic Game Boost"), MessageBoxButton.OKCancel, MessageBoxImage.Information) == MessageBoxResult.OK;
        }

        private void StartAutomaticSessionWatcher()
        {
            if (_previewMode || _automaticSessionTimer != null || _sessionExitInProgress) return;
            _automaticSessionTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
            _automaticSessionTimer.Tick += async delegate { await PollAutomaticSessions(); };
            _automaticSessionTimer.Start();
        }

        private void StopAutomaticSessionWatcher()
        {
            if (_automaticSessionTimer != null) { _automaticSessionTimer.Stop(); _automaticSessionTimer = null; }
        }

        private static AutomaticGameProbe ReadAutomaticGame(AutomaticGameProbe probe)
        {
            foreach (string name in probe.Paths.Select(Path.GetFileNameWithoutExtension).Distinct(StringComparer.OrdinalIgnoreCase)) {
                Process[] processes;
                try { processes = Process.GetProcessesByName(name); } catch { probe.Uncertain = true; continue; }
                foreach (Process process in processes) {
                    try {
                        string runningPath = AutomaticProcessPath(process.Id);
                        if (probe.Paths.Any(path => String.Equals(Path.GetFullPath(path), runningPath, StringComparison.OrdinalIgnoreCase))) probe.Running = true;
                    } catch { probe.Uncertain = true; } finally { process.Dispose(); }
                }
            }
            return probe;
        }

        private async Task PollAutomaticSessions()
        {
            if (_automaticProbeBusy || _sessionExitInProgress || _updateShutdown || _sessionStarting || (_sessionEndingTask != null && !_sessionEndingTask.IsCompleted)) return;
            var probes = AllGames().Where(game => {
                GameSessionProfile profile;
                return game.Id == _automaticSessionGameId || (_state.GameSessions.Profiles.TryGetValue(game.Id, out profile) && profile.Automatic);
            }).Select(game => new AutomaticGameProbe { Id = game.Id, Name = game.Name, Paths = PathsFor(game).Where(path => !String.IsNullOrWhiteSpace(path)).Distinct(StringComparer.OrdinalIgnoreCase).ToList() }).Where(x => x.Paths.Count > 0).ToList();
            if (_automaticSessionGameId != null && _automaticActiveProbe != null) {
                probes.RemoveAll(x => x.Id == _automaticSessionGameId);
                probes.Add(new AutomaticGameProbe { Id = _automaticActiveProbe.Id, Name = _automaticActiveProbe.Name, Paths = new List<string>(_automaticActiveProbe.Paths) });
            }
            if (probes.Count == 0) return;
            _automaticProbeBusy = true;
            try {
                await Task.Run(delegate { foreach (var probe in probes) ReadAutomaticGame(probe); });
                if (_sessionExitInProgress || _updateShutdown) return;
                foreach (var probe in probes.Where(x => !x.Running && !x.Uncertain)) _automaticSuppressed.Remove(probe.Id);
                if (_automaticSessionGameId != null) {
                    var active = probes.FirstOrDefault(x => x.Id == _automaticSessionGameId);
                    if (active == null || active.Uncertain) { _automaticMissingSince = null; return; }
                    if (active.Running) _automaticMissingSince = null;
                    else {
                        if (!_automaticMissingSince.HasValue) _automaticMissingSince = DateTime.UtcNow;
                        if ((DateTime.UtcNow - _automaticMissingSince.Value).TotalSeconds >= 15) await EndGameSession(true);
                    }
                    return;
                }
                if ((_sessionTimer != null && _sessionTimer.IsEnabled) || SessionRecoveryPending || _state.ActiveSessionReport != null || _state.MaintenanceServices.Count > 0 || _tweakOperationBusy) return;
                var detected = probes.FirstOrDefault(x => x.Running && !_automaticSuppressed.Contains(x.Id));
                if (detected != null) await StartAutomaticSession(detected);
            } catch (Exception ex) { LogActivity("Automatic Game Boost: " + ex.Message, true, false); }
            finally { _automaticProbeBusy = false; }
        }

        private async Task StartAutomaticSession(AutomaticGameProbe game)
        {
            GameSessionProfile saved;
            if (!_state.GameSessions.Profiles.TryGetValue(game.Id, out saved) || !saved.Automatic) return;
            // Snapshot consent/settings before awaiting service operations.
            var profile = GameSessionCodec.Read(_json.Serialize(_state.GameSessions)).Profiles[game.Id];
            _automaticSuppressed.Add(game.Id);
            _sessionStarting = true;
            SetSessionControlsEnabled(false);
            if (_sessionStartButton != null) _sessionStartButton.IsEnabled = false;
            _sessionActionNotes.Clear();
            Exception setupFailure = null;
            try {
              try {
                BeginSessionReport(game.Name);
                _state.ActiveSessionReport.Mode = "Automatic";
                SaveState();
                _automaticSessionGameId = game.Id; _automaticMissingSince = null;
                _automaticActiveProbe = game;
                _sessionPlanNotice = null;
                foreach (string name in profile.SelectedProcesses) {
                    if (IsKeptSessionProcess(name)) continue;
                    if (profile.ProcessMode != "LowerPriority" && !profile.AutomaticCloseApps) continue;
                    foreach (Process process in Process.GetProcessesByName(name)) {
                        try {
                            DateTime started = process.StartTime.ToUniversalTime();
                            var identity = new SessionProcessIdentity { Id = process.Id, Name = process.ProcessName, StartedUtc = started, StartedTicks = started.Ticks };
                            if (profile.ProcessMode == "LowerPriority") LowerSessionPriority(identity);
                            else if (identity.Matches(process)) _sessionActionNotes.Add((process.CloseMainWindow() ? "Asked app to close: " : "App stayed open: ") + name);
                        } catch (Exception ex) { _sessionActionNotes.Add(name + ": " + ex.Message); } finally { process.Dispose(); }
                    }
                }
                if (profile.PowerPlan) TrySwitchToPerformancePlan();
                if (!String.IsNullOrEmpty(_sessionPlanNotice)) _sessionActionNotes.Add(_sessionPlanNotice);
                if (profile.PauseUpdate) await PauseSessionUpdates();
                if (profile.TrimMemory) _sessionActionNotes.Add(await Task.Run(new Func<string>(TrimSessionMemory)));
                CheckpointSessionReport();
                if (_sessionExitAfterStart || _sessionExitInProgress || _updateShutdown) { await EndGameSession(false); return; }
                _sessionTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) }; // marks the shared session as active
                _sessionTimer.Start();
                if (_sessionEndButton != null) _sessionEndButton.IsEnabled = true;
                if (_sessionStatus != null) _sessionStatus.Text = Localization.Translate("Automatic Game Boost") + " · " + game.Name;
                LogActivity(Localization.Translate("Automatic Game Boost") + " · " + game.Name);
            } catch (Exception ex) {
                _sessionActionNotes.Add("Automatic Game Boost: " + ex.Message);
                setupFailure = ex;
            }
            if (setupFailure != null) await EndGameSession(true);
            } finally {
                _sessionStarting = false;
                if (_sessionExitAfterStart) { _sessionExitAfterStart = false; _allowExit = true; Close(); }
            }
        }
    }
}
