using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Principal;

namespace SharkOptimizer.Platform
{
    internal static class StartupRegistration
    {
        private static string UserSid { get { using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) return identity.User.Value; } }
        private static string TaskName { get { return "SharkOptimizer Startup " + UserSid; } }
        private static object Call(object target, string member, params object[] args) { return target.GetType().InvokeMember(member, BindingFlags.InvokeMethod, null, target, args); }
        private static object Read(object target, string member) { return target.GetType().InvokeMember(member, BindingFlags.GetProperty, null, target, null); }
        private static void Release(object value) { if (value != null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value); }
        private static object Connect()
        {
            Type type = Type.GetTypeFromProgID("Schedule.Service", true); object service = Activator.CreateInstance(type);
            try { Call(service, "Connect", Type.Missing, Type.Missing, Type.Missing, Type.Missing); return service; } catch { Release(service); throw; }
        }

        internal static string BuildXml(string executable, string sid)
        {
            if (String.IsNullOrWhiteSpace(executable) || !Path.IsPathRooted(executable) || !executable.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Startup requires a full executable path.");
            if (String.IsNullOrWhiteSpace(sid) || !sid.StartsWith("S-1-", StringComparison.Ordinal)) throw new ArgumentException("Startup requires a Windows account SID.");
            string path = SecurityElement.Escape(Path.GetFullPath(executable)), user = SecurityElement.Escape(sid), folder = SecurityElement.Escape(Path.GetDirectoryName(Path.GetFullPath(executable)));
            return "<?xml version=\"1.0\" encoding=\"UTF-16\"?><Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\"><RegistrationInfo><Description>Start SharkOptimizer in the notification area when this account signs in.</Description></RegistrationInfo><Triggers><LogonTrigger><Enabled>true</Enabled><UserId>" + user + "</UserId><Delay>PT10S</Delay></LogonTrigger></Triggers><Principals><Principal id=\"CurrentUser\"><UserId>" + user + "</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals><Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><AllowHardTerminate>false</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable><Enabled>true</Enabled><Hidden>false</Hidden><ExecutionTimeLimit>PT0S</ExecutionTimeLimit></Settings><Actions Context=\"CurrentUser\"><Exec><Command>" + path + "</Command><Arguments>--tray</Arguments><WorkingDirectory>" + folder + "</WorkingDirectory></Exec></Actions></Task>";
        }

        internal static bool IsEnabled()
        { return ReadEnabled(TaskName) ?? false; }

        internal static bool? ReadEnabled(string taskPath)
        {
            object service = null, root = null, task = null;
            try { service = Connect(); root = Call(service, "GetFolder", "\\"); task = Call(root, "GetTask", taskPath); return Convert.ToBoolean(Read(task, "Enabled")); }
            catch (Exception ex) { Exception actual = ex is TargetInvocationException && ex.InnerException != null ? ex.InnerException : ex; if (actual.HResult == unchecked((int)0x80070002) || actual.HResult == unchecked((int)0x8004130F)) return null; throw; }
            finally { Release(task); Release(root); Release(service); }
        }

        internal static void Enable(string executable)
        {
            if (!File.Exists(executable)) throw new FileNotFoundException("The startup executable was not found.", executable);
            object service = null, root = null, task = null;
            try { service = Connect(); root = Call(service, "GetFolder", "\\"); task = Call(root, "RegisterTask", TaskName, BuildXml(executable, UserSid), 6, UserSid, null, 3, null); }
            finally { Release(task); Release(root); Release(service); }
        }

        internal static void Disable()
        {
            object service = null, root = null;
            try { service = Connect(); root = Call(service, "GetFolder", "\\"); Call(root, "DeleteTask", TaskName, 0); }
            catch (Exception ex) { Exception actual = ex is TargetInvocationException && ex.InnerException != null ? ex.InnerException : ex; if (actual.HResult != unchecked((int)0x80070002) && actual.HResult != unchecked((int)0x8004130F)) throw; }
            finally { Release(root); Release(service); }
        }

        internal static string CaptureXml()
        {
            object service = null, root = null, task = null;
            try { service = Connect(); root = Call(service, "GetFolder", "\\"); task = Call(root, "GetTask", TaskName); return Convert.ToString(Read(task, "Xml")); }
            catch (Exception ex) { Exception actual = ex is TargetInvocationException && ex.InnerException != null ? ex.InnerException : ex; if (actual.HResult == unchecked((int)0x80070002) || actual.HResult == unchecked((int)0x8004130F)) return null; throw; }
            finally { Release(task); Release(root); Release(service); }
        }

        internal static void RestoreXml(string xml)
        {
            if (xml == null) { Disable(); return; }
            object service = null, root = null, task = null;
            try { service = Connect(); root = Call(service, "GetFolder", "\\"); task = Call(root, "RegisterTask", TaskName, xml, 6, UserSid, null, 3, null); }
            finally { Release(task); Release(root); Release(service); }
        }
    }
}
