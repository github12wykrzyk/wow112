using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace WoW112.OperatorConsole
{
    internal static class OperatorRuntimeBridgeBootstrap
    {
        [System.Runtime.CompilerServices.ModuleInitializer]
        internal static void Initialize()
        {
            var thread = new Thread(OperatorRuntimeBridge.Run) { IsBackground = true, Name = "WoW112 Operator native whisper bridge" };
            thread.Start();
        }
    }

    internal static class OperatorRuntimeBridge
    {
        private const uint Magic = 0x4F323157u;
        private const uint Version = 1u;
        private const int HeaderSize = 556;
        private const int SlotSize = 896;
        private const int RingCount = 16;
        private const int CommandSeqOffset = 28;
        private const int CommandAckOffset = 32;
        private const int CommandStatusOffset = 36;
        private const int CommandKindOffset = 40;
        private const int CommandPlayerOffset = 44;
        private const int CommandTextOffset = 108;
        private const int CommandCorrelationOffset = 364;
        private const int CommandErrorOffset = 428;
        private const int CommandPlayerCap = 64;
        private const int CommandTextCap = 256;
        private const int CommandCorrelationCap = 64;
        private const int CommandErrorCap = 128;
        private const uint CommandWhisper = 1u;
        private const uint CommandPending = 1u;
        private const uint CommandAccepted = 2u;
        private const uint CommandRejected = 3u;
        private const uint CommandUncertain = 4u;

        private sealed class PendingCommand
        {
            public int Pid;
            public uint Seq;
            public string SessionId = "", Character = "", Profile = "", Player = "", Text = "", Correlation = "";
            public DateTime IssuedUtc;
        }

        private sealed class AwaitingSent
        {
            public string SessionId = "", Character = "", Profile = "", Player = "", Correlation = "";
            public DateTime AcceptedUtc;
        }

        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 };
        private static readonly Dictionary<int, uint> LastEventSeq = new Dictionary<int, uint>();
        private static readonly Dictionary<int, uint> LastDropped = new Dictionary<int, uint>();
        private static readonly Dictionary<int, PendingCommand> Pending = new Dictionary<int, PendingCommand>();
        private static readonly Dictionary<string, AwaitingSent> Awaiting = new Dictionary<string, AwaitingSent>(StringComparer.OrdinalIgnoreCase);
        private static string BackendEvents, Commands;
        private static long CommandOffset;
        private static string CommandRemainder = "";

        internal static void Run()
        {
            try
            {
                var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WoW112", "OperatorConsole", "bridge");
                Directory.CreateDirectory(root);
                BackendEvents = Path.Combine(root, "backend-events.jsonl");
                Commands = Path.Combine(root, "operator-commands.jsonl");
                if (File.Exists(Commands)) CommandOffset = new FileInfo(Commands).Length;

                while (true)
                {
                    try
                    {
                        PollMaps();
                        PollCommands();
                        PollTimeouts();
                    }
                    catch (Exception ex)
                    {
                        Emit(new OperatorEvent {
                            Severity = OperatorSeverity.Warn, Category = "Whisper", EventType = "OperatorBridgeWarning",
                            Module = "OperatorRuntimeBridge", Direction = OperatorDirection.System,
                            Message = "Operator bridge poll error: " + ex.Message
                        });
                    }
                    Thread.Sleep(100);
                }
            }
            catch { }
        }

        private static void PollMaps()
        {
            Process[] processes;
            try { processes = Process.GetProcessesByName("Wow"); }
            catch { return; }
            var live = new HashSet<int>();
            foreach (var process in processes)
            {
                try
                {
                    var pid = process.Id;
                    live.Add(pid);
                    using (var map = OperatorMap.TryOpen(pid))
                    {
                        if (map == null) continue;
                        DrainEvents(pid, map);
                        PollCommandAck(pid, map);
                    }
                }
                catch { }
                finally { process.Dispose(); }
            }

            var gone = new List<int>();
            foreach (var pid in LastEventSeq.Keys) if (!live.Contains(pid)) gone.Add(pid);
            foreach (var pid in gone)
            {
                LastEventSeq.Remove(pid);
                LastDropped.Remove(pid);
                Pending.Remove(pid);
            }
        }

        private static void DrainEvents(int pid, OperatorMap map)
        {
            var current = map.Read32(20);
            var dropped = map.Read32(24);
            uint last;
            if (!LastEventSeq.TryGetValue(pid, out last))
            {
                last = current > RingCount ? current - RingCount : 0u;
                LastEventSeq[pid] = last;
                LastDropped[pid] = dropped;
                Emit(new OperatorEvent {
                    Severity = OperatorSeverity.Info, Category = "Whisper", EventType = "OperatorBridgeAttached",
                    Module = "OperatorRuntimeBridge", SessionId = Session(pid), Profile = Profile(pid), Direction = OperatorDirection.System,
                    Message = "Native Operator Bridge attached to WoW PID " + pid + "."
                });
            }

            if (current > last + RingCount)
            {
                var lost = current - last - RingCount;
                last = current - RingCount;
                EmitDrop(pid, lost, "ring overrun");
            }

            for (var seq = last + 1u; seq <= current; seq++)
            {
                var slot = HeaderSize + (int)((seq - 1u) % RingCount) * SlotSize;
                if (map.Read32(slot) != seq)
                {
                    EmitDrop(pid, 1u, "slot commit mismatch");
                    continue;
                }
                var kind = map.Read32(slot + 4);
                var confidence = map.Read32(slot + 8);
                var flags = map.Read32(slot + 12);
                var character = map.ReadUtf8(slot + 16, 64);
                var player = map.ReadUtf8(slot + 80, 64);
                var text = map.ReadUtf8(slot + 144, 256);
                var result = map.ReadUtf8(slot + 400, 32);
                var destination = map.ReadUtf8(slot + 432, 32);
                var intent = map.ReadUtf8(slot + 464, 32);
                var keywords = map.ReadUtf8(slot + 496, 96);
                var matched = map.ReadUtf8(slot + 592, 96);
                var reason = map.ReadUtf8(slot + 688, 144);
                var correlation = map.ReadUtf8(slot + 832, 64);
                var profile = Profile(pid);

                var ev = new OperatorEvent {
                    Severity = OperatorSeverity.Info,
                    Category = "Whisper",
                    Module = "SummonScout.OperatorBridge",
                    SessionId = Session(pid),
                    Profile = profile,
                    Character = character,
                    CorrelationId = correlation,
                    Message = text
                };
                ev.Metadata["player"] = player;
                ev.Metadata["bridge_seq"] = seq;

                if (kind == 1u)
                {
                    ev.EventType = "WhisperReceived";
                    ev.Direction = OperatorDirection.Incoming;
                    ev.Metadata["parser"] = new Dictionary<string, object> {
                        { "sender", player }, { "raw", text }, { "normalized", "" }, { "result", result },
                        { "destination", destination }, { "intent", intent }, { "keywords", keywords },
                        { "matched_rule", matched }, { "reason", reason }, { "ignore_reason", result == "rejected" ? reason : "" },
                        { "confidence", confidence / 1000.0 }, { "competition", (flags & 1u) != 0u },
                        { "summon_request", (flags & 2u) != 0u }
                    };
                }
                else if (kind == 2u || kind == 3u)
                {
                    ev.EventType = "WhisperSent";
                    ev.Direction = kind == 2u ? OperatorDirection.OutgoingManual : OperatorDirection.OutgoingAutomation;
                    if (kind == 2u && !string.IsNullOrWhiteSpace(correlation)) Awaiting.Remove(correlation);
                }
                else
                {
                    ev.EventType = "Debug";
                    ev.Direction = OperatorDirection.System;
                    ev.Severity = OperatorSeverity.Debug;
                }
                Emit(ev);
            }
            LastEventSeq[pid] = current;

            uint oldDropped;
            if (!LastDropped.TryGetValue(pid, out oldDropped)) oldDropped = dropped;
            if (dropped > oldDropped) EmitDrop(pid, dropped - oldDropped, "backend queue/transport drop counter");
            LastDropped[pid] = dropped;
        }

        private static void EmitDrop(int pid, uint count, string reason)
        {
            Emit(new OperatorEvent {
                Severity = OperatorSeverity.Warn, Category = "Whisper", EventType = "WhisperBridgeDropped",
                Module = "OperatorRuntimeBridge", SessionId = Session(pid), Profile = Profile(pid), Direction = OperatorDirection.System,
                Message = "Operator whisper bridge dropped " + count + " event(s): " + reason + "."
            });
        }

        private static void PollCommands()
        {
            if (!File.Exists(Commands)) return;
            byte[] bytes;
            using (var stream = new FileStream(Commands, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                if (stream.Length < CommandOffset) { CommandOffset = stream.Length; CommandRemainder = ""; return; }
                if (stream.Length == CommandOffset) return;
                stream.Position = CommandOffset;
                var remaining = stream.Length - CommandOffset;
                if (remaining > 4 * 1024 * 1024) { CommandOffset = stream.Length; CommandRemainder = ""; return; }
                bytes = new byte[(int)remaining];
                var got = stream.Read(bytes, 0, bytes.Length);
                if (got != bytes.Length) Array.Resize(ref bytes, got);
                CommandOffset += got;
            }

            var text = CommandRemainder + Encoding.UTF8.GetString(bytes);
            var lines = text.Split('\n');
            var complete = text.EndsWith("\n", StringComparison.Ordinal) ? lines.Length : lines.Length - 1;
            CommandRemainder = complete < lines.Length ? lines[lines.Length - 1] : "";
            for (var i = 0; i < complete; i++)
            {
                var line = lines[i].TrimEnd('\r').Trim();
                if (line.Length == 0) continue;
                try
                {
                    var cmd = Json.Deserialize<OperatorCommand>(line);
                    if (cmd != null) Dispatch(cmd);
                }
                catch (Exception ex)
                {
                    Emit(new OperatorEvent {
                        Severity = OperatorSeverity.Warn, Category = "Whisper", EventType = "OperatorCommandRejected",
                        Module = "OperatorRuntimeBridge", Direction = OperatorDirection.System,
                        Message = "Malformed operator command ignored: " + ex.Message
                    });
                }
            }
        }

        private static void Dispatch(OperatorCommand command)
        {
            if (command.CommandType != OperatorCommandType.ReplyToWhisper && command.CommandType != OperatorCommandType.SendWhisper)
            {
                EmitCommand(command, "OperatorCommandRejected", OperatorSeverity.Warn, "Command type is not exposed by the native bridge.");
                return;
            }
            int pid;
            if (!TryPid(command.SessionId, out pid))
            {
                EmitCommand(command, "OperatorCommandRejected", OperatorSeverity.Warn, "Session is not bound to a WoW PID.");
                return;
            }
            if (Pending.ContainsKey(pid))
            {
                EmitCommand(command, "OperatorCommandRejected", OperatorSeverity.Warn, "Native whisper bridge is busy for this character.");
                return;
            }

            var playerBytes = Encoding.UTF8.GetBytes(command.Player ?? "");
            var textBytes = Encoding.UTF8.GetBytes(command.Text ?? "");
            var corrBytes = Encoding.UTF8.GetBytes(command.CorrelationId ?? "");
            if (playerBytes.Length < 1 || playerBytes.Length >= CommandPlayerCap || textBytes.Length < 1 || textBytes.Length >= CommandTextCap || corrBytes.Length >= CommandCorrelationCap)
            {
                EmitCommand(command, "OperatorCommandRejected", OperatorSeverity.Warn, "Command exceeds native bridge field limits.");
                return;
            }

            using (var map = OperatorMap.TryOpen(pid))
            {
                if (map == null || map.Read32(16) == 0u)
                {
                    EmitCommand(command, "OperatorCommandRejected", OperatorSeverity.Warn, "Native Operator Bridge is unavailable or character is not in world.");
                    return;
                }
                var existing = map.Read32(CommandSeqOffset);
                var ack = map.Read32(CommandAckOffset);
                if (existing != 0u && existing != ack)
                {
                    EmitCommand(command, "OperatorCommandRejected", OperatorSeverity.Warn, "Native bridge still has an unacknowledged command.");
                    return;
                }
                var seq = existing + 1u; if (seq == 0u) seq = 1u;
                map.WriteUtf8(CommandPlayerOffset, CommandPlayerCap, command.Player);
                map.WriteUtf8(CommandTextOffset, CommandTextCap, command.Text);
                map.WriteUtf8(CommandCorrelationOffset, CommandCorrelationCap, command.CorrelationId);
                map.WriteUtf8(CommandErrorOffset, CommandErrorCap, "");
                map.Write32(CommandStatusOffset, CommandPending);
                map.Write32(CommandKindOffset, CommandWhisper);
                Thread.MemoryBarrier();
                map.Write32(CommandSeqOffset, seq);

                Pending[pid] = new PendingCommand {
                    Pid = pid, Seq = seq, SessionId = command.SessionId ?? "", Character = command.Character ?? "",
                    Profile = command.Profile ?? "", Player = command.Player ?? "", Text = command.Text ?? "",
                    Correlation = command.CorrelationId ?? "", IssuedUtc = DateTime.UtcNow
                };
                EmitCommand(command, "OperatorCommandDispatched", OperatorSeverity.Info, "Manual whisper dispatched to native bridge; awaiting Lua ACK.");
            }
        }

        private static void PollCommandAck(int pid, OperatorMap map)
        {
            PendingCommand pending;
            if (!Pending.TryGetValue(pid, out pending)) return;
            var ack = map.Read32(CommandAckOffset);
            if (ack != pending.Seq) return;
            var status = map.Read32(CommandStatusOffset);
            var error = map.ReadUtf8(CommandErrorOffset, CommandErrorCap);
            if (status == CommandAccepted)
            {
                EmitPending(pending, "OperatorCommandAccepted", OperatorSeverity.Info,
                    "Lua accepted manual whisper dispatch. Waiting for CHAT_MSG_WHISPER_INFORM confirmation.");
                if (!string.IsNullOrWhiteSpace(pending.Correlation))
                    Awaiting[pending.Correlation] = new AwaitingSent {
                        SessionId = pending.SessionId, Character = pending.Character, Profile = pending.Profile,
                        Player = pending.Player, Correlation = pending.Correlation, AcceptedUtc = DateTime.UtcNow
                    };
            }
            else if (status == CommandRejected)
                EmitPending(pending, "OperatorCommandRejected", OperatorSeverity.Warn, "Lua rejected manual whisper: " + error);
            else
                EmitPending(pending, "OperatorCommandUncertain", OperatorSeverity.Warn, "Manual whisper dispatch result is UNCERTAIN: " + error + " No automatic retry.");
            Pending.Remove(pid);
        }

        private static void PollTimeouts()
        {
            var now = DateTime.UtcNow;
            var timedOut = new List<int>();
            foreach (var kv in Pending)
            {
                if ((now - kv.Value.IssuedUtc).TotalSeconds > 5)
                {
                    EmitPending(kv.Value, "OperatorCommandUncertain", OperatorSeverity.Warn,
                        "Native/Lua ACK timed out. Result is UNCERTAIN; no automatic retry.");
                    timedOut.Add(kv.Key);
                }
            }
            foreach (var pid in timedOut) Pending.Remove(pid);

            var unconfirmed = new List<string>();
            foreach (var kv in Awaiting)
            {
                if ((now - kv.Value.AcceptedUtc).TotalSeconds > 10)
                {
                    var x = kv.Value;
                    var ev = new OperatorEvent {
                        Severity = OperatorSeverity.Warn, Category = "Whisper", EventType = "WhisperSendUnconfirmed",
                        Module = "OperatorRuntimeBridge", SessionId = x.SessionId, Character = x.Character, Profile = x.Profile,
                        CorrelationId = x.Correlation, Direction = OperatorDirection.System,
                        Message = "Manual whisper was dispatch-accepted but no CHAT_MSG_WHISPER_INFORM confirmation arrived."
                    };
                    ev.Metadata["player"] = x.Player;
                    Emit(ev);
                    unconfirmed.Add(kv.Key);
                }
            }
            foreach (var key in unconfirmed) Awaiting.Remove(key);
        }

        private static void EmitCommand(OperatorCommand c, string type, OperatorSeverity severity, string message)
        {
            var e = new OperatorEvent {
                Severity = severity, Category = "Whisper", EventType = type, Module = "OperatorRuntimeBridge",
                SessionId = c.SessionId ?? "", Character = c.Character ?? "", Profile = c.Profile ?? "",
                CorrelationId = c.CorrelationId ?? "", Direction = OperatorDirection.System, Message = message
            };
            e.Metadata["player"] = c.Player ?? "";
            Emit(e);
        }

        private static void EmitPending(PendingCommand p, string type, OperatorSeverity severity, string message)
        {
            var e = new OperatorEvent {
                Severity = severity, Category = "Whisper", EventType = type, Module = "OperatorRuntimeBridge",
                SessionId = p.SessionId, Character = p.Character, Profile = p.Profile, CorrelationId = p.Correlation,
                Direction = OperatorDirection.System, Message = message
            };
            e.Metadata["player"] = p.Player;
            Emit(e);
        }

        private static void Emit(OperatorEvent e)
        {
            if (e == null || string.IsNullOrEmpty(BackendEvents)) return;
            var line = Json.Serialize(e) + Environment.NewLine;
            var bytes = new UTF8Encoding(false).GetBytes(line);
            for (var attempt = 0; attempt < 5; attempt++)
            {
                try
                {
                    using (var stream = new FileStream(BackendEvents, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                    {
                        stream.Write(bytes, 0, bytes.Length);
                        stream.Flush();
                    }
                    return;
                }
                catch (IOException) { Thread.Sleep(10); }
                catch (UnauthorizedAccessException) { return; }
            }
        }

        private static string Session(int pid) { return "wow-pid-" + pid; }

        private static bool TryPid(string sessionId, out int pid)
        {
            pid = 0;
            const string prefix = "wow-pid-";
            if (string.IsNullOrWhiteSpace(sessionId) || !sessionId.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return false;
            return int.TryParse(sessionId.Substring(prefix.Length), out pid) && pid > 0;
        }

        private static string Profile(int pid)
        {
            using (var map = ReadOnlyMap.TryOpen("Local\\WoW112_AutoLoginProfile_" + pid))
            {
                if (map == null || map.Read32(0) != 0x50323157u || map.Read32(4) != 1u || map.Read32(8) != (uint)pid || map.Read32(20) == 0u) return "";
                return "profile-hash:" + map.Read32(12).ToString("X8") + "-" + map.Read32(16).ToString("X8");
            }
        }

        private sealed class OperatorMap : IDisposable
        {
            private const uint FileMapAllAccess = 0x000F001Fu;
            private readonly IntPtr mapping, view;
            private OperatorMap(IntPtr h, IntPtr v) { mapping = h; view = v; }

            internal static OperatorMap TryOpen(int pid)
            {
                var h = OpenFileMapping(FileMapAllAccess, false, "Local\\WoW112_OperatorBridge_" + pid);
                if (h == IntPtr.Zero) return null;
                var v = MapViewOfFile(h, FileMapAllAccess, 0, 0, UIntPtr.Zero);
                if (v == IntPtr.Zero) { CloseHandle(h); return null; }
                var map = new OperatorMap(h, v);
                if (map.Read32(0) != Magic || map.Read32(4) != Version || map.Read32(8) != (uint)pid) { map.Dispose(); return null; }
                return map;
            }

            internal uint Read32(int offset) { return unchecked((uint)Marshal.ReadInt32(view, offset)); }
            internal void Write32(int offset, uint value) { Marshal.WriteInt32(view, offset, unchecked((int)value)); }
            internal string ReadUtf8(int offset, int cap)
            {
                var bytes = new List<byte>(cap);
                for (var i = 0; i < cap; i++) { var b = Marshal.ReadByte(view, offset + i); if (b == 0) break; bytes.Add(b); }
                return Encoding.UTF8.GetString(bytes.ToArray());
            }
            internal void WriteUtf8(int offset, int cap, string value)
            {
                var bytes = Encoding.UTF8.GetBytes(value ?? "");
                if (bytes.Length >= cap) throw new InvalidOperationException("Operator bridge field too long.");
                for (var i = 0; i < cap; i++) Marshal.WriteByte(view, offset + i, i < bytes.Length ? bytes[i] : (byte)0);
            }
            public void Dispose() { if (view != IntPtr.Zero) UnmapViewOfFile(view); if (mapping != IntPtr.Zero) CloseHandle(mapping); }
        }

        private sealed class ReadOnlyMap : IDisposable
        {
            private const uint FileMapRead = 0x0004u;
            private readonly IntPtr mapping, view;
            private ReadOnlyMap(IntPtr h, IntPtr v) { mapping = h; view = v; }
            internal static ReadOnlyMap TryOpen(string name)
            {
                var h = OpenFileMapping(FileMapRead, false, name); if (h == IntPtr.Zero) return null;
                var v = MapViewOfFile(h, FileMapRead, 0, 0, UIntPtr.Zero); if (v == IntPtr.Zero) { CloseHandle(h); return null; }
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
