using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("SharkOptimizer Setup")]
[assembly: AssemblyDescription("SharkOptimizer Windows installer")]
[assembly: AssemblyCompany("Bas Makes Stuff")]
[assembly: AssemblyCopyright("Copyright © 2026 Bas Makes Stuff. All rights reserved.")]
[assembly: AssemblyProduct("SharkOptimizer")]
[assembly: AssemblyVersion("2.0.2.0")]
[assembly: AssemblyFileVersion("2.0.2.0")]
[assembly: AssemblyInformationalVersion("2.0.2")]

internal static class SetupProgram
{
    internal const string Version = "2.0.2";
    internal static string InstallRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "SharkOptimizer");
    internal const string UninstallKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\SharkOptimizer";

    [STAThread]
    private static void Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        if (args.Length == 3 && String.Equals(args[0], "/cleanup", StringComparison.OrdinalIgnoreCase))
        {
            UninstallCleanup.Run(args[1], args[2]); return;
        }
        if (args.Length > 0 && String.Equals(args[0], "/uninstall", StringComparison.OrdinalIgnoreCase))
        {
            Uninstall();
            return;
        }
        if (args.Length > 0 && String.Equals(args[0], "/update", StringComparison.OrdinalIgnoreCase))
        {
            int waitPid = 0; if (args.Length > 1) Int32.TryParse(args[1], out waitPid);
            string root = null;
            try { using (RegistryKey key = Registry.LocalMachine.OpenSubKey(UninstallKey)) root = key == null ? null : Convert.ToString(key.GetValue("InstallLocation")); } catch { }
            if (String.IsNullOrWhiteSpace(root) || !Directory.Exists(root)) { MessageBox.Show("SharkOptimizer's installed folder could not be found. Run the downloaded setup normally to repair the installation.", "SharkOptimizer Update", MessageBoxButtons.OK, MessageBoxIcon.Error); return; }
            Application.Run(new UpdateInstaller(root, waitPid));
            return;
        }
        Application.Run(new SetupWizard());
    }

    private static void Uninstall()
    {
        string root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        DialogResult result = MessageBox.Show(
            "Remove SharkOptimizer from this computer?\n\nYour saved settings and change history will be kept.",
            "Uninstall SharkOptimizer", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        if (result != DialogResult.Yes) return;

        try
        {
            UninstallCleanup.ValidateRoot(root);
            UninstallCleanup.RequireAppClosed(root);
            string helper = UninstallCleanup.PrepareHelper();
            RemoveShortcuts(root);
            SharkOptimizer.Platform.StartupRegistration.Disable();
            try { using (Process process = Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "schtasks.exe"), "/Delete /TN \"SharkOptimizer Weekly Cleanup\" /F") { CreateNoWindow = true, UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden })) if (process != null) process.WaitForExit(10000); } catch { }
            using (Process helperProcess = Process.Start(new ProcessStartInfo {
                FileName = helper,
                Arguments = "/cleanup \"" + root + "\" " + Process.GetCurrentProcess().Id,
                CreateNoWindow = true, UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden, WorkingDirectory = Path.GetTempPath()
            })) { if (helperProcess == null) throw new InvalidOperationException("The uninstall cleanup could not start."); }
        }
        catch (Exception ex)
        {
            MessageBox.Show("The app could not be fully removed.\n\n" + ex.Message, "Uninstall SharkOptimizer",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private static void RemoveShortcuts(string root)
    {
        string[] paths = {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms), "SharkOptimizer", "SharkOptimizer.lnk"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "SharkOptimizer", "SharkOptimizer.lnk"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "SharkOptimizer.lnk")
        };
        foreach (string path in paths) {
            if (File.Exists(path)) UninstallCleanup.RemoveOwnedShortcut(path, root);
        }
        UninstallCleanup.RemoveEmptyDirectory(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "SharkOptimizer"));
        UninstallCleanup.RemoveEmptyDirectory(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms), "SharkOptimizer"));
    }
}

internal sealed class UpdateInstaller : Form
{
    private readonly string installRoot;
    private readonly int waitPid;
    private readonly Label status = new Label();
    private readonly ProgressBar progress = new ProgressBar();

    internal UpdateInstaller(string root, int processId)
    {
        installRoot = Path.GetFullPath(root); waitPid = processId;
        Text = "SharkOptimizer Update"; ClientSize = new Size(480, 156); FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterScreen; MaximizeBox = false; MinimizeBox = false; ShowInTaskbar = true;
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        var title = new Label { Text = "Updating SharkOptimizer", Font = new Font("Segoe UI", 15, FontStyle.Bold), ForeColor = Color.FromArgb(30, 42, 62), AutoSize = true, Location = new Point(24, 20) };
        status.Text = "Waiting for SharkOptimizer to close…"; status.Font = new Font("Segoe UI", 9.5f); status.ForeColor = Color.FromArgb(98, 112, 136); status.AutoSize = true; status.Location = new Point(26, 60);
        progress.Location = new Point(26, 92); progress.Size = new Size(426, 18); progress.Style = ProgressBarStyle.Marquee; progress.MarqueeAnimationSpeed = 24;
        Controls.Add(title); Controls.Add(status); Controls.Add(progress);
        bool updating = true;
        FormClosing += delegate(object sender, FormClosingEventArgs e) { if (updating) e.Cancel = true; };
        var worker = new BackgroundWorker();
        worker.DoWork += delegate(object sender, DoWorkEventArgs e) { WaitForAppExit(); e.Result = InstallUpdate(); };
        worker.RunWorkerCompleted += delegate(object sender, RunWorkerCompletedEventArgs e)
        {
            updating = false;
            progress.Style = ProgressBarStyle.Blocks;
            if (e.Error != null)
            {
                status.Text = "The update could not be installed."; progress.Value = 0;
                MessageBox.Show(this, "SharkOptimizer was not updated." + Environment.NewLine + Environment.NewLine + e.Error.Message, "SharkOptimizer Update", MessageBoxButtons.OK, MessageBoxIcon.Error);
                Close(); return;
            }
            status.Text = "Update installed. Starting SharkOptimizer…"; progress.Value = 100;
            string app = Convert.ToString(e.Result);
            try { Process.Start(new ProcessStartInfo(app) { WorkingDirectory = installRoot, UseShellExecute = true }); }
            catch (Exception ex) { MessageBox.Show(this, "The update installed, but SharkOptimizer could not reopen automatically." + Environment.NewLine + ex.Message, "SharkOptimizer Update", MessageBoxButtons.OK, MessageBoxIcon.Information); }
            Close();
        };
        Shown += delegate { worker.RunWorkerAsync(); };
    }

    private void WaitForAppExit()
    {
        if (waitPid <= 0) return;
        try
        {
            using (Process app = Process.GetProcessById(waitPid))
                if (!app.WaitForExit(60000)) throw new TimeoutException("SharkOptimizer did not close within one minute. Close it and run the update again.");
        }
        catch (ArgumentException) { }
    }

    private string InstallUpdate()
    {
        string appPath = Path.Combine(installRoot, "SharkOptimizer.exe");
        var transaction = new InstallTransaction(installRoot);
        try
        {
            string app = transaction.StageResource("SharkOptimizer.Payload.SharkOptimizer.Native.exe", "app.exe");
            string icon = transaction.StageResource("SharkOptimizer.Payload.shark.ico", "shark.ico");
            string setup = transaction.StageSetup();
            InstallTransaction.ValidatePayload(app, icon);
            transaction.ReplaceFile(app, appPath);
            transaction.ReplaceFile(icon, Path.Combine(installRoot, "data", "shark.ico"));
            transaction.ReplaceFile(setup, Path.Combine(installRoot, "Uninstall-SharkOptimizer.exe"));
            SetupProgram.InstallRoot = installRoot;
            UpdateShortcuts(transaction);
            transaction.ChangingMetadata();
            if (SharkOptimizer.Platform.StartupRegistration.IsEnabled()) SharkOptimizer.Platform.StartupRegistration.Enable(appPath);
            using (RegistryKey key = Registry.LocalMachine.CreateSubKey(SetupProgram.UninstallKey))
            {
                if (key == null) throw new InvalidOperationException("The Windows uninstall record could not be updated.");
                key.SetValue("DisplayName", "SharkOptimizer"); key.SetValue("DisplayVersion", SetupProgram.Version); key.SetValue("Publisher", "Bas Makes Stuff");
                key.SetValue("InstallLocation", installRoot); key.SetValue("DisplayIcon", appPath); key.SetValue("UninstallString", "\"" + Path.Combine(installRoot, "Uninstall-SharkOptimizer.exe") + "\" /uninstall");
                key.SetValue("NoModify", 1, RegistryValueKind.DWord); key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            }
            transaction.Commit();
            return appPath;
        }
        catch (Exception ex) { throw transaction.Recover(ex); }
    }

    private void UpdateShortcuts(InstallTransaction transaction)
    {
        string programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
        string menu = Path.Combine(programs, "SharkOptimizer", "SharkOptimizer.lnk");
        transaction.CaptureFile(menu); CreateShortcut(menu);
        string desktop = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "SharkOptimizer.lnk");
        if (File.Exists(desktop)) { transaction.CaptureFile(desktop); CreateShortcut(desktop); }
    }

    private void CreateShortcut(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        Type shellType = Type.GetTypeFromProgID("WScript.Shell"); object shell = Activator.CreateInstance(shellType);
        try
        {
            object shortcut = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { path });
            try
            {
                Type type = shortcut.GetType(); type.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, new object[] { Path.Combine(installRoot, "SharkOptimizer.exe") });
                type.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut, new object[] { installRoot });
                type.InvokeMember("Description", BindingFlags.SetProperty, null, shortcut, new object[] { "SharkOptimizer " + SetupProgram.Version });
                type.InvokeMember("IconLocation", BindingFlags.SetProperty, null, shortcut, new object[] { Path.Combine(installRoot, "SharkOptimizer.exe") });
                type.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
            }
            finally { if (Marshal.IsComObject(shortcut)) Marshal.ReleaseComObject(shortcut); }
        }
        finally { if (Marshal.IsComObject(shell)) Marshal.ReleaseComObject(shell); }
    }
}

internal sealed class SetupWizard : Form
{
    private readonly Color navy = Color.FromArgb(11, 20, 36);
    private readonly Color blue = Color.FromArgb(31, 182, 255);
    private readonly Color ink = Color.FromArgb(30, 42, 62);
    private readonly Panel side = new Panel();
    private readonly Panel body = new Panel();
    private readonly Panel footer = new Panel();
    private readonly Label heading = new Label();
    private readonly Label subheading = new Label();
    private readonly Label status = new Label();
    private readonly ProgressBar progress = new ProgressBar();
    private readonly Button back = new Button();
    private readonly Button next = new Button();
    private readonly Button cancel = new Button();
    private readonly TextBox folder = new TextBox();
    private readonly CheckBox desktopLink = new CheckBox();
    private readonly CheckBox launchApp = new CheckBox();
    private int page;

    internal SetupWizard()
    {
        Text = "SharkOptimizer Setup";
        FormClosing += delegate(object sender, FormClosingEventArgs e) { if (page == 2) e.Cancel = true; };
        ClientSize = new Size(780, 500);
        MinimumSize = new Size(780, 500);
        MaximumSize = new Size(780, 500);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.White;
        Icon = LoadIcon();

        side.Dock = DockStyle.Left; side.Width = 220; side.BackColor = navy;
        Controls.Add(side);
        PictureBox logo = new PictureBox(); logo.Size = new Size(82, 82); logo.Location = new Point(34, 48); logo.SizeMode = PictureBoxSizeMode.Zoom;
        logo.Image = LoadLogo(); side.Controls.Add(logo);
        Label brand = new Label { Text = "SharkOptimizer", ForeColor = Color.White, Font = new Font("Segoe UI", 17, FontStyle.Bold), AutoSize = true, Location = new Point(24, 145) };
        side.Controls.Add(brand);
        Label release = new Label { Text = "VERSION " + SetupProgram.Version, ForeColor = blue, Font = new Font("Segoe UI", 9, FontStyle.Bold), AutoSize = true, Location = new Point(27, 180) };
        side.Controls.Add(release);
        Label tagline = new Label { Text = "A cleaner way to tune your PC.", ForeColor = Color.FromArgb(177, 192, 216), Font = new Font("Segoe UI", 10), AutoSize = false, Size = new Size(170, 48), Location = new Point(27, 224) };
        side.Controls.Add(tagline);
        Label steps = new Label { Text = "1   Welcome\n\n2   Install location\n\n3   Installing\n\n4   Complete", ForeColor = Color.FromArgb(128, 149, 180), Font = new Font("Segoe UI", 9.5f), AutoSize = false, Size = new Size(175, 130), Location = new Point(27, 320) };
        side.Controls.Add(steps);

        body.Location = new Point(220, 0); body.Size = new Size(560, 420); body.BackColor = Color.White;
        Controls.Add(body);
        heading.Location = new Point(40, 40); heading.Size = new Size(480, 38); heading.Font = new Font("Segoe UI", 18, FontStyle.Bold); heading.ForeColor = ink;
        body.Controls.Add(heading);
        subheading.Location = new Point(42, 84); subheading.Size = new Size(465, 44); subheading.Font = new Font("Segoe UI", 9.5f); subheading.ForeColor = Color.FromArgb(98, 112, 136);
        body.Controls.Add(subheading);

        footer.Location = new Point(220, 420); footer.Size = new Size(560, 80); footer.BackColor = Color.FromArgb(247, 249, 252); footer.BorderStyle = BorderStyle.FixedSingle;
        Controls.Add(footer);
        back.Text = "Back"; back.Location = new Point(280, 22); back.Size = new Size(82, 34); back.Click += delegate { ShowPage(Math.Max(0, page - 1)); };
        next.Text = "Next"; next.Location = new Point(370, 22); next.Size = new Size(100, 34); next.BackColor = blue; next.FlatStyle = FlatStyle.Flat; next.FlatAppearance.BorderSize = 0; next.Font = new Font("Segoe UI", 9, FontStyle.Bold); next.Click += NextClicked;
        cancel.Text = "Cancel"; cancel.Location = new Point(478, 22); cancel.Size = new Size(72, 34); cancel.Click += delegate { Close(); };
        footer.Controls.Add(back); footer.Controls.Add(next); footer.Controls.Add(cancel);

        folder.Location = new Point(42, 160); folder.Size = new Size(390, 28); folder.Font = new Font("Segoe UI", 10);
        folder.Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "SharkOptimizer"); body.Controls.Add(folder);
        Label folderLabel = new Label { Name = "folderLabel", Text = "Install SharkOptimizer to:", AutoSize = true, Location = new Point(44, 137), Font = new Font("Segoe UI", 9, FontStyle.Bold), ForeColor = ink };
        body.Controls.Add(folderLabel);
        Button browse = new Button { Text = "Browse...", Location = new Point(444, 157), Size = new Size(76, 32) };
        browse.Click += delegate { using (FolderBrowserDialog dialog = new FolderBrowserDialog()) { dialog.Description = "Choose where SharkOptimizer should be installed."; dialog.SelectedPath = folder.Text; if (dialog.ShowDialog(this) == DialogResult.OK) folder.Text = dialog.SelectedPath; } };
        body.Controls.Add(browse);
        desktopLink.Text = "Create a desktop shortcut (tray startup is enabled)"; desktopLink.Checked = true; desktopLink.AutoSize = true; desktopLink.Location = new Point(44, 212); body.Controls.Add(desktopLink);
        launchApp.Text = "Launch SharkOptimizer when setup closes"; launchApp.Checked = true; launchApp.AutoSize = true; launchApp.Location = new Point(44, 115); body.Controls.Add(launchApp);
        progress.Location = new Point(44, 175); progress.Size = new Size(470, 18); progress.Visible = false; body.Controls.Add(progress);
        status.Location = new Point(44, 207); status.Size = new Size(470, 48); status.Font = new Font("Segoe UI", 9.5f); status.ForeColor = Color.FromArgb(98, 112, 136); body.Controls.Add(status);
        ShowPage(0);
    }

    private Icon LoadIcon() { try { return Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { return SystemIcons.Application; } }
    private Image LoadLogo() {
        try { using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("SharkOptimizer.Payload.shark.ico")) { return new Icon(stream, 96, 96).ToBitmap(); } }
        catch { return null; }
    }

    private void ShowPage(int value)
    {
        page = value;
        folder.Visible = desktopLink.Visible = (page == 1);
        foreach (Control control in body.Controls) if (control.Name == "folderLabel") control.Visible = (page == 1);
        launchApp.Visible = (page == 1);
        progress.Visible = status.Visible = (page == 2);
        foreach (Control control in body.Controls) {
            if (control is Button && control.Text == "Browse...") control.Visible = (page == 1);
        }
        if (page == 0) {
            heading.Text = "Welcome to SharkOptimizer Setup";
            subheading.Text = "This wizard will install SharkOptimizer " + SetupProgram.Version + " on your computer.";
            Label welcome = FindOrCreate("welcome", "SharkOptimizer brings your tuning tools, game profiles, and recovery options together in one place.\n\nSelect Next to choose where the app will be installed.", new Point(44, 160), new Size(465, 100));
            welcome.Visible = true;
        } else Hide("welcome");
        if (page == 1) {
            heading.Text = "Choose install options";
            subheading.Text = "Choose the folder and shortcuts for this installation.";
        }
        if (page == 2) {
            heading.Text = "Installing SharkOptimizer";
            subheading.Text = "Please wait while setup copies the application files.";
        }
        if (page == 3) {
            heading.Text = "Setup is complete";
            subheading.Text = "SharkOptimizer " + SetupProgram.Version + " was installed successfully.";
            Label complete = FindOrCreate("complete", "You can start SharkOptimizer from the Start menu at any time.", new Point(44, 160), new Size(465, 75));
            complete.Visible = true;
        } else Hide("complete");
        back.Visible = page == 1;
        back.Enabled = page == 1;
        cancel.Visible = page < 2;
        next.Text = page == 1 ? "Install" : (page == 3 ? "Finish" : "Next");
        next.Visible = page != 2;
        next.Enabled = page != 2;
    }

    private Label FindOrCreate(string name, string text, Point location, Size size)
    {
        Control found = body.Controls[name];
        if (found != null) return (Label)found;
        Label label = new Label { Name = name, Text = text, Location = location, Size = size, Font = new Font("Segoe UI", 10), ForeColor = ink };
        body.Controls.Add(label); return label;
    }
    private void Hide(string name) { Control control = body.Controls[name]; if (control != null) control.Visible = false; }

    private void NextClicked(object sender, EventArgs args)
    {
        if (page == 0) { ShowPage(1); return; }
        if (page == 1) { Install(); return; }
        if (page == 3) {
            bool launch = launchApp.Checked;
            string app = Path.Combine(folder.Text, "SharkOptimizer.exe");
            Close();
            if (launch) try { Process.Start(new ProcessStartInfo(app) { WorkingDirectory = folder.Text, UseShellExecute = true }); } catch { }
        }
    }

    private void Install()
    {
        string root = folder.Text.Trim();
        try { root = Path.GetFullPath(root); } catch { root = ""; }
        if (root.Length < 4 || root.IndexOfAny(Path.GetInvalidPathChars()) >= 0) {
            MessageBox.Show(this, "Enter a valid installation folder.", "SharkOptimizer Setup", MessageBoxButtons.OK, MessageBoxIcon.Warning); return;
        }
        string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!root.StartsWith(programFiles, StringComparison.OrdinalIgnoreCase)) {
            DialogResult choice = MessageBox.Show(this, "This installer needs administrator permission to install into the selected folder. Continue?", "SharkOptimizer Setup", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (choice != DialogResult.Yes) return;
        }
        ShowPage(2); progress.Value = 0; status.Text = "Preparing installation..."; Application.DoEvents();
        InstallTransaction transaction = null;
        try {
            transaction = new InstallTransaction(root);
            string stagedApp = transaction.StageResource("SharkOptimizer.Payload.SharkOptimizer.Native.exe", "app.exe");
            string stagedIcon = transaction.StageResource("SharkOptimizer.Payload.shark.ico", "shark.ico");
            string stagedSetup = transaction.StageSetup();
            InstallTransaction.ValidatePayload(stagedApp, stagedIcon);
            status.Text = "Installing SharkOptimizer..."; Application.DoEvents();
            transaction.ReplaceFile(stagedApp, Path.Combine(root, "SharkOptimizer.exe"));
            transaction.ReplaceFile(stagedIcon, Path.Combine(root, "data", "shark.ico"));
            progress.Value = 70;
            status.Text = "Creating shortcuts and uninstall information..."; Application.DoEvents();
            string uninstaller = Path.Combine(root, "Uninstall-SharkOptimizer.exe");
            transaction.ReplaceFile(stagedSetup, uninstaller);
            string menu = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "SharkOptimizer", "SharkOptimizer.lnk");
            transaction.CaptureFile(menu); CreateShortcut(menu, root);
            if (desktopLink.Checked) { string desktop = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "SharkOptimizer.lnk"); transaction.CaptureFile(desktop); CreateShortcut(desktop, root); }
            status.Text = "Registering tray startup for this Windows account..."; Application.DoEvents();
            transaction.ChangingMetadata();
            SharkOptimizer.Platform.StartupRegistration.Enable(Path.Combine(root, "SharkOptimizer.exe"));
            using (RegistryKey key = Registry.LocalMachine.CreateSubKey(SetupProgram.UninstallKey)) {
                if (key == null) throw new InvalidOperationException("The Windows uninstall record could not be created.");
                key.SetValue("DisplayName", "SharkOptimizer");
                key.SetValue("DisplayVersion", SetupProgram.Version);
                key.SetValue("Publisher", "Bas Makes Stuff");
                key.SetValue("InstallLocation", root);
                key.SetValue("DisplayIcon", Path.Combine(root, "SharkOptimizer.exe"));
                key.SetValue("UninstallString", "\"" + uninstaller + "\" /uninstall");
                key.SetValue("NoModify", 1, RegistryValueKind.DWord);
                key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            }
            transaction.Commit(); transaction = null;
            try { File.Delete(Path.Combine(root, "unins000.exe")); File.Delete(Path.Combine(root, "unins000.dat")); RemovePreviousInnoEntry(); } catch { }
            progress.Value = 100; status.Text = "Finishing setup..."; Application.DoEvents();
            SetupProgram.InstallRoot = root;
            ShowPage(3);
        }
        catch (Exception ex) {
            Exception failure = transaction == null ? ex : transaction.Recover(ex);
            MessageBox.Show(this, "Setup could not finish the installation.\n\n" + failure.Message, "SharkOptimizer Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            ShowPage(1);
        }
    }

    private static void CreateShortcut(string path, string root)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        Type shellType = Type.GetTypeFromProgID("WScript.Shell");
        object shell = Activator.CreateInstance(shellType);
        try {
            object shortcut = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { path });
            Type type = shortcut.GetType();
            type.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, new object[] { Path.Combine(root, "SharkOptimizer.exe") });
            type.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut, new object[] { root });
            type.InvokeMember("Description", BindingFlags.SetProperty, null, shortcut, new object[] { "SharkOptimizer " + SetupProgram.Version });
            type.InvokeMember("IconLocation", BindingFlags.SetProperty, null, shortcut, new object[] { Path.Combine(root, "SharkOptimizer.exe") });
            type.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
            if (Marshal.IsComObject(shortcut)) Marshal.ReleaseComObject(shortcut);
        }
        finally { if (Marshal.IsComObject(shell)) Marshal.ReleaseComObject(shell); }
    }

    private static void RemovePreviousInnoEntry()
    {
        string[] roots = {
            @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
            @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        };
        foreach (string path in roots) {
            try {
                using (RegistryKey root = Registry.LocalMachine.OpenSubKey(path, true)) {
                    if (root == null) continue;
                    foreach (string name in root.GetSubKeyNames()) {
                        bool oldEntry = false;
                        try {
                            using (RegistryKey entry = root.OpenSubKey(name)) {
                                if (entry != null && String.Equals(Convert.ToString(entry.GetValue("DisplayName")), "SharkOptimizer", StringComparison.OrdinalIgnoreCase) && Convert.ToString(entry.GetValue("UninstallString")).IndexOf("unins000.exe", StringComparison.OrdinalIgnoreCase) >= 0)
                                    oldEntry = true;
                            }
                        } catch { }
                        if (oldEntry) {
                            try { root.DeleteSubKeyTree(name, false); } catch { }
                        }
                    }
                }
            } catch { }
        }
    }
}
