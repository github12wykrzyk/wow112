using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace WoW112.OperatorConsole
{
    internal enum OperatorSeverity { Trace = 0, Debug = 1, Info = 2, Warn = 3, Error = 4 }
    internal enum OperatorStatus { Ok, Active, Idle, Warning, Error, Uncertain, Blocked }
    internal enum OperatorDirection { None, Incoming, OutgoingAutomation, OutgoingManual, System }

    internal sealed class OperatorEvent
    {
        public string SchemaVersion = "1";
        public string EventId = Guid.NewGuid().ToString("N");
        public DateTime TimestampUtc = DateTime.UtcNow;
        public OperatorSeverity Severity = OperatorSeverity.Info;
        public string Category = "General";
        public string EventType = "Debug";
        public string Account = "";
        public string Profile = "";
        public string Character = "";
        public string SessionId = "";
        public string Module = "";
        public string Message = "";
        public string CorrelationId = "";
        public string OperationId = "";
        public OperatorDirection Direction = OperatorDirection.None;
        public Dictionary<string, object> Metadata = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);

        public string ConversationPlayer
        {
            get
            {
                object value;
                return Metadata != null && Metadata.TryGetValue("player", out value) ? Convert.ToString(value) ?? "" : "";
            }
        }
    }

    internal sealed class ParserDiagnostic
    {
        public string EventId = "", Sender = "", RawText = "", NormalizedText = "", Result = "", Destination = "", Intent = "", Keywords = "", MatchedRule = "", IgnoreReason = "", Reason = "";
        public double Confidence;
        public bool Competition, SummonRequest;
    }

    internal sealed class SessionState
    {
        public string SessionId = "", Account = "", Profile = "", Character = "", Module = "", CurrentAction = "", LastEvent = "", LastError = "";
        public DateTime LastActivityUtc, StartedUtc;
        public OperatorStatus World = OperatorStatus.Idle, Ah = OperatorStatus.Idle, Summon = OperatorStatus.Idle, Mail = OperatorStatus.Idle, Coordinator = OperatorStatus.Idle, Whispers = OperatorStatus.Idle;
        public int WhisperQueue, SummonQueue;
        public bool Connected;

        public SessionState Copy()
        {
            return new SessionState {
                SessionId = SessionId, Account = Account, Profile = Profile, Character = Character, Module = Module, CurrentAction = CurrentAction,
                LastEvent = LastEvent, LastError = LastError, LastActivityUtc = LastActivityUtc, StartedUtc = StartedUtc,
                World = World, Ah = Ah, Summon = Summon, Mail = Mail, Coordinator = Coordinator, Whispers = Whispers,
                WhisperQueue = WhisperQueue, SummonQueue = SummonQueue, Connected = Connected
            };
        }
    }

    internal sealed class WhisperCounters { public long Total, Understood, IgnoredIntentionally, Unhandled; }

    internal enum OperatorCommandType { SendWhisper, ReplyToWhisper, PauseAutomation, ResumeAutomation }

    internal sealed class OperatorCommand
    {
        public string SchemaVersion = "1", CommandId = Guid.NewGuid().ToString("N"), Account = "", Profile = "", Character = "", SessionId = "", Player = "", Text = "", CorrelationId = "";
        public DateTime TimestampUtc = DateTime.UtcNow;
        public OperatorCommandType CommandType;
    }

    internal interface IOperatorCommandSink { void Submit(OperatorCommand command); }

    internal sealed class OperatorEventBus
    {
        private readonly BlockingCollection<OperatorEvent> queue = new BlockingCollection<OperatorEvent>(new ConcurrentQueue<OperatorEvent>());
        public event Action<OperatorEvent> Published;
        public int Pending { get { return queue.Count; } }
        public OperatorEvent Take(CancellationToken token) { return queue.Take(token); }
        public void Publish(OperatorEvent item)
        {
            if (item == null) return;
            item.Message = SecretSanitizer.Sanitize(item.Message);
            item.Metadata = SecretSanitizer.SanitizeMetadata(item.Metadata);
            queue.Add(item);
            var h = Published; if (h != null) h(item);
        }
    }

    internal sealed class OperatorStateStore
    {
        private readonly object gate = new object();
        private readonly Dictionary<string, SessionState> sessions = new Dictionary<string, SessionState>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, ParserDiagnostic> parser = new Dictionary<string, ParserDiagnostic>(StringComparer.OrdinalIgnoreCase);
        private readonly WhisperCounters counters = new WhisperCounters();

        public void Apply(OperatorEvent e)
        {
            if (e == null) return;
            lock (gate)
            {
                var key = string.IsNullOrWhiteSpace(e.SessionId) ? ((e.Account ?? "") + "|" + (e.Character ?? "")) : e.SessionId;
                SessionState s;
                if (!sessions.TryGetValue(key, out s))
                {
                    s = new SessionState { SessionId = e.SessionId, Account = e.Account, Profile = e.Profile, Character = e.Character, StartedUtc = e.TimestampUtc };
                    sessions[key] = s;
                }
                s.Account = e.Account ?? s.Account; s.Profile = e.Profile ?? s.Profile; s.Character = e.Character ?? s.Character; s.Module = e.Module ?? s.Module;
                s.LastActivityUtc = e.TimestampUtc; s.LastEvent = e.EventType + ": " + e.Message;
                if (e.Severity == OperatorSeverity.Error) s.LastError = e.Message;
                Project(e, s); ProjectWhisper(e);
            }
        }

        private static void Project(OperatorEvent e, SessionState s)
        {
            switch (e.EventType)
            {
                case "SessionStarted": s.StartedUtc = e.TimestampUtc; break;
                case "LoginStarted": s.World = OperatorStatus.Active; s.CurrentAction = "Login"; break;
                case "LoginSucceeded": case "CharacterEnteredWorld": s.World = OperatorStatus.Ok; s.Connected = true; s.CurrentAction = ""; break;
                case "LoginFailed": case "Disconnected": if (s.Coordinator != OperatorStatus.Uncertain) s.World = OperatorStatus.Error; s.Connected = false; break;
                case "ReconnectStarted": s.World = OperatorStatus.Active; s.CurrentAction = "Reconnect"; break;
                case "ReconnectSucceeded": s.World = OperatorStatus.Ok; s.Connected = true; s.CurrentAction = ""; break;
                case "WhisperReceived": s.Whispers = OperatorStatus.Active; break;
                case "SummonQueued": s.Summon = OperatorStatus.Active; s.SummonQueue++; break;
                case "SummonStarted": s.Summon = OperatorStatus.Active; s.CurrentAction = "Summon"; break;
                case "SummonCompleted": s.Summon = OperatorStatus.Ok; if (s.SummonQueue > 0) s.SummonQueue--; s.CurrentAction = ""; break;
                case "SummonFailed": s.Summon = OperatorStatus.Error; s.CurrentAction = ""; break;
                case "AHScanStarted": s.Ah = OperatorStatus.Active; s.CurrentAction = "AH scan"; break;
                case "AHScanFinished": s.Ah = OperatorStatus.Ok; s.CurrentAction = ""; break;
                case "MailMutationStarted": s.Mail = OperatorStatus.Active; break;
                case "MailMutationConfirmed": if (s.Mail != OperatorStatus.Uncertain) s.Mail = OperatorStatus.Ok; break;
                case "MailMutationUncertain": s.Mail = OperatorStatus.Uncertain; s.Coordinator = OperatorStatus.Uncertain; break;
                case "MutationCoordinatorLocked": if (s.Coordinator != OperatorStatus.Uncertain) s.Coordinator = OperatorStatus.Active; break;
                case "MutationCoordinatorReleased": if (s.Coordinator != OperatorStatus.Uncertain) s.Coordinator = OperatorStatus.Ok; break;
                case "MutationCoordinatorUncertain": case "BuyUncertain": s.Coordinator = OperatorStatus.Uncertain; break;
            }
        }

        private void ProjectWhisper(OperatorEvent e)
        {
            if (e.EventType == "WhisperReceived") counters.Total++;
            else if (e.EventType == "WhisperParsed") counters.Understood++;
            else if (e.EventType == "WhisperIgnored") counters.IgnoredIntentionally++;
            else if (e.EventType == "UnhandledWhisper") counters.Unhandled++;

            object raw;
            if (e.Metadata == null || !e.Metadata.TryGetValue("parser", out raw)) return;
            var dict = raw as Dictionary<string, object>;
            if (dict == null)
            {
                var generic = raw as IDictionary<string, object>;
                if (generic != null) dict = generic.ToDictionary(k => k.Key, v => v.Value, StringComparer.OrdinalIgnoreCase);
            }
            if (dict == null) return;
            parser[e.EventId] = new ParserDiagnostic {
                EventId = e.EventId, Sender = S(dict, "sender"), RawText = S(dict, "raw"), NormalizedText = S(dict, "normalized"), Result = S(dict, "result"), Destination = S(dict, "destination"), Intent = S(dict, "intent"), Keywords = S(dict, "keywords"), MatchedRule = S(dict, "matched_rule"), IgnoreReason = S(dict, "ignore_reason"), Reason = S(dict, "reason"), Competition = B(dict, "competition"), SummonRequest = B(dict, "summon_request"), Confidence = D(dict, "confidence")
            };
        }

        private static string S(IDictionary<string, object> d, string k) { object v; return d.TryGetValue(k, out v) ? Convert.ToString(v) ?? "" : ""; }
        private static bool B(IDictionary<string, object> d, string k) { object v; bool x; return d.TryGetValue(k, out v) && bool.TryParse(Convert.ToString(v), out x) && x; }
        private static double D(IDictionary<string, object> d, string k) { object v; double x; return d.TryGetValue(k, out v) && double.TryParse(Convert.ToString(v), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out x) ? x : 0.0; }

        public List<SessionState> Sessions() { lock (gate) return sessions.Values.Select(x => x.Copy()).OrderBy(x => x.Character).ToList(); }
        public WhisperCounters Counters() { lock (gate) return new WhisperCounters { Total = counters.Total, Understood = counters.Understood, IgnoredIntentionally = counters.IgnoredIntentionally, Unhandled = counters.Unhandled }; }
        public ParserDiagnostic ParserFor(string eventId) { lock (gate) { ParserDiagnostic p; return parser.TryGetValue(eventId ?? "", out p) ? p : null; } }
    }

    internal sealed class JsonlOperatorStore : IDisposable
    {
        private readonly object gate = new object();
        private readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        private readonly string directory, path;
        private readonly long rotateBytes;
        private readonly int keepFiles;
        private StreamWriter writer;

        public JsonlOperatorStore(string directoryPath, long rotateBytes = 16L * 1024L * 1024L, int keepFiles = 10)
        {
            directory = directoryPath; this.rotateBytes = rotateBytes; this.keepFiles = Math.Max(2, keepFiles);
            Directory.CreateDirectory(directory); path = Path.Combine(directory, "operator-events.jsonl"); Open();
        }
        private void Open() { writer = new StreamWriter(new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false)) { AutoFlush = true }; }
        public void Append(OperatorEvent e) { lock (gate) { Rotate(); writer.WriteLine(json.Serialize(e)); } }
        public List<OperatorEvent> Load(int maxCount)
        {
            var all = new List<OperatorEvent>();
            foreach (var f in Directory.GetFiles(directory, "operator-events*.jsonl").OrderBy(x => x, StringComparer.OrdinalIgnoreCase))
            {
                try { foreach (var line in File.ReadLines(f)) if (!string.IsNullOrWhiteSpace(line)) try { var e = json.Deserialize<OperatorEvent>(line); if (e != null) all.Add(e); } catch { } } catch { }
            }
            return all.OrderBy(x => x.TimestampUtc).TakeLastCompat(maxCount).ToList();
        }
        private void Rotate()
        {
            writer.Flush(); var fi = new FileInfo(path); if (!fi.Exists || fi.Length < rotateBytes) return;
            writer.Dispose(); var rotated = Path.Combine(directory, "operator-events-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss-fff") + ".jsonl"); File.Move(path, rotated);
            foreach (var f in Directory.GetFiles(directory, "operator-events-*.jsonl").OrderByDescending(File.GetLastWriteTimeUtc).Skip(keepFiles - 1)) try { File.Delete(f); } catch { }
            Open();
        }
        public void Dispose() { lock (gate) { if (writer != null) writer.Dispose(); writer = null; } }
    }

    internal static class EnumerableCompat
    {
        public static IEnumerable<T> TakeLastCompat<T>(this IEnumerable<T> source, int count)
        {
            if (count <= 0) return Enumerable.Empty<T>(); var q = new Queue<T>(count);
            foreach (var item in source) { if (q.Count == count) q.Dequeue(); q.Enqueue(item); } return q;
        }
    }

    internal static class SecretSanitizer
    {
        private static readonly Regex KeyPattern = new Regex("(?i)password|passwd|pwd|token|secret|authorization|dpapi", RegexOptions.Compiled);
        private static readonly Regex Assignment = new Regex("(?i)(password|passwd|pwd|token|secret|authorization|dpapi)\\s*[:=]\\s*([^\\s,;]+)", RegexOptions.Compiled);
        private static readonly Regex Bearer = new Regex("(?i)bearer\\s+[A-Za-z0-9._~+\\-/]+=*", RegexOptions.Compiled);
        private static readonly Regex Github = new Regex("(?i)gh[pousr]_[A-Za-z0-9_]{20,}", RegexOptions.Compiled);
        public static string Sanitize(string text)
        {
            var x = text ?? "";
            x = Assignment.Replace(x, "$1=[REDACTED]"); x = Bearer.Replace(x, "bearer [REDACTED]"); x = Github.Replace(x, "[REDACTED]"); return x;
        }
        public static Dictionary<string, object> SanitizeMetadata(Dictionary<string, object> metadata)
        {
            var safe = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase); if (metadata == null) return safe;
            foreach (var kv in metadata) safe[kv.Key] = KeyPattern.IsMatch(kv.Key ?? "") ? (object)"[REDACTED]" : (kv.Value is string ? (object)Sanitize((string)kv.Value) : kv.Value);
            return safe;
        }
    }

    internal sealed class FileOperatorBridge : IOperatorCommandSink, IDisposable
    {
        private readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        private readonly object commandGate = new object();
        private readonly string eventsInbox, commandsOutbox;
        private readonly OperatorEventBus bus;
        private FileSystemWatcher watcher;
        private long offset;

        public FileOperatorBridge(string bridgeDirectory, OperatorEventBus eventBus)
        {
            Directory.CreateDirectory(bridgeDirectory); eventsInbox = Path.Combine(bridgeDirectory, "backend-events.jsonl"); commandsOutbox = Path.Combine(bridgeDirectory, "operator-commands.jsonl"); bus = eventBus;
            if (!File.Exists(eventsInbox)) File.WriteAllText(eventsInbox, "", new UTF8Encoding(false));
            offset = 0; watcher = new FileSystemWatcher(bridgeDirectory, Path.GetFileName(eventsInbox)); watcher.NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size;
            watcher.Changed += delegate { Drain(); }; watcher.EnableRaisingEvents = true; Drain();
        }

        public void Submit(OperatorCommand command)
        {
            if (command == null) return;
            switch (command.CommandType)
            {
                case OperatorCommandType.SendWhisper: case OperatorCommandType.ReplyToWhisper: case OperatorCommandType.PauseAutomation: case OperatorCommandType.ResumeAutomation: break;
                default: throw new InvalidOperationException("Operator Console refuses unsupported command type.");
            }
            command.Text = SecretSanitizer.Sanitize(command.Text);
            lock (commandGate) File.AppendAllText(commandsOutbox, json.Serialize(command) + Environment.NewLine, new UTF8Encoding(false));
        }

        public void Drain()
        {
            try
            {
                using (var fs = new FileStream(eventsInbox, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    if (offset > fs.Length) offset = 0; fs.Position = offset;
                    using (var reader = new StreamReader(fs, Encoding.UTF8, true, 4096, true))
                    {
                        string line; while ((line = reader.ReadLine()) != null)
                        {
                            if (string.IsNullOrWhiteSpace(line)) continue;
                            try { var e = json.Deserialize<OperatorEvent>(line); if (e != null) bus.Publish(e); }
                            catch (Exception ex) { bus.Publish(new OperatorEvent { Severity = OperatorSeverity.Warn, Category = "Bridge", Module = "OperatorBridge", EventType = "Warning", Message = "Rejected malformed backend event: " + ex.Message }); }
                        }
                    }
                    offset = fs.Length;
                }
            }
            catch (IOException) { }
        }
        public void Dispose() { if (watcher != null) watcher.Dispose(); watcher = null; }
    }
}
