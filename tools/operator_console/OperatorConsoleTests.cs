using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Web.Script.Serialization;

namespace WoW112.OperatorConsole
{
    internal static class OperatorConsoleTests
    {
        private static int failed;

        private static void Check(bool condition, string name)
        {
            if (!condition) { failed++; Console.Error.WriteLine("FAIL " + name); }
            else Console.WriteLine("PASS " + name);
        }

        public static int Main()
        {
            var root = Path.Combine(Path.GetTempPath(), "wow112-operator-tests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try
            {
                Serialization();
                Persistence(root);
                StateProjection();
                ParserDiagnostics();
                CommandSafety(root);
                Sanitization();
                Load();
            }
            finally { try { Directory.Delete(root, true); } catch { } }
            Console.WriteLine(failed == 0 ? "ALL OPERATOR CONSOLE TESTS PASS" : (failed + " TEST(S) FAILED"));
            return failed == 0 ? 0 : 1;
        }

        private static void Serialization()
        {
            var json = new JavaScriptSerializer();
            var source = new OperatorEvent { EventType = "WhisperReceived", SessionId = "s1", Character = "Smokinpole", Message = "hello", CorrelationId = "corr" };
            source.Metadata["player"] = "PlayerX";
            var clone = json.Deserialize<OperatorEvent>(json.Serialize(source));
            Check(clone.EventType == source.EventType && clone.SessionId == "s1" && clone.ConversationPlayer == "PlayerX", "event serialization roundtrip");
        }

        private static void Persistence(string root)
        {
            var dir = Path.Combine(root, "persistence");
            using (var store = new JsonlOperatorStore(dir, 1024 * 1024, 3))
            {
                store.Append(new OperatorEvent { TimestampUtc = DateTime.UtcNow.AddSeconds(-2), EventType = "SessionStarted", SessionId = "s1", Character = "A" });
                store.Append(new OperatorEvent { TimestampUtc = DateTime.UtcNow.AddSeconds(-1), EventType = "WhisperReceived", SessionId = "s1", Character = "A", Message = "one" });
            }
            using (var reopened = new JsonlOperatorStore(dir, 1024 * 1024, 3))
            {
                var loaded = reopened.Load(100);
                Check(loaded.Count == 2, "persistent history survives store reopen");
                Check(loaded.Count == 2 && loaded[0].TimestampUtc <= loaded[1].TimestampUtc, "event ordering on reopen");
            }
        }

        private static void StateProjection()
        {
            var state = new OperatorStateStore();
            state.Apply(new OperatorEvent { EventType = "SessionStarted", SessionId = "s1", Character = "A" });
            state.Apply(new OperatorEvent { EventType = "LoginSucceeded", SessionId = "s1", Character = "A" });
            state.Apply(new OperatorEvent { EventType = "WhisperReceived", SessionId = "s1", Character = "A" });
            state.Apply(new OperatorEvent { EventType = "WhisperParsed", SessionId = "s1", Character = "A" });
            state.Apply(new OperatorEvent { EventType = "MutationCoordinatorUncertain", SessionId = "s1", Character = "A" });
            state.Apply(new OperatorEvent { EventType = "MutationCoordinatorReleased", SessionId = "s1", Character = "A" });
            var s = state.Sessions().Single();
            var c = state.Counters();
            Check(s.Connected && s.Coordinator == OperatorStatus.Uncertain, "state projector preserves UNCERTAIN hard-stop visibility");
            Check(c.Total == 1 && c.Understood == 1, "whisper counters projection");
        }

        private static void ParserDiagnostics()
        {
            var state = new OperatorStateStore();
            var e = new OperatorEvent { EventType = "WhisperReceived", SessionId = "s1", EventId = "evt-parser" };
            e.Metadata["parser"] = new Dictionary<string, object> {
                { "sender", "PlayerX" }, { "raw", "invi hyjal" }, { "normalized", "invi hyjal" },
                { "result", "unhandled" }, { "destination", "Hyjal" }, { "intent", "unknown" }, { "keywords", "hyjal" },
                { "matched_rule", "" }, { "ignore_reason", "" }, { "reason", "no request verb" }, { "confidence", 0.25 },
                { "competition", false }, { "summon_request", false }
            };
            state.Apply(e);
            var p = state.ParserFor("evt-parser");
            Check(p != null && p.RawText == "invi hyjal" && p.Destination == "Hyjal" && !p.SummonRequest, "parser diagnostic mapping without semantic rewrite");
        }

        private static void CommandSafety(string root)
        {
            var bus = new OperatorEventBus();
            var dir = Path.Combine(root, "bridge");
            using (var bridge = new FileOperatorBridge(dir, bus))
            {
                bridge.Submit(new OperatorCommand { CommandType = OperatorCommandType.ReplyToWhisper, SessionId = "s1", Player = "PlayerX", Text = "hello" });
                var line = File.ReadAllText(Path.Combine(dir, "operator-commands.jsonl")).Trim();
                var decoded = new JavaScriptSerializer().Deserialize<OperatorCommand>(line);
                Check(decoded != null && decoded.CommandType == OperatorCommandType.ReplyToWhisper && decoded.Player == "PlayerX" && decoded.SessionId == "s1" && decoded.Text == "hello", "manual whisper typed command routing");
            }
            var forbidden = Enum.GetNames(typeof(OperatorCommandType)).Any(x =>
                x.IndexOf("Buy", StringComparison.OrdinalIgnoreCase) >= 0 ||
                x.IndexOf("Mail", StringComparison.OrdinalIgnoreCase) >= 0 ||
                x.IndexOf("Cancel", StringComparison.OrdinalIgnoreCase) >= 0 ||
                x.IndexOf("Post", StringComparison.OrdinalIgnoreCase) >= 0);
            Check(!forbidden, "operator command surface contains no economic mutation bypass");
        }

        private static void Sanitization()
        {
            var s = SecretSanitizer.Sanitize("password=hunter2 token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456 bearer abc.def.ghi");
            Check(!s.Contains("hunter2") && !s.Contains("ghp_") && !s.Contains("abc.def.ghi"), "secret sanitizer strips password/token/bearer values");
            var m = SecretSanitizer.SanitizeMetadata(new Dictionary<string, object> { { "password", "secret" }, { "message", "ok" } });
            Check(Convert.ToString(m["password"]) == "[REDACTED]" && Convert.ToString(m["message"]) == "ok", "metadata key sanitization");
        }

        private static void Load()
        {
            var state = new OperatorStateStore();
            var sw = Stopwatch.StartNew();
            for (int i = 0; i < 50000; i++)
                state.Apply(new OperatorEvent { TimestampUtc = DateTime.UtcNow.AddMilliseconds(i), EventType = i % 5 == 0 ? "AHScanStarted" : "Debug", SessionId = "load-" + (i % 8), Character = "Char" + (i % 8), Severity = OperatorSeverity.Info });
            for (int i = 0; i < 10000; i++)
                state.Apply(new OperatorEvent { EventType = "WhisperReceived", SessionId = "load-0", Character = "Char0" });
            sw.Stop();
            Check(state.Sessions().Count == 8, "50k event multi-session projection");
            Check(state.Counters().Total == 10000, "10k whisper projection");
            Check(sw.Elapsed < TimeSpan.FromSeconds(15), "core performance sanity under 50k events + 10k whispers (" + sw.ElapsedMilliseconds + " ms)");
        }
    }
}
