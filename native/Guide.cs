using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private sealed class GuideStep
        {
            public string Title, Body, Route, Action;
            public GuideStep(string title, string body, string route, string action) { Title = title; Body = body; Route = route; Action = action; }
        }
        private static readonly GuideStep[] GuideSteps = {
            new GuideStep("Start with a recovery point", "Create a Windows restore point before changing system settings. Enable System Protection in Windows if it is unavailable.\n\nSharkOptimizer separately records previous values for the reversible changes you apply. Cleanup and optional-app removal can delete data and are not undone by the Restore page.", null, "Create a restore point"),
            new GuideStep("Your Windows workspace", "The Dashboard brings your tools together: Tune Windows, Game Library, Cleanup, and Network. Its counts show available options and changes tracked for undo.\n\nUse the sidebar to move between pages. Appearance and interface size are in Settings.", "Dashboard", "Open Dashboard"),
            new GuideStep("Choose a few changes at a time", "On Optimize, search or choose a category. Expand Details & cautions before selecting an unfamiliar option. Apply selected stays in the window header while you scroll.\n\nPresets select options for review. Save your own selection or use Manage presets to edit, compare, and share it. Loading a preset never applies its options automatically.", "Optimize", "Open Optimize"),
            new GuideStep("Build your game library", "Scan common game folders or add a game executable. Each profile includes Windows-level recommendations and in-game settings tips.\n\nReview profile options before applying them. SharkOptimizer does not modify game files or inject into games.", "Games", "Open Game Library"),
            new GuideStep("Get ready for a game", "Game Boost can launch a detected game and ask selected app windows to close normally or lower their priority temporarily. Save your choices per game and use the protected-app list to keep important apps untouched.\n\nOriginal app priorities and the optional power-plan switch are restored when the session ends. Use End session to stop manually. Closing SharkOptimizer's window hides it in the tray; Exit in the tray menu ends the app.", "Game Session", "Open Game Boost"),
            new GuideStep("Maintain Windows and clear old files", "Windows Tools includes startup controls, optional-app removal, Windows shortcuts, repair tools, and an app closer. App removal needs a separate confirmation.\n\nCleanup scans first so you can review the folders. Locked files and linked folders are skipped. Emptying the Recycle Bin permanently deletes its contents.", "Windows", "Open Windows Tools"),
            new GuideStep("Measure before you decide", "Network includes live ping, DNS checks, and route diagnostics. A server may block ping; results depend on the target and connection.\n\nSystem Lab captures before/after snapshots and verifies tracked settings. Repeat measurements under similar conditions. Small differences can be normal variation.", "Lab", "Open System Lab"),
            new GuideStep("Keep control of your changes", "Restore shows saved changes and their undo actions. If a game or app behaves differently after a change, undo the recent option and compare again.\n\nSettings includes setup backups, appearance, GitHub updates, scheduled cleanup, and advanced custom registry definitions. Setup backup imports keep Windows undo history separate and do not apply optimization settings.", "Restore", "Open Restore")
        };

        private int _guideIndex;
        private Border _welcomeGuideCard;
        private UIElement BuildGuide()
        {
            if (!_state.GuideSeen) { _state.GuideSeen = true; try { SaveState(); } catch { } }
            if (_welcomeGuideCard != null) _welcomeGuideCard.Visibility = Visibility.Collapsed;
            var panel = ScrollColumn(); var card = Card(); card.Padding = new Thickness(26);
            var body = new StackPanel(); var progress = Text("", 9, Brush(AccentColor), true); body.Children.Add(progress);
            var title = Text("", 25, Brushes.White, true, 0, 12); body.Children.Add(title);
            var content = Text("", 13, Brush(MutedColor), false, 0, 14); content.LineHeight = 25; body.Children.Add(content);
            var action = ActionButton("", true); action.HorizontalAlignment = HorizontalAlignment.Left; action.Margin = new Thickness(0, 20, 0, 0); body.Children.Add(action);
            var navigation = new Grid { Margin = new Thickness(0, 28, 0, 0) }; navigation.ColumnDefinitions.Add(new ColumnDefinition()); navigation.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var previous = ActionButton("← Previous", false); previous.HorizontalAlignment = HorizontalAlignment.Left; previous.Margin = new Thickness(0); navigation.Children.Add(previous);
            var next = ActionButton("Next →", false); Grid.SetColumn(next, 1); navigation.Children.Add(next); body.Children.Add(navigation); card.Child = body; panel.Children.Add(card);
            Action render = delegate { GuideStep step = GuideSteps[_guideIndex]; progress.Text = "QUICK GUIDE · STEP " + (_guideIndex + 1) + " OF " + GuideSteps.Length; title.Text = step.Title; content.Text = step.Body; action.Content = step.Action; previous.IsEnabled = _guideIndex > 0; next.IsEnabled = _guideIndex < GuideSteps.Length - 1; };
            previous.Click += delegate { if (_guideIndex > 0) { _guideIndex--; render(); } }; next.Click += delegate { if (_guideIndex < GuideSteps.Length - 1) { _guideIndex++; render(); } };
            action.Click += async delegate {
                GuideStep step = GuideSteps[_guideIndex]; if (step.Route != null) { ShowPage(step.Route); return; }
                action.IsEnabled = false; action.Content = "Creating…"; string result = await CreateSystemRestorePoint(); action.IsEnabled = true; render(); MessageBox.Show(this, result, "Windows restore point", MessageBoxButton.OK, result.StartsWith("Windows accepted", StringComparison.Ordinal) ? MessageBoxImage.Information : MessageBoxImage.Warning);
            };
            var shortcuts = new WrapPanel { Margin = new Thickness(-5, 0, 0, 0) }; foreach (string page in new[] { "Optimize", "Games", "Network", "Restore", "Settings" }) { string route = page; var button = ActionButton(PageLabel(page), false); button.Click += delegate { ShowPage(route); }; shortcuts.Children.Add(button); } panel.Children.Add(shortcuts);
            render(); return panel;
        }
    }
}
