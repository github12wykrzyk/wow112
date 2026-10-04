using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace WoW112Updater
{
    // Local wrapper intentionally shadows System.Windows.Forms.Application for
    // Program.Main. It lets optional updater UI features attach after MainForm
    // has finished constructing without rewriting the main updater source.
    internal static class Application
    {
        public static void EnableVisualStyles()
        {
            System.Windows.Forms.Application.EnableVisualStyles();
        }

        public static void SetCompatibleTextRenderingDefault(bool defaultValue)
        {
            System.Windows.Forms.Application.SetCompatibleTextRenderingDefault(defaultValue);
        }

        public static void Run(Form mainForm)
        {
            RealmlistFeature.Attach(mainForm);
            MaintenanceFeature.Attach(mainForm);
            IssueReportFeature.Attach(mainForm);
            SummonScoutUnknownReportFeature.Attach(mainForm);
            ((MainForm)mainForm).AttachAccounts();
            ((MainForm)mainForm).BuildDashboard();
            var args = Environment.GetCommandLineArgs();
            if (args.Length == 3 && args[1] == "--ui-smoke")
            {
                try { ((MainForm)mainForm).CaptureUiSmoke(args[2]); }
                catch (Exception ex) { System.IO.Directory.CreateDirectory(args[2]); System.IO.File.WriteAllText(System.IO.Path.Combine(args[2], "failure.txt"), ex.ToString()); Environment.ExitCode = 1; }
                finally { mainForm.Dispose(); }
                return;
            }
            System.Windows.Forms.Application.Run(mainForm);
        }
    }

    internal static class RealmlistFeature
    {
        private const int AddedHeight = 58;

        public static void Attach(Form form)
        {
            if (form == null) return;
            var feature = new RealmlistController(form);
            feature.Attach();
        }

        private sealed class RealmlistController
        {
            private readonly Form form;
            private readonly TextBox gameDir;
            private readonly RichTextBox log;
            private readonly ComboBox selector = new ComboBox();
            private readonly Button applyButton = new Button();
            private readonly RealmlistPreset octo = new RealmlistPreset("OctoWoW", "play.octowow.st");
            private readonly RealmlistPreset raven = new RealmlistPreset("RavenCraft", "logon.ravencraft.io");
            private bool attached;

            public RealmlistController(Form form)
            {
                this.form = form;
                gameDir = GetPrivateField<TextBox>(form, "gameDir");
                log = GetPrivateField<RichTextBox>(form, "log");
            }

            public void Attach()
            {
                if (attached || gameDir == null) return;
                attached = true;

                selector.DropDownStyle = ComboBoxStyle.DropDownList;
                applyButton.Click += delegate { ApplySelected(); };
                var host = (IUpdaterHost)form;
                host.RegisterUiControl("realm", selector);
                host.RegisterUiControl("realmApply", applyButton);

                gameDir.TextChanged += delegate { RefreshSelection(); };
                RefreshSelection();
            }

            private void RefreshSelection()
            {
                selector.Items.Clear();
                selector.Items.Add(octo);
                selector.Items.Add(raven);

                var host = ReadCurrentHost();
                RealmlistPreset selected = null;
                if (string.Equals(host, octo.Host, StringComparison.OrdinalIgnoreCase)) selected = octo;
                if (string.Equals(host, raven.Host, StringComparison.OrdinalIgnoreCase)) selected = raven;

                if (selected != null)
                {
                    selector.SelectedItem = selected;
                }
                else if (!string.IsNullOrWhiteSpace(host))
                {
                    var custom = new RealmlistPreset("Aktualny (niestandardowy)", host);
                    selector.Items.Add(custom);
                    selector.SelectedItem = custom;
                }
                else
                {
                    selector.SelectedIndex = -1;
                }

                applyButton.Enabled = Directory.Exists(gameDir.Text.Trim()) && selector.SelectedItem != null;
            }

            private void ApplySelected()
            {
                try
                {
                    var preset = selector.SelectedItem as RealmlistPreset;
                    var root = gameDir.Text.Trim();
                    if (preset == null) throw new InvalidOperationException("Wybierz realmlist z listy.");
                    if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
                        throw new InvalidOperationException("Wybierz istniejący katalog gry.");

                    var path = Path.Combine(root, "realmlist.wtf");
                    var desired = "SET realmList \"" + preset.Host + "\"";
                    var lines = File.Exists(path)
                        ? new List<string>(File.ReadAllLines(path))
                        : new List<string>();

                    var replaced = false;
                    for (var i = 0; i < lines.Count; i++)
                    {
                        if (!IsRealmlistDirective(lines[i])) continue;
                        lines[i] = desired;
                        replaced = true;
                        break;
                    }
                    if (!replaced) lines.Insert(0, desired);

                    File.WriteAllLines(path, lines.ToArray(), new UTF8Encoding(false));
                    Log("Realmlist ustawiony: " + desired);
                    RefreshSelection();
                }
                catch (Exception ex)
                {
                    Log("BŁĄD realmlist: " + ex.Message);
                    MessageBox.Show(form, ex.Message, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }

            private string ReadCurrentHost()
            {
                try
                {
                    var root = gameDir.Text.Trim();
                    if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root)) return string.Empty;
                    var path = Path.Combine(root, "realmlist.wtf");
                    if (!File.Exists(path)) return string.Empty;

                    foreach (var line in File.ReadAllLines(path))
                    {
                        if (!IsRealmlistDirective(line)) continue;
                        var text = line.Trim();
                        var first = text.IndexOf('"');
                        if (first >= 0)
                        {
                            var second = text.IndexOf('"', first + 1);
                            if (second > first + 1) return text.Substring(first + 1, second - first - 1).Trim();
                        }

                        const string prefix = "set realmlist";
                        if (text.Length > prefix.Length)
                            return text.Substring(prefix.Length).Trim().Trim('"');
                    }
                }
                catch
                {
                }
                return string.Empty;
            }

            private static bool IsRealmlistDirective(string line)
            {
                if (line == null) return false;
                var text = line.TrimStart();
                const string prefix = "set realmlist";
                if (!text.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return false;
                return text.Length == prefix.Length || char.IsWhiteSpace(text[prefix.Length]);
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
                var field = instance.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic);
                return field == null ? null : field.GetValue(instance) as T;
            }
        }

        private sealed class RealmlistPreset
        {
            public readonly string Name;
            public readonly string Host;

            public RealmlistPreset(string name, string host)
            {
                Name = name;
                Host = host;
            }

            public override string ToString()
            {
                return Name + " — " + Host;
            }
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
                Log("SUMMON UNKNOWN telemetry: ON — publikuje tylko nierozpoznane whispery po zapisie SavedVariables.");
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
                        var seqMatch = Regex.Match(table, "\\[\\\"seq\\\"\\]\\s*=\\s*(\\d+)");
                        long seq;
                        if (!seqMatch.Success || !long.TryParse(seqMatch.Groups[1].Value, out seq) || seq <= 0) continue;
                        result.Add(new Snapshot
                        {
                            SavedUtc = File.GetLastWriteTimeUtc(file),
                            Table = table,
                            Seq = seq
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
                sb.AppendLine("Contains only `SummonScoutDB.unknownWhisperReport`: sender, raw whisper, normalized whisper, parser context, active service and module versions. No account path, credentials or unrelated SavedVariables are uploaded.");
                sb.AppendLine("WoW 1.12 writes SavedVariables on `/reload`, logout or client exit, so the report appears after the next flush.");
                sb.AppendLine();

                for (var i = 0; i < snapshots.Count; i++)
                {
                    var snapshot = snapshots[i];
                    sb.AppendLine("### Snapshot " + (i + 1));
                    sb.AppendLine("Saved UTC: " + snapshot.SavedUtc.ToString("o"));
                    sb.AppendLine("Max seq: " + snapshot.Seq);
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
                var field = instance.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic);
                return field == null ? null : field.GetValue(instance) as T;
            }

            private sealed class Snapshot
            {
                public DateTime SavedUtc;
                public string Table;
                public long Seq;
            }
        }
    }
}
