using System;
using System.Linq;
using System.IO;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private UIElement SectionViews(string[] titles, UIElement[] sections, Action<int> changed = null)
        {
            var panel = ScrollColumn(); var tabs = new WrapPanel { Margin = new Thickness(-4, 0, 0, 12) }; var host = new Grid(); var buttons = new Button[titles.Length];
            foreach (var section in sections) host.Children.Add(section);
            Action<int> select = delegate(int selected) {
                for (int index = 0; index < sections.Length; index++) { sections[index].Visibility = index == selected ? Visibility.Visible : Visibility.Collapsed; buttons[index].BorderBrush = index == selected ? LiveAccentBrush : Brush(BorderColor); }
                if (changed != null) changed(selected);
            };
            for (int index = 0; index < titles.Length; index++) { int tab = index; buttons[index] = ActionButton(titles[index], false); buttons[index].Click += delegate { select(tab); }; tabs.Children.Add(buttons[index]); }
            panel.Children.Add(tabs); panel.Children.Add(host); select(0); return panel;
        }

        private UIElement WindowsToolViews(StackPanel original)
        {
            var cards = original.Children.Cast<UIElement>().ToArray(); original.Children.Clear();
            return SectionViews(new[] { "Quick tools", "Installed apps", "Startup apps", "Windows repair", "Close background apps" }, cards, delegate(int selected) { if (selected == 2) RefreshStartupApps(); if (selected == 4) RefreshWindowsProcesses(); });
        }

        private UIElement CleanupViews(StackPanel cleanup, UIElement recycle, UIElement maintenance, UIElement history)
        {
            var historyExpander = history as Expander; if (historyExpander != null) historyExpander.IsExpanded = true;
            cleanup.Children.Remove(recycle);
            var maintenanceView = new StackPanel(); maintenanceView.Children.Add(maintenance);
            var run = ActionButton("Run selected", true); run.HorizontalAlignment = HorizontalAlignment.Left; run.Click += async delegate { await CleanSelectedFolders(true); }; maintenanceView.Children.Add(run);
            return SectionViews(new[] { "Cleanup", "Recycle Bin", "Maintenance", "History" }, new UIElement[] { cleanup, recycle, maintenanceView, history });
        }

        private List<CleanupTarget> SelectedCleanupTargets(bool maintenanceOnly)
        {
            return maintenanceOnly ? new List<CleanupTarget>() : _cleanupList.Children.OfType<Border>().Select(x => (CheckBox)x.Tag).Where(x => x.IsChecked == true).Select(x => (CleanupTarget)x.Tag).Where(x => Directory.Exists(x.Path)).ToList();
        }

        private List<MaintenanceJob> SelectedMaintenanceJobs(bool maintenanceOnly)
        {
            return maintenanceOnly ? _maintenanceJobs.Where(x => x.Check.IsChecked == true).ToList() : new List<MaintenanceJob>();
        }
    }
}
