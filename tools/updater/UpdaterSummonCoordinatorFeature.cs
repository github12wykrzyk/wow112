using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed class SummonCoordinatorRouteConfig
    {
        public string Id { get; set; }
        public int Slot { get; set; }
    }

    internal sealed class SummonCoordinatorConfig
    {
        public int Version { get; set; }
        public string WorkerAId { get; set; }
        public string WorkerBId { get; set; }
        // Kept only so V1/V2 JSON can be migrated without losing the old slots.
        public int HyjalSlot { get; set; }
        public int HydraxianSlot { get; set; }
        public List<SummonCoordinatorRouteConfig> Routes { get; set; }
        public bool AutoEnabled { get; set; }
    }

    internal sealed partial class MainForm
    {
        private const uint SummonWorkerMagic = 0x53323157u;
        private const uint SummonWorkerVersion = 2u;
        private const uint SummonAssistMagic = 0x41323157u;
        private const uint SummonAssistVersion = 2u;
        private const int SummonWorkerMapSize = 64;
        private const int SummonAssistMapSize = 64;
        private const int SummonPrepareTimeoutMs = 30000;
        private const int SummonClickTimeoutMs = 10000;
        private bool summonCoordinatorBusy;
        private bool summonCoordinatorAutoTick;
        private System.Windows.Forms.Timer summonCoordinatorTimer;
        private SummonCoordinatorConfig summonCoordinatorConfig;

        private sealed class SummonWorkerSnapshot
        {
            public uint Pid, Heartbeat, CommandSeq, CommandSlot, AckSeq, State, Phase;
            public uint TargetSlot, InWorld, Combat, Error, ElapsedMs, CurrentSlot, LastEventTick;
        }

        private sealed class SummonWorkerChannel : IDisposable
        {
            private const uint FileMapAllAccess = 0x000F001Fu;
            private readonly IntPtr mapping;
            private readonly IntPtr view;
            internal readonly int Pid;

            private SummonWorkerChannel(int pid, IntPtr mappingHandle, IntPtr mappedView)
            {
                Pid = pid; mapping = mappingHandle; view = mappedView;
            }

            internal static SummonWorkerChannel TryOpen(int pid)
            {
                var name = "Local\\WoW112_SummonWorker_" + pid;
                var mapping = OpenFileMapping(FileMapAllAccess, false, name);
                if (mapping == IntPtr.Zero) return null;
                var view = MapViewOfFile(mapping, FileMapAllAccess, 0, 0, (UIntPtr)SummonWorkerMapSize);
                if (view == IntPtr.Zero)
                {
                    CloseHandle(mapping);
                    return null;
                }
                var channel = new SummonWorkerChannel(pid, mapping, view);
                var magic = channel.Read32(0);
                var version = channel.Read32(4);
                var mappedPid = channel.Read32(8);
                if (magic != SummonWorkerMagic || version != SummonWorkerVersion || mappedPid != (uint)pid)
                {
                    channel.Dispose();
                    return null;
                }
                return channel;
            }

            internal static uint ProbeProtocolVersion(int pid)
            {
                var name = "Local\\WoW112_SummonWorker_" + pid;
                var mapping = OpenFileMapping(FileMapAllAccess, false, name);
                if (mapping == IntPtr.Zero) return 0;
                var view = MapViewOfFile(mapping, FileMapAllAccess, 0, 0, (UIntPtr)SummonWorkerMapSize);
                if (view == IntPtr.Zero)
                {
                    CloseHandle(mapping);
                    return 0;
                }
                try
                {
                    var magic = unchecked((uint)Marshal.ReadInt32(view, 0));
                    var version = unchecked((uint)Marshal.ReadInt32(view, 4));
                    var mappedPid = unchecked((uint)Marshal.ReadInt32(view, 8));
                    return magic == SummonWorkerMagic && mappedPid == (uint)pid ? version : 0;
                }
                finally
                {
                    UnmapViewOfFile(view);
                    CloseHandle(mapping);
                }
            }

            internal SummonWorkerSnapshot Read()
            {
                return new SummonWorkerSnapshot {
                    Pid = Read32(8), Heartbeat = Read32(12), CommandSeq = Read32(16), CommandSlot = Read32(20),
                    AckSeq = Read32(24), State = Read32(28), Phase = Read32(32), TargetSlot = Read32(36),
                    InWorld = Read32(40), Combat = Read32(44), Error = Read32(48), ElapsedMs = Read32(52),
                    CurrentSlot = Read32(56), LastEventTick = Read32(60)
                };
            }

            internal void Send(uint seq, int slot)
            {
                SendRaw(seq, (uint)slot);
            }

            internal void SendRaw(uint seq, uint command)
            {
                Write32(20, command);
                Thread.MemoryBarrier();
                Write32(16, seq);
            }

            private uint Read32(int offset) { return unchecked((uint)Marshal.ReadInt32(view, offset)); }
            private void Write32(int offset, uint value) { Marshal.WriteInt32(view, offset, unchecked((int)value)); }

            public void Dispose()
            {
                if (view != IntPtr.Zero) UnmapViewOfFile(view);
                if (mapping != IntPtr.Zero) CloseHandle(mapping);
            }

            [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
            private static extern IntPtr OpenFileMapping(uint desiredAccess, bool inheritHandle, string name);
            [DllImport("kernel32.dll", SetLastError = true)]
            private static extern IntPtr MapViewOfFile(IntPtr mapping, uint desiredAccess, uint offsetHigh, uint offsetLow, UIntPtr bytesToMap);
            [DllImport("kernel32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            private static extern bool UnmapViewOfFile(IntPtr address);
            [DllImport("kernel32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            private static extern bool CloseHandle(IntPtr handle);
        }

        private sealed class SummonAssistSnapshot
        {
            public uint Pid, Heartbeat, RequestSeq, Destination, State, ReadySeq, FailSeq, ActiveSeq;
            public uint PortalPreCalls, PortalPostReturns, PortalGuidLo, PortalGuidHi, RequestTick, LastEventTick;
        }

        private sealed class SummonAssistChannel : IDisposable
        {
            private const uint FileMapAllAccess = 0x000F001Fu;
            private readonly IntPtr mapping;
            private readonly IntPtr view;
            internal readonly int Pid;

            private SummonAssistChannel(int pid, IntPtr mappingHandle, IntPtr mappedView)
            {
                Pid = pid; mapping = mappingHandle; view = mappedView;
            }

            internal static SummonAssistChannel TryOpen(int pid)
            {
                var name = "Local\\WoW112_SummonAssist_" + pid;
                var mapping = OpenFileMapping(FileMapAllAccess, false, name);
                if (mapping == IntPtr.Zero) return null;
                var view = MapViewOfFile(mapping, FileMapAllAccess, 0, 0, (UIntPtr)SummonAssistMapSize);
                if (view == IntPtr.Zero)
                {
                    CloseHandle(mapping);
                    return null;
                }
                var channel = new SummonAssistChannel(pid, mapping, view);
                if (channel.Read32(0) != SummonAssistMagic ||
                    channel.Read32(4) != SummonAssistVersion ||
                    channel.Read32(8) != (uint)pid)
                {
                    channel.Dispose();
                    return null;
                }
                return channel;
            }

            internal SummonAssistSnapshot Read()
            {
                return new SummonAssistSnapshot {
                    Pid = Read32(8), Heartbeat = Read32(12), RequestSeq = Read32(16), Destination = Read32(20),
                    State = Read32(24), ReadySeq = Read32(28), FailSeq = Read32(32), ActiveSeq = Read32(36),
                    PortalPreCalls = Read32(40), PortalPostReturns = Read32(44), PortalGuidLo = Read32(48),
                    PortalGuidHi = Read32(52), RequestTick = Read32(56), LastEventTick = Read32(60)
                };
            }

            internal void SetReady(uint seq)
            {
                Write32(28, seq);
            }

            internal void SetFail(uint seq)
            {
                Write32(32, seq);
            }

            private uint Read32(int offset) { return unchecked((uint)Marshal.ReadInt32(view, offset)); }
            private void Write32(int offset, uint value) { Marshal.WriteInt32(view, offset, unchecked((int)value)); }

            public void Dispose()
            {
                if (view != IntPtr.Zero) UnmapViewOfFile(view);
                if (mapping != IntPtr.Zero) CloseHandle(mapping);
            }

            [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
            private static extern IntPtr OpenFileMapping(uint desiredAccess, bool inheritHandle, string name);
            [DllImport("kernel32.dll", SetLastError = true)]
            private static extern IntPtr MapViewOfFile(IntPtr mapping, uint desiredAccess, uint offsetHigh, uint offsetLow, UIntPtr bytesToMap);
            [DllImport("kernel32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            private static extern bool UnmapViewOfFile(IntPtr address);
            [DllImport("kernel32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            private static extern bool CloseHandle(IntPtr handle);
        }

        private sealed class PendingSummonRequest
        {
            public int Pid;
            public SummonAssistSnapshot Snapshot;
        }

        private static List<SummonCoordinatorRouteConfig> DefaultSummonRoutes()
        {
            return new List<SummonCoordinatorRouteConfig> {
                new SummonCoordinatorRouteConfig { Id = "hydraxian", Slot = 1 },
                new SummonCoordinatorRouteConfig { Id = "hyjal", Slot = 2 },
                new SummonCoordinatorRouteConfig { Id = "winterspring", Slot = 3 }
            };
        }

        private static SummonCoordinatorConfig DefaultSummonCoordinatorConfig()
        {
            return new SummonCoordinatorConfig {
                Version = 4, WorkerAId = "", WorkerBId = "",
                Routes = DefaultSummonRoutes(), AutoEnabled = true
            };
        }

        private static string NormalizeSummonRouteId(string value)
        {
            value = (value ?? "").Trim().ToLowerInvariant();
            if (value.Length < 1 || value.Length > 32)
                throw new InvalidDataException("Id lokalizacji musi mieć 1-32 znaki.");
            foreach (var ch in value)
            {
                var ok = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-';
                if (!ok) throw new InvalidDataException("Id lokalizacji może zawierać tylko a-z, 0-9, _ i -.");
            }
            return value;
        }

        private static uint SummonDestinationKey(string value)
        {
            var id = NormalizeSummonRouteId(value);
            unchecked
            {
                uint hash = 2166136261u;
                foreach (var ch in id)
                {
                    hash ^= (byte)ch;
                    hash *= 16777619u;
                }
                return hash == 0 ? 1u : hash;
            }
        }

        private static void ValidateSummonRoutes(List<SummonCoordinatorRouteConfig> routes)
        {
            if (routes == null || routes.Count == 0)
                throw new InvalidDataException("Coordinator wymaga co najmniej jednej trasy lokalizacja=slot.");
            if (routes.Count > 32)
                throw new InvalidDataException("Coordinator obsługuje maksymalnie 32 trasy.");
            var ids = new HashSet<string>(StringComparer.Ordinal);
            var keys = new HashSet<uint>();
            foreach (var route in routes)
            {
                if (route == null) throw new InvalidDataException("Pusta trasa coordinatora.");
                route.Id = NormalizeSummonRouteId(route.Id);
                if (route.Slot < 1 || route.Slot > 10)
                    throw new InvalidDataException("Slot coordinatora musi być w zakresie 1-10.");
                if (!ids.Add(route.Id))
                    throw new InvalidDataException("Powtórzona lokalizacja coordinatora: " + route.Id);
                var key = SummonDestinationKey(route.Id);
                if (!keys.Add(key))
                    throw new InvalidDataException("Kolizja klucza tras coordinatora: " + route.Id);
            }
        }

        private static SummonCoordinatorRouteConfig FindSummonRoute(SummonCoordinatorConfig cfg, uint destinationKey)
        {
            if (cfg == null || cfg.Routes == null || destinationKey == 0) return null;
            foreach (var route in cfg.Routes)
                if (route != null && SummonDestinationKey(route.Id) == destinationKey) return route;
            return null;
        }

        private static string FormatSummonRoutes(List<SummonCoordinatorRouteConfig> routes)
        {
            var sb = new StringBuilder();
            if (routes != null)
            {
                foreach (var route in routes)
                {
                    if (route == null) continue;
                    if (sb.Length > 0) sb.AppendLine();
                    sb.Append(NormalizeSummonRouteId(route.Id)).Append('=').Append(route.Slot);
                }
            }
            return sb.ToString();
        }

        private static List<SummonCoordinatorRouteConfig> ParseSummonRoutes(string text)
        {
            var routes = new List<SummonCoordinatorRouteConfig>();
            foreach (var raw in (text ?? "").Replace("\r", "").Split('\n'))
            {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#", StringComparison.Ordinal)) continue;
                var parts = line.Split(new[] { '=' }, 2);
                int slot;
                if (parts.Length != 2 || !int.TryParse(parts[1].Trim(), out slot))
                    throw new InvalidDataException("Trasa musi mieć format location=slot: " + line);
                routes.Add(new SummonCoordinatorRouteConfig { Id = parts[0].Trim(), Slot = slot });
            }
            ValidateSummonRoutes(routes);
            return routes;
        }

        private SummonCoordinatorConfig LoadSummonCoordinatorConfig()
        {
            var fallback = DefaultSummonCoordinatorConfig();
            try
            {
                var path = Path.Combine(configDir, "summon_coordinator.json");
                if (!File.Exists(path)) return fallback;
                if (new FileInfo(path).Length > 65536) return fallback;
                var cfg = new JavaScriptSerializer().Deserialize<SummonCoordinatorConfig>(File.ReadAllText(path, Encoding.UTF8));
                if (cfg == null || cfg.Version < 1 || cfg.Version > 4) return fallback;

                if (cfg.Version < 3)
                {
                    var oldVersion = cfg.Version;
                    var hyjal = cfg.HyjalSlot >= 1 && cfg.HyjalSlot <= 10 ? cfg.HyjalSlot : 1;
                    var hydraxian = cfg.HydraxianSlot >= 1 && cfg.HydraxianSlot <= 10 ? cfg.HydraxianSlot : 2;
                    cfg.Routes = DefaultSummonRoutes();

                    // Preserve explicit legacy slot choices. Only the shipped
                    // untouched 1/2 default is realigned to the current
                    // Azshara=1, Hyjal=2 layout.
                    if (!(hyjal == 1 && hydraxian == 2))
                    {
                        cfg.Routes.First(r => r.Id == "hyjal").Slot = hyjal;
                        cfg.Routes.First(r => r.Id == "hydraxian").Slot = hydraxian;
                    }
                    if (oldVersion == 1) cfg.AutoEnabled = true;
                    cfg.Version = 4;
                }
                else if (cfg.Version == 3 && cfg.Routes != null)
                {
                    // V3 shipped exactly: hyjal=1, hydraxian=2, winterspring=4.
                    // Migrate only that untouched default. If the user edited
                    // any route or already uses slot 3, preserve it verbatim.
                    var h = cfg.Routes.FirstOrDefault(r => r != null && string.Equals(r.Id, "hyjal", StringComparison.OrdinalIgnoreCase));
                    var a = cfg.Routes.FirstOrDefault(r => r != null && string.Equals(r.Id, "hydraxian", StringComparison.OrdinalIgnoreCase));
                    var w = cfg.Routes.FirstOrDefault(r => r != null && string.Equals(r.Id, "winterspring", StringComparison.OrdinalIgnoreCase));
                    var slot3Used = cfg.Routes.Any(r => r != null && r.Slot == 3);
                    if (h != null && a != null && w != null && h.Slot == 1 && a.Slot == 2 && w.Slot == 4 && !slot3Used)
                    {
                        a.Slot = 1;
                        h.Slot = 2;
                        w.Slot = 3;
                    }
                    cfg.Version = 4;
                }

                if (cfg.Routes == null) cfg.Routes = DefaultSummonRoutes();
                ValidateSummonRoutes(cfg.Routes);
                cfg.WorkerAId = cfg.WorkerAId ?? "";
                cfg.WorkerBId = cfg.WorkerBId ?? "";
                return cfg;
            }
            catch { return fallback; }
        }

        private void SaveSummonCoordinatorConfig(SummonCoordinatorConfig cfg)
        {
            if (cfg == null) return;
            if (cfg.Routes == null) cfg.Routes = DefaultSummonRoutes();
            ValidateSummonRoutes(cfg.Routes);
            cfg.Version = 4;
            var hyjal = cfg.Routes.FirstOrDefault(r => r != null && r.Id == "hyjal");
            var hydraxian = cfg.Routes.FirstOrDefault(r => r != null && r.Id == "hydraxian");
            cfg.HyjalSlot = hyjal == null ? 0 : hyjal.Slot;
            cfg.HydraxianSlot = hydraxian == null ? 0 : hydraxian.Slot;
            var path = Path.Combine(configDir, "summon_coordinator.json");
            UpdaterSafety.WriteUtf8Atomic(path, new JavaScriptSerializer().Serialize(cfg), ".tmp", ".previous");
            summonCoordinatorConfig = cfg;
        }

        private static uint NewSummonRequestSeq()
        {
            var seq = BitConverter.ToUInt32(Guid.NewGuid().ToByteArray(), 0);
            return seq == 0 ? 1u : seq;
        }

        private static bool HeartbeatFresh(SummonWorkerSnapshot s)
        {
            if (s == null || s.Heartbeat == 0) return false;
            var now = unchecked((uint)Environment.TickCount);
            return unchecked(now - s.Heartbeat) <= 3000u;
        }

        private static string WorkerStateName(uint state)
        {
            switch (state)
            {
                case 0: return "INIT";
                case 1: return "IDLE";
                case 2: return "COMBAT_BLOCKED";
                case 3: return "SWITCHING";
                case 4: return "READY";
                case 5: return "FAILED";
                case 6: return "BUSY";
                case 7: return "WAIT_WORLD";
                case 8: return "OFFLINE";
                default: return "STATE_" + state;
            }
        }

        private static string SafeCoordinatorToken(string value)
        {
            value = value ?? "";
            var chars = value.Take(64).Select(ch => char.IsControl(ch) || char.IsWhiteSpace(ch) || ch == '|' ? '_' : ch).ToArray();
            return new string(chars);
        }

        private void CoordinatorLog(string line)
        {
            try
            {
                var root = gameDir.Text.Trim();
                if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root)) return;
                var path = Path.Combine(root, "SummonCoordinator.log");
                using (var fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
                using (var sw = new StreamWriter(fs, new UTF8Encoding(false)))
                    sw.WriteLine(DateTime.UtcNow.ToString("o") + " " + line);
            }
            catch { }
        }

        internal void AttachSummonCoordinator()
        {
            if (summonCoordinatorTimer != null) return;
            summonCoordinatorConfig = LoadSummonCoordinatorConfig();
            summonCoordinatorTimer = new System.Windows.Forms.Timer { Interval = 250 };
            summonCoordinatorTimer.Tick += SummonCoordinatorAutoTimerTick;
            summonCoordinatorTimer.Start();
            CoordinatorLog("state=AUTO_MONITOR_STARTED interval_ms=250");
        }

        private static bool AssistHeartbeatFresh(SummonAssistSnapshot s)
        {
            if (s == null || s.Heartbeat == 0) return false;
            var now = unchecked((uint)Environment.TickCount);
            return unchecked(now - s.Heartbeat) <= 3000u;
        }

        private static string AssistStateName(uint state)
        {
            switch (state)
            {
                case 0: return "IDLE";
                case 1: return "REQUESTED";
                case 2: return "READY";
                case 3: return "CAST_ISSUED";
                case 4: return "STARTED";
                case 5: return "FAILED";
                case 6: return "CANCELLED";
                default: return "STATE_" + state;
            }
        }

        private WowAccountSession FindLiveAccountSession(string accountId)
        {
            if (string.IsNullOrWhiteSpace(accountId)) return null;
            accountSessions.RemoveAll(s => {
                try { return s.Game == null || s.Game.HasExited; }
                catch { return true; }
            });
            return accountSessions.LastOrDefault(s => s.AccountId == accountId);
        }

        private PendingSummonRequest FindOldestPendingSummonRequest()
        {
            var root = gameDir.Text.Trim();
            if (!Directory.Exists(root)) return null;
            root = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            PendingSummonRequest best = null;
            uint bestAge = 0;
            var now = unchecked((uint)Environment.TickCount);

            foreach (var process in System.Diagnostics.Process.GetProcesses())
            {
                try
                {
                    if (process.HasExited) continue;
                    var fullPath = Path.GetFullPath(process.MainModule.FileName);
                    var name = Path.GetFileName(fullPath);
                    if (!fullPath.StartsWith(root, StringComparison.OrdinalIgnoreCase)
                        || !name.StartsWith("WoW", StringComparison.OrdinalIgnoreCase)
                        || !name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                        continue;

                    using (var channel = SummonAssistChannel.TryOpen(process.Id))
                    {
                        if (channel == null) continue;
                        var s = channel.Read();
                        if (!AssistHeartbeatFresh(s) || s.State != 1 || s.RequestSeq == 0 || s.Destination == 0)
                            continue;
                        var age = unchecked(now - s.RequestTick);
                        if (best == null || age > bestAge)
                        {
                            best = new PendingSummonRequest { Pid = process.Id, Snapshot = s };
                            bestAge = age;
                        }
                    }
                }
                catch (System.ComponentModel.Win32Exception) { }
                catch (InvalidOperationException) { }
                finally { process.Dispose(); }
            }
            return best;
        }

        private async void SummonCoordinatorAutoTimerTick(object sender, EventArgs e)
        {
            if (summonCoordinatorAutoTick || summonCoordinatorBusy || accountVault == null) return;
            var cfg = summonCoordinatorConfig ?? LoadSummonCoordinatorConfig();
            if (cfg == null || !cfg.AutoEnabled || string.IsNullOrWhiteSpace(cfg.WorkerAId) || string.IsNullOrWhiteSpace(cfg.WorkerBId)
                || cfg.WorkerAId == cfg.WorkerBId) return;

            var pending = FindOldestPendingSummonRequest();
            if (pending == null) return;

            summonCoordinatorAutoTick = true;
            try
            {
                await ProcessAutomaticSummonRequestAsync(pending, cfg);
            }
            catch (Exception ex)
            {
                CoordinatorLog("state=AUTO_ERROR reason=" + SafeCoordinatorToken(ex.Message));
            }
            finally
            {
                summonCoordinatorAutoTick = false;
            }
        }

        private async Task ProcessAutomaticSummonRequestAsync(PendingSummonRequest pending, SummonCoordinatorConfig cfg)
        {
            if (pending == null || pending.Snapshot == null || summonCoordinatorBusy) return;
            summonCoordinatorBusy = true;
            var requestSeq = pending.Snapshot.RequestSeq;
            var route = FindSummonRoute(cfg, pending.Snapshot.Destination);
            var destination = route == null ? ("KEY_" + pending.Snapshot.Destination) : route.Id.ToUpperInvariant();
            var slot = route == null ? 0 : route.Slot;
            var requestId = "W" + pending.Pid + "-" + requestSeq;

            try
            {
                using (var warlock = SummonAssistChannel.TryOpen(pending.Pid))
                {
                    if (warlock == null) return;
                    var current = warlock.Read();
                    if (!AssistHeartbeatFresh(current) || current.State != 1 || current.RequestSeq != requestSeq) return;
                    if (route == null)
                    {
                        warlock.SetFail(requestSeq);
                        CoordinatorLog("request_id=" + requestId + " destination_key=" + pending.Snapshot.Destination
                            + " state=FAIL reason=route-unconfigured");
                        return;
                    }

                    var sa = FindLiveAccountSession(cfg.WorkerAId);
                    var sb = FindLiveAccountSession(cfg.WorkerBId);
                    if (sa == null || sb == null || sa.Game.Id == sb.Game.Id)
                    {
                        warlock.SetFail(requestSeq);
                        CoordinatorLog("request_id=" + requestId + " destination=" + destination + " state=FAIL reason=worker-session-missing");
                        return;
                    }

                    using (var workerA = await OpenCoordinatorWorkerAsync(sa))
                    using (var workerB = await OpenCoordinatorWorkerAsync(sb))
                    using (var assistA = SummonAssistChannel.TryOpen(sa.Game.Id))
                    using (var assistB = SummonAssistChannel.TryOpen(sb.Game.Id))
                    {
                        if (workerA == null || workerB == null || assistA == null || assistB == null)
                        {
                            warlock.SetFail(requestSeq);
                            CoordinatorLog("request_id=" + requestId + " destination=" + destination + " state=FAIL reason=worker-map-missing");
                            return;
                        }

                        var clickBaseA = assistA.Read().PortalPreCalls;
                        var clickBaseB = assistB.Read().PortalPreCalls;
                        var workerRequestSeq = NewSummonRequestSeq();

                        CoordinatorLog("request_id=" + requestId + " destination=" + destination + " state=RESERVED lease=PAIR slot=" + slot
                            + " warlock_pid=" + pending.Pid + " workerA_pid=" + sa.Game.Id + " workerB_pid=" + sb.Game.Id);
                        workerA.Send(workerRequestSeq, slot);
                        workerB.Send(workerRequestSeq, slot);

                        var started = Environment.TickCount;
                        while (unchecked(Environment.TickCount - started) < SummonPrepareTimeoutMs)
                        {
                            current = warlock.Read();
                            if (!AssistHeartbeatFresh(current) || current.RequestSeq != requestSeq || current.State != 1)
                            {
                                CoordinatorLog("request_id=" + requestId + " state=CANCELLED reason=warlock-request-gone");
                                return;
                            }

                            var a = workerA.Read();
                            var b = workerB.Read();
                            if (!HeartbeatFresh(a) || !HeartbeatFresh(b))
                            {
                                warlock.SetFail(requestSeq);
                                CoordinatorLog("request_id=" + requestId + " state=FAIL reason=worker-heartbeat");
                                return;
                            }
                            if ((a.AckSeq == workerRequestSeq && a.State == 5) || (b.AckSeq == workerRequestSeq && b.State == 5))
                            {
                                warlock.SetFail(requestSeq);
                                CoordinatorLog("request_id=" + requestId + " state=FAIL reason=worker-switch-failed"
                                    + " a_state=" + WorkerStateName(a.State) + " b_state=" + WorkerStateName(b.State));
                                return;
                            }

                            var readyA = a.AckSeq == workerRequestSeq && a.State == 4 && a.InWorld == 1 && a.CurrentSlot == (uint)slot;
                            var readyB = b.AckSeq == workerRequestSeq && b.State == 4 && b.InWorld == 1 && b.CurrentSlot == (uint)slot;
                            if (readyA && readyB)
                            {
                                warlock.SetReady(requestSeq);
                                CoordinatorLog("request_id=" + requestId + " destination=" + destination + " state=READY ready=2/2 lease=PAIR slot=" + slot);
                                break;
                            }
                            await Task.Delay(100);
                        }

                        current = warlock.Read();
                        if (current.ReadySeq != requestSeq)
                        {
                            warlock.SetFail(requestSeq);
                            CoordinatorLog("request_id=" + requestId + " destination=" + destination + " state=TIMEOUT phase=PREPARE timeout_ms=" + SummonPrepareTimeoutMs);
                            return;
                        }

                        var clickStarted = Environment.TickCount;
                        bool clickedA = false, clickedB = false;
                        while (unchecked(Environment.TickCount - clickStarted) < SummonClickTimeoutMs)
                        {
                            current = warlock.Read();
                            if (!AssistHeartbeatFresh(current) || current.RequestSeq != requestSeq)
                            {
                                CoordinatorLog("request_id=" + requestId + " state=LEASE_RELEASE reason=warlock-gone");
                                return;
                            }

                            var ta = assistA.Read();
                            var tb = assistB.Read();
                            clickedA = ta.PortalPreCalls > clickBaseA;
                            clickedB = tb.PortalPreCalls > clickBaseB;
                            if (clickedA && clickedB)
                            {
                                CoordinatorLog("request_id=" + requestId + " destination=" + destination + " state=CLICKS clicks=2/2 lease=RELEASE"
                                    + " cast_state=" + AssistStateName(current.State));
                                return;
                            }
                            if (current.State == 5 || current.State == 6)
                            {
                                CoordinatorLog("request_id=" + requestId + " destination=" + destination + " state=LEASE_RELEASE reason=warlock-" + AssistStateName(current.State));
                                return;
                            }
                            await Task.Delay(100);
                        }

                        CoordinatorLog("request_id=" + requestId + " destination=" + destination + " state=LEASE_TIMEOUT clicks="
                            + (clickedA ? "1" : "0") + "/" + (clickedB ? "1" : "0")
                            + " timeout_ms=" + SummonClickTimeoutMs + " lease=RELEASE");
                    }
                }
            }
            finally
            {
                summonCoordinatorBusy = false;
            }
        }

        private WowAccount SelectedCoordinatorAccount(ComboBox box)
        {
            var item = box.SelectedItem as WowAccountListItem;
            return item == null ? null : item.Account;
        }

        private async Task<SummonWorkerChannel> OpenCoordinatorWorkerAsync(WowAccountSession session)
        {
            if (session == null || session.Game == null) return null;
            for (int i = 0; i < 50; i++)
            {
                try
                {
                    if (session.Game.HasExited) return null;
                    var channel = SummonWorkerChannel.TryOpen(session.Game.Id);
                    if (channel != null && HeartbeatFresh(channel.Read())) return channel;
                    if (channel != null) channel.Dispose();
                }
                catch { return null; }
                await Task.Delay(100);
            }
            return null;
        }

        private static string FormatWorker(string name, SummonWorkerSnapshot s, uint requestSeq, int slot)
        {
            if (s == null) return name + ": NO MAP";
            var ready = s.AckSeq == requestSeq && s.State == 4 && s.InWorld == 1 && s.CurrentSlot == (uint)slot;
            return name + ": " + WorkerStateName(s.State) +
                " pid=" + s.Pid +
                " slot=" + s.CurrentSlot + "->" + slot +
                " ack=" + (s.AckSeq == requestSeq ? "YES" : "NO") +
                " world=" + s.InWorld +
                " combat=" + s.Combat +
                " phase=" + s.Phase +
                " err=" + s.Error +
                " ms=" + s.ElapsedMs +
                (ready ? "  [READY]" : "");
        }

        private async Task RefreshSummonWorkersAsync(WowAccount a, WowAccount b, TextBox output, IWin32Window owner)
        {
            if (a == null || b == null) throw new InvalidOperationException("Wybierz oba konta slave.");
            if (a.Id == b.Id) throw new InvalidOperationException("Worker A i B muszą być różnymi kontami.");
            var sa = ResolveAccountSession(a, owner);
            var sb = ResolveAccountSession(b, owner);
            if (sa == null || sb == null) return;
            if (sa.Game.Id == sb.Game.Id) throw new InvalidOperationException("Oba workery wskazują ten sam proces WoW.");
            using (var ca = await OpenCoordinatorWorkerAsync(sa))
            using (var cb = await OpenCoordinatorWorkerAsync(sb))
            {
                var aa = ca == null ? null : ca.Read();
                var bb = cb == null ? null : cb.Read();
                output.Text = "A " + SafeCoordinatorToken(a.Label) + ": " + (aa == null ? "brak mapy CharacterSwitchDiag" : WorkerStateName(aa.State) + " PID " + aa.Pid + " world=" + aa.InWorld + " combat=" + aa.Combat + " slot=" + aa.CurrentSlot) + Environment.NewLine +
                              "B " + SafeCoordinatorToken(b.Label) + ": " + (bb == null ? "brak mapy CharacterSwitchDiag" : WorkerStateName(bb.State) + " PID " + bb.Pid + " world=" + bb.InWorld + " combat=" + bb.Combat + " slot=" + bb.CurrentSlot);
            }
        }

        private async Task PrepareSummonPairAsync(string destination, int slot, WowAccount a, WowAccount b, TextBox output, Control[] controls, IWin32Window owner)
        {
            if (summonCoordinatorBusy) return;
            if (a == null || b == null) throw new InvalidOperationException("Wybierz oba konta slave.");
            if (a.Id == b.Id) throw new InvalidOperationException("Worker A i B muszą być różnymi kontami.");
            if (slot < 1 || slot > 10) throw new InvalidOperationException("Nieprawidłowy slot docelowy.");

            summonCoordinatorBusy = true;
            foreach (var control in controls) control.Enabled = false;
            try
            {
                var sa = ResolveAccountSession(a, owner);
                var sb = ResolveAccountSession(b, owner);
                if (sa == null || sb == null) throw new InvalidOperationException("Nie wskazano obu procesów WoW.");
                if (sa.Game.Id == sb.Game.Id) throw new InvalidOperationException("Oba workery wskazują ten sam proces WoW.");

                using (var ca = await OpenCoordinatorWorkerAsync(sa))
                using (var cb = await OpenCoordinatorWorkerAsync(sb))
                {
                    if (ca == null || cb == null)
                        throw new InvalidOperationException("Nie znaleziono aktywnej mapy SummonWorker w obu klientach. Zaktualizuj PARALLEL i uruchom slave'y ponownie.");

                    var requestSeq = NewSummonRequestSeq();
                    var requestId = "R" + requestSeq.ToString("X8");
                    CoordinatorLog("request_id=" + requestId + " destination=" + destination + " state=RESERVED lease=PAIR slot=" + slot +
                        " workerA=" + SafeCoordinatorToken(a.Label) + " pidA=" + sa.Game.Id +
                        " workerB=" + SafeCoordinatorToken(b.Label) + " pidB=" + sb.Game.Id);
                    ca.Send(requestSeq, slot);
                    cb.Send(requestSeq, slot);

                    string lastA = "", lastB = "";
                    var started = Environment.TickCount;
                    while (unchecked(Environment.TickCount - started) < SummonPrepareTimeoutMs)
                    {
                        var aa = ca.Read();
                        var bb = cb.Read();
                        if (!HeartbeatFresh(aa) || !HeartbeatFresh(bb))
                            throw new InvalidOperationException("Heartbeat workera zniknął podczas PREPARE.");

                        var stateA = aa.State + "/" + aa.Phase + "/" + aa.AckSeq + "/" + aa.Error;
                        var stateB = bb.State + "/" + bb.Phase + "/" + bb.AckSeq + "/" + bb.Error;
                        if (stateA != lastA)
                        {
                            lastA = stateA;
                            CoordinatorLog("request_id=" + requestId + " worker=A state=" + WorkerStateName(aa.State) + " phase=" + aa.Phase +
                                " ack=" + aa.AckSeq + " combat=" + aa.Combat + " error=" + aa.Error + " elapsed_ms=" + aa.ElapsedMs);
                        }
                        if (stateB != lastB)
                        {
                            lastB = stateB;
                            CoordinatorLog("request_id=" + requestId + " worker=B state=" + WorkerStateName(bb.State) + " phase=" + bb.Phase +
                                " ack=" + bb.AckSeq + " combat=" + bb.Combat + " error=" + bb.Error + " elapsed_ms=" + bb.ElapsedMs);
                        }

                        output.Text = "PREPARE " + destination + " • request " + requestId + Environment.NewLine +
                                      FormatWorker("A", aa, requestSeq, slot) + Environment.NewLine +
                                      FormatWorker("B", bb, requestSeq, slot);

                        if ((aa.AckSeq == requestSeq && aa.State == 5) || (bb.AckSeq == requestSeq && bb.State == 5))
                            throw new InvalidOperationException("Worker zgłosił FAILED. Wyślij raport z loadera.");

                        var readyA = aa.AckSeq == requestSeq && aa.State == 4 && aa.InWorld == 1 && aa.CurrentSlot == (uint)slot;
                        var readyB = bb.AckSeq == requestSeq && bb.State == 4 && bb.InWorld == 1 && bb.CurrentSlot == (uint)slot;
                        if (readyA && readyB)
                        {
                            CoordinatorLog("request_id=" + requestId + " destination=" + destination + " state=READY ready=2/2 lease=PAIR slot=" + slot);
                            output.Text += Environment.NewLine + destination + " READY 2/2";
                            Log("Slave Coordinator: " + destination + " READY 2/2 (" + requestId + ").");
                            return;
                        }
                        await Task.Delay(100);
                    }
                    CoordinatorLog("request_id=" + requestId + " destination=" + destination + " state=TIMEOUT ready<2/2 timeout_ms=" + SummonPrepareTimeoutMs);
                    throw new TimeoutException("PREPARE przekroczył " + (SummonPrepareTimeoutMs / 1000) + " s. Wyślij raport z loadera.");
                }
            }
            finally
            {
                summonCoordinatorBusy = false;
                foreach (var control in controls) control.Enabled = true;
            }
        }

        private void ShowSummonCoordinator(IWin32Window owner)
        {
            if (accountVault == null || accountVault.Data.Accounts.Count < 2)
            {
                MessageBox.Show(owner, "Coordinator wymaga co najmniej dwóch zapisanych kont slave.", "Slave Coordinator",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            var cfg = LoadSummonCoordinatorConfig();
            using (var dialog = new Form {
                Text = "SLAVE COORDINATOR V3 — shared pair / generic routes",
                ClientSize = new System.Drawing.Size(760, 515),
                FormBorderStyle = FormBorderStyle.FixedDialog,
                MaximizeBox = false, MinimizeBox = false,
                StartPosition = FormStartPosition.CenterParent,
                Font = new System.Drawing.Font("Segoe UI", 9F)
            })
            {
                var workerA = new ComboBox { Left = 20, Top = 45, Width = 335, DropDownStyle = ComboBoxStyle.DropDownList };
                var workerB = new ComboBox { Left = 405, Top = 45, Width = 335, DropDownStyle = ComboBoxStyle.DropDownList };
                foreach (var account in accountVault.Data.Accounts)
                {
                    workerA.Items.Add(new WowAccountListItem(account, account.Id == accountVault.Data.SelectedId));
                    workerB.Items.Add(new WowAccountListItem(account, account.Id == accountVault.Data.SelectedId));
                }
                for (int i = 0; i < workerA.Items.Count; i++)
                {
                    var id = ((WowAccountListItem)workerA.Items[i]).Account.Id;
                    if (id == cfg.WorkerAId) workerA.SelectedIndex = i;
                    if (((WowAccountListItem)workerB.Items[i]).Account.Id == cfg.WorkerBId) workerB.SelectedIndex = i;
                }
                if (workerA.SelectedIndex < 0) workerA.SelectedIndex = 0;
                if (workerB.SelectedIndex < 0) workerB.SelectedIndex = Math.Min(1, workerB.Items.Count - 1);

                var routes = new TextBox {
                    Left = 20, Top = 105, Width = 720, Height = 105,
                    Multiline = true, ScrollBars = ScrollBars.Vertical,
                    Text = FormatSummonRoutes(cfg.Routes)
                };
                var routePicker = new ComboBox { Left = 20, Top = 245, Width = 300, DropDownStyle = ComboBoxStyle.DropDownList };
                var prepare = new Button { Text = "PREPARE WYBRANĄ TRASĘ", Left = 330, Top = 243, Width = 220, Height = 32 };
                var refresh = new Button { Text = "ODŚWIEŻ WORKERY", Left = 20, Top = 288, Width = 180, Height = 32 };
                var auto = new CheckBox { Text = "AUTO: FIFO → READY 2/2 → Ritual → clicks 2/2", Left = 220, Top = 293, Width = 390, Checked = cfg.AutoEnabled };
                var close = new Button { Text = "Zamknij", Left = 620, Top = 288, Width = 120, Height = 32 };
                var output = new TextBox { Left = 20, Top = 335, Width = 720, Height = 125, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical };
                var controls = new Control[] { workerA, workerB, routes, routePicker, prepare, refresh, auto, close };

                Action refreshRoutePicker = delegate {
                    var parsed = ParseSummonRoutes(routes.Text);
                    routePicker.Items.Clear();
                    foreach (var route in parsed)
                        routePicker.Items.Add(route.Id + "=" + route.Slot);
                    if (routePicker.Items.Count > 0) routePicker.SelectedIndex = 0;
                };

                dialog.Controls.AddRange(new Control[] {
                    new Label { Text = "Worker A — konto slave", Left = 20, Top = 20, Width = 250 },
                    new Label { Text = "Worker B — konto slave", Left = 405, Top = 20, Width = 250 },
                    workerA, workerB,
                    new Label { Text = "Trasy: canonical SummonScout location id = character slot (1-10), jedna na linię", Left = 20, Top = 82, Width = 700 },
                    routes,
                    new Label { Text = "Ręczny test trasy:", Left = 20, Top = 225, Width = 180 },
                    routePicker, prepare, refresh, auto, close, output,
                    new Label { Text = "V4: jedna wspólna para slave obsługuje summonerów FIFO. Default: hydraxian=1, hyjal=2, winterspring=3.", Left = 20, Top = 478, Width = 720 }
                });

                Action save = delegate {
                    var a = SelectedCoordinatorAccount(workerA);
                    var b = SelectedCoordinatorAccount(workerB);
                    cfg.WorkerAId = a == null ? "" : a.Id;
                    cfg.WorkerBId = b == null ? "" : b.Id;
                    cfg.Routes = ParseSummonRoutes(routes.Text);
                    cfg.AutoEnabled = auto.Checked;
                    SaveSummonCoordinatorConfig(cfg);
                    refreshRoutePicker();
                };

                refreshRoutePicker();

                refresh.Click += async delegate {
                    try { save(); await RefreshSummonWorkersAsync(SelectedCoordinatorAccount(workerA), SelectedCoordinatorAccount(workerB), output, dialog); }
                    catch (Exception ex) { output.Text = "BŁĄD: " + ex.Message; }
                };
                prepare.Click += async delegate {
                    try
                    {
                        var parsed = ParseSummonRoutes(routes.Text);
                        if (routePicker.SelectedIndex < 0 || routePicker.SelectedIndex >= parsed.Count)
                            throw new InvalidOperationException("Wybierz trasę do PREPARE.");
                        var route = parsed[routePicker.SelectedIndex];
                        save();
                        await PrepareSummonPairAsync(route.Id.ToUpperInvariant(), route.Slot,
                            SelectedCoordinatorAccount(workerA), SelectedCoordinatorAccount(workerB), output, controls, dialog);
                    }
                    catch (Exception ex)
                    {
                        output.Text += Environment.NewLine + "BŁĄD: " + ex.Message;
                        CoordinatorLog("state=MANUAL_PREPARE_ERROR reason=" + SafeCoordinatorToken(ex.Message));
                    }
                };
                close.Click += delegate { if (!summonCoordinatorBusy) dialog.Close(); };
                dialog.FormClosing += delegate(object sender, FormClosingEventArgs e) {
                    if (summonCoordinatorBusy) { e.Cancel = true; return; }
                    try { save(); } catch { }
                };
                dialog.ShowDialog(owner);
            }
        }
    }
}
