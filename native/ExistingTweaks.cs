using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private Dictionary<string, bool?> _existingTweakResults = new Dictionary<string, bool?>(StringComparer.OrdinalIgnoreCase);
        private bool _existingTweakScanBusy;
        private CancellationTokenSource _existingTweakCancellation;
        private Task<Dictionary<string, bool?>> _existingTweakWork;
        private TextBlock _existingTweakStatus;
        private Button _existingTweakButton;

        private bool AlreadyEnabledOutsideShark(string id)
        { bool? value; return _existingTweakResults.TryGetValue(id, out value) && value == true && !_state.Applied.Any(x => x.Id == id); }

        private UIElement BuildExistingTweakScanControls()
        {
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
            _existingTweakButton = ActionButton("Scan existing tweaks", false); _existingTweakButton.IsEnabled = !_existingTweakScanBusy;
            _existingTweakButton.Click += async delegate { await ScanExistingTweaks(); };
            DockPanel.SetDock(_existingTweakButton, Dock.Right); row.Children.Add(_existingTweakButton);
            _existingTweakStatus = Text("Existing tweaks have not been scanned yet.", 10, Brush(MutedColor), false);
            _existingTweakStatus.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(_existingTweakStatus); RefreshExistingTweakScanControls(); return row;
        }

        private void RefreshExistingTweakScanControls()
        {
            if (_existingTweakButton != null) _existingTweakButton.IsEnabled = !_existingTweakScanBusy;
            if (_existingTweakStatus != null) _existingTweakStatus.Text = _existingTweakScanBusy ? "Scanning existing Windows settings…" : _existingTweakResults.Count == 0 ? "Existing tweaks have not been scanned yet." : String.Format("Already enabled: {0} · Could not verify: {1}", _existingTweakResults.Count(x => x.Value == true), _existingTweakResults.Count(x => !x.Value.HasValue));
            UpdateApplyButton();
        }

        private async Task ScanExistingTweaks()
        {
            if (_previewMode || _existingTweakScanBusy || _sessionExitInProgress || _tweakOperationBusy || _sessionStarting || (_sessionTimer != null && _sessionTimer.IsEnabled)) return;
            _existingTweakScanBusy = true; RefreshExistingTweakScanControls();
            var source = new CancellationTokenSource(); _existingTweakCancellation = source;
            var candidates = _catalogue.Where(x => !_state.Applied.Any(a => a.Id == x.Id) && TweakRequirement(x) == null).ToArray();
            try {
                _existingTweakWork = Task.Run(() => {
                    var results = new Dictionary<string, bool?>(StringComparer.OrdinalIgnoreCase); var clock = Stopwatch.StartNew();
                    foreach (var tweak in candidates) {
                        source.Token.ThrowIfCancellationRequested();
                        results[tweak.Id] = clock.Elapsed.TotalSeconds >= 90 ? (bool?)null : ReadExistingTweakState(tweak);
                    }
                    return results;
                });
                var scanned = await _existingTweakWork;
                if (_sessionExitInProgress || source.IsCancellationRequested) return;
                _existingTweakResults = scanned;
                _selectedTweaks.RemoveWhere(AlreadyEnabledOutsideShark);
                RenderTweakCards(); RenderGameDetail(); RefreshPresetEditStatus();
            } catch (OperationCanceledException) { }
            catch (Exception ex) { LogActivity("Existing tweak scan failed: " + ex.Message, true, false); }
            finally { _existingTweakScanBusy = false; _existingTweakCancellation = null; source.Dispose(); RefreshExistingTweakScanControls(); }
        }

        private async Task StopExistingTweakScan()
        {
            if (_existingTweakCancellation != null) _existingTweakCancellation.Cancel();
            if (_existingTweakWork != null) try { await _existingTweakWork; } catch { }
        }

        // Read-only: no apply, undo, restore-point, task registration, or state-file writes.
        private static bool? ReadExistingTweakState(TweakDefinition tweak)
        {
            try {
                int checkedSettings = 0;
                foreach (ValueTarget target in tweak.ResolveTargets()) {
                    checkedSettings++;
                    using (RegistryKey root = RegistryKey.OpenBaseKey(target.Hive, RegistryView.Default))
                    using (RegistryKey key = root.OpenSubKey(target.KeyPath, false)) {
                        if (key == null || !key.GetValueNames().Contains(target.Name, StringComparer.OrdinalIgnoreCase)) return false;
                        if (key.GetValueKind(target.Name) != target.Kind || !RegistryData.Equal(key.GetValue(target.Name, null, RegistryValueOptions.DoNotExpandEnvironmentNames), target.Value, target.Kind)) return false;
                    }
                }
                foreach (string name in tweak.ServiceNames) {
                    var service = ReadServiceState(name); if (service == null) continue; checkedSettings++;
                    if (!String.Equals(service.StartMode, "Disabled", StringComparison.OrdinalIgnoreCase) || service.WasRunning) return false;
                }
                foreach (string task in tweak.ScheduledTaskTargets) {
                    bool? enabled = SharkOptimizer.Platform.StartupRegistration.ReadEnabled(task); if (!enabled.HasValue) continue; checkedSettings++; if (enabled.Value) return false;
                }
                if (!String.IsNullOrEmpty(tweak.AdapterFeature)) {
                    var items = ReadAdapterChanges(tweak.AdapterFeature); if (items.Count == 0) return null; checkedSettings++;
                    foreach (var item in items) {
                        if (item.Feature == "dns") { if (item.DnsServers == null || !item.DnsServers.SequenceEqual(item.ExpectedDnsServers, StringComparer.OrdinalIgnoreCase)) return false; }
                        else if (item.Feature == "rss") { if (!item.RssEnabled) return false; }
                        else if (item.Feature == "power") { if (item.PowerStates == null || item.PowerStates.Count == 0) return null; if (item.PowerStates.Values.Any(x => x)) return false; }
                        else if (item.IPv4Enabled || item.IPv6Enabled) return false;
                    }
                }
                if (!String.IsNullOrEmpty(tweak.AdapterAdvancedFeature)) { var items = ReadAdvancedAdapterChanges(tweak.AdapterAdvancedFeature); if (items.Count == 0) return null; checkedSettings++; if (!items.All(x => x.OriginalRegistryValue.SequenceEqual(x.TargetRegistryValue, StringComparer.OrdinalIgnoreCase))) return false; }
                if (tweak.PowerTargets.Count > 0) { var items = CapturePowerSettings(tweak.PowerTargets); checkedSettings++; if (!items.All(x => (!x.SetAc || x.OriginalAc == x.TargetAc) && (!x.SetDc || x.OriginalDc == x.TargetDc))) return false; }
                if (tweak.BootTargets.Count > 0) { var items = CaptureBootSettings(tweak.BootTargets); checkedSettings++; if (!items.All(x => x.Existed && String.Equals(x.OriginalValue, x.TargetValue, StringComparison.OrdinalIgnoreCase))) return false; }
                if (tweak.NetshTargets.Count > 0) { var items = CaptureNetshSettings(tweak.NetshTargets); checkedSettings++; if (!items.All(x => String.Equals(x.OriginalValue, x.TargetValue, StringComparison.OrdinalIgnoreCase))) return false; }
                if (!String.IsNullOrEmpty(tweak.PowerPlanMode)) return null; // A cloned plan cannot be identified reliably from its name.
                if (tweak.DisableHibernation) { checkedSettings++; if (HibernationEnabled()) return false; }
                if (tweak.DisableMemoryCompression) { checkedSettings++; if (ReadMemoryCompression()) return false; }
                return checkedSettings > 0 ? (bool?)true : null;
            } catch { return null; }
        }
    }
}
