# SharkOptimizer launcher: animated loading screen, requirement checks, one admin prompt, clear error report.
# Keep this file in the same folder as SharkOptimizer.ps1. Start it with Start-SharkOptimizer.cmd.
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Main = Join-Path $Root 'SharkOptimizer.ps1'
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
function Show-Msg($text, $icon = 'Error') { [void][Windows.MessageBox]::Show($text, 'SharkOptimizer', 'OK', $icon) }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try { Start-Process $PsExe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`"" }
    catch { Show-Msg 'SharkOptimizer needs administrator rights to change Windows settings. Please accept the prompt next time.' 'Warning' }
    exit
}

$problems = @()
if ($PSVersionTable.PSVersion -lt [version]'5.1') { $problems += 'Windows PowerShell 5.1 or newer is required.' }
if ([Environment]::OSVersion.Version.Build -lt 10240) { $problems += 'Windows 10 or Windows 11 is required.' }
if (-not (Test-Path $Main)) { $problems += 'SharkOptimizer.ps1 was not found. Keep it in the same folder as this launcher.' }
if ($problems.Count) { Show-Msg ("SharkOptimizer cannot start:`n`n- " + ($problems -join "`n- ")); exit }
Get-ChildItem $Root -Filter *.ps1 -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

if (-not ('WinFind' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class WinFind {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    public static bool HasVisibleWindow(int pid, string prefix) {
        bool found = false;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == (uint)pid && IsWindowVisible(h)) {
                StringBuilder sb = new StringBuilder(256); GetWindowText(h, sb, 256);
                if (sb.ToString().StartsWith(prefix)) found = true;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
  Title="SharkOptimizer" Width="440" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
  WindowStartupLocation="CenterScreen" Topmost="True" ResizeMode="NoResize" FontFamily="Segoe UI">
 <Window.Resources>
  <DrawingImage x:Key="SharkIcon"><DrawingImage.Drawing><DrawingGroup>
   <GeometryDrawing Geometry="M0,0 H48 V48 H0 Z"><GeometryDrawing.Brush><SolidColorBrush Color="#00000000"/></GeometryDrawing.Brush></GeometryDrawing>
   <GeometryDrawing Geometry="M2,30 C9,15 25,10 40,18 L47,9 L45,24 L47,37 L38,31 C28,39 12,38 2,30 Z M19,17 L25,3 L31,15 Z M30,33 L34,41 L24,35 Z"><GeometryDrawing.Brush><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#5BE3FF" Offset="0"/><GradientStop Color="#1B7BFF" Offset="1"/></LinearGradientBrush></GeometryDrawing.Brush></GeometryDrawing>
   <GeometryDrawing Brush="White" Geometry="M10,24 A1.8,1.8 0 1 1 13.6,24 A1.8,1.8 0 1 1 10,24 Z"/>
  </DrawingGroup></DrawingImage.Drawing></DrawingImage>
  <Style TargetType="Button"><Setter Property="Foreground" Value="#E8ECF4"/><Setter Property="Background" Value="#16233A"/><Setter Property="Margin" Value="4"/><Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="14,7"><ContentPresenter HorizontalAlignment="Center"/></Border></ControlTemplate></Setter.Value></Setter></Style>
 </Window.Resources>
 <Border Margin="10" CornerRadius="22" Background="#0B1424" BorderBrush="#1A2943" BorderThickness="1" Padding="30,28,30,24">
  <StackPanel HorizontalAlignment="Center">
   <Image x:Name="logo" Source="{StaticResource SharkIcon}" Width="92" Height="92" RenderTransformOrigin="0.5,0.5"/>
   <TextBlock Text="SharkOptimizer" Foreground="White" FontSize="27" FontWeight="Black" HorizontalAlignment="Center" Margin="0,14,0,0"/>
   <TextBlock Text="Tune Windows for gaming" Foreground="#7F8FAE" FontSize="12.5" HorizontalAlignment="Center" Margin="0,2,0,22"/>
   <Border x:Name="track" Width="300" Height="6" CornerRadius="3" Background="#1E2B45" ClipToBounds="True">
    <Border x:Name="bar" Width="110" CornerRadius="3" HorizontalAlignment="Left" RenderTransformOrigin="0,0.5">
     <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#1B7BFF" Offset="0"/><GradientStop Color="#5BE3FF" Offset="1"/></LinearGradientBrush></Border.Background>
    </Border>
   </Border>
   <TextBlock x:Name="status" Text="Starting..." Foreground="#1FB6FF" FontSize="12.5" HorizontalAlignment="Center" Margin="0,14,0,0"/>
   <StackPanel x:Name="errPanel" Visibility="Collapsed" Margin="0,14,0,0">
    <TextBox x:Name="errBox" Height="120" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="11.5" Background="#0F1A2C" Foreground="#FF9C9C" BorderBrush="#1E2E4B"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,8,0,0">
     <Button x:Name="btnCopy" Content="Copy details"/><Button x:Name="btnLogs" Content="Open logs"/><Button x:Name="btnClose" Content="Close" Background="#1FB6FF" Foreground="#06121F"/>
    </StackPanel>
   </StackPanel>
  </StackPanel>
 </Border>
</Window>
'@
$splash = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
$splash.Icon = $splash.FindResource('SharkIcon')
$logo = $splash.FindName('logo'); $bar = $splash.FindName('bar'); $status = $splash.FindName('status')
$errPanel = $splash.FindName('errPanel'); $errBox = $splash.FindName('errBox')

$logDir = Join-Path $env:ProgramData 'SharkOptimizer'; New-Item $logDir -ItemType Directory -Force | Out-Null
$outFile = Join-Path $logDir 'launch-output.txt'; $errFile = Join-Path $logDir 'launch-error.txt'; $inFile = Join-Path $logDir 'empty-input.txt'
'' | Set-Content $inFile; Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue

function New-Anim($from, $to, $sec, $forever = $false, $auto = $false) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation; $a.From = $from; $a.To = $to
    $a.Duration = [Windows.Duration]::new([TimeSpan]::FromSeconds($sec))
    $e = New-Object Windows.Media.Animation.SineEase; $e.EasingMode = 'EaseInOut'; $a.EasingFunction = $e
    if ($forever) { $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever }
    $a.AutoReverse = $auto; $a
}
$tt = New-Object Windows.Media.TranslateTransform; $rt = New-Object Windows.Media.RotateTransform
$tg = New-Object Windows.Media.TransformGroup; [void]$tg.Children.Add($rt); [void]$tg.Children.Add($tt); $logo.RenderTransform = $tg
$bt = New-Object Windows.Media.TranslateTransform; $bar.RenderTransform = $bt

$splash.Add_ContentRendered({
    $splash.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Anim 0 1 0.4))
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-Anim -6 6 1.1 $true $true))
    $rt.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, (New-Anim -5 5 1.6 $true $true))
    $bt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, (New-Anim -110 300 1.5 $true $false))
})
$splash.Add_MouseLeftButtonDown({ try { $splash.DragMove() } catch {} })
$splash.Add_KeyDown({ if ($_.Key -eq 'Escape') { $splash.Close() } })

$proc = Start-Process $PsExe -PassThru -WindowStyle Hidden -WorkingDirectory $Root `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile -RedirectStandardInput $inFile `
    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$Main`""

$messages = @('Checking requirements...', 'Starting SharkOptimizer...', 'Detecting your hardware...', 'Loading tweaks...', 'Preparing game profiles...', 'Almost ready...')
$script:msgIdx = 0; $script:done = $false; $started = Get-Date
$status.Text = $messages[0]

function Show-Failure($title) {
    $script:done = $true
    $bt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $null)
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null); $rt.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null)
    $bar.Visibility = 'Collapsed'
    $status.Text = $title; $status.Foreground = [Windows.Media.Brushes]::Orange
    $detail = ''
    foreach ($f in $errFile, $outFile) { if (Test-Path $f) { $t = (Get-Content $f -Raw -ErrorAction SilentlyContinue); if ($t) { $detail += $t.Trim() + "`r`n" } } }
    if (-not $detail) { $detail = 'No error text was captured. Open the logs folder for more information.' }
    $errBox.Text = "SharkOptimizer $((Get-Item $Main).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))  |  Windows build $([Environment]::OSVersion.Version.Build)  |  PowerShell $($PSVersionTable.PSVersion)`r`n`r`n$detail"
    $errPanel.Visibility = 'Visible'
}
$splash.FindName('btnCopy').Add_Click({ [Windows.Clipboard]::SetText($errBox.Text) })
$splash.FindName('btnLogs').Add_Click({ Start-Process explorer.exe $logDir })
$splash.FindName('btnClose').Add_Click({ $splash.Close() })

$timer = New-Object Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:tick = 0
$timer.Add_Tick({
    if ($script:done) { return }
    $script:tick++
    if ($script:tick % 4 -eq 0 -and $script:msgIdx -lt $messages.Count - 1) { $script:msgIdx++; $status.Text = $messages[$script:msgIdx] }
    if ([WinFind]::HasVisibleWindow($proc.Id, 'SharkOptimizer')) {
        $script:done = $true; $timer.Stop(); $status.Text = 'Ready'
        $fade = New-Anim 1 0 0.35; $fade.Add_Completed({ $splash.Close() })
        $splash.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
    }
    elseif ($proc.HasExited) { $timer.Stop(); Show-Failure 'SharkOptimizer stopped while starting.' }
    elseif (((Get-Date) - $started).TotalSeconds -gt 120) { $timer.Stop(); Show-Failure 'SharkOptimizer is taking too long to start.' }
})
$timer.Start()
[void]$splash.ShowDialog()
