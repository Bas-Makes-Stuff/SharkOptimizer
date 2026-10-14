using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace SharkOptimizer.NativeApp
{
    internal sealed class LivePingSample
    {
        public DateTime TimeUtc { get; set; }
        public double? LatencyMs { get; set; }
    }

    internal sealed class LivePingHistory
    {
        private readonly Queue<LivePingSample> _samples = new Queue<LivePingSample>();
        public string Host { get; private set; }
        public long Completed { get; private set; }
        public long Lost { get; private set; }
        public LivePingHistory(string host) { Host = NormalizeHost(host); }
        public LivePingSample[] Samples { get { return _samples.ToArray(); } }
        public double LossPercent { get { return Completed == 0 ? 0 : 100.0 * Lost / Completed; } }
        public double? Average { get { double[] values = Successful(); return values.Length == 0 ? (double?)null : values.Average(); } }
        public double? Minimum { get { double[] values = Successful(); return values.Length == 0 ? (double?)null : values.Min(); } }
        public double? Maximum { get { double[] values = Successful(); return values.Length == 0 ? (double?)null : values.Max(); } }
        public double? Jitter { get { double[] values = Successful(); if (values.Length < 2) return null; double total = 0; for (int i = 1; i < values.Length; i++) total += Math.Abs(values[i] - values[i - 1]); return total / (values.Length - 1); } }
        private double[] Successful() { return _samples.Where(x => x.LatencyMs.HasValue).Select(x => x.LatencyMs.Value).ToArray(); }
        public void Add(DateTime timeUtc, double? latency)
        {
            if (latency.HasValue && (Double.IsNaN(latency.Value) || Double.IsInfinity(latency.Value) || latency.Value < 0)) throw new ArgumentOutOfRangeException("latency");
            Completed++; if (!latency.HasValue) Lost++; _samples.Enqueue(new LivePingSample { TimeUtc = timeUtc.ToUniversalTime(), LatencyMs = latency }); while (_samples.Count > 60) _samples.Dequeue();
        }
        public string Csv()
        {
            var text = new StringBuilder("Host,TimeUTC,Success,LatencyMs\r\n");
            foreach (LivePingSample sample in _samples) text.Append(Host).Append(',').Append(sample.TimeUtc.ToString("o", CultureInfo.InvariantCulture)).Append(',').Append(sample.LatencyMs.HasValue ? "true" : "false").Append(',').Append(sample.LatencyMs.HasValue ? sample.LatencyMs.Value.ToString("0.###", CultureInfo.InvariantCulture) : "").Append("\r\n");
            return text.ToString();
        }
        internal static string NormalizeHost(string host)
        {
            host = (host ?? "").Trim(); IPAddress address; if (IPAddress.TryParse(host.Trim('[', ']'), out address)) return address.ToString();
            try { host = new IdnMapping().GetAscii(host.TrimEnd('.')); } catch { throw new ArgumentException("Enter a hostname or IP address without a URL, port, or command."); }
            if (host.Length == 0 || host.Length > 253 || host.Split('.').Any(x => !Regex.IsMatch(x, @"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"))) throw new ArgumentException("Enter a hostname or IP address without a URL, port, or command.");
            return host.ToLowerInvariant();
        }
    }

    internal sealed partial class MainWindow
    {
        private LivePingHistory _liveHistory;
        private Ping _livePinger;
        private DispatcherTimer _livePingTimer;
        private int _livePingGeneration;
        private bool _livePingBusy;
        private bool _livePingRunning;
        private IPAddress _livePingAddress;
        private TextBox _livePingHost;
        private Button _livePingStart, _livePingStop, _livePingExport;
        private Canvas _livePingGraph;
        private TextBlock _livePingStatus;
        private readonly Dictionary<string, TextBlock> _livePingValues = new Dictionary<string, TextBlock>();

        private UIElement BuildLivePingCard()
        {
            var card = Card(); var body = new StackPanel(); body.Children.Add(Text("Your connection, live", 20, Brushes.White, true));
            body.Children.Add(Text("Track latency over time. Use a game-server address or a host that answers ping. Some servers block ICMP, so a failed ping does not necessarily mean game traffic is dropping.", 11, Brush(MutedColor), false, 0, 5));
            var controls = new Grid { Margin = new Thickness(0, 12, 0, 12) }; controls.ColumnDefinitions.Add(new ColumnDefinition()); controls.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _livePingHost = new TextBox { Text = "1.1.1.1", Height = 38, Padding = new Thickness(10, 8, 10, 8), Background = Brush(SurfaceRaised), Foreground = Brushes.White, BorderBrush = Brush(BorderColor) }; controls.Children.Add(_livePingHost);
            Localization.KeepData(_livePingHost);
            var actions = new WrapPanel(); _livePingStart = ActionButton("Start live ping", true); _livePingStart.Click += async delegate { await StartLivePing(); };
            _livePingStop = ActionButton("Stop", false); _livePingStop.IsEnabled = false; _livePingStop.Click += delegate { StopLivePing(); };
            _livePingExport = ActionButton("Export CSV", false); _livePingExport.IsEnabled = false; _livePingExport.Click += delegate { ExportLivePing(); };
            actions.Children.Add(_livePingStart); actions.Children.Add(_livePingStop); actions.Children.Add(_livePingExport); Grid.SetColumn(actions, 1); controls.Children.Add(actions); body.Children.Add(controls);
            var stats = new Grid(); string[] labels = { "LATEST", "AVERAGE", "MIN / MAX", "JITTER", "LOSS" }; _livePingValues.Clear();
            for (int i = 0; i < labels.Length; i++) { stats.ColumnDefinitions.Add(new ColumnDefinition()); var group = new StackPanel { Margin = new Thickness(0, 0, 12, 0) }; group.Children.Add(Text(labels[i], 9, Brush(MutedColor), true)); var value = Text("—", 17, Brushes.White, true, 0, 5); _livePingValues.Add(labels[i], value); group.Children.Add(value); Grid.SetColumn(group, i); stats.Children.Add(group); } body.Children.Add(stats);
            _livePingGraph = new Canvas { Height = 160, ClipToBounds = true }; _livePingGraph.SizeChanged += delegate { RenderLivePing(); };
            body.Children.Add(new Border { Background = Brush(SurfaceRaised), CornerRadius = new CornerRadius(12), Padding = new Thickness(12), Margin = new Thickness(0, 12, 0, 0), Child = _livePingGraph });
            _livePingStatus = Text("No samples yet. Graph and latency statistics show the latest 60 samples; loss covers the full run.", 10, Brush(MutedColor), false, 0, 8); body.Children.Add(_livePingStatus); card.Child = body; RenderLivePing(); return card;
        }

        private async Task StartLivePing()
        {
            string host; try { host = LivePingHistory.NormalizeHost(_livePingHost.Text); } catch (Exception ex) { _livePingStatus.Text = ex.Message; return; }
            StopLivePing(); int generation = _livePingGeneration; _liveHistory = new LivePingHistory(host);
            _livePingStart.IsEnabled = false; _livePingStop.IsEnabled = true; _livePingHost.IsReadOnly = true; _livePingExport.IsEnabled = false; _livePingStatus.Text = "Resolving " + host + "…"; RenderLivePing();
            try
            {
                IPAddress address;
                if (!IPAddress.TryParse(host, out address))
                {
                    Task<IPAddress[]> lookup = Dns.GetHostAddressesAsync(host);
                    ObserveLookupFailure(lookup);
                    Task completed = await Task.WhenAny(lookup, Task.Delay(4000)); if (generation != _livePingGeneration) return;
                    if (completed != lookup) throw new TimeoutException("Hostname lookup exceeded four seconds.");
                    IPAddress[] addresses = await lookup; address = addresses.FirstOrDefault(x => x.AddressFamily == AddressFamily.InterNetwork) ?? addresses.FirstOrDefault();
                }
                if (generation != _livePingGeneration) return; if (address == null) throw new InvalidOperationException("The host has no usable IP address.");
                _livePingAddress = address; _livePinger = new Ping(); _livePingRunning = true;
                if (_livePingTimer == null) { _livePingTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) }; _livePingTimer.Tick += async delegate { await SampleLivePing(_livePingGeneration); }; }
                _livePingTimer.Start(); await SampleLivePing(generation);
            }
            catch (Exception ex) { if (generation == _livePingGeneration) { StopLivePing(); _livePingStatus.Text = "Could not start live ping: " + ex.GetBaseException().Message; } }
        }

        private async Task SampleLivePing(int generation)
        {
            if (!_livePingRunning || _livePingBusy || generation != _livePingGeneration) return; _livePingBusy = true; Ping pinger = _livePinger;
            try
            {
                double? latency = null; try { PingReply reply = await pinger.SendPingAsync(_livePingAddress, 900); if (reply.Status == IPStatus.Success) latency = reply.RoundtripTime; } catch { }
                if (!_livePingRunning || generation != _livePingGeneration) return;
                _liveHistory.Add(DateTime.UtcNow, latency); _livePingExport.IsEnabled = true; RenderLivePing();
                _livePingStatus.Text = "Live · " + _liveHistory.Host + " → " + _livePingAddress + " · " + _liveHistory.Completed + " completed samples · latest 60 plotted · loss across this run";
            }
            finally { if (generation == _livePingGeneration) _livePingBusy = false; }
        }

        private static void ObserveLookupFailure(Task<IPAddress[]> lookup)
        { lookup.ContinueWith(delegate(Task<IPAddress[]> failed) { var error = failed.Exception; }, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously); }

        private void StopLivePing()
        {
            _livePingGeneration++; _livePingRunning = false; _livePingBusy = false; if (_livePingTimer != null) _livePingTimer.Stop();
            if (_livePinger != null) { Ping previous = _livePinger; _livePinger = null; Task.Run(delegate { try { previous.SendAsyncCancel(); } catch { } finally { previous.Dispose(); } }); }
            if (_livePingStart != null) { _livePingStart.IsEnabled = true; _livePingStop.IsEnabled = false; _livePingHost.IsReadOnly = false; if (_liveHistory != null) _livePingStatus.Text = "Stopped · " + _liveHistory.Completed + " completed samples. Export keeps the latest 60 samples."; }
        }

        private static string PingValue(double? value)
        { return !value.HasValue ? "—" : value.Value < 1 ? "<1 ms" : value.Value.ToString("0.#", CultureInfo.CurrentCulture) + " ms"; }

        private void RenderLivePing()
        {
            if (_livePingGraph == null) return; _livePingGraph.Children.Clear(); double width = Math.Max(1, _livePingGraph.ActualWidth);
            LivePingSample[] samples = _liveHistory == null ? new LivePingSample[0] : _liveHistory.Samples;
            double ceiling = Math.Max(100, Math.Ceiling(((_liveHistory == null ? null : _liveHistory.Maximum) ?? 0) * 1.15 / 25) * 25);
            for (int i = 0; i < 4; i++) { double y = 10 + i * 46; _livePingGraph.Children.Add(new System.Windows.Shapes.Line { X1 = 0, X2 = width, Y1 = y, Y2 = y, Stroke = Brush(BorderColor), StrokeThickness = 1, StrokeDashArray = new DoubleCollection { 3, 5 } }); }
            var scale = Text(ceiling.ToString("0", CultureInfo.CurrentCulture) + " ms", 9, Brush(MutedColor), false); Canvas.SetRight(scale, 1); Canvas.SetTop(scale, 0); _livePingGraph.Children.Add(scale);
            if (samples.Length == 0) { var hint = Text("Start a live test to see your connection over time.", 11, Brush(MutedColor), false); hint.MaxWidth = Math.Max(20, width - 28); Canvas.SetLeft(hint, 14); Canvas.SetTop(hint, 65); _livePingGraph.Children.Add(hint); }
            System.Windows.Shapes.Polyline segment = null;
            for (int i = 0; i < samples.Length; i++)
            {
                double x = (60 - samples.Length + i) * Math.Max(1, width - 6) / 59;
                if (!samples[i].LatencyMs.HasValue) { segment = null; _livePingGraph.Children.Add(new System.Windows.Shapes.Line { X1 = x, X2 = x, Y1 = 144, Y2 = 152, Stroke = Brush(Color.FromRgb(255, 130, 130)), StrokeThickness = 2 }); continue; }
                double y = 150 - Math.Min(samples[i].LatencyMs.Value, ceiling) / ceiling * 138;
                if (segment == null) { segment = new System.Windows.Shapes.Polyline { Stroke = Brush(AccentColor), StrokeThickness = 2, StrokeLineJoin = PenLineJoin.Round }; _livePingGraph.Children.Add(segment); } segment.Points.Add(new Point(x, y));
                var point = new System.Windows.Shapes.Ellipse { Width = 4, Height = 4, Fill = Brush(AccentColor) }; Canvas.SetLeft(point, x - 2); Canvas.SetTop(point, y - 2); _livePingGraph.Children.Add(point);
            }
            if (_livePingValues.Count == 0) return;
            _livePingValues["LATEST"].Text = samples.Length == 0 ? "—" : samples.Last().LatencyMs.HasValue ? PingValue(samples.Last().LatencyMs) : "No reply";
            _livePingValues["AVERAGE"].Text = _liveHistory == null ? "—" : PingValue(_liveHistory.Average);
            _livePingValues["MIN / MAX"].Text = _liveHistory == null || !_liveHistory.Minimum.HasValue ? "—" : _liveHistory.Minimum.Value.ToString("0.#") + " / " + _liveHistory.Maximum.Value.ToString("0.#") + " ms";
            _livePingValues["JITTER"].Text = _liveHistory == null ? "—" : PingValue(_liveHistory.Jitter);
            _livePingValues["LOSS"].Text = _liveHistory == null || _liveHistory.Completed == 0 ? "—" : _liveHistory.LossPercent.ToString("0.#") + "%";
        }

        private void ExportLivePing()
        {
            if (_liveHistory == null || _liveHistory.Completed == 0) return; var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "Ping samples (*.csv)|*.csv", FileName = "SharkOptimizer-LivePing.csv" }; if (LocalizedFileDialog.Show(dialog, this) != true) return;
            try { File.WriteAllText(dialog.FileName, _liveHistory.Csv(), new UTF8Encoding(false)); } catch (Exception ex) { MessageBox.Show(this, ex.Message, "Ping export failed", MessageBoxButton.OK, MessageBoxImage.Warning); }
        }
    }
}
