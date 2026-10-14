using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private bool _recommendedOnlyActive;
        private CheckBox _recommendedOnlyFilter;
        private static readonly string[] AlwaysRecommended = {
            "p_telemetry", "p_tasks", "p_adid", "p_bing", "p_cortana", "p_activity", "p_ads", "p_consumer", "p_recall", "p_feedback", "p_ink", "p_llmnr", "p_remreg", "p_remote", "p_do",
            "q_ext", "q_menu", "q_startdelay", "q_sticky", "q_reboot", "q_welcome", "f_gamemode", "f_dvr", "f_overlay", "f_prio", "f_mmcss", "f_mouse",
            "n_nagle", "n_throttle", "n_qos", "n_heur", "n_dns", "n_nicpwr", "w_edge", "w_services", "w_chat", "w_lastaccess", "w_wudrv"
        };

        private bool IsRecommended(TweakDefinition tweak)
        {
            string id = LegacyTweakAliases.Where(x => x.Value == tweak.Id).Select(x => x.Key).FirstOrDefault();
            if (id == null || !CanSelectTweak(tweak.Id)) return false;
            if (AlwaysRecommended.Contains(id, StringComparer.OrdinalIgnoreCase)) return true;
            var f = _requirements; if (f == null) return false;
            switch (id)
            {
                case "p_nvtel": return f.Nvidia == true;
                case "q_visfx": return (f.RamGb > 0 && f.RamGb <= 8) || f.IntelGpu == true;
                case "q_bgapps": return f.RamGb > 0 && f.RamGb <= 8;
                case "q_search": case "f_diskoff": return f.SystemSsd == false;
                case "f_power": case "f_usb": case "f_pcie": case "f_throttle": return f.Laptop == false;
                case "f_hags": return f.Nvidia == true || f.AmdGpu == true;
                case "f_fast": case "f_sysmain": case "w_prefetch": return f.SystemSsd == true;
                case "n_rsc": case "n_eee": return f.Ethernet && !f.Wifi;
                case "n_rss": return f.Threads >= 6;
                case "n_wifi": return f.Wifi;
                case "w_svchost": return f.RamGb >= 16;
                default: return false;
            }
        }

        private UIElement BuildRecommendedControls()
        {
            var row = new Grid { Margin = new Thickness(0, 0, 0, 12) };
            row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var selection = SelectionMenu(new[] { "Select safe recommendations", "Select visible", "Clear selection" }, delegate(int choice) {
                if (choice == 0) {
                foreach (TweakDefinition tweak in _catalogue.Where(x => (x.Risk == "Safe" || x.Risk == "Recommended" || x.Risk == "Personal choice") && IsRecommended(x) && !_state.Applied.Any(a => a.Id == x.Id))) _selectedTweaks.Add(tweak.Id);
                RenderTweakCards();
                } else if (choice == 1) { foreach (CheckBox check in _checks.Where(x => x.IsEnabled)) check.IsChecked = true; }
                else { _selectedTweaks.Clear(); RenderTweakCards(); }
            });
            var filter = new CheckBox { Content = "Recommended only", IsChecked = _recommendedOnlyActive, VerticalAlignment = VerticalAlignment.Center };
            _recommendedOnlyFilter = filter;
            filter.Click += delegate { _recommendedOnlyActive = filter.IsChecked == true; RenderTweakCards(); };
            row.Children.Add(filter); Grid.SetColumn(selection, 1); row.Children.Add(selection); return row;
        }
    }
}
