using System;
using System.Collections.Generic;
using System.Linq;
using System.Management;
using System.Net.NetworkInformation;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private sealed class HardwareRequirements
        {
            public int Build, Threads;
            public double RamGb;
            public bool? Laptop, Nvidia, AmdGpu, Intel, IntelGpu, SystemSsd;
            public bool Ethernet, Wifi;
        }
        private HardwareRequirements _requirements;
        private bool _requirementsReady;

        // One snapshot per app run; never issue WMI queries from card rendering.
        private async Task LoadHardwareRequirements()
        {
            try { _requirements = await Task.Run(() => ReadHardwareRequirements()); }
            catch { _requirements = new HardwareRequirements { Threads = Environment.ProcessorCount }; }
            _requirementsReady = true;
            _selectedTweaks.RemoveWhere(id => !CanSelectTweak(id));
            RenderTweakCards();
            RenderGameDetail();
            RefreshPresetEditStatus();
        }

        private static List<Dictionary<string, object>> HardwareRows(string scope, string query)
        {
            var result = new List<Dictionary<string, object>>();
            try
            {
                var options = new EnumerationOptions { ReturnImmediately = false, Timeout = TimeSpan.FromSeconds(3) };
                using (var search = new ManagementObjectSearcher(new ManagementScope(scope), new ObjectQuery(query), options))
                using (ManagementObjectCollection rows = search.Get())
                    foreach (ManagementObject row in rows)
                        using (row)
                        {
                            var values = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
                            foreach (PropertyData property in row.Properties) values[property.Name] = property.Value;
                            result.Add(values);
                        }
            }
            catch { }
            return result;
        }

        private static HardwareRequirements ReadHardwareRequirements()
        {
            var facts = new HardwareRequirements { Threads = Environment.ProcessorCount };
            try { using (RegistryKey key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion")) if (key != null) Int32.TryParse(Convert.ToString(key.GetValue("CurrentBuildNumber")), out facts.Build); } catch { }
            var systems = HardwareRows(@"root\cimv2", "SELECT TotalPhysicalMemory, PCSystemType FROM Win32_ComputerSystem");
            if (systems.Count == 1)
            {
                facts.RamGb = Convert.ToDouble(systems[0]["TotalPhysicalMemory"] ?? 0) / 1073741824.0;
                int type = Convert.ToInt32(systems[0]["PCSystemType"] ?? 0);
                if (type != 0) facts.Laptop = type == 2;
            }
            var gpu = HardwareRows(@"root\cimv2", "SELECT Name FROM Win32_VideoController");
            if (gpu.Count > 0)
            {
                facts.Nvidia = gpu.Any(x => Convert.ToString(x["Name"]).IndexOf("NVIDIA", StringComparison.OrdinalIgnoreCase) >= 0);
                facts.IntelGpu = gpu.Any(x => Convert.ToString(x["Name"]).IndexOf("Intel", StringComparison.OrdinalIgnoreCase) >= 0);
                facts.AmdGpu = gpu.Any(x => Convert.ToString(x["Name"]).IndexOf("AMD", StringComparison.OrdinalIgnoreCase) >= 0 || Convert.ToString(x["Name"]).IndexOf("Radeon", StringComparison.OrdinalIgnoreCase) >= 0);
            }
            var cpu = HardwareRows(@"root\cimv2", "SELECT Manufacturer FROM Win32_Processor");
            if (cpu.Count > 0) facts.Intel = cpu.Any(x => Convert.ToString(x["Manufacturer"]).IndexOf("Intel", StringComparison.OrdinalIgnoreCase) >= 0);
            try
            {
                var networks = NetworkInterface.GetAllNetworkInterfaces().Where(x => x.OperationalStatus == OperationalStatus.Up).ToArray();
                facts.Wifi = networks.Any(x => x.NetworkInterfaceType == NetworkInterfaceType.Wireless80211);
                facts.Ethernet = networks.Any(x => x.NetworkInterfaceType == NetworkInterfaceType.Ethernet || x.NetworkInterfaceType == NetworkInterfaceType.GigabitEthernet || x.NetworkInterfaceType == NetworkInterfaceType.FastEthernetT);
            }
            catch { }
            // Match the Windows volume to its disk identity. An unrelated SSD must not qualify.
            string drive = System.IO.Path.GetPathRoot(Environment.SystemDirectory).Substring(0, 1);
            var partitions = HardwareRows(@"root\Microsoft\Windows\Storage", "SELECT DiskNumber FROM MSFT_Partition WHERE DriveLetter = '" + drive + "'");
            if (partitions.Count == 1)
            {
                int number = Convert.ToInt32(partitions[0]["DiskNumber"]);
                var disks = HardwareRows(@"root\Microsoft\Windows\Storage", "SELECT UniqueId FROM MSFT_Disk WHERE Number = " + number);
                if (disks.Count == 1)
                {
                    string identity = Convert.ToString(disks[0]["UniqueId"]).Trim();
                    var physical = HardwareRows(@"root\Microsoft\Windows\Storage", "SELECT UniqueId, MediaType FROM MSFT_PhysicalDisk").Where(x => identity.Length > 0 && String.Equals(identity, Convert.ToString(x["UniqueId"]).Trim(), StringComparison.OrdinalIgnoreCase)).ToList();
                    if (physical.Count == 1) { int media = Convert.ToInt32(physical[0]["MediaType"]); if (media == 3 || media == 4) facts.SystemSsd = media == 4; }
                }
            }
            return facts;
        }

        private string TweakRequirement(TweakDefinition tweak)
        {
            HardwareRequirements f = _requirements;
            switch (tweak.Id)
            {
                case "disable-copilot": return f != null && f.Build >= 22621 ? null : "Needs Windows 11 22H2 or newer";
                case "disable-windows-ai-capture": return f != null && f.Build >= 26100 ? null : "Needs Windows 11 24H2 or newer";
                case "disable-widgets-policy": case "clean-windows-taskbar": case "classic-context-menu": case "remove-teams-chat-icon": return f != null && f.Build >= 22000 ? null : "Needs Windows 11";
                case "enable-gpu-scheduling": case "global-timer-resolution-requests": case "disable-vbs-memory-integrity": return f != null && f.Build >= 19041 ? null : "Needs Windows 10 2004 or newer";
                case "disable-nvidia-telemetry": return f != null && f.Nvidia == true ? null : "Needs an NVIDIA GPU";
                case "disable-mpo": return f != null && (f.Nvidia == true || f.AmdGpu == true) ? null : "Needs an NVIDIA or AMD GPU";
                case "maximum-cpu-minimum-state": case "disable-dynamic-tick": return f != null && f.Laptop == false ? null : "Desktop PCs only";
                case "disable-sysmain": case "disable-prefetcher": return f != null && f.SystemSsd == true ? null : "Needs an SSD system drive";
                case "disable-eee": case "disable-flow-control": return f != null && f.Ethernet ? null : "Ethernet adapters only";
                case "disable-interrupt-moderation": return f != null && f.Ethernet && f.Threads >= 6 ? null : "Ethernet and 6+ CPU threads";
                case "enable-receive-side-scaling": return f != null && f.Threads >= 4 ? null : "Needs 4 or more threads";
                case "wifi-maximum-performance": return f != null && f.Wifi ? null : "Needs a Wi-Fi adapter";
                case "merge-service-host-processes": return f != null && f.RamGb >= 8 ? null : "Needs 8 GB RAM or more";
                case "keep-kernel-in-ram": case "disable-memory-compression": return f != null && f.RamGb >= 16 ? null : "Needs 16 GB RAM or more";
                case "disable-cpu-mitigations": return f != null && f.Intel == true ? null : "Needs an Intel CPU";
                default: return null;
            }
        }

        private bool CanSelectTweak(string id)
        {
            TweakDefinition tweak = _catalogue.FirstOrDefault(x => x.Id == id);
            return tweak != null && !AlreadyEnabledOutsideShark(id) && TweakRequirement(tweak) == null;
        }
    }
}
