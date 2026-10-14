using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Diagnostics.Eventing.Reader;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Management;
using System.ServiceProcess;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shell;
using System.Windows.Threading;
using Microsoft.Win32;

 [assembly: AssemblyTitle("SharkOptimizer")]
 [assembly: AssemblyProduct("SharkOptimizer")]
 [assembly: AssemblyCompany("Bas Makes Stuff")]
 [assembly: AssemblyVersion("2.0.0.0")]
 [assembly: AssemblyFileVersion("2.0.0.0")]

namespace SharkOptimizer.NativeApp
{

    internal static class App
    {
        [STAThread]
        private static void Main()
        {
            if (Environment.GetCommandLineArgs().Any(x => String.Equals(x, "--weekly-cleanup", StringComparison.OrdinalIgnoreCase)))
            { MainWindow.RunScheduledCleanup(); return; }
            bool tray = Environment.GetCommandLineArgs().Any(x => String.Equals(x, "--tray", StringComparison.OrdinalIgnoreCase));
            bool reducedMotion = MainWindow.PreferReducedMotion();
            Localization.SetLanguage(MainWindow.SavedLanguagePreference());
            string sid; using (var identity = System.Security.Principal.WindowsIdentity.GetCurrent()) sid = identity.User.Value;
            string instanceName = "Local\\SharkOptimizer.Native." + sid, showName = instanceName + ".Show"; bool ownsInstance;
            using (var instance = new System.Threading.Mutex(true, instanceName, out ownsInstance))
            {
            if (!ownsInstance) {
                if (!tray) try { using (var signal = System.Threading.EventWaitHandle.OpenExisting(showName)) signal.Set(); } catch { }
                return;
            }
            using (var showSignal = new System.Threading.EventWaitHandle(false, System.Threading.EventResetMode.AutoReset, showName))
            {
            var app = new Application();
            app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            bool openRequested = false;
            var listener = System.Threading.ThreadPool.RegisterWaitForSingleObject(showSignal, delegate(object state, bool timedOut) {
                if (!app.Dispatcher.HasShutdownStarted) app.Dispatcher.BeginInvoke(new Action(delegate { var main = app.MainWindow as MainWindow; if (main != null) main.OpenFromShortcut(); else openRequested = true; }));
            }, null, -1, false);
            try {
            if (tray || reducedMotion) {
                app.Startup += delegate {
                    try { var main = new MainWindow(); app.MainWindow = main; app.ShutdownMode = ShutdownMode.OnMainWindowClose; if (tray) main.StartInTray(); else main.Show(); if (openRequested) main.OpenFromShortcut(); }
                    catch (Exception ex) { MessageBox.Show("SharkOptimizer could not start in the tray.\n\n" + ex.Message, "Startup error", MessageBoxButton.OK, MessageBoxImage.Error); app.Shutdown(); }
                };
                app.Run(); return;
            }
            var splash = new StartupWindow();
            splash.Loaded += delegate
            {
                var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1450) };
                timer.Tick += delegate
                {
                    timer.Stop();
                    try
                    {
                        var main = new MainWindow(); app.MainWindow = main; app.ShutdownMode = ShutdownMode.OnMainWindowClose;
                        main.Opacity = 0; splash.Topmost = true; main.Show();
                        var reveal = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(420)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
                        reveal.Completed += delegate { main.BeginAnimation(Window.OpacityProperty, null); main.Opacity = 1; };
                        main.BeginAnimation(Window.OpacityProperty, reveal);
                        var dismiss = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(240)); dismiss.Completed += delegate { splash.Close(); };
                        splash.BeginAnimation(Window.OpacityProperty, dismiss);
                    }
                    catch (Exception ex) { MessageBox.Show("SharkOptimizer could not finish starting." + Environment.NewLine + Environment.NewLine + ex.Message, "Startup error", MessageBoxButton.OK, MessageBoxImage.Error); app.Shutdown(); }
                };
                timer.Start();
            };
            app.Run(splash);
            } finally { listener.Unregister(null); }
            }
            }
        }
    }

    internal sealed class StartupWindow : Window
    {
        private static readonly string[] Tips = {
            "Game Mode prioritizes your game while you play.",
            "Compare DNS response times in the Network tab.",
            "Restore tracks tweaks so you can undo them later.",
            "Background recording can cause frame-time spikes.",
            "Some Windows changes need a restart to take effect.",
            "Choose tweaks that fit your hardware and setup."
        };
        private readonly DispatcherTimer _tipTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        private readonly TextBlock _tipText;
        private int _tipIndex = -1;
        private void AdvanceTip()
        {
            _tipIndex = (_tipIndex + 1) % Tips.Length;
            _tipText.Text = Localization.Translate(Tips[_tipIndex]);
        }
        private static SolidColorBrush Solid(byte r, byte g, byte b) { var brush = new SolidColorBrush(Color.FromRgb(r, g, b)); brush.Freeze(); return brush; }
        private static TextBlock Label(string text, double size, Brush color, FontWeight weight)
        { return new TextBlock { Text = text, FontSize = size, Foreground = color, FontWeight = weight, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center }; }

        public StartupWindow()
        {
            Width = 440; Height = 286; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; AllowsTransparency = true;
            Background = Brushes.Transparent; ShowInTaskbar = false; WindowStartupLocation = WindowStartupLocation.CenterScreen; Opacity = 0;
            var outer = new Border { Background = Solid(8, 15, 27), BorderBrush = Solid(34, 51, 75), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(22), Padding = new Thickness(28) };
            var content = new Grid(); content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(84) }); content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var logo = new Border { Width = 64, Height = 64, CornerRadius = new CornerRadius(22), Background = Solid(31, 182, 255), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, RenderTransformOrigin = new Point(.5, .5), RenderTransform = new ScaleTransform(.72, .72), Opacity = 0 };
            logo.Background = Brushes.Transparent; logo.Child = BrandAssets.Image(64);
            content.Children.Add(logo);
            var title = Label("SharkOptimizer", 23, Brushes.White, FontWeights.SemiBold); title.Margin = new Thickness(0, 5, 0, 0); Grid.SetRow(title, 1); content.Children.Add(title);
            var subtitle = Label("A smoother PC starts here.", 12, Solid(140, 156, 180), FontWeights.Normal); subtitle.Margin = new Thickness(0, 5, 0, 0); Grid.SetRow(subtitle, 2); content.Children.Add(subtitle);
            _tipText = Label("", 10, Solid(140, 156, 180), FontWeights.Normal); _tipText.TextWrapping = TextWrapping.Wrap; _tipText.MaxWidth = 340; _tipText.VerticalAlignment = VerticalAlignment.Center; _tipText.Margin = new Thickness(0, 8, 0, 8); Grid.SetRow(_tipText, 3); content.Children.Add(_tipText);
            AdvanceTip(); _tipTimer.Tick += delegate { AdvanceTip(); }; Closed += delegate { _tipTimer.Stop(); };
            var track = new Border { Height = 4, Width = 300, CornerRadius = new CornerRadius(2), Background = Solid(24, 37, 56), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, ClipToBounds = true };
            var progress = new Border { Height = 4, Width = 0, CornerRadius = new CornerRadius(2), Background = Solid(31, 182, 255), HorizontalAlignment = HorizontalAlignment.Left };
            track.Child = progress; Grid.SetRow(track, 4); content.Children.Add(track);
            var version = Label("Version 2.0.0", 9, Solid(92, 109, 134), FontWeights.Bold); version.Margin = new Thickness(0, 10, 0, 0); Grid.SetRow(version, 5); content.Children.Add(version);
            outer.Child = content; Content = outer;
            Localization.Apply(outer);
            Loaded += delegate
            {
                _tipTimer.Start();
                BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(360)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
                var scale = (ScaleTransform)logo.RenderTransform;
                scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(.72, 1, TimeSpan.FromMilliseconds(650)) { EasingFunction = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = .24 } });
                scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(.72, 1, TimeSpan.FromMilliseconds(650)) { EasingFunction = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = .24 } });
                logo.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(360)));
                progress.BeginAnimation(WidthProperty, new DoubleAnimation(0, 300, TimeSpan.FromMilliseconds(1250)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut } });
            };
        }
    }

    internal sealed class RegValueChange
    {
        public string Hive { get; set; }
        public string KeyPath { get; set; }
        public string Name { get; set; }
        public bool Existed { get; set; }
        public string Kind { get; set; }
        public object Value { get; set; }
        public string TargetKind { get; set; }
        public object TargetValue { get; set; }
    }

    internal sealed class AppliedTweak
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public DateTime AppliedAt { get; set; }
        public List<RegValueChange> Values { get; set; }
        public List<ServiceChange> Services { get; set; }
        public List<AdapterChange> Adapters { get; set; }
        public List<AdvancedAdapterChange> AdvancedAdapters { get; set; }
        public List<PowerSettingChange> PowerSettings { get; set; }
        public List<BootSettingChange> BootSettings { get; set; }
        public List<NetshSettingChange> NetshSettings { get; set; }
        public List<ScheduledTaskChange> ScheduledTasks { get; set; }
        public string PreviousPowerPlan { get; set; }
        public string TargetPowerPlan { get; set; }
        public string CreatedPowerPlan { get; set; }
        public bool? OriginalHibernationEnabled { get; set; }
        public bool? OriginalMemoryCompression { get; set; }
    }

    internal sealed class ServiceChange
    {
        public string Name { get; set; }
        public string StartMode { get; set; }
        public bool DelayedAutoStart { get; set; }
        public bool WasRunning { get; set; }
    }

    internal sealed class AdapterChange
    {
        public string Name { get; set; }
        public string Feature { get; set; }
        public bool IPv4Enabled { get; set; }
        public bool IPv6Enabled { get; set; }
        public bool RssEnabled { get; set; }
        public Dictionary<string, bool> PowerStates { get; set; }
        public string[] DnsServers { get; set; }
        public string[] ExpectedDnsServers { get; set; }
    }

    internal sealed class AdvancedAdapterChange
    {
        public string AdapterName { get; set; }
        public string DisplayName { get; set; }
        public string RegistryKeyword { get; set; }
        public string RegistryDataType { get; set; }
        public string[] OriginalRegistryValue { get; set; }
        public string[] TargetRegistryValue { get; set; }
        public string LegacyDisplayValue { get; set; }
    }

    internal sealed class PowerSettingChange
    {
        public string SchemeGuid { get; set; }
        public string SubgroupGuid { get; set; }
        public string SettingGuid { get; set; }
        public uint OriginalAc { get; set; }
        public uint OriginalDc { get; set; }
        public uint TargetAc { get; set; }
        public uint TargetDc { get; set; }
        public bool SetAc { get; set; }
        public bool SetDc { get; set; }
    }

    internal sealed class PowerTarget
    {
        public string SubgroupGuid;
        public string SettingGuid;
        public uint TargetAc;
        public uint TargetDc;
        public bool SetAc;
        public bool SetDc;
        public PowerTarget(string subgroup, string setting, uint ac, uint dc, bool setAc, bool setDc)
        { SubgroupGuid = subgroup; SettingGuid = setting; TargetAc = ac; TargetDc = dc; SetAc = setAc; SetDc = setDc; }
    }

    internal sealed class BootSettingChange
    {
        public string Name { get; set; }
        public string OriginalValue { get; set; }
        public string TargetValue { get; set; }
        public bool Existed { get; set; }
    }

    internal sealed class BootTarget
    {
        public string Name;
        public string Value;
        public BootTarget(string name, string value) { Name = name; Value = value; }
    }

    internal sealed class NetshSettingChange
    {
        public string Name { get; set; }
        public string OriginalValue { get; set; }
        public string TargetValue { get; set; }
    }

    internal sealed class NetshTarget
    {
        public string Name;
        public string Target;
        public NetshTarget(string name, string target) { Name = name; Target = target; }
    }

    internal sealed class ScheduledTaskChange
    {
        public string Path { get; set; }
        public bool OriginalEnabled { get; set; }
        public bool TargetEnabled { get; set; }
    }

    internal sealed class AppState
    {
        public int Schema { get; set; }
        public int LegacyUndoImportVersion { get; set; }
        public List<AppliedTweak> Applied { get; set; }
        public Dictionary<string, List<string>> GamePaths { get; set; }
        public List<GameDefinition> CustomGames { get; set; }
        public string SessionPreviousPlan { get; set; }
        public BenchSnapshot BenchBefore { get; set; }
        public BenchSnapshot BenchAfter { get; set; }
        public string CleanupDay { get; set; }
        public string CleanupTime { get; set; }
        public bool LegacyCleanupPreferencesImported { get; set; }
        public string Accent { get; set; }
        public string UiFont { get; set; }
        public double InterfaceScale { get; set; }
        public bool AutoCheckUpdates { get; set; }
        public bool AutoDownloadUpdates { get; set; }
        public bool AlwaysRestorePoint { get; set; }
        public bool LegacyRestorePointImported { get; set; }
        public List<UserPreset> SavedPresets { get; set; }
        public bool LegacyPresetsImported { get; set; }
        public Dictionary<string, string> LegacyBackupFiles { get; set; }
        public List<CustomTweak> CustomTweaks { get; set; }
        public bool LegacyCustomTweaksImported { get; set; }
        public bool GuideSeen { get; set; }
        public GameSessionStore GameSessions { get; set; }
        public bool LegacyGameSessionsImported { get; set; }
        public bool LegacySessionHistoryImported { get; set; }
        public List<SessionPriorityChange> SessionPriorities { get; set; }
        public bool SessionUpdateResume { get; set; }
        public GameSessionReport ActiveSessionReport { get; set; }
        public List<GameSessionReport> SessionHistory { get; set; }
        public List<BenchmarkRun> BenchmarkRuns { get; set; }
        public bool LegacyBenchmarksImported { get; set; }
        public bool Toasts { get; set; }
        public bool ShowLog { get; set; }
        public bool ScanOnStart { get; set; }
        public bool ReduceMotion { get; set; }
        public bool LegacyBehaviorImported { get; set; }
        public string Language { get; set; }
        public bool LegacyLanguageImported { get; set; }
        public List<string> MaintenanceServices { get; set; }
        public List<CleanupRun> CleanupHistory { get; set; }
        public bool LegacyCleanupHistoryImported { get; set; }
        public AppState() { Schema = 1; Applied = new List<AppliedTweak>(); MaintenanceServices = new List<string>(); GamePaths = new Dictionary<string, List<string>>(); CustomGames = new List<GameDefinition>(); SavedPresets = new List<UserPreset>(); CleanupDay = "SUN"; CleanupTime = "20:00"; Accent = "blue"; UiFont = "Poppins"; InterfaceScale = 1; AutoCheckUpdates = true; AutoDownloadUpdates = true; Toasts = true; ShowLog = true; }
    }

    internal sealed class BenchSnapshot
    {
        public DateTime CapturedAt { get; set; }
        public double PingMs { get; set; }
        public double JitterMs { get; set; }
        public double DnsMs { get; set; }
        public double CpuUse { get; set; }
        public double FreeMemoryMb { get; set; }
        public double RamUsedPercent { get; set; }
        public int ProcessCount { get; set; }
        public int ServicesRunning { get; set; }
        public double BootSeconds { get; set; }
    }

    internal sealed class CleanupTarget
    {
        public string Name;
        public string Path;
        public int MinimumAgeDays;
        public CleanupTarget(string name, string path, int minimumAgeDays) { Name = name; Path = path; MinimumAgeDays = minimumAgeDays; }
    }

    internal sealed class StartupEntry
    {
        public RegistryHive Hive;
        public string Name;
        public StartupEntry(RegistryHive hive, string name) { Hive = hive; Name = name; }
    }

    internal sealed class StartupFolderEntry
    {
        public string Path;
        public bool IsDisabled;
        public StartupFolderEntry(string path, bool isDisabled) { Path = path; IsDisabled = isDisabled; }
    }

    internal sealed class UpdateReleaseInfo
    {
        public Version Version;
        public string AssetUrl;
        public string AssetDigest;
        public long AssetSize;
        public string ReleaseUrl;
    }

    internal sealed class GameDefinition
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string AntiCheat { get; set; }
        public List<string> Executables { get; set; }
        public List<string> Tips { get; set; }
        public List<string> RecommendedTweaks { get; set; }
        public bool IsCustom { get; set; }
    }

    internal sealed class TweakDefinition
    {
        public string Id;
        public string Name;
        public string Category;
        public string Description;
        public string Risk;
        public string Warning;
        public List<ValueTarget> Targets;
        public Func<List<ValueTarget>> TargetFactory;
        public string AdapterFeature;
        public string AdapterAdvancedFeature;
        public List<PowerTarget> PowerTargets = new List<PowerTarget>();
        public List<BootTarget> BootTargets = new List<BootTarget>();
        public List<NetshTarget> NetshTargets = new List<NetshTarget>();
        public List<string> ScheduledTaskTargets = new List<string>();
        public string PowerPlanMode;
        public bool DisableHibernation;
        public bool DisableMemoryCompression;
        public List<string> ServiceNames = new List<string>();
        public TweakDefinition(string id, string name, string category, string description, string risk, string warning, params ValueTarget[] targets)
        {
            Id = id; Name = name; Category = category; Description = description; Risk = risk; Warning = warning; Targets = new List<ValueTarget>(targets);
        }
        public List<ValueTarget> ResolveTargets()
        { var result = new List<ValueTarget>(Targets); if (TargetFactory != null) result.AddRange(TargetFactory()); return result; }
    }

    internal sealed class ValueTarget
    {
        public RegistryHive Hive; public string KeyPath; public string Name; public object Value; public RegistryValueKind Kind;
        public ValueTarget(string keyPath, string name, object value, RegistryValueKind kind) : this(RegistryHive.CurrentUser, keyPath, name, value, kind) { }
        public ValueTarget(RegistryHive hive, string keyPath, string name, object value, RegistryValueKind kind) { Hive = hive; KeyPath = keyPath; Name = name; Value = value; Kind = kind; }
    }

    internal sealed partial class MainWindow : Window
    {
        private static readonly Color BackgroundColor = Color.FromRgb(8, 15, 27);
        private static readonly Color SurfaceColor = Color.FromRgb(15, 25, 42);
        private static readonly Color SurfaceRaised = Color.FromRgb(21, 34, 55);
        private static readonly Color BorderColor = Color.FromRgb(34, 51, 75);
        private static readonly Color MutedColor = Color.FromRgb(140, 156, 180);
        private static readonly Color AccentColor = Color.FromRgb(31, 182, 255);
        private sealed class AccentPalette : DependencyObject
        {
            public static readonly DependencyProperty AccentProperty = DependencyProperty.Register("Accent", typeof(Color), typeof(AccentPalette), new PropertyMetadata(Color.FromRgb(31, 182, 255)));
            public static readonly DependencyProperty NavFillProperty = DependencyProperty.Register("NavFill", typeof(Color), typeof(AccentPalette), new PropertyMetadata(Color.FromRgb(17, 43, 65)));
            public static readonly DependencyProperty NavBorderProperty = DependencyProperty.Register("NavBorder", typeof(Color), typeof(AccentPalette), new PropertyMetadata(Color.FromRgb(27, 69, 98)));
            public Color Accent { get { return (Color)GetValue(AccentProperty); } set { SetValue(AccentProperty, value); } }
            public Color NavFill { get { return (Color)GetValue(NavFillProperty); } set { SetValue(NavFillProperty, value); } }
            public Color NavBorder { get { return (Color)GetValue(NavBorderProperty); } set { SetValue(NavBorderProperty, value); } }
        }

        private static readonly AccentPalette LivePalette = new AccentPalette();
        private static readonly SolidColorBrush LiveAccentBrush = PaletteBrush("Accent");
        private static readonly SolidColorBrush LiveNavFill = PaletteBrush("NavFill");
        private static readonly SolidColorBrush LiveNavBorder = PaletteBrush("NavBorder");

        private static SolidColorBrush PaletteBrush(string property)
        {
            var brush = new SolidColorBrush();
            // A bound Color cannot be frozen when WPF seals a style using this brush.
            BindingOperations.SetBinding(brush, SolidColorBrush.ColorProperty, new Binding(property) { Source = LivePalette, Mode = BindingMode.OneWay });
            return brush;
        }
        private static readonly Dictionary<string, Color> AccentOptions = new Dictionary<string, Color> {
            { "blue", AccentColor }, { "green", Color.FromRgb(34, 211, 166) },
            { "purple", Color.FromRgb(167, 139, 250) }, { "orange", Color.FromRgb(255, 159, 26) }
        };
        private readonly string _dataPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SharkOptimizer", "native-state.json");
        private readonly JavaScriptSerializer _json = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024, RecursionLimit = 64 };
        private readonly object _stateSaveLock = new object();
        private bool _preserveRejectedStateOnSave;
        private string _nativeStateNotice;
        private readonly AppState _state;
        private bool _legacyStateMigrated;
        private string _legacyHistoryNotice;
        private readonly Dictionary<string, Border> _pages = new Dictionary<string, Border>();
        private readonly Dictionary<string, Func<UIElement>> _pageFactories = new Dictionary<string, Func<UIElement>>();
        private readonly HashSet<string> _loadedPages = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, Button> _navButtons = new Dictionary<string, Button>();
        private readonly Dictionary<string, Border> _navIndicators = new Dictionary<string, Border>();
        private readonly Dictionary<string, System.Windows.Shapes.Path> _navIcons = new Dictionary<string, System.Windows.Shapes.Path>();
        private readonly List<CheckBox> _checks = new List<CheckBox>();
        private readonly HashSet<string> _selectedTweaks = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private readonly TextBlock _pageTitle = new TextBlock();
        private readonly TextBlock _pageSubtitle = new TextBlock();
        private TextBox _tweakSearch;
        private DispatcherTimer _tweakSearchTimer;
        private ComboBox _categoryFilter;
        private ComboBox _presetPicker;
        private Button _applyButton;
        private StackPanel _gameList;
        private StackPanel _gameDetail;
        private TextBlock _gameStatus;
        private Button _scanGamesButton;
        private string _selectedGameId;
        private ComboBox _sessionGamePicker;
        private StackPanel _sessionProcessList;
        private TextBlock _sessionStatus;
        private CheckBox _sessionUsePerformancePlan;
        private Button _sessionStartButton;
        private Button _sessionEndButton;
        private readonly List<CheckBox> _sessionProcessChecks = new List<CheckBox>();
        private DispatcherTimer _sessionTimer;
        private string _sessionProcessName;
        private string _sessionPlanNotice;
        private DateTime _sessionStarted;
        private bool _sessionSawGame;
        private int _sessionMissingChecks;
        private StackPanel _restoreList = new StackPanel();
        private StackPanel _tweakList = new StackPanel();
        private StackPanel _cleanupList;
        private TextBlock _cleanupStatus;
        private TextBlock _cleanupScheduleStatus;
        private ComboBox _cleanupDayPicker;
        private TextBox _cleanupTimeEntry;
        private StackPanel _processList;
        private StackPanel _startupList;
        private Dictionary<string, Button> _accentChoices = new Dictionary<string, Button>();
        private StackPanel _optionalAppList;
        private TextBlock _optionalAppStatus;
        private CheckBox _optionalAppsAllUsers;
        private Button _optionalAppScan;
        private Button _optionalAppRemove;
        private bool _optionalAppsBusy;
        private List<OptionalAppPackage> _optionalPackages = new List<OptionalAppPackage>();
        private Button _updateButton;
        private Button _updateReadyButton;
        private TextBlock _updateStatus;
        private DispatcherTimer _updateCheckTimer;
        private bool _checkingUpdates;
        private bool _updateInstallPreparing, _deferredUpdateCheck;
        private TextBox _networkHost;
        private TextBox _networkOutput;
        private TextBlock _labStatus;
        private Button _benchBeforeButton;
        private Button _benchAfterButton;
        private readonly List<TweakDefinition> _catalogue;
        private const string CleanupTaskName = "SharkOptimizer Weekly Cleanup";
        private System.Windows.Forms.NotifyIcon _trayIcon;
        private System.Drawing.Icon _trayIconImage;
        private bool _allowExit;
        private static readonly Version CurrentAppVersion = new Version(2, 0, 0);

        [DllImport("powrprof.dll", SetLastError = true)] private static extern uint PowerGetActiveScheme(IntPtr userRootPowerKey, out IntPtr activePolicyGuid);
        [DllImport("powrprof.dll", SetLastError = true)] private static extern uint PowerReadACValueIndex(IntPtr userRootPowerKey, ref Guid schemeGuid, ref Guid subgroupGuid, ref Guid settingGuid, out uint valueIndex);
        [DllImport("powrprof.dll", SetLastError = true)] private static extern uint PowerReadDCValueIndex(IntPtr userRootPowerKey, ref Guid schemeGuid, ref Guid subgroupGuid, ref Guid settingGuid, out uint valueIndex);
        [DllImport("powrprof.dll", SetLastError = true)] private static extern uint PowerWriteACValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subgroupGuid, ref Guid settingGuid, uint valueIndex);
        [DllImport("powrprof.dll", SetLastError = true)] private static extern uint PowerWriteDCValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subgroupGuid, ref Guid settingGuid, uint valueIndex);
        [DllImport("powrprof.dll", SetLastError = true)] private static extern uint PowerSetActiveScheme(IntPtr userRootPowerKey, ref Guid schemeGuid);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr LocalFree(IntPtr memory);

        private static TweakDefinition WithServices(TweakDefinition tweak, params string[] names)
        { tweak.ServiceNames.AddRange(names); return tweak; }

        private static TweakDefinition ServiceTweak(string id, string name, string category, string description, string risk, string warning, params string[] services)
        { return WithServices(new TweakDefinition(id, name, category, description, risk, warning), services); }

        private static TweakDefinition WithDynamicTargets(TweakDefinition tweak, Func<List<ValueTarget>> factory)
        { tweak.TargetFactory = factory; return tweak; }

        private static long SystemRamBytes()
        {
            try { using (var search = new ManagementObjectSearcher("SELECT TotalPhysicalMemory FROM Win32_ComputerSystem")) using (ManagementObjectCollection rows = search.Get()) { ManagementObject row = rows.Cast<ManagementObject>().FirstOrDefault(); if (row != null) using (row) return Convert.ToInt64(row["TotalPhysicalMemory"]); } } catch { }
            return 0;
        }

        private static TweakDefinition AdapterTweak(string id, string name, string description, string warning, string feature)
        { return new TweakDefinition(id, name, "Network", description, "Caution", warning) { AdapterFeature = feature }; }

        private static TweakDefinition AdvancedAdapterTweak(string id, string name, string description, string warning, string feature)
        { return new TweakDefinition(id, name, "Network", description, "Caution", warning) { AdapterAdvancedFeature = feature }; }

        private static TweakDefinition PowerTweak(string id, string name, string description, string risk, string warning, params PowerTarget[] targets)
        { var tweak = new TweakDefinition(id, name, "Performance", description, risk, warning); tweak.PowerTargets.AddRange(targets); return tweak; }

        private static TweakDefinition BootTweak(string id, string name, string description, string risk, string warning, params BootTarget[] targets)
        { var tweak = new TweakDefinition(id, name, "Advanced", description, risk, warning); tweak.BootTargets.AddRange(targets); return tweak; }

        private static TweakDefinition NetshTweak(string id, string name, string description, string warning, params NetshTarget[] targets)
        { var tweak = new TweakDefinition(id, name, "Network", description, "Caution", warning); tweak.NetshTargets.AddRange(targets); return tweak; }

        private static TweakDefinition ScheduledTaskTweak(string id, string name, string description, string warning, params string[] tasks)
        { var tweak = new TweakDefinition(id, name, "Privacy", description, "Personal choice", warning); tweak.ScheduledTaskTargets.AddRange(tasks); return tweak; }

        private static TweakDefinition UltimatePlanTweak()
        { return new TweakDefinition("ultimate-performance-plan", "Use Ultimate Performance plan", "Performance", "Creates a dedicated Ultimate Performance plan and keeps the current plan for undo.", "Caution", "Uses more power and heat, especially on laptops. The prior active power plan is saved and restored when undone.") { PowerPlanMode = "ultimate" }; }

        private static readonly string[] AdapterPowerCapabilities = new string[] { "ArpOffload", "D0PacketCoalescing", "DeviceSleepOnDisconnect", "NSOffload", "RsnRekeyOffload", "SelectiveSuspend", "WakeOnMagicPacket", "WakeOnPattern" };

        private static List<ValueTarget> ActiveTcpInterfaceTargets(string valueName, int value)
        {
            var targets = new List<ValueTarget>();
            foreach (NetworkInterface adapter in NetworkInterface.GetAllNetworkInterfaces().Where(x => x.OperationalStatus == OperationalStatus.Up && (x.NetworkInterfaceType == NetworkInterfaceType.Ethernet || x.NetworkInterfaceType == NetworkInterfaceType.Wireless80211)))
            {
                Guid id; if (!Guid.TryParse(adapter.Id, out id)) continue;
                string path = @"SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\" + id.ToString("B");
                try { using (RegistryKey key = Registry.LocalMachine.OpenSubKey(path, false)) { if (key != null) targets.Add(new ValueTarget(RegistryHive.LocalMachine, path, valueName, value, RegistryValueKind.DWord)); } } catch { }
            }
            return targets;
        }

        private static List<ValueTarget> DisplayMsiTargets()
        {
            var targets = new List<ValueTarget>();
            using (var search = new ManagementObjectSearcher(@"root\CIMV2", "SELECT PNPDeviceID FROM Win32_VideoController WHERE PNPDeviceID IS NOT NULL"))
            using (ManagementObjectCollection rows = search.Get()) foreach (ManagementObject row in rows) using (row)
            {
                string deviceId = Convert.ToString(row["PNPDeviceID"]); if (String.IsNullOrWhiteSpace(deviceId)) continue;
                string path = @"SYSTEM\CurrentControlSet\Enum\" + deviceId + @"\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties";
                targets.Add(new ValueTarget(RegistryHive.LocalMachine, path, "MSISupported", 1, RegistryValueKind.DWord));
            }
            return targets;
        }

        private static readonly TweakDefinition[] Definitions = new TweakDefinition[] {
            new TweakDefinition("game-mode", "Enable Game Mode", "Gaming", "Lets Windows prioritize your game while you play.", "Recommended", "", 
                new ValueTarget(@"Software\Microsoft\GameBar", "AutoGameModeEnabled", 1, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\GameBar", "AllowAutoGameMode", 1, RegistryValueKind.DWord)),
            new TweakDefinition("game-capture", "Disable background recording", "Gaming", "Turns off background Game Bar capture, which can add recording overhead.", "Caution", "Win+G and Windows+Alt+R capture may stop working.",
                new ValueTarget(@"System\GameConfigStore", "GameDVR_Enabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\GameDVR", "AppCaptureEnabled", 0, RegistryValueKind.DWord),
                new ValueTarget(RegistryHive.LocalMachine, @"Software\Policies\Microsoft\Windows\GameDVR", "AllowGameDVR", 0, RegistryValueKind.DWord)),
            new TweakDefinition("file-extensions", "Show file extensions", "Windows", "Displays file endings such as .exe, .png, and .txt in File Explorer.", "Recommended", "", 
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", "HideFileExt", 0, RegistryValueKind.DWord)),
            new TweakDefinition("startup-delay", "Remove startup app delay", "Windows", "Removes the delay Windows adds before starting sign-in apps.", "Recommended", "", 
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize", "StartupDelayInMSec", 0, RegistryValueKind.DWord)),
            new TweakDefinition("disable-widgets-policy", "Disable Windows Widgets", "Windows", "Disables the Windows 11 Widgets board through machine policy.", "Personal choice", "The Widgets board and its web content will be unavailable. This option is for Windows 11.",
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Policies\Microsoft\Dsh", "AllowNewsAndInterests", 0, RegistryValueKind.DWord)),
            new TweakDefinition("remove-teams-chat-icon", "Remove Teams Chat taskbar icon", "Windows", "Hides the Chat button from the Windows 11 taskbar through machine policy.", "Personal choice", "This option is for Windows 11.",
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Policies\Microsoft\Windows\Windows Chat", "ChatIcon", 3, RegistryValueKind.DWord)),
            new TweakDefinition("menu-delay", "Instant menus", "Windows", "Removes the delay before Windows menus open.", "Recommended", "", 
                new ValueTarget(@"Control Panel\Desktop", "MenuShowDelay", "0", RegistryValueKind.String)),
            new TweakDefinition("dark-mode", "Use dark app and Windows theme", "Personalization", "Switches Windows and supported apps to the dark theme.", "Personal choice", "", 
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme", 0, RegistryValueKind.DWord)),
            new TweakDefinition("advertising-id", "Disable Advertising ID", "Privacy", "Stops apps from using your Windows advertising identifier.", "Privacy", "", 
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo", "Enabled", 0, RegistryValueKind.DWord)),
            new TweakDefinition("start-web-search", "Disable web suggestions in Start", "Privacy", "Keeps Start search focused on your PC instead of web suggestions.", "Privacy", "", 
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Search", "BingSearchEnabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Policies\Microsoft\Windows\Explorer", "DisableSearchBoxSuggestions", 1, RegistryValueKind.DWord)),
            new TweakDefinition("activity-history", "Disable activity history", "Privacy", "Stops Windows publishing and uploading your activity timeline.", "Privacy", "", 
                new ValueTarget(RegistryHive.LocalMachine, @"Software\Policies\Microsoft\Windows\System", "EnableActivityFeed", 0, RegistryValueKind.DWord),
                new ValueTarget(RegistryHive.LocalMachine, @"Software\Policies\Microsoft\Windows\System", "PublishUserActivities", 0, RegistryValueKind.DWord),
                new ValueTarget(RegistryHive.LocalMachine, @"Software\Policies\Microsoft\Windows\System", "UploadUserActivities", 0, RegistryValueKind.DWord)),
            new TweakDefinition("feedback-prompts", "Disable feedback prompts", "Privacy", "Stops Windows from periodically asking for feedback.", "Privacy", "", 
                new ValueTarget(@"Software\Microsoft\Siuf\Rules", "NumberOfSIUFInPeriod", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Siuf\Rules", "PeriodInNanoSeconds", 0, RegistryValueKind.DWord)),
            new TweakDefinition("typing-collection", "Limit typing and inking collection", "Privacy", "Restricts Windows collection of handwriting and typing data for personalization.", "Privacy", "", 
                new ValueTarget(@"Software\Microsoft\InputPersonalization", "RestrictImplicitInkCollection", 1, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\InputPersonalization", "RestrictImplicitTextCollection", 1, RegistryValueKind.DWord)),
            new TweakDefinition("clipboard-sync", "Disable clipboard cloud sync", "Privacy", "Stops clipboard history from syncing between your devices.", "Privacy", "Clipboard history will remain available locally.", 
                new ValueTarget(RegistryHive.LocalMachine, @"Software\Policies\Microsoft\Windows\System", "AllowCrossDeviceClipboard", 0, RegistryValueKind.DWord)),
            new TweakDefinition("hide-recent-files", "Hide recent and frequent files", "Windows", "Removes recent files and frequent folders from File Explorer Home and Quick Access.", "Personal choice", "", 
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Explorer", "ShowRecent", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Explorer", "ShowFrequent", 0, RegistryValueKind.DWord)),
            new TweakDefinition("show-hidden-files", "Show hidden files", "Windows", "Makes hidden files and folders visible in File Explorer.", "Personal choice", "Take care when editing hidden system files.", 
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", "Hidden", 1, RegistryValueKind.DWord)),
            new TweakDefinition("open-this-pc", "Open File Explorer to This PC", "Windows", "Opens File Explorer to This PC instead of Home or Quick Access.", "Personal choice", "", 
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", "LaunchTo", 1, RegistryValueKind.DWord)),
            new TweakDefinition("classic-context-menu", "Use classic context menu", "Windows", "Restores the full right-click menu in Windows 11 instead of opening the compact menu first.", "Personal choice", "Windows Explorer may need to restart or you may need to sign out and back in. This only affects Windows 11.",
                new ValueTarget(@"Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32", "", "", RegistryValueKind.String)),
            new TweakDefinition("disable-aero-shake", "Disable Aero Shake", "Windows", "Prevents shaking a window from minimizing other open windows.", "Personal choice", "", 
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", "DisallowShaking", 1, RegistryValueKind.DWord)),
            new TweakDefinition("keyboard-repeat", "Faster keyboard repeat", "Input", "Sets the shortest key-repeat delay and fastest repeat rate in Windows.", "Personal choice", "", 
                new ValueTarget(@"Control Panel\Keyboard", "KeyboardDelay", "0", RegistryValueKind.String),
                new ValueTarget(@"Control Panel\Keyboard", "KeyboardSpeed", "31", RegistryValueKind.String)),
            new TweakDefinition("sticky-keys", "Disable accessibility key pop-ups", "Input", "Disables Sticky Keys, Filter Keys, and Toggle Keys shortcut prompts.", "Personal choice", "This changes the keyboard accessibility shortcut settings.", 
                new ValueTarget(@"Control Panel\Accessibility\StickyKeys", "Flags", "506", RegistryValueKind.String),
                new ValueTarget(@"Control Panel\Accessibility\Keyboard Response", "Flags", "122", RegistryValueKind.String),
                new ValueTarget(@"Control Panel\Accessibility\ToggleKeys", "Flags", "58", RegistryValueKind.String)),
            new TweakDefinition("post-update-welcome", "Skip post-update welcome screens", "Windows", "Hides the Windows welcome and setup prompts shown after feature updates.", "Personal choice", "", 
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement", "ScoobeSystemSettingEnabled", 0, RegistryValueKind.DWord)),
            new TweakDefinition("lightweight-visuals", "Lightweight visual effects", "Performance", "Reduces selected animations and transparency effects in Windows.", "Caution", "Some interface animations and transparency will be disabled.", 
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects", "VisualFXSetting", 2, RegistryValueKind.DWord),
                new ValueTarget(@"Control Panel\Desktop\WindowMetrics", "MinAnimate", "0", RegistryValueKind.String),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "EnableTransparency", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", "TaskbarAnimations", 0, RegistryValueKind.DWord)),
            new TweakDefinition("gamebar-overlay", "Disable Game Bar overlay prompts", "Gaming", "Hides the Game Bar startup prompt and controller shortcut overlay.", "Personal choice", "This does not disable Windows Game Mode.", 
                new ValueTarget(@"Software\Microsoft\GameBar", "UseNexusForGameBarEnabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\GameBar", "ShowStartupPanel", 0, RegistryValueKind.DWord)),
            new TweakDefinition("raw-mouse", "Raw mouse input", "Gaming", "Disables Windows pointer acceleration for more direct mouse movement.", "Caution", "Sign out and back in for the change to take effect.", 
                new ValueTarget(@"Control Panel\Mouse", "MouseSpeed", "0", RegistryValueKind.String),
                new ValueTarget(@"Control Panel\Mouse", "MouseThreshold1", "0", RegistryValueKind.String),
                new ValueTarget(@"Control Panel\Mouse", "MouseThreshold2", "0", RegistryValueKind.String)),
            new TweakDefinition("fullscreen-optimizations", "Adjust fullscreen optimizations", "Gaming", "Changes the Windows fullscreen behavior flags used by some games.", "Caution", "May cause tearing or lower performance in some DirectX 12 games.", 
                new ValueTarget(@"System\GameConfigStore", "GameDVR_FSEBehaviorMode", 2, RegistryValueKind.DWord),
                new ValueTarget(@"System\GameConfigStore", "GameDVR_HonorUserFSEBehaviorMode", 1, RegistryValueKind.DWord),
                new ValueTarget(@"System\GameConfigStore", "GameDVR_DXGIHonorFSEWindowsCompatible", 1, RegistryValueKind.DWord),
                new ValueTarget(@"System\GameConfigStore", "GameDVR_EFSEFeatureFlags", 0, RegistryValueKind.DWord)),
            new TweakDefinition("disable-copilot", "Disable Copilot entry points", "Privacy", "Hides Windows Copilot through the current-user policy setting.", "Personal choice", "This does not uninstall Copilot or remove other AI features.",
                new ValueTarget(@"Software\Policies\Microsoft\Windows\WindowsCopilot", "TurnOffWindowsCopilot", 1, RegistryValueKind.DWord)),
            new TweakDefinition("disable-cortana-cloud-search", "Disable Cortana and cloud search", "Privacy", "Turns off Cortana and cloud search integration through Windows policy settings.", "Personal choice", "Windows search will focus on local results.",
                new ValueTarget(RegistryHive.LocalMachine, @"Software\Policies\Microsoft\Windows\Windows Search", "AllowCortana", 0, RegistryValueKind.DWord),
                new ValueTarget(RegistryHive.LocalMachine, @"Software\Policies\Microsoft\Windows\Windows Search", "AllowCloudSearch", 0, RegistryValueKind.DWord)),
            new TweakDefinition("disable-consumer-suggestions", "Reduce suggested apps", "Privacy", "Stops Windows from promoting suggested consumer apps and content.", "Personal choice", "Windows suggestions and promoted app installs may stop appearing.",
                new ValueTarget(RegistryHive.LocalMachine, @"Software\Policies\Microsoft\Windows\CloudContent", "DisableWindowsConsumerFeatures", 1, RegistryValueKind.DWord),
                new ValueTarget(RegistryHive.LocalMachine, @"Software\Policies\Microsoft\Windows\CloudContent", "DisableSoftLanding", 1, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Policies\Microsoft\Windows\CloudContent", "DisableWindowsSpotlightFeatures", 1, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "SystemPaneSuggestionsEnabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "SubscribedContent-338389Enabled", 0, RegistryValueKind.DWord)),
            new TweakDefinition("remove-windows-ads", "Reduce Windows promotional content", "Privacy", "Turns off common Start, Settings, and lock-screen promotional suggestions for this user.", "Personal choice", "Some Windows tips and suggestions will no longer appear.",
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "SubscribedContent-338387Enabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "SubscribedContent-338388Enabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "SubscribedContent-338389Enabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "SubscribedContent-338393Enabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "SubscribedContent-353694Enabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "SubscribedContent-353696Enabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "SubscribedContent-310093Enabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "SystemPaneSuggestionsEnabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "RotatingLockScreenOverlayEnabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "OemPreInstalledAppsEnabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "PreInstalledAppsEnabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "SilentInstalledAppsEnabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "SoftLandingEnabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "ContentDeliveryAllowed", 0, RegistryValueKind.DWord)),
            new TweakDefinition("disable-windows-ai-capture", "Disable Windows AI activity analysis", "Privacy", "Blocks Windows AI snapshot analysis on supported Windows versions.", "Personal choice", "Windows 11 24H2 or newer. This does not uninstall AI features.",
                new ValueTarget(@"Software\Policies\Microsoft\Windows\WindowsAI", "DisableAIDataAnalysis", 1, RegistryValueKind.DWord)),
            new TweakDefinition("disable-app-inventory", "Limit app inventory collection", "Privacy", "Limits machine-wide app compatibility inventory and Steps Recorder data collection.", "Personal choice", "Windows compatibility diagnostics may have less app information.",
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Policies\Microsoft\Windows\AppCompat", "DisableInventory", 1, RegistryValueKind.DWord),
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Policies\Microsoft\Windows\AppCompat", "DisableUAR", 1, RegistryValueKind.DWord)),
            new TweakDefinition("disable-location-policy", "Disable Windows location access", "Privacy", "Disables Windows location features through machine policy.", "Caution", "Maps, Weather, and Find My Device may stop working.",
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors", "DisableLocation", 1, RegistryValueKind.DWord)),
            new TweakDefinition("disable-update-sharing", "Disable update sharing", "Privacy", "Stops Windows from sharing update downloads with other PCs.", "Personal choice", "Windows will use Microsoft update servers instead of local network peers.",
                new ValueTarget(RegistryHive.LocalMachine, @"Software\Policies\Microsoft\Windows\DeliveryOptimization", "DODownloadMode", 0, RegistryValueKind.DWord)),
            new TweakDefinition("disable-onedrive-policy", "Pause OneDrive sync by policy", "Windows", "Disables OneDrive file sync through Windows policy.", "Caution", "Files already on this PC remain, but OneDrive will stop syncing until you undo this option.",
                new ValueTarget(RegistryHive.LocalMachine, @"Software\Policies\Microsoft\Windows\OneDrive", "DisableFileSyncNGSC", 1, RegistryValueKind.DWord)),
            new TweakDefinition("clean-windows-taskbar", "Simplify Windows 11 taskbar", "Personalization", "Hides Widgets, Task View, and the taskbar search box, and aligns app icons to the left.", "Personal choice", "Designed for Windows 11; unavailable items are ignored by older Windows versions.",
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", "TaskbarAl", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", "TaskbarDa", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", "ShowTaskViewButton", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\Search", "SearchboxTaskbarMode", 0, RegistryValueKind.DWord)),
            new TweakDefinition("faster-app-shutdown", "Reduce shutdown wait", "Windows", "Shortens machine service and user app shutdown waits and enables ending unresponsive apps.", "Caution", "Apps with unsaved work can be closed during shutdown, and slow services may be stopped sooner. Save work before shutting down.",
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control", "WaitToKillServiceTimeout", "2000", RegistryValueKind.String),
                new ValueTarget(@"Control Panel\Desktop", "WaitToKillAppTimeout", "3000", RegistryValueKind.String),
                new ValueTarget(@"Control Panel\Desktop", "HungAppTimeout", "3000", RegistryValueKind.String),
                new ValueTarget(@"Control Panel\Desktop", "AutoEndTasks", "1", RegistryValueKind.String)),
            WithDynamicTargets(new TweakDefinition("merge-service-host-processes", "Merge service host processes", "Windows", "Uses Windows' memory-based service-host grouping threshold on PCs with at least 8 GB RAM.", "Caution", "Requires a restart. If one grouped service crashes, others in its group can stop too."), delegate { long bytes = SystemRamBytes(); if (bytes < 8L * 1024L * 1024L * 1024L) return new List<ValueTarget>(); long threshold = Math.Min(bytes / 1024L, 2147483647L); return new List<ValueTarget> { new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control", "SvcHostSplitThresholdInKB", (int)threshold, RegistryValueKind.DWord) }; }),
            new TweakDefinition("keep-kernel-in-ram", "Keep kernel in RAM", "Windows", "Prevents Windows paging the kernel and drivers out to disk on high-memory PCs.", "Caution", "Requires a restart and uses more physical memory. Intended for systems with at least 16 GB RAM.",
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management", "DisablePagingExecutive", 1, RegistryValueKind.DWord)),
            new TweakDefinition("disable-prefetcher", "Disable Windows prefetch", "Windows", "Turns off the Windows prefetcher and Superfetch preloading.", "Caution", "Requires a restart. Apps may launch more slowly, especially on hard drives.",
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters", "EnablePrefetcher", 0, RegistryValueKind.DWord),
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters", "EnableSuperfetch", 0, RegistryValueKind.DWord)),
            new TweakDefinition("disable-ipv6", "Disable IPv6", "Network", "Disables IPv6 components through the Windows network stack setting.", "Warning", "Some games, Xbox services, VPNs, and internet providers rely on IPv6. Requires a restart; undo restores the previous value.",
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters", "DisabledComponents", 255, RegistryValueKind.DWord)),
            new TweakDefinition("disable-cpu-mitigations", "Disable CPU vulnerability mitigations", "Advanced", "Requests disabling selected CPU vulnerability mitigations through Windows registry settings. Effects depend on the processor and Windows version.", "Warning", "This reduces protection against CPU vulnerabilities. Use only on an isolated gaming PC and restore immediately after testing.",
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management", "FeatureSettingsOverride", 3, RegistryValueKind.DWord),
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management", "FeatureSettingsOverrideMask", 3, RegistryValueKind.DWord)),
            new TweakDefinition("disable-vbs-memory-integrity", "Disable VBS and Memory Integrity", "Advanced", "Disables Virtualization-Based Security and Hypervisor-protected Code Integrity through their Windows policy values.", "Warning", "Reduces kernel protection and can conflict with work policies or anti-cheat requirements. Requires a restart; undo restores the previous values.",
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control\DeviceGuard", "EnableVirtualizationBasedSecurity", 0, RegistryValueKind.DWord),
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity", "Enabled", 0, RegistryValueKind.DWord)),
            PowerTweak("usb-selective-suspend", "Disable USB selective suspend", "Keeps USB devices powered while the PC is on, which can help with intermittent mouse, keyboard, or headset dropouts.", "Personal choice", "Uses more power, especially on laptops. The exact AC and battery values are saved for undo.", new PowerTarget("2a737441-1930-4402-8d77-b2bebba308a3", "48e6b7a6-50f5-4782-a5d4-53bb8f07e226", 0, 0, true, true)),
            PowerTweak("disable-pcie-link-power-saving", "Disable PCIe link power saving", "Keeps PCIe links at full power instead of using Active State Power Management.", "Caution", "Can increase idle power and heat. The exact AC setting is saved for undo.", new PowerTarget("501a4d13-42af-4429-9fd1-a8218c268e20", "ee12f906-d277-404b-b6da-e5fa1a576df5", 0, 0, true, false)),
            PowerTweak("keep-hard-disks-awake", "Keep hard disks awake", "Prevents Windows from powering down disks while the PC is connected to AC power.", "Caution", "Increases power use and drive activity. The exact AC setting is saved for undo.", new PowerTarget("0012ee47-9041-4b5d-9b77-535fba8b1442", "6738e2c4-e8a5-4a42-b16a-e040e769756e", 0, 0, true, false)),
            PowerTweak("maximum-cpu-minimum-state", "Set minimum CPU state to 100%", "Requests a 100% minimum processor state in the active power plan while plugged in. Actual clock speed depends on hardware and other power controls.", "Warning", "Can increase idle temperatures and power draw. Intended for desktop PCs; avoid on laptops. The previous AC setting is saved for undo.", new PowerTarget("54533251-82be-4824-96c1-47b60b740d00", "893dee8e-2bef-41e0-89c6-b55d0929964c", 100, 0, true, false)),
            PowerTweak("wifi-maximum-performance", "Wi-Fi maximum performance", "Sets the wireless adapter power-saving mode to maximum performance on AC and battery.", "Caution", "Can noticeably reduce laptop battery life. The exact AC and battery values are saved for undo.", new PowerTarget("19cbb8fa-5279-450e-9fac-8a3d5fedd0c1", "12bbebe6-58d6-4636-95bb-3217ef867c1a", 0, 0, true, true)),
            UltimatePlanTweak(),
            new TweakDefinition("disable-hibernation", "Disable hibernation", "Windows", "Turns off Windows hibernation and removes its hibernation file.", "Caution", "Hibernate and Fast Startup stop working until you undo this. The previous hibernation state is saved.") { DisableHibernation = true },
            new TweakDefinition("disable-memory-compression", "Disable memory compression", "Performance", "Turns off RAM page compression through the Windows memory-management provider.", "Caution", "For PCs with at least 16 GB RAM. Memory pressure can increase and performance can get worse when RAM fills up. Compare your workload and undo if needed; a restart may be required.") { DisableMemoryCompression = true },
            WithDynamicTargets(new TweakDefinition("gpu-msi-mode", "Enable GPU MSI mode", "Advanced", "Enables Message Signaled Interrupts for detected display devices when the driver exposes that registry option.", "Caution", "Requires a restart. An unsupported GPU or driver may cause a black screen; create a Windows restore point first. Only detected display devices are changed and each previous value is saved."), DisplayMsiTargets),
            BootTweak("disable-dynamic-tick", "Disable dynamic tick", "Enables constant timer interrupts through Windows Boot Configuration.", "Caution", "May increase idle power use and heat. Requires a restart; the exact prior boot setting is saved for undo.", new BootTarget("disabledynamictick", "Yes")),
            BootTweak("disable-hypervisor", "Turn off the Windows hypervisor", "Prevents the Windows hypervisor from loading at boot.", "Warning", "WSL2, Docker, Windows Sandbox, and Android emulators may stop working. Requires a restart; the exact prior boot setting is saved for undo.", new BootTarget("hypervisorlaunchtype", "Off")),
            new TweakDefinition("disable-lockscreen-tips", "Remove lock screen tips", "Privacy", "Hides Windows tips and promotional content on the lock screen.", "Personal choice", "Spotlight tips will no longer appear on the lock screen.",
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "RotatingLockScreenEnabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", "RotatingLockScreenOverlayEnabled", 0, RegistryValueKind.DWord)),
            new TweakDefinition("disable-edge-startup-boost", "Stop Edge background activity", "Windows", "Disables Microsoft Edge Startup Boost and background mode for this user.", "Personal choice", "Edge may take slightly longer to open after being fully closed.",
                new ValueTarget(@"Software\Policies\Microsoft\Edge", "StartupBoostEnabled", 0, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Policies\Microsoft\Edge", "BackgroundModeEnabled", 0, RegistryValueKind.DWord)),
            new TweakDefinition("limit-background-apps", "Limit Store app background activity", "Performance", "Restricts Store app background execution through Windows policy and user settings.", "Caution", "Mail, calendar, and other Store apps may stop showing notifications while closed.",
                new ValueTarget(RegistryHive.LocalMachine, @"Software\Policies\Microsoft\Windows\AppPrivacy", "LetAppsRunInBackground", 2, RegistryValueKind.DWord),
                new ValueTarget(@"Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications", "GlobalUserDisabled", 1, RegistryValueKind.DWord)),
            WithServices(new TweakDefinition("system-telemetry-policy", "Limit Windows diagnostic data", "Privacy", "Sets Windows diagnostic-data policy to the required level for supported editions.", "Personal choice", "Some diagnostic data required by Windows may still be sent. Restart may be needed.",
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Policies\Microsoft\Windows\DataCollection", "AllowTelemetry", 0, RegistryValueKind.DWord)), "DiagTrack", "dmwappushservice"),
            ScheduledTaskTweak("disable-telemetry-tasks", "Disable telemetry scheduled tasks", "Disables selected Compatibility Appraiser, Customer Experience, and disk diagnostic tasks.", "These tasks may contribute to Windows compatibility and diagnostic information. Each task's enabled state is saved and restored individually.", @"\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser", @"\Microsoft\Windows\Customer Experience Improvement Program\Consolidator", @"\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip", @"\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector"),
            new TweakDefinition("system-error-reporting", "Disable Windows error reporting", "Privacy", "Disables the Windows Error Reporting service policy for this PC.", "Caution", "Crash reports will not be collected for diagnosis.",
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Microsoft\Windows\Windows Error Reporting", "Disabled", 1, RegistryValueKind.DWord)),
            new TweakDefinition("system-llmnr", "Disable legacy LLMNR discovery", "Privacy", "Turns off multicast name resolution on this PC.", "Caution", "Older local-network devices that rely on LLMNR name discovery may no longer resolve by name.",
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Policies\Microsoft\Windows NT\DNSClient", "EnableMulticast", 0, RegistryValueKind.DWord)),
            new TweakDefinition("system-remote-assistance", "Disable Remote Assistance", "Privacy", "Disables inbound Remote Assistance invitations through Windows policy.", "Personal choice", "Remote Assistance sessions will not be available until this is undone.",
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control\Remote Assistance", "fAllowToGetHelp", 0, RegistryValueKind.DWord)),
            new TweakDefinition("detailed-boot-messages", "Show detailed boot messages", "Windows", "Shows Windows status messages while signing in and shutting down.", "Personal choice", "This is for troubleshooting and does not make boot faster.",
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System", "VerboseStatus", 1, RegistryValueKind.DWord)),
            new TweakDefinition("prevent-forced-update-restarts", "Prevent forced update restarts while signed in", "Windows", "Asks Windows Update not to restart automatically while a user is signed in.", "Personal choice", "Windows may still ask you to restart to finish important updates.",
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU", "NoAutoRebootWithLoggedOnUsers", 1, RegistryValueKind.DWord)),
            new TweakDefinition("shorter-service-shutdown", "Reduce service shutdown wait", "Windows", "Reduces the time Windows waits for services to stop during shutdown.", "Caution", "A slow service may be terminated sooner during shutdown.",
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control", "WaitToKillServiceTimeout", "5000", RegistryValueKind.String)),
            new TweakDefinition("disable-automatic-maintenance", "Disable automatic idle maintenance", "Windows", "Stops Windows from starting automatic maintenance jobs while the PC is idle.", "Caution", "Scheduled maintenance and diagnostics will not run automatically. Windows Optimize Drives remains available.",
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance", "MaintenanceDisabled", 1, RegistryValueKind.DWord)),
            new TweakDefinition("disable-ntfs-last-access", "Disable NTFS last-access updates", "Performance", "Reduces file-system writes by disabling last-access timestamp updates.", "Personal choice", "Some backup or auditing tools may use file access timestamps.",
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control\FileSystem", "NtfsDisableLastAccessUpdate", 1, RegistryValueKind.DWord)),
            new TweakDefinition("disable-ntfs-83-names", "Disable legacy 8.3 file names", "Performance", "Stops NTFS from creating new short file names for files and folders.", "Caution", "Some older installers and 16-bit programs may require short file names.",
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control\FileSystem", "NtfsDisable8dot3NameCreation", 1, RegistryValueKind.DWord)),
            new TweakDefinition("disable-network-throttling", "Disable multimedia network throttling", "Network", "Removes the multimedia network throttle used by some real-time workloads.", "Personal choice", "Heavy background network traffic may use more CPU time.",
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile", "NetworkThrottlingIndex", -1, RegistryValueKind.DWord)),
            new TweakDefinition("remove-qos-reserve", "Remove QoS bandwidth reserve policy", "Network", "Sets the policy bandwidth reserve to zero where an application requests QoS.", "Personal choice", "This does not increase the speed of your internet connection.",
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Policies\Microsoft\Windows\Psched", "NonBestEffortLimit", 0, RegistryValueKind.DWord)),
            NetshTweak("disable-tcp-heuristics", "Disable TCP window-size heuristics", "Stops Windows TCP heuristics from changing the receive-window scaling choice automatically.", "May change throughput behavior on some connections. The current netsh setting is read first and restored exactly on undo.", new NetshTarget("tcp-heuristics", "disabled")),
            NetshTweak("disable-teredo", "Disable Teredo tunneling", "Turns off the IPv6-over-IPv4 Teredo tunnel.", "Xbox party chat and some peer-to-peer games use Teredo. The current tunnel type is saved and restored on undo.", new NetshTarget("teredo-type", "disabled")),
            WithDynamicTargets(new TweakDefinition("tcp-nagle", "Send small game packets promptly", "Network", "Sets TCPNoDelay and TcpAckFrequency on active Ethernet and Wi-Fi adapters, matching the legacy Nagle option.", "Caution", "This can increase packet traffic and may not improve ping. Only active Ethernet and Wi-Fi adapters are changed; undo restores each saved value."), delegate { var targets = ActiveTcpInterfaceTargets("TCPNoDelay", 1); targets.AddRange(ActiveTcpInterfaceTargets("TcpAckFrequency", 1)); return targets; }),
            WithDynamicTargets(new TweakDefinition("disable-netbios", "Disable legacy NetBIOS broadcasts", "Network", "Disables NetBIOS over TCP/IP on active Ethernet and Wi-Fi adapters.", "Caution", "Older file sharing or local network devices may rely on NetBIOS names. Undo restores each adapter's saved setting."), delegate { return ActiveTcpInterfaceTargets("NetbiosOptions", 2); }),
            AdapterTweak("disable-rsc", "Disable Receive Segment Coalescing", "Turns off RSC for IPv4 and IPv6 on active Ethernet and Wi-Fi adapters.", "This driver setting may restart an adapter and briefly interrupt the network. Higher CPU use is possible; undo restores each adapter's saved IPv4 and IPv6 state.", "rsc"),
            AdapterTweak("disable-lso", "Disable Large Send Offload", "Turns off LSOv2 for IPv4 and IPv6 on active Ethernet and Wi-Fi adapters.", "This driver setting may restart an adapter and briefly interrupt the network. CPU use during large uploads may increase; undo restores each adapter's saved IPv4 and IPv6 state.", "lso"),
            AdapterTweak("disable-adapter-power-saving", "Disable adapter power-saving features", "Disables enabled adapter offload and selective-suspend features on active Ethernet and Wi-Fi adapters.", "Some features can affect wake-on-LAN, battery use, or wireless power behavior. Adapter state may briefly reset; undo restores the capabilities that were enabled before.", "power"),
            AdapterTweak("cloudflare-dns", "Use Cloudflare DNS", "Sets active Ethernet and Wi-Fi adapters to Cloudflare DNS (1.1.1.1 and 1.0.0.1).", "DNS response time varies by provider and location. Managed networks may require their own DNS. Undo restores each adapter's original DNS server list or automatic assignment.", "dns"),
            AdvancedAdapterTweak("disable-eee", "Disable Energy-Efficient Ethernet", "Disables matching Energy Efficient Ethernet or Green Ethernet advanced properties on active Ethernet adapters.", "Driver property names and supported values vary. Matching adapters may reset and briefly interrupt connectivity; unsupported drivers are skipped and saved values are restored on undo.", "eee"),
            AdvancedAdapterTweak("disable-flow-control", "Disable adapter flow control", "Disables the Flow Control advanced property on active Ethernet adapters when the driver exposes a Disabled value.", "Heavy local file transfers may behave differently. The adapter may briefly reconnect; undo restores its exact saved registry values.", "flow"),
            AdvancedAdapterTweak("disable-interrupt-moderation", "Disable interrupt moderation", "Disables Interrupt Moderation on active Ethernet adapters that expose the option.", "This may raise CPU use during network activity and briefly reconnect the adapter. Undo restores its exact saved registry values.", "interrupt"),
            AdapterTweak("enable-receive-side-scaling", "Enable Receive Side Scaling", "Enables RSS on active Ethernet and Wi-Fi adapters so supported network processing can spread across CPU cores.", "Requires driver support and may change adapter behavior. Each adapter's original RSS state is saved for undo.", "rss"),
            new TweakDefinition("faster-tcp-port-reuse", "Shorten TCP port reuse delay", "Network", "Sets the legacy TIME_WAIT and ephemeral port values for systems that frequently open short-lived connections.", "Caution", "This is a system-wide TCP setting and usually does not improve game ping. Use only if you understand the workload; undo restores the previous values.",
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Services\Tcpip\Parameters", "TcpTimedWaitDelay", 30, RegistryValueKind.DWord),
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Services\Tcpip\Parameters", "MaxUserPort", 65534, RegistryValueKind.DWord)),
            new TweakDefinition("foreground-priority-boost", "Set foreground scheduling preference", "Performance", "Sets the Windows foreground scheduling preference used by desktop apps and games.", "Personal choice", "The effect varies by workload and may not change game frame rates.",
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control\PriorityControl", "Win32PrioritySeparation", 38, RegistryValueKind.DWord)),
            new TweakDefinition("game-scheduling-profile", "Tune MMCSS Games scheduling", "Gaming", "Sets the Windows Multimedia Class Scheduler Games profile for foreground game workloads.", "Caution", "May change scheduling behavior for games and other multimedia workloads; undo it if audio or streaming behaves differently.",
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile", "SystemResponsiveness", 10, RegistryValueKind.DWord),
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games", "GPU Priority", 8, RegistryValueKind.DWord),
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games", "Priority", 6, RegistryValueKind.DWord),
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games", "Scheduling Category", "High", RegistryValueKind.String),
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games", "SFIO Priority", "High", RegistryValueKind.String)),
            new TweakDefinition("disable-power-throttling", "Disable Windows power throttling", "Performance", "Disables Windows power throttling for background desktop processes.", "Caution", "May increase idle power use and battery drain.",
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control\Power\PowerThrottling", "PowerThrottlingOff", 1, RegistryValueKind.DWord)),
            new TweakDefinition("enable-gpu-scheduling", "Enable hardware-accelerated GPU scheduling", "Gaming", "Enables hardware-accelerated GPU scheduling where the driver and Windows version support it.", "Caution", "Requires a restart. Older GPUs or drivers can stutter; undo it if performance gets worse.",
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control\GraphicsDrivers", "HwSchMode", 2, RegistryValueKind.DWord)),
            new TweakDefinition("disable-mpo", "Disable Multiplane Overlay", "Gaming", "Disables the Windows display overlay path that can cause flicker on some GPU setups.", "Caution", "Requires a restart and may increase power use or reduce display efficiency. Use only when troubleshooting flicker.",
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Microsoft\Windows\Dwm", "OverlayTestMode", 5, RegistryValueKind.DWord)),
            new TweakDefinition("disable-fast-startup", "Disable Windows Fast Startup", "Windows", "Makes shutdown perform a full kernel shutdown instead of saving a hibernation session.", "Caution", "Cold starts may take longer. Hibernation and Fast Startup behavior change; restart Windows after applying.",
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control\Session Manager\Power", "HiberbootEnabled", 0, RegistryValueKind.DWord)),
            new TweakDefinition("global-timer-resolution-requests", "Allow per-app timer requests", "Gaming", "Restores per-process timer resolution requests on supported Windows versions.", "Caution", "May slightly increase power use. Only affects apps that request a finer timer; restart Windows after applying.",
                new ValueTarget(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Control\Session Manager\kernel", "GlobalTimerResolutionRequests", 1, RegistryValueKind.DWord)),
            new TweakDefinition("exclude-driver-updates", "Keep drivers out of Windows Update", "Windows", "Prevents Windows Update from replacing device drivers with newer catalog drivers.", "Caution", "You will need to check for graphics and chipset driver updates from their manufacturers.",
                new ValueTarget(RegistryHive.LocalMachine, @"SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate", "ExcludeWUDriversInQualityUpdate", 1, RegistryValueKind.DWord)),
            ServiceTweak("disable-remote-registry", "Disable Remote Registry service", "Privacy", "Stops the service that allows remote computers to modify this PC's registry.", "Personal choice", "Remote registry administration from another PC will no longer be available.", "RemoteRegistry"),
            ServiceTweak("disable-search-indexing", "Disable Windows Search indexing", "Performance", "Stops background indexing for Windows Search.", "Caution", "Start menu and File Explorer searches may take longer and search content may be incomplete.", "WSearch"),
            ServiceTweak("disable-unused-services", "Disable optional Windows services", "Windows", "Disables Fax, Retail Demo, Windows Media Player sharing, and Maps Broker when those services are installed.", "Caution", "Faxing, media library sharing, or location features can stop working. Only services found on this PC are changed.", "Fax", "RetailDemo", "WMPNetworkSvc", "MapsBroker"),
            ServiceTweak("disable-xbox-services", "Disable Xbox services", "Windows", "Stops Xbox authentication, game-save, networking, and accessory services when installed.", "Warning", "The Xbox app, PC Game Pass sign-in, cloud saves, and Xbox accessories may stop working. Undo restores each service's startup and running state.", "XblAuthManager", "XblGameSave", "XboxNetApiSvc", "XboxGipSvc"),
            ServiceTweak("disable-print-spooler", "Disable Print Spooler", "Windows", "Stops the Windows printing service.", "Caution", "Local and network printing, including Print to PDF, may stop working.", "Spooler"),
            ServiceTweak("disable-sysmain", "Disable SysMain service", "Performance", "Stops SysMain, the Windows service that manages prefetching and application launch caching.", "Caution", "App launch behavior may change, especially on hard drives. Test first and undo if launches get slower.", "SysMain"),
            ServiceTweak("disable-nvidia-telemetry", "Disable NVIDIA telemetry service", "Privacy", "Stops the NVIDIA telemetry container service when it is installed.", "Personal choice", "NVIDIA driver and game features should continue to work; driver updates may reinstall or re-enable this service.", "NvTelemetryContainer")
        };

        private static readonly GameDefinition[] GameProfiles = new GameDefinition[] {
            MakeGame("valorant", "VALORANT", "Riot Vanguard", new string[] { "VALORANT-Win64-Shipping.exe" }, new string[] { "Try lower material, detail, and UI quality settings.", "Disable V-Sync and cap frame rate near your monitor refresh rate.", "Enable NVIDIA Reflex if your GPU supports it." }, "game-mode", "game-capture", "gamebar-overlay", "raw-mouse"),
            MakeGame("fortnite", "Fortnite", "Easy Anti-Cheat", new string[] { "FortniteClient-Win64-Shipping.exe" }, new string[] { "Compare Performance Mode and DirectX 12 on your PC.", "Shadows Off and lower effects can improve frame rate.", "Cap FPS just below your monitor refresh rate for steadier frame times." }, "game-mode", "game-capture", "gamebar-overlay", "raw-mouse"),
            MakeGame("cs2", "Counter-Strike 2", "VAC", new string[] { "cs2.exe" }, new string[] { "Most gains come from in-game video and GPU driver settings.", "Try disabling V-Sync and enabling raw mouse input.", "Use an FPS cap if uncapped frame times are inconsistent." }, "game-mode", "game-capture", "gamebar-overlay", "raw-mouse", "fullscreen-optimizations"),
            MakeGame("apex", "Apex Legends", "Easy Anti-Cheat", new string[] { "r5apex.exe", "r5apex_dx12.exe" }, new string[] { "Compare fullscreen and display options on your system.", "Lower texture streaming budget if VRAM is limited.", "Update your GPU driver before adjusting graphics settings." }, "game-mode", "game-capture", "gamebar-overlay", "raw-mouse"),
            MakeGame("warzone", "Call of Duty: Warzone", "Ricochet", new string[] { "cod.exe" }, new string[] { "Keep the game on an SSD when possible.", "Let shaders finish compiling after a game update.", "Close overlays you do not use while playing." }, "game-mode", "game-capture", "gamebar-overlay", "raw-mouse"),
            MakeGame("fivem", "FiveM / GTA V", "", new string[] { "FiveM.exe", "GTA5.exe" }, new string[] { "Test settings across a few servers; streamed content can affect performance.", "Lower anti-aliasing and grass quality if frame times spike.", "Do not modify game files for optimization." }, "game-mode", "game-capture", "gamebar-overlay", "raw-mouse"),
            MakeGame("roblox", "Roblox", "Hyperion", new string[] { "RobloxPlayerBeta.exe" }, new string[] { "Adjust Graphics Quality in Roblox settings.", "Close extra browser tabs if CPU use is high.", "Use Windows-level changes only; avoid modifying game files." }, "game-mode", "game-capture", "gamebar-overlay"),
            MakeGame("rocket-league", "Rocket League", "Easy Anti-Cheat", new string[] { "RocketLeague.exe" }, new string[] { "Try V-Sync off if you want lower input latency.", "Lower effects quality if you see frame-time spikes." }, "game-mode", "game-capture", "gamebar-overlay", "raw-mouse"),
            MakeGame("overwatch", "Overwatch 2", "", new string[] { "Overwatch.exe" }, new string[] { "Try Reduce Buffering and V-Sync off.", "Lower shadow and effects detail if performance is inconsistent." }, "game-mode", "game-capture", "gamebar-overlay", "raw-mouse"),
            MakeGame("rust", "Rust", "Easy Anti-Cheat", new string[] { "RustClient.exe" }, new string[] { "Install on an SSD and lower draw distance if needed.", "Close other apps before joining large servers on a memory-limited PC." }, "game-mode", "game-capture", "gamebar-overlay", "raw-mouse")
        };

        private readonly bool _previewMode;
        public MainWindow() : this(false) { }
        internal MainWindow(bool preview)
        {
            _previewMode = preview;
            Title = "SharkOptimizer 2.0.0"; Width = 1240; Height = 800; MinWidth = 980; MinHeight = 660;
            Icon = BrandAssets.Icon;
            WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.CanResize; WindowStartupLocation = WindowStartupLocation.CenterScreen; Background = Brush(BackgroundColor); Foreground = Brushes.White;
            WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 0, CornerRadius = new CornerRadius(14), GlassFrameThickness = new Thickness(0), ResizeBorderThickness = new Thickness(6), UseAeroCaptionButtons = false });
            FontFamily = new FontFamily("Segoe UI Variable Display"); FontSize = 13;
            _catalogue = new List<TweakDefinition>(Definitions);
            _state = preview ? new AppState() : LoadState();
            if (_state.MaintenanceServices == null) _state.MaintenanceServices = new List<string>();
            if (_state.CleanupHistory == null) _state.CleanupHistory = new List<CleanupRun>();
            if (_state.GamePaths == null) _state.GamePaths = new Dictionary<string, List<string>>();
            if (_state.CustomGames == null) _state.CustomGames = new List<GameDefinition>();
            if (_state.SavedPresets == null) _state.SavedPresets = new List<UserPreset>();
            if (_state.LegacyBackupFiles == null) _state.LegacyBackupFiles = new Dictionary<string, string>();
            if (!preview) ImportLegacyCleanupHistory();
            if (!preview) ImportLegacyBehavior();
            if (!preview) ImportLegacyCleanupPreferences();
            if (!preview) ImportLegacyLanguage();
            if (!Localization.Languages.ContainsKey(_state.Language ?? "")) { _state.Language = preview ? "en" : Localization.DefaultWindowsLanguage(); if (!preview) _legacyStateMigrated = true; }
            Localization.AddTweakLabels(Definitions, LegacyTweakAliases); Localization.SetLanguage(_state.Language);
            if (_state.CustomTweaks == null) _state.CustomTweaks = new List<CustomTweak>();
            if (_state.GameSessions == null) _state.GameSessions = new GameSessionStore();
            if (_state.SessionPriorities == null) _state.SessionPriorities = new List<SessionPriorityChange>();
            if (_state.SessionHistory == null) _state.SessionHistory = new List<GameSessionReport>();
            _state.SessionHistory = _state.SessionHistory.Where(x => x != null).Take(50).ToList();
            if (_state.BenchmarkRuns == null) _state.BenchmarkRuns = new List<BenchmarkRun>();
            _state.BenchmarkRuns = _state.BenchmarkRuns.Where(x => x != null && x.Data != null && (x.Slot == "Before" || x.Slot == "After")).Take(60).ToList();
            if (!preview) ImportLegacyBenchmarks();
            try { GameSessionCodec.Validate(_state.GameSessions); } catch { _state.GameSessions = new GameSessionStore(); _sessionSettingsNotice = "Saved game-session settings were invalid. The current file will be preserved in the state backup."; }
            if (!preview) ImportLegacyGameSessions();
            if (!preview) ImportLegacySessionHistory();
            if (!preview) ImportLegacyCustomTweaks();
            RebuildCustomCatalogue();
            if (!preview) ImportLegacyPresets();
            if (String.IsNullOrWhiteSpace(_state.CleanupDay)) _state.CleanupDay = "SUN";
            if (String.IsNullOrWhiteSpace(_state.CleanupTime)) _state.CleanupTime = "20:00";
            if (!preview && !File.Exists(_dataPath)) ImportLegacyAppearance();
            if (String.IsNullOrWhiteSpace(_state.Accent) || !AccentOptions.ContainsKey(_state.Accent)) _state.Accent = "blue";
            if (_state.UiFont != "Poppins" && _state.UiFont != "Segoe UI") _state.UiFont = "Poppins";
            if (!new[] { .9, 1, 1.1, 1.25 }.Contains(_state.InterfaceScale)) _state.InterfaceScale = 1;
            SetAccentBrushes(_state.Accent);
            try { FontFamily = preview ? new FontFamily(new Uri(Path.Combine(Environment.CurrentDirectory, "legacy", "fonts") + Path.DirectorySeparatorChar), "./#Poppins") : ResolveUiFont(_state.UiFont); }
            catch { _state.UiFont = "Segoe UI"; FontFamily = new FontFamily("Segoe UI"); }
            var comboItemStyle = new Style(typeof(ComboBoxItem));
            comboItemStyle.Setters.Add(new Setter(Control.BackgroundProperty, Brush(SurfaceRaised)));
            comboItemStyle.Setters.Add(new Setter(Control.ForegroundProperty, Brushes.White));
            comboItemStyle.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(9, 6, 9, 6)));
            var highlighted = new Trigger { Property = ComboBoxItem.IsHighlightedProperty, Value = true };
            highlighted.Setters.Add(new Setter(Control.BackgroundProperty, LiveNavFill)); comboItemStyle.Triggers.Add(highlighted);
            var selectedItem = new Trigger { Property = ComboBoxItem.IsSelectedProperty, Value = true };
            selectedItem.Setters.Add(new Setter(Control.BackgroundProperty, LiveNavFill)); comboItemStyle.Triggers.Add(selectedItem);
            Resources[typeof(ComboBoxItem)] = comboItemStyle;
            ApplyControlStyles();
            if (_legacyStateMigrated) SaveState();
            _requirementsReady = preview;
            if (!preview) Loaded += async delegate { Task hardware = LoadHardwareRequirements(); await RecoverOnFirstOpen(); await hardware; await ScanExistingTweaks(); };
            Content = BuildShell();
            IsVisibleChanged += delegate { Dispatcher.BeginInvoke(new Action(RefreshMonitoringVisibility)); };
            Localization.Apply((DependencyObject)Content);
            ((FrameworkElement)Content).LayoutTransform = new ScaleTransform(_state.InterfaceScale, _state.InterfaceScale);
            ShowPage("Dashboard");
            if (!preview) { InitializeTrayIcon(); Closing += HandleClosing; Microsoft.Win32.SystemEvents.SessionEnding += OnSystemSessionEnding; }
            _updateCheckTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
            _updateCheckTimer.Tick += async delegate { _updateCheckTimer.Stop(); await CheckForUpdates(true); if (!_updateShutdown && !_sessionExitInProgress && _state.AutoCheckUpdates) { _updateCheckTimer.Interval = TimeSpan.FromHours(6); _updateCheckTimer.Start(); } };
            if (!preview && _state.AutoCheckUpdates) _updateCheckTimer.Start();
        }

        private void InitializeTrayIcon()
        {
            try { _trayIconImage = System.Drawing.Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location); } catch { }
            _trayIcon = new System.Windows.Forms.NotifyIcon { Icon = _trayIconImage ?? System.Drawing.SystemIcons.Application, Text = "SharkOptimizer 2.0.0", Visible = false };
            _trayIcon.DoubleClick += delegate { RestoreFromTray(); };
            _trayIcon.BalloonTipClicked += delegate { if (!String.IsNullOrEmpty(_updateNotifiedVersion)) Dispatcher.BeginInvoke(new Action(delegate { RestoreFromTray(); ShowPage("Settings"); if (_selectSettingsSection != null) _selectSettingsSection(1); })); };
            var menu = new System.Windows.Forms.ContextMenuStrip();
            menu.Items.Add("Open SharkOptimizer", null, delegate { RestoreFromTray(); });
            menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            menu.Items.Add("Exit", null, delegate { _allowExit = true; Close(); });
            menu.Opening += delegate { menu.Items[0].Text = Localization.Translate("Open SharkOptimizer"); menu.Items[2].Text = Localization.Translate("Exit"); };
            _trayIcon.ContextMenuStrip = menu;
        }

        private async void HandleClosing(object sender, CancelEventArgs e)
        {
            if (!_allowExit)
            {
                e.Cancel = true;
                ShowInTaskbar = false;
                Hide();
                if (_trayIcon != null) _trayIcon.Visible = true;
                return;
            }
            if (_sessionExitReady) return;
            e.Cancel = true;
            if (_sessionStarting) { _sessionExitAfterStart = true; return; }
            if (_sessionExitInProgress) return;
            _sessionExitInProgress = true;
            await StopExistingTweakScan();
            await StopBackgroundUpdateDownloads();
            if (_tweakOperationBusy && _tweakOperationCompletion != null) await _tweakOperationCompletion.Task;
            await EndGameSession(false);
            await RecoverMaintenanceServices();
            StopLivePing();
            if (_monitorTimer != null) _monitorTimer.Stop(); _monitorGeneration++; _systemSampler = null;
            if (_trayIcon != null) { _trayIcon.Visible = false; _trayIcon.Dispose(); _trayIcon = null; }
            if (_trayIconImage != null) { _trayIconImage.Dispose(); _trayIconImage = null; }
            Microsoft.Win32.SystemEvents.SessionEnding -= OnSystemSessionEnding;
            _sessionExitReady = true; Close();
        }

        private void OnSystemSessionEnding(object sender, Microsoft.Win32.SessionEndingEventArgs e)
        { Dispatcher.BeginInvoke(new Action(delegate { _allowExit = true; Close(); })); }

        private void RestoreFromTray()
        {
            ShowInTaskbar = true;
            Show();
            if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
            Activate();
            if (_trayIcon != null) _trayIcon.Visible = false;
        }

        private static GameDefinition MakeGame(string id, string name, string antiCheat, string[] executables, string[] tips, params string[] tweaks)
        {
            return new GameDefinition { Id = id, Name = name, AntiCheat = antiCheat, Executables = new List<string>(executables), Tips = new List<string>(tips), RecommendedTweaks = new List<string>(tweaks), IsCustom = false };
        }

        private AppState LoadState()
        {
            foreach (string candidate in new[] { _dataPath, _dataPath + ".bak" }) {
                if (!File.Exists(candidate)) continue;
                try {
                    if (new FileInfo(candidate).Length > 16 * 1024 * 1024) throw new InvalidDataException("Saved app state exceeds 16 MB.");
                    AppState state = _json.Deserialize<AppState>(File.ReadAllText(candidate));
                    if (state != null && state.Applied != null && !state.Applied.Any(x => x == null)) {
                        if (state.LegacyUndoImportVersion < 2) {
                            try { UpgradeLegacyUndoHistory(state); }
                            catch (Exception ex) { _legacyHistoryNotice = "Could not expand previous undo history: " + ex.Message; }
                        }
                        if (candidate != _dataPath) {
                            _preserveRejectedStateOnSave = true; _legacyStateMigrated = true;
                            _nativeStateNotice = "Recovered saved app state from the previous copy. Review Restore before making new changes.";
                        }
                        return state;
                    }
                    throw new InvalidDataException("Saved app state is invalid.");
                } catch (Exception ex) {
                    if (candidate == _dataPath) _preserveRejectedStateOnSave = true;
                    _nativeStateNotice = "Saved app state could not be loaded: " + ex.Message;
                }
            }
            AppState legacy = LoadLegacyState();
            _legacyStateMigrated = true; return legacy;
        }

        private void UpgradeLegacyUndoHistory(AppState state)
        {
            AppState previous = LoadLegacyState(); if (previous.LegacyUndoImportVersion < 2) return;
            int updated = 0;
            foreach (AppliedTweak incoming in previous.Applied) {
                AppliedTweak existing = state.Applied.FirstOrDefault(x => x != null && x.Id == incoming.Id);
                if (existing == null) {
                    // An absent record that the earlier native importer supported may already have been undone.
                    bool supportedBefore = incoming.Services.Count > 0 || incoming.Values.Any(x => String.IsNullOrWhiteSpace(x.Hive) || String.Equals(x.Hive, RegistryHive.CurrentUser.ToString(), StringComparison.OrdinalIgnoreCase));
                    if (supportedBefore) continue;
                    state.Applied.Insert(0, incoming); updated++; continue;
                }
                bool changed = false;
                if (existing.Values == null) existing.Values = new List<RegValueChange>();
                foreach (RegValueChange value in incoming.Values) {
                    string hive = String.IsNullOrWhiteSpace(value.Hive) ? RegistryHive.CurrentUser.ToString() : value.Hive;
                    if (existing.Values.Any(x => String.Equals(String.IsNullOrWhiteSpace(x.Hive) ? RegistryHive.CurrentUser.ToString() : x.Hive, hive, StringComparison.OrdinalIgnoreCase) && String.Equals(x.KeyPath, value.KeyPath, StringComparison.OrdinalIgnoreCase) && String.Equals(x.Name ?? "", value.Name ?? "", StringComparison.OrdinalIgnoreCase))) continue;
                    existing.Values.Add(value); changed = true;
                }
                if (existing.Services == null) existing.Services = new List<ServiceChange>();
                foreach (ServiceChange service in incoming.Services) if (!existing.Services.Any(x => String.Equals(x.Name, service.Name, StringComparison.OrdinalIgnoreCase))) { existing.Services.Add(service); changed = true; }
                if (existing.AdvancedAdapters == null) existing.AdvancedAdapters = new List<AdvancedAdapterChange>();
                foreach (AdvancedAdapterChange adapter in incoming.AdvancedAdapters) if (!existing.AdvancedAdapters.Any(x => String.Equals(x.AdapterName, adapter.AdapterName, StringComparison.OrdinalIgnoreCase) && String.Equals(x.DisplayName, adapter.DisplayName, StringComparison.OrdinalIgnoreCase))) { existing.AdvancedAdapters.Add(adapter); changed = true; }
                if (changed) updated++;
            }
            state.LegacyUndoImportVersion = 2; _legacyStateMigrated = true;
            if (updated > 0) _legacyHistoryNotice = "Expanded " + updated + " previous-app undo record(s) with registry or adapter recovery data. Existing saved values were kept.";
            else _legacyHistoryNotice = null;
        }

        private AppState LoadLegacyState()
        {
            string legacyPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SharkOptimizer", "state.json");
            var migrated = new AppState { LegacyUndoImportVersion = 2 }; if (!File.Exists(legacyPath)) return migrated;
            int skipped = 0;
            try
            {
                object root = _json.DeserializeObject(File.ReadAllText(legacyPath));
                var properties = root as IDictionary<string, object>; if (properties == null) return migrated;
                foreach (var property in properties)
                {
                    var records = new List<RegValueChange>();
                    var serviceRecords = new List<ServiceChange>();
                    var advancedRecords = new List<AdvancedAdapterChange>();
                    IEnumerable entries = property.Value as IEnumerable;
                    if (entries == null || property.Value is string) { skipped++; continue; }
                    foreach (object item in entries)
                    {
                        var entry = item as IDictionary<string, object>; if (entry == null) continue;
                        string kindTag = Convert.ToString(entry.ContainsKey("K") ? entry["K"] : null);
                        if (String.Equals(kindTag, "Svc", StringComparison.OrdinalIgnoreCase))
                        {
                            string serviceName = Convert.ToString(entry.ContainsKey("Name") ? entry["Name"] : null);
                            string startMode = Convert.ToString(entry.ContainsKey("Old") ? entry["Old"] : null);
                            if (Regex.IsMatch(serviceName ?? "", "^[A-Za-z0-9_.-]{1,256}$") && new[] { "Auto", "Manual", "Disabled", "Boot", "System" }.Contains(startMode, StringComparer.OrdinalIgnoreCase))
                                serviceRecords.Add(new ServiceChange { Name = serviceName, StartMode = startMode, WasRunning = String.Equals(startMode, "Auto", StringComparison.OrdinalIgnoreCase) });
                            else skipped++;
                            continue;
                        }
                        if (String.Equals(kindTag, "Adv", StringComparison.OrdinalIgnoreCase)) {
                            string adapter = Convert.ToString(entry.ContainsKey("Adapter") ? entry["Adapter"] : null);
                            string display = Convert.ToString(entry.ContainsKey("DisplayName") ? entry["DisplayName"] : null);
                            object old = entry.ContainsKey("Old") ? entry["Old"] : null;
                            string oldDisplay = old as string;
                            if (oldDisplay == null) { string[] values = WmiStringArray(old); if (values.Length == 1) oldDisplay = values[0]; }
                            if (String.IsNullOrWhiteSpace(adapter) || String.IsNullOrWhiteSpace(display) || oldDisplay == null || adapter.Length > 1024 || display.Length > 1024 || oldDisplay.Length > 8192 || adapter.Any(Char.IsControl) || display.Any(Char.IsControl)) skipped++;
                            else advancedRecords.Add(new AdvancedAdapterChange { AdapterName = adapter, DisplayName = display, LegacyDisplayValue = oldDisplay });
                            continue;
                        }
                        if (!String.Equals(kindTag, "Reg", StringComparison.OrdinalIgnoreCase)) { skipped++; continue; }
                        string fullPath = Convert.ToString(entry.ContainsKey("Path") ? entry["Path"] : null);
                        string name = Convert.ToString(entry.ContainsKey("Name") ? entry["Name"] : null);
                        string kind = Convert.ToString(entry.ContainsKey("Type") ? entry["Type"] : "String");
                        try {
                            RegistryValueKind valueKind; if (!Enum.TryParse<RegistryValueKind>(kind, true, out valueKind) || valueKind == RegistryValueKind.Unknown) throw new InvalidDataException("Unsupported registry value type.");
                            var address = CustomTweakCodec.Target(new CustomRegistryValue { Path = fullPath, Name = name, Type = "String", Value = "" });
                            bool existed = entry.ContainsKey("Existed") && Convert.ToBoolean(entry["Existed"]);
                            object oldValue = entry.ContainsKey("Old") ? entry["Old"] : null;
                            if (existed) oldValue = RegistryData.ConvertValue(oldValue, valueKind);
                            records.Add(new RegValueChange { Hive = address.Hive.ToString(), KeyPath = address.KeyPath, Name = address.Name, Existed = existed, Kind = valueKind.ToString(), Value = oldValue });
                        } catch { skipped++; }
                    }
                    if (records.Count > 0 || serviceRecords.Count > 0 || advancedRecords.Count > 0) migrated.Applied.Add(new AppliedTweak { Id = "legacy-" + property.Key, Name = "Previous version · " + property.Key, AppliedAt = DateTime.Now, Values = records, Services = serviceRecords, AdvancedAdapters = advancedRecords });
                }
            }
            catch (Exception ex) { _legacyHistoryNotice = "Could not import previous undo history: " + ex.Message; return new AppState(); }
            if (migrated.Applied.Count > 0)
            {
                _legacyHistoryNotice = "Imported " + migrated.Applied.Count + " undo record(s) from the previous app. Registry values and service startup settings were copied." + (skipped > 0 ? Environment.NewLine + "Unimported entries: " + skipped + ". The original history remains in the previous app." : "");
            }
            else if (skipped > 0) _legacyHistoryNotice = "Previous undo history was found, but its entries could not be imported. The original history remains in the previous app.";
            return migrated;
        }

        private void SaveState()
        {
            if (_previewMode) return;
            lock (_stateSaveLock) {
                string folder = Path.GetDirectoryName(_dataPath); Directory.CreateDirectory(folder);
                string temp = _dataPath + ".tmp." + Guid.NewGuid().ToString("N");
                try {
                    string serialized = _json.Serialize(_state);
                    if (Encoding.UTF8.GetByteCount(serialized) > 16 * 1024 * 1024) throw new InvalidDataException("Saved app state exceeds 16 MB.");
                    File.WriteAllText(temp, serialized);
                    if (File.Exists(_dataPath)) {
                        string backup = _preserveRejectedStateOnSave ? _dataPath + ".rejected." + DateTime.UtcNow.ToString("yyyyMMddTHHmmss", CultureInfo.InvariantCulture) + "." + Guid.NewGuid().ToString("N") + ".json" : _dataPath + ".bak";
                        File.Replace(temp, _dataPath, backup, true);
                    } else File.Move(temp, _dataPath);
                    _preserveRejectedStateOnSave = false;
                } finally { if (File.Exists(temp)) try { File.Delete(temp); } catch { } }
            }
        }

        private UIElement BuildShell()
        {
            var root = new Grid(); root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(76) }); root.ColumnDefinitions.Add(new ColumnDefinition());
            root.Children.Add(BuildSidebar());
            var main = new Grid(); main.RowDefinitions.Add(new RowDefinition { Height = new GridLength(98) }); main.RowDefinitions.Add(new RowDefinition()); main.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var header = new Grid { Margin = new Thickness(34, 20, 34, 14) };
            header.ColumnDefinitions.Add(new ColumnDefinition()); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var titleStack = new StackPanel();
            _pageTitle.FontSize = 25; _pageTitle.FontWeight = FontWeights.SemiBold; _pageTitle.Foreground = Brushes.White;
            _pageTitle.TextTrimming = TextTrimming.CharacterEllipsis;
            _pageSubtitle.FontSize = 12; _pageSubtitle.Foreground = Brush(MutedColor); _pageSubtitle.Margin = new Thickness(0, 3, 0, 0);
            _pageSubtitle.TextTrimming = TextTrimming.CharacterEllipsis;
            titleStack.Children.Add(_pageTitle); titleStack.Children.Add(_pageSubtitle); header.Children.Add(titleStack);
            var windowButtons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top };
            _applyButton = ActionButton("Apply selected", true); _applyButton.Visibility = Visibility.Collapsed; _applyButton.Margin = new Thickness(0, 0, 12, 0); _applyButton.Click += async delegate { await ApplySelected(); }; windowButtons.Children.Add(_applyButton);
            _updateReadyButton = ActionButton("Update ready", false); _updateReadyButton.Visibility = Visibility.Collapsed; _updateReadyButton.Margin = new Thickness(0, 0, 10, 0); _updateReadyButton.Click += delegate { ShowPage("Settings"); if (_selectSettingsSection != null) _selectSettingsSection(1); }; windowButtons.Children.Add(_updateReadyButton);
            var minimize = SmallButton("—"); minimize.Click += delegate { WindowState = WindowState.Minimized; };
            var help = SmallButton("?"); help.ToolTip = "Quick guide"; help.Click += delegate { ShowPage("Guide"); }; windowButtons.Children.Add(help);
            minimize.ToolTip = "Minimize";
            var maximize = SmallButton("□"); maximize.ToolTip = "Maximize or restore"; maximize.Click += delegate { WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized; };
            var close = SmallButton("×"); close.Click += delegate { Close(); };
            close.ToolTip = "Hide to notification area";
            windowButtons.Children.Add(minimize); windowButtons.Children.Add(maximize); windowButtons.Children.Add(close); Grid.SetColumn(windowButtons, 1); header.Children.Add(windowButtons);
            titleStack.MouseLeftButtonDown += delegate(object sender, MouseButtonEventArgs e) { if (e.ButtonState == MouseButtonState.Pressed) DragMove(); };
            main.Children.Add(header);
            var contentHost = new Grid { Margin = new Thickness(28, 0, 28, 24) }; Grid.SetRow(contentHost, 1); main.Children.Add(contentHost);
            AddPage(contentHost, "Dashboard", BuildDashboard);
            AddPage(contentHost, "Optimize", BuildOptimize);
            AddPage(contentHost, "Games", BuildGames);
            AddPage(contentHost, "Game Session", BuildGameSession);
            AddPage(contentHost, "Windows", BuildWindowsTools);
            AddPage(contentHost, "Boost-Up", BuildBoostUp);
            AddPage(contentHost, "Network", BuildNetwork);
            AddPage(contentHost, "Lab", BuildLab);
            AddPage(contentHost, "Restore", BuildRestore);
            AddPage(contentHost, "Settings", BuildSettings);
            AddPage(contentHost, "Guide", BuildGuide);
            var activity = BuildActivityPanel(); Grid.SetRow(activity, 2); main.Children.Add(activity);
            Grid.SetColumn(main, 1); root.Children.Add(main);
            return new Border { Child = root, Background = Brush(BackgroundColor), BorderBrush = Brush(BorderColor), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(14), ClipToBounds = true };
        }

        private UIElement BuildSidebar()
        {
            var side = new Border { Background = Brush(Color.FromRgb(11, 20, 34)), BorderBrush = Brush(BorderColor), BorderThickness = new Thickness(0, 0, 1, 0) };
            var stack = new DockPanel { Margin = new Thickness(10, 16, 10, 16), LastChildFill = true };
            var brand = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 2, 0, 20), ToolTip = "SharkOptimizer" };
            var mark = new Border { Width = 38, Height = 38, Child = BrandAssets.Image(38) };
            brand.Children.Add(mark); DockPanel.SetDock(brand, Dock.Top); stack.Children.Add(brand);
            var nav = new StackPanel();
            nav.Children.Add(NavSection("HOME"));
            nav.Children.Add(NavButton("Dashboard", "⌂")); nav.Children.Add(NavButton("Optimize", "◈"));
            nav.Children.Add(NavSection("GAMING")); nav.Children.Add(NavButton("Games", "▣")); nav.Children.Add(NavButton("Game Session", "▶"));
            nav.Children.Add(NavSection("TOOLS")); nav.Children.Add(NavButton("Windows", "⊞")); nav.Children.Add(NavButton("Boost-Up", "✦")); nav.Children.Add(NavButton("Network", "⌁")); nav.Children.Add(NavButton("Lab", "⌘"));
            nav.Children.Add(NavSection("MANAGE")); nav.Children.Add(NavButton("Restore", "↶")); nav.Children.Add(NavButton("Settings", "⚙"));
            nav.Children.Add(NavButton("Guide", "?"));
            var footer = new Border { BorderBrush = Brush(BorderColor), BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(10, 12, 0, 0), Margin = new Thickness(2, 12, 2, 0), VerticalAlignment = VerticalAlignment.Bottom };
            footer.Padding = new Thickness(0, 12, 0, 0); footer.ToolTip = "Version 2.0.0"; footer.Child = Text("2.0.0", 9, Brush(MutedColor), false);
            DockPanel.SetDock(footer, Dock.Bottom); stack.Children.Add(footer);
            var navScroll = new ScrollViewer { Content = nav, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
            stack.Children.Add(navScroll); side.Child = stack; return side;
        }

        private TextBlock NavSection(string title)
        { return new TextBlock { Visibility = Visibility.Collapsed, IsHitTestVisible = false }; }

        private Button NavButton(string title, string glyph)
        {
            var button = new Button { Tag = title, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(10, 0, 8, 0), Height = 44, Margin = new Thickness(0), Foreground = Brush(MutedColor), Background = Brushes.Transparent,
                BorderBrush = Brushes.Transparent, BorderThickness = new Thickness(1), FontSize = 12.5, Cursor = Cursors.Hand };
            var row = new Grid(); row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(4) }); row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) }); row.ColumnDefinitions.Add(new ColumnDefinition());
            var indicator = new Border { Width = 3, Height = 20, CornerRadius = new CornerRadius(2), Background = Brushes.Transparent, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
            row.Children.Add(indicator); _navIndicators[title] = indicator;
            var icon = new System.Windows.Shapes.Path { Data = SidebarIcon(title), Width = 24, Height = 24, Stretch = Stretch.None, Fill = Brush(MutedColor) };
            var iconFrame = new Viewbox { Width = 24, Height = 24, Child = icon, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
            Grid.SetColumn(iconFrame, 1); row.Children.Add(iconFrame); _navIcons[title] = icon;
            var label = new TextBlock { Text = PageLabel(title), Visibility = Visibility.Collapsed, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
            BindingOperations.SetBinding(label, TextBlock.ForegroundProperty, new Binding("Foreground") { Source = button });
            Grid.SetColumn(label, 2); row.Children.Add(label); button.Content = row; button.ToolTip = PageLabel(title);
            System.Windows.Automation.AutomationProperties.SetName(button, PageLabel(title));
            var chrome = new FrameworkElementFactory(typeof(Border)); chrome.SetValue(Border.CornerRadiusProperty, new CornerRadius(10));
            chrome.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Button.BackgroundProperty));
            chrome.SetValue(Border.BorderBrushProperty, new TemplateBindingExtension(Button.BorderBrushProperty));
            chrome.SetValue(Border.BorderThicknessProperty, new TemplateBindingExtension(Button.BorderThicknessProperty));
            var content = new FrameworkElementFactory(typeof(ContentPresenter)); content.SetValue(ContentPresenter.MarginProperty, new TemplateBindingExtension(Button.PaddingProperty));
            content.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Left); content.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
            chrome.AppendChild(content); button.Template = new ControlTemplate(typeof(Button)) { VisualTree = chrome };
            button.Click += delegate { ShowPage(title); }; _navButtons[title] = button; return button;
        }

        private void AddPage(Grid host, string name, Func<UIElement> factory)
        {
            var border = new Border { Visibility = Visibility.Collapsed };
            _pageFactories[name] = factory;
            _pages[name] = border; host.Children.Add(border);
        }

        private static ScrollViewer PageScroll(UIElement content)
        { return new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }; }

        private UIElement BuildDashboard()
        { return BuildCompactDashboard(); }

        private UIElement BuildOptimize()
        {
            var panel = ScrollColumn();
            var presetSection = new StackPanel();
            var presetCard = Card(); presetCard.Padding = new Thickness(13, 10, 13, 10); var presetGrid = new Grid(); presetGrid.ColumnDefinitions.Add(new ColumnDefinition()); presetGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var presetCopy = new StackPanel(); presetCopy.Children.Add(Text("Quick presets", 12, Brushes.White, true)); presetCopy.Children.Add(Text("Presets select options for you to review. Nothing is applied automatically.", 10, Brush(MutedColor), false, 0, 2)); presetGrid.Children.Add(presetCopy);
            var presetActions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            _presetPicker = new ComboBox { Width = 190, Height = 36, Padding = new Thickness(8, 6, 8, 6), Background = Brush(SurfaceColor), Foreground = Brushes.White, BorderBrush = Brush(BorderColor), BorderThickness = new Thickness(1) };
            foreach (string name in new[] { "Safe Essentials", "Competitive Gaming", "Max Privacy", "Low-End PC", "Laptop Safe" }) _presetPicker.Items.Add(new ComboBoxItem { Content = name, Tag = name }); _presetPicker.SelectedIndex = 0;
            var loadPreset = ActionButton("Select preset", false); loadPreset.Click += delegate { var selected = _presetPicker.SelectedItem as ComboBoxItem; if (selected != null) SelectPreset(Convert.ToString(selected.Tag)); };
            presetActions.Children.Add(_presetPicker); presetActions.Children.Add(loadPreset); Grid.SetColumn(presetActions, 1); presetGrid.Children.Add(presetActions); presetCard.Child = presetGrid; presetSection.Children.Add(presetCard);
            var savedCard = Card(); var savedBody = new StackPanel(); savedBody.Children.Add(Text("Your presets", 14, Brushes.White, true));
            _presetEditStatus = Text("Save your selected options or manage your own presets and share codes.", 11, Brush(MutedColor), false, 0, 4); savedBody.Children.Add(_presetEditStatus);
            var savedActions = new WrapPanel { Margin = new Thickness(-5, 7, 0, 0) };
            _savePresetButton = ActionButton("Save selection", false); _savePresetButton.Click += delegate { SaveUserPreset(); };
            var managePresets = ActionButton("Manage presets", false); managePresets.Click += delegate { ShowPresetManager(); };
            _finishPresetEditing = ActionButton("Finish editing", false); _finishPresetEditing.Click += delegate { _editingPreset = null; RefreshPresetEditStatus(); };
            savedActions.Children.Add(_savePresetButton); savedActions.Children.Add(managePresets); savedActions.Children.Add(_finishPresetEditing); savedBody.Children.Add(savedActions); savedCard.Child = savedBody; presetSection.Children.Add(savedCard);
            _presetsExpander = new Expander { Header = "Presets · 5 built-in + " + _state.SavedPresets.Count + " saved", Content = presetSection, Foreground = Brushes.White, FontSize = 12, Margin = new Thickness(0, 0, 0, 13), Padding = new Thickness(0, 4, 0, 4) }; panel.Children.Add(_presetsExpander); RefreshPresetEditStatus();
            var filterBar = new Grid { Margin = new Thickness(0, 0, 0, 10) }; filterBar.ColumnDefinitions.Add(new ColumnDefinition()); filterBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) });
            var searchHost = new Grid();
            _tweakSearch = new TextBox { Height = 38, Padding = new Thickness(36, 8, 11, 8), Background = Brush(SurfaceColor), Foreground = Brushes.White, BorderBrush = Brush(BorderColor), BorderThickness = new Thickness(1), ToolTip = "Search by name, category, or description" }; searchHost.Children.Add(_tweakSearch);
            var searchIcon = new TextBlock { Text = "\uE721", FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 13, Foreground = Brush(MutedColor), Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false }; searchHost.Children.Add(searchIcon);
            var placeholder = Text("Search optimizations…", 11, Brush(MutedColor), false, 36); placeholder.IsHitTestVisible = false; searchHost.Children.Add(placeholder);
            if (_tweakSearchTimer != null) _tweakSearchTimer.Stop(); _tweakSearchTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(140) };
            _tweakSearchTimer.Tick += delegate { _tweakSearchTimer.Stop(); RenderTweakCards(); };
            _tweakSearch.TextChanged += delegate { placeholder.Visibility = _tweakSearch.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; _tweakSearchTimer.Stop(); _tweakSearchTimer.Start(); }; filterBar.Children.Add(searchHost);
            _categoryFilter = new ComboBox { Height = 36, Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(8, 6, 8, 6), Background = Brush(SurfaceColor), Foreground = Brushes.White, BorderBrush = Brush(BorderColor), BorderThickness = new Thickness(1) };
            _categoryFilter.Items.Add(new ComboBoxItem { Content = "All categories", Tag = "All categories" });
            foreach (string category in _catalogue.Select(x => x.Category).Distinct()) {
                var choice = new ComboBoxItem { Content = category, Tag = category };
                if (!Definitions.Any(x => x.Category == category)) Localization.KeepData(choice);
                _categoryFilter.Items.Add(choice);
            }
            _categoryFilter.SelectedIndex = 0; _categoryFilter.SelectionChanged += delegate { RenderTweakCards(); };
            Grid.SetColumn(_categoryFilter, 1); filterBar.Children.Add(_categoryFilter); panel.Children.Add(filterBar);
            panel.Children.Add(BuildRecommendedControls());
            panel.Children.Add(BuildExistingTweakScanControls());
            _tweakList = new StackPanel();
            panel.Children.Add(_tweakList); RenderTweakCards(); return panel;
        }

        private void SelectPreset(string name)
        {
            _editingPreset = null; RefreshPresetEditStatus();
            var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (name == "Safe Essentials") ids.UnionWith(new[] { "game-mode", "file-extensions", "startup-delay", "menu-delay", "advertising-id", "start-web-search", "activity-history", "feedback-prompts", "typing-collection", "clipboard-sync", "gamebar-overlay" });
            else if (name == "Competitive Gaming") ids.UnionWith(new[] { "game-mode", "game-capture", "gamebar-overlay", "raw-mouse", "fullscreen-optimizations" });
            else if (name == "Max Privacy") ids.UnionWith(new[] { "advertising-id", "start-web-search", "activity-history", "feedback-prompts", "typing-collection", "clipboard-sync", "disable-copilot", "disable-cortana-cloud-search", "disable-consumer-suggestions", "remove-windows-ads", "disable-windows-ai-capture", "disable-app-inventory", "disable-location-policy", "disable-update-sharing", "disable-lockscreen-tips" });
            else if (name == "Low-End PC") ids.UnionWith(new[] { "lightweight-visuals", "limit-background-apps", "disable-edge-startup-boost", "startup-delay", "game-mode" });
            else if (name == "Laptop Safe") ids.UnionWith(new[] { "game-mode", "file-extensions", "startup-delay", "menu-delay", "advertising-id", "start-web-search", "activity-history", "feedback-prompts", "typing-collection", "clipboard-sync", "gamebar-overlay", "disable-consumer-suggestions", "disable-edge-startup-boost" });
            _selectedTweaks.Clear(); foreach (string id in ids) if (CanSelectTweak(id) && !_state.Applied.Any(x => x.Id == id)) _selectedTweaks.Add(id);
            if (_tweakSearch != null) _tweakSearch.Clear(); if (_categoryFilter != null) _categoryFilter.SelectedIndex = 0;
            RenderTweakCards(); ShowPage("Optimize");
        }

        private UIElement BuildGames()
        {
            var panel = ScrollColumn();
            var intro = Card(); var introGrid = new Grid(); introGrid.ColumnDefinitions.Add(new ColumnDefinition()); introGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var copy = new StackPanel(); copy.Children.Add(Text("Game profiles", 20, Brushes.White, true));
            copy.Children.Add(Text("Find installed games, review their tips, and choose safe Windows-level changes.", 11, Brush(MutedColor), false, 0, 5));
            _gameStatus = Text("Scan common library folders to find supported games.", 10, Brush(MutedColor), false, 0, 8); copy.Children.Add(_gameStatus); introGrid.Children.Add(copy);
            var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            _scanGamesButton = ActionButton("Scan for games", true); _scanGamesButton.Click += delegate { ScanForGames(); };
            var add = ActionButton("Add game", false); add.Click += delegate { AddCustomGame(); }; actions.Children.Add(_scanGamesButton); actions.Children.Add(add);
            Grid.SetColumn(actions, 1); introGrid.Children.Add(actions); intro.Child = introGrid; panel.Children.Add(intro);

            var browser = new Grid { Height = 530 }; browser.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(300) }); browser.ColumnDefinitions.Add(new ColumnDefinition());
            var listCard = Card(); listCard.Padding = new Thickness(10); listCard.Margin = new Thickness(0, 0, 7, 0);
            _gameList = new StackPanel(); listCard.Child = new ScrollViewer { Content = _gameList, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            browser.Children.Add(listCard);
            var detailCard = Card(); detailCard.Margin = new Thickness(7, 0, 0, 0);
            _gameDetail = new StackPanel(); detailCard.Child = new ScrollViewer { Content = _gameDetail, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            Grid.SetColumn(detailCard, 1); browser.Children.Add(detailCard); panel.Children.Add(browser);
            int savedFound = AllGames().Count(x => PathsFor(x).Count > 0);
            _gameStatus.Text = savedFound > 0 ? "Saved scan · " + savedFound + " installed profile" + (savedFound == 1 ? "" : "s") + " detected." : "Scan common library folders to find supported games.";
            RenderGameList(); RenderGameDetail(); return panel;
        }

        private UIElement BuildGameSession()
        {
            var panel = ScrollColumn();
            var intro = Card(); var introStack = new StackPanel();
            introStack.Children.Add(Text("A calmer start to your game", 20, Brushes.White, true));
            introStack.Children.Add(Text("Start a session with a game, ask selected apps to close normally, and restore the previous power plan when the game exits.", 11, Brush(MutedColor), false, 0, 5));
            introStack.Children.Add(Text("Review the selected apps before starting. A close request can prompt you to save work.", 10, Brush(MutedColor), false, 0, 8));
            intro.Child = introStack; panel.Children.Add(intro);

            var gameCard = Card(); var gameStack = new StackPanel(); gameStack.Children.Add(Text("Game to start", 13, Brushes.White, true));
            _sessionGamePicker = new ComboBox { Height = 36, Margin = new Thickness(0, 8, 0, 8), Padding = new Thickness(8, 6, 8, 6), Background = Brush(SurfaceColor), Foreground = Brushes.White, BorderBrush = Brush(BorderColor) };
            gameStack.Children.Add(_sessionGamePicker); RefreshSessionGames();
            _sessionUsePerformancePlan = new CheckBox { Content = "Switch to High performance power plan for this session", IsChecked = false, Foreground = Brush(MutedColor), Margin = new Thickness(0, 4, 0, 6), ToolTip = "The currently active plan is restored when the session ends." };
            gameStack.Children.Add(_sessionUsePerformancePlan);
            var planNote = Text("Optional. Power plan changes may be unavailable on some PCs and use more power.", 10, Brush(MutedColor), false, 0, 2); gameStack.Children.Add(planNote);
            AddSessionProfileControls(gameStack);
            _sessionStatus = Text("No game session is running.", 11, Brush(MutedColor), true, 0, 12); gameStack.Children.Add(_sessionStatus);
            var sessionButtons = new WrapPanel { Margin = new Thickness(-4, 7, 0, 0) };
            _sessionStartButton = ActionButton("Start game session", true); _sessionStartButton.Click += delegate { StartGameSession(); };
            _sessionEndButton = ActionButton("End session", false); _sessionEndButton.IsEnabled = SessionRecoveryPending; _sessionEndButton.Click += async delegate { await EndGameSession(true); };
            sessionButtons.Children.Add(_sessionStartButton); sessionButtons.Children.Add(_sessionEndButton); gameStack.Children.Add(sessionButtons); gameCard.Child = gameStack; panel.Children.Add(gameCard);

            var appsCard = Card(); var appsStack = new StackPanel();
            var appHeader = new Grid(); appHeader.ColumnDefinitions.Add(new ColumnDefinition()); appHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var appTitle = new StackPanel(); appTitle.Children.Add(Text("Selected apps", 13, Brushes.White, true)); appTitle.Children.Add(Text("Choose apps for the session action. Protected apps stay untouched.", 10, Brush(MutedColor), false, 0, 3)); appHeader.Children.Add(appTitle);
            var refresh = ActionButton("Refresh", false); refresh.Click += delegate { RefreshSessionProcesses(); }; Grid.SetColumn(refresh, 1); appHeader.Children.Add(refresh); appsStack.Children.Add(appHeader);
            _sessionProcessList = new StackPanel { Margin = new Thickness(0, 10, 0, 0) }; appsStack.Children.Add(_sessionProcessList); appsCard.Child = appsStack; panel.Children.Add(appsCard);
            LoadSessionProfile();
            panel.Children.Add(BuildSessionReports());
            return panel;
        }

        private void RefreshSessionGames()
        {
            if (_sessionGamePicker == null) return;
            if (_sessionStarting || (_sessionTimer != null && _sessionTimer.IsEnabled)) return;
            var previous = _sessionGamePicker.SelectedItem as ComboBoxItem; string previousKey = previous == null ? "_manual" : previous.Uid;
            _sessionGamePicker.Items.Clear();
            _sessionGamePicker.Items.Add(new ComboBoxItem { Content = "Manual session (start the game yourself)", Tag = null, Uid = "_manual" });
            foreach (GameDefinition game in AllGames())
            {
                string path = PathsFor(game).FirstOrDefault(x => File.Exists(x));
                if (String.IsNullOrEmpty(path)) continue;
                _sessionGamePicker.Items.Add(new ComboBoxItem { Content = game.Name, Tag = path, Uid = game.Id });
            }
            _sessionGamePicker.SelectedItem = _sessionGamePicker.Items.Cast<ComboBoxItem>().FirstOrDefault(x => x.Uid == previousKey) ?? (ComboBoxItem)_sessionGamePicker.Items[0];
        }

        private void RefreshSessionProcesses()
        {
            if (_sessionProcessList == null) return;
            _sessionProcessChecks.Clear(); _sessionProcessList.Children.Clear();
            var processes = new List<Process>();
            foreach (Process process in Process.GetProcesses())
            {
                try
                {
                    if (process.Id == Process.GetCurrentProcess().Id || process.MainWindowHandle == IntPtr.Zero || String.IsNullOrWhiteSpace(process.MainWindowTitle)) { process.Dispose(); continue; }
                    if (IsProtectedSessionProcess(process.ProcessName)) { process.Dispose(); continue; }
                    processes.Add(process);
                }
                catch { try { process.Dispose(); } catch { } }
            }
            foreach (Process process in processes.OrderBy(x => x.ProcessName, StringComparer.OrdinalIgnoreCase).Take(50))
            {
                try {
                    DateTime started = process.StartTime.ToUniversalTime();
                    var identity = new SessionProcessIdentity { Id = process.Id, Name = process.ProcessName, StartedUtc = started, StartedTicks = started.Ticks };
                    var check = new CheckBox { Tag = identity, Content = identity.Name + "  ·  " + process.MainWindowTitle, Foreground = Brush(MutedColor), Margin = new Thickness(2, 3, 2, 3), ToolTip = "The app will be asked to close normally." };
                    ApplySessionProcessSelection(check, identity);
                    _sessionProcessChecks.Add(check); _sessionProcessList.Children.Add(check);
                } catch { } finally { process.Dispose(); }
            }
            foreach (Process process in processes) process.Dispose();
            if (_sessionProcessChecks.Count == 0) _sessionProcessList.Children.Add(Text("No other app windows found.", 10, Brush(MutedColor), false, 2, 5));
        }

        private async void StartGameSession()
        {
            if (_state.MaintenanceServices.Count > 0) { ShowPage("Restore"); MessageBox.Show(this, "Maintenance services need recovery", "Restore", MessageBoxButton.OK, MessageBoxImage.Warning); return; }
            if (_sessionStarting || (_sessionEndingTask != null && !_sessionEndingTask.IsCompleted) || (_sessionTimer != null && _sessionTimer.IsEnabled)) return;
            if (SessionRecoveryPending || _state.ActiveSessionReport != null) { await RecoverInterruptedSession(); }
            if (SessionRecoveryPending) { MessageBox.Show(this, "A previous session still has settings waiting to be restored. End session to retry before starting another session.", "Session recovery", MessageBoxButton.OK, MessageBoxImage.Warning); _sessionEndButton.IsEnabled = true; return; }
            _sessionActionNotes.Clear();
            string launchPath = null;
            ComboBoxItem choice = _sessionGamePicker == null ? null : _sessionGamePicker.SelectedItem as ComboBoxItem;
            if (choice != null) launchPath = choice.Tag as string;
            bool pauseUpdates = _sessionPauseUpdate.IsChecked == true, trimMemory = _sessionTrimMemory.IsChecked == true;
            if (!String.IsNullOrEmpty(launchPath) && !File.Exists(launchPath)) { MessageBox.Show(this, "The selected game executable was not found. Scan for games again or choose a different game.", "Game not found", MessageBoxButton.OK, MessageBoxImage.Warning); return; }
            var selectedApps = _sessionProcessChecks.Where(x => x.IsChecked == true).Select(x => x.Tag as SessionProcessIdentity).Where(x => x != null && !IsKeptSessionProcess(x.Name) && !String.Equals(x.Name, Path.GetFileNameWithoutExtension(launchPath), StringComparison.OrdinalIgnoreCase)).ToList();
            string review = "Game: " + (choice == null ? "Manual session" : Convert.ToString(choice.Content)) + "\n\nSelected apps: " + (selectedApps.Count == 0 ? "None" : String.Join(", ", selectedApps.Select(x => x.Name).Distinct(StringComparer.OrdinalIgnoreCase))) + "\n\nApp action: " + (SessionLowersPriority ? "Lower priority temporarily, then restore original priority." : "Ask apps to close normally.") + "\n\nPower plan: " + (_sessionUsePerformancePlan.IsChecked == true ? "High performance for this session, then restore the previous plan." : "Keep current plan.");
            if (selectedApps.Count > 0 && !SessionLowersPriority) review += "\n\nApps can prompt you to save work. Closed apps are not reopened automatically.";
            if (_sessionPauseUpdate.IsChecked == true) review += "\n\nTemporarily stop the Windows Update service if it is running, then resume it.";
            if (_sessionTrimMemory.IsChecked == true) review += "\n\nTrim background app working sets once. Apps may reload memory and briefly slow down.";
            if (MessageBox.Show(this, review + "\n\nStart this session?", "Review Game Boost", MessageBoxButton.OKCancel, MessageBoxImage.Information) != MessageBoxResult.OK) return;
            try { BeginSessionReport(choice == null ? "Manual session" : Convert.ToString(choice.Content)); }
            catch (Exception ex) { MessageBox.Show(this, "Could not save session recovery: " + ex.Message, "Session not started", MessageBoxButton.OK, MessageBoxImage.Warning); return; }
            _sessionStarting = true; SetSessionControlsEnabled(false); _sessionStartButton.IsEnabled = false; _sessionEndButton.IsEnabled = false;
            _sessionStatus.Text = "Preparing session…";
            Exception setupError = null;
            try {
            try {
            foreach (SessionProcessIdentity identity in selectedApps)
            {
                if (SessionLowersPriority) { LowerSessionPriority(identity); continue; }
                try { using (Process process = Process.GetProcessById(identity.Id)) { if (identity.Matches(process)) _sessionActionNotes.Add((process.CloseMainWindow() ? "Asked app to close: " : "App stayed open: ") + identity.Name); } }
                catch (Exception ex) { _sessionActionNotes.Add("Could not close " + identity.Name + ": " + ex.Message); }
            }
            _sessionPlanNotice = null;
            if (_sessionUsePerformancePlan != null && _sessionUsePerformancePlan.IsChecked == true) TrySwitchToPerformancePlan();
            if (!String.IsNullOrEmpty(_sessionPlanNotice)) _sessionActionNotes.Add(_sessionPlanNotice);
            if (pauseUpdates) await PauseSessionUpdates();
            if (trimMemory) _sessionActionNotes.Add(await Task.Run(new Func<string>(TrimSessionMemory)));
            if (_sessionExitAfterStart) { await EndGameSession(false); return; }
            _sessionProcessName = null; _sessionSawGame = false; _sessionMissingChecks = 0; _sessionStarted = DateTime.Now;
            if (!String.IsNullOrEmpty(launchPath))
            {
                if (!File.Exists(launchPath)) { await EndGameSession(false); MessageBox.Show(this, "The selected game executable was not found. Scan for games again or choose a different game.", "Game not found", MessageBoxButton.OK, MessageBoxImage.Warning); return; }
                _sessionProcessName = Path.GetFileNameWithoutExtension(launchPath);
                Exception launchFailure = null;
                try
                {
                    if (GameProcessRunning(_sessionProcessName)) _sessionSawGame = true;
                    else { Process launched = Process.Start(new ProcessStartInfo(launchPath) { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(launchPath) }); _sessionSawGame = launched != null; if (launched != null) launched.Dispose(); }
                }
                catch (Exception ex) { launchFailure = ex; }
                if (launchFailure != null) { _sessionActionNotes.Add("Could not launch game: " + launchFailure.Message); await EndGameSession(false); MessageBox.Show(this, "Could not start this game: " + launchFailure.Message, "Launch failed", MessageBoxButton.OK, MessageBoxImage.Error); return; }
            }
            CheckpointSessionReport();
            _sessionTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
            _sessionTimer.Tick += delegate { CheckGameSession(); }; _sessionTimer.Start();
            if (_sessionStartButton != null) _sessionStartButton.IsEnabled = false;
            if (_sessionEndButton != null) _sessionEndButton.IsEnabled = true;
            SetSessionControlsEnabled(false);
            _sessionStatus.Text = _sessionProcessName == null ? "Manual game session is active. End it here when you finish." : "Session active · restoring settings after " + Path.GetFileNameWithoutExtension(launchPath) + " closes.";
            if (!String.IsNullOrEmpty(_sessionPlanNotice)) _sessionStatus.Text += "\n" + _sessionPlanNotice;
            } catch (Exception ex) { setupError = ex; }
            if (setupError != null) { _sessionActionNotes.Add("Session setup failed: " + setupError.Message); await EndGameSession(true); }
            }
            finally { _sessionStarting = false; if (_sessionExitAfterStart) { _sessionExitAfterStart = false; _allowExit = true; Close(); } }
        }

        private async void CheckGameSession()
        {
            if (String.IsNullOrEmpty(_sessionProcessName)) return;
            bool running = false;
            try { running = GameProcessRunning(_sessionProcessName); } catch { return; }
            if (running) { _sessionSawGame = true; _sessionMissingChecks = 0; }
            else if (_sessionSawGame) { _sessionMissingChecks++; if (_sessionMissingChecks >= 2) await EndGameSession(true); }
            else if ((DateTime.Now - _sessionStarted).TotalSeconds > 180) await EndGameSession(true);
        }

        private void TrySwitchToPerformancePlan()
        {
            int getExit; string schemes = RunPowerCfg("/list", out getExit);
            string highPlan = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c";
            int activeExit; string active = RunPowerCfg("/getactivescheme", out activeExit);
            Match currentMatch = Regex.Match(active ?? "", "[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}");
            if (getExit != 0 || activeExit != 0 || !Regex.IsMatch(schemes ?? "", Regex.Escape(highPlan), RegexOptions.IgnoreCase) || !currentMatch.Success)
            { _sessionPlanNotice = "High performance plan is unavailable; no power change was made."; return; }
            if (String.Equals(currentMatch.Value, highPlan, StringComparison.OrdinalIgnoreCase)) { _sessionPlanNotice = "Already using the High performance plan."; return; }
            _state.SessionPreviousPlan = currentMatch.Value;
            try { SaveState(); }
            catch { _state.SessionPreviousPlan = null; _sessionPlanNotice = "Could not save a restore point for the power plan, so it was left unchanged."; return; }
            int setExit; RunPowerCfg("/setactive " + highPlan, out setExit);
            if (setExit != 0) { _state.SessionPreviousPlan = null; try { SaveState(); } catch { } _sessionPlanNotice = "Could not switch power plans; the current plan was left active."; }
        }

        private void RestoreSessionPlan()
        {
            if (String.IsNullOrEmpty(_state.SessionPreviousPlan)) return;
            int exit; RunPowerCfg("/setactive " + _state.SessionPreviousPlan, out exit);
            if (exit == 0) { _state.SessionPreviousPlan = null; SaveState(); }
        }

        private Task EndGameSession(bool showStatus)
        {
            if (_sessionEndingTask != null && !_sessionEndingTask.IsCompleted) return _sessionEndingTask;
            return _sessionEndingTask = EndGameSessionCore(showStatus);
        }

        private async Task EndGameSessionCore(bool showStatus)
        {
            if (_sessionTimer != null) { _sessionTimer.Stop(); _sessionTimer = null; }
            SetSessionControlsEnabled(false);
            if (_sessionStartButton != null) _sessionStartButton.IsEnabled = false;
            if (_sessionEndButton != null) _sessionEndButton.IsEnabled = false;
            if (_sessionStatus != null) _sessionStatus.Text = "Restoring session settings…";
            try { RestoreSessionPlan(); } catch (Exception ex) { _sessionActionNotes.Add("Could not restore power plan: " + ex.Message); }
            await RestoreSessionUpdates();
            RestoreSessionPriorities(); _sessionProcessName = null; _sessionSawGame = false; _sessionMissingChecks = 0;
            if (_sessionStartButton != null) _sessionStartButton.IsEnabled = true;
            bool pending = SessionRecoveryPending;
            if (_sessionEndButton != null) _sessionEndButton.IsEnabled = pending;
            SetSessionControlsEnabled(true);
            if (showStatus && _sessionStatus != null) _sessionStatus.Text = pending ? "Session ended with restoration pending. End session retries; startup also retries." : "Game session ended. Temporary settings restored.";
            FinishSessionReport(false);
        }

        private async Task RecoverInterruptedSession()
        {
            if (!SessionRecoveryPending && _state.ActiveSessionReport == null) return;
            if (_state.ActiveSessionReport != null) _state.ActiveSessionReport.Interrupted = true;
            await EndGameSession(true);
        }

        private static string RunPowerCfg(string arguments, out int exitCode)
        { return RunCapturedSystemTool("powercfg.exe", arguments, 30000, out exitCode); }

        private static string RunCapturedSystemTool(string executable, string arguments, int timeoutMilliseconds, out int exitCode)
        {
            exitCode = -1;
            try {
                if (!new[] { "powercfg.exe", "bcdedit.exe", "netsh.exe", "schtasks.exe", "sc.exe", "defrag.exe", "ipconfig.exe" }.Contains(executable, StringComparer.OrdinalIgnoreCase)) throw new ArgumentException("Unsupported Windows tool.");
                var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, executable), arguments) {
                    UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
                    StandardOutputEncoding = Encoding.GetEncoding((int)GetOEMCP()), StandardErrorEncoding = Encoding.GetEncoding((int)GetOEMCP())
                };
                using (var process = new Process { StartInfo = info }) {
                    var output = new StringBuilder(); var errors = new StringBuilder(); object outputLock = new object(); bool truncated = false;
                    var outputDone = new TaskCompletionSource<bool>(); var errorsDone = new TaskCompletionSource<bool>();
                    Action<StringBuilder, TaskCompletionSource<bool>, string> collect = delegate(StringBuilder target, TaskCompletionSource<bool> done, string line) {
                        if (line == null) { done.TrySetResult(true); return; }
                        lock (outputLock) {
                            int remaining = Math.Max(0, 512 * 1024 - output.Length - errors.Length);
                            int take = Math.Min(line.Length, remaining); target.Append(line, 0, take);
                            if (take < line.Length) truncated = true;
                            else if (remaining - take >= Environment.NewLine.Length) target.AppendLine();
                            else truncated = true;
                        }
                    };
                    process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { collect(output, outputDone, e.Data); };
                    process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { collect(errors, errorsDone, e.Data); };
                    if (!process.Start()) throw new InvalidOperationException("Windows could not start " + executable + ".");
                    try {
                        process.BeginOutputReadLine(); process.BeginErrorReadLine();
                        if (!process.WaitForExit(timeoutMilliseconds)) throw new System.TimeoutException("Windows tool " + executable + " exceeded its time limit.");
                        if (!Task.WaitAll(new Task[] { outputDone.Task, errorsDone.Task }, 2000)) throw new System.TimeoutException("Windows tool " + executable + " did not finish returning its output.");
                        lock (outputLock) {
                            if (truncated) throw new InvalidOperationException("Windows tool " + executable + " exceeded the output limit.");
                            exitCode = process.ExitCode;
                            return errors.Length == 0 ? output.ToString() : output.ToString() + Environment.NewLine + errors.ToString();
                        }
                    } catch {
                        try { if (!process.HasExited) { process.Kill(); process.WaitForExit(2000); } } catch { }
                        throw;
                    }
                }
            } catch (Exception ex) { return ex.Message; }
        }

        private static string ActivePowerPlan()
        {
            IntPtr pointer; uint status = PowerGetActiveScheme(IntPtr.Zero, out pointer);
            if (status != 0 || pointer == IntPtr.Zero) throw new InvalidOperationException("Windows could not read the active power plan.");
            try { return ((Guid)Marshal.PtrToStructure(pointer, typeof(Guid))).ToString("D"); }
            finally { LocalFree(pointer); }
        }

        private static void RequirePowerCfg(string arguments)
        {
            int exit; string output = RunPowerCfg(arguments, out exit);
            if (exit != 0) throw new InvalidOperationException("Windows could not change the power configuration. " + output.Trim());
        }

        private void ApplyUltimatePlan(AppliedTweak record)
        {
            // The unique destination GUID is persisted before duplication, so interrupted changes remain undoable.
            RequirePowerCfg("/duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 " + record.CreatedPowerPlan);
            RequirePowerCfg("/changename " + record.CreatedPowerPlan + " \"SharkOptimizer Ultimate\"");
            RequirePowerCfg("/setactive " + record.TargetPowerPlan);
        }

        private static bool HibernationEnabled()
        {
            string path = Path.Combine(Path.GetPathRoot(Environment.SystemDirectory), "hiberfil.sys");
            try { File.GetAttributes(path); return true; }
            catch (FileNotFoundException) { return false; }
            catch (DirectoryNotFoundException) { return false; }
        }

        private static void SetHibernation(bool enabled)
        {
            RequirePowerCfg("/hibernate " + (enabled ? "on" : "off"));
            if (HibernationEnabled() != enabled) throw new InvalidOperationException("Windows did not confirm the requested hibernation state.");
        }

        private static bool ReadMemoryCompression()
        {
            using (var provider = new ManagementClass(new ManagementScope(@"\\.\root\Microsoft\Windows\PS_MMAgent"), new ManagementPath("PS_MMAgent"), null))
            using (ManagementBaseObject result = provider.InvokeMethod("Get", null, null))
            {
                if (result == null || Convert.ToUInt32(result["ReturnValue"]) != 0) throw new InvalidOperationException("Windows could not read memory compression.");
                using (ManagementBaseObject components = result["CmdletOutput"] as ManagementBaseObject)
                {
                    if (components == null || components["MemoryCompression"] == null) throw new InvalidOperationException("This Windows version did not expose memory compression.");
                    return Convert.ToBoolean(components["MemoryCompression"]);
                }
            }
        }

        private static void SetMemoryCompression(bool enabled)
        {
            using (var provider = new ManagementClass(new ManagementScope(@"\\.\root\Microsoft\Windows\PS_MMAgent"), new ManagementPath("PS_MMAgent"), null))
            using (ManagementBaseObject input = provider.GetMethodParameters(enabled ? "Enable" : "Disable"))
            {
                input["ApplicationLaunchPrefetching"] = false; input["ApplicationPreLaunch"] = false;
                input["OperationAPI"] = false; input["PageCombining"] = false; input["MemoryCompression"] = true;
                using (ManagementBaseObject result = provider.InvokeMethod(enabled ? "Enable" : "Disable", input, null))
                    if (result == null || Convert.ToUInt32(result["ReturnValue"]) != 0) throw new InvalidOperationException("Windows could not change memory compression.");
            }
            if (ReadMemoryCompression() != enabled) throw new InvalidOperationException("Windows did not confirm the requested memory-compression state.");
        }

        private static void RequireMemoryCompressionHardware()
        {
            ulong total = 0;
            using (var search = new ManagementObjectSearcher("SELECT Capacity FROM Win32_PhysicalMemory"))
            using (ManagementObjectCollection rows = search.Get()) foreach (ManagementObject row in rows) using (row) total += Convert.ToUInt64(row["Capacity"]);
            if (total < 16UL * 1024 * 1024 * 1024) throw new InvalidOperationException("Disabling memory compression requires at least 16 GB installed RAM.");
        }

        private static List<PowerSettingChange> CapturePowerSettings(List<PowerTarget> targets)
        {
            var changes = new List<PowerSettingChange>(); if (targets == null || targets.Count == 0) return changes;
            IntPtr activePointer = IntPtr.Zero; uint status = PowerGetActiveScheme(IntPtr.Zero, out activePointer);
            if (status != 0 || activePointer == IntPtr.Zero) throw new InvalidOperationException("Windows could not read the active power plan.");
            Guid scheme; try { scheme = (Guid)Marshal.PtrToStructure(activePointer, typeof(Guid)); } finally { LocalFree(activePointer); }
            foreach (PowerTarget target in targets)
            {
                Guid subgroup = new Guid(target.SubgroupGuid), setting = new Guid(target.SettingGuid); uint ac = 0, dc = 0;
                if (PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, out ac) != 0) throw new InvalidOperationException("Windows could not read a supported AC power setting.");
                if (PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, out dc) != 0) throw new InvalidOperationException("Windows could not read a supported battery power setting.");
                changes.Add(new PowerSettingChange { SchemeGuid = scheme.ToString("D"), SubgroupGuid = target.SubgroupGuid, SettingGuid = target.SettingGuid, OriginalAc = ac, OriginalDc = dc, TargetAc = target.TargetAc, TargetDc = target.TargetDc, SetAc = target.SetAc, SetDc = target.SetDc });
            }
            return changes;
        }

        private static void SetPowerSettings(List<PowerSettingChange> changes, bool restore)
        {
            if (changes == null || changes.Count == 0) return;
            foreach (PowerSettingChange change in changes)
            {
                Guid scheme = new Guid(change.SchemeGuid), subgroup = new Guid(change.SubgroupGuid), setting = new Guid(change.SettingGuid);
                if (change.SetAc && PowerWriteACValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, restore ? change.OriginalAc : change.TargetAc) != 0)
                    throw new InvalidOperationException("Windows could not update the saved AC power setting.");
                if (change.SetDc && PowerWriteDCValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, restore ? change.OriginalDc : change.TargetDc) != 0)
                    throw new InvalidOperationException("Windows could not update the saved battery power setting.");
                if (PowerSetActiveScheme(IntPtr.Zero, ref scheme) != 0) throw new InvalidOperationException("Windows could not activate the updated power plan.");
            }
        }

        private static bool PowerSettingsMatch(List<PowerSettingChange> changes)
        {
            if (changes == null) return true;
            foreach (PowerSettingChange change in changes) try
            {
                Guid scheme = new Guid(change.SchemeGuid), subgroup = new Guid(change.SubgroupGuid), setting = new Guid(change.SettingGuid); uint ac, dc;
                if (PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, out ac) != 0 || PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, out dc) != 0) return false;
                if ((change.SetAc && ac != change.TargetAc) || (change.SetDc && dc != change.TargetDc)) return false;
            }
            catch { return false; }
            return true;
        }

        private static string RunBcdEdit(string arguments, out int exitCode)
        { return RunCapturedSystemTool("bcdedit.exe", arguments, 10000, out exitCode); }

        private static List<BootSettingChange> CaptureBootSettings(List<BootTarget> targets)
        {
            var changes = new List<BootSettingChange>(); if (targets == null || targets.Count == 0) return changes;
            int exit; string config = RunBcdEdit("/enum {current}", out exit); if (exit != 0) throw new InvalidOperationException("Windows Boot Configuration could not be read. " + config.Trim());
            foreach (BootTarget target in targets)
            {
                Match match = Regex.Match(config, @"^\s*" + Regex.Escape(target.Name) + @"\s+([^\r\n]+?)\s*$", RegexOptions.Multiline | RegexOptions.IgnoreCase);
                changes.Add(new BootSettingChange { Name = target.Name, Existed = match.Success, OriginalValue = match.Success ? match.Groups[1].Value.Trim() : null, TargetValue = target.Value });
            }
            return changes;
        }

        private static void SetBootSettings(List<BootSettingChange> changes, bool restore)
        {
            if (changes == null) return;
            foreach (BootSettingChange change in changes)
            {
                string args = restore && !change.Existed ? "/deletevalue {current} " + change.Name : "/set {current} " + change.Name + " " + (restore ? change.OriginalValue : change.TargetValue);
                int exit; string output = RunBcdEdit(args, out exit); if (exit != 0) throw new InvalidOperationException("Windows could not update the boot option '" + change.Name + "'. " + output.Trim());
            }
        }

        private static bool BootSettingsMatch(List<BootSettingChange> changes)
        {
            if (changes == null || changes.Count == 0) return true;
            int exit; string config = RunBcdEdit("/enum {current}", out exit); if (exit != 0) return false;
            foreach (BootSettingChange change in changes)
            {
                Match match = Regex.Match(config, @"^\s*" + Regex.Escape(change.Name) + @"\s+([^\r\n]+?)\s*$", RegexOptions.Multiline | RegexOptions.IgnoreCase);
                if (!match.Success || !String.Equals(match.Groups[1].Value.Trim(), change.TargetValue, StringComparison.OrdinalIgnoreCase)) return false;
            }
            return true;
        }

        private static string RunNetsh(string arguments, out int exitCode)
        { return RunCapturedSystemTool("netsh.exe", arguments, 10000, out exitCode); }

        private static string QueryNetshSetting(string name)
        {
            int exit; string output;
            if (String.Equals(name, "tcp-heuristics", StringComparison.OrdinalIgnoreCase))
            {
                output = RunNetsh("interface tcp show heuristics", out exit);
                if (exit != 0) throw new InvalidOperationException("Windows could not read TCP heuristics. " + output.Trim());
                Match match = Regex.Match(output, @"(?im)^.*heuristic.*:\s*(enabled|disabled|default)\s*$");
                if (!match.Success) throw new InvalidOperationException("The TCP heuristics state could not be recognized, so no change was made.");
                return match.Groups[1].Value;
            }
            if (String.Equals(name, "teredo-type", StringComparison.OrdinalIgnoreCase))
            {
                output = RunNetsh("interface teredo show state", out exit);
                if (exit != 0) throw new InvalidOperationException("Windows could not read Teredo state. " + output.Trim());
                Match match = Regex.Match(output, @"(?im)^\s*[^:\r\n]+:\s*(default|client|enterpriseclient|disabled)\s*$");
                if (!match.Success) throw new InvalidOperationException("The Teredo configuration could not be recognized, so no change was made.");
                return match.Groups[1].Value;
            }
            throw new InvalidOperationException("The saved network setting is unsupported.");
        }

        private static List<NetshSettingChange> CaptureNetshSettings(List<NetshTarget> targets)
        {
            var changes = new List<NetshSettingChange>(); if (targets == null) return changes;
            foreach (NetshTarget target in targets) changes.Add(new NetshSettingChange { Name = target.Name, OriginalValue = QueryNetshSetting(target.Name), TargetValue = target.Target });
            return changes;
        }

        private static void SetNetshSettings(List<NetshSettingChange> changes, bool restore)
        {
            if (changes == null) return;
            foreach (NetshSettingChange change in changes)
            {
                string value = restore ? change.OriginalValue : change.TargetValue;
                string args = String.Equals(change.Name, "tcp-heuristics", StringComparison.OrdinalIgnoreCase) ? "interface tcp set heuristics " + value : "interface teredo set state " + value;
                int exit; string output = RunNetsh(args, out exit); if (exit != 0) throw new InvalidOperationException("Windows could not update network setting '" + change.Name + "'. " + output.Trim());
            }
        }

        private static bool NetshSettingsMatch(List<NetshSettingChange> changes)
        {
            if (changes == null) return true;
            foreach (NetshSettingChange change in changes) try { if (!String.Equals(QueryNetshSetting(change.Name), change.TargetValue, StringComparison.OrdinalIgnoreCase)) return false; } catch { return false; }
            return true;
        }

        private List<GameDefinition> AllGames()
        {
            var games = new List<GameDefinition>(GameProfiles);
            if (_state.CustomGames != null) games.AddRange(_state.CustomGames);
            return games;
        }

        private List<string> PathsFor(GameDefinition game)
        {
            List<string> paths;
            return _state.GamePaths != null && _state.GamePaths.TryGetValue(game.Id, out paths) && paths != null ? paths : new List<string>();
        }

        private void RenderGameList()
        {
            if (_gameList == null) return;
            _gameList.Children.Clear();
            foreach (GameDefinition game in AllGames())
            {
                List<string> paths = PathsFor(game);
                var button = new Button { Tag = game.Id, HorizontalContentAlignment = HorizontalAlignment.Stretch, Background = game.Id == _selectedGameId ? Brush(SurfaceRaised) : Brushes.Transparent,
                    BorderBrush = Brush(BorderColor), BorderThickness = new Thickness(1), Padding = new Thickness(11, 9, 11, 9), Margin = new Thickness(0, 2, 0, 3), Cursor = Cursors.Hand };
                var stack = new StackPanel(); stack.Children.Add(Text(game.Name, 12, Brushes.White, true));
                string status = paths.Count > 0 ? "Installed · " + paths.Count + " match" + (paths.Count == 1 ? "" : "es") : "Not detected";
                stack.Children.Add(Text(status, 9, paths.Count > 0 ? Brush(AccentColor) : Brush(MutedColor), false, 0, 2)); button.Content = stack;
                button.Click += delegate { _selectedGameId = game.Id; RenderGameList(); RenderGameDetail(); };
                _gameList.Children.Add(button);
            }
        }

        private void RenderGameDetail()
        {
            if (_gameDetail == null) return;
            _gameDetail.Children.Clear();
            GameDefinition game = AllGames().FirstOrDefault(x => x.Id == _selectedGameId);
            if (game == null)
            {
                _gameDetail.Children.Add(Text("Choose a game", 17, Brushes.White, true));
                _gameDetail.Children.Add(Text("Select a profile on the left to see its recommendations and in-game tips.", 11, Brush(MutedColor), false, 0, 6)); return;
            }
            var gameTitle = Text(game.Name, 20, Brushes.White, true); Localization.KeepData(gameTitle); _gameDetail.Children.Add(gameTitle);
            List<string> paths = PathsFor(game);
            _gameDetail.Children.Add(Text(paths.Count > 0 ? "INSTALLED" : "NOT DETECTED", 9, paths.Count > 0 ? Brush(Color.FromRgb(86, 220, 155)) : Brush(MutedColor), true, 0, 5));
            if (!String.IsNullOrEmpty(game.AntiCheat))
            {
                var safety = new Border { Background = Brush(Color.FromRgb(49, 39, 23)), BorderBrush = Brush(Color.FromRgb(101, 77, 37)), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Padding = new Thickness(11), Margin = new Thickness(0, 10, 0, 6) };
                safety.Child = Text("Anti-cheat: " + game.AntiCheat + ". This profile only recommends Windows settings; it does not change game files, inject into the game, or alter its process priority.", 10.5, Brush(Color.FromRgb(255, 204, 123)), false); _gameDetail.Children.Add(safety);
            }
            if (paths.Count > 0) _gameDetail.Children.Add(Text(paths[0], 9.5, Brush(MutedColor), false, 0, 4));
            _gameDetail.Children.Add(Text("Suggested Windows options", 13, Brushes.White, true, 0, 15));
            int compatible = 0;
            foreach (string id in game.RecommendedTweaks ?? new List<string>())
            {
                TweakDefinition tweak = _catalogue.FirstOrDefault(x => x.Id == id); if (tweak == null || !CanSelectTweak(id)) continue; compatible++;
                bool active = _state.Applied.Any(x => x.Id == id);
                var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(1, 3, 0, 3) };
                row.Children.Add(Text(active ? "✓" : "·", 13, active ? Brush(Color.FromRgb(86, 220, 155)) : Brush(MutedColor), true, 0, 0));
                var optionLabel = Text(tweak.Name, 10.5, active ? Brush(Color.FromRgb(86, 220, 155)) : Brush(MutedColor), false, 7, 0);
                if (!Definitions.Any(x => x.Id == tweak.Id)) Localization.KeepData(optionLabel);
                row.Children.Add(optionLabel);
                if (active) row.Children.Add(Text("Active", 10.5, Brush(Color.FromRgb(86, 220, 155)), false, 7, 0));
                _gameDetail.Children.Add(row);
            }
            if (compatible == 0) _gameDetail.Children.Add(Text("No available options match this profile.", 10, Brush(MutedColor), false, 0, 3));
            var buttons = new WrapPanel { Margin = new Thickness(-4, 11, 0, 4) };
            var select = ActionButton("Review profile options", true); select.Click += delegate { foreach (string id in game.RecommendedTweaks ?? new List<string>()) if (CanSelectTweak(id) && !_state.Applied.Any(x => x.Id == id)) _selectedTweaks.Add(id); _pages["Optimize"].Child = PageScroll(BuildOptimize()); ShowPage("Optimize"); };
            buttons.Children.Add(select);
            if (paths.Count > 0)
            {
                var launch = ActionButton("Launch game", false); launch.Click += delegate { try { Process.Start(new ProcessStartInfo(paths[0]) { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(paths[0]) }); } catch (Exception ex) { MessageBox.Show(this, "Could not launch this game: " + ex.Message, "Launch failed", MessageBoxButton.OK, MessageBoxImage.Error); } }; buttons.Children.Add(launch);
            }
            if (game.IsCustom)
            {
                var remove = ActionButton("Remove game", false); remove.Click += delegate { _state.CustomGames.RemoveAll(x => x.Id == game.Id); _state.GamePaths.Remove(game.Id); _selectedGameId = null; SaveState(); RenderGameList(); RenderGameDetail(); RefreshSessionGames(); }; buttons.Children.Add(remove);
            }
            _gameDetail.Children.Add(buttons);
            _gameDetail.Children.Add(Text("In-game tips", 13, Brushes.White, true, 0, 15));
            foreach (string tip in game.Tips ?? new List<string>())
            {
                var tipRow = new Grid { Margin = new Thickness(2, 5, 0, 0) };
                tipRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(13) }); tipRow.ColumnDefinitions.Add(new ColumnDefinition());
                tipRow.Children.Add(Text("•", 10.5, Brush(MutedColor), false));
                var tipLabel = Text(tip, 10.5, Brush(MutedColor), false);
                if (game.IsCustom && tip != "Use in-game graphics options first and compare changes in a practice session." && tip != "Keep the game files unchanged; this profile only recommends Windows settings.") Localization.KeepData(tipLabel);
                Grid.SetColumn(tipLabel, 1); tipRow.Children.Add(tipLabel); _gameDetail.Children.Add(tipRow);
            }
        }

        private async void ScanForGames() { await ScanGamesAsync(false); }

        private Dictionary<string, List<string>> FindInstalledGames()
        {
            var roots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            AddRoot(roots, Path.Combine(programFiles, "Epic Games")); AddRoot(roots, Path.Combine(programFilesX86, "Epic Games"));
            AddRoot(roots, Path.Combine(programFiles, "Riot Games")); AddRoot(roots, @"C:\Riot Games");
            AddRoot(roots, Path.Combine(local, "Roblox", "Versions")); AddRoot(roots, Path.Combine(programFiles, "Rockstar Games"));
            AddRoot(roots, Path.Combine(programFilesX86, "Rockstar Games")); AddRoot(roots, Path.Combine(programFiles, "Call of Duty"));
            string steam = null;
            try { using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam")) { if (key != null) steam = key.GetValue("SteamPath") as string; } } catch { }
            if (!String.IsNullOrEmpty(steam))
            {
                AddRoot(roots, Path.Combine(steam, "steamapps", "common"));
                string vdf = Path.Combine(steam, "steamapps", "libraryfolders.vdf");
                try { if (File.Exists(vdf)) foreach (Match match in Regex.Matches(File.ReadAllText(vdf), "\\\"path\\\"\\s+\\\"([^\\\"]+)\\\"")) AddRoot(roots, Path.Combine(match.Groups[1].Value.Replace("\\\\", "\\"), "steamapps", "common")); } catch { }
            }
            foreach (DriveInfo drive in DriveInfo.GetDrives())
            {
                if (!drive.IsReady) continue;
                AddRoot(roots, Path.Combine(drive.RootDirectory.FullName, "Games"));
                AddRoot(roots, Path.Combine(drive.RootDirectory.FullName, "Epic Games"));
                AddRoot(roots, Path.Combine(drive.RootDirectory.FullName, "SteamLibrary", "steamapps", "common"));
                AddRoot(roots, Path.Combine(drive.RootDirectory.FullName, "Riot Games"));
            }
            var result = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
            foreach (GameDefinition game in AllGames())
            {
                result[game.Id] = new List<string>();
                if (game.IsCustom) foreach (string savedPath in PathsFor(game)) if (File.Exists(savedPath)) result[game.Id].Add(savedPath);
            }
            var executableMap = new Dictionary<string, List<GameDefinition>>(StringComparer.OrdinalIgnoreCase);
            foreach (GameDefinition game in AllGames()) foreach (string exe in game.Executables ?? new List<string>())
            { List<GameDefinition> list; if (!executableMap.TryGetValue(exe, out list)) executableMap[exe] = list = new List<GameDefinition>(); list.Add(game); }
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string root in roots)
            {
                Dispatcher.BeginInvoke(new Action(delegate { if (_gameStatus != null) _gameStatus.Text = "Scanning " + root + "…"; }));
                var queue = new Queue<Tuple<string, int>>(); queue.Enqueue(Tuple.Create(root, 0));
                while (queue.Count > 0)
                {
                    Tuple<string, int> current = queue.Dequeue(); if (!seen.Add(current.Item1)) continue;
                    try
                    {
                        foreach (string file in Directory.EnumerateFiles(current.Item1, "*.exe", SearchOption.TopDirectoryOnly))
                        {
                            List<GameDefinition> matches;
                            if (executableMap.TryGetValue(Path.GetFileName(file), out matches)) foreach (GameDefinition game in matches) if (!result[game.Id].Contains(file, StringComparer.OrdinalIgnoreCase)) result[game.Id].Add(file);
                        }
                        if (current.Item2 >= 5) continue;
                        foreach (string dir in Directory.EnumerateDirectories(current.Item1, "*", SearchOption.TopDirectoryOnly))
                        {
                            try { if ((File.GetAttributes(dir) & FileAttributes.ReparsePoint) == 0) queue.Enqueue(Tuple.Create(dir, current.Item2 + 1)); } catch { }
                        }
                    }
                    catch { }
                }
            }
            return result;
        }

        private static void AddRoot(HashSet<string> roots, string path)
        { if (!String.IsNullOrEmpty(path)) try { string full = Path.GetFullPath(path); if (Directory.Exists(full)) roots.Add(full); } catch { } }

        private void AddCustomGame()
        {
            var dialog = new Microsoft.Win32.OpenFileDialog { Filter = "Game applications (*.exe)|*.exe", Title = "Choose a game executable" };
            if (LocalizedFileDialog.Show(dialog, this) != true) return;
            string name = Path.GetFileNameWithoutExtension(dialog.FileName);
            try { string product = FileVersionInfo.GetVersionInfo(dialog.FileName).ProductName; if (!String.IsNullOrWhiteSpace(product)) name = product.Trim(); } catch { }
            MessageBoxResult answer = MessageBox.Show(this, "Does " + name + " use anti-cheat software? Choose Yes if you are unsure. The profile will still recommend Windows-level settings only.", "Anti-cheat", MessageBoxButton.YesNo, MessageBoxImage.Question);
            string id = "custom-" + Regex.Replace(name.ToLowerInvariant(), "[^a-z0-9]+", "-").Trim('-');
            if (String.IsNullOrEmpty(id) || AllGames().Any(x => x.Id == id)) id = "custom-" + Guid.NewGuid().ToString("N").Substring(0, 8);
            var custom = MakeGame(id, name, answer == MessageBoxResult.Yes ? "User marked as present / unsure" : "", new string[] { Path.GetFileName(dialog.FileName) },
                new string[] { "Use in-game graphics options first and compare changes in a practice session.", "Keep the game files unchanged; this profile only recommends Windows settings." }, "game-mode", "game-capture", "gamebar-overlay");
            custom.IsCustom = true; _state.CustomGames.Add(custom); _state.GamePaths[id] = new List<string> { dialog.FileName };
            _selectedGameId = id; SaveState(); RenderGameList(); RenderGameDetail(); RefreshSessionGames();
        }

        private void RenderTweakCards()
        {
            if (_tweakList == null) return;
            _tweakList.Children.Clear(); _checks.Clear(); UpdateApplyButton();
            string query = _tweakSearch == null ? "" : _tweakSearch.Text.Trim();
            var categoryChoice = _categoryFilter == null ? null : _categoryFilter.SelectedItem as ComboBoxItem;
            string categoryFilter = categoryChoice == null ? "All categories" : Convert.ToString(categoryChoice.Tag);
            var visible = _catalogue.Where(x => (!_recommendedOnlyActive || IsRecommended(x)) && (categoryFilter == "All categories" || x.Category == categoryFilter) &&
                (String.IsNullOrEmpty(query) || x.Name.IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0 || x.Category.IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0 || x.Description.IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0 || Localization.Translate(x.Name).IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0 || Localization.Translate(x.Category).IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0 || Localization.Translate(x.Description).IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0)).ToList();
            if (visible.Count == 0) { _tweakList.Children.Add(Text("No optimizations match that search.", 12, Brush(MutedColor), false, 2, 14)); return; }
            foreach (string category in visible.Select(x => x.Category).Distinct())
            {
                _tweakList.Children.Add(Text(category, 15, Brushes.White, true, 2, 10));
                foreach (TweakDefinition tweak in visible.Where(x => x.Category == category)) _tweakList.Children.Add(TweakCard(tweak));
            }
            UpdateApplyButton();
        }

        private UIElement TweakCard(TweakDefinition tweak)
        {
            var card = Card(); card.Padding = new Thickness(15, 12, 15, 12); card.Margin = new Thickness(0, 4, 0, 4);
            var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            bool alreadyApplied = _state.Applied.Any(x => x.Id == tweak.Id);
            bool alreadyEnabled = AlreadyEnabledOutsideShark(tweak.Id);
            string requirement = TweakRequirement(tweak);
            string availability = requirement == null ? null : _requirementsReady ? requirement : "Checking hardware…";
            var check = new CheckBox { IsChecked = _selectedTweaks.Contains(tweak.Id), IsEnabled = !alreadyApplied && !alreadyEnabled && requirement == null, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(1, 0, 14, 0), ToolTip = alreadyApplied ? "Already applied. Undo it from Restore first." : alreadyEnabled ? "Already enabled outside SharkOptimizer. No original value is available for undo." : availability ?? "Select this change" };
            check.Checked += delegate { _selectedTweaks.Add(tweak.Id); card.BorderBrush = Brush(AccentColor); UpdateApplyButton(); };
            check.Unchecked += delegate { _selectedTweaks.Remove(tweak.Id); card.BorderBrush = Brush(BorderColor); UpdateApplyButton(); };
            if (check.IsChecked == true) card.BorderBrush = Brush(AccentColor);
            check.Tag = tweak; _checks.Add(check); grid.Children.Add(check);
            var details = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            var customDefinition = _state.CustomTweaks.FirstOrDefault(x => x.Id == tweak.Id);
            var nameLabel = Text(tweak.Name, 12, Brushes.White, true); var descriptionLabel = Text(tweak.Description, 10.5, Brush(MutedColor), false, 0, 3);
            if (customDefinition != null) { Localization.KeepData(nameLabel); Localization.KeepData(descriptionLabel); }
            details.Children.Add(nameLabel); details.Children.Add(descriptionLabel);
            if (availability != null && !alreadyApplied) details.Children.Add(Text(availability, 10, Brush(MutedColor), false, 0, 4));
            if (!String.IsNullOrEmpty(tweak.Warning) || TweakPolicyScope(tweak) != null) {
                var warningBody = new StackPanel();
                if (customDefinition == null) {
                    if (!String.IsNullOrEmpty(tweak.Warning)) warningBody.Children.Add(Text(tweak.Warning, 10, Brush(Color.FromRgb(255, 190, 96)), false, 0, 4));
                    if (TweakPolicyScope(tweak) != null) warningBody.Children.Add(Text(TweakPolicyScope(tweak), 10, Brush(Color.FromRgb(255, 190, 96)), false, 0, 4));
                }
                else {
                    warningBody.Children.Add(Text(CustomTweakCodec.ReviewWarning, 10, Brush(Color.FromRgb(255, 190, 96)), false, 0, 4));
                    if (!String.IsNullOrWhiteSpace(customDefinition.Warning)) { var customWarning = Text(customDefinition.Warning, 10, Brush(Color.FromRgb(255, 190, 96)), false, 0, 4); Localization.KeepData(customWarning); warningBody.Children.Add(customWarning); }
                    if (customDefinition.Reboot) warningBody.Children.Add(Text(CustomTweakCodec.RestartWarning, 10, Brush(Color.FromRgb(255, 190, 96)), false, 0, 4));
                }
                details.Children.Add(new Expander { Header = "Details & cautions", Content = warningBody, Foreground = Brush(MutedColor), FontSize = 9, Margin = new Thickness(0, 5, 12, 0) });
            }
            Grid.SetColumn(details, 1); grid.Children.Add(details);
            var risk = Text(alreadyApplied ? "APPLIED" : alreadyEnabled ? "ALREADY ENABLED" : tweak.Risk.ToUpperInvariant(), 8, Brush(alreadyApplied || alreadyEnabled ? Color.FromRgb(86, 220, 155) : tweak.Risk == "Caution" ? Color.FromRgb(255, 190, 96) : AccentColor), true);
            var badge = new Border { Background = Brush(SurfaceRaised), CornerRadius = new CornerRadius(8), Padding = new Thickness(9, 5, 9, 5), Child = risk, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(badge, 2); grid.Children.Add(badge); card.Child = grid; return card;
        }

        private UIElement BuildWindowsTools()
        {
            var panel = ScrollColumn(); var intro = Card(); var stack = new StackPanel();
            stack.Children.Add(Text("Windows tools", 20, Brushes.White, true));
            stack.Children.Add(Text("Quick access to common Windows controls and a gentle app closer. Changes happen only when you choose an action.", 11, Brush(MutedColor), false, 0, 5));
            var tools = new WrapPanel { Margin = new Thickness(-5, 10, 0, 0) };
            tools.Children.Add(UtilityButton("Startup Apps", "ms-settings:startupapps")); tools.Children.Add(UtilityButton("Storage", "ms-settings:storagesense"));
            tools.Children.Add(UtilityButton("Windows Update", "ms-settings:windowsupdate")); tools.Children.Add(UtilityButton("Installed apps", "ms-settings:appsfeatures")); tools.Children.Add(UtilityButton("Troubleshoot", "ms-settings:troubleshoot")); tools.Children.Add(UtilityButton("Task Manager", "taskmgr.exe"));
            stack.Children.Add(tools); intro.Child = stack; panel.Children.Add(intro);
            panel.Children.Add(BuildOptionalAppsCard());
            var startupCard = Card(); var startup = new StackPanel();
            var startupHeader = new Grid(); startupHeader.ColumnDefinitions.Add(new ColumnDefinition()); startupHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var startupCopy = new StackPanel(); startupCopy.Children.Add(Text("Startup apps", 15, Brushes.White, true)); startupCopy.Children.Add(Text("Toggle Run entries and files in the current-user or shared Startup folders. Scheduled tasks and Store app startup remain in Windows Settings.", 11, Brush(MutedColor), false, 0, 3)); startupHeader.Children.Add(startupCopy);
            var refreshStartup = ActionButton("Refresh", false); refreshStartup.Click += delegate { RefreshStartupApps(); }; Grid.SetColumn(refreshStartup, 1); startupHeader.Children.Add(refreshStartup); startup.Children.Add(startupHeader);
            _startupList = new StackPanel { Margin = new Thickness(0, 8, 0, 0) }; startup.Children.Add(_startupList); startupCard.Child = startup; panel.Children.Add(startupCard); RefreshStartupApps();
            var repairCard = Card(); var repair = new StackPanel(); repair.Children.Add(Text("Windows repair", 15, Brushes.White, true));
            repair.Children.Add(Text("These built-in checks open an elevated console and may take several minutes. Windows will show a UAC prompt.", 11, Brush(MutedColor), false, 0, 3));
            var repairActions = new WrapPanel { Margin = new Thickness(-5, 8, 0, 0) }; var sfc = ActionButton("Run System File Checker", false); sfc.Click += delegate { LaunchRepair("sfc.exe", "/scannow"); }; var dism = ActionButton("Repair Windows image", false); dism.Click += delegate { LaunchRepair("dism.exe", "/Online /Cleanup-Image /RestoreHealth"); }; repairActions.Children.Add(sfc); repairActions.Children.Add(dism); repair.Children.Add(repairActions); repairCard.Child = repair; panel.Children.Add(repairCard);
            var card = Card(); var body = new StackPanel();
            var header = new Grid(); header.ColumnDefinitions.Add(new ColumnDefinition()); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var copy = new StackPanel(); copy.Children.Add(Text("Close background apps", 15, Brushes.White, true)); copy.Children.Add(Text("Select app windows and ask them to close normally. Unsaved work can prompt you to save.", 11, Brush(MutedColor), false, 0, 3)); header.Children.Add(copy);
            var refresh = ActionButton("Refresh", false); refresh.Click += delegate { RefreshWindowsProcesses(); }; Grid.SetColumn(refresh, 1); header.Children.Add(refresh); body.Children.Add(header);
            _processList = new StackPanel { Margin = new Thickness(0, 8, 0, 0) }; body.Children.Add(_processList);
            var close = ActionButton("Request selected apps to close", true); close.Margin = new Thickness(0, 10, 0, 0); close.Click += delegate { RequestSelectedProcessesClose(); }; body.Children.Add(close);
            card.Child = body; panel.Children.Add(card); RefreshWindowsProcesses(); return panel;
        }

        private sealed class OptionalAppPackage
        {
            public string Name;
            public string FullName;
            public string DisplayName;
            public bool IsBundle;
        }

        private static readonly Dictionary<string, string> OptionalAppNames = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
            { "Microsoft.BingNews", "Microsoft News" }, { "Microsoft.BingWeather", "Weather" },
            { "Microsoft.GetHelp", "Get Help" }, { "Microsoft.Getstarted", "Tips" },
            { "Microsoft.MicrosoftSolitaireCollection", "Solitaire Collection" }, { "Microsoft.People", "People" },
            { "Microsoft.WindowsFeedbackHub", "Feedback Hub" }, { "Microsoft.ZuneMusic", "Media Player (Groove)" },
            { "Microsoft.ZuneVideo", "Movies and TV" }, { "Microsoft.YourPhone", "Phone Link" },
            { "Microsoft.MicrosoftOfficeHub", "Microsoft 365 Hub" }, { "Microsoft.Todos", "To Do" },
            { "Microsoft.PowerAutomateDesktop", "Power Automate" }, { "Clipchamp.Clipchamp", "Clipchamp" },
            { "Microsoft.549981C3F5F10", "Cortana" }, { "MicrosoftTeams", "Teams (personal)" },
            { "Microsoft.MixedReality.Portal", "Mixed Reality Portal" }, { "Microsoft.SkypeApp", "Skype" },
            { "Microsoft.WindowsMaps", "Maps" }, { "Microsoft.Microsoft3DViewer", "3D Viewer" }
        };

        private UIElement BuildOptionalAppsCard()
        {
            var card = Card(); var body = new StackPanel();
            body.Children.Add(Text("Optional Windows apps", 15, Brushes.White, true));
            body.Children.Add(Text("Review installed optional apps before removing them. App removal can delete local app data and cannot be undone in Restore. Apps can usually be reinstalled from Microsoft Store.", 11, Brush(MutedColor), false, 0, 4));
            _optionalAppsAllUsers = new CheckBox { Content = "Include and remove apps for all users", Foreground = Brushes.White, Margin = new Thickness(0, 10, 0, 5) };
            _optionalAppsAllUsers.Click += delegate { _optionalPackages.Clear(); _optionalAppList.Children.Clear(); _optionalAppStatus.Text = "Scope changed. Scan installed apps again."; _optionalAppRemove.IsEnabled = false; };
            body.Children.Add(_optionalAppsAllUsers);
            _optionalAppList = new StackPanel { Margin = new Thickness(0, 6, 0, 4) }; body.Children.Add(_optionalAppList);
            var actions = new WrapPanel { Margin = new Thickness(-5, 6, 0, 0) };
            _optionalAppScan = ActionButton("Scan installed apps", false); _optionalAppScan.Click += async delegate { await RefreshOptionalApps(); };
            _optionalAppRemove = ActionButton("Remove selected apps", true); _optionalAppRemove.IsEnabled = false; _optionalAppRemove.Click += async delegate { await RemoveOptionalApps(); };
            actions.Children.Add(_optionalAppScan); actions.Children.Add(_optionalAppRemove); actions.Children.Add(UtilityButton("Open Microsoft Store", "ms-windows-store://home")); body.Children.Add(actions);
            _optionalAppStatus = Text("Scan to see which of the 20 optional apps are installed. Nothing is selected automatically.", 11, Brush(MutedColor), false, 0, 8);
            body.Children.Add(_optionalAppStatus); card.Child = body; return card;
        }

        private void SetOptionalAppsBusy(bool busy)
        {
            _optionalAppsBusy = busy; _optionalAppsAllUsers.IsEnabled = !busy; _optionalAppList.IsEnabled = !busy;
            _optionalAppScan.IsEnabled = !busy; _optionalAppRemove.IsEnabled = !busy && _optionalPackages.Count > 0;
        }

        private static List<OptionalAppPackage> ScanOptionalApps(bool allUsers)
        {
            var manager = new global::Windows.Management.Deployment.PackageManager(); var packages = new List<OptionalAppPackage>();
            var installed = allUsers ? manager.FindPackages() : manager.FindPackagesForUser("");
            foreach (var package in installed)
            {
                string displayName; string name = package.Id.Name;
                if (!OptionalAppNames.TryGetValue(name, out displayName) || package.IsFramework || package.IsResourcePackage) continue;
                packages.Add(new OptionalAppPackage { Name = name, FullName = package.Id.FullName, DisplayName = displayName, IsBundle = package.IsBundle });
            }
            // Removing a bundle also removes its member packages. Avoid submitting both.
            return packages.GroupBy(x => x.Name, StringComparer.OrdinalIgnoreCase)
                .SelectMany(x => x.Any(p => p.IsBundle) ? x.Where(p => p.IsBundle) : x)
                .GroupBy(x => x.FullName, StringComparer.OrdinalIgnoreCase).Select(x => x.First()).OrderBy(x => x.DisplayName).ToList();
        }

        private async Task RefreshOptionalApps()
        {
            if (_optionalAppsBusy) return; bool allUsers = _optionalAppsAllUsers.IsChecked == true;
            SetOptionalAppsBusy(true); _optionalAppStatus.Text = "Scanning optional apps…";
            _optionalPackages.Clear(); _optionalAppList.Children.Clear();
            try
            {
                _optionalPackages = await Task.Run(delegate { return ScanOptionalApps(allUsers); });
                foreach (var group in _optionalPackages.GroupBy(x => x.Name, StringComparer.OrdinalIgnoreCase))
                    _optionalAppList.Children.Add(new CheckBox { Content = group.First().DisplayName, Tag = group.Key, Foreground = Brushes.White, Margin = new Thickness(4, 5, 4, 5), ToolTip = group.Key });
                int count = _optionalAppList.Children.Count;
                Localization.Apply(_optionalAppList);
                _optionalAppStatus.Text = count == 0 ? "None of the listed optional apps are installed in this scope." : count + " optional app(s) found. Choose only the apps you want to remove.";
            }
            catch (Exception ex) { _optionalAppStatus.Text = "Windows could not scan app packages: " + ex.Message; }
            finally { SetOptionalAppsBusy(false); }
        }

        private static async Task RemoveOptionalPackage(OptionalAppPackage package, bool allUsers)
        {
            if (!OptionalAppNames.ContainsKey(package.Name)) throw new InvalidOperationException("This package is outside the optional-app list.");
            var manager = new global::Windows.Management.Deployment.PackageManager();
            var options = allUsers ? global::Windows.Management.Deployment.RemovalOptions.RemoveForAllUsers : global::Windows.Management.Deployment.RemovalOptions.None;
            var operation = manager.RemovePackageAsync(package.FullName, options);
            try
            {
                while (operation.Status == global::Windows.Foundation.AsyncStatus.Started) await Task.Delay(150).ConfigureAwait(false);
                var result = operation.GetResults();
                if (result.ExtendedErrorCode != null) throw new InvalidOperationException(result.ErrorText, result.ExtendedErrorCode);
            }
            finally { if (operation.Status != global::Windows.Foundation.AsyncStatus.Started) operation.Close(); }
        }

        private async Task RemoveOptionalApps()
        {
            if (_optionalAppsBusy) return;
            var selectedNames = new HashSet<string>(_optionalAppList.Children.OfType<CheckBox>().Where(x => x.IsChecked == true).Select(x => Convert.ToString(x.Tag)), StringComparer.OrdinalIgnoreCase);
            var selected = _optionalPackages.Where(x => selectedNames.Contains(x.Name)).ToList();
            if (selected.Count == 0) { _optionalAppStatus.Text = "Select at least one app to remove."; return; }
            bool allUsers = _optionalAppsAllUsers.IsChecked == true;
            string names = String.Join(Environment.NewLine, selected.Select(x => "• " + x.DisplayName).Distinct().ToArray());
            if (MessageBox.Show(this, "Remove these apps " + (allUsers ? "for all users" : "for your Windows account") + "?" + Environment.NewLine + Environment.NewLine + names + Environment.NewLine + Environment.NewLine + "Local app data can be deleted. This cannot be undone through SharkOptimizer's Restore page.", "Remove optional apps", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
            SetOptionalAppsBusy(true); var failures = new List<string>(); int removed = 0;
            try
            {
                _optionalAppStatus.Text = "Requesting a Windows restore point…";
                string recovery = await CreateSystemRestorePoint();
                if (!recovery.StartsWith("Windows accepted", StringComparison.Ordinal) && MessageBox.Show(this, recovery + Environment.NewLine + Environment.NewLine + "Continue removing the selected apps?", "Restore point unavailable", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
                foreach (OptionalAppPackage package in selected)
                {
                    _optionalAppStatus.Text = "Removing " + package.DisplayName + "…";
                    try { await Task.Run(delegate { return RemoveOptionalPackage(package, allUsers); }); removed++; }
                    catch (Exception ex) { failures.Add(package.DisplayName + ": " + ex.GetBaseException().Message); }
                }
            }
            finally { SetOptionalAppsBusy(false); }
            await RefreshOptionalApps();
            _optionalAppStatus.Text = "Removed " + removed + " package(s). " + failures.Count + " could not be removed." + (failures.Count == 0 ? "" : Environment.NewLine + String.Join(Environment.NewLine, failures.ToArray()));
        }

        private Button UtilityButton(string label, string target)
        {
            var button = ActionButton(label, false); button.Margin = new Thickness(5, 3, 5, 3);
            button.Click += delegate { try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); } catch (Exception ex) { MessageBox.Show(this, "Windows could not open this tool." + Environment.NewLine + ex.Message, "Open Windows tool", MessageBoxButton.OK, MessageBoxImage.Information); } };
            return button;
        }

        private void LaunchRepair(string executable, string arguments)
        {
            string label = executable == "sfc.exe" ? "System File Checker" : "DISM image repair";
            label = Localization.Translate(label);
            if (MessageBox.Show(this, label + " will open in an administrator console. It can take several minutes. Continue?", label, MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
            try { Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, executable), arguments) { UseShellExecute = true, Verb = "runas" }); }
            catch (Exception ex) { MessageBox.Show(this, "Windows could not start the repair tool." + Environment.NewLine + ex.Message, label, MessageBoxButton.OK, MessageBoxImage.Error); }
        }

        private void RefreshStartupApps()
        {
            if (_startupList == null) return; _startupList.Children.Clear(); int count = 0;
            const string runPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
            const string approvedPath = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
            try
            {
                foreach (RegistryHive hive in new[] { RegistryHive.CurrentUser, RegistryHive.LocalMachine })
                {
                    using (RegistryKey root = RegistryKey.OpenBaseKey(hive, RegistryView.Default))
                    using (RegistryKey run = root.OpenSubKey(runPath, false))
                    {
                        if (run == null) continue;
                        foreach (string name in run.GetValueNames())
                        {
                            if (String.IsNullOrWhiteSpace(name)) continue;
                            object raw = run.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames); string command = Convert.ToString(raw);
                            bool enabled = true; try { using (RegistryKey approved = root.OpenSubKey(approvedPath, false)) { byte[] bytes = approved == null ? null : approved.GetValue(name) as byte[]; if (bytes != null && bytes.Length > 0 && bytes[0] % 2 == 1) enabled = false; } } catch { }
                            string brief = command ?? ""; if (brief.Length > 95) brief = brief.Substring(0, 92) + "…";
                            var check = new CheckBox { IsChecked = enabled, Tag = new StartupEntry(hive, name), Content = name + "  ·  " + brief + "  ·  " + (hive == RegistryHive.CurrentUser ? "Current user" : "All users"), Margin = new Thickness(4, 4, 4, 4), Foreground = Brushes.White, ToolTip = hive + " · " + command };
                            check.Click += delegate(object sender, RoutedEventArgs e) { SetStartupApp(check); };
                            _startupList.Children.Add(check); count++;
                        }
                    }
                }
            }
            catch (Exception ex) { _startupList.Children.Add(Text("Could not read startup entries: " + ex.Message, 11, Brush(MutedColor), false)); }
            string suffix = ".sharkoptimizer-disabled";
            string currentStartup = Environment.GetFolderPath(Environment.SpecialFolder.Startup);
            string sharedStartup = Environment.GetFolderPath(Environment.SpecialFolder.CommonStartup);
            foreach (string folder in new[] { currentStartup, sharedStartup }.Where(x => !String.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase))
            {
                try
                {
                    if (!Directory.Exists(folder)) continue;
                    string scope = String.Equals(folder, sharedStartup, StringComparison.OrdinalIgnoreCase) ? "All users · Startup folder" : "Current user · Startup folder";
                    string[] files = Directory.GetFiles(folder, "*", SearchOption.TopDirectoryOnly).Where(x => !String.Equals(Path.GetFileName(x), "desktop.ini", StringComparison.OrdinalIgnoreCase)).ToArray();
                    foreach (string path in files.Where(x => !x.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)).Concat(files.Where(x => x.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))))
                    {
                        bool isDisabled = path.EndsWith(suffix, StringComparison.OrdinalIgnoreCase);
                        string visiblePath = isDisabled ? path.Substring(0, path.Length - suffix.Length) : path;
                        string fileName = Path.GetFileName(visiblePath);
                        var check = new CheckBox { IsChecked = !isDisabled, Tag = new StartupFolderEntry(path, isDisabled), Content = fileName + "  ·  " + scope, Margin = new Thickness(4, 4, 4, 4), Foreground = Brushes.White, ToolTip = visiblePath + (isDisabled ? " · Disabled by SharkOptimizer" : "") };
                        check.Click += delegate(object sender, RoutedEventArgs e) { SetStartupFolderEntry(check); };
                        _startupList.Children.Add(check); count++;
                    }
                }
                catch (Exception ex) { _startupList.Children.Add(Text("Could not read " + folder + ": " + ex.Message, 10, Brush(MutedColor), false)); }
            }
            if (count == 0) _startupList.Children.Add(Text("No Run entries or Startup-folder files were found.", 11, Brush(MutedColor), false));
            Localization.Apply(_startupList);
        }

        private void SetStartupFolderEntry(CheckBox check)
        {
            try
            {
                var item = (StartupFolderEntry)check.Tag;
                const string suffix = ".sharkoptimizer-disabled";
                string destination = item.IsDisabled ? item.Path.Substring(0, item.Path.Length - suffix.Length) : item.Path + suffix;
                if (File.Exists(destination)) throw new IOException("A file already exists at the destination. Rename or move it first, then refresh the list.");
                File.Move(item.Path, destination);
                RefreshStartupApps();
            }
            catch (Exception ex) { MessageBox.Show(this, "Windows could not update this Startup-folder entry." + Environment.NewLine + ex.Message, "Startup apps", MessageBoxButton.OK, MessageBoxImage.Error); RefreshStartupApps(); }
        }

        private void SetStartupApp(CheckBox check)
        {
            const string approvedPath = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
            try
            {
                var item = (StartupEntry)check.Tag;
                using (RegistryKey root = RegistryKey.OpenBaseKey(item.Hive, RegistryView.Default))
                using (RegistryKey approved = root.CreateSubKey(approvedPath))
                {
                    byte[] bytes = approved.GetValue(item.Name) as byte[];
                    if (bytes == null || bytes.Length < 12) bytes = new byte[12]; else bytes = bytes.Take(12).ToArray();
                    bytes[0] = check.IsChecked == true ? (byte)2 : (byte)3;
                    approved.SetValue(item.Name, bytes, RegistryValueKind.Binary);
                }
            }
            catch (Exception ex) { MessageBox.Show(this, "Windows could not update this startup entry." + Environment.NewLine + ex.Message, "Startup apps", MessageBoxButton.OK, MessageBoxImage.Error); RefreshStartupApps(); }
        }

        private void RefreshWindowsProcesses()
        {
            if (_processList == null) return; _processList.Children.Clear();
            var processes = new List<Process>();
            int ownProcessId = Process.GetCurrentProcess().Id;
            try { processes = Process.GetProcesses().Where(p => p.Id != ownProcessId && p.MainWindowHandle != IntPtr.Zero).OrderByDescending(p => { try { return p.WorkingSet64; } catch { return 0L; } }).Take(30).ToList(); } catch { }
            foreach (Process process in processes)
            {
                string name; long memory; int id; try { name = process.ProcessName; memory = process.WorkingSet64; id = process.Id; } catch { continue; }
                if (new[] { "explorer", "dwm", "sihost", "winlogon", "csrss", "services", "lsass", "wininit", "System", "ShellExperienceHost", "SearchHost", "StartMenuExperienceHost", "TextInputHost", "SystemSettings", "ApplicationFrameHost", "powershell", "pwsh", "WindowsTerminal", "taskmgr", "LockApp" }.Contains(name, StringComparer.OrdinalIgnoreCase)) continue;
                _processList.Children.Add(new CheckBox { Content = name + "  ·  " + (memory / 1024 / 1024).ToString("N0") + " MB", Tag = id, Margin = new Thickness(4), Foreground = Brushes.White });
            }
            if (_processList.Children.Count == 0) _processList.Children.Add(Text("No closable app windows were found.", 11, Brush(MutedColor), false));
            Localization.Apply(_processList);
        }

        private void RequestSelectedProcessesClose()
        {
            var selected = _processList == null ? new List<CheckBox>() : _processList.Children.OfType<CheckBox>().Where(x => x.IsChecked == true).ToList();
            if (selected.Count == 0) { MessageBox.Show(this, "Select one or more apps first.", "Close background apps", MessageBoxButton.OK, MessageBoxImage.Information); return; }
            if (MessageBox.Show(this, "Ask " + selected.Count + " selected app window(s) to close? Apps may ask you to save work.", "Close background apps", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
            foreach (CheckBox check in selected) try { using (Process process = Process.GetProcessById((int)check.Tag)) process.CloseMainWindow(); } catch { }
            DispatcherTimer timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) }; timer.Tick += delegate { timer.Stop(); RefreshWindowsProcesses(); }; timer.Start();
        }

        private UIElement BuildBoostUp()
        {
            var panel = ScrollColumn(); var intro = Card(); var stack = new StackPanel();
            stack.Children.Add(Text("Choose the caches and history you want to clear. Browser passwords, cookies, bookmarks, and documents are not included.", 11, Brush(MutedColor), false));
            var cleanupDetails = new Expander { Header = "Cleanup details", Margin = new Thickness(0, 8, 0, 0), Foreground = Brush(MutedColor) };
            cleanupDetails.Content = Text("Temporary files and caches include items older than 7 days. Recent-file history can be cleared in full. Locked files and linked folders are skipped.", 10, Brush(MutedColor), false, 0, 8); stack.Children.Add(cleanupDetails);
            var scanRow = new Grid { Margin = new Thickness(0, 12, 0, 0) }; scanRow.ColumnDefinitions.Add(new ColumnDefinition()); scanRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _cleanupStatus = Text("Scan these folders to see what can be cleaned.", 11, Brush(MutedColor), false); _cleanupStatus.Margin = new Thickness(0, 0, 16, 0); scanRow.Children.Add(_cleanupStatus);
            var actions = new StackPanel { Orientation = Orientation.Horizontal };
            var scan = ActionButton("Scan cleanup folders", false); scan.Click += async delegate { await ScanCleanupAsync(); };
            var clean = ActionButton("Run selected", true); clean.Click += async delegate { await CleanSelectedFolders(); }; actions.Children.Add(scan); actions.Children.Add(clean); Grid.SetColumn(actions, 1); scanRow.Children.Add(actions); stack.Children.Add(scanRow);
            intro.Child = stack; panel.Children.Add(intro);
            var recycle = Card(); recycle.Padding = new Thickness(15, 12, 15, 12); var recycleRow = new Grid(); recycleRow.ColumnDefinitions.Add(new ColumnDefinition()); recycleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var recycleCopy = new StackPanel(); recycleCopy.Children.Add(Text("Recycle Bin", 13, Brushes.White, true)); recycleCopy.Children.Add(Text("Review its contents in Windows before emptying; this action cannot be undone.", 10, Brush(MutedColor), false, 0, 3)); recycleRow.Children.Add(recycleCopy);
            var empty = ActionButton("Empty Recycle Bin", false); empty.Click += delegate { EmptyRecycleBin(); }; Grid.SetColumn(empty, 1); recycleRow.Children.Add(empty); recycle.Child = recycleRow; panel.Children.Add(recycle);
            _cleanupList = new StackPanel();
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            AddCleanupTarget("User temporary files", Path.GetTempPath());
            AddCleanupTarget("Windows temporary files", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Temp"));
            AddCleanupTarget("Crash dumps", Path.Combine(local, "CrashDumps"));
            AddCleanupTarget("Windows error reports", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Microsoft", "Windows", "WER", "ReportArchive"));
            AddCleanupTarget("Queued Windows error reports", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Microsoft", "Windows", "WER", "ReportQueue"));
            AddCleanupTarget("DirectX shader cache", Path.Combine(local, "D3DSCache"));
            AddCleanupTarget("NVIDIA DirectX shader cache", Path.Combine(local, "NVIDIA", "DXCache"));
            AddCleanupTarget("NVIDIA OpenGL shader cache", Path.Combine(local, "NVIDIA", "GLCache"));
            AddCleanupTarget("AMD shader cache", Path.Combine(local, "AMD", "DxCache"));
            AddCleanupTarget("Explorer recent-file history", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Microsoft", "Windows", "Recent"), 0);
            AddBrowserCleanupTargets(local);
            panel.Children.Add(BuildCleanupFilters()); panel.Children.Add(_cleanupList); panel.Children.Add(BuildMaintenanceTools()); panel.Children.Add(BuildCleanupHistory()); ApplyCleanupFilter(); return panel;
        }

        private void AddBrowserCleanupTargets(string local)
        {
            _cleanupList.Children.Add(Text("Browser caches", 14, Brushes.White, true, 3, 15));
            _cleanupList.Children.Add(Text("Only cache folders are scanned. Close browsers first for the most complete cleanup.", 10, Brush(MutedColor), false, 3, 3));
            string[] browsers = { "Google\\Chrome", "Microsoft\\Edge", "BraveSoftware\\Brave-Browser" };
            foreach (string browserPath in browsers)
            {
                string userData = Path.Combine(local, browserPath, "User Data");
                var profiles = new List<string>(); if (Directory.Exists(userData)) try { profiles.AddRange(Directory.GetDirectories(userData, "*", SearchOption.TopDirectoryOnly).Where(x => Path.GetFileName(x) == "Default" || Path.GetFileName(x).StartsWith("Profile ", StringComparison.OrdinalIgnoreCase))); } catch { }
                foreach (string profile in profiles) { AddCleanupTarget(Path.GetFileName(browserPath) + " · " + Path.GetFileName(profile) + " cache", Path.Combine(profile, "Cache")); AddCleanupTarget(Path.GetFileName(browserPath) + " · " + Path.GetFileName(profile) + " code cache", Path.Combine(profile, "Code Cache")); }
            }
            string firefoxRoot = Path.Combine(local, "Mozilla", "Firefox", "Profiles"); if (Directory.Exists(firefoxRoot)) try { foreach (string profile in Directory.GetDirectories(firefoxRoot)) AddCleanupTarget("Firefox · " + Path.GetFileName(profile) + " cache", Path.Combine(profile, "cache2")); } catch { }
        }

        private void AddCleanupTarget(string label, string path, int minimumAgeDays = 7)
        {
            var target = new CleanupTarget(label, path, minimumAgeDays);
            var card = Card(); card.Padding = new Thickness(15, 11, 15, 11); card.Margin = new Thickness(0, 0, 0, 8);
            var row = new Grid(); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition());
            var check = new CheckBox { IsChecked = true, Tag = target, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(2, 0, 14, 0) }; row.Children.Add(check);
            var details = new StackPanel(); details.Children.Add(Text(label, 12, Brushes.White, true)); details.Children.Add(Text(path, 10, Brush(MutedColor), false, 0, 3)); details.Children.Add(Text("Not scanned · older than " + minimumAgeDays + " days", 10, Brush(MutedColor), false, 0, 3));
            card.Tag = check; card.Child = row; Grid.SetColumn(details, 1); row.Children.Add(details); _cleanupList.Children.Add(card);
        }

        private async Task ScanCleanupAsync()
        {
            if (_cleanupStatus == null) return; _cleanupStatus.Text = "Scanning selected cleanup folders…";
            var paths = _cleanupList.Children.OfType<Border>().Select(x => (CheckBox)x.Tag).Select(x => { var target = (CleanupTarget)x.Tag; return Tuple.Create(target.Path, target.MinimumAgeDays, x.IsChecked == true); }).ToList();
            var sizes = await Task.Run<Dictionary<string, Tuple<long, int>>>(delegate {
                var found = new Dictionary<string, Tuple<long, int>>(StringComparer.OrdinalIgnoreCase);
                foreach (var item in paths) { long bytes = 0; int count = 0; string root = item.Item1;
                    if (item.Item3 && Directory.Exists(root)) WalkFilesSafe(root, delegate(string file) { try { var info = new FileInfo(file); if (item.Item2 == 0 || info.LastWriteTimeUtc < DateTime.UtcNow.AddDays(-item.Item2)) { bytes += info.Length; count++; } } catch { } });
                    found[root] = Tuple.Create(bytes, count); }
                return found;
            });
            long total = 0; int files = 0;
            foreach (Border card in _cleanupList.Children.OfType<Border>()) { var check = (CheckBox)card.Tag; var target = (CleanupTarget)check.Tag; var result = sizes[target.Path]; total += result.Item1; files += result.Item2; var row = (Grid)card.Child; var details = row.Children.OfType<StackPanel>().First(); ((TextBlock)details.Children[2]).Text = result.Item2 + " files · " + FormatBytes(result.Item1) + " available"; }
            _cleanupStatus.Text = "Found " + files + " older files · " + FormatBytes(total) + " available to clean.";
        }

        private async Task CleanSelectedFolders()
        {
            if (_tweakOperationBusy) return;
            var paths = _cleanupList.Children.OfType<Border>().Select(x => (CheckBox)x.Tag).Where(x => x.IsChecked == true).Select(x => (CleanupTarget)x.Tag).Where(x => Directory.Exists(x.Path)).ToList();
            var jobs = _maintenanceJobs.Where(x => x.Check.IsChecked == true).ToList();
            if (paths.Count == 0 && jobs.Count == 0) { MessageBox.Show(this, "Select at least one available action.", "Boost-Up", MessageBoxButton.OK, MessageBoxImage.Information); return; }
            string review = paths.Count == 0 ? "" : Localization.Translate("Remove eligible files from " + paths.Count + " selected folder(s)? Recent-file history is cleared in full. Browser cache files may need to be downloaded again. Locked files and linked folders are skipped.");
            foreach (MaintenanceJob job in jobs) review += Environment.NewLine + Environment.NewLine + Localization.Translate(job.Title) + ": " + Localization.Translate(job.Note);
            if (System.Windows.MessageBox.Show(this, review.Trim() + Environment.NewLine + Environment.NewLine + Localization.Translate("Continue?"), Localization.Translate("Review changes"), MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
            if (!BeginTweakOperation("Maintenance is running…")) return;
            DateTime started = DateTime.UtcNow;
            _cleanupStatus.Text = "Cleaning selected folders…";
            try {
                if (paths.Count > 0) {
                var result = await Task.Run(delegate { int removed = 0; long freed = 0; foreach (CleanupTarget target in paths) WalkFilesSafe(target.Path, delegate(string file) { try { var info = new FileInfo(file); if (target.MinimumAgeDays == 0 || info.LastWriteTimeUtc < DateTime.UtcNow.AddDays(-target.MinimumAgeDays)) { long bytes = info.Length; File.Delete(file); removed++; freed += bytes; } } catch { } }); return Tuple.Create(removed, freed); });
                await ScanCleanupAsync();
                string message = "Removed " + result.Item1 + " files · " + FormatBytes(result.Item2) + " freed. Some files may have been in use.";
                _cleanupStatus.Text = message; LogActivity(message); RecordCleanupRun("Clean selected", message, true, started);
                }
                await RunSelectedMaintenanceJobs(jobs);
            } catch (Exception ex) { RecordCleanupRun("Clean selected", ex.Message, false, started); MessageBox.Show(this, "Maintenance failed: " + ex.Message, "Boost-Up", MessageBoxButton.OK, MessageBoxImage.Warning); }
            finally { EndTweakOperation(); }
        }

        private static void WalkFilesSafe(string root, Action<string> visit)
        {
            try
            {
                string canonicalRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                var pending = new Queue<string>(); pending.Enqueue(canonicalRoot.TrimEnd(Path.DirectorySeparatorChar));
                while (pending.Count > 0)
                {
                    string current = pending.Dequeue(); string[] files = new string[0], directories = new string[0];
                    try { files = Directory.GetFiles(current); } catch { }
                    foreach (string file in files) try { string full = Path.GetFullPath(file); if (!full.StartsWith(canonicalRoot, StringComparison.OrdinalIgnoreCase)) continue; if ((File.GetAttributes(full) & FileAttributes.ReparsePoint) == 0) visit(full); } catch { }
                    try { directories = Directory.GetDirectories(current); } catch { }
                    foreach (string directory in directories) try { string full = Path.GetFullPath(directory); if (!full.StartsWith(canonicalRoot, StringComparison.OrdinalIgnoreCase)) continue; FileAttributes attrs = File.GetAttributes(full); if ((attrs & FileAttributes.ReparsePoint) == 0) pending.Enqueue(full); } catch { }
                }
            }
            catch { }
        }

        private void EmptyRecycleBin()
        {
            if (MessageBox.Show(this, "Empty the Recycle Bin for this Windows account? This permanently deletes its contents.", "Empty Recycle Bin", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
            uint result = SHEmptyRecycleBin(new IntPtr(0), null, 1 | 2 | 4);
            if (result == 0) MessageBox.Show(this, "Recycle Bin emptied.", "Boost-Up", MessageBoxButton.OK, MessageBoxImage.Information);
            else MessageBox.Show(this, "Windows could not empty the Recycle Bin. It may already be empty or blocked by another process.", "Boost-Up", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        private static extern uint SHEmptyRecycleBin(IntPtr hwnd, string rootPath, uint flags);

        private static string FormatBytes(long bytes)
        { if (bytes < 1024) return bytes + " B"; if (bytes < 1024 * 1024) return (bytes / 1024.0).ToString("N1") + " KB"; return (bytes / 1024.0 / 1024.0).ToString("N1") + " MB"; }

        private UIElement BuildNetwork()
        {
            var panel = ScrollColumn(); var card = Card(); var stack = new StackPanel(); stack.Children.Add(Text("Network diagnostics", 20, Brushes.White, true));
            stack.Children.Add(Text("Check latency, resolve a host, and inspect the route from your PC. Results depend on your network and destination.", 11, Brush(MutedColor), false, 0, 5));
            var row = new Grid { Margin = new Thickness(0, 12, 0, 0) }; row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _networkHost = new TextBox { Text = "1.1.1.1", Height = 38, Padding = new Thickness(10, 8, 10, 8), Background = Brush(SurfaceRaised), Foreground = Brushes.White, BorderBrush = Brush(BorderColor), BorderThickness = new Thickness(1), VerticalContentAlignment = VerticalAlignment.Center };
            Localization.KeepData(_networkHost);
            row.Children.Add(_networkHost); var buttons = new StackPanel { Orientation = Orientation.Horizontal };
            var ping = ActionButton("Ping", true); ping.Click += async delegate { await RunNetworkCheck("ping"); }; var dns = ActionButton("DNS lookup", false); dns.Click += async delegate { await RunNetworkCheck("dns"); }; var trace = ActionButton("Trace route", false); trace.Click += async delegate { await RunNetworkCheck("trace"); };
            buttons.Children.Add(ping); buttons.Children.Add(dns); buttons.Children.Add(trace); Grid.SetColumn(buttons, 1); row.Children.Add(buttons); stack.Children.Add(row);
            var dnsBench = ActionButton("Benchmark DNS providers", false); dnsBench.Margin = new Thickness(-5, 8, 0, 0); dnsBench.Click += async delegate { await RunNetworkCheck("dnsbench"); }; stack.Children.Add(dnsBench);
            var regionBench = ActionButton("Test game regions", false); regionBench.Margin = new Thickness(-5, 8, 0, 0); regionBench.Click += async delegate { await RunNetworkCheck("regions"); }; stack.Children.Add(regionBench);
            var utility = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(-5, 8, 0, 0) }; var flush = ActionButton("Flush DNS cache", false); flush.Click += async delegate { await RunNetworkCheck("flush"); }; utility.Children.Add(flush); utility.Children.Add(UtilityButton("Network settings", "ms-settings:network-status")); stack.Children.Add(utility);
            var wifi = ActionButton("Scan nearby Wi-Fi", false); wifi.Margin = new Thickness(-5, 8, 0, 0); wifi.Click += async delegate { await RunNetworkCheck("wifi"); }; stack.Children.Add(wifi);
            _networkButtons.Clear(); _networkButtons.AddRange(new[] { ping, dns, trace, dnsBench, regionBench, flush, wifi });
            _networkOutput = new TextBox { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Height = 250, Margin = new Thickness(0, 12, 0, 0), Padding = new Thickness(12), Background = Brush(Color.FromRgb(9, 16, 28)), Foreground = Brush(Color.FromRgb(200, 215, 234)), BorderBrush = Brush(BorderColor), BorderThickness = new Thickness(1), FontFamily = new FontFamily("Consolas") };
            stack.Children.Add(_networkOutput); card.Child = stack; panel.Children.Add(BuildLivePingCard()); panel.Children.Add(card); return panel;
        }

        private async Task RunNetworkCheck(string mode)
        {
            if (_networkCheckBusy) return;
            string host = _networkHost.Text.Trim(); if (String.IsNullOrWhiteSpace(host)) host = "1.1.1.1"; _networkOutput.Text = "Working…";
            if (mode == "ping" || mode == "dns" || mode == "trace") try { host = LivePingHistory.NormalizeHost(host); } catch (Exception ex) { _networkOutput.Text = ex.Message; return; }
            _networkCheckBusy = true; foreach (Button button in _networkButtons) button.IsEnabled = false; _networkHost.IsReadOnly = true;
            try { string output = await Task.Run<string>(delegate {
                try {
                    if (mode == "ping") { using (var ping = new Ping()) { var lines = new List<string>(); for (int i = 0; i < 4; i++) try { PingReply reply = ping.Send(host, 1800); lines.Add(reply.Status == IPStatus.Success ? "Reply from " + reply.Address + ": time=" + reply.RoundtripTime + "ms" : "Ping " + reply.Status); } catch (Exception ex) { lines.Add(ex.Message); } return String.Join(Environment.NewLine, lines.ToArray()); } }
                    if (mode == "dns") { var watch = Stopwatch.StartNew(); Task<IPAddress[]> lookup = Dns.GetHostAddressesAsync(host); ObserveLookupFailure(lookup); if (!lookup.Wait(4000)) return "Hostname lookup exceeded four seconds."; IPAddress[] addresses = lookup.Result; watch.Stop(); return "Resolved " + host + " in " + watch.ElapsedMilliseconds + " ms" + Environment.NewLine + String.Join(Environment.NewLine, addresses.Select(x => "  " + x.ToString()).ToArray()); }
                    if (mode == "dnsbench") return BenchmarkDnsResolvers();
                    if (mode == "regions") return BenchmarkRegions();
                    if (mode == "flush") return RunNetworkCommand("ipconfig.exe", "/flushdns", 5000);
                    if (mode == "wifi") return RunNetworkCommand("netsh.exe", "wlan show networks mode=bssid", 8000);
                    return RunNetworkCommand("tracert.exe", "-d -h 12 -w 700 " + host, 16000);
                } catch (Exception ex) { return "Could not complete the network check: " + ex.Message; }
            });
            if (_networkOutput != null) _networkOutput.Text = output;
            } finally { _networkCheckBusy = false; foreach (Button button in _networkButtons) button.IsEnabled = true; _networkHost.IsReadOnly = false; }
        }

        private static string BenchmarkDnsResolvers()
        {
            var servers = new[] { Tuple.Create("Cloudflare", "1.1.1.1"), Tuple.Create("Google", "8.8.8.8"), Tuple.Create("Quad9", "9.9.9.9"), Tuple.Create("OpenDNS", "208.67.222.222") };
            var domains = new[] { "example.com", "microsoft.com", "steampowered.com" }; var results = new List<Tuple<string, string, double>>();
            foreach (var server in servers)
            {
                var times = new List<double>(); foreach (string domain in domains) try { times.Add(QueryDns(server.Item2, domain)); } catch { }
                results.Add(Tuple.Create(server.Item1, server.Item2, times.Count == 0 ? -1.0 : times.Average()));
            }
            var lines = new List<string> { "Public DNS response-time sample (three uncached A-record queries per provider):", "" };
            foreach (var result in results.OrderBy(x => x.Item3 < 0 ? Double.MaxValue : x.Item3)) lines.Add(result.Item1 + " · " + result.Item2 + " · " + (result.Item3 < 0 ? "unreachable" : result.Item3.ToString("N1") + " ms average"));
            lines.Add(""); lines.Add("This measures DNS response time from this PC; it does not change your network settings.");
            return String.Join(Environment.NewLine, lines.ToArray());
        }

        private static double QueryDns(string server, string domain)
        {
            var packet = new List<byte>(); int id = Environment.TickCount & 0xffff;
            packet.Add((byte)(id >> 8)); packet.Add((byte)id); packet.Add(1); packet.Add(0); packet.Add(0); packet.Add(1);
            packet.AddRange(new byte[] { 0, 0, 0, 0, 0, 0 });
            foreach (string label in domain.Split('.')) { byte[] bytes = Encoding.ASCII.GetBytes(label); packet.Add((byte)bytes.Length); packet.AddRange(bytes); }
            packet.Add(0); packet.Add(0); packet.Add(1); packet.Add(0); packet.Add(1);
            using (var client = new UdpClient())
            {
                client.Client.ReceiveTimeout = 1400; client.Connect(IPAddress.Parse(server), 53); byte[] query = packet.ToArray();
                var watch = Stopwatch.StartNew(); client.Send(query, query.Length); IPEndPoint remote = new IPEndPoint(IPAddress.Any, 0); byte[] reply = client.Receive(ref remote); watch.Stop();
                if (reply.Length < 12 || reply[0] != query[0] || reply[1] != query[1]) throw new InvalidDataException("Invalid DNS response.");
                return watch.Elapsed.TotalMilliseconds;
            }
        }

        private static string BenchmarkRegions()
        {
            var regions = new[] { Tuple.Create("Cloudflare DNS", "1.1.1.1"), Tuple.Create("Google DNS", "8.8.8.8"), Tuple.Create("EU Frankfurt", "ec2.eu-central-1.amazonaws.com"), Tuple.Create("EU Ireland", "ec2.eu-west-1.amazonaws.com"), Tuple.Create("EU London", "ec2.eu-west-2.amazonaws.com"), Tuple.Create("EU Stockholm", "ec2.eu-north-1.amazonaws.com"), Tuple.Create("US East", "ec2.us-east-1.amazonaws.com"), Tuple.Create("US West", "ec2.us-west-2.amazonaws.com"), Tuple.Create("South America", "ec2.sa-east-1.amazonaws.com"), Tuple.Create("Asia Tokyo", "ec2.ap-northeast-1.amazonaws.com"), Tuple.Create("Asia Singapore", "ec2.ap-southeast-1.amazonaws.com"), Tuple.Create("Oceania Sydney", "ec2.ap-southeast-2.amazonaws.com") };
            var lines = new List<string> { "REGION LATENCY · TCP PORT 443 · 4 SAMPLES", "" };
            foreach (var region in regions)
            {
                var samples = new List<double>(); int lost = 0;
                for (int i = 0; i < 4; i++)
                {
                    var watch = Stopwatch.StartNew();
                    try { using (var client = new TcpClient()) { IAsyncResult connection = client.BeginConnect(region.Item2, 443, null, null); try { if (!connection.AsyncWaitHandle.WaitOne(1100) || !client.Connected) lost++; else { client.EndConnect(connection); watch.Stop(); samples.Add(watch.Elapsed.TotalMilliseconds); } } finally { try { connection.AsyncWaitHandle.Close(); } catch { } } } }
                    catch { lost++; }
                }
                if (samples.Count == 0) lines.Add(region.Item1 + " · timeout · 100% loss");
                else { double avg = samples.Average(), jitter = 0; for (int i = 1; i < samples.Count; i++) jitter += Math.Abs(samples[i] - samples[i - 1]); if (samples.Count > 1) jitter /= samples.Count - 1; lines.Add(region.Item1 + " · " + avg.ToString("N1") + " ms · jitter " + jitter.ToString("N1") + " · loss " + (lost * 25) + "%"); }
            }
            lines.Add(""); lines.Add("These are TCP connection times to sample endpoints, not a promise of latency to a particular game server. Test the actual game region too.");
            return String.Join(Environment.NewLine, lines.ToArray());
        }

        private UIElement BuildLab()
        {
            var panel = ScrollColumn(); var card = Card(); var stack = new StackPanel(); stack.Children.Add(Text("SharkOptimizer Lab", 20, Brushes.White, true));
            stack.Children.Add(Text("Check applied settings, review your system summary, and export a setup profile for another PC.", 11, Brush(MutedColor), false, 0, 5));
            _labStatus = Text("", 11, Brush(MutedColor), false, 0, 9); stack.Children.Add(_labStatus);
            var actions = new WrapPanel { Margin = new Thickness(-5, 8, 0, 0) };
            var verify = ActionButton("Verify applied tweaks", true); verify.Click += delegate { VerifyTweaks(); }; actions.Children.Add(verify);
            var report = ActionButton("Export system report", false); report.Click += delegate { ExportSystemReport(); }; actions.Children.Add(report);
            var export = ActionButton("Export selected profile", false); export.Click += delegate { ExportProfile(); }; actions.Children.Add(export);
            var import = ActionButton("Import profile", false); import.Click += delegate { ImportProfile(); }; actions.Children.Add(import);
            var sys = ActionButton("System information", false); sys.Click += delegate { _labStatus.Text = BuildSystemSummary(); }; actions.Children.Add(sys); stack.Children.Add(actions);
            var hw = ActionButton("Run hardware check", false); hw.Click += async delegate { _labStatus.Text = "Checking hardware and Windows security status…"; _labStatus.Text = await Task.Run<string>(delegate { return BuildHardwareReport(); }); }; actions.Children.Add(hw);
            var bench = new Border { Background = Brush(SurfaceRaised), CornerRadius = new CornerRadius(12), Padding = new Thickness(14), Margin = new Thickness(0, 14, 0, 0) }; var benchStack = new StackPanel();
            benchStack.Children.Add(Text("Before and after snapshot", 14, Brushes.White, true));
            benchStack.Children.Add(Text("Samples ping, jitter, DNS, idle CPU, RAM, processes, services, and the last recorded Windows boot time. Repeat both runs under similar conditions.", 11, Brush(MutedColor), false, 0, 4));
            var benchActions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(-5, 8, 0, 0) };
            _benchBeforeButton = ActionButton("Capture BEFORE", false); _benchBeforeButton.Click += async delegate { await CaptureBenchmark(true); };
            _benchAfterButton = ActionButton("Capture AFTER", true); _benchAfterButton.Click += async delegate { await CaptureBenchmark(false); };
            var compare = ActionButton("Compare", false); compare.Click += delegate { ShowBenchmarkComparison(); };
            benchActions.Children.Add(_benchBeforeButton); benchActions.Children.Add(_benchAfterButton); benchActions.Children.Add(compare); benchStack.Children.Add(benchActions); bench.Child = benchStack; stack.Children.Add(bench);
            card.Child = stack; panel.Children.Add(card);
            panel.Children.Add(BuildBenchmarkHistoryCard());
            var guide = Card(); var guideStack = new StackPanel(); guideStack.Children.Add(Text("Compare changes with care", 15, Brushes.White, true)); guideStack.Children.Add(Text("Restart after system changes, compare the same game or workload, and undo changes that cause problems. Windows updates or driver installers can reset some settings.", 11, Brush(MutedColor), false, 0, 5)); guide.Child = guideStack; panel.Children.Add(guide); return panel;
        }

        private async Task CaptureBenchmark(bool before)
        {
            if (_benchmarkBusy) return;
            _benchmarkBusy = true; _benchBeforeButton.IsEnabled = _benchAfterButton.IsEnabled = false;
            try {
            _labStatus.Text = "Sampling ping, DNS, CPU, memory, services, and boot data… pause other workloads for a cleaner comparison.";
            var snapshot = await Task.Run<BenchSnapshot>(delegate {
                var result = new BenchSnapshot { CapturedAt = DateTime.Now, PingMs = -1, JitterMs = -1, DnsMs = -1, CpuUse = -1, FreeMemoryMb = -1, RamUsedPercent = -1, ProcessCount = -1, ServicesRunning = -1, BootSeconds = -1 };
                try
                {
                    var averages = new List<double>(); var jitters = new List<double>();
                    foreach (string host in new[] { "1.1.1.1", "8.8.8.8" }) { var samples = new List<double>(); using (var pinger = new Ping()) for (int i = 0; i < 5; i++) try { PingReply reply = pinger.Send(host, 1300); if (reply.Status == IPStatus.Success) samples.Add(reply.RoundtripTime); } catch { } if (samples.Count > 0) { averages.Add(samples.Average()); double jitter = 0; for (int i = 1; i < samples.Count; i++) jitter += Math.Abs(samples[i] - samples[i - 1]); jitters.Add(samples.Count > 1 ? jitter / (samples.Count - 1) : 0); } }
                    if (averages.Count > 0) result.PingMs = averages.Average(); if (jitters.Count > 0) result.JitterMs = jitters.Average();
                } catch { }
                var dnsTimes = new List<double>(); foreach (string domain in new[] { "google.com", "cloudflare.com", "wikipedia.org", "steampowered.com", "epicgames.com" }) try { var watch = Stopwatch.StartNew(); var lookup = Dns.GetHostAddressesAsync(domain); ObserveLookupFailure(lookup); if (!lookup.Wait(4000)) continue; lookup.GetAwaiter().GetResult(); watch.Stop(); dnsTimes.Add(watch.Elapsed.TotalMilliseconds); } catch { }
                if (dnsTimes.Count > 0) result.DnsMs = dnsTimes.Average();
                try { using (var cpu = new PerformanceCounter("Processor", "% Processor Time", "_Total")) { cpu.NextValue(); var samples = new List<float>(); for (int i = 0; i < 4; i++) { System.Threading.Thread.Sleep(800); samples.Add(cpu.NextValue()); } result.CpuUse = samples.Average(); } } catch { }
                try { using (var memory = new PerformanceCounter("Memory", "Available MBytes")) result.FreeMemoryMb = memory.NextValue(); } catch { }
                try { using (var search = new ManagementObjectSearcher("SELECT TotalPhysicalMemory FROM Win32_ComputerSystem")) using (ManagementObjectCollection rows = search.Get()) { ManagementObject system = rows.Cast<ManagementObject>().FirstOrDefault(); if (system != null) using (system) { double totalMb = Convert.ToDouble(system["TotalPhysicalMemory"]) / 1024.0 / 1024.0; if (totalMb > 0 && result.FreeMemoryMb >= 0) result.RamUsedPercent = 100.0 * (1.0 - result.FreeMemoryMb / totalMb); } } } catch { }
                try { Process[] processes = Process.GetProcesses(); result.ProcessCount = processes.Length; foreach (Process process in processes) process.Dispose(); } catch { }
                try { ServiceController[] services = ServiceController.GetServices(); result.ServicesRunning = services.Count(x => { try { return x.Status == ServiceControllerStatus.Running; } catch { return false; } }); foreach (ServiceController service in services) service.Dispose(); } catch { }
                try { result.BootSeconds = ReadLastRecordedBootSeconds(); } catch { }
                return result;
            });
            var previousRuns = _state.BenchmarkRuns; BenchSnapshot previousBefore = _state.BenchBefore, previousAfter = _state.BenchAfter;
            var run = new BenchmarkRun { Id = Guid.NewGuid().ToString("N"), Slot = before ? "Before" : "After", Data = snapshot };
            _state.BenchmarkRuns = new[] { run }.Concat(previousRuns).Take(60).ToList();
            if (before) _state.BenchBefore = snapshot; else _state.BenchAfter = snapshot;
            try { SaveState(); } catch { _state.BenchmarkRuns = previousRuns; _state.BenchBefore = previousBefore; _state.BenchAfter = previousAfter; throw; }
            RenderBenchmarkHistory();
            _labStatus.Text = run.Slot.ToUpperInvariant() + " captured at " + snapshot.CapturedAt.ToString("t") + ". Repeat up to three samples under similar conditions, then Compare.";
            } catch (Exception ex) { _labStatus.Text = "Benchmark could not be saved: " + ex.Message; }
            finally { _benchmarkBusy = false; _benchBeforeButton.IsEnabled = _benchAfterButton.IsEnabled = true; }
        }

        private void ShowBenchmarkComparison()
        {
            BenchSnapshot before = BenchmarkHistory.Summarize(_state.BenchmarkRuns, "Before"), after = BenchmarkHistory.Summarize(_state.BenchmarkRuns, "After");
            if (before == null || after == null) { _labStatus.Text = "Capture both BEFORE and AFTER snapshots before comparing."; return; }
            string compare = "Medians of up to three latest samples per group. BEFORE: " + Math.Min(3, _state.BenchmarkRuns.Count(x => x.Slot == "Before")) + " · AFTER: " + Math.Min(3, _state.BenchmarkRuns.Count(x => x.Slot == "After")) + Environment.NewLine + "Metric · BEFORE → AFTER" + Environment.NewLine +
                "Ping average: " + Metric(before.PingMs, " ms") + " → " + Metric(after.PingMs, " ms") + Environment.NewLine +
                "Jitter average: " + Metric(before.JitterMs, " ms") + " → " + Metric(after.JitterMs, " ms") + Environment.NewLine +
                "DNS lookup: " + Metric(before.DnsMs, " ms") + " → " + Metric(after.DnsMs, " ms") + Environment.NewLine +
                "CPU usage: " + Metric(before.CpuUse, "%") + " → " + Metric(after.CpuUse, "%") + Environment.NewLine +
                "Available memory: " + Metric(before.FreeMemoryMb, " MB") + " → " + Metric(after.FreeMemoryMb, " MB") + Environment.NewLine +
                "RAM used: " + Metric(before.RamUsedPercent, "%") + " → " + Metric(after.RamUsedPercent, "%") + Environment.NewLine +
                "Running processes: " + Metric(BenchmarkHistory.CountMedian(_state.BenchmarkRuns, "Before", false), "") + " → " + Metric(BenchmarkHistory.CountMedian(_state.BenchmarkRuns, "After", false), "") + Environment.NewLine +
                "Running services: " + Metric(BenchmarkHistory.CountMedian(_state.BenchmarkRuns, "Before", true), "") + " → " + Metric(BenchmarkHistory.CountMedian(_state.BenchmarkRuns, "After", true), "") + Environment.NewLine +
                "Last boot duration: " + Metric(before.BootSeconds, " s") + " → " + Metric(after.BootSeconds, " s") + Environment.NewLine +
                "These snapshots describe current conditions and do not measure game FPS. Process/service counts are context; fewer is not automatically better. Repeat small differences under the same workload.";
            _labStatus.Text = compare;
        }

        private static double ReadLastRecordedBootSeconds()
        {
            var query = new EventLogQuery("Microsoft-Windows-Diagnostics-Performance/Operational", PathType.LogName, "*[System[(EventID=100)]]") { ReverseDirection = true };
            using (var reader = new EventLogReader(query))
            using (EventRecord record = reader.ReadEvent())
            {
                if (record == null) return -1;
                var xml = new System.Xml.XmlDocument(); xml.LoadXml(record.ToXml());
                System.Xml.XmlNode boot = xml.SelectSingleNode("//*[local-name()='Data' and @Name='BootTime']");
                return boot == null ? -1 : Convert.ToDouble(boot.InnerText) / 1000.0;
            }
        }

        private static string Metric(double value, string suffix)
        { return value < 0 ? "n/a" : value.ToString("N1") + suffix; }

        private void VerifyTweaks()
        {
            int good = 0, drifted = 0; var lines = new List<string>();
            foreach (AppliedTweak applied in _state.Applied)
            {
                TweakDefinition tweak = _catalogue.FirstOrDefault(x => x.Id == applied.Id);
                if (tweak == null) { lines.Add("UNVERIFIED  " + applied.Name + " (undo is available in Restore)"); continue; }
                bool matches = true;
                if (applied.Values != null && applied.Values.Any(x => !String.IsNullOrWhiteSpace(x.TargetKind)))
                {
                    foreach (RegValueChange expected in applied.Values) try { RegistryHive hive = String.IsNullOrWhiteSpace(expected.Hive) ? RegistryHive.CurrentUser : (RegistryHive)Enum.Parse(typeof(RegistryHive), expected.Hive, true); RegistryValueKind kind = (RegistryValueKind)Enum.Parse(typeof(RegistryValueKind), expected.TargetKind, true); using (RegistryKey root = RegistryKey.OpenBaseKey(hive, RegistryView.Default)) using (RegistryKey key = root.OpenSubKey(expected.KeyPath, false)) { object actual = key == null ? null : key.GetValue(expected.Name, null, RegistryValueOptions.DoNotExpandEnvironmentNames); if (key == null || key.GetValueKind(expected.Name) != kind || !RegistryData.Equal(actual, expected.TargetValue, kind)) matches = false; } } catch { matches = false; }
                }
                else foreach (ValueTarget target in tweak.ResolveTargets()) try { using (RegistryKey root = RegistryKey.OpenBaseKey(target.Hive, RegistryView.Default)) using (RegistryKey key = root.OpenSubKey(target.KeyPath, false)) { object actual = key == null ? null : key.GetValue(target.Name, null, RegistryValueOptions.DoNotExpandEnvironmentNames); if (key == null || key.GetValueKind(target.Name) != target.Kind || !RegistryData.Equal(actual, target.Value, target.Kind)) matches = false; } } catch { matches = false; }
                if (applied.Services != null) foreach (ServiceChange changed in applied.Services) try { ServiceChange current = ReadServiceState(changed.Name); if (current == null || !String.Equals(current.StartMode, "Disabled", StringComparison.OrdinalIgnoreCase) || current.WasRunning) matches = false; } catch { matches = false; }
                if (applied.Adapters != null && !VerifyAdapterFeatures(applied.Adapters)) matches = false;
                if (applied.AdvancedAdapters != null && !VerifyAdvancedAdapterChanges(applied.AdvancedAdapters)) matches = false;
                if (applied.PowerSettings != null && !PowerSettingsMatch(applied.PowerSettings)) matches = false;
                if (applied.BootSettings != null && !BootSettingsMatch(applied.BootSettings)) matches = false;
                if (applied.NetshSettings != null && !NetshSettingsMatch(applied.NetshSettings)) matches = false;
                if (applied.ScheduledTasks != null && !ScheduledTasksMatch(applied.ScheduledTasks)) matches = false;
                if (!String.IsNullOrWhiteSpace(applied.TargetPowerPlan)) try { if (!String.Equals(ActivePowerPlan(), applied.TargetPowerPlan, StringComparison.OrdinalIgnoreCase)) matches = false; } catch { matches = false; }
                if (applied.OriginalHibernationEnabled.HasValue) try { if (HibernationEnabled()) matches = false; } catch { matches = false; }
                if (applied.OriginalMemoryCompression.HasValue) try { if (ReadMemoryCompression()) matches = false; } catch { matches = false; }
                if (matches) good++; else drifted++; lines.Add((matches ? "OK    " : "CHECK ") + applied.Name);
            }
            if (lines.Count == 0) lines.Add("No tracked changes to verify."); _labStatus.Text = "Verified " + good + " tracked item(s); " + drifted + " need review." + Environment.NewLine + String.Join(Environment.NewLine, lines.ToArray());
        }

        private string BuildSystemSummary()
        {
            string windows = "Windows " + Environment.OSVersion.Version.ToString();
            try { using (RegistryKey key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion")) { string product = Convert.ToString(key.GetValue("ProductName", "Windows")); string display = Convert.ToString(key.GetValue("DisplayVersion", "")); windows = product + (String.IsNullOrEmpty(display) ? "" : " · " + display); } } catch { }
            string[] drives = DriveInfo.GetDrives().Where(x => x.IsReady).Select(x => x.Name.TrimEnd('\\') + " " + FormatBytes(x.AvailableFreeSpace) + " free").ToArray();
            return windows + "\n" + Environment.ProcessorCount + " logical processors\n" + String.Join("\n", drives);
        }

        private static string BuildHardwareReport()
        {
            var lines = new List<string> { "SHARK OPTIMIZER SYSTEM CHECK", "" };
            try { using (var search = new ManagementObjectSearcher("SELECT Name,NumberOfCores,NumberOfLogicalProcessors FROM Win32_Processor")) using (ManagementObjectCollection rows = search.Get()) foreach (ManagementObject cpu in rows) { using (cpu) lines.Add("CPU: " + Convert.ToString(cpu["Name"]) + " · " + Convert.ToString(cpu["NumberOfCores"]) + " cores / " + Convert.ToString(cpu["NumberOfLogicalProcessors"]) + " threads"); } } catch { lines.Add("CPU details unavailable."); }
            try
            {
                using (var search = new ManagementObjectSearcher("SELECT Name,DriverVersion,DriverDate,CurrentRefreshRate FROM Win32_VideoController")) using (ManagementObjectCollection rows = search.Get())
                {
                    foreach (ManagementObject gpu in rows) using (gpu)
                    {
                        string line = "GPU: " + Convert.ToString(gpu["Name"]) + " · driver " + Convert.ToString(gpu["DriverVersion"]);
                        try { string date = Convert.ToString(gpu["DriverDate"]); if (!String.IsNullOrWhiteSpace(date)) line += " · driver date " + ManagementDateTimeConverter.ToDateTime(date).ToString("d"); } catch { }
                        try { uint refresh = Convert.ToUInt32(gpu["CurrentRefreshRate"]); if (refresh > 0) line += " · display " + refresh + " Hz"; } catch { }
                        lines.Add(line);
                    }
                }
            }
            catch { lines.Add("Graphics and display details unavailable."); }
            try
            {
                var speeds = new List<uint>(); using (var search = new ManagementObjectSearcher("SELECT Speed,ConfiguredClockSpeed FROM Win32_PhysicalMemory")) using (ManagementObjectCollection rows = search.Get()) foreach (ManagementObject module in rows) using (module) { try { speeds.Add(Convert.ToUInt32(module["ConfiguredClockSpeed"])); } catch { try { speeds.Add(Convert.ToUInt32(module["Speed"])); } catch { } } }
                if (speeds.Count > 0) { uint current = speeds.Min(); lines.Add("Memory: " + speeds.Count + " module(s) · configured " + current + " MHz" + (speeds.Count == 1 ? " · one module detected; dual-channel memory uses matched modules" : "")); }
                else lines.Add("Memory module speed unavailable.");
            }
            catch { lines.Add("Memory module details unavailable."); }
            try
            {
                var network = NetworkInterface.GetAllNetworkInterfaces().Where(x => x.OperationalStatus == OperationalStatus.Up && x.NetworkInterfaceType != NetworkInterfaceType.Loopback).ToList();
                bool wifi = network.Any(x => x.NetworkInterfaceType == NetworkInterfaceType.Wireless80211);
                lines.Add(network.Count == 0 ? "Network: no active adapter detected." : "Network: " + (wifi ? "Wi-Fi connection detected; Ethernet often gives steadier game latency." : "wired or other connection detected") + " · " + String.Join(", ", network.Select(x => x.Name).ToArray()));
            }
            catch { lines.Add("Network adapter details unavailable."); }
            try { using (RegistryKey key = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\SecureBoot\State")) { object value = key == null ? null : key.GetValue("UEFISecureBootEnabled"); lines.Add(value == null ? "Secure Boot: unavailable (legacy BIOS or restricted access)." : "Secure Boot: " + (Convert.ToInt32(value) == 1 ? "on" : "off")); } } catch { lines.Add("Secure Boot status unavailable."); }
            try
            {
                using (var search = new ManagementObjectSearcher(@"root\CIMV2\Security\MicrosoftTpm", "SELECT IsEnabled_InitialValue,IsActivated_InitialValue FROM Win32_Tpm")) using (ManagementObjectCollection rows = search.Get())
                {
                    ManagementObject tpm = rows.Cast<ManagementObject>().FirstOrDefault(); if (tpm == null) lines.Add("TPM: not detected or not available through Windows management."); else using (tpm) lines.Add("TPM: " + Convert.ToString(tpm["IsEnabled_InitialValue"]) + " enabled · " + Convert.ToString(tpm["IsActivated_InitialValue"]) + " activated");
                }
            }
            catch { lines.Add("TPM status unavailable."); }
            try
            {
                using (var search = new ManagementObjectSearcher(@"root\Microsoft\Windows\DeviceGuard", "SELECT VirtualizationBasedSecurityStatus FROM Win32_DeviceGuard")) using (ManagementObjectCollection rows = search.Get())
                {
                    ManagementObject guard = rows.Cast<ManagementObject>().FirstOrDefault(); if (guard != null) using (guard) lines.Add("Virtualization-Based Security: " + (Convert.ToInt32(guard["VirtualizationBasedSecurityStatus"]) == 2 ? "running" : "not running"));
                }
            }
            catch { }
            try
            {
                string root = Path.GetPathRoot(Environment.SystemDirectory); var drive = new DriveInfo(root); double free = 100.0 * drive.AvailableFreeSpace / drive.TotalSize;
                lines.Add("System drive: " + free.ToString("N0") + "% free · " + FormatBytes(drive.AvailableFreeSpace));
                if (free < 15) lines.Add("Tip: low free space can affect updates and game installs. Consider freeing storage.");
            }
            catch { lines.Add("System drive capacity unavailable."); }
            lines.Add(""); lines.Add("Check driver updates and BIOS memory profiles at your PC or component manufacturer. Recommendations here are informational.");
            return String.Join(Environment.NewLine, lines.ToArray());
        }

        private void ExportSystemReport()
        {
            var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "Text report (*.txt)|*.txt", FileName = "SharkOptimizer-System-Report.txt" }; if (LocalizedFileDialog.Show(dialog, this) != true) return;
            try { File.WriteAllText(dialog.FileName, "SharkOptimizer 2.0.0 system report" + Environment.NewLine + DateTime.Now.ToString("F") + Environment.NewLine + Environment.NewLine + BuildSystemSummary() + Environment.NewLine + Environment.NewLine + "Tracked changes: " + _state.Applied.Count + Environment.NewLine + String.Join(Environment.NewLine, _state.Applied.Select(x => "- " + x.Name).ToArray())); _labStatus.Text = "System report saved to " + dialog.FileName; }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, "Export failed", MessageBoxButton.OK, MessageBoxImage.Error); }
        }

        private void ExportProfile()
        {
            var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "SharkOptimizer profile (*.json)|*.json", FileName = "SharkOptimizer-Profile.json" }; if (LocalizedFileDialog.Show(dialog, this) != true) return;
            try { var profile = new Dictionary<string, object> { { "App", "SharkOptimizer" }, { "Version", "2.0.0" }, { "Created", DateTime.Now.ToString("s") }, { "Tweaks", _state.Applied.Select(x => x.Id).Where(x => !x.StartsWith("legacy-", StringComparison.OrdinalIgnoreCase)).Select(ExportPresetId).ToList() } }; File.WriteAllText(dialog.FileName, _json.Serialize(profile)); _labStatus.Text = "Profile exported. Matching option IDs use legacy names for compatibility; native-only options may be unavailable in older builds. Importing selects options for review and does not apply them."; }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, "Export failed", MessageBoxButton.OK, MessageBoxImage.Error); }
        }

        private void ImportProfile()
        {
            var dialog = new Microsoft.Win32.OpenFileDialog { Filter = "SharkOptimizer profile (*.json)|*.json", Title = "Import an optimization profile" }; if (LocalizedFileDialog.Show(dialog, this) != true) return;
            try {
                if (new FileInfo(dialog.FileName).Length > 1024 * 1024) throw new InvalidDataException("Profile files must be no larger than 1 MB.");
                List<string> ids = ReadProfileIds(File.ReadAllText(dialog.FileName)); int unavailable = 0, applied = 0, added = 0;
                foreach (string id in ids.Distinct(StringComparer.OrdinalIgnoreCase)) {
                    string mapped = MapLegacyTweakId(id);
                    if (mapped == null || !CanSelectTweak(mapped)) unavailable++;
                    else if (_state.Applied.Any(x => x.Id == mapped)) applied++;
                    else if (_selectedTweaks.Add(mapped)) added++;
                }
                RefreshAll(); ShowPage("Optimize"); _tweakSearch.Clear(); _categoryFilter.SelectedIndex = 0; RenderTweakCards();
                MessageBox.Show(this, "Added " + added + " options to your selection. " + applied + " already applied; " + unavailable + " unavailable. Review the selection before applying.", "Profile imported", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, "Import failed", MessageBoxButton.OK, MessageBoxImage.Error); }
        }

        private List<string> ReadProfileIds(string json)
        {
            object parsed = _json.DeserializeObject(json); var ids = new List<string>();
            IEnumerable source = parsed as IEnumerable;
            var dictionary = parsed as IDictionary<string, object>;
            if (dictionary != null) { object tweaks = dictionary.FirstOrDefault(x => String.Equals(x.Key, "Tweaks", StringComparison.OrdinalIgnoreCase)).Value; source = tweaks as IEnumerable; }
            if (source == null || source is string || source is IDictionary) throw new InvalidDataException("This profile does not contain a tweak list.");
            int entries = 0;
            foreach (object id in source) {
                if (++entries > 1000) throw new InvalidDataException("A profile can contain up to 1000 option entries.");
                if (id is string) ids.Add((string)id);
                else { var item = id as IDictionary<string, object>; if (item != null && item.ContainsKey("Id")) ids.Add(Convert.ToString(item["Id"])); else throw new InvalidDataException("A profile option entry is invalid."); }
            }
            return ids;
        }

        private static readonly Dictionary<string, string> LegacyTweakAliases = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                { "p_telemetry", "system-telemetry-policy" }, { "p_wer", "system-error-reporting" }, { "p_llmnr", "system-llmnr" }, { "p_remote", "system-remote-assistance" }, { "p_remreg", "disable-remote-registry" }, { "p_nvtel", "disable-nvidia-telemetry" }, { "p_tasks", "disable-telemetry-tasks" },
                { "p_adid", "advertising-id" }, { "p_bing", "start-web-search" }, { "p_cortana", "disable-cortana-cloud-search" },
                { "p_activity", "activity-history" }, { "p_ads", "remove-windows-ads" }, { "p_consumer", "disable-consumer-suggestions" },
                { "p_copilot", "disable-copilot" }, { "p_recall", "disable-windows-ai-capture" }, { "p_feedback", "feedback-prompts" }, { "p_inventory", "disable-app-inventory" }, { "p_widgets", "disable-widgets-policy" },
                { "p_ink", "typing-collection" }, { "p_clip", "clipboard-sync" }, { "p_location", "disable-location-policy" }, { "p_do", "disable-update-sharing" },
                { "q_ext", "file-extensions" }, { "q_hidden", "show-hidden-files" }, { "q_thispc", "open-this-pc" }, { "q_recent", "hide-recent-files" },
                { "q_shake", "disable-aero-shake" }, { "q_dark", "dark-mode" }, { "q_taskbar", "clean-windows-taskbar" }, { "q_classic", "classic-context-menu" }, { "q_boot", "detailed-boot-messages" }, { "q_reboot", "prevent-forced-update-restarts" }, { "q_menu", "menu-delay" },
                { "q_kb", "keyboard-repeat" }, { "q_sticky", "sticky-keys" }, { "q_welcome", "post-update-welcome" }, { "q_visfx", "lightweight-visuals" }, { "q_shutdown", "faster-app-shutdown" }, { "q_startdelay", "startup-delay" },
                { "q_bgapps", "limit-background-apps" }, { "q_search", "disable-search-indexing" }, { "f_gamemode", "game-mode" }, { "f_dvr", "game-capture" }, { "f_overlay", "gamebar-overlay" }, { "f_sysmain", "disable-sysmain" }, { "f_timerreq", "global-timer-resolution-requests" },
                { "n_nagle", "tcp-nagle" }, { "n_netbios", "disable-netbios" }, { "n_ports", "faster-tcp-port-reuse" }, { "n_rsc", "disable-rsc" }, { "n_lso", "disable-lso" }, { "n_nicpwr", "disable-adapter-power-saving" }, { "n_dns", "cloudflare-dns" }, { "n_throttle", "disable-network-throttling" }, { "n_qos", "remove-qos-reserve" }, { "n_wifi", "wifi-maximum-performance" }, { "n_rss", "enable-receive-side-scaling" },
                { "n_eee", "disable-eee" }, { "n_flow", "disable-flow-control" }, { "n_intmod", "disable-interrupt-moderation" }, { "n_heur", "disable-tcp-heuristics" }, { "n_teredo", "disable-teredo" },
                { "f_fso", "fullscreen-optimizations" }, { "f_mouse", "raw-mouse" }, { "f_throttle", "disable-power-throttling" }, { "f_prio", "foreground-priority-boost" },
                { "f_mmcss", "game-scheduling-profile" }, { "f_hags", "enable-gpu-scheduling" }, { "f_mpo", "disable-mpo" }, { "f_fast", "disable-fast-startup" }, { "f_usb", "usb-selective-suspend" }, { "f_pcie", "disable-pcie-link-power-saving" }, { "f_diskoff", "keep-hard-disks-awake" }, { "f_cpumin", "maximum-cpu-minimum-state" },
                { "w_maint", "disable-automatic-maintenance" }, { "w_lastaccess", "disable-ntfs-last-access" }, { "w_8dot3", "disable-ntfs-83-names" }, { "w_wudrv", "exclude-driver-updates" }, { "w_edge", "disable-edge-startup-boost" }, { "w_services", "disable-unused-services" }, { "w_spooler", "disable-print-spooler" },
                { "w_chat", "remove-teams-chat-icon" }, { "w_svchost", "merge-service-host-processes" }, { "w_pagingexec", "keep-kernel-in-ram" }, { "w_prefetch", "disable-prefetcher" }, { "w_onedrive", "disable-onedrive-policy" }, { "a_xbox", "disable-xbox-services" },
                { "a_ipv6", "disable-ipv6" }, { "a_spectre", "disable-cpu-mitigations" }, { "a_vbs", "disable-vbs-memory-integrity" }, { "a_msi", "gpu-msi-mode" }, { "a_tick", "disable-dynamic-tick" }, { "a_hyperv", "disable-hypervisor" }, { "a_hib", "disable-hibernation" }, { "f_power", "ultimate-performance-plan" }, { "w_memcomp", "disable-memory-compression" }
            };
        private string MapLegacyTweakId(string id)
        {
            if (String.IsNullOrWhiteSpace(id)) return null;
            id = id.Trim(); TweakDefinition native = _catalogue.FirstOrDefault(x => String.Equals(x.Id, id, StringComparison.OrdinalIgnoreCase)); if (native != null) return native.Id;
            CustomTweak custom = (_state.CustomTweaks ?? new List<CustomTweak>()).FirstOrDefault(x => String.Equals(x.Id, id, StringComparison.OrdinalIgnoreCase)); if (custom != null) return custom.Id;
            string mapped; return LegacyTweakAliases.TryGetValue(id, out mapped) ? mapped : null;
        }

        private UIElement BuildRestore()
        {
            var panel = ScrollColumn(); var intro = Card(); var header = new Grid(); header.ColumnDefinitions.Add(new ColumnDefinition()); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var copy = new StackPanel(); copy.Children.Add(Text("Restore your changes", 20, Brushes.White, true)); copy.Children.Add(Text("Applied optimizations save the previous registry values and service states so you can undo them later.", 11, Brush(MutedColor), false, 0, 5)); header.Children.Add(copy);
            var undoAll = ActionButton("Undo all", false); undoAll.VerticalAlignment = VerticalAlignment.Center; undoAll.Click += async delegate { await UndoAll(); }; Grid.SetColumn(undoAll, 1); header.Children.Add(undoAll); intro.Child = header; panel.Children.Add(intro);
            if (_state.MaintenanceServices.Count > 0) panel.Children.Add(MaintenanceRecoveryCard());
            _restoreList = new StackPanel(); panel.Children.Add(_restoreList); RefreshRestore(); return panel;
        }

        private UIElement BuildSettings()
        {
            var panel = ScrollColumn();
            var preferences = new StackPanel(); var startup = new StackPanel(); var data = new StackPanel(); var maintenance = new StackPanel();
            panel.Children.Add(BuildSettingsNavigation(new[] { preferences, startup, data, maintenance }));
            foreach (StackPanel section in new[] { preferences, startup, data, maintenance }) panel.Children.Add(section);
            preferences.Children.Add(BuildAppearanceCard());
            preferences.Children.Add(BuildLanguageCard());
            preferences.Children.Add(BuildBehaviorCard());
            startup.Children.Add(BuildStartupCard());
            data.Children.Add(BuildBackupCard());
            data.Children.Add(BuildCustomTweaksCard());
            data.Children.Add(BuildDataActionsCard());
            var updateCard = Card(); var updateStack = new StackPanel();
            updateStack.Children.Add(Text("Updates", 16, Brushes.White, true));
            updateStack.Children.Add(Text("Check the official SharkOptimizer GitHub releases for a newer setup. Updates download and install through the signed-in Windows session.", 11, Brush(MutedColor), false, 0, 5));
            var automaticUpdates = new CheckBox { Content = "Check for updates automatically after startup", IsChecked = _state.AutoCheckUpdates, Foreground = Brushes.White, Margin = new Thickness(0, 10, 0, 3) };
            automaticUpdates.Click += delegate
            {
                bool previous = _state.AutoCheckUpdates; _state.AutoCheckUpdates = automaticUpdates.IsChecked == true;
                try { SaveState(); if (_state.AutoCheckUpdates) { _updateCheckTimer.Interval = TimeSpan.FromSeconds(8); _updateCheckTimer.Start(); } else _updateCheckTimer.Stop(); }
                catch (Exception ex) { _state.AutoCheckUpdates = previous; automaticUpdates.IsChecked = previous; MessageBox.Show(this, "The update preference could not be saved." + Environment.NewLine + ex.Message, "Updates", MessageBoxButton.OK, MessageBoxImage.Warning); }
            };
            updateStack.Children.Add(automaticUpdates);
            var automaticDownloads = new CheckBox { Content = "Download updates automatically in the background", IsChecked = _state.AutoDownloadUpdates, Foreground = Brushes.White, Margin = new Thickness(0, 8, 0, 3) };
            automaticDownloads.Click += delegate { bool previous = _state.AutoDownloadUpdates; _state.AutoDownloadUpdates = automaticDownloads.IsChecked == true; try { SaveState(); } catch (Exception ex) { _state.AutoDownloadUpdates = previous; automaticDownloads.IsChecked = previous; MessageBox.Show(this, "The update preference could not be saved." + Environment.NewLine + ex.Message, "Updates", MessageBoxButton.OK, MessageBoxImage.Warning); } }; updateStack.Children.Add(automaticDownloads);
            updateStack.Children.Add(Text("Updates are checked at startup and every six hours. Downloaded updates wait for your confirmation before installation.", 10, Brush(MutedColor), false, 0, 5));
            _updateStatus = Text("Release channel · GitHub stable releases", 10, Brush(MutedColor), false, 0, 5); updateStack.Children.Add(_updateStatus);
            _updateButton = ActionButton("Check for updates", true); _updateButton.Margin = new Thickness(-5, 7, 0, 0); _updateButton.Click += async delegate { if (HasPendingUpdate()) await InstallPendingUpdate(); else await CheckForUpdates(false); }; updateStack.Children.Add(_updateButton); RefreshUpdateControls();
            updateCard.Child = updateStack; startup.Children.Add(updateCard);
            var card = Card(); var stack = new StackPanel();
            stack.Children.Add(Text("SharkOptimizer 2.0.0", 20, Brushes.White, true));
            stack.Children.Add(Text("Windows optimization and game tools", 12, Brush(MutedColor), false, 0, 6));
            stack.Children.Add(Text("Closing the window sends SharkOptimizer to the notification area. Double-click its tray icon to reopen it, or choose Exit from the tray menu to quit.", 11, Brush(MutedColor), false, 0, 8));
            var openData = ActionButton("Open data folder", false); openData.Margin = new Thickness(-5, 10, 0, 0); openData.Click += delegate { try { Directory.CreateDirectory(Path.GetDirectoryName(_dataPath)); Process.Start(new ProcessStartInfo(Path.GetDirectoryName(_dataPath)) { UseShellExecute = true }); } catch (Exception ex) { MessageBox.Show(this, ex.Message, "Open data folder", MessageBoxButton.OK, MessageBoxImage.Information); } }; stack.Children.Add(openData);
            var notices = ActionButton("Third-party notices", false); notices.Margin = new Thickness(-5, 8, 0, 0); notices.Click += delegate { ShowThirdPartyNotices(); }; stack.Children.Add(notices);
            stack.Children.Add(Text("State file", 10, Brush(MutedColor), true, 0, 8));
            var path = new TextBlock { Text = _dataPath, TextWrapping = TextWrapping.Wrap, FontSize = 11, Foreground = Brushes.White };
            stack.Children.Add(path); card.Child = stack; data.Children.Add(card);

            var restorePointCard = Card(); var restorePointStack = new StackPanel();
            restorePointStack.Children.Add(Text("Windows restore point", 16, Brushes.White, true));
            restorePointStack.Children.Add(Text("Create a Windows recovery checkpoint before making system-level changes. Windows may limit new points to one per 24 hours. SharkOptimizer's Restore page separately tracks its own reversible settings.", 11, Brush(MutedColor), false, 0, 5));
            var createRestorePoint = ActionButton("Create restore point", false); createRestorePoint.Margin = new Thickness(-5, 7, 0, 0); createRestorePoint.Click += async delegate { createRestorePoint.IsEnabled = false; createRestorePoint.Content = "Creating…"; string result = await CreateSystemRestorePoint(); createRestorePoint.IsEnabled = true; createRestorePoint.Content = "Create restore point"; MessageBox.Show(this, result, "Windows restore point", MessageBoxButton.OK, result.StartsWith("Windows accepted", StringComparison.Ordinal) ? MessageBoxImage.Information : MessageBoxImage.Warning); };
            restorePointStack.Children.Add(createRestorePoint); restorePointCard.Child = restorePointStack; maintenance.Children.Add(restorePointCard);

            var cleanup = Card(); var cleanStack = new StackPanel(); cleanStack.Children.Add(Text("Scheduled cleanup", 16, Brushes.White, true));
            cleanStack.Children.Add(Text("Once a week, remove files older than two days from your temporary files, crash dumps, and shader caches. It never clears documents or the Recycle Bin.", 11, Brush(MutedColor), false, 0, 4));
            _cleanupScheduleStatus = Text("Checking schedule…", 11, Brush(AccentColor), false, 0, 8); cleanStack.Children.Add(_cleanupScheduleStatus);
            var scheduleRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(-5, 8, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            _cleanupDayPicker = new ComboBox { Width = 135, Height = 36, Margin = new Thickness(5, 0, 5, 0), Padding = new Thickness(7, 5, 7, 5), Background = Brush(SurfaceRaised), Foreground = Brushes.White, BorderBrush = Brush(BorderColor) };
            string[] days = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" }; string[] dayCodes = { "MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN" };
            for (int i = 0; i < days.Length; i++) { var item = new ComboBoxItem { Content = days[i], Tag = dayCodes[i] }; _cleanupDayPicker.Items.Add(item); if (dayCodes[i] == _state.CleanupDay) _cleanupDayPicker.SelectedItem = item; }
            _cleanupTimeEntry = new TextBox { Text = _state.CleanupTime, Width = 75, Height = 36, Margin = new Thickness(5, 0, 5, 0), Padding = new Thickness(9, 7, 9, 7), Background = Brush(SurfaceRaised), Foreground = Brushes.White, BorderBrush = Brush(BorderColor), VerticalContentAlignment = VerticalAlignment.Center, ToolTip = "24-hour time, for example 20:00" };
            var enable = ActionButton("Enable weekly cleanup", true); enable.Click += delegate { EnableWeeklyCleanup(); };
            var disable = ActionButton("Disable", false); disable.Click += delegate { DisableWeeklyCleanup(); };
            var run = ActionButton("Run now", false); run.Click += async delegate { await RunCleanupNow(); };
            scheduleRow.Children.Add(_cleanupDayPicker); scheduleRow.Children.Add(_cleanupTimeEntry); scheduleRow.Children.Add(enable); scheduleRow.Children.Add(disable); scheduleRow.Children.Add(run); cleanStack.Children.Add(scheduleRow);
            cleanup.Child = cleanStack; maintenance.Children.Add(cleanup); RefreshCleanupSchedule(); return panel;
        }

        private void ImportLegacyAppearance()
        {
            try
            {
                string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SharkOptimizer", "settings.json");
                if (!File.Exists(path)) return;
                var settings = _json.DeserializeObject(File.ReadAllText(path)) as IDictionary<string, object>;
                if (settings != null && settings.ContainsKey("AutoUpdate") && settings["AutoUpdate"] is bool) { _state.AutoCheckUpdates = (bool)settings["AutoUpdate"]; _legacyStateMigrated = true; }
                if (settings != null && settings.ContainsKey("TextScale")) { double scale; if (Double.TryParse(Convert.ToString(settings["TextScale"], CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out scale) && new[] { .9, 1, 1.1, 1.25 }.Contains(scale)) { _state.InterfaceScale = scale; _legacyStateMigrated = true; } }
                if (settings != null && settings.ContainsKey("Accent"))
                {
                    string accent = Convert.ToString(settings["Accent"]).ToLowerInvariant();
                    if (AccentOptions.ContainsKey(accent)) { _state.Accent = accent; _legacyStateMigrated = true; }
                }
            }
            catch { }
        }

        private static FontFamily ResolveUiFont(string choice)
        {
            if (choice == "Segoe UI") return new FontFamily("Segoe UI");
            string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SharkOptimizer", "Fonts");
            Directory.CreateDirectory(directory);
            foreach (string name in new[] { "Poppins-Regular.ttf", "Poppins-Bold.ttf" })
            using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("SharkOptimizer.Fonts." + name))
            {
                if (resource == null) throw new InvalidDataException("Bundled font missing: " + name);
                using (var memory = new MemoryStream())
                {
                    resource.CopyTo(memory); byte[] data = memory.ToArray(); string destination = Path.Combine(directory, name);
                    if (!File.Exists(destination) || !File.ReadAllBytes(destination).SequenceEqual(data)) File.WriteAllBytes(destination, data);
                }
            }
            return new FontFamily(new Uri(directory.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar), "./#Poppins");
        }

        private static Color AccentTint(Color accent, Color background, double amount)
        { return Color.FromRgb((byte)(background.R + (accent.R - background.R) * amount), (byte)(background.G + (accent.G - background.G) * amount), (byte)(background.B + (accent.B - background.B) * amount)); }

        private static void SetAccentBrushes(string name)
        {
            Color color = AccentOptions[name]; LivePalette.Accent = color;
            LivePalette.NavFill = AccentTint(color, BackgroundColor, 0.16);
            LivePalette.NavBorder = AccentTint(color, BackgroundColor, 0.30);
        }

        private UIElement BuildAppearanceCard()
        {
            var card = Card(); var body = new StackPanel();
            body.Children.Add(Text("Appearance", 16, Brushes.White, true));
            body.Children.Add(Text("Choose an accent and font. Your changes apply immediately and are saved for the next launch.", 11, Brush(MutedColor), false, 0, 5));
            var swatches = new WrapPanel { Margin = new Thickness(-5, 10, 0, 0) }; _accentChoices.Clear();
            foreach (var option in AccentOptions)
            {
                string name = option.Key; var button = ActionButton(CultureInfo.InvariantCulture.TextInfo.ToTitleCase(name), false);
                button.Background = new SolidColorBrush(option.Value); button.Foreground = Brush(BackgroundColor);
                button.BorderBrush = Brushes.Transparent; button.Click += delegate { ChangeAppearance(name, _state.UiFont); };
                _accentChoices.Add(name, button); swatches.Children.Add(button);
            }
            body.Children.Add(swatches); body.Children.Add(Text("Interface font", 11, Brush(MutedColor), true, 0, 12));
            var fonts = new ComboBox { Width = 210, Height = 36, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0), Padding = new Thickness(8, 5, 8, 5), Background = Brush(SurfaceRaised), Foreground = Brushes.White, BorderBrush = Brush(BorderColor) };
            fonts.Items.Add("Poppins"); fonts.Items.Add("Segoe UI"); fonts.SelectedItem = _state.UiFont;
            fonts.SelectionChanged += delegate { string selected = Convert.ToString(fonts.SelectedItem); if (selected != _state.UiFont) { ChangeAppearance(_state.Accent, selected); fonts.SelectedItem = _state.UiFont; } };
            body.Children.Add(fonts); body.Children.Add(Text("SharkOptimizer · Ready when you are", 18, Brushes.White, true, 0, 12));
            body.Children.Add(Text("Interface size", 11, Brush(MutedColor), true, 0, 14));
            var size = new ComboBox { Width = 210, Height = 36, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0), Padding = new Thickness(8, 5, 8, 5), Background = Brush(SurfaceRaised), Foreground = Brushes.White, BorderBrush = Brush(BorderColor) };
            foreach (double scale in new[] { .9, 1, 1.1, 1.25 }) { var item = new ComboBoxItem { Content = (scale * 100).ToString("0", CultureInfo.InvariantCulture) + "%", Tag = scale }; size.Items.Add(item); if (scale == _state.InterfaceScale) size.SelectedItem = item; }
            size.SelectionChanged += delegate
            {
                var item = size.SelectedItem as ComboBoxItem; if (item == null || (double)item.Tag == _state.InterfaceScale) return; double previous = _state.InterfaceScale; _state.InterfaceScale = (double)item.Tag;
                try { SaveState(); ((FrameworkElement)Content).LayoutTransform = new ScaleTransform(_state.InterfaceScale, _state.InterfaceScale); }
                catch (Exception ex) { _state.InterfaceScale = previous; foreach (ComboBoxItem old in size.Items) if ((double)old.Tag == previous) { size.SelectedItem = old; break; } MessageBox.Show(this, "The interface size could not be saved." + Environment.NewLine + ex.Message, "Appearance", MessageBoxButton.OK, MessageBoxImage.Warning); }
            };
            body.Children.Add(size);
            foreach (var choice in _accentChoices) { choice.Value.Opacity = choice.Key == _state.Accent ? 1 : 0.55; choice.Value.ToolTip = choice.Key == _state.Accent ? "Selected accent" : "Choose this accent"; }
            card.Child = body; return card;
        }

        private void ChangeAppearance(string accent, string font)
        {
            string oldAccent = _state.Accent, oldFont = _state.UiFont; FontFamily oldFamily = FontFamily;
            try
            {
                if (!AccentOptions.ContainsKey(accent) || (font != "Poppins" && font != "Segoe UI")) throw new InvalidDataException("Choose an available accent and font.");
                FontFamily family = font == _state.UiFont ? FontFamily : ResolveUiFont(font);
                SetAccentBrushes(accent); FontFamily = family; _state.Accent = accent; _state.UiFont = font; SaveState();
                foreach (var choice in _accentChoices) { choice.Value.Opacity = choice.Key == accent ? 1 : 0.55; choice.Value.ToolTip = choice.Key == accent ? "Selected accent" : "Choose this accent"; }
            }
            catch (Exception ex) { _state.Accent = oldAccent; _state.UiFont = oldFont; SetAccentBrushes(oldAccent); FontFamily = oldFamily; MessageBox.Show(this, "Appearance could not be saved." + Environment.NewLine + ex.Message, "Appearance", MessageBoxButton.OK, MessageBoxImage.Warning); }
        }

        private UpdateReleaseInfo FetchLatestRelease()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            const string api = "https://api.github.com/repos/Bas-Makes-Stuff/SharkOptimizer/releases/latest";
            string json = UpdateTransport.ReadJson(new Uri(api), _updateDownloadCancellation == null ? System.Threading.CancellationToken.None : _updateDownloadCancellation.Token);
            var release = new JavaScriptSerializer { MaxJsonLength = 2 * 1024 * 1024 }.DeserializeObject(json) as IDictionary<string, object>;
            if (release == null) throw new InvalidDataException("GitHub returned release data in an unsupported format.");
            string tag = Convert.ToString(release.ContainsKey("tag_name") ? release["tag_name"] : "").Trim();
            if (tag.StartsWith("v", StringComparison.OrdinalIgnoreCase)) tag = tag.Substring(1);
            int dash = tag.IndexOf('-'); if (dash >= 0) tag = tag.Substring(0, dash);
            Version version; if (!Version.TryParse(tag, out version)) throw new InvalidDataException("The latest GitHub release has an invalid version tag.");
            var result = new UpdateReleaseInfo { Version = version, ReleaseUrl = Convert.ToString(release.ContainsKey("html_url") ? release["html_url"] : "") };
            IEnumerable assets = release.ContainsKey("assets") ? release["assets"] as IEnumerable : null;
            if (assets != null) foreach (object assetObject in assets)
            {
                var asset = assetObject as IDictionary<string, object>; if (asset == null) continue;
                if (!String.Equals(Convert.ToString(asset.ContainsKey("name") ? asset["name"] : ""), "SharkOptimizer-Setup.exe", StringComparison.OrdinalIgnoreCase)) continue;
                result.AssetUrl = Convert.ToString(asset.ContainsKey("browser_download_url") ? asset["browser_download_url"] : "");
                result.AssetDigest = Convert.ToString(asset.ContainsKey("digest") ? asset["digest"] : "");
                long size; result.AssetSize = Int64.TryParse(Convert.ToString(asset.ContainsKey("size") ? asset["size"] : "0"), out size) ? size : 0;
                break;
            }
            return result;
        }

        private string DownloadAndVerifySetup(UpdateReleaseInfo release)
        {
            Uri uri; if (!Uri.TryCreate(release.AssetUrl, UriKind.Absolute, out uri)) throw new InvalidDataException("The setup download URL is not an official HTTPS GitHub release asset.");
            UpdateTransport.ValidateAssetUri(uri);
            if (release.AssetSize < 1 || release.AssetSize > 100L * 1024L * 1024L) throw new InvalidDataException("The setup asset size is invalid or exceeds the 100 MB update limit.");
            string folder = Path.Combine(Path.GetTempPath(), "SharkOptimizer-Updates"); Directory.CreateDirectory(folder);
            string path = Path.Combine(folder, "SharkOptimizer-Setup-" + release.Version.ToString(3) + "-" + Guid.NewGuid().ToString("N") + ".exe");
            UpdateTransport.Download(uri, path, release.AssetSize, _updateDownloadCancellation == null ? System.Threading.CancellationToken.None : _updateDownloadCancellation.Token);
            try {
            ValidateDownloadedSetup(path, release); return path;
            } catch { try { File.Delete(path); } catch { } throw; }
        }

        private static void ValidateDownloadedSetup(string path, UpdateReleaseInfo release)
        {
            FileInfo downloaded = new FileInfo(path); if (downloaded.Length != release.AssetSize) throw new InvalidDataException("The downloaded setup file size does not match GitHub's release metadata.");
            if (!String.IsNullOrWhiteSpace(release.AssetDigest) && release.AssetDigest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
            {
                string expected = release.AssetDigest.Substring("sha256:".Length).Trim();
                using (var sha = SHA256.Create()) using (FileStream input = File.OpenRead(path))
                { string actual = String.Concat(sha.ComputeHash(input).Select(b => b.ToString("x2", CultureInfo.InvariantCulture)).ToArray()); if (!String.Equals(actual, expected, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The setup file's SHA-256 digest does not match GitHub's release metadata."); }
            }
            string fileVersion = FileVersionInfo.GetVersionInfo(path).ProductVersion; Version packaged;
            if (!Version.TryParse((fileVersion ?? "").Split('-')[0], out packaged) || packaged.Major != release.Version.Major || packaged.Minor != release.Version.Minor || packaged.Build != release.Version.Build)
                throw new InvalidDataException("The downloaded setup's product version does not match GitHub release " + release.Version.ToString(3) + ".");
        }

        private static async Task<string> CreateSystemRestorePoint()
        {
            return await Task.Run<string>(delegate {
                try
                {
                    var scope = new ManagementScope(@"\\.\root\DEFAULT"); scope.Connect();
                    using (var systemRestore = new ManagementClass(scope, new ManagementPath("SystemRestore"), null))
                    using (ManagementBaseObject parameters = systemRestore.GetMethodParameters("CreateRestorePoint"))
                    {
                        parameters["Description"] = "SharkOptimizer 2.0.0 restore point";
                        parameters["RestorePointType"] = 0;
                        parameters["EventType"] = 100;
                        using (ManagementBaseObject result = systemRestore.InvokeMethod("CreateRestorePoint", parameters, null))
                        {
                            int code = Convert.ToInt32(result["ReturnValue"]);
                            return code == 0 ? "Windows accepted the restore point request. It may skip creating a new point if one was created within the last 24 hours." : "Windows could not create the restore point (System Restore returned " + code + "). Check that System Protection is enabled for the Windows drive.";
                        }
                    }
                }
                catch (Exception ex) { return "Could not create a Windows restore point. Check that System Protection is enabled for the Windows drive." + Environment.NewLine + Environment.NewLine + ex.Message; }
            });
        }

        private void EnableWeeklyCleanup()
        {
            var selectedDay = _cleanupDayPicker.SelectedItem as ComboBoxItem; string day = selectedDay == null ? "SUN" : Convert.ToString(selectedDay.Tag);
            string time = _cleanupTimeEntry.Text.Trim(); DateTime parsed;
            if (!DateTime.TryParseExact(time, new[] { "H:mm", "HH:mm" }, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out parsed))
            { MessageBox.Show(this, "Enter a 24-hour time such as 20:00.", "Scheduled cleanup", MessageBoxButton.OK, MessageBoxImage.Information); return; }
            string executable = Assembly.GetExecutingAssembly().Location;
            string action = "\"" + executable + "\" --weekly-cleanup";
            string args = "/Create /TN " + QuoteCommandArgument(CleanupTaskName) + " /SC WEEKLY /D " + day + " /ST " + parsed.ToString("HH:mm") + " /TR " + QuoteCommandArgument(action) + " /F /RL HIGHEST /IT";
            int exit; string output = RunSchtasks(args, out exit);
            if (exit != 0) { MessageBox.Show(this, "Windows Task Scheduler could not create the cleanup task." + Environment.NewLine + output, "Scheduled cleanup", MessageBoxButton.OK, MessageBoxImage.Warning); return; }
            _state.CleanupDay = day; _state.CleanupTime = parsed.ToString("HH:mm"); SaveState(); RefreshCleanupSchedule();
        }

        private void DisableWeeklyCleanup()
        {
            int exit; string output = RunSchtasks("/Delete /TN " + QuoteCommandArgument(CleanupTaskName) + " /F", out exit);
            if (exit != 0) { MessageBox.Show(this, "Windows Task Scheduler could not remove the cleanup task." + Environment.NewLine + output, "Scheduled cleanup", MessageBoxButton.OK, MessageBoxImage.Information); return; }
            RefreshCleanupSchedule();
        }

        private async Task RunCleanupNow()
        {
            if (MessageBox.Show(this, "Clean eligible files from your temporary, crash dump, and shader cache folders now? Files newer than two days and the Recycle Bin are left alone.", "Run cleanup now", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
            _cleanupScheduleStatus.Text = "Cleanup is running…"; await Task.Run(delegate { RunScheduledCleanup(); }); RefreshCleanupSchedule();
            _cleanupScheduleStatus.Text = "Cleanup finished. Check the local cleanup log for the number of files removed.";
        }

        private async void RefreshCleanupSchedule()
        {
            if (_cleanupScheduleStatus == null) return;
            var status = _cleanupScheduleStatus;
            int queryVersion = ++_cleanupQueryVersion;
            status.Text = "Checking schedule…";
            if (_previewMode) { status.Text = "Weekly cleanup is off."; return; }
            try {
                bool? enabled = await Task.Run(() => SharkOptimizer.Platform.StartupRegistration.ReadEnabled(CleanupTaskName));
                if (queryVersion != _cleanupQueryVersion || !Object.ReferenceEquals(status, _cleanupScheduleStatus)) return;
                status.Text = enabled == true ? "Weekly cleanup is on. Open Task Scheduler to review its saved trigger." : "Weekly cleanup is off.";
            } catch (Exception ex) { if (queryVersion == _cleanupQueryVersion && Object.ReferenceEquals(status, _cleanupScheduleStatus)) status.Text = "Could not read the cleanup schedule: " + ex.Message; }
        }

        private static string QuoteCommandArgument(string value)
        {
            var result = new StringBuilder("\""); int slashes = 0;
            foreach (char c in value) { if (c == '\\') { slashes++; continue; } if (c == '"') { result.Append('\\', slashes * 2 + 1); result.Append('"'); slashes = 0; continue; } result.Append('\\', slashes); slashes = 0; result.Append(c); }
            result.Append('\\', slashes * 2); result.Append('"'); return result.ToString();
        }

        private static string RunSchtasks(string arguments, out int exitCode)
        { return RunCapturedSystemTool("schtasks.exe", arguments, 10000, out exitCode); }

        private static bool TryReadScheduledTaskEnabled(string taskPath, out bool enabled)
        {
            try
            {
                bool? value = SharkOptimizer.Platform.StartupRegistration.ReadEnabled(taskPath);
                enabled = value ?? false; return value.HasValue;
            }
            catch (Exception ex) { throw new InvalidOperationException("Windows could not read the enabled state for scheduled task " + taskPath + ".", ex); }
        }

        private static List<ScheduledTaskChange> CaptureScheduledTasks(List<string> taskPaths)
        {
            var changes = new List<ScheduledTaskChange>(); if (taskPaths == null) return changes;
            foreach (string path in taskPaths)
            {
                bool enabled; if (TryReadScheduledTaskEnabled(path, out enabled)) changes.Add(new ScheduledTaskChange { Path = path, OriginalEnabled = enabled, TargetEnabled = false });
            }
            return changes;
        }

        private static void SetScheduledTasks(List<ScheduledTaskChange> tasks, bool restore)
        {
            if (tasks == null) return;
            foreach (ScheduledTaskChange task in tasks)
            {
                bool enabled = restore ? task.OriginalEnabled : task.TargetEnabled; int exit;
                string output = RunSchtasks("/Change /TN " + QuoteCommandArgument(task.Path) + (enabled ? " /Enable" : " /Disable"), out exit);
                if (exit != 0) throw new InvalidOperationException("Windows could not " + (enabled ? "enable" : "disable") + " scheduled task " + task.Path + ". " + output.Trim());
            }
        }

        private static bool ScheduledTasksMatch(List<ScheduledTaskChange> tasks)
        {
            if (tasks == null) return true;
            foreach (ScheduledTaskChange task in tasks) { bool enabled; if (!TryReadScheduledTaskEnabled(task.Path, out enabled) || enabled != task.TargetEnabled) return false; }
            return true;
        }

        internal static void RunScheduledCleanup()
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData); DateTime cutoff = DateTime.UtcNow.AddDays(-2); int removed = 0; long freed = 0;
            string common = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData); string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string[] roots = { Path.GetTempPath(), Path.Combine(windows, "Temp"), Path.Combine(local, "CrashDumps"), Path.Combine(common, "Microsoft", "Windows", "WER", "ReportArchive"), Path.Combine(common, "Microsoft", "Windows", "WER", "ReportQueue"), Path.Combine(local, "D3DSCache"), Path.Combine(local, "NVIDIA", "DXCache"), Path.Combine(local, "NVIDIA", "GLCache"), Path.Combine(local, "AMD", "DxCache"), Path.Combine(local, "Microsoft", "Windows", "WER", "ReportArchive"), Path.Combine(local, "Microsoft", "Windows", "WER", "ReportQueue") };
            foreach (string root in roots) if (Directory.Exists(root)) WalkFilesSafe(root, delegate(string file) { try { var info = new FileInfo(file); if (info.LastWriteTimeUtc < cutoff) { long length = info.Length; File.Delete(file); removed++; freed += length; } } catch { } });
            try { var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "ipconfig.exe"), "/flushdns") { UseShellExecute = false, CreateNoWindow = true }; using (Process process = Process.Start(info)) if (process != null) process.WaitForExit(5000); } catch { }
            try { string log = Path.Combine(local, "SharkOptimizer", "scheduled-cleanup.log"); Directory.CreateDirectory(Path.GetDirectoryName(log)); File.AppendAllText(log, DateTime.Now.ToString("yyyy-MM-dd HH:mm") + "  removed " + removed + " files, freed " + FormatBytes(freed) + Environment.NewLine); } catch { }
        }

        private async Task ApplySelected()
        {
            if (_tweakOperationBusy) return;
            List<TweakDefinition> selected = _catalogue.Where(t => _selectedTweaks.Contains(t.Id) && CanSelectTweak(t.Id) && !_state.Applied.Any(a => a.Id == t.Id)).ToList();
            if (selected.Count == 0) { MessageBox.Show(this, "Select at least one available change.", "SharkOptimizer", MessageBoxButton.OK, MessageBoxImage.Information); return; }
            if (selected.Any(x => !String.IsNullOrEmpty(TweakWarningForReview(x))))
            {
                string warnings = String.Join(Environment.NewLine, selected.Where(x => !String.IsNullOrEmpty(TweakWarningForReview(x))).Select(x => "• " + (Definitions.Any(d => d.Id == x.Id) ? Localization.Translate(x.Name) : x.Name) + ": " + TweakWarningForReview(x)).ToArray());
                if (System.Windows.MessageBox.Show(this, Localization.Translate("Review these notes before applying:") + Environment.NewLine + Environment.NewLine + warnings + Environment.NewLine + Environment.NewLine + Localization.Translate("Continue?"), Localization.Translate("Review changes"), MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
            }
            var before = new HashSet<string>(_state.Applied.Select(x => x.Id), StringComparer.OrdinalIgnoreCase);
            if (!BeginTweakOperation("Applying changes…")) return;
            bool applied = false;
            try
            {
                if (ShouldRequestRestorePoint(selected, _state.AlwaysRestorePoint)) {
                    _pageSubtitle.Text = "Requesting a Windows restore point…";
                    string recovery = await CreateSystemRestorePoint();
                    if (!recovery.StartsWith("Windows accepted", StringComparison.Ordinal) && MessageBox.Show(this, recovery + Environment.NewLine + Environment.NewLine + Localization.Translate("Continue?"), "Restore point unavailable", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
                    if (_sessionExitInProgress) return;
                }
                Exception failure = null;
                try
                {
                int completed = 0;
                foreach (TweakDefinition tweak in selected.OrderBy(x => String.IsNullOrWhiteSpace(x.PowerPlanMode) ? 1 : 0))
                {
                    _pageSubtitle.Text = "Applying changes · " + (++completed) + "/" + selected.Count;
                    await Task.Run(() => ApplyOne(tweak));
                }
                SaveState(); _selectedTweaks.Clear(); applied = true; LogActivity("Selected optimizations applied.");
                }
                catch (Exception ex) { failure = ex; }
                if (failure != null)
                {
                var rollbackFailures = new List<string>();
                foreach (AppliedTweak item in _state.Applied.Where(x => !before.Contains(x.Id)).ToArray().Reverse())
                {
                    try { await RestoreAndSave(item); }
                    catch (Exception restoreError) { rollbackFailures.Add(item.Name + ": " + restoreError.Message); }
                }
                try { SaveState(); } catch (Exception saveError) { rollbackFailures.Add("Could not save the remaining restore history: " + saveError.Message); }
                string rollbackText = rollbackFailures.Count == 0 ? "Changes from this batch were rolled back." : "Some changes remain tracked in Restore because Windows could not roll them back:" + Environment.NewLine + String.Join(Environment.NewLine, rollbackFailures.ToArray());
                MessageBox.Show(this, "The selected changes could not be fully applied. " + rollbackText + Environment.NewLine + Environment.NewLine + failure.Message, "Apply failed", MessageBoxButton.OK, MessageBoxImage.Error);
                }
            }
            finally { EndTweakOperation(); }
            if (applied && !_sessionExitInProgress) ShowPage("Restore");
        }

        private void ApplyOne(TweakDefinition tweak)
        {
            string requirement = TweakRequirement(tweak);
            if (requirement != null) throw new InvalidOperationException(Localization.Translate(requirement));
            List<ValueTarget> targets = tweak.ResolveTargets();
            var record = new AppliedTweak { Id = tweak.Id, Name = tweak.Name, AppliedAt = DateTime.Now, Values = new List<RegValueChange>(), Services = new List<ServiceChange>(), Adapters = new List<AdapterChange>(), AdvancedAdapters = new List<AdvancedAdapterChange>(), PowerSettings = new List<PowerSettingChange>(), BootSettings = new List<BootSettingChange>(), NetshSettings = new List<NetshSettingChange>(), ScheduledTasks = new List<ScheduledTaskChange>() };
            try
            {
                if (!String.IsNullOrWhiteSpace(tweak.AdapterFeature)) record.Adapters = ReadAdapterChanges(tweak.AdapterFeature);
                if (!String.IsNullOrWhiteSpace(tweak.AdapterAdvancedFeature)) record.AdvancedAdapters = ReadAdvancedAdapterChanges(tweak.AdapterAdvancedFeature);
                if (tweak.PowerTargets != null && tweak.PowerTargets.Count > 0) record.PowerSettings = CapturePowerSettings(tweak.PowerTargets);
                if (tweak.BootTargets != null && tweak.BootTargets.Count > 0) record.BootSettings = CaptureBootSettings(tweak.BootTargets);
                if (tweak.NetshTargets != null && tweak.NetshTargets.Count > 0) record.NetshSettings = CaptureNetshSettings(tweak.NetshTargets);
                if (tweak.ScheduledTaskTargets != null && tweak.ScheduledTaskTargets.Count > 0) record.ScheduledTasks = CaptureScheduledTasks(tweak.ScheduledTaskTargets);
                if (!String.IsNullOrWhiteSpace(tweak.PowerPlanMode)) { record.PreviousPowerPlan = ActivePowerPlan(); record.CreatedPowerPlan = Guid.NewGuid().ToString("D"); record.TargetPowerPlan = record.CreatedPowerPlan; }
                if (tweak.DisableHibernation) record.OriginalHibernationEnabled = HibernationEnabled();
                if (tweak.DisableMemoryCompression) { RequireMemoryCompressionHardware(); record.OriginalMemoryCompression = ReadMemoryCompression(); }
                foreach (ValueTarget target in targets)
                {
                    using (RegistryKey root = RegistryKey.OpenBaseKey(target.Hive, RegistryView.Default))
                    using (RegistryKey oldKey = root.OpenSubKey(target.KeyPath, false))
                    {
                        bool exists = oldKey != null && oldKey.GetValueNames().Contains(target.Name, StringComparer.OrdinalIgnoreCase);
                        record.Values.Add(new RegValueChange { Hive = target.Hive.ToString(), KeyPath = target.KeyPath, Name = target.Name, Existed = exists,
                            Kind = exists ? oldKey.GetValueKind(target.Name).ToString() : "DWord", Value = exists ? oldKey.GetValue(target.Name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) : null,
                            TargetKind = target.Kind.ToString(), TargetValue = target.Value });
                    }
                }
                foreach (string serviceName in tweak.ServiceNames)
                {
                    ServiceChange previous = ReadServiceState(serviceName);
                    if (previous == null) continue;
                    record.Services.Add(previous);
                }
                if (record.Values.Count == 0 && record.Services.Count == 0 && record.Adapters.Count == 0 && record.AdvancedAdapters.Count == 0 && record.PowerSettings.Count == 0 && record.BootSettings.Count == 0 && record.NetshSettings.Count == 0 && record.ScheduledTasks.Count == 0 && String.IsNullOrWhiteSpace(record.PreviousPowerPlan) && !record.OriginalHibernationEnabled.HasValue && !record.OriginalMemoryCompression.HasValue) throw new InvalidOperationException("No supported settings were found on this PC.");
                OnStateThread(delegate { _state.Applied.Add(record); SaveState(); });
                foreach (ValueTarget target in targets)
                {
                    using (RegistryKey root = RegistryKey.OpenBaseKey(target.Hive, RegistryView.Default))
                    using (RegistryKey key = root.CreateSubKey(target.KeyPath))
                    { if (key == null) throw new InvalidOperationException("Could not open the " + target.Hive + " registry key " + target.KeyPath); key.SetValue(target.Name, target.Value, target.Kind); }
                }
                foreach (ServiceChange service in record.Services)
                {
                    if (service.WasRunning) SetServiceRunning(service.Name, false);
                    SetServiceStartMode(service.Name, "Disabled", false);
                }
                if (record.Adapters.Count > 0) SetAdapterFeatures(record.Adapters, false);
                if (record.AdvancedAdapters.Count > 0) SetAdvancedAdapterChanges(record.AdvancedAdapters, false);
                if (record.PowerSettings.Count > 0) SetPowerSettings(record.PowerSettings, false);
                if (record.BootSettings.Count > 0) SetBootSettings(record.BootSettings, false);
                if (record.NetshSettings.Count > 0) SetNetshSettings(record.NetshSettings, false);
                if (record.ScheduledTasks.Count > 0) SetScheduledTasks(record.ScheduledTasks, false);
                if (!String.IsNullOrWhiteSpace(record.PreviousPowerPlan)) ApplyUltimatePlan(record);
                if (record.OriginalHibernationEnabled.HasValue) SetHibernation(false);
                if (record.OriginalMemoryCompression.HasValue) SetMemoryCompression(false);
                OnStateThread(SaveState);
            }
            catch { throw; }
        }

        private async Task UndoRecord(AppliedTweak record)
        {
            if (!BeginTweakOperation("Restoring changes…")) return;
            try {
                if (!_state.Applied.Contains(record)) return;
                await RestoreAndSave(record);
                LogActivity("Restored: " + record.Name);
            }
            catch (Exception ex) { MessageBox.Show(this, "Windows could not restore every saved setting. The change remains in Restore so you can retry." + Environment.NewLine + Environment.NewLine + ex.Message, "Restore incomplete", MessageBoxButton.OK, MessageBoxImage.Warning); }
            finally { EndTweakOperation(); }
        }

        private void RestoreRecord(AppliedTweak record)
        {
            if (record.Values != null) foreach (RegValueChange change in record.Values.AsEnumerable().Reverse())
            {
                RegistryHive hive = RegistryHive.CurrentUser;
                if (!String.IsNullOrWhiteSpace(change.Hive) && (!Enum.TryParse<RegistryHive>(change.Hive, true, out hive) || !Enum.IsDefined(typeof(RegistryHive), hive))) throw new InvalidDataException("The saved registry hive is invalid.");
                using (RegistryKey root = RegistryKey.OpenBaseKey(hive, RegistryView.Default))
                using (RegistryKey key = root.CreateSubKey(change.KeyPath))
                {
                    if (key == null) throw new InvalidOperationException("Windows could not open the saved registry key.");
                    if (!change.Existed) key.DeleteValue(change.Name, false);
                    else { RegistryValueKind kind = (RegistryValueKind)Enum.Parse(typeof(RegistryValueKind), change.Kind); key.SetValue(change.Name, RegistryData.ConvertValue(change.Value, kind), kind); }
                }
            }
            if (record.Services != null) foreach (ServiceChange change in record.Services.AsEnumerable().Reverse())
            {
                if (ReadServiceState(change.Name) == null) continue;
                SetServiceStartMode(change.Name, change.StartMode, change.DelayedAutoStart);
                SetServiceRunning(change.Name, change.WasRunning);
            }
            if (record.Adapters != null && record.Adapters.Count > 0) SetAdapterFeatures(record.Adapters, true);
            if (record.AdvancedAdapters != null && record.AdvancedAdapters.Count > 0) SetAdvancedAdapterChanges(record.AdvancedAdapters, true);
            if (record.PowerSettings != null && record.PowerSettings.Count > 0) SetPowerSettings(record.PowerSettings, true);
            if (record.BootSettings != null && record.BootSettings.Count > 0) SetBootSettings(record.BootSettings, true);
            if (record.NetshSettings != null && record.NetshSettings.Count > 0) SetNetshSettings(record.NetshSettings, true);
            if (record.ScheduledTasks != null && record.ScheduledTasks.Count > 0) SetScheduledTasks(record.ScheduledTasks, true);
            if (record.OriginalHibernationEnabled.HasValue) SetHibernation(record.OriginalHibernationEnabled.Value);
            if (record.OriginalMemoryCompression.HasValue) SetMemoryCompression(record.OriginalMemoryCompression.Value);
            if (!String.IsNullOrWhiteSpace(record.PreviousPowerPlan))
            {
                RequirePowerCfg("/setactive " + new Guid(record.PreviousPowerPlan).ToString("D"));
                if (!String.IsNullOrWhiteSpace(record.CreatedPowerPlan))
                {
                    int exit; string plans = RunPowerCfg("/list", out exit);
                    if (exit != 0) throw new InvalidOperationException("Windows could not list power plans during restore. " + plans.Trim());
                    string created = new Guid(record.CreatedPowerPlan).ToString("D");
                    if (plans.IndexOf(created, StringComparison.OrdinalIgnoreCase) >= 0) RequirePowerCfg("/delete " + created);
                }
            }
        }

        private static string AdapterFeatureClass(string feature)
        {
            if (String.Equals(feature, "rsc", StringComparison.OrdinalIgnoreCase)) return "MSFT_NetAdapterRscSettingData";
            if (String.Equals(feature, "lso", StringComparison.OrdinalIgnoreCase)) return "MSFT_NetAdapterLsoSettingData";
            if (String.Equals(feature, "rss", StringComparison.OrdinalIgnoreCase)) return "MSFT_NetAdapterRssSettingData";
            if (String.Equals(feature, "power", StringComparison.OrdinalIgnoreCase)) return "MSFT_NetAdapterPowerManagementSettingData";
            if (String.Equals(feature, "dns", StringComparison.OrdinalIgnoreCase)) return "Win32_NetworkAdapterConfiguration";
            throw new InvalidOperationException("The saved adapter feature is unsupported.");
        }

        private static HashSet<string> ActivePhysicalAdapterNames()
        {
            return new HashSet<string>(NetworkInterface.GetAllNetworkInterfaces().Where(x => x.OperationalStatus == OperationalStatus.Up && (x.NetworkInterfaceType == NetworkInterfaceType.Ethernet || x.NetworkInterfaceType == NetworkInterfaceType.Wireless80211)).Select(x => x.Name), StringComparer.OrdinalIgnoreCase);
        }

        private static HashSet<string> ActiveEthernetAdapterNames()
        {
            return new HashSet<string>(NetworkInterface.GetAllNetworkInterfaces().Where(x => x.OperationalStatus == OperationalStatus.Up && x.NetworkInterfaceType == NetworkInterfaceType.Ethernet).Select(x => x.Name), StringComparer.OrdinalIgnoreCase);
        }

        private static string[] WmiStringArray(object value)
        {
            var strings = value as string[]; if (strings != null) return strings.ToArray();
            var items = value as IEnumerable; if (items == null || value is string) return new string[0];
            return items.Cast<object>().Where(x => x != null).Select(Convert.ToString).ToArray();
        }

        private static string AdvancedAdapterPattern(string feature)
        {
            if (String.Equals(feature, "eee", StringComparison.OrdinalIgnoreCase)) return @"Energy.?Efficient|Green Ethernet|Power Saving Mode";
            if (String.Equals(feature, "flow", StringComparison.OrdinalIgnoreCase)) return @"^Flow Control$";
            if (String.Equals(feature, "interrupt", StringComparison.OrdinalIgnoreCase)) return @"Interrupt Moderation";
            throw new InvalidOperationException("The saved advanced adapter feature is unsupported.");
        }

        private static List<AdvancedAdapterChange> ReadAdvancedAdapterChanges(string feature)
        {
            var changes = new List<AdvancedAdapterChange>(); HashSet<string> active = ActiveEthernetAdapterNames(); string pattern = AdvancedAdapterPattern(feature);
            using (var search = new ManagementObjectSearcher(@"root\StandardCimv2", "SELECT Name,DisplayName,RegistryKeyword,RegistryDataType,RegistryValue,ValidDisplayValues,ValidRegistryValues FROM MSFT_NetAdapterAdvancedPropertySettingData"))
            using (ManagementObjectCollection rows = search.Get()) foreach (ManagementObject row in rows) using (row)
            {
                string adapter = Convert.ToString(row["Name"]); string display = Convert.ToString(row["DisplayName"]); string keyword = Convert.ToString(row["RegistryKeyword"]);
                if (String.IsNullOrWhiteSpace(adapter) || !active.Contains(adapter) || String.IsNullOrWhiteSpace(display) || !Regex.IsMatch(display, pattern, RegexOptions.IgnoreCase) || String.IsNullOrWhiteSpace(keyword)) continue;
                string[] labels = WmiStringArray(row["ValidDisplayValues"]); string[] values = WmiStringArray(row["ValidRegistryValues"]); string[] original = WmiStringArray(row["RegistryValue"]);
                int disabledIndex = Array.FindIndex(labels, x => String.Equals(x == null ? "" : x.Trim(), "Disabled", StringComparison.OrdinalIgnoreCase));
                if (disabledIndex < 0 || disabledIndex >= values.Length || original.Length == 0) continue;
                changes.Add(new AdvancedAdapterChange { AdapterName = adapter, DisplayName = display, RegistryKeyword = keyword, RegistryDataType = Convert.ToString(row["RegistryDataType"]), OriginalRegistryValue = original, TargetRegistryValue = new string[] { values[disabledIndex] } });
            }
            return changes;
        }

        private static void SetAdvancedAdapterChanges(List<AdvancedAdapterChange> changes, bool restore)
        {
            foreach (AdvancedAdapterChange change in changes)
            {
                AdvancedAdapterChange resolved = change;
                if (change.LegacyDisplayValue != null) {
                    if (!restore) throw new InvalidOperationException("A legacy adapter record can only be restored.");
                    resolved = ResolveLegacyAdvancedAdapter(change);
                }
                var scope = new ManagementScope(@"\\.\root\StandardCimv2");
                using (var adapterClass = new ManagementClass(scope, new ManagementPath("MSFT_NetAdapterAdvancedPropertySettingData"), null))
                using (ManagementBaseObject input = adapterClass.GetMethodParameters("SetByNameRegKeyword"))
                {
                    input["Name"] = new string[] { resolved.AdapterName }; input["RegistryKeyword"] = resolved.RegistryKeyword;
                    input["RegistryValue"] = restore ? resolved.OriginalRegistryValue : resolved.TargetRegistryValue;
                    input["RegistryDataType"] = resolved.RegistryDataType;
                    using (ManagementBaseObject result = adapterClass.InvokeMethod("SetByNameRegKeyword", input, null))
                    {
                        uint code = result == null ? UInt32.MaxValue : Convert.ToUInt32(result["ReturnValue"]);
                        if (code != 0) throw new InvalidOperationException("Windows could not update '" + change.DisplayName + "' on " + change.AdapterName + " (WMI result " + code + ").");
                    }
                }
            }
        }

        private static AdvancedAdapterChange ResolveLegacyAdvancedAdapter(AdvancedAdapterChange change)
        {
            var matches = new List<AdvancedAdapterChange>();
            using (var search = new ManagementObjectSearcher(@"root\StandardCimv2", "SELECT Name,DisplayName,RegistryKeyword,RegistryDataType,ValidDisplayValues,ValidRegistryValues FROM MSFT_NetAdapterAdvancedPropertySettingData"))
            using (ManagementObjectCollection rows = search.Get()) foreach (ManagementObject row in rows) using (row) {
                if (!String.Equals(Convert.ToString(row["Name"]), change.AdapterName, StringComparison.OrdinalIgnoreCase) || !String.Equals(Convert.ToString(row["DisplayName"]), change.DisplayName, StringComparison.OrdinalIgnoreCase)) continue;
                string keyword = Convert.ToString(row["RegistryKeyword"]), dataType = Convert.ToString(row["RegistryDataType"]);
                string[] labels = WmiStringArray(row["ValidDisplayValues"]), values = WmiStringArray(row["ValidRegistryValues"]);
                if (String.IsNullOrWhiteSpace(keyword) || String.IsNullOrWhiteSpace(dataType) || labels.Length != values.Length) continue;
                var indices = Enumerable.Range(0, labels.Length).Where(i => String.Equals(labels[i], change.LegacyDisplayValue, StringComparison.OrdinalIgnoreCase)).ToArray();
                if (indices.Length != 1 || values[indices[0]] == null) continue;
                matches.Add(new AdvancedAdapterChange { AdapterName = change.AdapterName, DisplayName = change.DisplayName, RegistryKeyword = keyword, RegistryDataType = dataType, OriginalRegistryValue = new[] { values[indices[0]] } });
            }
            if (matches.Count != 1) throw new InvalidOperationException("Windows could not uniquely match the saved adapter setting '" + change.DisplayName + "' on " + change.AdapterName + ". Reconnect the original adapter and check its driver before retrying.");
            return matches[0];
        }

        private static bool VerifyAdvancedAdapterChanges(List<AdvancedAdapterChange> changes)
        {
            if (changes == null || changes.Count == 0) return true;
            using (var search = new ManagementObjectSearcher(@"root\StandardCimv2", "SELECT Name,RegistryKeyword,RegistryValue FROM MSFT_NetAdapterAdvancedPropertySettingData"))
            using (ManagementObjectCollection rows = search.Get())
            {
                var values = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
                foreach (ManagementObject row in rows) using (row)
                {
                    string name = Convert.ToString(row["Name"]); string keyword = Convert.ToString(row["RegistryKeyword"]);
                    if (!String.IsNullOrWhiteSpace(name) && !String.IsNullOrWhiteSpace(keyword)) values[name + "\n" + keyword] = WmiStringArray(row["RegistryValue"]);
                }
                foreach (AdvancedAdapterChange expected in changes)
                {
                    string[] actual;
                    if (!values.TryGetValue(expected.AdapterName + "\n" + expected.RegistryKeyword, out actual) || actual == null || expected.TargetRegistryValue == null || !actual.SequenceEqual(expected.TargetRegistryValue, StringComparer.OrdinalIgnoreCase)) return false;
                }
            }
            return true;
        }

        private static List<AdapterChange> ReadAdapterChanges(string feature)
        {
            var changes = new List<AdapterChange>(); var active = ActivePhysicalAdapterNames();
            if (String.Equals(feature, "dns", StringComparison.OrdinalIgnoreCase))
            {
                var descriptions = new HashSet<string>(NetworkInterface.GetAllNetworkInterfaces().Where(x => x.OperationalStatus == OperationalStatus.Up && (x.NetworkInterfaceType == NetworkInterfaceType.Ethernet || x.NetworkInterfaceType == NetworkInterfaceType.Wireless80211)).Select(x => x.Description), StringComparer.OrdinalIgnoreCase);
                using (var search = new ManagementObjectSearcher(@"root\CIMV2", "SELECT Description,DNSServerSearchOrder FROM Win32_NetworkAdapterConfiguration WHERE IPEnabled=TRUE"))
                using (ManagementObjectCollection rows = search.Get()) foreach (ManagementObject row in rows) using (row)
                {
                    string name = Convert.ToString(row["Description"]); if (String.IsNullOrWhiteSpace(name) || !descriptions.Contains(name)) continue;
                    changes.Add(new AdapterChange { Name = name, Feature = feature, DnsServers = row["DNSServerSearchOrder"] as string[], ExpectedDnsServers = new string[] { "1.1.1.1", "1.0.0.1" } });
                }
                return changes;
            }
            if (String.Equals(feature, "rss", StringComparison.OrdinalIgnoreCase))
            {
                using (var search = new ManagementObjectSearcher(@"root\StandardCimv2", "SELECT Name,Enabled FROM MSFT_NetAdapterRssSettingData"))
                using (ManagementObjectCollection rows = search.Get()) foreach (ManagementObject row in rows) using (row)
                {
                    string name = Convert.ToString(row["Name"]); if (String.IsNullOrWhiteSpace(name) || !active.Contains(name)) continue;
                    changes.Add(new AdapterChange { Name = name, Feature = feature, RssEnabled = Convert.ToBoolean(row["Enabled"]) });
                }
                return changes;
            }
            string select = String.Equals(feature, "power", StringComparison.OrdinalIgnoreCase) ? "SELECT Name," + String.Join(",", AdapterPowerCapabilities) + " FROM " + AdapterFeatureClass(feature) : "SELECT Name,IPv4Enabled,IPv6Enabled FROM " + AdapterFeatureClass(feature);
            using (var search = new ManagementObjectSearcher(@"root\StandardCimv2", select))
            using (ManagementObjectCollection rows = search.Get())
            {
                foreach (ManagementObject row in rows) using (row)
                {
                    string name = Convert.ToString(row["Name"]); if (String.IsNullOrWhiteSpace(name) || !active.Contains(name)) continue;
                    if (String.Equals(feature, "power", StringComparison.OrdinalIgnoreCase))
                    {
                        var states = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
                        foreach (string property in AdapterPowerCapabilities) try { states[property] = Convert.ToUInt32(row[property]) == 2; } catch { states[property] = false; }
                        if (states.Values.Any(x => x)) changes.Add(new AdapterChange { Name = name, Feature = feature, PowerStates = states });
                    }
                    else changes.Add(new AdapterChange { Name = name, Feature = feature, IPv4Enabled = Convert.ToBoolean(row["IPv4Enabled"]), IPv6Enabled = Convert.ToBoolean(row["IPv6Enabled"]) });
                }
            }
            return changes;
        }

        private static void SetAdapterFeatures(List<AdapterChange> changes, bool restore)
        {
            foreach (AdapterChange change in changes)
            {
                if (String.Equals(change.Feature, "dns", StringComparison.OrdinalIgnoreCase))
                {
                    bool foundDnsAdapter = false;
                    using (var search = new ManagementObjectSearcher(@"root\CIMV2", "SELECT Description FROM Win32_NetworkAdapterConfiguration WHERE IPEnabled=TRUE"))
                    using (ManagementObjectCollection rows = search.Get()) foreach (ManagementObject row in rows) using (row)
                    {
                        if (!String.Equals(Convert.ToString(row["Description"]), change.Name, StringComparison.OrdinalIgnoreCase)) continue;
                        foundDnsAdapter = true;
                        using (ManagementBaseObject input = row.GetMethodParameters("SetDNSServerSearchOrder"))
                        {
                            input["DNSServerSearchOrder"] = restore ? change.DnsServers : change.ExpectedDnsServers;
                            using (ManagementBaseObject result = row.InvokeMethod("SetDNSServerSearchOrder", input, null))
                            {
                                uint code = result == null ? UInt32.MaxValue : Convert.ToUInt32(result["ReturnValue"]);
                                if (code != 0 && code != 1) throw new InvalidOperationException("Windows could not set DNS on " + change.Name + " (WMI result " + code + ").");
                            }
                        }
                        break;
                    }
                    if (!foundDnsAdapter) throw new InvalidOperationException("Network adapter '" + change.Name + "' is no longer available. Reconnect it and retry the change.");
                    continue;
                }
                if (String.Equals(change.Feature, "rss", StringComparison.OrdinalIgnoreCase))
                {
                    bool foundRss = false;
                    using (var search = new ManagementObjectSearcher(@"root\StandardCimv2", "SELECT Name,Enabled FROM " + AdapterFeatureClass(change.Feature)))
                    using (ManagementObjectCollection rows = search.Get()) foreach (ManagementObject row in rows) using (row)
                    {
                        if (!String.Equals(Convert.ToString(row["Name"]), change.Name, StringComparison.OrdinalIgnoreCase)) continue;
                        foundRss = true; bool desired = restore ? change.RssEnabled : true; bool current = Convert.ToBoolean(row["Enabled"]);
                        if (current != desired)
                        {
                            string methodName = desired ? "Enable" : "Disable";
                            using (ManagementBaseObject input = row.GetMethodParameters(methodName))
                            using (ManagementBaseObject result = row.InvokeMethod(methodName, input, null))
                            { uint code = result == null ? UInt32.MaxValue : Convert.ToUInt32(result["ReturnValue"]); if (code != 0 && code != 1) throw new InvalidOperationException("Windows could not " + methodName.ToLowerInvariant() + " RSS on " + change.Name + " (WMI result " + code + ")."); }
                        }
                        break;
                    }
                    if (!foundRss) throw new InvalidOperationException("Network adapter '" + change.Name + "' is no longer available. Reconnect it and retry the change.");
                    continue;
                }
                if (String.Equals(change.Feature, "power", StringComparison.OrdinalIgnoreCase))
                {
                    bool foundPowerAdapter = false;
                    using (var search = new ManagementObjectSearcher(@"root\StandardCimv2", "SELECT Name FROM " + AdapterFeatureClass(change.Feature)))
                    using (ManagementObjectCollection rows = search.Get())
                    {
                        foreach (ManagementObject row in rows) using (row)
                        {
                            if (!String.Equals(Convert.ToString(row["Name"]), change.Name, StringComparison.OrdinalIgnoreCase)) continue;
                            foundPowerAdapter = true; string methodName = restore ? "Enable" : "Disable";
                            using (ManagementBaseObject input = row.GetMethodParameters(methodName))
                            {
                                foreach (string property in AdapterPowerCapabilities) input[property] = change.PowerStates != null && change.PowerStates.ContainsKey(property) && change.PowerStates[property];
                                using (ManagementBaseObject result = row.InvokeMethod(methodName, input, null))
                                {
                                    uint code = result == null ? UInt32.MaxValue : Convert.ToUInt32(result["ReturnValue"]);
                                    if (code != 0 && code != 1) throw new InvalidOperationException("Windows could not " + methodName.ToLowerInvariant() + " adapter power features on " + change.Name + " (WMI result " + code + ").");
                                }
                            }
                            break;
                        }
                    }
                    if (!foundPowerAdapter) throw new InvalidOperationException("Network adapter '" + change.Name + "' is no longer available. Reconnect it and retry the change.");
                    continue;
                }
                bool ipv4 = restore ? change.IPv4Enabled : true; bool ipv6 = restore ? change.IPv6Enabled : true;
                if (restore && !ipv4 && !ipv6) continue;
                string method = restore ? "Enable" : "Disable"; bool found = false;
                using (var search = new ManagementObjectSearcher(@"root\StandardCimv2", "SELECT Name FROM " + AdapterFeatureClass(change.Feature)))
                using (ManagementObjectCollection rows = search.Get())
                {
                    foreach (ManagementObject row in rows) using (row)
                    {
                        if (!String.Equals(Convert.ToString(row["Name"]), change.Name, StringComparison.OrdinalIgnoreCase)) continue;
                        found = true;
                        using (ManagementBaseObject input = row.GetMethodParameters(method))
                        {
                            input["IPv4"] = ipv4; input["IPv6"] = ipv6;
                            using (ManagementBaseObject result = row.InvokeMethod(method, input, null))
                            {
                                uint code = result == null ? UInt32.MaxValue : Convert.ToUInt32(result["ReturnValue"]);
                                if (code != 0 && code != 1) throw new InvalidOperationException("Windows could not " + method.ToLowerInvariant() + " " + change.Feature.ToUpperInvariant() + " on " + change.Name + " (WMI result " + code + ").");
                            }
                        }
                        break;
                    }
                }
                if (!found) throw new InvalidOperationException("Network adapter '" + change.Name + "' is no longer available. Reconnect it and retry the change.");
            }
        }

        private static bool VerifyAdapterFeatures(List<AdapterChange> changes)
        {
            if (changes == null || changes.Count == 0) return true;
            foreach (AdapterChange expected in changes)
            {
                bool found = false;
                if (String.Equals(expected.Feature, "dns", StringComparison.OrdinalIgnoreCase))
                {
                    using (var search = new ManagementObjectSearcher(@"root\CIMV2", "SELECT Description,DNSServerSearchOrder FROM Win32_NetworkAdapterConfiguration WHERE IPEnabled=TRUE"))
                    using (ManagementObjectCollection rows = search.Get()) foreach (ManagementObject row in rows) using (row)
                    {
                        if (!String.Equals(Convert.ToString(row["Description"]), expected.Name, StringComparison.OrdinalIgnoreCase)) continue;
                        found = true; var actual = row["DNSServerSearchOrder"] as string[]; if (actual == null || expected.ExpectedDnsServers == null || !actual.SequenceEqual(expected.ExpectedDnsServers, StringComparer.OrdinalIgnoreCase)) return false; break;
                    }
                    if (!found) return false;
                    continue;
                }
                if (String.Equals(expected.Feature, "rss", StringComparison.OrdinalIgnoreCase))
                {
                    using (var search = new ManagementObjectSearcher(@"root\StandardCimv2", "SELECT Name,Enabled FROM " + AdapterFeatureClass(expected.Feature)))
                    using (ManagementObjectCollection rows = search.Get()) foreach (ManagementObject row in rows) using (row)
                    {
                        if (!String.Equals(Convert.ToString(row["Name"]), expected.Name, StringComparison.OrdinalIgnoreCase)) continue;
                        found = true; if (!Convert.ToBoolean(row["Enabled"])) return false; break;
                    }
                    if (!found) return false;
                    continue;
                }
                string select = String.Equals(expected.Feature, "power", StringComparison.OrdinalIgnoreCase) ? "SELECT Name," + String.Join(",", AdapterPowerCapabilities) + " FROM " + AdapterFeatureClass(expected.Feature) : "SELECT Name,IPv4Enabled,IPv6Enabled FROM " + AdapterFeatureClass(expected.Feature);
                using (var search = new ManagementObjectSearcher(@"root\StandardCimv2", select))
                using (ManagementObjectCollection rows = search.Get()) foreach (ManagementObject row in rows) using (row)
                {
                    if (!String.Equals(Convert.ToString(row["Name"]), expected.Name, StringComparison.OrdinalIgnoreCase)) continue;
                    found = true;
                    if (String.Equals(expected.Feature, "power", StringComparison.OrdinalIgnoreCase))
                    { foreach (string property in AdapterPowerCapabilities) if (expected.PowerStates != null && expected.PowerStates.ContainsKey(property) && expected.PowerStates[property] && Convert.ToUInt32(row[property]) == 2) return false; }
                    else if (Convert.ToBoolean(row["IPv4Enabled"]) || Convert.ToBoolean(row["IPv6Enabled"])) return false;
                    break;
                }
                if (!found) return false;
            }
            return true;
        }

        private static ServiceChange ReadServiceState(string name)
        {
            if (!Regex.IsMatch(name ?? "", "^[A-Za-z0-9_.-]{1,256}$")) throw new InvalidOperationException("The saved service name is invalid.");
            string escaped = name.Replace("\\", "\\\\").Replace("'", "\\'");
            using (var search = new ManagementObjectSearcher("SELECT StartMode,State FROM Win32_Service WHERE Name='" + escaped + "'"))
            using (ManagementObjectCollection rows = search.Get())
            {
                ManagementObject item = rows.Cast<ManagementObject>().FirstOrDefault();
                if (item == null) return null;
                using (item)
                {
                    bool delayed = false;
                    try { using (RegistryKey key = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\" + name, false)) delayed = key != null && Convert.ToInt32(key.GetValue("DelayedAutoStart", 0)) != 0; } catch { }
                    return new ServiceChange { Name = name, StartMode = Convert.ToString(item["StartMode"]), DelayedAutoStart = delayed, WasRunning = String.Equals(Convert.ToString(item["State"]), "Running", StringComparison.OrdinalIgnoreCase) };
                }
            }
        }

        private static void SetServiceStartMode(string name, string mode, bool delayed)
        {
            if (!Regex.IsMatch(name ?? "", "^[A-Za-z0-9_.-]{1,256}$")) throw new InvalidOperationException("The saved service name is invalid.");
            string start = mode;
            if (String.Equals(mode, "Auto", StringComparison.OrdinalIgnoreCase)) start = delayed ? "delayed-auto" : "auto";
            else if (String.Equals(mode, "Manual", StringComparison.OrdinalIgnoreCase)) start = "demand";
            else if (String.Equals(mode, "Disabled", StringComparison.OrdinalIgnoreCase)) start = "disabled";
            else if (!String.Equals(mode, "Boot", StringComparison.OrdinalIgnoreCase) && !String.Equals(mode, "System", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Windows returned an unsupported startup mode for service " + name + ".");
            RunServiceControl("config " + name + " start= " + start, "Could not restore or update the startup mode for service " + name + ".");
        }

        private static void SetServiceRunning(string name, bool running)
        {
            if (!Regex.IsMatch(name ?? "", "^[A-Za-z0-9_.-]{1,256}$")) throw new InvalidOperationException("The saved service name is invalid.");
            using (var service = new ServiceController(name))
            {
                service.Refresh();
                if (running && service.Status != ServiceControllerStatus.Running)
                { service.Start(); service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(12)); }
                else if (!running && service.Status != ServiceControllerStatus.Stopped)
                { service.Stop(); service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(12)); }
            }
        }

        private static void RunServiceControl(string arguments, string errorMessage)
        {
            int exitCode; string output = RunCapturedSystemTool("sc.exe", arguments, 10000, out exitCode);
            if (exitCode != 0) throw new InvalidOperationException(errorMessage + Environment.NewLine + output.Trim());
        }

        private async Task UndoAll()
        {
            if (_tweakOperationBusy) return;
            if (_state.Applied.Count == 0) return;
            if (MessageBox.Show(this, "Undo all " + _state.Applied.Count + " tracked changes?", "Undo all", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
            if (!BeginTweakOperation("Restoring changes…")) return;
            var failures = new List<string>();
            try
            {
                int completed = 0; int total = _state.Applied.Count;
                foreach (AppliedTweak item in _state.Applied.ToArray().Reverse())
                {
                    try
                    {
                        _pageSubtitle.Text = "Restoring changes · " + (++completed) + "/" + total;
                        await RestoreAndSave(item);
                    }
                    catch (Exception ex) { failures.Add(item.Name + ": " + ex.Message); }
                }
                try { SaveState(); } catch (Exception ex) { failures.Add("Could not save restore history: " + ex.Message); }
                if (failures.Count > 0) MessageBox.Show(this, "Some changes could not be restored and remain tracked:" + Environment.NewLine + Environment.NewLine + String.Join(Environment.NewLine, failures.ToArray()), "Restore incomplete", MessageBoxButton.OK, MessageBoxImage.Warning);
                else LogActivity("All tracked changes restored.");
            }
            finally { EndTweakOperation(); }
        }

        private void RefreshAll()
        {
            _checks.Clear();
            if (_loadedPages.Contains("Optimize")) _pages["Optimize"].Child = PageScroll(BuildOptimize());
            if (_loadedPages.Contains("Restore")) _pages["Restore"].Child = PageScroll(BuildRestore());
            if (_loadedPages.Contains("Dashboard")) _pages["Dashboard"].Child = PageScroll(BuildDashboard());
        }

        private void UpdateApplyButton()
        {
            if (_applyButton != null) { _applyButton.Content = _selectedTweaks.Count == 0 ? "Apply selected" : "Apply selected (" + _selectedTweaks.Count + ")"; _applyButton.IsEnabled = !_tweakOperationBusy && !_existingTweakScanBusy && _selectedTweaks.Count > 0; }
            if (_savePresetButton != null) _savePresetButton.IsEnabled = _selectedTweaks.Count > 0 || (_editingPreset != null && _editingPreset.Ids.Any(id => _state.Applied.Any(a => a.Id == id) || !CanSelectTweak(id)));
        }

        private void RefreshRestore()
        {
            _restoreList.Children.Clear();
            if (_state.Applied.Count == 0)
            {
                var empty = Card(); var stack = new StackPanel(); stack.Children.Add(Text("Nothing to restore yet", 14, Brushes.White, true)); stack.Children.Add(Text("Applied changes will appear here with an undo action.", 11, Brush(MutedColor), false, 0, 4)); empty.Child = stack; _restoreList.Children.Add(empty); return;
            }
            foreach (AppliedTweak item in _state.Applied.ToArray().Reverse())
            {
                var card = Card(); card.Padding = new Thickness(15, 12, 15, 12); card.Margin = new Thickness(0, 4, 0, 4);
                var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var stack = new StackPanel(); stack.Children.Add(Text(item.Name, 12, Brushes.White, true)); stack.Children.Add(Text("Applied " + item.AppliedAt.ToString("g"), 10, Brush(MutedColor), false, 0, 3)); grid.Children.Add(stack);
                var undo = ActionButton("Undo", false); undo.VerticalAlignment = VerticalAlignment.Center; undo.Click += async delegate { try { await UndoRecord(item); } catch (Exception ex) { MessageBox.Show(this, ex.Message, "Undo failed", MessageBoxButton.OK, MessageBoxImage.Error); } };
                Grid.SetColumn(undo, 1); grid.Children.Add(undo); card.Child = grid; _restoreList.Children.Add(card);
            }
        }

        private void ShowPage(string name)
        {
            if (_tweakOperationBusy) return;
            if (!_loadedPages.Contains(name))
            {
                Func<UIElement> factory;
                if (_pageFactories.TryGetValue(name, out factory))
                {
                    _pages[name].Child = PageScroll(factory());
                    _loadedPages.Add(name);
                }
            }
            if (name == "Game Session") RefreshSessionProcesses();
            foreach (var page in _pages) page.Value.Visibility = page.Key == name ? Visibility.Visible : Visibility.Collapsed;
            foreach (var nav in _navButtons)
            {
                bool selected = nav.Key == name;
                nav.Value.Background = selected ? Brush(Color.FromRgb(17, 43, 65)) : Brushes.Transparent;
                nav.Value.BorderBrush = selected ? Brush(Color.FromRgb(27, 69, 98)) : Brushes.Transparent;
                nav.Value.Foreground = selected ? Brushes.White : Brush(MutedColor);
                Border indicator; if (_navIndicators.TryGetValue(nav.Key, out indicator)) indicator.Background = selected ? Brush(AccentColor) : Brushes.Transparent;
                System.Windows.Shapes.Path icon; if (_navIcons.TryGetValue(nav.Key, out icon)) { icon.Fill = selected ? Brush(AccentColor) : Brush(MutedColor); icon.Data = SidebarIcon(nav.Key, selected); }
            }
            _pageTitle.Text = name == "Dashboard" ? "Welcome to SharkOptimizer" : PageLabel(name);
            _applyButton.Visibility = name == "Optimize" ? Visibility.Visible : Visibility.Collapsed;
            _pageSubtitle.Text = name == "Dashboard" ? "Your PC, your settings, all in one place." :
                name == "Optimize" ? "Review changes before they touch your PC." :
                name == "Games" ? "Game detection, profiles, and settings tips." :
                name == "Game Session" ? "Launch a game and restore selected settings when you finish." :
                name == "Windows" ? "Useful Windows controls and apps you can close safely." :
                name == "Boost-Up" ? "Clear old temporary files and review the space first." :
                name == "Network" ? "Ping, DNS, and route checks for your connection." :
                name == "Lab" ? "Verify settings, inspect your PC, and move profiles." :
                name == "Restore" ? "A clear history of changes you can roll back." : name == "Guide" ? "A quick tour of your Windows workspace." : "App preferences and local data.";
            Localization.Apply((DependencyObject)Content);
            Dispatcher.BeginInvoke(new Action(RefreshMonitoringVisibility));
        }

        private static StackPanel ScrollColumn()
        { var panel = new StackPanel { Margin = new Thickness(6, 4, 6, 12) }; return panel; }

        private static Border Card()
        { return new Border { Background = Brush(SurfaceColor), BorderBrush = Brush(BorderColor), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(14), Padding = new Thickness(18), Margin = new Thickness(0, 0, 0, 14) }; }

        private static TextBlock Text(string value, double size, Brush color, bool bold, double left = 0, double top = 0)
        { var text = new TextBlock { Text = value, FontSize = size, Foreground = color, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal, Margin = new Thickness(left, top, 0, 0), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center }; Localization.Apply(text); return text; }

        private static Button ActionButton(string label, bool primary)
        {
            var button = new Button { Content = label, Padding = new Thickness(13, 8, 13, 8), Margin = new Thickness(5, 0, 0, 0), FontSize = 11.5, HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center, Foreground = primary ? Brush(BackgroundColor) : Brushes.White,
                Background = primary ? Brush(AccentColor) : Brush(SurfaceRaised), BorderBrush = primary ? Brush(AccentColor) : Brush(BorderColor), BorderThickness = new Thickness(1), FontWeight = FontWeights.SemiBold, Cursor = Cursors.Hand };
            var border = new FrameworkElementFactory(typeof(Border)); border.SetValue(Border.CornerRadiusProperty, new CornerRadius(9)); border.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Button.BackgroundProperty)); border.SetValue(Border.BorderBrushProperty, new TemplateBindingExtension(Button.BorderBrushProperty)); border.SetValue(Border.BorderThicknessProperty, new TemplateBindingExtension(Button.BorderThicknessProperty));
            var presenter = new FrameworkElementFactory(typeof(ContentPresenter)); presenter.SetValue(ContentPresenter.HorizontalAlignmentProperty, new TemplateBindingExtension(Button.HorizontalContentAlignmentProperty)); presenter.SetValue(ContentPresenter.VerticalAlignmentProperty, new TemplateBindingExtension(Button.VerticalContentAlignmentProperty)); presenter.SetValue(ContentPresenter.MarginProperty, new TemplateBindingExtension(Button.PaddingProperty)); border.AppendChild(presenter);
            var template = new ControlTemplate(typeof(Button)) { VisualTree = border };
            var hover = new Trigger { Property = Button.IsMouseOverProperty, Value = true }; hover.Setters.Add(new Setter(Button.BorderBrushProperty, LiveAccentBrush)); template.Triggers.Add(hover);
            var disabled = new Trigger { Property = Button.IsEnabledProperty, Value = false }; disabled.Setters.Add(new Setter(Button.OpacityProperty, .45)); template.Triggers.Add(disabled);
            var pressed = new Trigger { Property = Button.IsPressedProperty, Value = true }; pressed.Setters.Add(new Setter(Button.OpacityProperty, .8)); template.Triggers.Add(pressed);
            button.Template = template; Localization.Apply(button); return button;
        }

        private static Button SmallButton(string text)
        { var button = ActionButton(text, false); button.Width = 34; button.Height = 32; button.Padding = new Thickness(0); button.FontSize = 16; return button; }

        private static Brush Brush(Color color)
        {
            if (color == AccentColor) return LiveAccentBrush;
            if (color == Color.FromRgb(17, 43, 65)) return LiveNavFill;
            if (color == Color.FromRgb(27, 69, 98)) return LiveNavBorder;
            var brush = new SolidColorBrush(color); brush.Freeze(); return brush;
        }
    }
}
