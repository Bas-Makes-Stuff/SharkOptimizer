using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private Expander _presetsExpander;
        private Action<int> _selectSettingsSection;

        private void ShowThirdPartyNotices()
        {
            var dialog = new Window { Title = "Third-party notices", Owner = this, Width = 780, Height = 560, MinWidth = 560, MinHeight = 420, WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Brush(BackgroundColor), Foreground = Brushes.White, FontFamily = FontFamily };
            CopyControlStyles(dialog);
            var body = new Grid { Margin = new Thickness(18) }; body.RowDefinitions.Add(new RowDefinition()); body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var notices = new TextBox { Text = FluentIcons.Notices(), IsReadOnly = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, FontFamily = new FontFamily("Consolas"), FontSize = 11, Padding = new Thickness(12) }; Localization.KeepData(notices); body.Children.Add(notices);
            var close = ActionButton("Close", false); close.IsCancel = true; close.HorizontalAlignment = HorizontalAlignment.Right; close.Margin = new Thickness(0, 12, 0, 0); close.Click += delegate { dialog.Close(); }; Grid.SetRow(close, 1); body.Children.Add(close); dialog.Content = body; dialog.ShowDialog();
        }

        private static Geometry SidebarIcon(string page, bool selected = false)
        { return FluentIcons.Get(page, selected); }

        private UIElement BuildSettingsNavigation(StackPanel[] sections)
        {
            string[] labels = { "Preferences", "Startup & updates", "Data & recovery", "Maintenance" };
            var row = new WrapPanel { Margin = new Thickness(-5, 0, 0, 14) };
            var buttons = new Button[sections.Length];
            Action<int> select = delegate(int active) {
                for (int i = 0; i < sections.Length; i++) {
                    sections[i].Visibility = i == active ? Visibility.Visible : Visibility.Collapsed;
                    buttons[i].Background = i == active ? LiveNavFill : Brush(SurfaceRaised);
                    buttons[i].BorderBrush = i == active ? LiveAccentBrush : Brush(BorderColor);
                    buttons[i].Foreground = i == active ? LiveAccentBrush : Brush(MutedColor);
                }
            };
            for (int i = 0; i < labels.Length; i++) {
                int index = i; var button = ActionButton(labels[i], false);
                button.Margin = new Thickness(5, 0, 0, 6);
                button.Click += delegate { select(index); };
                buttons[i] = button; row.Children.Add(button);
            }
            _selectSettingsSection = select; select(0); return row;
        }

        private ComboBox SelectionMenu(string[] actions, Action<int> execute)
        {
            var menu = new ComboBox { MinWidth = 156, Height = 36, VerticalAlignment = VerticalAlignment.Center };
            menu.Items.Add(new ComboBoxItem { Content = "Selection actions", IsEnabled = false });
            foreach (string action in actions) menu.Items.Add(new ComboBoxItem { Content = action });
            menu.SelectedIndex = 0;
            menu.SelectionChanged += delegate {
                int choice = menu.SelectedIndex - 1;
                if (choice < 0) return;
                menu.SelectedIndex = 0;
                execute(choice);
            };
            return menu;
        }

        private static string PageLabel(string page)
        {
            if (page == "Games") return "Game Library";
            if (page == "Game Session") return "Game Boost";
            if (page == "Windows") return "Windows Tools";
            if (page == "Boost-Up") return "Cleanup";
            if (page == "Lab") return "System Lab";
            return page;
        }

        private static Viewbox PageIconView(string page, double size, Brush color)
        {
            var path = new System.Windows.Shapes.Path { Data = FluentIcons.Get(page, false), Fill = color, Width = 24, Height = 24, Stretch = Stretch.None };
            return new Viewbox { Width = size, Height = size, Child = path, HorizontalAlignment = HorizontalAlignment.Center };
        }
    }
}
