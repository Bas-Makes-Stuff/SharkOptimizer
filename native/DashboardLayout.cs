using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private UIElement BuildCompactDashboard()
        {
            var panel = ScrollColumn();
            string noticeText = String.Join(Environment.NewLine, new[] { _nativeStateNotice, _legacyHistoryNotice }.Where(x => !String.IsNullOrWhiteSpace(x)).ToArray());
            if (noticeText.Length > 0) { var notice = Card(); notice.Child = Text(noticeText, 11, Brush(Color.FromRgb(255, 190, 96)), false); panel.Children.Add(notice); }
            var layout = new Grid(); layout.ColumnDefinitions.Add(new ColumnDefinition()); layout.ColumnDefinitions.Add(new ColumnDefinition());
            var left = new StackPanel { Margin = new Thickness(0, 0, 10, 0) };
            var right = new StackPanel { Margin = new Thickness(10, 0, 0, 0) }; Grid.SetColumn(right, 1); layout.Children.Add(left); layout.Children.Add(right);
            var stats = new Grid { Margin = new Thickness(0, 0, 0, 16) }; for (int i = 0; i < 3; i++) stats.ColumnDefinitions.Add(new ColumnDefinition());
            AddDashboardStat(stats, "Tracked changes", _state.Applied.Count, "Restore", 0);
            AddDashboardStat(stats, "Available tweaks", _catalogue.Count, "Optimize", 1);
            AddDashboardStat(stats, "Game library", AllGames().Count(), "Games", 2); left.Children.Add(stats);
            var optimizationHeader = new Grid { Margin = new Thickness(0, 0, 0, 12) }; optimizationHeader.ColumnDefinitions.Add(new ColumnDefinition()); optimizationHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            optimizationHeader.Children.Add(Text("Your optimizations", 13, Brushes.White, true));
            var presets = ActionButton("Manage presets", false); presets.FontSize = 10; presets.Padding = new Thickness(10, 6, 10, 6); presets.Click += delegate { ShowPage("Optimize"); _presetsExpander.IsExpanded = true; }; Grid.SetColumn(presets, 1); optimizationHeader.Children.Add(presets); left.Children.Add(optimizationHeader);
            foreach (string id in new[] { "game-mode", "game-capture", "file-extensions", "startup-delay", "raw-mouse" }) {
                TweakDefinition tweak = _catalogue.FirstOrDefault(x => x.Id == id); if (tweak != null) left.Children.Add(DashboardOptimization(tweak));
            }
            left.Children.Add(Text("Review changes before they touch your PC.", 10, Brush(MutedColor), false, 0, 5));
            if (!_state.GuideSeen) {
                var welcome = Card(); _welcomeGuideCard = welcome; welcome.Padding = new Thickness(14, 10, 14, 10); welcome.Margin = new Thickness(0, 16, 0, 0);
                var row = new DockPanel(); var guide = ActionButton("Quick guide  →", false); guide.FontSize = 10; guide.Click += delegate { ShowPage("Guide"); }; DockPanel.SetDock(guide, Dock.Right); row.Children.Add(guide); row.Children.Add(Text("New here? Start with the quick guide.", 10, Brush(MutedColor), false)); welcome.Child = row; left.Children.Add(welcome);
            }
            right.Children.Add(BuildMonitoringCard());
            right.Children.Add(Text("Shortcuts", 13, Brushes.White, true, 0, 2));
            var shortcuts = new Grid { Margin = new Thickness(0, 12, 0, 0) }; for (int i = 0; i < 4; i++) shortcuts.ColumnDefinitions.Add(new ColumnDefinition());
            AddDashboardShortcut(shortcuts, "Restore", 0); AddDashboardShortcut(shortcuts, "Games", 1); AddDashboardShortcut(shortcuts, "Boost-Up", 2); AddDashboardShortcut(shortcuts, "Network", 3); right.Children.Add(shortcuts);
            panel.Children.Add(layout); return panel;
        }

        private void AddDashboardStat(Grid grid, string label, int count, string route, int column)
        {
            var button = ActionButton("", false); button.HorizontalContentAlignment = HorizontalAlignment.Stretch; button.Padding = new Thickness(13, 12, 13, 12); button.Margin = new Thickness(column == 0 ? 0 : 4, 0, column == 2 ? 0 : 4, 0); button.Background = Brush(SurfaceColor);
            var body = new StackPanel(); var icon = PageIconView(route, 16, LiveAccentBrush); icon.HorizontalAlignment = HorizontalAlignment.Left; body.Children.Add(icon);
            body.Children.Add(Text(count.ToString(), 22, Brushes.White, true, 0, 7)); body.Children.Add(Text(label, 10, Brush(MutedColor), false));
            button.Content = body; button.ToolTip = PageLabel(route); button.Click += delegate { ShowPage(route); }; Grid.SetColumn(button, column); grid.Children.Add(button);
        }

        private UIElement DashboardOptimization(TweakDefinition tweak)
        {
            bool tracked = _state.Applied.Any(x => x.Id == tweak.Id);
            var button = ActionButton("", false); button.HorizontalContentAlignment = HorizontalAlignment.Stretch; button.Padding = new Thickness(14, 13, 14, 13); button.Margin = new Thickness(0, 0, 0, 8); button.Background = Brush(SurfaceColor); button.ToolTip = "Review optimization";
            var row = new Grid(); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var copy = new StackPanel(); copy.Children.Add(Text(tweak.Name, 11.5, Brushes.White, true)); copy.Children.Add(Text(tweak.Description, 10, Brush(MutedColor), false, 0, 4)); copy.Margin = new Thickness(0, 0, 12, 0); row.Children.Add(copy);
            var state = new Border { CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 4, 8, 4), Background = tracked ? LiveNavFill : Brush(SurfaceRaised), VerticalAlignment = VerticalAlignment.Center, Child = Text(tracked ? "Tracked" : "Review", 9, tracked ? LiveAccentBrush : Brush(MutedColor), true) }; Grid.SetColumn(state, 1); row.Children.Add(state);
            button.Content = row; button.Click += delegate { _optimizationGroup = null; ShowPage("Optimize"); _recommendedOnlyActive = false; if (_recommendedOnlyFilter != null) _recommendedOnlyFilter.IsChecked = false; _categoryFilter.SelectedIndex = 0; _tweakSearch.Text = tweak.Name; if (!tracked && CanSelectTweak(tweak.Id)) _selectedTweaks.Add(tweak.Id); RenderTweakCards(); }; return button;
        }

        private void AddDashboardShortcut(Grid host, string route, int column)
        {
            var button = ActionButton("", false); button.Background = Brush(SurfaceColor); button.MinHeight = 92; button.Padding = new Thickness(8, 14, 8, 12); button.Margin = new Thickness(column == 0 ? 0 : 4, 0, column == 3 ? 0 : 4, 0);
            var body = new StackPanel(); body.Children.Add(PageIconView(route, 28, Brushes.White));
            var label = Text(PageLabel(route), 10, Brush(MutedColor), false, 0, 10); label.TextAlignment = TextAlignment.Center; body.Children.Add(label); button.Content = body; button.ToolTip = PageLabel(route); button.Click += delegate { ShowPage(route); }; Grid.SetColumn(button, column); host.Children.Add(button);
        }
    }
}
