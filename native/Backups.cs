using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace SharkOptimizer.NativeApp
{
    internal sealed class PortablePreferences
    {
        public string Accent { get; set; }
        public string UiFont { get; set; }
        public double InterfaceScale { get; set; }
        public bool AutoCheckUpdates { get; set; }
        public bool AutoDownloadUpdates { get; set; }
        public string CleanupDay { get; set; }
        public string CleanupTime { get; set; }
        public bool Toasts { get; set; }
        public bool ShowLog { get; set; }
        public bool ScanOnStart { get; set; }
        public bool ReduceMotion { get; set; }
        public bool AlwaysRestorePoint { get; set; }
        public string Language { get; set; }
        public PortablePreferences() { Accent = "blue"; UiFont = "Poppins"; InterfaceScale = 1; AutoCheckUpdates = true; AutoDownloadUpdates = true; CleanupDay = "SUN"; CleanupTime = "20:00"; Toasts = true; ShowLog = true; Language = "en"; }
    }

    internal sealed class PortableSetup
    {
        public PortablePreferences Preferences { get; set; }
        public List<UserPreset> Presets { get; set; }
        public Dictionary<string, List<string>> GamePaths { get; set; }
        public List<GameDefinition> CustomGames { get; set; }
        public List<CustomTweak> CustomTweaks { get; set; }
        public GameSessionStore GameSessions { get; set; }
        public List<GameSessionReport> SessionHistory { get; set; }
        public List<CleanupRun> CleanupHistory { get; set; }
        public bool IncludesBenchmarks { get; set; }
        public BenchSnapshot BenchBefore { get; set; }
        public BenchSnapshot BenchAfter { get; set; }
        public List<BenchmarkRun> BenchmarkRuns { get; set; }
        public Dictionary<string, string> LegacyFiles { get; set; }
    }

    internal static class SetupBackupCodec
    {
        private static readonly string[] LegacyNames = { "settings.json", "presets.json", "games-cache.json", "custom-games.json", "custom-tweaks.json", "game-sessions.json", "game-session-history.json", "boost-history.json", "bench.json" };
        private static JavaScriptSerializer Serializer() { return new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024, RecursionLimit = 64 }; }
        private static object Member(IDictionary<string, object> item, string name)
        { return item == null ? null : item.FirstOrDefault(x => String.Equals(x.Key, name, StringComparison.OrdinalIgnoreCase)).Value; }
        private static double Number(IDictionary<string, object> item, string name, double fallback)
        { object value = Member(item, name); return value == null ? fallback : Convert.ToDouble(value, CultureInfo.InvariantCulture); }

        internal static PortableSetup Capture(AppState state)
        {
            var data = new PortableSetup {
                Preferences = new PortablePreferences { Accent = state.Accent, UiFont = state.UiFont, InterfaceScale = state.InterfaceScale, AutoCheckUpdates = state.AutoCheckUpdates, AutoDownloadUpdates = state.AutoDownloadUpdates, CleanupDay = state.CleanupDay, CleanupTime = state.CleanupTime, Toasts = state.Toasts, ShowLog = state.ShowLog, ScanOnStart = state.ScanOnStart, ReduceMotion = state.ReduceMotion, AlwaysRestorePoint = state.AlwaysRestorePoint, Language = state.Language ?? "en" },
                Presets = state.SavedPresets ?? new List<UserPreset>(), GamePaths = state.GamePaths,
                CustomGames = state.CustomGames, CustomTweaks = state.CustomTweaks ?? new List<CustomTweak>(), IncludesBenchmarks = true, BenchBefore = state.BenchBefore, BenchAfter = state.BenchAfter,
                GameSessions = state.GameSessions,
                SessionHistory = state.SessionHistory,
                CleanupHistory = state.CleanupHistory ?? new List<CleanupRun>(),
                BenchmarkRuns = state.BenchmarkRuns,
                LegacyFiles = state.LegacyBackupFiles ?? new Dictionary<string, string>()
            };
            return Serializer().Deserialize<PortableSetup>(Serializer().Serialize(data));
        }

        internal static string Encode(PortableSetup setup, Func<string, string> exportId)
        {
            var serializer = Serializer(); var files = new Dictionary<string, string>();
            if (setup.LegacyFiles != null) foreach (var file in setup.LegacyFiles) if (LegacyNames.Contains(file.Key)) files[file.Key] = file.Value;
            files["native-setup.json"] = serializer.Serialize(setup);
            if (setup.Preferences != null)
            {
                var settings = files.ContainsKey("settings.json") ? serializer.DeserializeObject(files["settings.json"]) as IDictionary<string, object> : null;
                if (settings == null) settings = new Dictionary<string, object>();
                settings["Accent"] = setup.Preferences.Accent; settings["AutoUpdate"] = setup.Preferences.AutoCheckUpdates; settings["TextScale"] = setup.Preferences.InterfaceScale;
                settings["Toasts"] = setup.Preferences.Toasts; settings["ShowLog"] = setup.Preferences.ShowLog; settings["ScanOnStart"] = setup.Preferences.ScanOnStart;
                settings["Language"] = setup.Preferences.Language;
                settings["AlwaysRestorePoint"] = setup.Preferences.AlwaysRestorePoint;
                settings["CleanDay"] = MainWindow.CleanupDayName(setup.Preferences.CleanupDay); settings["CleanTime"] = setup.Preferences.CleanupTime;
                files["settings.json"] = serializer.Serialize(settings);
            }
            if (setup.Presets != null) files["presets.json"] = serializer.Serialize(setup.Presets.Select(x => new { name = x.Name, ids = x.Ids.Select(exportId).ToArray() }).ToArray());
            if (setup.GamePaths != null) files["games-cache.json"] = serializer.Serialize(setup.GamePaths);
            if (setup.CustomGames != null) files["custom-games.json"] = serializer.Serialize(setup.CustomGames.Select(x => new { id = x.Id, name = x.Name, ac = x.AntiCheat, exes = x.Executables, tweaks = x.RecommendedTweaks.Select(exportId).ToArray(), tips = x.Tips, enabled = true }).ToArray());
            if (setup.CustomTweaks != null) files["custom-tweaks.json"] = CustomTweakCodec.WriteJson(setup.CustomTweaks);
            if (setup.GameSessions != null) files["game-sessions.json"] = serializer.Serialize(setup.GameSessions);
            if (setup.IncludesBenchmarks)
            {
                var benchmarks = files.ContainsKey("bench.json") ? serializer.DeserializeObject(files["bench.json"]) as IDictionary<string, object> : null;
                if (benchmarks == null) benchmarks = new Dictionary<string, object>();
                benchmarks["Before"] = ExportLegacyBenchmark(setup.BenchBefore); benchmarks["After"] = ExportLegacyBenchmark(setup.BenchAfter); files["bench.json"] = serializer.Serialize(benchmarks);
                if (setup.BenchmarkRuns != null) { benchmarks["Runs"] = setup.BenchmarkRuns.Select(x => new { slot = x.Slot, time = x.Data.CapturedAt.ToString("s"), data = ExportLegacyBenchmark(x.Data) }).ToArray(); files["bench.json"] = serializer.Serialize(benchmarks); }
            }
            string json = serializer.Serialize(new { format = "SharkOptimizerBackup", version = 1, created = DateTime.Now.ToString("s"), files = files });
            if (Encoding.UTF8.GetByteCount(json) > 4 * 1024 * 1024) throw new InvalidDataException("The setup backup exceeds 4 MB.");
            return json;
        }

        internal static PortableSetup Decode(string json, Func<string, string> map)
        {
            if (Encoding.UTF8.GetByteCount(json) > 4 * 1024 * 1024) throw new InvalidDataException("Setup backups must be no larger than 4 MB.");
            var serializer = Serializer(); var root = serializer.DeserializeObject(json) as IDictionary<string, object>;
            if (Convert.ToString(Member(root, "format")) != "SharkOptimizerBackup" || Convert.ToInt32(Member(root, "version"), CultureInfo.InvariantCulture) != 1) throw new InvalidDataException("This is not a supported SharkOptimizer setup backup.");
            var entries = Member(root, "files") as IDictionary<string, object>; if (entries == null) throw new InvalidDataException("The backup has no data files.");
            var files = new Dictionary<string, string>();
            foreach (var entry in entries)
            {
                if (entry.Key != "native-setup.json" && !LegacyNames.Contains(entry.Key)) continue;
                if (!(entry.Value is string) || Encoding.UTF8.GetByteCount((string)entry.Value) > 2 * 1024 * 1024) throw new InvalidDataException("Backup entry is invalid or larger than 2 MB: " + entry.Key);
                if (serializer.DeserializeObject((string)entry.Value) == null) throw new InvalidDataException("Backup entry is empty: " + entry.Key);
                files[entry.Key] = (string)entry.Value;
            }
            if (files.Count == 0) throw new InvalidDataException("The backup contains no supported app data.");
            PortableSetup setup = files.ContainsKey("native-setup.json") ? serializer.Deserialize<PortableSetup>(files["native-setup.json"]) : ConvertLegacy(files, map);
            if (setup == null) throw new InvalidDataException("The native setup data is invalid.");
            if (setup.LegacyFiles == null) setup.LegacyFiles = new Dictionary<string, string>();
            foreach (var file in files) if (LegacyNames.Contains(file.Key)) setup.LegacyFiles[file.Key] = file.Value;
            Validate(setup, map); return setup;
        }

        private static PortableSetup ConvertLegacy(Dictionary<string, string> files, Func<string, string> map)
        {
            var serializer = Serializer(); var setup = new PortableSetup();
            if (files.ContainsKey("custom-tweaks.json")) { setup.CustomTweaks = CustomTweakCodec.ReadJson(files["custom-tweaks.json"]); map = WithCustomIds(map, setup.CustomTweaks); }
            if (files.ContainsKey("game-sessions.json")) setup.GameSessions = GameSessionCodec.Read(files["game-sessions.json"]);
            if (files.ContainsKey("settings.json"))
            {
                var values = serializer.DeserializeObject(files["settings.json"]) as IDictionary<string, object>; if (values == null) throw new InvalidDataException("Legacy settings must be an object.");
                setup.Preferences = new PortablePreferences(); object accent = Member(values, "Accent"), update = Member(values, "AutoUpdate");
                if (accent != null) setup.Preferences.Accent = Convert.ToString(accent).ToLowerInvariant();
                if (update != null) setup.Preferences.AutoCheckUpdates = Convert.ToBoolean(update, CultureInfo.InvariantCulture);
                setup.Preferences.InterfaceScale = Number(values, "TextScale", 1);
                object toast = Member(values, "Toasts"), log = Member(values, "ShowLog"), scan = Member(values, "ScanOnStart");
                if (toast is bool) setup.Preferences.Toasts = (bool)toast; if (log is bool) setup.Preferences.ShowLog = (bool)log; if (scan is bool) setup.Preferences.ScanOnStart = (bool)scan;
                object restore = Member(values, "AlwaysRestorePoint"); if (restore is bool) setup.Preferences.AlwaysRestorePoint = (bool)restore;
                object language = Member(values, "Language"); if (language is string) setup.Preferences.Language = (string)language;
                string day = MainWindow.CleanupDayCode(Convert.ToString(Member(values, "CleanDay")));
                if (day != null) setup.Preferences.CleanupDay = day;
                object cleanTime = Member(values, "CleanTime"); DateTime time;
                if (cleanTime != null && DateTime.TryParseExact(Convert.ToString(cleanTime), new[] { "H:mm", "HH:mm" }, CultureInfo.InvariantCulture, DateTimeStyles.None, out time)) setup.Preferences.CleanupTime = time.ToString("HH:mm", CultureInfo.InvariantCulture);
            }
            if (files.ContainsKey("presets.json"))
            {
                object parsed = serializer.DeserializeObject(files["presets.json"]);
                setup.Presets = parsed is object[] && ((object[])parsed).Length == 0 ? new List<UserPreset>() : PresetCodec.ReadJson(files["presets.json"], map);
            }
            if (files.ContainsKey("games-cache.json")) setup.GamePaths = serializer.Deserialize<Dictionary<string, List<string>>>(files["games-cache.json"]);
            if (files.ContainsKey("custom-games.json"))
            {
                var entries = serializer.DeserializeObject(files["custom-games.json"]) as object[]; if (entries == null) throw new InvalidDataException("Legacy custom games must be a list."); setup.CustomGames = new List<GameDefinition>();
                foreach (object entry in entries)
                {
                    var game = entry as IDictionary<string, object>; if (game == null) throw new InvalidDataException("A custom game entry is invalid.");
                    if (Member(game, "enabled") is bool && !(bool)Member(game, "enabled")) continue;
                    setup.CustomGames.Add(new GameDefinition { Id = Convert.ToString(Member(game, "id")), Name = Convert.ToString(Member(game, "name")), AntiCheat = Convert.ToString(Member(game, "ac")),
                        Executables = Strings(Member(game, "exes")), Tips = Strings(Member(game, "tips")), RecommendedTweaks = Strings(Member(game, "tweaks")).Select(map).Where(x => x != null).Distinct().ToList(), IsCustom = true });
                }
            }
            if (files.ContainsKey("bench.json"))
            {
                var benchmarks = serializer.DeserializeObject(files["bench.json"]) as IDictionary<string, object>; if (benchmarks == null) throw new InvalidDataException("Legacy benchmarks must be an object.");
                setup.IncludesBenchmarks = true; setup.BenchBefore = LegacyBenchmark(Member(benchmarks, "Before") as IDictionary<string, object>); setup.BenchAfter = LegacyBenchmark(Member(benchmarks, "After") as IDictionary<string, object>);
                setup.BenchmarkRuns = BenchmarkHistory.Legacy(files["bench.json"]);
            }
            return setup;
        }

        private static List<string> Strings(object value)
        { var items = value as IEnumerable; if (items == null || value is string) return new List<string>(); return items.Cast<object>().Where(x => x is string).Cast<string>().ToList(); }
        internal static BenchSnapshot LegacyBenchmark(IDictionary<string, object> value)
        {
            if (value == null) return null; DateTime captured; DateTime.TryParse(Convert.ToString(Member(value, "Time")), CultureInfo.InvariantCulture, DateTimeStyles.None, out captured);
            return new BenchSnapshot { CapturedAt = captured, PingMs = Number(value, "PingMs", -1), JitterMs = Number(value, "JitterMs", -1), DnsMs = Number(value, "DnsMs", -1), CpuUse = Number(value, "CpuIdlePct", -1), RamUsedPercent = Number(value, "RamUsedPct", -1), FreeMemoryMb = -1, ProcessCount = (int)Number(value, "Processes", 0), ServicesRunning = (int)Number(value, "Services", 0), BootSeconds = Number(value, "BootSec", -1) };
        }

        private static object ExportLegacyBenchmark(BenchSnapshot value)
        { return value == null ? null : new { Time = value.CapturedAt.ToString("s"), PingMs = value.PingMs, JitterMs = value.JitterMs, DnsMs = value.DnsMs, CpuIdlePct = value.CpuUse, RamUsedPct = value.RamUsedPercent, Processes = value.ProcessCount, Services = value.ServicesRunning, BootSec = value.BootSeconds }; }

        internal static void Validate(PortableSetup setup, Func<string, string> map)
        {
            if (setup.CustomTweaks != null)
            {
                if (setup.CustomTweaks.Count > 100) throw new InvalidDataException("A backup can contain up to 100 custom definitions."); var customIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (CustomTweak tweak in setup.CustomTweaks) { CustomTweakCodec.Validate(tweak); if (!customIds.Add(tweak.Id)) throw new InvalidDataException("Custom-tweak IDs must be unique."); }
                map = WithCustomIds(map, setup.CustomTweaks);
            }
            if (setup.Preferences != null)
            {
                var p = setup.Preferences; DateTime time;
                if (!Localization.Languages.ContainsKey(p.Language ?? "")) throw new InvalidDataException("The saved interface language is unsupported.");
                if (!new[] { "blue", "green", "purple", "orange" }.Contains(p.Accent) || !new[] { "Poppins", "Segoe UI" }.Contains(p.UiFont) || !new[] { .9, 1, 1.1, 1.25 }.Contains(p.InterfaceScale)) throw new InvalidDataException("The appearance preferences are not supported.");
                if (!new[] { "MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN" }.Contains(p.CleanupDay) || !DateTime.TryParseExact(p.CleanupTime, new[] { "H:mm", "HH:mm" }, CultureInfo.InvariantCulture, DateTimeStyles.None, out time)) throw new InvalidDataException("The saved cleanup schedule preference is invalid.");
            }
            if (setup.GameSessions != null) GameSessionCodec.Validate(setup.GameSessions);
            if (setup.Presets != null)
            {
                if (setup.Presets.Count > 100) throw new InvalidDataException("A backup can contain up to 100 presets.");
                var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase); var valid = new List<UserPreset>();
                foreach (UserPreset p in setup.Presets) { if (p == null) throw new InvalidDataException("A preset entry is invalid."); var item = PresetCodec.Normalize(p.Name, p.Ids, map); if (!names.Add(item.Name)) throw new InvalidDataException("Preset names must be unique."); valid.Add(item); } setup.Presets = valid;
            }
            if (setup.GamePaths != null)
            {
                if (setup.GamePaths.Count > 200) throw new InvalidDataException("The game-path list is too large.");
                foreach (var entry in setup.GamePaths)
                {
                    if (!Regex.IsMatch(entry.Key, @"^[A-Za-z0-9_.-]{1,100}$") || entry.Value == null || entry.Value.Count > 50) throw new InvalidDataException("A game-path entry is invalid.");
                    foreach (string path in entry.Value) if (String.IsNullOrWhiteSpace(path) || path.Length > 2048 || !Path.IsPathRooted(path) || !path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Saved game paths must be full executable paths.");
                }
            }
            if (setup.CustomGames != null)
            {
                if (setup.CustomGames.Count > 100) throw new InvalidDataException("The custom-game list is too large."); var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (GameDefinition game in setup.CustomGames)
                {
                    if (game == null || String.IsNullOrWhiteSpace(game.Id) || !Regex.IsMatch(game.Id, @"^[A-Za-z0-9_.-]{1,100}$") || !ids.Add(game.Id) || String.IsNullOrWhiteSpace(game.Name) || game.Name.Length > 120) throw new InvalidDataException("A custom-game profile is invalid.");
                    if (game.Executables == null || game.Executables.Count == 0 || game.Executables.Count > 30 || game.Executables.Any(x => String.IsNullOrWhiteSpace(x) || x.Length > 260 || Path.GetFileName(x) != x || !x.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))) throw new InvalidDataException("Custom-game executables must be file names ending in .exe.");
                    if (game.Tips == null) game.Tips = new List<string>(); if (game.Tips.Count > 30 || game.Tips.Any(x => x == null || x.Length > 2048)) throw new InvalidDataException("A game-tip entry is invalid.");
                    game.RecommendedTweaks = (game.RecommendedTweaks ?? new List<string>()).Select(map).Where(x => x != null).Distinct().ToList(); game.IsCustom = true;
                }
            }
            if (setup.IncludesBenchmarks && setup.BenchmarkRuns == null) {
                setup.BenchmarkRuns = new List<BenchmarkRun>();
                if (setup.BenchBefore != null) setup.BenchmarkRuns.Add(new BenchmarkRun { Id = Guid.NewGuid().ToString("N"), Slot = "Before", Data = setup.BenchBefore });
                if (setup.BenchAfter != null) setup.BenchmarkRuns.Add(new BenchmarkRun { Id = Guid.NewGuid().ToString("N"), Slot = "After", Data = setup.BenchAfter });
            }
            if (setup.BenchmarkRuns != null && (setup.BenchmarkRuns.Count > 60 || setup.BenchmarkRuns.Any(x => x == null || x.Data == null || (x.Slot != "Before" && x.Slot != "After")))) throw new InvalidDataException("Benchmark history must contain up to 60 valid BEFORE/AFTER runs.");
            foreach (BenchSnapshot snapshot in new[] { setup.BenchBefore, setup.BenchAfter }.Concat((setup.BenchmarkRuns ?? new List<BenchmarkRun>()).Select(x => x.Data)).Where(x => x != null))
            {
                if (new[] { snapshot.PingMs, snapshot.JitterMs, snapshot.DnsMs, snapshot.CpuUse, snapshot.RamUsedPercent, snapshot.FreeMemoryMb, snapshot.BootSeconds }.Any(x => Double.IsNaN(x) || Double.IsInfinity(x) || x < -1 || x > 1e12) || snapshot.CpuUse > 100 || snapshot.RamUsedPercent > 100 || snapshot.ProcessCount < -1 || snapshot.ServicesRunning < -1) throw new InvalidDataException("A benchmark snapshot contains invalid measurements.");
            }
            if (setup.LegacyFiles != null) foreach (var file in setup.LegacyFiles)
            {
                if (!LegacyNames.Contains(file.Key) || file.Value == null || Encoding.UTF8.GetByteCount(file.Value) > 2 * 1024 * 1024 || Serializer().DeserializeObject(file.Value) == null) throw new InvalidDataException("A preserved legacy backup entry is invalid.");
            }
            if (setup.SessionHistory != null) {
                if (setup.SessionHistory.Count > 50) throw new InvalidDataException("Session history can contain up to 50 reports.");
                var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (GameSessionReport report in setup.SessionHistory) {
                    if (report == null || !Regex.IsMatch(report.Id ?? "", @"^[A-Za-z0-9_.-]{1,100}$") || !ids.Add(report.Id) || String.IsNullOrWhiteSpace(report.Game) || report.Game.Length > 120 || (report.Mode ?? "").Length > 120 || report.StartedUtc == default(DateTime) || report.EndedUtc < report.StartedUtc || report.Checklist == null || report.Checklist.Count > 300 || report.Checklist.Any(x => x == null || x.Length > 8192)) throw new InvalidDataException("A saved session report is invalid.");
                }
            }
            if (setup.CleanupHistory != null) {
                if (setup.CleanupHistory.Count > 50) throw new InvalidDataException("Cleanup history must contain no more than 50 entries.");
                foreach (CleanupRun run in setup.CleanupHistory) MainWindow.ValidateCleanupRun(run);
            }
            if (setup.Preferences == null && setup.Presets == null && setup.GamePaths == null && setup.CustomGames == null && setup.CustomTweaks == null && setup.GameSessions == null && setup.SessionHistory == null && setup.CleanupHistory == null && !setup.IncludesBenchmarks && (setup.LegacyFiles == null || setup.LegacyFiles.Count == 0)) throw new InvalidDataException("The backup contains no app preferences or profiles.");
        }

        private static Func<string, string> WithCustomIds(Func<string, string> original, List<CustomTweak> tweaks)
        { return delegate(string id) { CustomTweak custom = tweaks.FirstOrDefault(x => String.Equals(x.Id, id, StringComparison.OrdinalIgnoreCase)); return custom == null ? original(id) : custom.Id; }; }

        internal static void Apply(AppState state, PortableSetup setup)
        {
            if (setup.Preferences != null) { var p = setup.Preferences; state.Accent = p.Accent; state.UiFont = p.UiFont; state.InterfaceScale = p.InterfaceScale; state.AutoCheckUpdates = p.AutoCheckUpdates; state.AutoDownloadUpdates = p.AutoDownloadUpdates; state.CleanupDay = p.CleanupDay; state.CleanupTime = p.CleanupTime; state.Toasts = p.Toasts; state.ShowLog = p.ShowLog; state.ScanOnStart = p.ScanOnStart; state.ReduceMotion = p.ReduceMotion; state.AlwaysRestorePoint = p.AlwaysRestorePoint; state.LegacyRestorePointImported = true; state.LegacyBehaviorImported = true; }
            if (setup.Preferences != null) { state.Language = setup.Preferences.Language; state.LegacyLanguageImported = true; }
            if (setup.Preferences != null) state.LegacyCleanupPreferencesImported = true;
            if (setup.Presets != null) state.SavedPresets = setup.Presets;
            if (setup.GamePaths != null) state.GamePaths = setup.GamePaths;
            if (setup.CustomGames != null) state.CustomGames = setup.CustomGames;
            if (setup.CustomTweaks != null) state.CustomTweaks = setup.CustomTweaks;
            if (setup.GameSessions != null) { state.GameSessions = setup.GameSessions; state.LegacyGameSessionsImported = true; }
            if (setup.SessionHistory != null) {
                var pending = (state.SessionHistory ?? new List<GameSessionReport>()).Where(x => x != null && x.RecoveryPending).ToList();
                state.SessionHistory = pending.Concat(setup.SessionHistory.OrderByDescending(x => x.StartedUtc)).GroupBy(x => x.Id, StringComparer.OrdinalIgnoreCase).Select(x => x.First()).Take(50).ToList();
                state.LegacySessionHistoryImported = true;
            }
            if (setup.IncludesBenchmarks) { state.BenchBefore = setup.BenchBefore; state.BenchAfter = setup.BenchAfter; state.BenchmarkRuns = setup.BenchmarkRuns ?? new List<BenchmarkRun>(); state.LegacyBenchmarksImported = true; }
            if (setup.CleanupHistory != null) { state.CleanupHistory = setup.CleanupHistory.OrderByDescending(x => x.TimeUtc).Take(50).ToList(); state.LegacyCleanupHistoryImported = true; }
            if (setup.LegacyFiles != null) { state.LegacyBackupFiles = setup.LegacyFiles; if (setup.SessionHistory == null && setup.LegacyFiles.ContainsKey("game-session-history.json")) state.LegacySessionHistoryImported = false; if (setup.CleanupHistory == null && setup.LegacyFiles.ContainsKey("boost-history.json")) state.LegacyCleanupHistoryImported = false; }
            // Applied tweaks, captured undo values, and session recovery metadata are never assigned.
        }
    }

    internal sealed partial class MainWindow
    {
        private UIElement BuildBackupCard()
        {
            var card = Card(); var body = new StackPanel(); body.Children.Add(Text("Setup backup", 16, System.Windows.Media.Brushes.White, true));
            body.Children.Add(Text("Keep a portable copy of your preferences, presets, game profiles, and benchmark snapshots. Importing does not apply Windows changes or replace your undo history. Cleanup schedule preferences are included; importing does not create a scheduled task.", 11, Brush(MutedColor), false, 0, 5));
            var buttons = new WrapPanel { Margin = new Thickness(-5, 10, 0, 0) }; var export = ActionButton("Export setup backup", false); export.Click += delegate { ExportSetupBackup(); }; var import = ActionButton("Import setup backup", false); import.Click += delegate { ImportSetupBackup(); }; buttons.Children.Add(export); buttons.Children.Add(import); body.Children.Add(buttons); card.Child = body; return card;
        }

        private void ExportSetupBackup()
        {
            var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "SharkOptimizer backup (*.json)|*.json", FileName = "SharkOptimizer-Backup.json" }; if (LocalizedFileDialog.Show(dialog, this) != true) return;
            try { File.WriteAllText(dialog.FileName, SetupBackupCodec.Encode(SetupBackupCodec.Capture(_state), ExportPresetId), new UTF8Encoding(false)); MessageBox.Show(this, "Setup backup saved.", "Backup exported", MessageBoxButton.OK, MessageBoxImage.Information); }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, "Backup export failed", MessageBoxButton.OK, MessageBoxImage.Warning); }
        }

        private void ImportSetupBackup()
        {
            var dialog = new Microsoft.Win32.OpenFileDialog { Filter = "SharkOptimizer backup (*.json)|*.json" }; if (LocalizedFileDialog.Show(dialog, this) != true) return;
            try
            {
                if (new FileInfo(dialog.FileName).Length > 4 * 1024 * 1024) throw new InvalidDataException("Setup backups must be no larger than 4 MB.");
                PortableSetup incoming = SetupBackupCodec.Decode(File.ReadAllText(dialog.FileName), MapLegacyTweakId); var sections = new List<string>();
                if (incoming.CustomGames != null && incoming.CustomGames.Any(x => GameProfiles.Any(y => String.Equals(x.Id, y.Id, StringComparison.OrdinalIgnoreCase)))) throw new InvalidDataException("A custom game uses the ID of a built-in profile. Rename its ID before importing.");
                if (incoming.Preferences != null) sections.Add("Preferences and appearance"); if (incoming.Presets != null) sections.Add(incoming.Presets.Count + " saved presets");
                if (incoming.GamePaths != null || incoming.CustomGames != null) sections.Add("Game library and custom profiles"); if (incoming.IncludesBenchmarks) sections.Add("Benchmark snapshots");
                if (incoming.CustomTweaks != null) sections.Add(incoming.CustomTweaks.Count + " custom registry definitions; adding definitions does not apply their values.");
                if (incoming.GameSessions != null) sections.Add("Saved Game Boost profiles and protected apps. Importing does not start a session.");
                if (incoming.SessionHistory != null) sections.Add(incoming.SessionHistory.Count + " archived session reports. Current reports with pending recovery are kept.");
                if (incoming.CleanupHistory != null) sections.Add(incoming.CleanupHistory.Count + " cleanup history entries");
                if (MessageBox.Show(this, "Replace the included app data? Current Windows changes and undo records are kept.\n\n" + String.Join(Environment.NewLine, sections.Select(x => "• " + Localization.Translate(x)).ToArray()) + "\n\nThe previous native state is backed up before replacement. Restart the app after importing.", "Review setup backup", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
                PortableSetup previous = SetupBackupCodec.Capture(_state);
                bool previousHistoryImported = _state.LegacySessionHistoryImported;
                bool previousCleanupImported = _state.LegacyCleanupHistoryImported;
                try { SetupBackupCodec.Apply(_state, incoming); SaveState(); }
                catch { SetupBackupCodec.Apply(_state, previous); _state.SessionHistory = previous.SessionHistory ?? new List<GameSessionReport>(); _state.LegacySessionHistoryImported = previousHistoryImported; _state.LegacyCleanupHistoryImported = previousCleanupImported; throw; }
                _editingPreset = null; RefreshPresetEditStatus();
                MessageBox.Show(this, "Backup imported. Exit SharkOptimizer from the tray menu, then reopen it to load the restored preferences and profiles.", "Backup imported", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, "Backup import failed", MessageBoxButton.OK, MessageBoxImage.Warning); }
        }
    }
}
