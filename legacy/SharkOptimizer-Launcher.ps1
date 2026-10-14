# SharkOptimizer launcher 2.0.1: animated loading screen, requirement checks, one admin prompt,
# single instance, clear error report with Retry, and a quiet fallback that still starts the app if the animation fails.
# Keep this file in the same folder as SharkOptimizer.ps1. Start it with the root Start-SharkOptimizer.bat file.
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Main = Join-Path $Root 'SharkOptimizer.ps1'
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$DataDir = Join-Path $env:ProgramData 'SharkOptimizer'
try { New-Item $DataDir -ItemType Directory -Force | Out-Null } catch {}
$LauncherLog = Join-Path $DataDir 'launcher.log'
function Write-LLog($m) {
    try {
        if ((Test-Path $LauncherLog) -and ((Get-Item $LauncherLog).Length -gt 200KB)) { Remove-Item $LauncherLog -Force -ErrorAction SilentlyContinue }
        Add-Content -Path $LauncherLog -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -ErrorAction SilentlyContinue
    } catch {}
}
Write-LLog 'Launcher started.'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
trap {
    $m = "Launcher error: $($_.Exception.Message)`r`n$($_.InvocationInfo.PositionMessage)"
    Write-LLog $m
    try { Add-Content (Join-Path $DataDir 'launcher-crash.txt') ("[{0}] {1}`r`n" -f (Get-Date -Format s), $m) } catch {}
    $started = $false
    try {
        if ($proc -and -not $proc.HasExited) { $started = $true }
        elseif (Test-Path $Main) { Start-Process $PsExe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$Main`""; $started = $true; Write-LLog 'Fallback: started the app without the loading screen.' }
    } catch { Write-LLog "Fallback failed: $($_.Exception.Message)" }
    if (-not $started) { try { [void][Windows.MessageBox]::Show($m, 'SharkOptimizer launcher', 'OK', 'Error') } catch {} }
    exit 1
}
function Show-Msg($text, $icon = 'Error') { [void][Windows.MessageBox]::Show($text, 'SharkOptimizer', 'OK', $icon) }

# ---- 1. one admin prompt
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-LLog 'Not elevated: asking for administrator rights.'
    try { Start-Process $PsExe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`"" }
    catch { Write-LLog 'Administrator prompt was declined.'; Show-Msg 'SharkOptimizer needs administrator rights to change Windows settings. Please accept the prompt next time.' 'Warning' }
    exit
}

# ---- 2. only one launcher at a time
try {
    $createdNew = $false
    $script:LauncherMutex = New-Object System.Threading.Mutex($true, 'Local\SharkOptimizerLauncher', [ref]$createdNew)
    if (-not $createdNew) { Write-LLog 'Another launcher is already running. Exiting.'; exit }
} catch {}

# ---- 3. requirement checks
$problems = @()
if ($PSVersionTable.PSVersion -lt [version]'5.1') { $problems += 'Windows PowerShell 5.1 or newer is required.' }
if ([Environment]::OSVersion.Version.Build -lt 10240) { $problems += 'Windows 10 or Windows 11 is required.' }
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { $problems += 'PowerShell is running in a restricted mode (Constrained Language Mode), which blocks SharkOptimizer.' }
try {
    $gpo = @(Get-ExecutionPolicy -List | Where-Object { $_.Scope -in 'MachinePolicy', 'UserPolicy' -and $_.ExecutionPolicy -in 'AllSigned', 'Restricted' })
    if ($gpo.Count) { $problems += 'A Group Policy on this PC only allows signed PowerShell scripts, which blocks SharkOptimizer.' }
} catch {}
if (-not (Test-Path -LiteralPath $Main)) { $problems += 'SharkOptimizer.ps1 was not found. Keep it in the same folder as this launcher.' }
else {
    try {
        $tk = $null; $pe = $null
        [void][Management.Automation.Language.Parser]::ParseFile($Main, [ref]$tk, [ref]$pe)
        if ($pe -and $pe.Count) { $problems += "SharkOptimizer.ps1 is damaged (line $($pe[0].Extent.StartLineNumber): $($pe[0].Message)). Restore a backup or download it again." }
    } catch {}
}
if ($problems.Count) { Write-LLog ('Preflight problems: ' + ($problems -join ' | ')); Show-Msg ("SharkOptimizer cannot start:`n`n- " + ($problems -join "`n- ")); exit }
try { Get-ChildItem -LiteralPath $Root -Filter *.ps1 -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch {}

# ---- window finder: only used as a fallback for older app versions that do not write the ready marker
$WinFindCs = @"
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
function Test-AppWindow($processId) {
    if (-not ('WinFind' -as [type])) { Add-Type -TypeDefinition $WinFindCs }
    [WinFind]::HasVisibleWindow($processId, 'SharkOptimizer')
}

# ---- 4. language, accent colour and version (read from the app's settings)
$LauncherVersion = '2.0.1'
$lang = 'en'; $accent = '#1FB6FF'; $ver = "v$LauncherVersion"
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
    if ($vm.Success -and $vm.Groups[1].Value -ne $LauncherVersion) {
        Write-LLog "Version mismatch: launcher $LauncherVersion, app $($vm.Groups[1].Value)."
        $ver = 'v' + $vm.Groups[1].Value
    }
} catch { Write-LLog "Settings could not be read: $($_.Exception.Message)" }
function Mix-White($hex, $t) {
    $c = [Windows.Media.ColorConverter]::ConvertFromString($hex)
    '#{0:X2}{1:X2}{2:X2}' -f [int]($c.R + (255 - $c.R) * $t), [int]($c.G + (255 - $c.G) * $t), [int]($c.B + (255 - $c.B) * $t)
}
$accent2 = Mix-White $accent 0.45

$TT = @{
 en = @('Checking requirements...', 'Starting SharkOptimizer...', 'Detecting your hardware...', 'Loading tweaks...', 'Preparing game profiles...', 'Almost ready...', 'Tune Windows for gaming', 'Ready', 'SharkOptimizer stopped while starting.', 'SharkOptimizer is taking too long to start.', 'Copy details', 'Open logs', 'Close', 'SharkOptimizer is already running. Close it and start again?', 'Retry')
 nl = @('Vereisten controleren...', 'SharkOptimizer starten...', 'Je hardware detecteren...', 'Tweaks laden...', 'Gameprofielen voorbereiden...', 'Bijna klaar...', 'Stem Windows af op gamen', 'Klaar', 'SharkOptimizer stopte tijdens het starten.', 'SharkOptimizer start te langzaam.', 'Details kopiëren', 'Logs openen', 'Sluiten', 'SharkOptimizer draait al. Afsluiten en opnieuw starten?', 'Opnieuw')
 es = @('Comprobando requisitos...', 'Iniciando SharkOptimizer...', 'Detectando tu hardware...', 'Cargando ajustes...', 'Preparando perfiles de juegos...', 'Casi listo...', 'Optimiza Windows para jugar', 'Listo', 'SharkOptimizer se detuvo al iniciar.', 'SharkOptimizer tarda demasiado en iniciar.', 'Copiar detalles', 'Abrir registros', 'Cerrar', 'SharkOptimizer ya se está ejecutando. ¿Cerrarlo y volver a iniciarlo?', 'Reintentar')
 de = @('Anforderungen werden geprüft...', 'SharkOptimizer wird gestartet...', 'Hardware wird erkannt...', 'Tweaks werden geladen...', 'Spielprofile werden vorbereitet...', 'Fast fertig...', 'Windows fürs Gaming optimieren', 'Bereit', 'SharkOptimizer wurde beim Start beendet.', 'SharkOptimizer startet zu langsam.', 'Details kopieren', 'Protokolle öffnen', 'Schließen', 'SharkOptimizer läuft bereits. Beenden und neu starten?', 'Wiederholen')
 fr = @('Vérification de la configuration...', 'Démarrage de SharkOptimizer...', 'Détection de votre matériel...', 'Chargement des réglages...', 'Préparation des profils de jeux...', 'Presque prêt...', 'Optimisez Windows pour le jeu', 'Prêt', "SharkOptimizer s'est arrêté au démarrage.", 'SharkOptimizer met trop de temps à démarrer.', 'Copier les détails', 'Ouvrir les journaux', 'Fermer', "SharkOptimizer est déjà en cours d'exécution. Le fermer et le relancer ?", 'Réessayer')
 pt = @('Verificando requisitos...', 'Iniciando o SharkOptimizer...', 'Detectando seu hardware...', 'Carregando ajustes...', 'Preparando perfis de jogos...', 'Quase pronto...', 'Otimize o Windows para jogar', 'Pronto', 'O SharkOptimizer parou ao iniciar.', 'O SharkOptimizer está demorando para iniciar.', 'Copiar detalhes', 'Abrir registros', 'Fechar', 'O SharkOptimizer já está em execução. Fechar e iniciar de novo?', 'Tentar novamente')
 ru = @('Проверка требований...', 'Запуск SharkOptimizer...', 'Определение вашего оборудования...', 'Загрузка твиков...', 'Подготовка игровых профилей...', 'Почти готово...', 'Настройте Windows для игр', 'Готово', 'SharkOptimizer остановился при запуске.', 'SharkOptimizer запускается слишком долго.', 'Копировать данные', 'Открыть журналы', 'Закрыть', 'SharkOptimizer уже запущен. Закрыть и запустить заново?', 'Повторить')
 zh = @('正在检查运行要求...', '正在启动 SharkOptimizer...', '正在检测你的硬件...', '正在加载优化项...', '正在准备游戏配置...', '马上就好...', '为游戏优化 Windows', '已就绪', 'SharkOptimizer 在启动时停止了。', 'SharkOptimizer 启动时间过长。', '复制详情', '打开日志', '关闭', 'SharkOptimizer 已在运行。要关闭并重新启动吗？', '重试')
}
$S = $TT[$lang]; if (-not $S) { $S = $TT['en'] }
$TipSets = @{
 en = @('Game Mode prioritizes your game while you play.', 'Compare DNS response times in the Network tab.', 'Restore tracks tweaks so you can undo them later.', 'Background recording can cause frame-time spikes.', 'Some Windows changes need a restart to take effect.', 'Choose tweaks that fit your hardware and setup.')
 nl = @('Game Mode geeft je game prioriteit tijdens het spelen.', 'Vergelijk DNS-responstijden in het tabblad Netwerk.', 'Herstel houdt tweaks bij zodat je ze kunt terugdraaien.', 'Achtergrondopname kan frametimepieken veroorzaken.', 'Sommige Windows-wijzigingen vereisen een herstart.', 'Kies tweaks die bij je hardware en setup passen.')
 es = @('El modo Juego prioriza tu juego mientras juegas.', 'Compara los tiempos de DNS en la pestaña Red.', 'Restaurar registra los ajustes para poder deshacerlos.', 'La grabación en segundo plano puede causar tirones.', 'Algunos cambios requieren reiniciar Windows.', 'Elige ajustes adecuados para tu equipo.')
 de = @('Der Spielmodus priorisiert dein Spiel während des Spielens.', 'Vergleiche DNS-Antwortzeiten im Netzwerk-Tab.', 'Wiederherstellen speichert Tweaks zum späteren Rückgängigmachen.', 'Hintergrundaufnahmen können Ruckler verursachen.', 'Einige Windows-Änderungen erfordern einen Neustart.', 'Wähle Tweaks passend zu deiner Hardware.')
 fr = @('Le mode Jeu donne la priorité à votre jeu pendant la partie.', 'Comparez les temps DNS dans Réseau.', 'Restaurer suit les réglages pour pouvoir les annuler.', 'La capture en arrière-plan peut causer des saccades.', 'Certains changements nécessitent un redémarrage.', 'Choisissez des réglages adaptés à votre matériel.')
 pt = @('O Modo de Jogo prioriza seu jogo durante a partida.', 'Compare os tempos de DNS na aba Rede.', 'Restaurar registra ajustes para você poder desfazê-los.', 'A gravação em segundo plano pode causar travamentos.', 'Algumas mudanças exigem reiniciar o Windows.', 'Escolha ajustes adequados ao seu hardware.')
 ru = @('Игровой режим отдаёт приоритет игре во время запуска.', 'Сравните время отклика DNS на странице сети.', 'Восстановление сохраняет твики для отмены изменений.', 'Фоновая запись может вызывать скачки времени кадра.', 'Некоторые изменения требуют перезагрузки Windows.', 'Выбирайте настройки с учётом своего оборудования.')
 zh = @('游戏模式会在游玩时优先处理游戏。', '在网络页面比较 DNS 响应时间。', '还原功能会记录优化项，方便之后撤销。', '后台录制可能导致帧时间波动。', '部分 Windows 设置需要重启后生效。', '根据你的硬件选择合适的优化项。')
}
$Tips = $TipSets[$lang]; if (-not $Tips) { $Tips = $TipSets['en'] }

# ---- 5. already running?
try {
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' AND CommandLine LIKE '%SharkOptimizer.ps1%'" -ErrorAction Stop | Where-Object { $_.ProcessId -ne $PID })
    if ($running.Count) {
        Write-LLog "App already running (pid $($running[0].ProcessId))."
        if ([Windows.MessageBox]::Show($S[13], 'SharkOptimizer', 'YesNo', 'Question') -ne 'Yes') { exit }
        foreach ($rp in $running) { try { Stop-Process -Id $rp.ProcessId -Force -ErrorAction Stop } catch { Write-LLog "Could not stop pid $($rp.ProcessId)" } }
        Start-Sleep -Milliseconds 800
    }
} catch { Write-LLog "Running-instance check skipped: $($_.Exception.Message)" }

# ---- 6. splash window
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
     <WrapPanel HorizontalAlignment="Center" Margin="0,8,0,0">
      <Button x:Name="btnRetry" Background="__ACC__" Foreground="#06121F"/><Button x:Name="btnCopy"/><Button x:Name="btnLogs"/><Button x:Name="btnClose"/>
     </WrapPanel>
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
foreach ($n in 'logo','glow','bar','status','tag','verTxt','dots','errPanel','errBox','bubbles') { Set-Variable -Name ('u_' + $n) -Value $splash.FindName($n) }
$u_tag.Text = $S[6]; $u_verTxt.Text = $ver
$splash.FindName('btnCopy').Content = $S[10]; $splash.FindName('btnLogs').Content = $S[11]; $splash.FindName('btnClose').Content = $S[12]; $splash.FindName('btnRetry').Content = $S[14]
try { $splash.Dispatcher.add_UnhandledException({ param($sender, $e) try { Write-LLog ('UI error: ' + $e.Exception.Message) } catch {}; $e.Handled = $true }) } catch {}

# every launch uses its own output files, so a running app can never block the next launch
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$outFile = Join-Path $DataDir "launch-$runId.out.txt"; $errFile = Join-Path $DataDir "launch-$runId.err.txt"; $inFile = Join-Path $DataDir "launch-$runId.in.txt"
$readyFile = Join-Path $DataDir 'ready.flag'
try { Get-ChildItem -LiteralPath $DataDir -Filter 'launch-*' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
'' | Set-Content $inFile; Remove-Item $readyFile -Force -ErrorAction SilentlyContinue

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
$tt = New-Object Windows.Media.TranslateTransform; $rt = New-Object Windows.Media.RotateTransform
$tg = New-Object Windows.Media.TransformGroup; [void]$tg.Children.Add($rt); [void]$tg.Children.Add($tt); $u_logo.RenderTransform = $tg
$bt = New-Object Windows.Media.TranslateTransform; $u_bar.RenderTransform = $bt
$gs = New-Object Windows.Media.ScaleTransform; $u_glow.RenderTransform = $gs
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
    try {
        $splash.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Anim 0 1 0.45))
        $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-Anim -6 6 1.2 $true $true))
        $rt.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, (New-Anim -5 5 1.7 $true $true))
        $bt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, (New-Anim -120 320 1.5 $true $false))
        $gs.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-Anim 0.88 1.12 1.6 $true $true))
        $gs.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-Anim 0.88 1.12 1.6 $true $true))
        $u_glow.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Anim 0.55 1 1.6 $true $true))
        foreach ($b in $bubbleList) { $b[0].BeginAnimation([Windows.Controls.Canvas]::TopProperty, (New-Linear 360 -14 $b[1] $b[2])) }
    } catch { Write-LLog "Animation failed (the app still starts): $($_.Exception.Message)" }
})
$splash.Add_MouseLeftButtonDown({ try { $splash.DragMove() } catch {} })
$splash.Add_KeyDown({ if ($_.Key -eq 'Escape') { $splash.Close() } })

# ---- 7. start the app (hidden, output captured so errors can be shown)
Write-LLog 'Starting the app.'
$proc = Start-Process $PsExe -PassThru -WindowStyle Hidden -WorkingDirectory $Root `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile -RedirectStandardInput $inFile `
    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$Main`""
Write-LLog "App process started (pid $($proc.Id))."

$script:msgIdx = 0; $script:done = $false; $started = Get-Date
$script:tipIdx = -1
$tipTimer = New-Object Windows.Threading.DispatcherTimer
$tipTimer.Interval = [TimeSpan]::FromSeconds(5)
$tipTimer.Add_Tick({
    if ($script:done) { $tipTimer.Stop(); return }
    $script:tipIdx = ($script:tipIdx + 1) % $Tips.Count
    $u_tag.Text = $Tips[$script:tipIdx]
})
$u_status.Text = $S[0]; Set-Dots 0

function Show-Failure($title) {
    $script:done = $true
    $tipTimer.Stop()
    Write-LLog "Failure: $title"
    try {
        $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null); $rt.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null)
        $bt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $null)
    } catch {}
    $u_status.Text = $title; $u_status.Foreground = [Windows.Media.Brushes]::Orange
    $u_bar.Visibility = 'Collapsed'
    $detail = ''
    foreach ($f in $errFile, $outFile) { try { if (Test-Path $f) { $t = (Get-Content $f -Raw -ErrorAction SilentlyContinue); if ($t) { $detail += $t.Trim() + "`r`n" } } } catch {} }
    if (-not $detail) { $detail = 'No error text was captured. Open the logs folder for more information.' }
    $u_errBox.Text = "SharkOptimizer $ver  |  $((Get-Item $Main).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))  |  Windows build $([Environment]::OSVersion.Version.Build)  |  PowerShell $($PSVersionTable.PSVersion)`r`n`r`n$detail"
    $u_errPanel.Visibility = 'Visible'
}
$splash.FindName('btnCopy').Add_Click({ try { [Windows.Clipboard]::SetText($u_errBox.Text) } catch {} })
$splash.FindName('btnLogs').Add_Click({ try { Start-Process explorer.exe $DataDir } catch {} })
$splash.FindName('btnClose').Add_Click({ $splash.Close() })
$splash.FindName('btnRetry').Add_Click({
    $tipTimer.Stop()
    try {
        try { if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } } catch {}
        try { $script:LauncherMutex.ReleaseMutex() } catch {}
        Start-Process $PsExe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    } catch { Write-LLog "Retry failed: $($_.Exception.Message)" }
    $splash.Close()
})

$timer = New-Object Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:tick = 0
$timer.Add_Tick({
    try {
        if ($script:done) { return }
        $script:tick++
        if ($script:tick % 5 -eq 0 -and $script:msgIdx -lt 5) { $script:msgIdx++; $u_status.Text = $S[$script:msgIdx]; Set-Dots $script:msgIdx }
        $isReady = Test-Path $readyFile
        if (-not $isReady -and $script:tick -gt 80 -and -not $proc.HasExited) { try { $isReady = Test-AppWindow $proc.Id } catch {} }
        if ($isReady) {
            $script:done = $true; $timer.Stop(); $tipTimer.Stop(); $u_status.Text = $S[7]; Set-Dots 5
            Write-LLog 'App is ready.'
            $fade = New-Anim 1 0 0.4; $fade.Add_Completed({ $splash.Close() })
            $splash.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
        }
        elseif ($proc.HasExited) { $timer.Stop(); Show-Failure $S[8] }
        elseif (((Get-Date) - $started).TotalSeconds -gt 120) { $timer.Stop(); Show-Failure $S[9] }
    } catch { Write-LLog "Timer error: $($_.Exception.Message)" }
})
$splash.Add_Closed({ $tipTimer.Stop() })
$tipTimer.Start()
$timer.Start()
[void]$splash.ShowDialog()
Write-LLog 'Launcher finished.'
