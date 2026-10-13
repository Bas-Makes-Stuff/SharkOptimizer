using System;
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
[assembly: AssemblyProduct("SharkOptimizer")]
[assembly: AssemblyFileVersion("1.5.1.0")]
[assembly: AssemblyInformationalVersion("1.5.1")]

internal static class SetupProgram
{
    internal const string Version = "1.5.1";
    internal static string InstallRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "SharkOptimizer");
    internal const string UninstallKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\SharkOptimizer";

    [STAThread]
    private static void Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        if (args.Length > 0 && String.Equals(args[0], "/uninstall", StringComparison.OrdinalIgnoreCase))
        {
            Uninstall();
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
            RemoveShortcuts();
            try { Registry.LocalMachine.DeleteSubKeyTree(UninstallKey, false); } catch { }
            string cleanup = Path.Combine(Path.GetTempPath(), "SharkOptimizer-Uninstall-" + Guid.NewGuid().ToString("N") + ".ps1");
            string script = "$ErrorActionPreference='SilentlyContinue'\r\n" +
                "Wait-Process -Id " + Process.GetCurrentProcess().Id + " -ErrorAction SilentlyContinue\r\n" +
                "Start-Sleep -Milliseconds 300\r\n" +
                "$root='" + root.Replace("'", "''") + "'\r\n" +
                "Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue\r\n" +
                "Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue\r\n";
            File.WriteAllText(cleanup, script, Encoding.UTF8);
            Process.Start(new ProcessStartInfo {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + cleanup + "\"",
                CreateNoWindow = true, UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden
            });
            MessageBox.Show("SharkOptimizer is being removed. Saved settings and change history were kept.",
                "Uninstall SharkOptimizer", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            MessageBox.Show("The app could not be fully removed.\n\n" + ex.Message, "Uninstall SharkOptimizer",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private static void RemoveShortcuts()
    {
        string[] paths = {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms), "SharkOptimizer"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "SharkOptimizer"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "SharkOptimizer.lnk")
        };
        foreach (string path in paths) {
            try { if (Directory.Exists(path)) Directory.Delete(path, true); else if (File.Exists(path)) File.Delete(path); } catch { }
        }
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
        desktopLink.Text = "Create a desktop shortcut"; desktopLink.Checked = true; desktopLink.AutoSize = true; desktopLink.Location = new Point(44, 212); body.Controls.Add(desktopLink);
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
            string app = Path.Combine(folder.Text, "Start-SharkOptimizer.bat");
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
        try {
            string data = Path.Combine(root, "data"), fonts = Path.Combine(root, "data", "fonts");
            Directory.CreateDirectory(fonts);
            string[] names = { "Start-SharkOptimizer.bat", "SharkOptimizer.ps1", "SharkOptimizer-Launcher.ps1", "Poppins-Regular.ttf", "Poppins-Bold.ttf", "shark.ico" };
            string[] resources = { "SharkOptimizer.Payload.Start-SharkOptimizer.bat", "SharkOptimizer.Payload.SharkOptimizer.ps1", "SharkOptimizer.Payload.SharkOptimizer-Launcher.ps1", "SharkOptimizer.Payload.Poppins-Regular.ttf", "SharkOptimizer.Payload.Poppins-Bold.ttf", "SharkOptimizer.Payload.shark.ico" };
            for (int i = 0; i < names.Length; i++) {
                status.Text = "Installing " + names[i] + "..."; Application.DoEvents();
                string destination = i == 0 ? Path.Combine(root, names[i]) : (i < 3 ? Path.Combine(data, names[i]) : Path.Combine(fonts, names[i]));
                using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream(resources[i])) {
                    if (input == null) throw new InvalidOperationException("Setup payload is missing " + names[i] + ".");
                    using (FileStream output = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None)) input.CopyTo(output);
                }
                progress.Value = (i + 1) * 70 / names.Length; Application.DoEvents();
            }
            status.Text = "Creating shortcuts and uninstall information..."; Application.DoEvents();
            string uninstaller = Path.Combine(root, "Uninstall-SharkOptimizer.exe");
            File.Copy(Application.ExecutablePath, uninstaller, true);
            try { File.Delete(Path.Combine(root, "unins000.exe")); File.Delete(Path.Combine(root, "unins000.dat")); } catch { }
            CreateShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "SharkOptimizer", "SharkOptimizer.lnk"), root);
            if (desktopLink.Checked) CreateShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "SharkOptimizer.lnk"), root);
            RemovePreviousInnoEntry();
            using (RegistryKey key = Registry.LocalMachine.CreateSubKey(SetupProgram.UninstallKey)) {
                key.SetValue("DisplayName", "SharkOptimizer");
                key.SetValue("DisplayVersion", SetupProgram.Version);
                key.SetValue("Publisher", "Bas Makes Stuff");
                key.SetValue("InstallLocation", root);
                key.SetValue("DisplayIcon", Path.Combine(data, "shark.ico"));
                key.SetValue("UninstallString", "\"" + uninstaller + "\" /uninstall");
                key.SetValue("NoModify", 1, RegistryValueKind.DWord);
                key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            }
            progress.Value = 100; status.Text = "Finishing setup..."; Application.DoEvents();
            SetupProgram.InstallRoot = root;
            ShowPage(3);
        }
        catch (Exception ex) {
            MessageBox.Show(this, "Setup could not finish the installation.\n\n" + ex.Message, "SharkOptimizer Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
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
            type.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, new object[] { Path.Combine(root, "Start-SharkOptimizer.bat") });
            type.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut, new object[] { root });
            type.InvokeMember("Description", BindingFlags.SetProperty, null, shortcut, new object[] { "SharkOptimizer " + SetupProgram.Version });
            type.InvokeMember("IconLocation", BindingFlags.SetProperty, null, shortcut, new object[] { Path.Combine(root, "data", "shark.ico") });
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
