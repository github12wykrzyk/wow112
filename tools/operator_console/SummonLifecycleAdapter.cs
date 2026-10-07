using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace WoW112.OperatorConsole
{
    internal static class SummonLifecycleAdapterBootstrap
    {
        [System.Runtime.CompilerServices.ModuleInitializer]
        internal static void Initialize()
        {
            var thread = new Thread(SummonLifecycleAdapter.Run) {
                IsBackground = true,
                Name = "WoW112 Summon lifecycle telemetry"
            };
            thread.Start();
        }
    }

    // Read-only decoder for Operator Bridge event kinds 4..9. The existing
    // RuntimeAdapters class owns whisper command dispatch/ACK. This class never
    // writes to the WoW mapping and cannot issue gameplay or economic actions.
    internal static class SummonLifecycleAdapter
    {
        private const uint Magic = 0x4F323157u;
        private const uint Version = 1u;
        private const int HeaderSize = 556;
        private const int SlotSize = 896;
        private const int RingCount = 16;
        private const int MapSize = HeaderSize + SlotSize * RingCount;
        private const uint FileMapRead = 0x0004u;

        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 };
        private static readonly object FileGate = new object();
        private static readonly Dictionary<int, uint> LastSeq = new Dictionary<int, uint>();
        private static readonly HashSet<string> Seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private static readonly List<int> CandidatePids = new List<int>();
        private static string BackendEvents = "";
        private static string DedupePath = "";
        private static DateTime NextDiscoveryUtc = DateTime.MinValue;

        internal static void Run()
        {
            try
            {
                var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WoW112", "OperatorConsole");
                var bridge = Path.Combine(root, "bridge");
                Directory.CreateDirectory(bridge);
                BackendEvents = Path.Combine(bridge, "backend-events.jsonl");
                DedupePath = Path.Combine(bridge, "summon-telemetry-seen.txt");
                LoadDedupe();

                while (true)
                {
                    try
                    {
                        DiscoverIfDue();
                        Poll();
                    }
                    catch (Exception ex)
                    {
                        Emit(new OperatorEvent {
                            Severity = OperatorSeverity.Warn,
                            Category = "Runtime",
                            EventType = "SummonTelemetryWarning",
                            Module = "SummonLifecycleAdapter",
                            Direction = OperatorDirection.System,
                            Message = "Summon telemetry poll error: " + ex.Message
                        }, false);
                    }
                    Thread.Sleep(100);
                }
            }
            catch { }
        }

        private static void DiscoverIfDue()
        {
            var now = DateTime.UtcNow;
            if (now < NextDiscoveryUtc) return;
            NextDiscoveryUtc = now.AddSeconds(1);
            var found = new List<int>();
            Process[] processes;
            try { processes = Process.GetProcesses(); }
            catch { return; }
            foreach (var process in processes)
            {
                try
                {
                    var pid = process.Id;
                    using (var map = Map.TryOpen(pid)) if (map != null) found.Add(pid);
                }
                catch { }
                finally { process.Dispose(); }
            }
            CandidatePids.Clear();
            CandidatePids.AddRange(found);

            var gone = new List<int>();
            foreach (var pid in LastSeq.Keys) if (!found.Contains(pid)) gone.Add(pid);
            foreach (var pid in gone) LastSeq.Remove(pid);
        }

        private static void Poll()
        {
            foreach (var pid in CandidatePids)
            {
                using (var map = Map.TryOpen(pid))
                {
                    if (map == null) continue;
                    var current = map.Read32(20);
                    uint last;
                    if (!LastSeq.TryGetValue(pid, out last))
                        last = current > RingCount ? current - RingCount : 0u;

                    if (current > last + RingCount)
                    {
                        var lost = current - last - RingCount;
                        last = current - RingCount;
                        Emit(new OperatorEvent {
                            Severity = OperatorSeverity.Warn,
                            Category = "Summon",
                            EventType = "SummonTelemetryDropped",
                            Module = "SummonLifecycleAdapter",
                            SessionId = Session(pid),
                            Direction = OperatorDirection.System,
                            Message = "Summon telemetry ring overrun: " + lost + " event(s) lost."
                        }, false);
                    }

                    for (var seq = last + 1u; seq <= current; seq++)
                    {
                        var slot = HeaderSize + (int)((seq - 1u) % RingCount) * SlotSize;
                        if (map.Read32(slot) != seq) continue;
                        Decode(pid, seq, slot, map);
                    }
                    LastSeq[pid] = current;
                }
            }
        }

        private static void Decode(int pid, uint seq, int slot, Map map)
        {
            var kind = map.Read32(slot + 4);
            if (kind < 4u || kind > 9u) return;

            var character = map.ReadUtf8(slot + 16, 64);
            var player = map.ReadUtf8(slot + 80, 64);
            var text = map.ReadUtf8(slot + 144, 256);
            var result = map.ReadUtf8(slot + 400, 32);
            var destination = map.ReadUtf8(slot + 432, 32);
            var intent = map.ReadUtf8(slot + 464, 32);
            var keywords = map.ReadUtf8(slot + 496, 96);
            var sourceUnix = map.ReadUtf8(slot + 592, 96);
            var reason = map.ReadUtf8(slot + 688, 144);
            var correlation = map.ReadUtf8(slot + 832, 64);

            var ev = new OperatorEvent {
                Severity = OperatorSeverity.Info,
                Category = kind == 8u ? "Payment" : kind == 9u ? "Whisper" : "Summon",
                Module = "SummonScout.OperatorBridge",
                SessionId = Session(pid),
                Character = character,
                CorrelationId = correlation,
                Direction = OperatorDirection.System,
                Message = text
            };
            ev.Metadata["player"] = player;
            ev.Metadata["destination"] = destination;
            ev.Metadata["bridge_seq"] = seq;
            ev.Metadata["source"] = "canonical-summonscout";
            ev.Metadata["result"] = result;
            ev.Metadata["intent"] = intent;
            ApplySourceTime(ev, sourceUnix);

            switch (kind)
            {
                case 4u:
                    ev.EventType = "SummonQueued";
                    if (!string.IsNullOrWhiteSpace(keywords)) ev.Metadata["request_seq"] = keywords;
                    Emit(ev, true);
                    break;
                case 5u:
                    ev.EventType = "SummonStarted";
                    if (!string.IsNullOrWhiteSpace(keywords)) ev.Metadata["request_seq"] = keywords;
                    Emit(ev, true);
                    break;
                case 6u:
                    ev.EventType = "SummonCompleted";
                    if (!string.IsNullOrWhiteSpace(keywords)) ev.Metadata["request_seq"] = keywords;
                    Emit(ev, true);
                    var pay = new OperatorEvent {
                        TimestampUtc = ev.TimestampUtc,
                        Severity = OperatorSeverity.Info,
                        Category = "Payment",
                        EventType = "PaymentExpected",
                        Module = "SummonLifecycleAdapter",
                        SessionId = ev.SessionId,
                        Character = ev.Character,
                        CorrelationId = string.IsNullOrWhiteSpace(correlation) ? "" : correlation + ":payment",
                        Direction = OperatorDirection.System,
                        Message = "Payment expected after completed summon for " + (player.Length == 0 ? "unknown player" : player) + "."
                    };
                    pay.Metadata["player"] = player;
                    pay.Metadata["destination"] = destination;
                    pay.Metadata["source"] = "summon-completed";
                    Emit(pay, true);
                    break;
                case 7u:
                    ev.EventType = "SummonFailed";
                    ev.Severity = OperatorSeverity.Warn;
                    ev.Message = text + (string.IsNullOrWhiteSpace(reason) ? "" : " | " + reason);
                    if (!string.IsNullOrWhiteSpace(keywords)) ev.Metadata["request_seq"] = keywords;
                    ev.Metadata["reason"] = reason;
                    Emit(ev, true);
                    break;
                case 8u:
                    ev.EventType = "PaymentReceived";
                    long copper;
                    if (long.TryParse(keywords, NumberStyles.Integer, CultureInfo.InvariantCulture, out copper) && copper > 0)
                    {
                        ev.Metadata["copper"] = copper;
                        ev.Message = "Received " + Money(copper) + " from " + (player.Length == 0 ? "UNKNOWN" : player) + ".";
                    }
                    ev.Metadata["trusted_ledger"] = true;
                    Emit(ev, true);
                    break;
                case 9u:
                    ev.EventType = "WhisperSendUncertain";
                    ev.Severity = OperatorSeverity.Warn;
                    ev.Direction = OperatorDirection.OutgoingManual;
                    ev.Metadata["reason"] = reason;
                    ev.Message = "Manual whisper to " + (player.Length == 0 ? "unknown player" : player) + " has no final CHAT_MSG_WHISPER_INFORM confirmation; no retry.";
                    Emit(ev, true);
                    break;
            }
        }

        private static void ApplySourceTime(OperatorEvent ev, string raw)
        {
            long unix;
            if (!long.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out unix)) return;
            if (unix < 946684800L || unix > 4102444800L) return;
            ev.TimestampUtc = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(unix);
            ev.Metadata["source_unix"] = unix;
        }

        private static string Money(long copper)
        {
            return (copper / 10000L) + "g " + ((copper / 100L) % 100L) + "s " + (copper % 100L) + "c";
        }

        private static string Session(int pid) { return "wow-pid-" + pid; }

        private static string DedupeKey(OperatorEvent ev)
        {
            if (string.IsNullOrWhiteSpace(ev.CorrelationId)) return "";
            return ev.EventType + "|" + ev.CorrelationId;
        }

        private static void Emit(OperatorEvent ev, bool dedupe)
        {
            try
            {
                var key = dedupe ? DedupeKey(ev) : "";
                lock (FileGate)
                {
                    if (key.Length > 0 && Seen.Contains(key)) return;
                    File.AppendAllText(BackendEvents, Json.Serialize(ev) + Environment.NewLine, new UTF8Encoding(false));
                    if (key.Length > 0)
                    {
                        Seen.Add(key);
                        File.AppendAllText(DedupePath, key + Environment.NewLine, new UTF8Encoding(false));
                    }
                }
            }
            catch { }
        }

        private static void LoadDedupe()
        {
            try
            {
                if (!File.Exists(DedupePath)) return;
                foreach (var line in File.ReadAllLines(DedupePath, Encoding.UTF8))
                {
                    var key = (line ?? "").Trim();
                    if (key.Length > 0) Seen.Add(key);
                }
            }
            catch { }
        }

        private sealed class Map : IDisposable
        {
            private readonly IntPtr handle;
            private readonly IntPtr view;
            private Map(IntPtr h, IntPtr v) { handle = h; view = v; }

            internal static Map TryOpen(int pid)
            {
                var h = OpenFileMapping(FileMapRead, false, "Local\\WoW112_OperatorBridge_" + pid);
                if (h == IntPtr.Zero) return null;
                var v = MapViewOfFile(h, FileMapRead, 0, 0, (UIntPtr)MapSize);
                if (v == IntPtr.Zero) { CloseHandle(h); return null; }
                var map = new Map(h, v);
                if (map.Read32(0) != Magic || map.Read32(4) != Version || map.Read32(8) != (uint)pid)
                { map.Dispose(); return null; }
                return map;
            }

            internal uint Read32(int offset) { return unchecked((uint)Marshal.ReadInt32(view, offset)); }
            internal string ReadUtf8(int offset, int cap)
            {
                var bytes = new byte[cap];
                Marshal.Copy(IntPtr.Add(view, offset), bytes, 0, cap);
                var n = Array.IndexOf(bytes, (byte)0); if (n < 0) n = cap;
                try { return Encoding.UTF8.GetString(bytes, 0, n); } catch { return ""; }
            }
            public void Dispose()
            {
                if (view != IntPtr.Zero) UnmapViewOfFile(view);
                if (handle != IntPtr.Zero) CloseHandle(handle);
            }
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenFileMapping(uint desiredAccess, bool inheritHandle, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr MapViewOfFile(IntPtr mapping, uint desiredAccess, uint offsetHigh, uint offsetLow, UIntPtr bytesToMap);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnmapViewOfFile(IntPtr address);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);
    }
}
