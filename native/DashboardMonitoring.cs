using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private Path _cpuArc, _ramArc, _gpuArc;
        private Canvas _cpuHistoryCanvas;
        private readonly List<double> _dashboardCpuHistory = new List<double>();
        private static readonly Color CpuGaugeColor = Color.FromRgb(44, 220, 111);

        private UIElement BuildDashboardMonitoring()
        {
            var panel = new StackPanel();
            var cpu = Card(); cpu.Padding = new Thickness(17); cpu.CornerRadius = new CornerRadius(10);
            var cpuBody = new StackPanel(); var header = new DockPanel();
            _monitorStatus = Text(_previewMode ? "Preview" : "Waiting for readings", 9, Brush(MutedColor), false); DockPanel.SetDock(_monitorStatus, Dock.Right); header.Children.Add(_monitorStatus); header.Children.Add(Text("CPU", 10, Brush(MutedColor), true)); cpuBody.Children.Add(header);
            var cpuRow = new Grid { Margin = new Thickness(0, 14, 0, 6) }; cpuRow.ColumnDefinitions.Add(new ColumnDefinition()); cpuRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(124) });
            _cpuHistoryCanvas = new Canvas { Height = 124, ClipToBounds = true, Margin = new Thickness(0, 0, 16, 0), VerticalAlignment = VerticalAlignment.Center };
            _cpuHistoryCanvas.SizeChanged += delegate { DrawCpuHistory(); }; cpuRow.Children.Add(_cpuHistoryCanvas);
            var cpuGauge = Gauge(CpuGaugeColor, out _cpuReading, out _cpuArc); Grid.SetColumn(cpuGauge, 1); cpuRow.Children.Add(cpuGauge); cpuBody.Children.Add(cpuRow); cpuBody.Children.Add(Text("Across logical processors", 9, Brush(MutedColor), false)); cpu.Child = cpuBody; panel.Children.Add(cpu);
            var pair = new Grid(); pair.ColumnDefinitions.Add(new ColumnDefinition()); pair.ColumnDefinitions.Add(new ColumnDefinition());
            var gpu = Card(); gpu.CornerRadius = new CornerRadius(10); gpu.Padding = new Thickness(15); gpu.Margin = new Thickness(0, 0, 6, 10);
            var gpuBody = new StackPanel(); gpuBody.Children.Add(Text("GPU", 10, Brush(MutedColor), true)); var gpuGauge = Gauge(Color.FromRgb(71, 123, 255), out _gpuReading, out _gpuArc); gpuGauge.Margin = new Thickness(0, 9, 0, 6); gpuBody.Children.Add(gpuGauge); gpuBody.Children.Add(Text("Busiest reported engine", 9, Brush(MutedColor), false)); gpu.Child = gpuBody; pair.Children.Add(gpu);
            var ram = Card(); ram.CornerRadius = new CornerRadius(10); ram.Padding = new Thickness(15); ram.Margin = new Thickness(6, 0, 0, 10);
            var ramBody = new StackPanel(); ramBody.Children.Add(Text("MEMORY", 10, Brush(MutedColor), true)); var ramGauge = Gauge(Color.FromRgb(255, 169, 48), out _ramReading, out _ramArc); ramGauge.Margin = new Thickness(0, 9, 0, 6); ramBody.Children.Add(ramGauge); _ramDetail = Text("Physical RAM in use", 9, Brush(MutedColor), false); ramBody.Children.Add(_ramDetail); ram.Child = ramBody; Grid.SetColumn(ram, 1); pair.Children.Add(ram); panel.Children.Add(pair);
            panel.Children.Add(Text("Readings refresh while this page is visible. Driver-dependent GPU data may be unavailable.", 9, Brush(MutedColor), false));
            panel.IsVisibleChanged += delegate { RefreshMonitoringVisibility(); }; panel.Loaded += delegate { RefreshMonitoringVisibility(); }; DrawCpuHistory(); return panel;
        }

        private Grid Gauge(Color color, out TextBlock reading, out Path arc)
        {
            var grid = new Grid { Width = 108, Height = 108, HorizontalAlignment = HorizontalAlignment.Center };
            grid.Children.Add(new Ellipse { Width = 86, Height = 86, StrokeThickness = 6, Stroke = Brush(Color.FromRgb(44, 59, 78)) });
            arc = new Path { Stroke = Brush(color), StrokeThickness = 6, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, IsHitTestVisible = false };
            grid.Children.Add(arc); reading = Text("—", 22, Brushes.White, true); reading.HorizontalAlignment = HorizontalAlignment.Center; reading.VerticalAlignment = VerticalAlignment.Center; grid.Children.Add(reading); return grid;
        }

        private static void SetGauge(Path arc, double value)
        {
            if (arc == null) return;
            if (Double.IsNaN(value) || Double.IsInfinity(value) || value <= 0 || value > 100) { arc.Data = null; return; }
            double fraction = Math.Min(value, 99.999) / 100, angle = fraction * Math.PI * 2 - Math.PI / 2;
            var shape = new StreamGeometry(); using (StreamGeometryContext context = shape.Open()) {
                context.BeginFigure(new Point(54, 11), false, false);
                context.ArcTo(new Point(54 + 43 * Math.Cos(angle), 54 + 43 * Math.Sin(angle)), new Size(43, 43), 0, fraction > .5, SweepDirection.Clockwise, true, false);
            }
            shape.Freeze(); arc.Data = shape;
        }

        private void UpdateDashboardGauges(SystemSample sample)
        {
            SetGauge(_cpuArc, sample.Cpu); SetGauge(_ramArc, sample.Ram); SetGauge(_gpuArc, sample.Gpu);
            if (!Double.IsNaN(sample.Cpu) && !Double.IsInfinity(sample.Cpu) && sample.Cpu >= 0 && sample.Cpu <= 100) {
                _dashboardCpuHistory.Add(sample.Cpu); if (_dashboardCpuHistory.Count > 40) _dashboardCpuHistory.RemoveAt(0); DrawCpuHistory();
            }
        }

        private void DrawCpuHistory()
        {
            if (_cpuHistoryCanvas == null) return;
            double width = _cpuHistoryCanvas.ActualWidth, height = _cpuHistoryCanvas.Height;
            if (width <= 0) return; _cpuHistoryCanvas.Children.Clear();
            for (int i = 1; i < 4; i++) _cpuHistoryCanvas.Children.Add(new Line { X1 = 0, X2 = width, Y1 = height * i / 4, Y2 = height * i / 4, Stroke = Brush(BorderColor), StrokeThickness = 1, Opacity = .4 });
            if (_dashboardCpuHistory.Count < 2) return;
            var points = new PointCollection(); for (int i = 0; i < _dashboardCpuHistory.Count; i++) points.Add(new Point(width * i / (_dashboardCpuHistory.Count - 1), height * (1 - _dashboardCpuHistory[i] / 100)));
            var area = new PointCollection(points); area.Insert(0, new Point(0, height)); area.Add(new Point(width, height));
            _cpuHistoryCanvas.Children.Add(new Polygon { Points = area, Fill = new LinearGradientBrush(Color.FromArgb(45, CpuGaugeColor.R, CpuGaugeColor.G, CpuGaugeColor.B), Colors.Transparent, 90) });
            _cpuHistoryCanvas.Children.Add(new Polyline { Points = points, Stroke = Brush(CpuGaugeColor), StrokeThickness = 1.5, StrokeLineJoin = PenLineJoin.Round });
        }
    }
}
