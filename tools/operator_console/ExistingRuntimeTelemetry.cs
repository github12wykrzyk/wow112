using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace System.Runtime.CompilerServices
{
    [AttributeUsage(AttributeTargets.Method, Inherited = false)]
    internal sealed class ModuleInitializerAttribute : Attribute { }
}

namespace WoW112.OperatorConsole
{
    internal static class ExistingRuntimeTelemetryBootstrap
    {
        [System.Runtime.CompilerServices.ModuleInitializer]
        internal static void Initialize()
        {
            var thread = new Thread(ExistingRuntimeTelemetry.Run) { IsBackground = true, Name = "WoW112 Operator existing-IPC telemetry" };
            thread.Start();
        }
    }

    internal static class ExistingRuntimeTelemetry
    {
        private const uint ProfileMagic = 0x50323157u;
        private const uint ProfileVersion = 1u;
        private const uint WorkerMagic = 0x53323157u;
        private const uint WorkerVersion = 2u;
        private const uint AssistMagic = 0x41323157u;
        private const uint AssistVersion = 2u;
        private const uint FileMapRead = 0x0004u;

        private sealed class Seen
        {
            public int Pid;
            public bool ProfileLoaded;
            public uint Profile1, Profile2, Relogin;
            public bool WorkerPresent, AssistPresent;
            public uint InWorld, WorkerState, WorkerPhase, WorkerError, WorkerSlot;
            public uint AssistState, AssistDestination, AssistActiveSeq, AssistFailSeq, AssistReadySeq;
        }

        private static readonly Dictionary<int, Seen> seen = new Dictionary<int, Seen>();
        private static readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 2 * 1024 * 1024 };
        private static readonly object fileGate = new object();
        private static string inbox;

        internal static void Run()
        {
            try
            {
                var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WoW112", "OperatorConsole", "bridge");
                Directory.CreateDirectory(root);
                inbox = Path.Combine(root, "backend-events.jsonl");
                while (true)
                {
                    try { Poll(); } catch (Exception ex) { Emit("Warning", OperatorSeverity.Warn, "RuntimeIPC", "ExistingIPC", "", "Existing IPC probe error: " + ex.Message, null); }
                    Thread.Sleep(1000);
                }
            }
            catch { }
        }

        private static void Poll()
        {
            var live = new HashSet<int>();
            Process[] processes;
            try { processes = Process.GetProcessesByName("Wow"); }
            catch { return; }

            foreach (var process in processes)
            {
                try
                {
                    var pid = process.Id;
                    live.Add(pid);
                    Seen old;
                    var isNew = !seen.TryGetValue(pid, out old);
                    if (isNew) old = new Seen { Pid = pid };
                    var cur = Read(pid);
                    if (isNew)
                    {
                        seen[pid] = cur;
                        Emit("SessionStarted", OperatorSeverity.Info, "Runtime", "ExistingIPC", Session(pid), "Detected WoW client PID " + pid + ".", cur);
                        EmitPresence(cur, null);
                    }
                    else
                    {
                        EmitChanges(old, cur);
                        seen[pid] = cur;
                    }
                }
                catch { }
                finally { process.Dispose(); }
            }

            var gone = new List<int>();
            foreach (var kv in seen) if (!live.Contains(kv.Key)) gone.Add(kv.Key);
            foreach (var pid in gone)
            {
                Emit("SessionStopped", OperatorSeverity.Info, "Runtime", "ExistingIPC", Session(pid), "WoW client PID " + pid + " exited.", seen[pid]);
                seen.Remove(pid);
            }
        }

        private static Seen Read(int pid)
        {
            var s = new Seen { Pid = pid };
            using (var map = ReadOnlyMap.TryOpen("Local\\WoW112_AutoLoginProfile_" + pid, 32))
            {
                if (map != null && map.Read32(0) == ProfileMagic && map.Read32(4) == ProfileVersion && map.Read32(8) == (uint)pid)
                {
                    s.Profile1 = map.Read32(12); s.Profile2 = map.Read32(16); s.ProfileLoaded = map.Read32(20) != 0; s.Relogin = map.Read32(24);
                }
            }
            using (var map = ReadOnlyMap.TryOpen("Local\\WoW112_SummonWorker_" + pid, 64))
            {
                if (map != null && map.Read32(0) == WorkerMagic && map.Read32(4) == WorkerVersion && map.Read32(8) == (uint)pid)
                {
                    s.WorkerPresent = true; s.WorkerState = map.Read32(28); s.WorkerPhase = map.Read32(32); s.InWorld = map.Read32(40); s.WorkerError = map.Read32(48); s.WorkerSlot = map.Read32(56);
                }
            }
            using (var map = ReadOnlyMap.TryOpen("Local\\WoW112_SummonAssist_" + pid, 64))
            {
                if (map != null && map.Read32(0) == AssistMagic && map.Read32(4) == AssistVersion && map.Read32(8) == (uint)pid)
                {
                    s.AssistPresent = true; s.AssistDestination = map.Read32(20); s.AssistState = map.Read32(24); s.AssistReadySeq = map.Read32(28); s.AssistFailSeq = map.Read32(32); s.AssistActiveSeq = map.Read32(36);
                }
            }
            return s;
        }

        private static void EmitPresence(Seen cur, Seen old)
        {
            if (cur.ProfileLoaded) Emit("LoginSucceeded", OperatorSeverity.Info, "World", "AutoLoginBridge", Session(cur.Pid), "AutoLogin profile loaded for PID " + cur.Pid + ".", cur);
            if (cur.InWorld != 0) Emit("CharacterEnteredWorld", OperatorSeverity.Info, "World", "SummonWorker", Session(cur.Pid), "Existing worker reports in-world for PID " + cur.Pid + ".", cur);
            if (cur.WorkerPresent) Emit("Debug", OperatorSeverity.Debug, "Summon", "SummonWorker", Session(cur.Pid), "SummonWorker IPC detected.", cur);
            if (cur.AssistPresent) Emit("Debug", OperatorSeverity.Debug, "Summon", "AutoSummonAssist", Session(cur.Pid), "SummonAssist IPC detected.", cur);
        }

        private static void EmitChanges(Seen old, Seen cur)
        {
            if (!old.ProfileLoaded && cur.ProfileLoaded) Emit("LoginSucceeded", OperatorSeverity.Info, "World", "AutoLoginBridge", Session(cur.Pid), "AutoLogin profile became available.", cur);
            if (old.Relogin != cur.Relogin)
            {
                var type = cur.Relogin == 0 ? "ReconnectSucceeded" : "ReconnectStarted";
                Emit(type, OperatorSeverity.Info, "World", "AutoLoginBridge", Session(cur.Pid), "Relogin state " + old.Relogin + " -> " + cur.Relogin + ".", cur);
            }
            if (old.InWorld == 0 && cur.InWorld != 0) Emit("CharacterEnteredWorld", OperatorSeverity.Info, "World", "SummonWorker", Session(cur.Pid), "Worker entered world.", cur);
            else if (old.InWorld != 0 && cur.InWorld == 0) Emit("Disconnected", OperatorSeverity.Warn, "World", "SummonWorker", Session(cur.Pid), "Worker left world.", cur);

            if (!old.WorkerPresent && cur.WorkerPresent) Emit("Debug", OperatorSeverity.Debug, "Summon", "SummonWorker", Session(cur.Pid), "SummonWorker IPC attached.", cur);
            if (old.WorkerState != cur.WorkerState || old.WorkerPhase != cur.WorkerPhase || old.WorkerSlot != cur.WorkerSlot || old.WorkerError != cur.WorkerError)
                Emit("SummonRuntimeState", cur.WorkerError == 0 ? OperatorSeverity.Debug : OperatorSeverity.Warn, "Summon", "SummonWorker", Session(cur.Pid), "Worker state=" + cur.WorkerState + " phase=" + cur.WorkerPhase + " slot=" + cur.WorkerSlot + " error=" + cur.WorkerError + ".", cur);

            if (!old.AssistPresent && cur.AssistPresent) Emit("Debug", OperatorSeverity.Debug, "Summon", "AutoSummonAssist", Session(cur.Pid), "SummonAssist IPC attached.", cur);
            if (old.AssistState != cur.AssistState || old.AssistDestination != cur.AssistDestination || old.AssistActiveSeq != cur.AssistActiveSeq || old.AssistFailSeq != cur.AssistFailSeq || old.AssistReadySeq != cur.AssistReadySeq)
                Emit("SummonRuntimeState", cur.AssistFailSeq != old.AssistFailSeq ? OperatorSeverity.Warn : OperatorSeverity.Debug, "Summon", "AutoSummonAssist", Session(cur.Pid), "Assist state=" + cur.AssistState + " destination=" + cur.AssistDestination + " activeSeq=" + cur.AssistActiveSeq + " readySeq=" + cur.AssistReadySeq + " failSeq=" + cur.AssistFailSeq + ".", cur);
        }

        private static string Session(int pid) { return "wow-pid-" + pid; }

        private static void Emit(string type, OperatorSeverity severity, string category, string module, string sessionId, string message, Seen s)
        {
            try
            {
                var e = new OperatorEvent {
                    Severity = severity, Category = category, EventType = type, Module = module, SessionId = sessionId,
                    Profile = s != null && s.ProfileLoaded ? ("profile-hash:" + s.Profile1.ToString("X8") + "-" + s.Profile2.ToString("X8")) : "",
                    Message = message, Direction = OperatorDirection.System
                };
                if (s != null)
                {
                    e.Metadata["pid"] = s.Pid; e.Metadata["profile_loaded"] = s.ProfileLoaded; e.Metadata["in_world"] = s.InWorld;
                    e.Metadata["summon_worker_present"] = s.WorkerPresent; e.Metadata["summon_assist_present"] = s.AssistPresent;
                }
                var line = json.Serialize(e) + Environment.NewLine;
                lock (fileGate) File.AppendAllText(inbox, line, new UTF8Encoding(false));
            }
            catch { }
        }

        private sealed class ReadOnlyMap : IDisposable
        {
            private readonly IntPtr mapping;
            private readonly IntPtr view;
            private ReadOnlyMap(IntPtr h, IntPtr v) { mapping = h; view = v; }

            internal static ReadOnlyMap TryOpen(string name, int size)
            {
                var h = OpenFileMapping(FileMapRead, false, name); if (h == IntPtr.Zero) return null;
                var v = MapViewOfFile(h, FileMapRead, 0, 0, (UIntPtr)size);
                if (v == IntPtr.Zero) { CloseHandle(h); return null; }
                return new ReadOnlyMap(h, v);
            }

            internal uint Read32(int offset) { return unchecked((uint)Marshal.ReadInt32(view, offset)); }
            public void Dispose() { if (view != IntPtr.Zero) UnmapViewOfFile(view); if (mapping != IntPtr.Zero) CloseHandle(mapping); }
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr OpenFileMapping(uint desiredAccess, bool inheritHandle, string name);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr MapViewOfFile(IntPtr mapping, uint desiredAccess, uint offsetHigh, uint offsetLow, UIntPtr bytesToMap);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnmapViewOfFile(IntPtr address);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
    }
}
