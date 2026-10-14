using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace SharkOptimizer.NativeApp
{
    internal static class BrandAssets
    {
        private static readonly ImageSource Shark = LoadIcon();
        internal static ImageSource Icon { get { return Shark; } }
        private static ImageSource LoadIcon()
        {
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("SharkOptimizer.Brand.shark.ico")) {
                if (stream == null) throw new InvalidDataException("The SharkOptimizer icon is missing.");
                var decoder = new IconBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                var frame = decoder.Frames.OrderByDescending(x => x.PixelWidth).First(); frame.Freeze(); return frame;
            }
        }
        internal static Image Image(double size)
        { return new Image { Source = Shark, Width = size, Height = size, Stretch = Stretch.Uniform, SnapsToDevicePixels = true }; }
    }
}
