using System;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using SharkOptimizer.Platform;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private bool _startupRecoveryStarted;
        private async Task RecoverOnFirstOpen()
        {
            if (_startupRecoveryStarted) return;
            _startupRecoveryStarted = true;
            await RecoverMaintenanceServices();
            await RecoverInterruptedSession();
            if (_state.ScanOnStart) await ScanGamesAsync(true);
        }
        internal void OpenFromShortcut() { RestoreFromTray(); }
        internal void StartInTray()
        {
            ShowInTaskbar = false;
            if (_trayIcon != null) _trayIcon.Visible = true;
            Dispatcher.BeginInvoke(new Action(async delegate { await RecoverOnFirstOpen(); }));
        }

        private UIElement BuildStartupCard()
        {
            var card = Card(); var body = new StackPanel(); body.Children.Add(Text("Windows startup", 15, Brushes.White, true));
            body.Children.Add(Text("Start SharkOptimizer in the tray when you sign in. Open it from the tray icon or your shortcut. Installation enables this by default.", 11, Brush(MutedColor), false, 0, 5));
            var status = Text("Reading startup setting…", 10, Brush(MutedColor), false, 0, 9); body.Children.Add(status);
            var buttons = new WrapPanel { Margin = new Thickness(-5, 8, 0, 0) }; var enable = ActionButton("Enable tray startup", false); var disable = ActionButton("Disable startup", false); buttons.Children.Add(enable); buttons.Children.Add(disable); body.Children.Add(buttons);
            Func<Task> refresh = async delegate { try { bool on = await Task.Run(new Func<bool>(StartupRegistration.IsEnabled)); status.Text = on ? "Tray startup is enabled for this Windows account." : "Tray startup is off."; enable.IsEnabled = !on; disable.IsEnabled = on; } catch (Exception ex) { status.Text = "Could not read startup registration: " + ex.Message; enable.IsEnabled = true; disable.IsEnabled = true; } };
            enable.Click += async delegate { enable.IsEnabled = disable.IsEnabled = false; Exception error = null; try { await Task.Run(delegate { StartupRegistration.Enable(Assembly.GetExecutingAssembly().Location); }); } catch (Exception ex) { error = ex; } await refresh(); if (error != null) status.Text = "Could not enable startup: " + error.Message; };
            disable.Click += async delegate { enable.IsEnabled = disable.IsEnabled = false; Exception error = null; try { await Task.Run(new Action(StartupRegistration.Disable)); } catch (Exception ex) { error = ex; } await refresh(); if (error != null) status.Text = "Could not disable startup: " + error.Message; };
            if (!_previewMode) body.Loaded += async delegate { await refresh(); }; else status.Text = "Startup registration is not queried in previews.";
            card.Child = body; return card;
        }
    }
}
