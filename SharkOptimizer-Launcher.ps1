# SharkOptimizer launcher v2: animated loading screen (shark, bubbles, waves), requirement checks, one admin prompt, clear error report.
# Keep this file in the same folder as SharkOptimizer.ps1. Start it with Start-SharkOptimizer.cmd.
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Main = Join-Path $Root 'SharkOptimizer.ps1'
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
trap {
    $m = "Launcher error: $($_.Exception.Message)`r`n$($_.InvocationInfo.PositionMessage)"
    try { New-Item (Join-Path $env:ProgramData 'SharkOptimizer') -ItemType Directory -Force | Out-Null; Set-Content (Join-Path $env:ProgramData 'SharkOptimizer\launcher-crash.txt') $m } catch {}
    try { [void][Windows.MessageBox]::Show($m + "`r`n`r`nSharkOptimizer will now start without the loading screen.", 'SharkOptimizer launcher', 'OK', 'Error') } catch {}
    try { if ((Test-Path $Main) -and (-not $proc -or $proc.HasExited)) { Start-Process $PsExe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$Main`"" } } catch {}
    exit 1
}
function Show-Msg($text, $icon = 'Error') { [void][Windows.MessageBox]::Show($text, 'SharkOptimizer', 'OK', $icon) }

# ---- 1. one admin prompt
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try { Start-Process $PsExe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`"" }
    catch { Show-Msg 'SharkOptimizer needs administrator rights to change Windows settings. Please accept the prompt next time.' 'Warning' }
    exit
}

# ---- 2. requirement checks
$problems = @()
if ($PSVersionTable.PSVersion -lt [version]'5.1') { $problems += 'Windows PowerShell 5.1 or newer is required.' }
if ([Environment]::OSVersion.Version.Build -lt 10240) { $problems += 'Windows 10 or Windows 11 is required.' }
if (-not (Test-Path $Main)) { $problems += 'SharkOptimizer.ps1 was not found. Keep it in the same folder as this launcher.' }
if ($problems.Count) { Show-Msg ("SharkOptimizer cannot start:`n`n- " + ($problems -join "`n- ")); exit }
Get-ChildItem $Root -Filter *.ps1 -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# ---- window finder (is the app window visible yet?)
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

# ---- 3. language, accent colour and version (read from the app's settings)
$DataDir = Join-Path $env:ProgramData 'SharkOptimizer'
$lang = 'en'; $accent = '#1FB6FF'; $ver = ''
$codes = 'nl', 'es', 'de', 'fr', 'pt', 'ru', 'zh'
try {
    $cc = (Get-UICulture).TwoLetterISOLanguageName
    if ($codes -contains $cc) { $lang = $cc }
    $sf = Join-Path $DataDir 'settings.json'
    if (Test-Path $sf) {
        $st = Get-Content $sf -Raw | ConvertFrom-Json
        if ($st.Language -and (($codes + 'en') -contains [string]$st.Language)) { $lang = [string]$st.Language }
        $accMap = @{ blue = '#1FB6FF'; green = '#22D3A6'; purple = '#A78BFA'; orange = '#FF9F1A' }
        if ($st.Accent -and $accMap.ContainsKey([string]$st.Accent)) { $accent = $accMap[[string]$st.Accent] }
    }
    $vm = [regex]::Match([IO.File]::ReadAllText($Main), "\`$AppVer = '([0-9][0-9.]*)'")
    if ($vm.Success) { $ver = 'v' + $vm.Groups[1].Value }
} catch {}
function Mix-White($hex, $t) {
    $c = [Windows.Media.ColorConverter]::ConvertFromString($hex)
    '#{0:X2}{1:X2}{2:X2}' -f [int]($c.R + (255 - $c.R) * $t), [int]($c.G + (255 - $c.G) * $t), [int]($c.B + (255 - $c.B) * $t)
}
$accent2 = Mix-White $accent 0.45

$TT = @{
 en = @('Checking requirements...', 'Starting SharkOptimizer...', 'Detecting your hardware...', 'Loading tweaks...', 'Preparing game profiles...', 'Almost ready...', 'Tune Windows for gaming', 'Ready', 'SharkOptimizer stopped while starting.', 'SharkOptimizer is taking too long to start.', 'Copy details', 'Open logs', 'Close')
 nl = @('Vereisten controleren...', 'SharkOptimizer starten...', 'Je hardware detecteren...', 'Tweaks laden...', 'Gameprofielen voorbereiden...', 'Bijna klaar...', 'Stem Windows af op gamen', 'Klaar', 'SharkOptimizer stopte tijdens het starten.', 'SharkOptimizer start te langzaam.', 'Details kopiëren', 'Logs openen', 'Sluiten')
 es = @('Comprobando requisitos...', 'Iniciando SharkOptimizer...', 'Detectando tu hardware...', 'Cargando ajustes...', 'Preparando perfiles de juegos...', 'Casi listo...', 'Optimiza Windows para jugar', 'Listo', 'SharkOptimizer se detuvo al iniciar.', 'SharkOptimizer tarda demasiado en iniciar.', 'Copiar detalles', 'Abrir registros', 'Cerrar')
 de = @('Anforderungen werden geprüft...', 'SharkOptimizer wird gestartet...', 'Hardware wird erkannt...', 'Tweaks werden geladen...', 'Spielprofile werden vorbereitet...', 'Fast fertig...', 'Windows fürs Gaming optimieren', 'Bereit', 'SharkOptimizer wurde beim Start beendet.', 'SharkOptimizer startet zu langsam.', 'Details kopieren', 'Protokolle öffnen', 'Schließen')
 fr = @('Vérification de la configuration...', 'Démarrage de SharkOptimizer...', 'Détection de votre matériel...', 'Chargement des réglages...', 'Préparation des profils de jeux...', 'Presque prêt...', 'Optimisez Windows pour le jeu', 'Prêt', "SharkOptimizer s'est arrêté au démarrage.", 'SharkOptimizer met trop de temps à démarrer.', 'Copier les détails', 'Ouvrir les journaux', 'Fermer')
 pt = @('Verificando requisitos...', 'Iniciando o SharkOptimizer...', 'Detectando seu hardware...', 'Carregando ajustes...', 'Preparando perfis de jogos...', 'Quase pronto...', 'Otimize o Windows para jogar', 'Pronto', 'O SharkOptimizer parou ao iniciar.', 'O SharkOptimizer está demorando para iniciar.', 'Copiar detalhes', 'Abrir registros', 'Fechar')
 ru = @('Проверка требований...', 'Запуск SharkOptimizer...', 'Определение вашего оборудования...', 'Загрузка твиков...', 'Подготовка игровых профилей...', 'Почти готово...', 'Настройте Windows для игр', 'Готово', 'SharkOptimizer остановился при запуске.', 'SharkOptimizer запускается слишком долго.', 'Копировать данные', 'Открыть журналы', 'Закрыть')
 zh = @('正在检查运行要求...', '正在启动 SharkOptimizer...', '正在检测你的硬件...', '正在加载优化项...', '正在准备游戏配置...', '马上就好...', '为游戏优化 Windows', '已就绪', 'SharkOptimizer 在启动时停止了。', 'SharkOptimizer 启动时间过长。', '复制详情', '打开日志', '关闭')
}
$S = $TT[$lang]

# ---- 4. splash window
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
  Title="SharkOptimizer" Width="460" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
  WindowStartupLocation="CenterScreen" Topmost="True" ResizeMode="NoResize" FontFamily="Segoe UI">
 <Window.Resources>
  <DrawingImage x:Key="SharkIcon"><DrawingImage.Drawing><DrawingGroup>
   <GeometryDrawing Geometry="M0,0 H48 V48 H0 Z"><GeometryDrawing.Brush><SolidColorBrush Color="#00000000"/></GeometryDrawing.Brush></GeometryDrawing>
   <GeometryDrawing Geometry="__SHARK__"><GeometryDrawing.Brush><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="__ACC2__" Offset="0"/><GradientStop Color="__ACC__" Offset="1"/></LinearGradientBrush></GeometryDrawing.Brush></GeometryDrawing>
   <GeometryDrawing Brush="White" Geometry="M10,24 A1.8,1.8 0 1 1 13.6,24 A1.8,1.8 0 1 1 10,24 Z"/>
  </DrawingGroup></DrawingImage.Drawing></DrawingImage>
  <Style TargetType="Button"><Setter Property="Foreground" Value="#E8ECF4"/><Setter Property="Background" Value="#16233A"/><Setter Property="Margin" Value="4"/><Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="14,7"><ContentPresenter HorizontalAlignment="Center"/></Border></ControlTemplate></Setter.Value></Setter></Style>
 </Window.Resources>
 <Border Margin="12" CornerRadius="24" BorderBrush="#1A2943" BorderThickness="1" MinHeight="350">
  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#0E1A33" Offset="0"/><GradientStop Color="#08101D" Offset="1"/></LinearGradientBrush></Border.Background>
  <Grid>
   <Canvas x:Name="bubbles" Width="400" Height="350" HorizontalAlignment="Center" VerticalAlignment="Top" IsHitTestVisible="False" ClipToBounds="True"/>
   <Canvas x:Name="waves" Width="392" Height="46" HorizontalAlignment="Center" VerticalAlignment="Bottom" IsHitTestVisible="False" ClipToBounds="True">
    <Canvas.OpacityMask><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#00000000" Offset="0"/><GradientStop Color="#FF000000" Offset="0.18"/><GradientStop Color="#FF000000" Offset="0.82"/><GradientStop Color="#00000000" Offset="1"/></LinearGradientBrush></Canvas.OpacityMask>
   </Canvas>
   <StackPanel HorizontalAlignment="Center" Margin="30,30,30,28">
    <Grid Width="150" Height="124" HorizontalAlignment="Center">
     <Ellipse x:Name="glow" Width="150" Height="150" RenderTransformOrigin="0.5,0.5">
      <Ellipse.Fill><RadialGradientBrush><GradientStop Color="#55__ACCRAW__" Offset="0"/><GradientStop Color="#00__ACCRAW__" Offset="1"/></RadialGradientBrush></Ellipse.Fill>
     </Ellipse>
     <Image x:Name="logo" Source="{StaticResource SharkIcon}" Width="98" Height="98" RenderTransformOrigin="0.5,0.5"/>
    </Grid>
    <TextBlock Text="SharkOptimizer" Foreground="White" FontSize="28" FontWeight="Black" HorizontalAlignment="Center" Margin="0,6,0,0"/>
    <TextBlock x:Name="tag" Foreground="#7F8FAE" FontSize="12.5" HorizontalAlignment="Center" Margin="0,2,0,0"/>
    <TextBlock x:Name="verTxt" Foreground="#4A5A78" FontSize="11" HorizontalAlignment="Center" Margin="0,2,0,18"/>
    <Border x:Name="track" Width="320" Height="6" CornerRadius="3" Background="#1E2B45" ClipToBounds="True">
     <Border x:Name="bar" Width="120" CornerRadius="3" HorizontalAlignment="Left" RenderTransformOrigin="0,0.5">
      <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="__ACC__" Offset="0"/><GradientStop Color="__ACC2__" Offset="1"/></LinearGradientBrush></Border.Background>
     </Border>
    </Border>
    <TextBlock x:Name="status" Foreground="__ACC__" FontSize="12.5" HorizontalAlignment="Center" Margin="0,14,0,0"/>
    <StackPanel x:Name="dots" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,10,0,0"/>
    <StackPanel x:Name="errPanel" Visibility="Collapsed" Margin="0,14,0,0">
     <TextBox x:Name="errBox" Height="120" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="11.5" Background="#0F1A2C" Foreground="#FF9C9C" BorderBrush="#1E2E4B"/>
     <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,8,0,0">
      <Button x:Name="btnCopy"/><Button x:Name="btnLogs"/><Button x:Name="btnClose" Background="__ACC__" Foreground="#06121F"/>
     </StackPanel>
    </StackPanel>
   </StackPanel>
  </Grid>
 </Border>
</Window>
'@
$accRaw = $accent.TrimStart('#')
$xaml = $xaml.Replace('__ACCRAW__', $accRaw).Replace('__ACC2__', $accent2).Replace('__ACC__', $accent).Replace('__SHARK__', 'M2,30 C9,15 25,10 40,18 L47,9 L45,24 L47,37 L38,31 C28,39 12,38 2,30 Z M19,17 L25,3 L31,15 Z M30,33 L34,41 L24,35 Z')
$splash = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
$splash.Icon = $splash.FindResource('SharkIcon')
try {
    $fr = Join-Path $Root 'fonts\Poppins-Regular.ttf'
    if (Test-Path $fr) { $splash.FontFamily = New-Object Windows.Media.FontFamily((New-Object Uri(((Resolve-Path (Join-Path $Root 'fonts')).Path.TrimEnd('\') + '\'))), './#Poppins') }
} catch {}
foreach ($n in 'logo','glow','bar','status','tag','verTxt','dots','errPanel','errBox','bubbles','waves') { Set-Variable -Name ('u_' + $n) -Value $splash.FindName($n) }
$u_tag.Text = $S[6]; $u_verTxt.Text = $ver
$splash.FindName('btnCopy').Content = $S[10]; $splash.FindName('btnLogs').Content = $S[11]; $splash.FindName('btnClose').Content = $S[12]

$logDir = $DataDir; New-Item $logDir -ItemType Directory -Force | Out-Null
$outFile = Join-Path $logDir 'launch-output.txt'; $errFile = Join-Path $logDir 'launch-error.txt'; $inFile = Join-Path $logDir 'empty-input.txt'
'' | Set-Content $inFile; Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue

function New-Anim($from, $to, $sec, $forever = $false, $auto = $false, $begin = 0) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation; $a.From = $from; $a.To = $to
    $a.Duration = [Windows.Duration]::new([TimeSpan]::FromSeconds($sec))
    $e = New-Object Windows.Media.Animation.SineEase; $e.EasingMode = 'EaseInOut'; $a.EasingFunction = $e
    if ($forever) { $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever }
    $a.AutoReverse = $auto; if ($begin -gt 0) { $a.BeginTime = [TimeSpan]::FromSeconds($begin) }; $a
}
function New-Linear($from, $to, $sec, $begin = 0) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation; $a.From = $from; $a.To = $to
    $a.Duration = [Windows.Duration]::new([TimeSpan]::FromSeconds($sec)); $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    if ($begin -gt 0) { $a.BeginTime = [TimeSpan]::FromSeconds($begin) }; $a
}
$bc = [Windows.Media.BrushConverter]::new()
# logo transforms
$tt = New-Object Windows.Media.TranslateTransform; $rt = New-Object Windows.Media.RotateTransform
$tg = New-Object Windows.Media.TransformGroup; [void]$tg.Children.Add($rt); [void]$tg.Children.Add($tt); $u_logo.RenderTransform = $tg
$bt = New-Object Windows.Media.TranslateTransform; $u_bar.RenderTransform = $bt
$gs = New-Object Windows.Media.ScaleTransform; $u_glow.RenderTransform = $gs
# bubbles
$rnd = New-Object Random 7
$bubbleList = @()
for ($i = 0; $i -lt 12; $i++) {
    $size = 4 + $rnd.Next(0, 7)
    $el = New-Object Windows.Shapes.Ellipse; $el.Width = $size; $el.Height = $size
    $c = [Windows.Media.ColorConverter]::ConvertFromString($accent); $c.A = 90
    $el.Fill = New-Object Windows.Media.SolidColorBrush($c)
    [Windows.Controls.Canvas]::SetLeft($el, 30 + $rnd.Next(0, 340)); [Windows.Controls.Canvas]::SetTop($el, 360)
    [void]$u_bubbles.Children.Add($el)
    $bubbleList += , @($el, (4 + $rnd.NextDouble() * 4), ($rnd.NextDouble() * 4))
}
# waves (two layers, seamless loop)
function New-Wave($w, $amp, $period, $y0, $alpha) {
    $pts = New-Object Windows.Media.PointCollection; $total = $w * 3
    for ($x = 0; $x -le $total; $x += 8) { [void]$pts.Add(([Windows.Point]::new($x, $y0 + $amp * [math]::Sin(2 * [math]::PI * $x / $period)))) }
    [void]$pts.Add(([Windows.Point]::new($total, 60))); [void]$pts.Add(([Windows.Point]::new(0, 60)))
    $pg = New-Object Windows.Shapes.Polygon; $pg.Points = $pts
    $c = [Windows.Media.ColorConverter]::ConvertFromString($accent); $c.A = $alpha
    $pg.Fill = New-Object Windows.Media.SolidColorBrush($c); $pg
}
$waveW = 392
$wave1 = New-Wave $waveW 5 $waveW 24 38; $wave2 = New-Wave $waveW 7 ($waveW / 2) 30 26
$w1t = New-Object Windows.Media.TranslateTransform; $w2t = New-Object Windows.Media.TranslateTransform
$wave1.RenderTransform = $w1t; $wave2.RenderTransform = $w2t
[void]$u_waves.Children.Add($wave2); [void]$u_waves.Children.Add($wave1)
# progress dots
$dotEls = @()
for ($i = 0; $i -lt 6; $i++) {
    $d = New-Object Windows.Shapes.Ellipse; $d.Width = 7; $d.Height = 7; $d.Margin = '4,0'; $d.Fill = $bc.ConvertFromString('#26324D')
    [void]$u_dots.Children.Add($d); $dotEls += $d
}
function Set-Dots($idx) {
    for ($i = 0; $i -lt $dotEls.Count; $i++) {
        $dotEls[$i].Fill = if ($i -eq $idx) { $bc.ConvertFromString($accent) } elseif ($i -lt $idx) { $bc.ConvertFromString($accent2) } else { $bc.ConvertFromString('#26324D') }
    }
}

$splash.Add_ContentRendered({
    $splash.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Anim 0 1 0.45))
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-Anim -6 6 1.2 $true $true))
    $rt.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, (New-Anim -5 5 1.7 $true $true))
    $bt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, (New-Anim -120 320 1.5 $true $false))
    $gs.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-Anim 0.88 1.12 1.6 $true $true))
    $gs.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-Anim 0.88 1.12 1.6 $true $true))
    $u_glow.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Anim 0.55 1 1.6 $true $true))
    $w1t.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, (New-Linear 0 (-$waveW) 6))
    $w2t.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, (New-Linear 0 (-$waveW) 9))
    foreach ($b in $bubbleList) { $b[0].BeginAnimation([Windows.Controls.Canvas]::TopProperty, (New-Linear 360 -14 $b[1] $b[2])) }
})
$splash.Add_MouseLeftButtonDown({ try { $splash.DragMove() } catch {} })
$splash.Add_KeyDown({ if ($_.Key -eq 'Escape') { $splash.Close() } })

# ---- 5. start the app (hidden, output captured so errors can be shown)
$proc = Start-Process $PsExe -PassThru -WindowStyle Hidden -WorkingDirectory $Root `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile -RedirectStandardInput $inFile `
    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$Main`""

$script:msgIdx = 0; $script:done = $false; $started = Get-Date
$u_status.Text = $S[0]; Set-Dots 0

function Show-Failure($title) {
    $script:done = $true
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null); $rt.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null)
    $bt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $null)
    $u_status.Text = $title; $u_status.Foreground = [Windows.Media.Brushes]::Orange
    $u_bar.Visibility = 'Collapsed'
    $detail = ''
    foreach ($f in $errFile, $outFile) { if (Test-Path $f) { $t = (Get-Content $f -Raw -ErrorAction SilentlyContinue); if ($t) { $detail += $t.Trim() + "`r`n" } } }
    if (-not $detail) { $detail = 'No error text was captured. Open the logs folder for more information.' }
    $u_errBox.Text = "SharkOptimizer $ver  |  $((Get-Item $Main).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))  |  Windows build $([Environment]::OSVersion.Version.Build)  |  PowerShell $($PSVersionTable.PSVersion)`r`n`r`n$detail"
    $u_errPanel.Visibility = 'Visible'
}
$splash.FindName('btnCopy').Add_Click({ [Windows.Clipboard]::SetText($u_errBox.Text) })
$splash.FindName('btnLogs').Add_Click({ Start-Process explorer.exe $logDir })
$splash.FindName('btnClose').Add_Click({ $splash.Close() })

$timer = New-Object Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:tick = 0
$timer.Add_Tick({
    if ($script:done) { return }
    $script:tick++
    if ($script:tick % 4 -eq 0 -and $script:msgIdx -lt 5) { $script:msgIdx++; $u_status.Text = $S[$script:msgIdx]; Set-Dots $script:msgIdx }
    if ([WinFind]::HasVisibleWindow($proc.Id, 'SharkOptimizer')) {
        $script:done = $true; $timer.Stop(); $u_status.Text = $S[7]; Set-Dots 5
        $fade = New-Anim 1 0 0.4; $fade.Add_Completed({ $splash.Close() })
        $splash.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
    }
    elseif ($proc.HasExited) { $timer.Stop(); Show-Failure $S[8] }
    elseif (((Get-Date) - $started).TotalSeconds -gt 120) { $timer.Stop(); Show-Failure $S[9] }
})
$timer.Start()
[void]$splash.ShowDialog()
