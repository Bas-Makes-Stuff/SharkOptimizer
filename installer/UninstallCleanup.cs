using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class UninstallCleanup
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool MoveFileEx(string existing, string replacement, int flags);

    internal static void ValidateRoot(string root)
    {
        string full = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
        if (!String.Equals(full, root, StringComparison.OrdinalIgnoreCase) || full == Path.GetPathRoot(full).TrimEnd(Path.DirectorySeparatorChar))
            throw new InvalidOperationException("The installation folder is invalid.");
        string uninstaller = Path.Combine(full, "Uninstall-SharkOptimizer.exe");
        if (!File.Exists(uninstaller) || FileVersionInfo.GetVersionInfo(uninstaller).ProductName != "SharkOptimizer")
            throw new InvalidOperationException("This folder does not contain a SharkOptimizer installation.");
        if ((File.GetAttributes(full) & FileAttributes.ReparsePoint) != 0 ||
            (Directory.Exists(Path.Combine(full, "data")) && (File.GetAttributes(Path.Combine(full, "data")) & FileAttributes.ReparsePoint) != 0))
            throw new InvalidOperationException("Uninstall cannot remove files through a linked installation folder.");
    }

    internal static void RequireAppClosed(string root)
    {
        string app = Path.Combine(root, "SharkOptimizer.exe");
        if (!File.Exists(app)) return;
        try { using (FileStream stream = File.Open(app, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { } }
        catch (IOException) { throw new InvalidOperationException("Choose Exit from SharkOptimizer's tray menu, then run uninstall again."); }
    }

    internal static string PrepareHelper()
    {
        string folder = Path.Combine(Path.GetTempPath(), "SharkOptimizer-Uninstall-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        string helper = Path.Combine(folder, "Cleanup.exe");
        try { File.Copy(Application.ExecutablePath, helper); }
        catch { RemoveEmptyDirectory(folder); throw; }
        // Windows removes this running helper and its empty folder at the next restart.
        MoveFileEx(helper, null, 4); MoveFileEx(folder, null, 4);
        return helper;
    }

    internal static void Run(string root, string parentId)
    {
        try {
            ValidateRoot(root);
            int id; if (!Int32.TryParse(parentId, out id) || id <= 0) throw new ArgumentException("Invalid uninstall process.");
            try { using (Process parent = Process.GetProcessById(id)) if (!parent.WaitForExit(30000)) throw new TimeoutException("The uninstaller did not exit in time."); }
            catch (ArgumentException) { }
            using (RegistryKey key = Registry.LocalMachine.OpenSubKey(SetupProgram.UninstallKey)) {
                if (key != null && !String.Equals(Convert.ToString(key.GetValue("InstallLocation")), root, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("The Windows uninstall record belongs to another installation.");
            }
            DeletePayload(root);
            Registry.LocalMachine.DeleteSubKeyTree(SetupProgram.UninstallKey, false);
            MessageBox.Show("SharkOptimizer was removed. Saved settings and change history were kept.",
                "Uninstall SharkOptimizer", MessageBoxButtons.OK, MessageBoxIcon.Information);
        } catch (Exception ex) {
            MessageBox.Show("Some SharkOptimizer files could not be removed.\n\n" + ex.Message + "\n\nFolder: " + root,
                "Uninstall SharkOptimizer", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    internal static void DeletePayload(string root)
    {
        ValidateRoot(root);
        string[] files = { Path.Combine(root, "SharkOptimizer.exe"), Path.Combine(root, "data", "shark.ico"), Path.Combine(root, "Uninstall-SharkOptimizer.exe") };
        foreach (string file in files) {
            for (int attempt = 0; File.Exists(file); attempt++) {
                try { File.Delete(file); }
                catch (IOException) { if (attempt >= 29) throw; Thread.Sleep(1000); }
            }
        }
        RemoveEmptyDirectory(Path.Combine(root, "data")); RemoveEmptyDirectory(root);
    }

    internal static void RemoveEmptyDirectory(string path)
    {
        if (!Directory.Exists(path)) return;
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) return;
        if (Directory.GetFileSystemEntries(path).Length == 0) Directory.Delete(path, false);
    }

    internal static void RemoveOwnedShortcut(string path, string root)
    {
        object shell = null, shortcut = null;
        try {
            shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", true));
            shortcut = shell.GetType().InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { path });
            string target = Convert.ToString(shortcut.GetType().InvokeMember("TargetPath", BindingFlags.GetProperty, null, shortcut, null));
            if (String.Equals(Path.GetFullPath(target), Path.Combine(root, "SharkOptimizer.exe"), StringComparison.OrdinalIgnoreCase)) File.Delete(path);
        } finally {
            if (shortcut != null && Marshal.IsComObject(shortcut)) Marshal.ReleaseComObject(shortcut);
            if (shell != null && Marshal.IsComObject(shell)) Marshal.ReleaseComObject(shell);
        }
    }
}
