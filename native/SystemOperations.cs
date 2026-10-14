using System;
using System.Threading.Tasks;
using System.Windows.Input;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private bool _tweakOperationBusy;
        private TaskCompletionSource<bool> _tweakOperationCompletion;
        private string _operationPreviousSubtitle;

        private bool BeginTweakOperation(string caption, bool serviceRecovery = false)
        {
            if (_tweakOperationBusy || _sessionExitInProgress) return false;
            if (_existingTweakScanBusy && !serviceRecovery) return false;
            if (!serviceRecovery && _state.MaintenanceServices.Count > 0)
            {
                MessageBox.Show(this, "Maintenance services need recovery", "Restore", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Warning);
                ShowPage("Restore"); return false;
            }
            if (_updateInstallPreparing || _optionalAppsBusy)
            {
                MessageBox.Show(this, "Wait for the current operation to finish.", "SharkOptimizer", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Information);
                return false;
            }
            if (_sessionStarting || SessionRecoveryPending || (_sessionTimer != null && _sessionTimer.IsEnabled) || (_sessionEndingTask != null && !_sessionEndingTask.IsCompleted))
            {
                MessageBox.Show(this, "End the game session and restore its settings before applying or undoing optimizations.", "Game session", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Information);
                return false;
            }
            _tweakOperationBusy = true;
            _tweakOperationCompletion = new TaskCompletionSource<bool>();
            _operationPreviousSubtitle = _pageSubtitle.Text;
            _pageSubtitle.Text = caption;
            foreach (var page in _pages.Values) page.IsEnabled = false;
            foreach (var button in _navButtons.Values) button.IsEnabled = false;
            if (_applyButton != null) _applyButton.IsEnabled = false;
            Cursor = Cursors.AppStarting;
            return true;
        }

        private void EndTweakOperation()
        {
            _tweakOperationBusy = false;
            foreach (var page in _pages.Values) page.IsEnabled = true;
            foreach (var button in _navButtons.Values) button.IsEnabled = true;
            _pageSubtitle.Text = _operationPreviousSubtitle;
            Cursor = null;
            try { RefreshAll(); UpdateApplyButton(); }
            finally {
                if (_tweakOperationCompletion != null) _tweakOperationCompletion.TrySetResult(true);
                if (_deferredUpdateCheck) { _deferredUpdateCheck = false; if (_state.AutoCheckUpdates && !_sessionExitInProgress && _updateCheckTimer != null) { _updateCheckTimer.Interval = TimeSpan.FromSeconds(8); _updateCheckTimer.Start(); } }
            }
        }

        // Collection changes and serialization stay on the UI thread; Windows work does not.
        private void OnStateThread(Action action)
        {
            if (Dispatcher.CheckAccess()) action();
            else Dispatcher.Invoke(action);
        }

        private async Task RestoreAndSave(AppliedTweak record)
        {
            await Task.Run(() => RestoreRecord(record));
            int index = _state.Applied.IndexOf(record);
            if (index < 0) return;
            _state.Applied.RemoveAt(index);
            try { SaveState(); }
            catch { _state.Applied.Insert(Math.Min(index, _state.Applied.Count), record); throw; }
        }
    }
}
