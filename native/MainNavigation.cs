using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private static string MainRoute(string route)
        {
            switch (route) {
                case "Game Session": return "Games";
                case "Windows": case "Boost-Up": case "Network": case "Lab": return "Tools";
                case "Restore": return "Settings";
                case "Guide": return "Dashboard";
                default: return route;
            }
        }

        private UIElement RouteContent(string route, UIElement content)
        {
            if (route == "Tools" || route == "Optimize" || route == "Dashboard" || route == "Guide") return content;
            string[] routes = route == "Games" || route == "Game Session" ? new[] { "Games", "Game Session" } : route == "Settings" || route == "Restore" ? new[] { "Settings", "Restore" } : new[] { "Tools", route };
            var panel = new StackPanel(); var navigation = new WrapPanel { Margin = new Thickness(2, 4, 0, 12) };
            foreach (string target in routes) {
                string destination = target; string label = target == "Tools" ? "Back to tools" : target == "Games" ? "Game Library" : PageLabel(target);
                var button = ActionButton(label, false); button.BorderBrush = destination == route ? LiveAccentBrush : Brush(BorderColor); button.Click += delegate { ShowPage(destination); }; navigation.Children.Add(button);
            }
            panel.Children.Add(navigation); panel.Children.Add(content); return panel;
        }

        private UIElement BuildToolsOverview()
        {
            var panel = ScrollColumn(); var grid = new UniformGrid { Columns = 2, Margin = new Thickness(-6, 0, -6, 0) };
            string[] routes = { "Boost-Up", "Network", "Windows", "Lab" };
            string[] descriptions = { "Temporary files, caches, and cleanup history.", "Ping, DNS, and connection diagnostics.", "Startup apps, Windows repair, and installed apps.", "Benchmarks, system checks, and reports." };
            for (int index = 0; index < routes.Length; index++) {
                string destination = routes[index]; var card = Card(); card.Margin = new Thickness(6); card.Padding = new Thickness(22); card.Height = 180;
                var body = new StackPanel(); var icon = PageIconView(destination, 24, LiveAccentBrush); icon.HorizontalAlignment = HorizontalAlignment.Left; body.Children.Add(icon);
                body.Children.Add(Text(PageLabel(destination), 16, Brushes.White, true, 0, 12)); body.Children.Add(Text(descriptions[index], 11, Brush(MutedColor), false, 0, 6));
                var open = ActionButton("Open", false); open.Margin = new Thickness(0, 14, 0, 0); open.HorizontalAlignment = HorizontalAlignment.Left; open.Click += delegate { ShowPage(destination); }; body.Children.Add(open); card.Child = body; grid.Children.Add(card);
            }
            panel.Children.Add(grid); return panel;
        }
    }
}
