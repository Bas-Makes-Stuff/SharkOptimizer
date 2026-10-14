using System.Windows;

namespace SharkOptimizer.NativeApp
{
    internal static class LocalizedFileDialog
    {
        internal static bool? Show(Microsoft.Win32.FileDialog dialog, Window owner)
        {
            dialog.Title = Localization.Translate(dialog.Title);
            // Translate visible filter labels while preserving file patterns and extensions.
            string[] filters = dialog.Filter.Split('|');
            for (int i = 0; i < filters.Length; i += 2)
            {
                var suffix = System.Text.RegularExpressions.Regex.Match(filters[i], @"^(.*?)(\s*\([^)]*\))$");
                filters[i] = suffix.Success ? Localization.Translate(suffix.Groups[1].Value) + suffix.Groups[2].Value : Localization.Translate(filters[i]);
            }
            dialog.Filter = string.Join("|", filters);
            return dialog.ShowDialog(owner);
        }
    }
    // Centralize native dialog text without changing owners, choices, or result handling.
    internal static class MessageBox
    {
        internal static MessageBoxResult Show(string message, string caption = "SharkOptimizer", MessageBoxButton buttons = MessageBoxButton.OK, MessageBoxImage image = MessageBoxImage.None)
        { return System.Windows.MessageBox.Show(Localization.Translate(message), Localization.Translate(caption), buttons, image); }
        internal static MessageBoxResult Show(Window owner, string message, string caption = "SharkOptimizer", MessageBoxButton buttons = MessageBoxButton.OK, MessageBoxImage image = MessageBoxImage.None)
        { return System.Windows.MessageBox.Show(owner, Localization.Translate(message), Localization.Translate(caption), buttons, image); }
    }
}
