using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private TextBox _cleanupSearch;
        private ComboBox _cleanupCategory;
        private TextBlock _cleanupFilterStatus;

        private UIElement BuildCleanupFilters()
        {
            var body = new StackPanel(); var row = new Grid { Margin = new Thickness(0, 0, 0, 10) };
            row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) });
            var searchHost = new Grid();
            _cleanupSearch = new TextBox { Height = 38, Padding = new Thickness(36, 8, 11, 8), Background = Brush(SurfaceColor), Foreground = Brushes.White, BorderBrush = Brush(BorderColor), ToolTip = "Search cleanup…" };
            searchHost.Children.Add(_cleanupSearch);
            searchHost.Children.Add(new TextBlock { Text = "\uE721", FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 13, Foreground = Brush(MutedColor), Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false });
            var placeholder = Text("Search cleanup…", 11, Brush(MutedColor), false, 36); placeholder.IsHitTestVisible = false; searchHost.Children.Add(placeholder);
            _cleanupCategory = new ComboBox { Height = 38, Margin = new Thickness(8, 0, 0, 0) };
            foreach (string name in new[] { "All categories", "Cleanup", "System", "Gaming", "Privacy", "Network" }) _cleanupCategory.Items.Add(new ComboBoxItem { Content = name, Tag = name });
            _cleanupCategory.SelectedIndex = 0;
            _cleanupSearch.TextChanged += delegate { placeholder.Visibility = _cleanupSearch.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; ApplyCleanupFilter(); };
            _cleanupCategory.SelectionChanged += delegate { ApplyCleanupFilter(); };
            row.Children.Add(searchHost); Grid.SetColumn(_cleanupCategory, 1); row.Children.Add(_cleanupCategory); body.Children.Add(row);
            var selection = SelectionMenu(new[] { "Select visible", "Clear selection" }, delegate(int choice) {
                if (choice == 0) {
                foreach (Border card in _cleanupList.Children.OfType<Border>()) { var check = card.Tag as CheckBox; if (card.Visibility == Visibility.Visible && check != null && check.IsEnabled) check.IsChecked = true; }
                foreach (MaintenanceJob job in _maintenanceJobs) if (job.Card.IsVisible) job.Check.IsChecked = true;
                } else {
                foreach (Border card in _cleanupList.Children.OfType<Border>()) { var check = card.Tag as CheckBox; if (check != null) check.IsChecked = false; }
                foreach (MaintenanceJob job in _maintenanceJobs) job.Check.IsChecked = false;
                }
            });
            selection.HorizontalAlignment = HorizontalAlignment.Right; selection.Margin = new Thickness(0, 0, 0, 12); body.Children.Add(selection);
            _cleanupFilterStatus = Text("No cleanup actions match these filters.", 11, Brush(MutedColor), false, 0, 8); _cleanupFilterStatus.Visibility = Visibility.Collapsed; body.Children.Add(_cleanupFilterStatus); return body;
        }

        private static string CleanupCategory(string name)
        {
            if (name.IndexOf("shader", StringComparison.OrdinalIgnoreCase) >= 0 || name == "Trim Process RAM") return "Gaming";
            if (name.IndexOf("history", StringComparison.OrdinalIgnoreCase) >= 0) return "Privacy";
            if (name == "Flush DNS Cache") return "Network";
            if (name == "Optimize Drives" || name == "Clean Font Cache" || name == "Clean Thumbnail Cache" || name == "Clean Windows Update Downloads" || name.IndexOf("error report", StringComparison.OrdinalIgnoreCase) >= 0 || name == "Crash dumps") return "System";
            return "Cleanup";
        }

        private bool MatchesCleanupFilter(string name, string detail)
        {
            string query = _cleanupSearch == null ? "" : _cleanupSearch.Text.Trim();
            var choice = _cleanupCategory == null ? null : _cleanupCategory.SelectedItem as ComboBoxItem;
            string category = choice == null ? "All categories" : Convert.ToString(choice.Tag);
            if (category != "All categories" && category != CleanupCategory(name)) return false;
            return query.Length == 0 || name.IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0 || Localization.Translate(name).IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0 || (detail ?? "").IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0 || Localization.Translate(detail ?? "").IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private void ApplyCleanupFilter()
        {
            if (_cleanupList == null) return;
            foreach (Border card in _cleanupList.Children.OfType<Border>())
            {
                var check = card.Tag as CheckBox; var target = check == null ? null : check.Tag as CleanupTarget;
                if (target != null) card.Visibility = MatchesCleanupFilter(target.Name, target.Path) ? Visibility.Visible : Visibility.Collapsed;
            }
            foreach (MaintenanceJob job in _maintenanceJobs) job.Card.Visibility = MatchesCleanupFilter(job.Title, job.Note) ? Visibility.Visible : Visibility.Collapsed;
            if (_cleanupFilterStatus != null) _cleanupFilterStatus.Visibility = _cleanupList.Children.OfType<Border>().Any(x => x.Visibility == Visibility.Visible) || _maintenanceJobs.Any(x => x.Card.Visibility == Visibility.Visible) ? Visibility.Collapsed : Visibility.Visible;
        }
    }
}
