using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace System.Runtime.CompilerServices
{
    [AttributeUsage(AttributeTargets.Method, Inherited = false)]
    internal sealed class ModuleInitializerAttribute : Attribute { }
}

namespace WoW112Updater
{
    // Kept in a standalone compilation unit on purpose. The updater has several
    // independently developed UI features, so this avoids sharing their hot files.
    internal static class SummonScoutUnknownReportBootstrap
    {
        private static bool attached;

        [System.Runtime.CompilerServices.ModuleInitializer]
        internal static void Initialize()
        {
            System.Windows.Forms.Application.Idle += OnIdle;
        }

        private static void OnIdle(object sender, EventArgs e)
        {
            if (attached) return;
            Form target = null;
            foreach (Form form in System.Windows.Forms.Application.OpenForms)
            {
                if (form is MainForm)
                {
                    target = form;
                    break;
                }
            }
            if (target == null) return;

            attached = true;
            System.Windows.Forms.Application.Idle -= OnIdle;
            SummonScoutUnknownReportFeature.Attach(target);
        }
    }

    // Publishes only SummonScout's bounded unknown-whisper SavedVariables table.
    // The existing DPAPI-protected report token is reused; account paths,
    // credentials and unrelated SavedVariables are never uploaded.
    internal static class SummonScoutUnknownReportFeature
    {
        public static void Attach(Form form)
        {
            if (form == null) return;
            new Controller(form).Attach();
        }

        private sealed class Controller
        {
            private const string Owner = "github12wykrzyk";
            private const string Repo = "wow112";
            private const string ApiRoot = "https://api.github.com/repos/" + Owner + "/" + Repo;
            private const string SearchApiRoot = "https://api.github.com/search/issues";
            private const int PollMs = 60000;
            private const int IssueBodySafeChars = 58000;
            private const int CommentChunkChars = 45000;
            private readonly Form form;
            private readonly TextBox gameDir;
            private readonly RichTextBox log;
            private readonly Timer timer = new Timer();
            private readonly JavaScriptSerializer json = new JavaScriptSerializer();
            private bool busy;

            public Controller(Form form)
            {
                this.form = form;
                gameDir = GetPrivateField<TextBox>(form, "gameDir");
                log = GetPrivateField<RichTextBox>(form, "log");
                timer.Interval = PollMs;
                json.MaxJsonLength = 32 * 1024 * 1024;
                json.RecursionLimit = 128;
            }

            public void Attach()
            {
                if (gameDir == null) return;
                timer.Tick += async delegate { await SyncAsync(); };
                form.FormClosed += delegate
                {
                    timer.Stop();
                    timer.Dispose();
                };
                timer.Start();
                Log("SUMMON UNKNOWN telemetry: ON — raportuje nierozpoznane whispery po zapisie SavedVariables.");
            }

            private async Task SyncAsync()
            {
                if (busy || form.IsDisposed) return;
                var token = LoadReportToken();
                if (string.IsNullOrWhiteSpace(token)) return;

                var root = gameDir.Text.Trim();
                if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root)) return;
                root = Path.GetFullPath(root);

                var snapshots = BuildSnapshots(root);
                if (snapshots.Count == 0) return;

                var canonical = new StringBuilder();
                foreach (var snapshot in snapshots)
                {
                    canonical.AppendLine(snapshot.Table);
                    canonical.AppendLine("---");
                }
                var fullHash = Sha256Text(canonical.ToString());
                if (string.Equals(ReadStateHash(), fullHash, StringComparison.OrdinalIgnoreCase)) return;

                busy = true;
                try
                {
                    string headSha;
                    long runId;
                    ReadInstalled(root, out headSha, out runId);
                    var marker = "[ssunknown:" + fullHash.Substring(0, 12) + "]";

                    using (var client = CreateClient(token))
                    {
                        var existing = await FindExistingIssueAsync(client, marker);
                        if (existing > 0)
                        {
                            WriteStateHash(fullHash);
                            Log("SUMMON UNKNOWN: zsynchronizowany z istniejącym Issue #" + existing + ".");
                            return;
                        }

                        var report = BuildReport(headSha, runId, marker, fullHash, snapshots);
                        var body = report;
                        var chunks = 0;
                        if (report.Length > IssueBodySafeChars)
                        {
                            chunks = Math.Max(1, (report.Length + CommentChunkChars - 1) / CommentChunkChars);
                            body = "## SummonScout unknown whisper report\n\n" +
                                "Pełny raport jest w " + chunks + " komentarzach poniżej.\n\n" +
                                "Head SHA: `" + headSha + "`\n\n" +
                                "Run ID: " + runId + "\n\n" +
                                "Payload SHA256: `" + fullHash + "`\n\n" + marker;
                        }

                        var title = "[SUMMON-UNKNOWN] " + ShortSha(headSha) + " " +
                            DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm") + "Z " + marker;
                        var issueNumber = await CreateIssueAsync(client, title, body);

                        if (chunks > 0)
                        {
                            for (var i = 0; i < chunks; i++)
                            {
                                var start = i * CommentChunkChars;
                                var count = Math.Min(CommentChunkChars, report.Length - start);
                                await CreateCommentAsync(client, issueNumber,
                                    "## Summon unknown chunk " + (i + 1) + "/" + chunks + "\n\n" +
                                    report.Substring(start, count));
                                if (i + 1 < chunks) await Task.Delay(100);
                            }
                        }

                        WriteStateHash(fullHash);
                        Log("SUMMON UNKNOWN -> GitHub Issue #" + issueNumber + ".");
                    }
                }
                catch (Exception ex)
                {
                    Log("SUMMON UNKNOWN błąd: " + ex.Message);
                }
                finally
                {
                    busy = false;
                }
            }

            private List<Snapshot> BuildSnapshots(string root)
            {
                var result = new List<Snapshot>();
                var accountRoot = Path.Combine(root, "WTF", "Account");
                if (!Directory.Exists(accountRoot)) return result;

                string[] files;
                try
                {
                    files = Directory.GetFiles(accountRoot, "SummonScout.lua", SearchOption.AllDirectories)
                        .Where(p => p.IndexOf(Path.DirectorySeparatorChar + "SavedVariables" + Path.DirectorySeparatorChar,
                            StringComparison.OrdinalIgnoreCase) >= 0)
                        .OrderBy(p => p, StringComparer.OrdinalIgnoreCase)
                        .ToArray();
                }
                catch
                {
                    return result;
                }

                foreach (var file in files)
                {
                    try
                    {
                        var text = File.ReadAllText(file, Encoding.UTF8);
                        var table = ExtractLuaTableField(text, "unknownWhisperReport");
                        if (string.IsNullOrWhiteSpace(table)) continue;
                        var seqMatches = Regex.Matches(table, "\\[\\\"seq\\\"\\]\\s*=\\s*(\\d+)");
                        long maxSeq = 0;
                        foreach (Match seqMatch in seqMatches)
                        {
                            long seq;
                            if (long.TryParse(seqMatch.Groups[1].Value, out seq) && seq > maxSeq) maxSeq = seq;
                        }
                        if (maxSeq <= 0) continue;
                        result.Add(new Snapshot
                        {
                            SavedUtc = File.GetLastWriteTimeUtc(file),
                            Table = table,
                            MaxSeq = maxSeq
                        });
                    }
                    catch
                    {
                    }
                }
                return result;
            }

            private static string BuildReport(string headSha, long runId, string marker, string hash, List<Snapshot> snapshots)
            {
                var sb = new StringBuilder();
                sb.AppendLine("## SummonScout unknown whisper report");
                sb.AppendLine();
                sb.AppendLine("Head SHA: `" + headSha + "`");
                sb.AppendLine("Run ID: " + runId);
                sb.AppendLine("Payload SHA256: `" + hash + "`");
                sb.AppendLine("SavedVariables snapshots: " + snapshots.Count);
                sb.AppendLine();
                sb.AppendLine("Contains only `SummonScoutDB.unknownWhisperReport`: raw/normalized whisper, parser context, service and module versions. No account path, credentials or unrelated SavedVariables are uploaded.");
                sb.AppendLine("WoW 1.12 writes SavedVariables on `/reload`, logout or client exit, so the report appears after the next flush.");
                sb.AppendLine();

                for (var i = 0; i < snapshots.Count; i++)
                {
                    var snapshot = snapshots[i];
                    sb.AppendLine("### Snapshot " + (i + 1));
                    sb.AppendLine("Saved UTC: " + snapshot.SavedUtc.ToString("o"));
                    sb.AppendLine("Max seq: " + snapshot.MaxSeq);
                    sb.AppendLine("```lua");
                    sb.AppendLine(EscapeFence(snapshot.Table));
                    sb.AppendLine("```");
                    sb.AppendLine();
                }
                sb.AppendLine(marker);
                return sb.ToString();
            }

            private async Task<long> CreateIssueAsync(HttpClient client, string title, string body)
            {
                var payload = new Dictionary<string, object>();
                payload["title"] = title;
                payload["body"] = body;
                using (var request = new HttpRequestMessage(HttpMethod.Post, ApiRoot + "/issues"))
                {
                    request.Content = new StringContent(json.Serialize(payload), Encoding.UTF8, "application/json");
                    using (var response = await client.SendAsync(request))
                    {
                        var text = await response.Content.ReadAsStringAsync();
                        if (!response.IsSuccessStatusCode)
                            throw new InvalidOperationException("GitHub Issue API " + (int)response.StatusCode + ": " + Tail(text, 500));
                        var obj = json.DeserializeObject(text) as Dictionary<string, object>;
                        if (obj == null || !obj.ContainsKey("number")) throw new InvalidOperationException("GitHub Issue API: brak numeru Issue.");
                        return Convert.ToInt64(obj["number"]);
                    }
                }
            }

            private async Task CreateCommentAsync(HttpClient client, long issueNumber, string body)
            {
                var payload = new Dictionary<string, object>();
                payload["body"] = body;
                using (var request = new HttpRequestMessage(HttpMethod.Post, ApiRoot + "/issues/" + issueNumber + "/comments"))
                {
                    request.Content = new StringContent(json.Serialize(payload), Encoding.UTF8, "application/json");
                    using (var response = await client.SendAsync(request))
                    {
                        var text = await response.Content.ReadAsStringAsync();
                        if (!response.IsSuccessStatusCode)
                            throw new InvalidOperationException("GitHub comment API " + (int)response.StatusCode + ": " + Tail(text, 500));
                    }
                }
            }

            private async Task<long> FindExistingIssueAsync(HttpClient client, string marker)
            {
                try
                {
                    var q = "repo:" + Owner + "/" + Repo + " \"" + marker + "\" in:body";
                    using (var response = await client.GetAsync(SearchApiRoot + "?q=" + Uri.EscapeDataString(q) + "&per_page=1"))
                    {
                        if (!response.IsSuccessStatusCode) return 0;
                        var text = await response.Content.ReadAsStringAsync();
                        var root = json.DeserializeObject(text) as Dictionary<string, object>;
                        if (root == null || !root.ContainsKey("items")) return 0;
                        var items = root["items"] as object[];
                        if (items == null || items.Length == 0) return 0;
                        var first = items[0] as Dictionary<string, object>;
                        if (first == null || !first.ContainsKey("number")) return 0;
                        return Convert.ToInt64(first["number"]);
                    }
                }
                catch
                {
                    return 0;
                }
            }

            private static HttpClient CreateClient(string token)
            {
                var client = new HttpClient();
                client.DefaultRequestHeaders.UserAgent.ParseAdd("WoW112ParallelUpdater/" + UpdaterBuildInfo.Version);
                client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
                client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Trim());
                client.DefaultRequestHeaders.Add("X-GitHub-Api-Version", "2022-11-28");
                return client;
            }

            private static string ExtractLuaTableField(string text, string field)
            {
                if (string.IsNullOrEmpty(text) || string.IsNullOrEmpty(field)) return null;
                var marker = "[\"" + field + "\"]";
                var fieldAt = text.IndexOf(marker, StringComparison.Ordinal);
                if (fieldAt < 0) fieldAt = text.IndexOf(field, StringComparison.Ordinal);
                if (fieldAt < 0) return null;
                var equalsAt = text.IndexOf('=', fieldAt);
                if (equalsAt < 0) return null;
                var open = text.IndexOf('{', equalsAt);
                if (open < 0) return null;

                var depth = 0;
                var inString = false;
                var escaped = false;
                for (var i = open; i < text.Length; i++)
                {
                    var ch = text[i];
                    if (inString)
                    {
                        if (escaped) escaped = false;
                        else if (ch == '\\') escaped = true;
                        else if (ch == '"') inString = false;
                        continue;
                    }
                    if (ch == '"')
                    {
                        inString = true;
                        continue;
                    }
                    if (ch == '{') depth++;
                    else if (ch == '}')
                    {
                        depth--;
                        if (depth == 0) return text.Substring(fieldAt, i - fieldAt + 1);
                    }
                }
                return null;
            }

            private static void ReadInstalled(string root, out string headSha, out long runId)
            {
                headSha = string.Empty;
                runId = 0;
                try
                {
                    var path = Path.Combine(root, ".wow112_parallel_updater", "installed.json");
                    if (!File.Exists(path)) return;
                    var text = File.ReadAllText(path, Encoding.UTF8);
                    var sha = Regex.Match(text, "\\\"head_sha\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"");
                    if (sha.Success) headSha = sha.Groups[1].Value;
                    var run = Regex.Match(text, "\\\"run_id\\\"\\s*:\\s*(\\d+)");
                    if (run.Success) long.TryParse(run.Groups[1].Value, out runId);
                }
                catch
                {
                }
            }

            private static string ReportTokenPath()
            {
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "WoW112ParallelUpdater", "report_token.dpapi");
            }

            private static byte[] ReportEntropy()
            {
                return Encoding.UTF8.GetBytes("WoW112ParallelUpdater-report-token-v1");
            }

            private static string LoadReportToken()
            {
                try
                {
                    var path = ReportTokenPath();
                    if (!File.Exists(path)) return string.Empty;
                    var protectedBytes = Convert.FromBase64String(File.ReadAllText(path, Encoding.ASCII));
                    return Encoding.UTF8.GetString(ProtectedData.Unprotect(protectedBytes, ReportEntropy(), DataProtectionScope.CurrentUser));
                }
                catch
                {
                    return string.Empty;
                }
            }

            private static string StatePath()
            {
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "WoW112ParallelUpdater", "summonscout_unknown.sha256");
            }

            private static string ReadStateHash()
            {
                try { return File.Exists(StatePath()) ? File.ReadAllText(StatePath(), Encoding.ASCII).Trim() : string.Empty; }
                catch { return string.Empty; }
            }

            private static void WriteStateHash(string value)
            {
                var path = StatePath();
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.WriteAllText(path, value ?? string.Empty, Encoding.ASCII);
            }

            private static string Sha256Text(string value)
            {
                using (var sha = SHA256.Create())
                {
                    var bytes = sha.ComputeHash(Encoding.UTF8.GetBytes(value ?? string.Empty));
                    var sb = new StringBuilder(bytes.Length * 2);
                    foreach (var b in bytes) sb.Append(b.ToString("x2"));
                    return sb.ToString();
                }
            }

            private static string ShortSha(string sha)
            {
                if (string.IsNullOrWhiteSpace(sha)) return "unknown";
                return sha.Length <= 8 ? sha : sha.Substring(0, 8);
            }

            private static string EscapeFence(string text)
            {
                return (text ?? string.Empty).Replace("```", "``\\`");
            }

            private static string Tail(string text, int max)
            {
                if (string.IsNullOrEmpty(text) || text.Length <= max) return text ?? string.Empty;
                return text.Substring(text.Length - max);
            }

            private void Log(string message)
            {
                if (log == null) return;
                log.AppendText("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + message + Environment.NewLine);
                log.SelectionStart = log.TextLength;
                log.ScrollToCaret();
            }

            private static T GetPrivateField<T>(object instance, string name) where T : class
            {
                var field = instance.GetType().GetField(name, System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
                return field == null ? null : field.GetValue(instance) as T;
            }

            private sealed class Snapshot
            {
                public DateTime SavedUtc;
                public string Table;
                public long MaxSeq;
            }
        }
    }
}
