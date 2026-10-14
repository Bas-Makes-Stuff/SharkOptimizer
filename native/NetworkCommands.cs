using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Controls;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private bool _networkCheckBusy;
        private readonly List<Button> _networkButtons = new List<Button>();
        [DllImport("kernel32.dll")] private static extern uint GetOEMCP();

        private static string RunNetworkCommand(string executable, string arguments, int timeoutMs)
        {
            if (executable != "ipconfig.exe" && executable != "netsh.exe" && executable != "tracert.exe") throw new ArgumentException("Unsupported network command.");
            var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, executable), arguments) {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.GetEncoding((int)GetOEMCP()), StandardErrorEncoding = Encoding.GetEncoding((int)GetOEMCP())
            };
            var text = new StringBuilder(); object outputLock = new object();
            using (var process = new Process { StartInfo = info })
            {
                DataReceivedEventHandler collect = delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) lock (outputLock) if (text.Length < 1024 * 1024) text.AppendLine(e.Data); };
                process.OutputDataReceived += collect; process.ErrorDataReceived += collect;
                if (!process.Start()) throw new InvalidOperationException("Windows could not start the network tool.");
                process.BeginOutputReadLine(); process.BeginErrorReadLine(); bool timedOut = !process.WaitForExit(timeoutMs);
                if (timedOut) { try { process.Kill(); } catch { } if (!process.WaitForExit(2000)) return "The network command timed out and could not be closed."; }
                process.WaitForExit(); string output; lock (outputLock) output = text.ToString().Trim();
                if (timedOut) return output + Environment.NewLine + "The network check reached its time limit.";
                if (process.ExitCode != 0) return output + Environment.NewLine + "Windows returned exit code " + process.ExitCode + ".";
                return String.IsNullOrWhiteSpace(output) ? "The network tool returned no output." : output;
            }
        }
    }
}
