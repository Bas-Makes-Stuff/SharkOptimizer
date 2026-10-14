using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private string _pendingUpdatePath, _updateNotifiedVersion;
        private UpdateReleaseInfo _pendingUpdateRelease;
        private CancellationTokenSource _updateDownloadCancellation;
        private Task<string> _updateDownloadTask;
        private Task _updateWorkTask;
        private bool _updateShutdown;

        private bool HasPendingUpdate()
        { return _pendingUpdateRelease != null && !String.IsNullOrEmpty(_pendingUpdatePath) && File.Exists(_pendingUpdatePath); }

        private void RefreshUpdateControls()
        {
            if (_updateReadyButton != null) _updateReadyButton.Visibility = HasPendingUpdate() ? Visibility.Visible : Visibility.Collapsed;
            if (_updateButton != null) { _updateButton.IsEnabled = !_checkingUpdates && !_updateInstallPreparing; _updateButton.Content = HasPendingUpdate() ? "Install downloaded update" : "Check for updates"; }
            if (HasPendingUpdate() && _updateStatus != null) _updateStatus.Text = "Version " + _pendingUpdateRelease.Version.ToString(3) + " downloaded · ready to install";
        }

        private void ClearPendingUpdate()
        {
            string path = _pendingUpdatePath; _pendingUpdatePath = null; _pendingUpdateRelease = null;
            if (!String.IsNullOrEmpty(path)) try { File.Delete(path); } catch { }
        }

        private void NotifyUpdate(UpdateReleaseInfo release, bool downloaded)
        {
            string key = release.Version + ":" + downloaded;
            if (_updateNotifiedVersion == key || !_state.Toasts || _trayIcon == null) return;
            _updateNotifiedVersion = key;
            _sessionRecapReady = false;
            _trayIcon.Visible = true;
            _trayIcon.ShowBalloonTip(8000, "SharkOptimizer", Localization.Translate(downloaded ? "An update is downloaded. Open Settings to install it when you are ready." : "A new update is available. Open Settings to download it."), System.Windows.Forms.ToolTipIcon.Info);
        }

        private async Task CheckForUpdates(bool automatic)
        {
            if (_updateShutdown || _sessionExitInProgress || _checkingUpdates || _updateInstallPreparing) return;
            if (_tweakOperationBusy) { if (automatic) _deferredUpdateCheck = true; return; }
            if (automatic && !_state.AutoCheckUpdates) return;
            _checkingUpdates = true;
            if (_updateButton != null) { _updateButton.IsEnabled = false; _updateButton.Content = "Checking…"; }
            if (_updateStatus != null) _updateStatus.Text = "Contacting GitHub stable releases…";
            bool installAfterCheck = false;
            try {
                _updateDownloadCancellation = new CancellationTokenSource();
                var fetch = Task.Run<UpdateReleaseInfo>(new Func<UpdateReleaseInfo>(FetchLatestRelease)); _updateWorkTask = fetch;
                UpdateReleaseInfo release = await fetch;
                if (_updateShutdown || _sessionExitInProgress || (automatic && !_state.AutoCheckUpdates)) return;
                if (_tweakOperationBusy) { if (automatic) _deferredUpdateCheck = true; return; }
                if (release.Version.CompareTo(CurrentAppVersion) <= 0) {
                    ClearPendingUpdate(); if (_updateStatus != null) _updateStatus.Text = "You are up to date · latest stable release " + release.Version.ToString(3); return;
                }
                if (String.IsNullOrWhiteSpace(release.AssetUrl)) {
                    if (_updateStatus != null) _updateStatus.Text = "Version " + release.Version.ToString(3) + " is on GitHub, but its setup file is not attached yet."; return;
                }
                bool cached = HasPendingUpdate() && _pendingUpdateRelease.Version.Equals(release.Version) && _pendingUpdateRelease.AssetDigest == release.AssetDigest && _pendingUpdateRelease.AssetSize == release.AssetSize;
                if (cached) {
                    string cachedPath = _pendingUpdatePath;
                    try { var verify = Task.Run(() => ValidateDownloadedSetup(cachedPath, release)); _updateWorkTask = verify; await verify; }
                    catch { ClearPendingUpdate(); cached = false; }
                }
                if (_updateShutdown || _sessionExitInProgress) return;
                if (!cached) {
                    if (!_state.AutoDownloadUpdates) {
                        if (automatic) { NotifyUpdate(release, false); if (_updateStatus != null) _updateStatus.Text = "Version " + release.Version.ToString(3) + " is available when you are ready."; return; }
                        if (MessageBox.Show(this, "Download the available update now? Installation will wait for your confirmation.", "Update available", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
                    }
                    ClearPendingUpdate();
                    if (_updateButton != null) _updateButton.Content = "Downloading…";
                    if (_updateStatus != null) _updateStatus.Text = "Downloading the GitHub setup asset and checking its version…";
                    _updateDownloadTask = Task.Run<string>(() => DownloadAndVerifySetup(release));
                    _updateWorkTask = _updateDownloadTask;
                    string path = await _updateDownloadTask;
                    if (_updateShutdown || _sessionExitInProgress) { try { File.Delete(path); } catch { } return; }
                    _pendingUpdatePath = path; _pendingUpdateRelease = release;
                }
                RefreshUpdateControls();
                if (automatic) NotifyUpdate(release, true); else installAfterCheck = true;
            } catch (Exception ex) {
                if (!_updateShutdown && !_sessionExitInProgress) {
                    if (_updateStatus != null) _updateStatus.Text = "Update check did not complete.";
                    if (!automatic) MessageBox.Show(this, "SharkOptimizer could not check or install the GitHub update." + Environment.NewLine + Environment.NewLine + ex.Message, "SharkOptimizer updates", MessageBoxButton.OK, MessageBoxImage.Warning);
                }
            } finally {
                if (_updateDownloadCancellation != null) { _updateDownloadCancellation.Dispose(); _updateDownloadCancellation = null; }
                _checkingUpdates = false; RefreshUpdateControls();
            }
            if (installAfterCheck && !_updateShutdown && !_sessionExitInProgress) await InstallPendingUpdate();
        }

        private async Task InstallPendingUpdate()
        {
            if (_updateShutdown || _sessionExitInProgress || _checkingUpdates || _updateInstallPreparing || !HasPendingUpdate()) return;
            if (_tweakOperationBusy) { if (_updateStatus != null) _updateStatus.Text = "Finish the current action before installing the update."; return; }
            if (MessageBox.Show(this, "Install the downloaded update now? SharkOptimizer will close and reopen after installation.", "Update available", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
            _updateInstallPreparing = true; RefreshUpdateControls();
            try {
                string path = _pendingUpdatePath; UpdateReleaseInfo release = _pendingUpdateRelease;
                await Task.Run(() => ValidateDownloadedSetup(path, release));
                var start = new ProcessStartInfo(path, "/update " + Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture)) { UseShellExecute = true, Verb = "runas", WorkingDirectory = Path.GetDirectoryName(path) };
                using (Process setup = Process.Start(start)) { if (setup == null) throw new InvalidOperationException("The update installer could not start."); }
                _pendingUpdatePath = null; _pendingUpdateRelease = null;
                if (_updateStatus != null) _updateStatus.Text = "Setup is preparing the update…";
                _allowExit = true; Close();
            } catch (Exception ex) {
                MessageBox.Show(this, "SharkOptimizer could not check or install the GitHub update." + Environment.NewLine + Environment.NewLine + ex.Message, "SharkOptimizer updates", MessageBoxButton.OK, MessageBoxImage.Warning);
            } finally { _updateInstallPreparing = false; RefreshUpdateControls(); }
        }

        private async Task StopBackgroundUpdateDownloads()
        {
            _updateShutdown = true; if (_updateCheckTimer != null) _updateCheckTimer.Stop();
            if (_updateDownloadCancellation != null) _updateDownloadCancellation.Cancel();
            if (_updateWorkTask != null) { try { await _updateWorkTask; } catch { } }
            ClearPendingUpdate();
        }
    }
}
