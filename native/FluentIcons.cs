using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Web.Script.Serialization;
using System.Windows.Media;

namespace SharkOptimizer.NativeApp
{
    internal static class FluentIcons
    {
        private static readonly Dictionary<string, Dictionary<string, Geometry>> Icons = Load();
        private static Dictionary<string, Dictionary<string, Geometry>> Load()
        {
            var result = new Dictionary<string, Dictionary<string, Geometry>>();
            var data = new JavaScriptSerializer().Deserialize<Dictionary<string, Dictionary<string, string>>>(Resource("SharkOptimizer.Icons.json"));
            foreach (var icon in data) {
                var variants = new Dictionary<string, Geometry>();
                foreach (var variant in icon.Value) { Geometry geometry = Geometry.Parse(variant.Value); geometry.Freeze(); variants[variant.Key] = geometry; }
                result[icon.Key] = variants;
            }
            return result;
        }
        internal static Geometry Get(string page, bool selected)
        { return Icons[Icons.ContainsKey(page) ? page : "Settings"][selected ? "filled" : "regular"]; }
        private static string Resource(string name)
        {
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)) {
                if (stream == null) throw new InvalidDataException("An embedded icon resource is missing.");
                using (var reader = new StreamReader(stream)) return reader.ReadToEnd();
            }
        }
        internal static string Notices()
        { return Resource("SharkOptimizer.Icons.Source") + Environment.NewLine + Environment.NewLine + Resource("SharkOptimizer.Icons.Notice") + Environment.NewLine + Resource("SharkOptimizer.Icons.License") + Environment.NewLine + Environment.NewLine + "Poppins font" + Environment.NewLine + Resource("SharkOptimizer.Fonts.License"); }
    }
}
