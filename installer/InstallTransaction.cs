using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using Microsoft.Win32;

// Protect both payload files and installation metadata until setup finishes.
internal sealed class InstallTransaction
{
    private sealed class SavedFile { internal string Path, Backup; internal bool Existed, NeedsRestore; }
    private sealed class SavedValue { internal object Value; internal RegistryValueKind Kind; }
    private readonly List<SavedFile> files = new List<SavedFile>();
    private readonly List<string> stagingFiles = new List<string>();
    private readonly Dictionary<string, SavedValue> uninstallValues = new Dictionary<string, SavedValue>();
    private readonly string folder, startupXml;
    private readonly bool uninstallExisted;
    private bool metadataChanged;

    internal InstallTransaction(string root)
    {
        root = Path.GetFullPath(root);
        startupXml = SharkOptimizer.Platform.StartupRegistration.CaptureXml();
        using (RegistryKey key = Registry.LocalMachine.OpenSubKey(SetupProgram.UninstallKey))
        {
            uninstallExisted = key != null;
            if (key != null) foreach (string name in key.GetValueNames()) uninstallValues[name] = new SavedValue { Value = key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames), Kind = key.GetValueKind(name) };
        }
        folder = Path.Combine(root, ".shark-setup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
    }

    internal string StageResource(string resource, string name)
    {
        string path = Path.Combine(folder, name);
        if (!String.Equals(Path.GetDirectoryName(path), folder, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Invalid setup payload path.");
        stagingFiles.Add(path);
        using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource))
        {
            if (input == null) throw new InvalidOperationException("Setup payload is missing " + name + ".");
            using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) input.CopyTo(output);
        }
        return path;
    }

    internal string StageSetup()
    {
        string path = Path.Combine(folder, "setup.exe"); stagingFiles.Add(path);
        File.Copy(Assembly.GetExecutingAssembly().Location, path);
        return path;
    }

    internal static void ValidatePayload(string app, string icon)
    {
        Version version;
        if (!Version.TryParse(FileVersionInfo.GetVersionInfo(app).FileVersion, out version) || version != new Version(SetupProgram.Version + ".0")) throw new InvalidDataException("The embedded app version does not match this installer.");
        using (var image = new Icon(icon)) if (image.Width < 1 || image.Height < 1) throw new InvalidDataException("The setup icon is invalid.");
    }

    internal void CaptureFile(string path, bool uncertainWrite = true)
    {
        path = Path.GetFullPath(path);
        if (files.Exists(x => String.Equals(x.Path, path, StringComparison.OrdinalIgnoreCase))) return;
        bool exists = File.Exists(path);
        string backup = Path.Combine(folder, "backup-" + files.Count);
        if (exists) { File.Copy(path, backup); stagingFiles.Add(backup); }
        files.Add(new SavedFile { Path = path, Existed = exists, Backup = backup, NeedsRestore = uncertainWrite });
    }

    internal void ReplaceFile(string staged, string destination)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(destination));
        CaptureFile(destination, false);
        if (File.Exists(destination)) File.Replace(staged, destination, null);
        else File.Move(staged, destination);
        files.Find(x => String.Equals(x.Path, Path.GetFullPath(destination), StringComparison.OrdinalIgnoreCase)).NeedsRestore = true;
    }

    internal void ChangingMetadata() { metadataChanged = true; }
    internal void Commit() { Cleanup(); }

    internal Exception Recover(Exception failure)
    {
        var errors = new List<string>();
        for (int i = files.Count - 1; i >= 0; i--)
        {
            SavedFile file = files[i];
            if (!file.NeedsRestore) continue;
            try
            {
                if (file.Existed)
                {
                    // User shortcuts may live on a different drive from Program Files.
                    if (!String.Equals(Path.GetPathRoot(file.Backup), Path.GetPathRoot(file.Path), StringComparison.OrdinalIgnoreCase)) File.Copy(file.Backup, file.Path, true);
                    else if (File.Exists(file.Path)) File.Replace(file.Backup, file.Path, null);
                    else File.Move(file.Backup, file.Path);
                }
                else if (File.Exists(file.Path)) File.Delete(file.Path);
            }
            catch (Exception ex) { errors.Add(file.Path + ": " + ex.Message); }
        }
        if (metadataChanged)
        {
            try { SharkOptimizer.Platform.StartupRegistration.RestoreXml(startupXml); } catch (Exception ex) { errors.Add("Startup task: " + ex.Message); }
            try
            {
                if (!uninstallExisted) Registry.LocalMachine.DeleteSubKey(SetupProgram.UninstallKey, false);
                else using (RegistryKey key = Registry.LocalMachine.CreateSubKey(SetupProgram.UninstallKey))
                {
                    if (key == null) throw new InvalidOperationException("Could not restore the uninstall record.");
                    foreach (string name in key.GetValueNames()) if (!uninstallValues.ContainsKey(name)) key.DeleteValue(name, false);
                    foreach (var value in uninstallValues) key.SetValue(value.Key, value.Value.Value, value.Value.Kind);
                }
            }
            catch (Exception ex) { errors.Add("Uninstall record: " + ex.Message); }
        }
        if (errors.Count == 0) { Cleanup(); return new InvalidOperationException(failure.Message + Environment.NewLine + "Setup restored the previous installation files and registration.", failure); }
        return new InvalidOperationException(failure.Message + Environment.NewLine + "Recovery is incomplete. Previous file copies remain in " + folder + Environment.NewLine + String.Join(Environment.NewLine, errors.ToArray()), failure);
    }

    private void Cleanup()
    {
        foreach (string path in stagingFiles) try { if (File.Exists(path)) File.Delete(path); } catch { }
        try { Directory.Delete(folder, false); } catch { }
    }
}
