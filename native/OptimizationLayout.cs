using System;
using System.Linq;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private string _optimizationGroup;
        private readonly Dictionary<string, Button> _optimizationGroupButtons = new Dictionary<string, Button>();
        private static readonly string[] OptimizationGroups = { "FPS & Latency", "Network & Ping", "Privacy & Security", "Windows Experience", "Advanced" };
        private UIElement OptimizeSections(StackPanel general)
        {
            general.Children.Remove(_presetsExpander);
            var panel = ScrollColumn(); var tabs = new WrapPanel { Margin = new Thickness(-4, 0, 0, 12) };
            var browse = ActionButton("General", false); var presets = ActionButton("Presets", false); tabs.Children.Add(browse); tabs.Children.Add(presets); panel.Children.Add(tabs);
            var host = new Grid(); host.Children.Add(general); host.Children.Add(_presetsExpander); panel.Children.Add(host);
            Action<bool> select = delegate(bool saved) { general.Visibility = saved ? Visibility.Collapsed : Visibility.Visible; _presetsExpander.Visibility = saved ? Visibility.Visible : Visibility.Collapsed; browse.BorderBrush = saved ? Brush(BorderColor) : LiveAccentBrush; presets.BorderBrush = saved ? LiveAccentBrush : Brush(BorderColor); };
            browse.Click += delegate { _presetsExpander.IsExpanded = false; select(false); };
            presets.Click += delegate { _presetsExpander.IsExpanded = true; select(true); };
            _presetsExpander.Expanded += delegate { select(true); };
            _presetsExpander.Collapsed += delegate { select(false); };
            select(false); return panel;
        }

        private string OptimizationGroup(TweakDefinition tweak)
        {
            switch (tweak.Category) {
                case "Gaming": case "Input": case "Performance": return "FPS & Latency";
                case "Network": return "Network & Ping";
                case "Privacy": case "Security": return "Privacy & Security";
                case "Advanced": return "Advanced";
                case "Windows": case "Personalization": return "Windows Experience";
                default: return tweak.Category;
            }
        }

        private UIElement OptimizationNavigation()
        {
            var row = new WrapPanel { Margin = new Thickness(-4, 0, 0, 12) };
            _optimizationGroupButtons.Clear();
            foreach (string group in new[] { "Overview" }.Concat(OptimizationGroups)) {
                string target = group;
                var button = ActionButton(group, false); button.FontSize = 10; button.Padding = new Thickness(12, 7, 12, 7);
                button.Click += delegate { _optimizationGroup = target == "Overview" ? null : target; _recommendedOnlyActive = false; if (_recommendedOnlyFilter != null) _recommendedOnlyFilter.IsChecked = false; _tweakSearch.Clear(); _categoryFilter.SelectedIndex = 0; RenderTweakCards(); };
                row.Children.Add(button);
                _optimizationGroupButtons[group] = button;
            }
            return row;
        }

        private void RenderOptimizationOverview()
        {
            foreach (var entry in _optimizationGroupButtons) entry.Value.BorderBrush = entry.Key == (_optimizationGroup ?? "Overview") ? LiveAccentBrush : Brush(BorderColor);
            string query = _tweakSearch == null ? "" : _tweakSearch.Text.Trim();
            var categoryChoice = _categoryFilter == null ? null : _categoryFilter.SelectedItem as ComboBoxItem;
            string category = categoryChoice == null ? "All categories" : Convert.ToString(categoryChoice.Tag);
            var visible = _catalogue.Where(t => (_optimizationGroup == null || OptimizationGroup(t) == _optimizationGroup) &&
                (!_recommendedOnlyActive || IsRecommended(t)) && (category == "All categories" || t.Category == category) &&
                (query.Length == 0 || (t.Name + " " + t.Description + " " + t.Category + " " + Localization.Translate(t.Name)).IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0)).ToList();
            bool overview = _optimizationGroup == null && query.Length == 0 && category == "All categories" && !_recommendedOnlyActive;
            if (overview) {
                var popular = visible.OrderByDescending(t => IsRecommended(t)).ThenBy(t => t.Risk == "Safe" ? 0 : 1).Take(3).ToList();
                _tweakList.Children.Add(Text("Recommended", 17, Brushes.White, true, 0, 4));
                _tweakList.Children.Add(TweakTileGrid(popular));
                var groups = new UniformGrid { Columns = 3, Margin = new Thickness(-5, 12, -5, 0) };
                foreach (string group in visible.Select(OptimizationGroup).Distinct()) {
                    string target = group; var tweaks = visible.Where(t => OptimizationGroup(t) == group).ToList();
                    var card = Card(); card.Margin = new Thickness(5); card.Padding = new Thickness(14); var body = new StackPanel();
                    body.Children.Add(Text(group, 12, Brushes.White, true));
                    int enabled = tweaks.Count(t => _state.Applied.Any(a => a.Id == t.Id) || AlreadyEnabledOutsideShark(t.Id));
                    body.Children.Add(Text(enabled + " / " + tweaks.Count + " · " + Localization.Translate("Enabled"), 9, Brush(MutedColor), false, 0, 4));
                    foreach (var tweak in tweaks.OrderByDescending(IsRecommended).Take(3)) {
                        var line = Text(tweak.Name, 10, Brush(MutedColor), false, 0, 7); line.TextWrapping = TextWrapping.NoWrap; line.TextTrimming = TextTrimming.CharacterEllipsis; body.Children.Add(line);
                    }
                    var all = ActionButton("Show all", false); all.Margin = new Thickness(0, 11, 0, 0); all.HorizontalAlignment = HorizontalAlignment.Left; all.FontSize = 10;
                    all.Click += delegate { _optimizationGroup = target; RenderTweakCards(); }; body.Children.Add(all); card.Child = body; groups.Children.Add(card);
                }
                _tweakList.Children.Add(groups);
            } else {
                var header = new DockPanel { Margin = new Thickness(0, 5, 0, 10) };
                var back = ActionButton("Back to overview", false); back.FontSize = 10; back.Click += delegate { _optimizationGroup = null; _tweakSearch.Clear(); _categoryFilter.SelectedIndex = 0; _recommendedOnlyActive = false; if (_recommendedOnlyFilter != null) _recommendedOnlyFilter.IsChecked = false; RenderTweakCards(); }; DockPanel.SetDock(back, Dock.Right); header.Children.Add(back);
                header.Children.Add(Text(_optimizationGroup ?? "All optimizations", 17, Brushes.White, true)); _tweakList.Children.Add(header);
                if (visible.Count == 0) _tweakList.Children.Add(Text("No optimizations match that search.", 12, Brush(MutedColor), false));
                else _tweakList.Children.Add(TweakTileGrid(visible));
            }
        }

        private UIElement TweakTileGrid(IEnumerable<TweakDefinition> tweaks)
        {
            var grid = new UniformGrid { Columns = Width < 1100 ? 2 : 3, Margin = new Thickness(-5, 5, -5, 0) };
            foreach (var tweak in tweaks) grid.Children.Add(CompactTweakTile(tweak));
            return grid;
        }

        private UIElement CompactTweakTile(TweakDefinition tweak)
        {
            bool tracked = _state.Applied.Any(a => a.Id == tweak.Id), external = AlreadyEnabledOutsideShark(tweak.Id), enabled = tracked || external;
            string requirement = TweakRequirement(tweak);
            var green = Brush(Color.FromRgb(63, 177, 116));
            var card = Card(); card.Height = 190; card.Margin = new Thickness(5); card.Padding = new Thickness(14);
            card.BorderBrush = enabled ? green : _selectedTweaks.Contains(tweak.Id) ? LiveAccentBrush : Brush(BorderColor);
            card.BorderThickness = new Thickness(1);
            var body = new Grid(); body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); body.RowDefinitions.Add(new RowDefinition()); body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var tag = new DockPanel();
            if (!enabled && tweak.Risk != "Safe" && tweak.Risk != "Recommended") { var risk = Text(tweak.Risk, 9, Brush(Color.FromRgb(255, 190, 96)), true); DockPanel.SetDock(risk, Dock.Right); tag.Children.Add(risk); }
            tag.Children.Add(Text(OptimizationGroup(tweak), 9, Brush(MutedColor), false)); body.Children.Add(tag);
            var copy = new StackPanel { Margin = new Thickness(0, 10, 0, 8) }; Grid.SetRow(copy, 1);
            var name = Text(tweak.Name, 14, Brushes.White, true); name.MaxHeight = 44; name.TextTrimming = TextTrimming.CharacterEllipsis; copy.Children.Add(name);
            var description = Text(tweak.Description, 11, Brush(MutedColor), false, 0, 7); description.MaxHeight = 48; description.TextTrimming = TextTrimming.CharacterEllipsis; copy.Children.Add(description);
            if (_state.CustomTweaks.Any(t => t.Id == tweak.Id)) { Localization.KeepData(name); Localization.KeepData(description); }
            if (enabled) copy.Children.Add(Text(external ? "Already enabled" : "Enabled", 9, green, true, 0, 6));
            else if (requirement != null) copy.Children.Add(Text(_requirementsReady ? requirement : "Checking hardware…", 9, Brush(MutedColor), false, 0, 6));
            body.Children.Add(copy);
            var footer = new Grid(); footer.ColumnDefinitions.Add(new ColumnDefinition()); footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); Grid.SetRow(footer, 2);
            var details = ActionButton("Details", false); details.Padding = new Thickness(0); details.Margin = new Thickness(0); details.Background = Brushes.Transparent; details.BorderThickness = new Thickness(0); details.FontSize = 10; details.HorizontalAlignment = HorizontalAlignment.Left;
            details.Click += delegate { ShowTweakDetails(tweak); }; footer.Children.Add(details);
            var check = new CheckBox { Content = enabled ? "Enabled" : "Select", IsChecked = enabled || _selectedTweaks.Contains(tweak.Id), IsEnabled = !enabled && requirement == null, VerticalAlignment = VerticalAlignment.Center, FontSize = 10, ToolTip = external ? "Already enabled outside SharkOptimizer. No original value is available for undo." : tracked ? "Already applied. Undo it from Restore first." : "Select this change", Tag = tweak };
            check.Checked += delegate { if (!enabled) _selectedTweaks.Add(tweak.Id); card.BorderBrush = enabled ? green : LiveAccentBrush; UpdateApplyButton(); };
            check.Unchecked += delegate { _selectedTweaks.Remove(tweak.Id); card.BorderBrush = enabled ? green : Brush(BorderColor); UpdateApplyButton(); };
            Grid.SetColumn(check, 1); footer.Children.Add(check); _checks.Add(check); body.Children.Add(footer); card.Child = body; return card;
        }

        private void ShowTweakDetails(TweakDefinition tweak)
        {
            var dialog = new Window { Owner = this, Title = tweak.Name, Width = 540, Height = 430, WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Brush(BackgroundColor), Foreground = Brushes.White, FontFamily = FontFamily };
            CopyControlStyles(dialog); var panel = new StackPanel { Margin = new Thickness(22) };
            panel.Children.Add(Text(tweak.Name, 18, Brushes.White, true)); panel.Children.Add(Text(tweak.Description, 12, Brush(MutedColor), false, 0, 12));
            panel.Children.Add(Text(tweak.Risk, 10, Brush(MutedColor), true, 0, 12));
            string warning = TweakWarningForReview(tweak); if (!String.IsNullOrEmpty(warning)) panel.Children.Add(Text(warning, 11, Brush(Color.FromRgb(255, 190, 96)), false, 0, 12));
            if (AlreadyEnabledOutsideShark(tweak.Id)) panel.Children.Add(Text("Already enabled outside SharkOptimizer. No original value is available for undo.", 11, Brush(MutedColor), false, 0, 12));
            var close = ActionButton("Close", false); close.IsCancel = true; close.HorizontalAlignment = HorizontalAlignment.Right; close.Margin = new Thickness(0, 18, 0, 0); close.Click += delegate { dialog.Close(); }; panel.Children.Add(close);
            dialog.Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }; Localization.Apply(panel); dialog.ShowDialog();
        }
    }
}
