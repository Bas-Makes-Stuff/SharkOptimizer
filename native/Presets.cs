using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace SharkOptimizer.NativeApp
{
    internal sealed class UserPreset
    {
        public string Name { get; set; }
        public List<string> Ids { get; set; }
        public UserPreset() { Ids = new List<string>(); }
    }

    internal static class PresetCodec
    {
        internal static string CleanName(string name)
        {
            string result = Regex.Replace(name ?? "", @"[\p{C}|]", " ").Trim();
            if (result.Length > 80) result = result.Substring(0, 80).Trim();
            return result.Length == 0 ? "Imported preset" : result;
        }

        internal static UserPreset Normalize(string name, IEnumerable ids, Func<string, string> map)
        {
            if (ids == null || ids is string) throw new InvalidDataException("The preset has no option list.");
            var valid = new HashSet<string>(StringComparer.OrdinalIgnoreCase); int count = 0;
            foreach (object value in ids)
            {
                if (++count > 1000) throw new InvalidDataException("A preset contains too many options.");
                if (!(value is string)) continue; string id = map((string)value); if (!String.IsNullOrWhiteSpace(id)) valid.Add(id);
            }
            if (valid.Count == 0) throw new InvalidDataException("The preset contains no supported options.");
            return new UserPreset { Name = CleanName(name), Ids = valid.OrderBy(x => x).ToList() };
        }

        internal static string Encode(UserPreset preset, Func<string, string> exportId)
        {
            string name = CleanName(preset.Name); if (name.Length > 40) name = name.Substring(0, 40);
            byte[] data = Encoding.UTF8.GetBytes(name + "|" + String.Join(",", preset.Ids.Select(exportId).ToArray()));
            if (data.Length > 16000) throw new InvalidDataException("This preset is too large for a share code.");
            using (var output = new MemoryStream())
            {
                using (var compressed = new DeflateStream(output, CompressionMode.Compress, true)) compressed.Write(data, 0, data.Length);
                return "SHARK1-" + Convert.ToBase64String(output.ToArray()).TrimEnd('=').Replace('+', '-').Replace('/', '_');
            }
        }

        internal static UserPreset Decode(string code, Func<string, string> map)
        {
            code = (code ?? "").Trim();
            if (code.Length > 32000 || !Regex.IsMatch(code, @"^SHARK1-[A-Za-z0-9_-]+$")) throw new InvalidDataException("Enter a valid SHARK1 share code.");
            string encoded = code.Substring(7).Replace('-', '+').Replace('_', '/'); while (encoded.Length % 4 != 0) encoded += "=";
            using (var input = new MemoryStream(Convert.FromBase64String(encoded)))
            using (var compressed = new DeflateStream(input, CompressionMode.Decompress))
            using (var reader = new StreamReader(compressed, new UTF8Encoding(false, true)))
            {
                var text = new StringBuilder(); var buffer = new char[1024]; int read;
                while ((read = reader.Read(buffer, 0, buffer.Length)) > 0) { if (text.Length + read > 8000) throw new InvalidDataException("The decoded share code is too large."); text.Append(buffer, 0, read); }
                string[] parts = text.ToString().Split('|'); if (parts.Length != 2) throw new InvalidDataException("The share code has an invalid format.");
                return Normalize(parts[0], parts[1].Split(','), map);
            }
        }

        private static object Property(IDictionary<string, object> item, string name)
        { return item.FirstOrDefault(x => String.Equals(x.Key, name, StringComparison.OrdinalIgnoreCase)).Value; }

        internal static List<UserPreset> ReadJson(string json, Func<string, string> map)
        {
            if (Encoding.UTF8.GetByteCount(json) > 1024 * 1024) throw new InvalidDataException("Preset files must be no larger than 1 MB.");
            var serializer = new JavaScriptSerializer(); object parsed = serializer.DeserializeObject(json);
            var root = parsed as IDictionary<string, object>; IEnumerable entries = parsed as object[];
            if (root != null)
            {
                object format = Property(root, "format"); if (format != null && Convert.ToString(format) != "SharkOptimizerPresets") throw new InvalidDataException("This is not a SharkOptimizer preset file.");
                object version = Property(root, "version"); if (version != null && Convert.ToInt32(version, CultureInfo.InvariantCulture) != 1) throw new InvalidDataException("This preset file uses an unsupported format version.");
                entries = Property(root, "presets") as IEnumerable;
                if (entries == null && Property(root, "name") != null) entries = new[] { root };
            }
            if (entries == null || entries is string) throw new InvalidDataException("The file does not contain a preset list.");
            var result = new List<UserPreset>(); int count = 0;
            foreach (object entry in entries)
            {
                if (++count > 100) throw new InvalidDataException("Preset files can contain up to 100 presets.");
                var item = entry as IDictionary<string, object>; if (item == null) continue;
                try { result.Add(Normalize(Convert.ToString(Property(item, "name")), Property(item, "ids") as IEnumerable, map)); }
                catch (InvalidDataException) { }
            }
            if (result.Count == 0) throw new InvalidDataException("No presets with supported options were found.");
            return result;
        }

        internal static string WriteJson(IEnumerable<UserPreset> presets, Func<string, string> exportId)
        {
            var payload = new { format = "SharkOptimizerPresets", version = 1, exported = DateTime.Now.ToString("s"),
                presets = presets.Select(x => new { name = x.Name, ids = x.Ids.Select(exportId).ToArray() }).ToArray() };
            return new JavaScriptSerializer().Serialize(payload);
        }
    }

    internal sealed partial class MainWindow
    {
        private UserPreset _editingPreset;
        private Button _savePresetButton;
        private Button _finishPresetEditing;
        private TextBlock _presetEditStatus;
        private string _presetImportNotice;

        private static string ExportPresetId(string id)
        { string legacy = LegacyTweakAliases.FirstOrDefault(x => String.Equals(x.Value, id, StringComparison.OrdinalIgnoreCase)).Key; return legacy ?? id; }

        private string UniquePresetName(string name, IEnumerable<UserPreset> existing)
        {
            string basis = PresetCodec.CleanName(name), candidate = basis; int index = 2;
            while (existing.Any(x => String.Equals(x.Name, candidate, StringComparison.OrdinalIgnoreCase))) { string suffix = " (" + index++ + ")"; candidate = basis.Substring(0, Math.Min(basis.Length, 80 - suffix.Length)) + suffix; }
            return candidate;
        }

        private void ImportLegacyPresets()
        {
            if (_state.LegacyPresetsImported) return;
            string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SharkOptimizer", "presets.json");
            try
            {
                if (File.Exists(path))
                {
                    if (new FileInfo(path).Length > 1024 * 1024) throw new InvalidDataException("The previous preset file exceeds 1 MB.");
                    foreach (UserPreset preset in PresetCodec.ReadJson(File.ReadAllText(path), MapLegacyTweakId))
                    {
                        if (_state.SavedPresets.Count >= 100) break;
                        preset.Name = UniquePresetName(preset.Name, _state.SavedPresets); _state.SavedPresets.Add(preset);
                    }
                    _presetImportNotice = "Imported saved presets from the previous PowerShell app.";
                }
            }
            catch (Exception ex) { _presetImportNotice = "Previous presets were not imported: " + ex.Message + " You can import a repaired preset file manually."; }
            _state.LegacyPresetsImported = true; _legacyStateMigrated = true;
        }

        private bool CommitPresets(List<UserPreset> presets)
        {
            var previous = _state.SavedPresets;
            try { if (presets.Count > 100) throw new InvalidDataException("Keep up to 100 saved presets."); _state.SavedPresets = presets; SaveState(); return true; }
            catch (Exception ex) { _state.SavedPresets = previous; MessageBox.Show(this, ex.Message, "Preset could not be saved", MessageBoxButton.OK, MessageBoxImage.Warning); return false; }
        }

        private List<UserPreset> ClonePresets()
        { return _state.SavedPresets.Select(x => new UserPreset { Name = x.Name, Ids = new List<string>(x.Ids) }).ToList(); }

        private string ReadPresetText(string title, string prompt, string value, Window owner = null)
        {
            var dialog = new Window { Title = title, Owner = owner ?? this, Width = 510, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Brush(BackgroundColor), Foreground = Brushes.White, FontFamily = FontFamily };
            CopyControlStyles(dialog);
            var body = new StackPanel { Margin = new Thickness(20) }; body.Children.Add(Text(prompt, 12, Brushes.White, false));
            var input = new TextBox { Text = value ?? "", MaxLength = title.Contains("code") ? 32000 : 80, Margin = new Thickness(0, 10, 0, 0), Padding = new Thickness(9), Background = Brush(SurfaceRaised), Foreground = Brushes.White, BorderBrush = Brush(BorderColor) }; body.Children.Add(input);
            var row = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, -5, 0) };
            var ok = ActionButton("Save", true); ok.IsDefault = true; ok.Click += delegate { if (!String.IsNullOrWhiteSpace(input.Text)) dialog.DialogResult = true; };
            var cancel = ActionButton("Cancel", false); cancel.IsCancel = true; row.Children.Add(ok); row.Children.Add(cancel); body.Children.Add(row); dialog.Content = body;
            dialog.Loaded += delegate { input.Focus(); input.SelectAll(); }; return dialog.ShowDialog() == true ? input.Text : null;
        }

        private void RefreshPresetEditStatus()
        {
            if (_savePresetButton == null) return; _savePresetButton.Content = _editingPreset == null ? "Save selection" : "Save preset changes";
            _finishPresetEditing.Visibility = _editingPreset == null ? Visibility.Collapsed : Visibility.Visible;
            if (_presetsExpander != null) { _presetsExpander.Header = "Presets · 5 built-in + " + _state.SavedPresets.Count + " saved"; if (_editingPreset != null) _presetsExpander.IsExpanded = true; }
            _savePresetButton.IsEnabled = _selectedTweaks.Count > 0 || (_editingPreset != null && _editingPreset.Ids.Any(id => _state.Applied.Any(a => a.Id == id) || !CanSelectTweak(id)));
            _presetEditStatus.Text = _editingPreset == null ? (_presetImportNotice ?? "Save your selected options or manage your own presets and share codes.") : "Editing “" + _editingPreset.Name + "”. Adjust the selected options, then save preset changes. Already applied options in this preset are kept.";
        }

        private void SaveUserPreset()
        {
            var ids = new HashSet<string>(_selectedTweaks, StringComparer.OrdinalIgnoreCase);
            if (_editingPreset != null) ids.UnionWith(_editingPreset.Ids.Where(x => _state.Applied.Any(a => a.Id == x) || !CanSelectTweak(x)));
            if (ids.Count == 0) { MessageBox.Show(this, "Select options on Optimize first.", "Save preset", MessageBoxButton.OK, MessageBoxImage.Information); return; }
            string name = _editingPreset == null ? ReadPresetText("Save preset", "Name this preset", "") : _editingPreset.Name;
            if (name == null) return; var changed = ClonePresets();
            if (_editingPreset == null) name = UniquePresetName(name, changed); else changed.RemoveAll(x => String.Equals(x.Name, name, StringComparison.OrdinalIgnoreCase));
            changed.Add(new UserPreset { Name = name, Ids = ids.OrderBy(x => x).ToList() });
            if (CommitPresets(changed)) { _editingPreset = null; _presetImportNotice = "Saved “" + name + "” with " + ids.Count + " options."; RefreshPresetEditStatus(); }
        }

        private void ReviewUserPreset(UserPreset preset, bool edit)
        {
            _selectedTweaks.Clear(); foreach (string id in preset.Ids) if (CanSelectTweak(id) && !_state.Applied.Any(x => x.Id == id)) _selectedTweaks.Add(id);
            _editingPreset = edit ? preset : null; ShowPage("Optimize");
            _tweakSearch.Clear(); _categoryFilter.SelectedIndex = 0; RenderTweakCards(); RefreshPresetEditStatus();
        }

        private string PresetOptionNames(IEnumerable<string> ids)
        { return String.Join(Environment.NewLine, ids.Select(id => { TweakDefinition option = _catalogue.FirstOrDefault(x => x.Id == id); return "• " + (option == null ? id : Definitions.Any(x => x.Id == id) ? Localization.Translate(option.Name) : option.Name); }).OrderBy(x => x).ToArray()); }

        private void ShowPresetManager()
        {
            var dialog = new Window { Title = "Your presets", Owner = this, Width = 760, Height = 650, MinWidth = 600, MinHeight = 450, WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Brush(BackgroundColor), Foreground = Brushes.White, FontFamily = FontFamily };
            CopyControlStyles(dialog);
            var body = new StackPanel { Margin = new Thickness(22) }; body.Children.Add(Text("Your presets", 20, Brushes.White, true)); body.Children.Add(Text("Manage saved selections. Review and Edit select options on Optimize; they never apply Windows changes.", 11, Brush(MutedColor), false, 0, 5));
            var picker = new ComboBox { Height = 36, Margin = new Thickness(0, 12, 0, 5), Background = Brush(SurfaceRaised), Foreground = Brushes.White };
            var compareWith = new ComboBox { Height = 36, Background = Brush(SurfaceRaised), Foreground = Brushes.White };
            Localization.KeepData(picker); Localization.KeepData(compareWith);
            body.Children.Add(picker); var details = new TextBox { Height = 170, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(10), Background = Brush(SurfaceColor), Foreground = Brushes.White, BorderBrush = Brush(BorderColor) }; body.Children.Add(details);
            var actions = new WrapPanel { Margin = new Thickness(-5, 8, 0, 0) }; body.Children.Add(actions);
            Func<UserPreset> selected = delegate { return _state.SavedPresets.FirstOrDefault(x => x.Name == Convert.ToString(picker.SelectedItem)); };
            Action refresh = delegate { string previous = Convert.ToString(picker.SelectedItem); string[] names = _state.SavedPresets.Select(x => x.Name).OrderBy(x => x).ToArray(); picker.ItemsSource = names; compareWith.ItemsSource = names; picker.SelectedItem = names.Contains(previous) ? previous : names.FirstOrDefault(); compareWith.SelectedIndex = names.Length > 1 ? 1 : 0; details.Text = selected() == null ? "No saved presets yet. Save a selection on Optimize, or import a preset file or share code." : PresetOptionNames(selected().Ids); };
            picker.SelectionChanged += delegate { details.Text = selected() == null ? "No preset selected." : PresetOptionNames(selected().Ids); };
            Action<string, Action> action = delegate(string label, Action callback) { var button = ActionButton(label, false); button.Click += delegate { try { callback(); } catch (Exception ex) { MessageBox.Show(dialog, ex.Message, label, MessageBoxButton.OK, MessageBoxImage.Warning); } }; actions.Children.Add(button); };
            action("Review", delegate { UserPreset preset = selected(); if (preset != null) { dialog.Close(); ReviewUserPreset(preset, false); } });
            action("Edit options", delegate { UserPreset preset = selected(); if (preset != null) { dialog.Close(); ReviewUserPreset(preset, true); } });
            action("Rename", delegate { UserPreset preset = selected(); if (preset == null) return; string name = ReadPresetText("Rename preset", "Preset name", preset.Name, dialog); if (name == null) return; name = PresetCodec.CleanName(name); var changed = ClonePresets(); if (changed.Any(x => x.Name != preset.Name && String.Equals(x.Name, name, StringComparison.OrdinalIgnoreCase))) throw new InvalidDataException("A preset already has that name."); changed.First(x => x.Name == preset.Name).Name = name; if (CommitPresets(changed)) { if (_editingPreset != null && _editingPreset.Name == preset.Name) _editingPreset = changed.First(x => x.Name == name); refresh(); picker.SelectedItem = name; RefreshPresetEditStatus(); } });
            action("Duplicate", delegate { UserPreset preset = selected(); if (preset == null) return; var changed = ClonePresets(); string name = UniquePresetName(preset.Name + " copy", changed); changed.Add(new UserPreset { Name = name, Ids = new List<string>(preset.Ids) }); if (CommitPresets(changed)) { refresh(); picker.SelectedItem = name; } });
            action("Copy code", delegate { UserPreset preset = selected(); if (preset != null) { Clipboard.SetText(PresetCodec.Encode(preset, ExportPresetId)); details.Text = "Share code copied.\n\n" + PresetOptionNames(preset.Ids); } });
            action("Delete", delegate { UserPreset preset = selected(); if (preset == null || MessageBox.Show(dialog, "Delete “" + preset.Name + "”? Applied Windows changes are kept.", "Delete preset", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return; var changed = ClonePresets(); changed.RemoveAll(x => x.Name == preset.Name); if (CommitPresets(changed)) { if (_editingPreset != null && _editingPreset.Name == preset.Name) _editingPreset = null; refresh(); RefreshPresetEditStatus(); } });
            body.Children.Add(Text("Compare with", 11, Brush(MutedColor), true, 0, 10)); body.Children.Add(compareWith);
            var compare = ActionButton("Compare presets", false); compare.Margin = new Thickness(-5, 6, 0, 0); compare.Click += delegate { UserPreset left = selected(), right = _state.SavedPresets.FirstOrDefault(x => x.Name == Convert.ToString(compareWith.SelectedItem)); if (left == null || right == null) return; details.Text = "In both presets:\n" + PresetOptionNames(left.Ids.Intersect(right.Ids)) + "\n\nOnly in “" + left.Name + "”:\n" + PresetOptionNames(left.Ids.Except(right.Ids)) + "\n\nOnly in “" + right.Name + "”:\n" + PresetOptionNames(right.Ids.Except(left.Ids)); }; body.Children.Add(compare);
            action("Export JSON", delegate { if (_state.SavedPresets.Count == 0) return; var file = new Microsoft.Win32.SaveFileDialog { Filter = "SharkOptimizer presets (*.json)|*.json", FileName = "SharkOptimizer-Presets.json" }; if (LocalizedFileDialog.Show(file, dialog) == true) File.WriteAllText(file.FileName, PresetCodec.WriteJson(_state.SavedPresets, ExportPresetId), new UTF8Encoding(false)); });
            action("Import JSON", delegate { var file = new Microsoft.Win32.OpenFileDialog { Filter = "SharkOptimizer presets (*.json)|*.json" }; if (LocalizedFileDialog.Show(file, dialog) != true) return; if (new FileInfo(file.FileName).Length > 1024 * 1024) throw new InvalidDataException("Preset files must be no larger than 1 MB."); ImportPresetBatch(PresetCodec.ReadJson(File.ReadAllText(file.FileName), MapLegacyTweakId), dialog); refresh(); });
            action("Import code", delegate { string code = ReadPresetText("Import code", "Paste a SHARK1 share code", "", dialog); if (code != null) { ImportPresetBatch(new List<UserPreset> { PresetCodec.Decode(code, MapLegacyTweakId) }, dialog); refresh(); } });
            dialog.Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }; refresh(); dialog.ShowDialog();
        }

        private void ImportPresetBatch(List<UserPreset> incoming, Window owner)
        {
            var changed = ClonePresets(); foreach (UserPreset preset in incoming) changed.Add(new UserPreset { Name = UniquePresetName(preset.Name, changed), Ids = new List<string>(preset.Ids) });
            if (changed.Count > 100) throw new InvalidDataException("The import would exceed 100 saved presets.");
            string preview = String.Join(Environment.NewLine, changed.Skip(_state.SavedPresets.Count).Select(x => "• " + x.Name + " · " + x.Ids.Count + " options").ToArray());
            if (MessageBox.Show(owner, "Import these presets? Existing presets will be kept. Only supported option IDs are included.\n\n" + preview, "Review preset import", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes) CommitPresets(changed);
        }
    }
}
