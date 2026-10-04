using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace WoW112Updater
{
    internal static partial class AhEvidenceV2Feature
    {
        private sealed class Snapshot
        {
            public string Path, Id, Key, Reason;
            public long WriteTicks, Scans, Pages, Records, Decisions, Errors, Mismatches;
            public bool Valid;
        }

        private sealed class BaseSource
        {
            public string path, id, key;
            public long write_ticks, scans, pages, records, decisions;
        }

        private sealed class Baseline
        {
            public string head_sha, captured_utc;
            public List<BaseSource> sources;
        }

        private sealed class Pair
        {
            public BaseSource Before;
            public Snapshot After;
            public bool Changed;
        }

        private static bool Changed(BaseSource before, Snapshot after)
        {
            return after == null || after.WriteTicks != before.write_ticks || after.Scans != before.scans ||
                after.Pages != before.pages || after.Records != before.records || after.Decisions != before.decisions ||
                !string.Equals(after.Key ?? "", before.key ?? "", StringComparison.Ordinal);
        }

        private static List<Snapshot> All(string root)
        {
            var result = new List<Snapshot>();
            var dir = Path.Combine(root, "WTF", "Account");
            if (!Directory.Exists(dir)) return result;
            foreach (var path in Directory.GetFiles(dir, "AuxVmangos.lua", SearchOption.AllDirectories))
                result.Add(Read(root, path));
            return result;
        }

        private static Snapshot Read(string root, string path)
        {
            var item = new Snapshot { Path = path, Id = SourceId(root, path), Valid = false };
            try
            {
                if (!File.Exists(path)) { item.Reason = "missing"; return item; }
                item.WriteTicks = File.GetLastWriteTimeUtc(path).Ticks;
                var text = File.ReadAllText(path, Encoding.UTF8);
                var meta = Table(text, "marketMeta");
                var parity = Table(meta, "shadowParity");
                var evidence = Table(meta, "shadowParityEvidence");
                if (string.IsNullOrWhiteSpace(parity) || string.IsNullOrWhiteSpace(evidence))
                { item.Reason = "missing-parity-evidence"; return item; }
                item.Key = LuaString(evidence, "compatibilityKey");
                item.Scans = LuaLong(evidence, "scans");
                item.Pages = LuaLong(evidence, "pages");
                item.Records = LuaLong(evidence, "records");
                item.Errors = LuaLong(evidence, "observerErrors");
                item.Decisions = LuaLong(parity, "decisionCompared");
                item.Mismatches = LuaLong(parity, "evidenceMismatches");
                if (string.IsNullOrWhiteSpace(item.Key)) { item.Reason = "missing-compatibility-key"; return item; }
                item.Valid = true; item.Reason = ""; return item;
            }
            catch (Exception ex) { item.Reason = ex.GetType().Name + ":" + ex.Message; return item; }
        }

        private static long LuaLong(string table, string key)
        {
            if (string.IsNullOrEmpty(table)) return 0;
            var m = Regex.Match(table, "\\[\\\"" + Regex.Escape(key) + "\\\"\\]\\s*=\\s*(-?[0-9]+)");
            long value;
            return m.Success && long.TryParse(m.Groups[1].Value, out value) ? value : 0;
        }

        private static string LuaString(string table, string key)
        {
            if (string.IsNullOrEmpty(table)) return "";
            var marker = "[\"" + key + "\"]";
            var at = table.IndexOf(marker, StringComparison.Ordinal); if (at < 0) return "";
            var eq = table.IndexOf('=', at + marker.Length); if (eq < 0) return "";
            var quote = table.IndexOf('"', eq + 1); if (quote < 0) return "";
            var result = new StringBuilder(); var escaped = false;
            for (var i = quote + 1; i < table.Length; i++)
            {
                var c = table[i];
                if (escaped) { result.Append(c == 'n' ? '\n' : c); escaped = false; continue; }
                if (c == '\\') { escaped = true; continue; }
                if (c == '"') return result.ToString();
                result.Append(c);
            }
            return "";
        }

        private static string Table(string text, string key)
        {
            if (string.IsNullOrEmpty(text)) return null;
            var marker = "[\"" + key + "\"]";
            var at = text.IndexOf(marker, StringComparison.Ordinal); if (at < 0) return null;
            var eq = text.IndexOf('=', at + marker.Length);
            var open = eq < 0 ? -1 : text.IndexOf('{', eq + 1); if (open < 0) return null;
            var depth = 0; var quoted = false; var escaped = false;
            for (var i = open; i < text.Length; i++)
            {
                var c = text[i];
                if (quoted)
                {
                    if (escaped) { escaped = false; continue; }
                    if (c == '\\') { escaped = true; continue; }
                    if (c == '"') quoted = false;
                    continue;
                }
                if (c == '"') { quoted = true; continue; }
                if (c == '{') depth++;
                else if (c == '}' && --depth == 0) return text.Substring(open, i - open + 1);
            }
            return null;
        }

        private static string SourceId(string root, string path)
        {
            try
            {
                var prefix = Path.GetFullPath(root).TrimEnd('\\', '/') + Path.DirectorySeparatorChar;
                var full = Path.GetFullPath(path);
                var relative = full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) ? full.Substring(prefix.Length) : full;
                relative = relative.Replace('\\', '/').ToLowerInvariant();
                using (var sha = SHA256.Create())
                {
                    var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(relative));
                    return string.Concat(hash.Take(8).Select(x => x.ToString("x2")));
                }
            }
            catch { return "unknown"; }
        }
    }
}
