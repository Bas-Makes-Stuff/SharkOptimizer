using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private UIElement BuildFocusedGameBoost()
        {
            var panel = ScrollColumn();
            var pickerCard = Card(); var pickerBody = new StackPanel();
            pickerBody.Children.Add(Text("Choose your game", 15, Brushes.White, true));
            _sessionGamePicker = new ComboBox { Height = 38, Margin = new Thickness(0, 10, 0, 0), Padding = new Thickness(8, 6, 8, 6) };
            pickerBody.Children.Add(_sessionGamePicker); pickerCard.Child = pickerBody; panel.Children.Add(pickerCard); RefreshSessionGames();

            var session = new StackPanel(); var profile = new StackPanel(); var apps = new StackPanel(); var history = new StackPanel();
            var sessionCard = Card(); var sessionBody = new StackPanel();
            _sessionStatus = Text("No game session is running.", 16, Brushes.White, true); sessionBody.Children.Add(_sessionStatus);
            AddAutomaticSessionControls(sessionBody);
            sessionBody.Children.Remove(_automaticCloseAppsCheck);
            var actions = new WrapPanel { Margin = new Thickness(-4, 16, 0, 0) };
            _sessionStartButton = ActionButton("Start game session", true); _sessionStartButton.Click += delegate { StartGameSession(); };
            _sessionEndButton = ActionButton("End session", false); _sessionEndButton.Click += async delegate { await EndGameSession(true); };
            var save = ActionButton("Save profile", false); save.Click += delegate { SaveSessionProfile(); };
            actions.Children.Add(_sessionStartButton); actions.Children.Add(_sessionEndButton); actions.Children.Add(save);
            sessionBody.Children.Add(actions); sessionCard.Child = sessionBody; session.Children.Add(sessionCard);
            session.Children.Add(Text("Temporary session settings are restored when your game closes.", 10, Brush(MutedColor), false, 0, 4));

            var profileCard = Card(); var profileBody = new StackPanel();
            profileBody.Children.Add(Text("Session preferences", 15, Brushes.White, true));
            _sessionUsePerformancePlan = new CheckBox { Content = "Switch to High performance power plan for this session", Margin = new Thickness(0, 12, 0, 6), ToolTip = "The currently active plan is restored when the session ends." };
            profileBody.Children.Add(_sessionUsePerformancePlan);
            AddSessionProfileControls(profileBody);
            var statusParent = _sessionProfileStatus.Parent as Panel; if (statusParent != null) statusParent.Children.Remove(_sessionProfileStatus); sessionBody.Children.Add(_sessionProfileStatus);
            profileCard.Child = profileBody; profile.Children.Add(profileCard);

            var appCard = Card(); var appBody = new StackPanel();
            var appHeader = new DockPanel(); var refresh = ActionButton("Refresh", false); refresh.Click += delegate { RefreshSessionProcesses(); }; DockPanel.SetDock(refresh, Dock.Right); appHeader.Children.Add(refresh); appHeader.Children.Add(Text("Selected apps", 15, Brushes.White, true)); appBody.Children.Add(appHeader);
            appBody.Children.Add(Text("Games and protected apps stay untouched.", 10, Brush(MutedColor), false, 0, 5));
            appBody.Children.Add(_automaticCloseAppsCheck);
            _sessionProcessList = new StackPanel { Margin = new Thickness(0, 12, 0, 0) }; appBody.Children.Add(_sessionProcessList);
            appCard.Child = appBody; apps.Children.Add(appCard);
            var appSave = ActionButton("Save profile", false); appSave.HorizontalAlignment = HorizontalAlignment.Left; appSave.Click += delegate { SaveSessionProfile(); }; apps.Children.Add(appSave);
            history.Children.Add(BuildSessionReports());

            var tabs = new WrapPanel { Margin = new Thickness(-4, 0, 0, 12) }; var views = new[] { session, profile, apps, history }; var titles = new[] { "Session", "Profile", "Apps", "History" }; var buttons = new Button[views.Length];
            var host = new Grid(); foreach (var view in views) host.Children.Add(view);
            Action<int> select = delegate(int selected) {
                for (int index = 0; index < views.Length; index++) { views[index].Visibility = index == selected ? Visibility.Visible : Visibility.Collapsed; buttons[index].Background = index == selected ? Brush(SurfaceRaised) : Brushes.Transparent; buttons[index].BorderBrush = index == selected ? LiveAccentBrush : Brush(BorderColor); }
            };
            for (int index = 0; index < views.Length; index++) { int tab = index; buttons[index] = ActionButton(titles[index], false); buttons[index].Click += delegate { select(tab); }; tabs.Children.Add(buttons[index]); }
            panel.Children.Add(tabs); panel.Children.Add(host); select(0);
            LoadSessionProfile();
            bool active = _sessionStarting || (_sessionTimer != null && _sessionTimer.IsEnabled);
            SetSessionControlsEnabled(!active); _sessionStartButton.IsEnabled = !active; _sessionEndButton.IsEnabled = active || SessionRecoveryPending;
            if (active) _sessionStatus.Text = _automaticSessionGameId != null ? Localization.Translate("Automatic Game Boost") + " · " + _automaticActiveProbe.Name : Localization.Translate("Session active");
            return panel;
        }
    }
}
