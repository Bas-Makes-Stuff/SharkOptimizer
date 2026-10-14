using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;

namespace SharkOptimizer.NativeApp
{
    internal sealed class CustomRegistryValue
    {
        public string Path { get; set; }
        public string Name { get; set; }
        public object Value { get; set; }
        public string Type { get; set; }
    }

    internal sealed class CustomTweak
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Category { get; set; }
        public string Description { get; set; }
        public string Risk { get; set; }
        public string Warning { get; set; }
        public bool Recommended { get; set; }
        public bool Reboot { get; set; }
        public bool Enabled { get; set; }
        public List<CustomRegistryValue> Registry { get; set; }
        public CustomTweak() { Enabled = true; Category = "Custom"; Risk = "Caution"; Registry = new List<CustomRegistryValue>(); }
    }

    internal static class RegistryData
    {
        internal static object ConvertValue(object value, RegistryValueKind kind)
        {
            if (value == null) throw new InvalidDataException("Registry values cannot be null.");
            if (kind == RegistryValueKind.String || kind == RegistryValueKind.ExpandString)
            { if (!(value is string)) throw new InvalidDataException("String registry values must be text."); return value; }
            if (kind == RegistryValueKind.MultiString)
            {
                if (value is string) return new[] { (string)value };
                var items = value as IEnumerable; if (items == null) throw new InvalidDataException("MultiString values must be a text list.");
                var strings = new List<string>(); foreach (object item in items) { if (!(item is string)) throw new InvalidDataException("MultiString entries must be text."); strings.Add((string)item); }
                return strings.ToArray();
            }
            if (kind == RegistryValueKind.Binary || kind == RegistryValueKind.None)
            {
                var items = value as IEnumerable; if (items == null || value is string) throw new InvalidDataException("Binary values must be a list of bytes.");
                var bytes = new List<byte>(); foreach (object item in items) { if (item == null) throw new InvalidDataException("Binary entries cannot be null."); decimal number = Convert.ToDecimal(item, CultureInfo.InvariantCulture); if (number != Decimal.Truncate(number) || number < 0 || number > 255) throw new InvalidDataException("Binary entries must be integers from 0 to 255."); bytes.Add((byte)number); }
                return bytes.ToArray();
            }
            if (kind == RegistryValueKind.DWord || kind == RegistryValueKind.QWord)
            {
                string text = Convert.ToString(value, CultureInfo.InvariantCulture); decimal number;
                if (text.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) number = UInt64.Parse(text.Substring(2), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture);
                else number = Convert.ToDecimal(value, CultureInfo.InvariantCulture);
                if (number != Decimal.Truncate(number)) throw new InvalidDataException("Integer registry values cannot have a fractional part.");
                if (kind == RegistryValueKind.DWord) { if (number < Int32.MinValue || number > UInt32.MaxValue) throw new InvalidDataException("DWord value is outside the 32-bit range."); return number < 0 ? (int)number : unchecked((int)(uint)number); }
                if (number < Int64.MinValue || number > UInt64.MaxValue) throw new InvalidDataException("QWord value is outside the 64-bit range."); return number < 0 ? (long)number : unchecked((long)(ulong)number);
            }
            throw new InvalidDataException("Unsupported registry value type.");
        }

        internal static bool Equal(object actual, object expected, RegistryValueKind kind)
        {
            if (actual == null) return false; object converted = ConvertValue(expected, kind);
            if (kind == RegistryValueKind.Binary || kind == RegistryValueKind.None) return (actual as byte[]) != null && ((byte[])actual).SequenceEqual((byte[])converted);
            if (kind == RegistryValueKind.MultiString) return (actual as string[]) != null && ((string[])actual).SequenceEqual((string[])converted);
            return Object.Equals(actual, converted);
        }
    }

    internal static class CustomTweakCodec
    {
        internal const string ReviewWarning = "Custom registry tweak: review its targets in Settings before applying.";
        internal const string RestartWarning = "Restart Windows after applying.";
        private static object Member(IDictionary<string, object> item, string name)
        { return item.FirstOrDefault(x => String.Equals(x.Key, name, StringComparison.OrdinalIgnoreCase)).Value; }
        private static string Text(IDictionary<string, object> item, string name, string fallback = "")
        { object value = Member(item, name); return value == null ? fallback : Convert.ToString(value, CultureInfo.InvariantCulture); }
        private static bool Flag(IDictionary<string, object> item, string name, bool fallback)
        { object value = Member(item, name); if (value == null) return fallback; if (!(value is bool)) throw new InvalidDataException(name + " must be true or false."); return (bool)value; }

        internal static List<CustomTweak> ReadJson(string json)
        {
            if (Encoding.UTF8.GetByteCount(json) > 1024 * 1024) throw new InvalidDataException("Custom-tweak files must be no larger than 1 MB.");
            object parsed = new JavaScriptSerializer().DeserializeObject(json); var entries = parsed as object[]; var root = parsed as IDictionary<string, object>;
            if (root != null) { if (Text(root, "format") != "SharkOptimizerCustomTweaks" || Convert.ToInt32(Member(root, "version"), CultureInfo.InvariantCulture) != 1) throw new InvalidDataException("Unsupported custom-tweak format."); entries = Member(root, "tweaks") as object[]; }
            if (entries == null || entries.Length > 100) throw new InvalidDataException("Custom-tweak files must contain a list of up to 100 definitions.");
            var result = new List<CustomTweak>(); var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (object entry in entries)
            {
                var item = entry as IDictionary<string, object>; if (item == null) throw new InvalidDataException("A custom-tweak entry is not an object.");
                var tweak = new CustomTweak { Id = Text(item, "id").Trim().ToLowerInvariant(), Name = Text(item, "name"), Category = Text(item, "cat", "Custom"), Description = Text(item, "desc"), Risk = Text(item, "risk", "Caution"), Warning = Text(item, "warn"), Enabled = Flag(item, "enabled", true), Recommended = Flag(item, "rec", false), Reboot = Flag(item, "reboot", false) };
                var values = Member(item, "reg") as object[]; if (values == null || values.Length > 100) throw new InvalidDataException("Registry entries must be a list of up to 100 values.");
                foreach (object value in values) { var reg = value as IDictionary<string, object>; if (reg == null) throw new InvalidDataException("A registry entry is invalid."); tweak.Registry.Add(new CustomRegistryValue { Path = Text(reg, "path"), Name = Text(reg, "name"), Value = Member(reg, "value"), Type = Text(reg, "type", "DWord") }); }
                Validate(tweak); if (!ids.Add(tweak.Id)) throw new InvalidDataException("Custom-tweak IDs must be unique."); result.Add(tweak);
            }
            return result;
        }

        internal static string WriteJson(IEnumerable<CustomTweak> tweaks)
        { return new JavaScriptSerializer().Serialize(tweaks.Select(x => new { id = x.Id, name = x.Name, cat = x.Category, desc = x.Description, risk = x.Risk, warn = x.Warning, rec = x.Recommended, reboot = x.Reboot, enabled = x.Enabled, reg = x.Registry.Select(r => new { path = r.Path, name = r.Name, value = r.Value, type = r.Type }).ToArray() }).ToArray()); }

        internal static void Validate(CustomTweak tweak)
        {
            if (tweak == null || String.IsNullOrWhiteSpace(tweak.Id) || !Regex.IsMatch(tweak.Id, @"^[a-z][a-z0-9_.-]{0,79}$") || MainWindow.ReservedCustomIds().Contains(tweak.Id, StringComparer.OrdinalIgnoreCase)) throw new InvalidDataException("Use a unique custom ID that does not replace a built-in tweak or legacy alias.");
            if (String.IsNullOrWhiteSpace(tweak.Name) || tweak.Name.Length > 120 || tweak.Category == null || tweak.Category.Length > 80 || (tweak.Description ?? "").Length > 8192 || (tweak.Warning ?? "").Length > 8192) throw new InvalidDataException("A custom-tweak label is invalid or too long.");
            if (tweak.Registry == null || tweak.Registry.Count == 0 || tweak.Registry.Count > 100) throw new InvalidDataException("A custom tweak needs between 1 and 100 registry values.");
            var addresses = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (CustomRegistryValue reg in tweak.Registry) { ValueTarget target = Target(reg); if (!addresses.Add(target.Hive + "|" + target.KeyPath + "|" + target.Name)) throw new InvalidDataException("The same registry value appears more than once in a tweak."); }
        }

        internal static ValueTarget Target(CustomRegistryValue reg)
        {
            if (reg == null || String.IsNullOrWhiteSpace(reg.Path) || reg.Path.Length > 16384 || (reg.Name ?? "").Length > 16383 || reg.Path.Any(Char.IsControl) || (reg.Name ?? "").Any(Char.IsControl)) throw new InvalidDataException("A registry address is invalid.");
            string path = reg.Path.Trim(); if (path.StartsWith("Registry::", StringComparison.OrdinalIgnoreCase)) path = path.Substring(10);
            Match match = Regex.Match(path, @"^(HKCU|HKLM|HKCR|HKU|HKCC|HKEY_CURRENT_USER|HKEY_LOCAL_MACHINE|HKEY_CLASSES_ROOT|HKEY_USERS|HKEY_CURRENT_CONFIG):?\\(.*)$", RegexOptions.IgnoreCase);
            if (!match.Success) throw new InvalidDataException("Use an HKCU, HKLM, HKCR, HKU, or HKCC registry path.");
            string root = match.Groups[1].Value.ToUpperInvariant(); RegistryHive hive;
            if (root == "HKCU" || root == "HKEY_CURRENT_USER") hive = RegistryHive.CurrentUser;
            else if (root == "HKLM" || root == "HKEY_LOCAL_MACHINE") hive = RegistryHive.LocalMachine;
            else if (root == "HKCR" || root == "HKEY_CLASSES_ROOT") hive = RegistryHive.ClassesRoot;
            else if (root == "HKU" || root == "HKEY_USERS") hive = RegistryHive.Users;
            else hive = RegistryHive.CurrentConfig;
            string key = match.Groups[2].Value.Trim('\\'); if (key.Split('\\').Any(x => x == "." || x == ".." || x.Length > 255)) throw new InvalidDataException("A registry key component is invalid.");
            RegistryValueKind kind; if (!Enum.TryParse<RegistryValueKind>(reg.Type ?? "DWord", true, out kind) || kind == RegistryValueKind.Unknown) throw new InvalidDataException("Choose a supported registry value type.");
            object value = RegistryData.ConvertValue(reg.Value, kind); if (value is byte[] && ((byte[])value).Length > 65536) throw new InvalidDataException("Custom binary values must be no larger than 64 KB.");
            return new ValueTarget(hive, key, reg.Name ?? "", value, kind);
        }

        internal static TweakDefinition Build(CustomTweak custom)
        {
            Validate(custom); string warning = ReviewWarning + (String.IsNullOrWhiteSpace(custom.Warning) ? "" : " " + custom.Warning) + (custom.Reboot ? " " + RestartWarning : "");
            return new TweakDefinition(custom.Id, custom.Name, String.IsNullOrWhiteSpace(custom.Category) ? "Custom" : custom.Category, custom.Description ?? "", "Caution", warning, custom.Registry.Select(Target).ToArray());
        }
    }

    internal sealed partial class MainWindow
    {
        private string TweakWarningForReview(TweakDefinition definition)
        {
            var custom = _state.CustomTweaks.FirstOrDefault(x => x.Id == definition.Id);
            if (custom == null) return Localization.Translate(definition.Warning);
            var parts = new List<string> { Localization.Translate(CustomTweakCodec.ReviewWarning) };
            if (!String.IsNullOrWhiteSpace(custom.Warning)) parts.Add(custom.Warning);
            if (custom.Reboot) parts.Add(Localization.Translate(CustomTweakCodec.RestartWarning));
            return String.Join(Environment.NewLine, parts.ToArray());
        }
        private string _customTweaksNotice;
        private TextBlock _customTweaksStatus;
        internal static IEnumerable<string> ReservedCustomIds() { return Definitions.Select(x => x.Id).Concat(LegacyTweakAliases.Keys); }

        private void ImportLegacyCustomTweaks()
        {
            if (_state.LegacyCustomTweaksImported) return;
            try
            {
                string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SharkOptimizer", "custom-tweaks.json"); string json = null;
                if (_state.LegacyBackupFiles.ContainsKey("custom-tweaks.json")) json = _state.LegacyBackupFiles["custom-tweaks.json"];
                else if (File.Exists(path)) { if (new FileInfo(path).Length > 1024 * 1024) throw new InvalidDataException("The previous custom-tweak file exceeds 1 MB."); json = File.ReadAllText(path); }
                if (json != null) foreach (CustomTweak tweak in CustomTweakCodec.ReadJson(json)) if (!_state.CustomTweaks.Any(x => x.Id == tweak.Id)) _state.CustomTweaks.Add(tweak);
                _customTweaksNotice = json == null ? null : "Imported custom definitions from the previous app. No registry values were applied.";
            }
            catch (Exception ex) { _customTweaksNotice = "Previous custom tweaks could not be loaded: " + ex.Message; }
            _state.LegacyCustomTweaksImported = true; _legacyStateMigrated = true;
        }

        private void RebuildCustomCatalogue()
        {
            _catalogue.Clear(); _catalogue.AddRange(Definitions);
            var ids = new HashSet<string>(Definitions.Select(x => x.Id), StringComparer.OrdinalIgnoreCase);
            foreach (CustomTweak tweak in _state.CustomTweaks) if (tweak != null && tweak.Enabled) try { if (!ids.Add(tweak.Id)) throw new InvalidDataException("Duplicate custom ID."); _catalogue.Add(CustomTweakCodec.Build(tweak)); } catch (Exception ex) { _customTweaksNotice = "A custom definition was not loaded: " + ex.Message; }
            _selectedTweaks.RemoveWhere(id => !_catalogue.Any(x => x.Id == id));
        }

        private bool CommitCustomTweaks(List<CustomTweak> changed)
        {
            var previous = _state.CustomTweaks;
            try { if (changed.Count > 100) throw new InvalidDataException("Keep up to 100 custom definitions."); foreach (CustomTweak tweak in changed) CustomTweakCodec.Validate(tweak); _state.CustomTweaks = changed; SaveState(); RebuildCustomCatalogue(); RefreshAll(); RefreshCustomTweaksStatus(); return true; }
            catch (Exception ex) { _state.CustomTweaks = previous; RebuildCustomCatalogue(); MessageBox.Show(this, ex.Message, "Custom tweaks could not be saved", MessageBoxButton.OK, MessageBoxImage.Warning); return false; }
        }

        private void RefreshCustomTweaksStatus()
        { if (_customTweaksStatus != null) _customTweaksStatus.Text = (_customTweaksNotice == null ? "" : _customTweaksNotice + "\n") + _state.CustomTweaks.Count + " definitions · " + _state.CustomTweaks.Count(x => x.Enabled) + " enabled on Optimize"; }

        private UIElement BuildCustomTweaksCard()
        {
            var card = Card(); var body = new StackPanel(); body.Children.Add(Text("Custom registry tweaks", 16, Brushes.White, true));
            body.Children.Add(Text("Import your own registry definitions, review their exact targets, and make them available on Optimize. Enabling a definition does not apply it. Applied values stay tracked in Restore when a definition is disabled or removed.", 11, Brush(MutedColor), false, 0, 5));
            var row = new WrapPanel { Margin = new Thickness(-5, 10, 0, 0) }; var import = ActionButton("Import definitions", false); import.Click += delegate { ImportCustomTweaks(); }; var manage = ActionButton("Manage definitions", false); manage.Click += delegate { ShowCustomTweaksManager(); };
            var export = ActionButton("Export JSON", false); export.Click += delegate { ExportCustomTweaks(false); }; var example = ActionButton("Save example", false); example.Click += delegate { ExportCustomTweaks(true); };
            row.Children.Add(import); row.Children.Add(manage); row.Children.Add(export); row.Children.Add(example); body.Children.Add(row);
            _customTweaksStatus = Text("", 11, Brush(MutedColor), false, 0, 8); body.Children.Add(_customTweaksStatus); RefreshCustomTweaksStatus(); card.Child = body;
            return new Expander { Header = "Advanced · Custom registry tweaks", Content = card, Foreground = Brushes.White, FontSize = 12, Margin = new Thickness(0, 0, 0, 14) };
        }

        private void ImportCustomTweaks()
        {
            var dialog = new OpenFileDialog { Filter = "Custom registry tweaks (*.json)|*.json", Title = "Import custom registry definitions" }; if (LocalizedFileDialog.Show(dialog, this) != true) return;
            try
            {
                if (new FileInfo(dialog.FileName).Length > 1024 * 1024) throw new InvalidDataException("Custom-tweak files must be no larger than 1 MB."); var incoming = CustomTweakCodec.ReadJson(File.ReadAllText(dialog.FileName)); if (incoming.Count == 0) throw new InvalidDataException("The file has no definitions.");
                string preview = String.Join(Environment.NewLine, incoming.Select(x => "• " + x.Name + " · " + x.Registry.Count + " registry values · " + (x.Enabled ? "enabled" : "disabled")).ToArray());
                if (MessageBox.Show(this, "Import these definitions? Matching IDs will replace existing definitions. Windows values and undo history are kept.\n\n" + preview + "\n\nReview the exact targets in Manage definitions before applying anything on Optimize.", "Review custom definitions", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
                var changed = _state.CustomTweaks.Where(x => !incoming.Any(y => y.Id == x.Id)).Concat(incoming).ToList(); CommitCustomTweaks(changed);
            }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, "Definition import failed", MessageBoxButton.OK, MessageBoxImage.Warning); }
        }

        private void ExportCustomTweaks(bool example)
        {
            var dialog = new SaveFileDialog { Filter = "Custom registry tweaks (*.json)|*.json", FileName = example ? "custom-tweaks.example.json" : "custom-tweaks.json" }; if (LocalizedFileDialog.Show(dialog, this) != true) return;
            try
            {
                if (example) File.WriteAllText(dialog.FileName, "[{\"id\":\"c_example\",\"name\":\"Example custom tweak\",\"cat\":\"Custom\",\"desc\":\"Edit the example before enabling it.\",\"enabled\":false,\"reg\":[{\"path\":\"HKCU:\\\\Software\\\\Example\",\"name\":\"Value\",\"value\":1,\"type\":\"DWord\"}]}]", new UTF8Encoding(false));
                else File.WriteAllText(dialog.FileName, CustomTweakCodec.WriteJson(_state.CustomTweaks), new UTF8Encoding(false));
            }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, "Definition export failed", MessageBoxButton.OK, MessageBoxImage.Warning); }
        }

        private void ShowCustomTweaksManager()
        {
            var dialog = new Window { Title = "Custom registry definitions", Owner = this, Width = 760, Height = 520, WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Brush(BackgroundColor), Foreground = Brushes.White, FontFamily = FontFamily }; CopyControlStyles(dialog);
            var body = new StackPanel { Margin = new Thickness(22) }; body.Children.Add(Text("Review custom targets", 20, Brushes.White, true)); body.Children.Add(Text("Definitions only choose what Optimize offers. No registry changes happen in this manager.", 11, Brush(MutedColor), false, 0, 5));
            var picker = new ComboBox { Height = 36, Margin = new Thickness(0, 12, 0, 8), Background = Brush(SurfaceRaised), Foreground = Brushes.White, DisplayMemberPath = "Name" }; body.Children.Add(picker);
            var details = new TextBox { IsReadOnly = true, Height = 230, AcceptsReturn = true, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, TextWrapping = TextWrapping.Wrap, Padding = new Thickness(10), Background = Brush(SurfaceColor), Foreground = Brushes.White }; body.Children.Add(details);
            Localization.KeepData(details);
            var enabled = new CheckBox { Content = "Available on Optimize", Margin = new Thickness(0, 12, 0, 0), Foreground = Brushes.White }; body.Children.Add(enabled);
            Action refresh = delegate { string id = picker.SelectedItem == null ? null : ((CustomTweak)picker.SelectedItem).Id; picker.ItemsSource = _state.CustomTweaks.OrderBy(x => x.Name).ToList(); picker.SelectedItem = _state.CustomTweaks.FirstOrDefault(x => x.Id == id) ?? _state.CustomTweaks.FirstOrDefault(); if (picker.SelectedItem == null) { details.Text = Localization.Translate("No custom definitions yet. Import a JSON file from Settings."); enabled.IsEnabled = false; } };
            picker.SelectionChanged += delegate { var selected = picker.SelectedItem as CustomTweak; enabled.IsEnabled = selected != null; enabled.IsChecked = selected != null && selected.Enabled; details.Text = selected == null ? Localization.Translate("No definition selected.") : CustomTweakCodec.WriteJson(new[] { selected }); };
            enabled.Click += delegate { var selected = picker.SelectedItem as CustomTweak; if (selected == null) return; var changed = CustomTweakCodec.ReadJson(CustomTweakCodec.WriteJson(_state.CustomTweaks)); changed.First(x => x.Id == selected.Id).Enabled = enabled.IsChecked == true; CommitCustomTweaks(changed); refresh(); };
            var remove = ActionButton("Remove definition", false); remove.Margin = new Thickness(-5, 12, 0, 0); remove.Click += delegate { var selected = picker.SelectedItem as CustomTweak; if (selected == null || MessageBox.Show(dialog, "Remove “" + selected.Name + "”? Applied values remain tracked in Restore.", "Remove definition", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return; CommitCustomTweaks(_state.CustomTweaks.Where(x => x.Id != selected.Id).ToList()); refresh(); }; body.Children.Add(remove);
            dialog.Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }; refresh(); dialog.ShowDialog();
        }
    }
}
