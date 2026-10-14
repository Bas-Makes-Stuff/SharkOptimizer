using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;

namespace SharkOptimizer.NativeApp
{
    internal static class UpdateTransport
    {
        internal sealed class Client : WebClient
        {
            private WebRequest _request;
            private readonly CancellationToken _cancellation;
            protected override WebRequest GetWebRequest(Uri address)
            {
                WebRequest request = base.GetWebRequest(address); request.Timeout = 30000;
                var http = request as HttpWebRequest; if (http != null) http.ReadWriteTimeout = 15000;
                _request = request; _cancellation.ThrowIfCancellationRequested(); return request;
            }
            internal void AbortRequest() { var request = _request; if (request != null) try { request.Abort(); } catch { } }
            internal Client() : this(CancellationToken.None) { }
            internal Client(CancellationToken cancellation) { _cancellation = cancellation; Headers[HttpRequestHeader.UserAgent] = "SharkOptimizer/2.0.2 (Windows updater)"; }
        }

        internal static long CopyBounded(Stream input, Stream output, long maximumBytes, int seconds)
        { return CopyBoundedCore(input, output, maximumBytes, seconds, CancellationToken.None); }

        private static long CopyBoundedCore(Stream input, Stream output, long maximumBytes, int seconds, CancellationToken cancellation)
        {
            if (maximumBytes < 0 || seconds <= 0) throw new ArgumentOutOfRangeException();
            var clock = Stopwatch.StartNew(); byte[] buffer = new byte[65536]; long total = 0;
            while (true) {
                cancellation.ThrowIfCancellationRequested();
                int remaining = (int)Math.Max(0, seconds * 1000L - clock.ElapsedMilliseconds);
                if (remaining == 0) throw new TimeoutException("Update transfer timed out.");
                if (input.CanTimeout) input.ReadTimeout = Math.Max(1, Math.Min(15000, remaining));
                int read = input.Read(buffer, 0, buffer.Length);
                cancellation.ThrowIfCancellationRequested();
                if (clock.ElapsedMilliseconds >= seconds * 1000L) throw new TimeoutException("Update transfer timed out.");
                if (read == 0) return total;
                if (read > maximumBytes - total) throw new InvalidDataException("The update response is larger than expected.");
                output.Write(buffer, 0, read); total += read;
            }
        }

        internal static string ReadJson(Uri uri, CancellationToken cancellation)
        {
            using (var client = new Client(cancellation)) using (cancellation.Register(client.AbortRequest)) {
                cancellation.ThrowIfCancellationRequested();
                client.Headers[HttpRequestHeader.Accept] = "application/vnd.github+json";
                using (Stream input = client.OpenRead(uri)) using (var output = new MemoryStream()) {
                    CopyBoundedCore(input, output, 2 * 1024 * 1024, 30, cancellation);
                    return new UTF8Encoding(false, true).GetString(output.ToArray());
                }
            }
        }

        internal static void ValidateAssetUri(Uri uri)
        {
            if (uri == null || !uri.IsAbsoluteUri || uri.Scheme != Uri.UriSchemeHttps || !uri.IsDefaultPort || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0 ||
                !String.Equals(uri.Host, "github.com", StringComparison.OrdinalIgnoreCase) || !uri.AbsolutePath.StartsWith("/Bas-Makes-Stuff/SharkOptimizer/releases/download/", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The setup download URL is not an official HTTPS GitHub release asset.");
        }

        internal static void Download(Uri uri, string path, long expectedBytes, CancellationToken cancellation)
        {
            ValidateAssetUri(uri);
            if (expectedBytes < 1 || expectedBytes > 100L * 1024 * 1024) throw new InvalidDataException("The setup asset size is invalid or exceeds the 100 MB update limit.");
            bool created = false;
            try {
                using (var client = new Client(cancellation)) using (cancellation.Register(client.AbortRequest)) {
                cancellation.ThrowIfCancellationRequested();
                using (Stream input = client.OpenRead(uri))
                using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                    created = true; long length = CopyBoundedCore(input, output, expectedBytes, 120, cancellation);
                    if (length != expectedBytes) throw new InvalidDataException("The downloaded setup file size does not match GitHub's release metadata.");
                }
                }
            } catch { if (created) try { File.Delete(path); } catch { } throw; }
        }
    }
}
