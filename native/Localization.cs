using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace SharkOptimizer.NativeApp
{
    internal sealed class LanguagePack
    {
        public Dictionary<string, string> UI { get; set; }
        public Dictionary<string, string> Tweaks { get; set; }
        public Dictionary<string, string> Descriptions { get; set; }
    }
    internal static class Localization
    {
        internal static readonly Dictionary<string, string> Languages = new Dictionary<string, string> { {"en","English"},{"nl","Nederlands"},{"es","Español"},{"de","Deutsch"},{"fr","Français"},{"pt","Português (Brasil)"},{"ru","Русский"},{"zh","简体中文"} };
        private static readonly Dictionary<string, LanguagePack> Packs = Load();
        private sealed class TemplateRule
        {
            internal Regex Pattern;
            internal string Translation;
            internal int[] Indices;
        }
        private static readonly Dictionary<string, List<TemplateRule>> Templates = BuildTemplates();
        internal static string Current = "en";
        internal static string LanguageForWindows(string cultureName)
        {
            string primary = (cultureName ?? "").Split('-', '_')[0].ToLowerInvariant();
            return Languages.ContainsKey(primary) ? primary : "en";
        }
        internal static string DefaultWindowsLanguage()
        { return LanguageForWindows(CultureInfo.CurrentUICulture.Name); }
        internal static string ResolveStartupLanguage(string native, string legacy, string windowsCulture)
        {
            if (Languages.ContainsKey(native ?? "")) return native;
            if (Languages.ContainsKey(legacy ?? "")) return legacy;
            return LanguageForWindows(windowsCulture);
        }
        private static Dictionary<string, LanguagePack> Load()
        {
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("SharkOptimizer.Translations.json")) {
                if (stream == null) throw new InvalidDataException("The language resource is missing.");
                using (var reader = new StreamReader(stream)) {
                    var result = new JavaScriptSerializer { MaxJsonLength = 2 * 1024 * 1024 }.Deserialize<Dictionary<string, LanguagePack>>(reader.ReadToEnd());
                    foreach (LanguagePack pack in result.Values) pack.UI = new Dictionary<string, string>(pack.UI, StringComparer.OrdinalIgnoreCase);
                    return result;
                }
            }
        }
        private static Dictionary<string, List<TemplateRule>> BuildTemplates()
        {
            var result = new Dictionary<string, List<TemplateRule>>();
            foreach (var language in Packs) {
                var rules = new List<TemplateRule>();
                foreach (var phrase in language.Value.UI.OrderByDescending(x => Regex.Replace(x.Key, @"\{\d+\}", "").Length).ThenBy(x => Regex.Matches(x.Key, @"\{\d+\}").Count)) {
                    MatchCollection slots = Regex.Matches(phrase.Key, @"\{(\d+)\}"); if (slots.Count == 0) continue;
                    var pattern = new StringBuilder(@"\A"); var indices = new List<int>(); int position = 0;
                    foreach (Match slot in slots) {
                        int index = Int32.Parse(slot.Groups[1].Value, CultureInfo.InvariantCulture); if (index > 9) throw new InvalidDataException("Translation placeholders support indices 0 through 9.");
                        pattern.Append(Regex.Escape(phrase.Key.Substring(position, slot.Index - position))).Append("(?<p").Append(index).Append(">.*?)");
                        if (!indices.Contains(index)) indices.Add(index); position = slot.Index + slot.Length;
                    }
                    pattern.Append(Regex.Escape(phrase.Key.Substring(position))).Append(@"\z");
                    int[] translatedSlots = Regex.Matches(phrase.Value, @"\{(\d+)\}").Cast<Match>().Select(x => Int32.Parse(x.Groups[1].Value, CultureInfo.InvariantCulture)).Distinct().OrderBy(x => x).ToArray();
                    if (!translatedSlots.SequenceEqual(indices.OrderBy(x => x))) throw new InvalidDataException("Translation placeholders do not match: " + language.Key + " / " + phrase.Key);
                    rules.Add(new TemplateRule { Pattern = new Regex(pattern.ToString(), RegexOptions.Singleline | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(50)), Translation = phrase.Value, Indices = indices.ToArray() });
                }
                result[language.Key] = rules;
            }
            return result;
        }
        internal static void AddTweakLabels(IEnumerable<TweakDefinition> definitions, IDictionary<string, string> aliases)
        {
            foreach (var pack in Packs.Values) foreach (var definition in definitions) {
                string legacy = aliases.FirstOrDefault(x => x.Value == definition.Id).Key, translated;
                if (legacy != null && !pack.UI.ContainsKey(definition.Name) && pack.Tweaks.TryGetValue(legacy, out translated)) pack.UI[definition.Name] = translated;
            }
        }
        internal static string Translate(string english)
        {
            if (english == null || Current == "en") return english; LanguagePack pack; string value;
            if (!Packs.TryGetValue(Current, out pack)) return english;
            if (pack.UI.TryGetValue(english, out value)) return value;
            string trimmed = english.Trim(); if (pack.UI.TryGetValue(trimmed, out value)) return english.Replace(trimmed, value);
            if (english.IndexOf('\n') >= 0 || english.IndexOf('\r') >= 0) {
                string[] lines = Regex.Split(english, @"(\r\n|\n|\r)");
                for (int i = 0; i < lines.Length; i += 2) lines[i] = Translate(lines[i]);
                return String.Concat(lines);
            }
            // Activity timestamps are data; translate only the message that follows them.
            if (english.Length > 22 && english.Substring(19, 3) == " · " && Regex.IsMatch(english.Substring(0, 19), @"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"))
                return english.Substring(0, 22) + Translate(english.Substring(22));
            if (english.StartsWith("ERROR · ", StringComparison.Ordinal))
                return Translate("Error") + " · " + Translate(english.Substring(8));
            foreach (TemplateRule rule in Templates[Current]) {
                try { Match match = rule.Pattern.Match(english); if (!match.Success) continue;
                    var arguments = new object[rule.Indices.Max() + 1]; foreach (int index in rule.Indices) arguments[index] = match.Groups["p" + index].Value;
                    return String.Format(CultureInfo.CurrentCulture, rule.Translation, arguments);
                } catch (RegexMatchTimeoutException) { }
            }
            return english;
        }

        private sealed class LabelRecord
        {
            internal WeakReference Target;
            internal DependencyProperty Property;
            internal string Original;
            internal bool Changing, Attached;
            internal DependencyPropertyDescriptor Descriptor;
            internal EventHandler Changed;
            internal void SyncOriginal()
            {
                var target = Target.Target as DependencyObject; if (target == null) return;
                string current = target.GetValue(Property) as string;
                if (current != null && current != Translate(Original)) Original = current;
            }
            internal void Update()
            {
                var target = Target.Target as DependencyObject; if (target == null) return;
                if ((bool)target.GetValue(DataProperty)) return;
                // A button can replace its initial caption with a structured visual.
                // Translate its child labels without overwriting that visual with the old caption.
                if (!(target.GetValue(Property) is string)) return;
                Changing = true; try { target.SetCurrentValue(Property, Translate(Original)); } finally { Changing = false; }
            }
        }
        private static readonly DependencyProperty RecordsProperty = DependencyProperty.RegisterAttached("TranslationRecords", typeof(List<LabelRecord>), typeof(Localization));
        private static readonly DependencyProperty DataProperty = DependencyProperty.RegisterAttached("KeepOriginalData", typeof(bool), typeof(Localization), new PropertyMetadata(false));
        internal static void KeepData(DependencyObject target)
        {
            target.SetValue(DataProperty, true);
            var own = target.GetValue(RecordsProperty) as List<LabelRecord>; if (own == null) return;
            foreach (LabelRecord record in own) {
                record.Changing = true; try { target.SetCurrentValue(record.Property, record.Original); } finally { record.Changing = false; }
                if (record.Attached) { record.Descriptor.RemoveValueChanged(target, record.Changed); record.Attached = false; }
            }
        }
        private static readonly List<WeakReference> Records = new List<WeakReference>();
        private static void Track(DependencyObject target, DependencyProperty property)
        {
            string value = target.GetValue(property) as string; if (value == null) return;
            var own = target.GetValue(RecordsProperty) as List<LabelRecord>;
            if (own == null) { own = new List<LabelRecord>(); target.SetValue(RecordsProperty, own); }
            var record = own.FirstOrDefault(x => x.Property == property); if (record != null) { record.SyncOriginal(); record.Update(); return; }
            record = new LabelRecord { Target = new WeakReference(target), Property = property, Original = value, Descriptor = DependencyPropertyDescriptor.FromProperty(property, target.GetType()) };
            record.Changed = delegate { if (record.Changing) return; var item = record.Target.Target as DependencyObject; if (item == null) return; string raw = item.GetValue(property) as string; if (raw == null) return; record.Original = raw; record.Update(); };
            var element = target as FrameworkElement;
            Action attach = delegate { var item = record.Target.Target; if (item != null && !record.Attached) { record.Descriptor.AddValueChanged(item, record.Changed); record.Attached = true; } };
            Action detach = delegate { var item = record.Target.Target; if (item != null && record.Attached) { record.Descriptor.RemoveValueChanged(item, record.Changed); record.Attached = false; } };
            if (element != null) { element.Loaded += delegate { record.SyncOriginal(); attach(); record.Update(); }; element.Unloaded += delegate { detach(); }; if (element.IsLoaded) attach(); }
            own.Add(record); Records.Add(new WeakReference(record)); if (Records.Count % 256 == 0) Records.RemoveAll(x => !x.IsAlive); record.Update();
        }
        internal static void Apply(DependencyObject root)
        { Walk(root, new HashSet<DependencyObject>()); }
        private static void Walk(DependencyObject root, HashSet<DependencyObject> visited)
        {
            if (root == null || !visited.Add(root) || (bool)root.GetValue(DataProperty)) return;
            var textBox = root as TextBox;
            if (textBox != null) { if (textBox.IsReadOnly) Track(textBox, TextBox.TextProperty); return; }
            if (root is TextBlock) Track(root, TextBlock.TextProperty);
            if (root is FrameworkElement) Track(root, FrameworkElement.ToolTipProperty);
            if (root is Window) Track(root, Window.TitleProperty);
            if (root is HeaderedContentControl) Track(root, HeaderedContentControl.HeaderProperty);
            if (root is ContentControl) Track(root, ContentControl.ContentProperty);
            foreach (object child in LogicalTreeHelper.GetChildren(root)) { var item = child as DependencyObject; if (item != null) Walk(item, visited); }
        }
        internal static void SetLanguage(string language)
        {
            foreach (WeakReference weak in Records.ToArray()) { var record = weak.Target as LabelRecord; if (record != null) record.SyncOriginal(); }
            Current = Languages.ContainsKey(language ?? "") ? language : "en";
            foreach (WeakReference weak in Records.ToArray()) { var record = weak.Target as LabelRecord; if (record != null) record.Update(); }
            Records.RemoveAll(x => !x.IsAlive);
        }
    }
    internal sealed partial class MainWindow
    {
        private void ImportLegacyLanguage()
        {
            if (_state.LegacyLanguageImported) return;
            if (Localization.Languages.ContainsKey(_state.Language ?? "")) { _state.LegacyLanguageImported = true; _legacyStateMigrated = true; return; }
            try {
                string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SharkOptimizer", "settings.json"), json = null;
                if (_state.LegacyBackupFiles.ContainsKey("settings.json")) json = _state.LegacyBackupFiles["settings.json"];
                else {
                    foreach (string candidate in new[] { path, path + ".bak" }) {
                        try {
                            if (!File.Exists(candidate) || new FileInfo(candidate).Length > 1024 * 1024) continue;
                            var values = _json.DeserializeObject(File.ReadAllText(candidate)) as IDictionary<string, object>;
                            object language; if (values != null && values.TryGetValue("Language", out language) && language is string && Localization.Languages.ContainsKey((string)language)) { json = _json.Serialize(values); break; }
                        } catch { }
                    }
                }
                if (json != null) { var data = _json.DeserializeObject(json) as IDictionary<string, object>; object value; if (data != null && data.TryGetValue("Language", out value) && value is string && Localization.Languages.ContainsKey((string)value)) _state.Language = (string)value; }
                _state.LegacyLanguageImported = true; _legacyStateMigrated = true;
            } catch (Exception ex) { LogActivity("Previous language preference could not be imported: " + ex.Message, true, false); }
        }
        private UIElement BuildLanguageCard()
        {
            var card = Card(); var body = new StackPanel(); body.Children.Add(Text("Language", 15, Brushes.White, true));
            body.Children.Add(Text("Choose the interface language. Your choice is saved for the next launch.", 11, Brush(MutedColor), false, 0, 5));
            var picker = new ComboBox { MinHeight = 36, Width = 260, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 10, 0, 0) };
            foreach (var language in Localization.Languages) { var item = new ComboBoxItem { Content = language.Value, Tag = language.Key }; picker.Items.Add(item); if (language.Key == _state.Language) picker.SelectedItem = item; }
            picker.SelectionChanged += delegate { var item = picker.SelectedItem as ComboBoxItem; if (item == null) return; string previous = _state.Language; try { _state.Language = Convert.ToString(item.Tag); SaveState(); Localization.SetLanguage(_state.Language); Localization.Apply((DependencyObject)Content); } catch (Exception ex) { _state.Language = previous; Localization.SetLanguage(previous); MessageBox.Show(this, ex.Message, "Language", MessageBoxButton.OK, MessageBoxImage.Warning); } }; body.Children.Add(picker); card.Child = body; return card;
        }
    }
}
