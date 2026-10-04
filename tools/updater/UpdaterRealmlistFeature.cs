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
            AhEvidenceGateFeature.Attach(mainForm);
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

    internal static class AhEvidenceGateFeature
    {
        private const string ApiRoot = "https://api.github.com/repos/github12wykrzyk/wow112";
        private const string BaselineFileName = "ah_evidence_baseline.json";
        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();

        private sealed class Snapshot
        {
            public string Path;
            public string SourceId;
            public string CompatibilityKey;
            public long LastScanAt;
            public long Items;
            public long Auctions;
            public long PackedRows;
            public long Scans;
            public long Pages;
            public long Records;
            public long DecisionCompared;
            public long ObserverErrors;
            public long Mismatches;
            public string Reason;
            public bool Valid;
        }

        private sealed class Baseline
        {
            public string head_sha;
            public string source_path;
            public string source_id;
            public string compatibility_key;
            public long scans;
            public long pages;
            public long records;
            public long decision_compared;
            public string captured_utc;
        }

        public static void Attach(Form form)
        {
            if (form == null) return;
            var host = form as IUpdaterHost;
            if (host == null) return;

            var button = new Button
            {
                Text = "AH EVIDENCE",
                Width = 142,
                Height = 30,
                Anchor = AnchorStyles.Right | AnchorStyles.Bottom,
                FlatStyle = FlatStyle.Flat,
                UseVisualStyleBackColor = false,
                BackColor = Color.FromArgb(50, 58, 75),
                ForeColor = Color.White
            };
            button.FlatAppearance.BorderColor = Color.FromArgb(223, 182, 115);
            button.Click += async delegate { await HandleClickAsync(host, button); };

            form.Shown += delegate
            {
                if (button.Parent != null) return;
                button.Left = Math.Max(8, form.ClientSize.Width - button.Width - 18);
                button.Top = Math.Max(8, form.ClientSize.Height - button.Height - 18);
                form.Controls.Add(button);
                button.BringToFront();
                RefreshButton(host, button);
            };
            form.Resize += delegate
            {
                if (button.Parent == null) return;
                button.Left = Math.Max(8, form.ClientSize.Width - button.Width - 18);
                button.Top = Math.Max(8, form.ClientSize.Height - button.Height - 18);
                button.BringToFront();
            };
        }

        private static async Task HandleClickAsync(IUpdaterHost host, Button button)
        {
            if (button == null || button.IsDisposed) return;
            button.Enabled = false;
            try
            {
                var root = (host.GameDirectory ?? string.Empty).Trim();
                if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
                    throw new InvalidOperationException("Wybierz istniejący katalog gry.");
                root = Path.GetFullPath(root);

                var baselinePath = BaselinePath(root);
                var head = ReadInstalledHead(root);
                Baseline baseline = null;
                if (File.Exists(baselinePath))
                {
                    try { baseline = Json.Deserialize<Baseline>(File.ReadAllText(baselinePath, Encoding.UTF8)); }
                    catch { baseline = null; }
                }

                if (baseline != null && !string.Equals(baseline.head_sha ?? string.Empty, head ?? string.Empty, StringComparison.OrdinalIgnoreCase))
                {
                    File.Delete(baselinePath);
                    baseline = null;
                    host.LogMessage("AH EVIDENCE: stary baseline odrzucony po zmianie installed HEAD.");
                }

                if (baseline == null)
                {
                    var selected = SelectSource(root);
                    if (selected == null || !selected.Valid)
                        throw new InvalidOperationException(selected == null ? "Brak jednoznacznego pełnego źródła AuxVmangos." : selected.Reason);

                    baseline = new Baseline
                    {
                        head_sha = head ?? string.Empty,
                        source_path = selected.Path,
                        source_id = selected.SourceId,
                        compatibility_key = selected.CompatibilityKey,
                        scans = selected.Scans,
                        pages = selected.Pages,
                        records = selected.Records,
                        decision_compared = selected.DecisionCompared,
                        captured_utc = DateTime.UtcNow.ToString("o")
                    };
                    Directory.CreateDirectory(Path.GetDirectoryName(baselinePath));
                    File.WriteAllText(baselinePath, Json.Serialize(baseline), new UTF8Encoding(false));
                    host.LogMessage("AH EVIDENCE BASELINE: source=" + selected.SourceId +
                        " scans=" + selected.Scans + " pages=" + selected.Pages +
                        " decisions=" + selected.DecisionCompared + ".");
                    MessageBox.Show(host.Window,
                        "Baseline zapisany.\n\nTeraz puść 2 pełne cykle LOOP, potem /reload i kliknij AH EVIDENCE ponownie.\n\n" +
                        "source_id: " + selected.SourceId + "\n" +
                        "scans: " + selected.Scans + "  pages: " + selected.Pages + "  decisions: " + selected.DecisionCompared,
                        "AH Evidence Gate", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                var current = ReadSnapshot(root, baseline.source_path);
                if (current == null)
                    current = new Snapshot { Path = baseline.source_path, SourceId = baseline.source_id, Valid = false, Reason = "Źródłowy AuxVmangos.lua z baseline nie istnieje." };

                var reasons = new List<string>();
                if (!current.Valid) reasons.Add("source-invalid:" + current.Reason);
                if (!string.Equals(current.SourceId ?? string.Empty, baseline.source_id ?? string.Empty, StringComparison.OrdinalIgnoreCase))
                    reasons.Add("source-id-changed");
                if (!string.Equals(current.CompatibilityKey ?? string.Empty, baseline.compatibility_key ?? string.Empty, StringComparison.Ordinal))
                    reasons.Add("compatibility-key-changed");
                if (current.Scans < baseline.scans + 2) reasons.Add("scans-delta<2");
                if (current.Pages <= baseline.pages) reasons.Add("pages-not-growing");
                if (current.Records <= baseline.records) reasons.Add("records-not-growing");
                if (current.DecisionCompared <= baseline.decision_compared) reasons.Add("decisionCompared-not-growing");
                if (current.ObserverErrors != 0) reasons.Add("observer-errors=" + current.ObserverErrors);
                if (current.Mismatches != 0) reasons.Add("mismatches=" + current.Mismatches);

                var verdict = reasons.Count == 0 ? "PASS" : "FAIL";
                var report = BuildReport(head, baseline, current, verdict, reasons);
                await UploadIssueAsync(host.GitHubToken, head, baseline.source_id, verdict, report);
                host.LogMessage("AH EVIDENCE " + verdict + ": source=" + baseline.source_id +
                    " scans " + baseline.scans + "->" + current.Scans +
                    ", decisions " + baseline.decision_compared + "->" + current.DecisionCompared + ".");

                File.Delete(baselinePath);
                MessageBox.Show(host.Window, report,
                    "AH Evidence Gate — " + verdict,
                    MessageBoxButtons.OK,
                    verdict == "PASS" ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
            }
            catch (Exception ex)
            {
                host.LogMessage("AH EVIDENCE błąd: " + ex.Message);
                MessageBox.Show(host.Window, ex.Message, "AH Evidence Gate", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                button.Enabled = true;
                RefreshButton(host, button);
            }
        }

        private static void RefreshButton(IUpdaterHost host, Button button)
        {
            try
            {
                var root = (host.GameDirectory ?? string.Empty).Trim();
                button.Text = Directory.Exists(root) && File.Exists(BaselinePath(root)) ? "AH EVIDENCE: CHECK" : "AH EVIDENCE";
            }
            catch { button.Text = "AH EVIDENCE"; }
        }

        private static string BaselinePath(string root)
        {
            return Path.Combine(root, ".wow112_parallel_updater", BaselineFileName);
        }

        private static string ReadInstalledHead(string root)
        {
            try
            {
                var path = Path.Combine(root, ".wow112_parallel_updater", "installed.json");
                if (!File.Exists(path)) return string.Empty;
                var text = File.ReadAllText(path, Encoding.UTF8);
                var match = Regex.Match(text, "\\\"head_sha\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"", RegexOptions.IgnoreCase);
                return match.Success ? match.Groups[1].Value : string.Empty;
            }
            catch { return string.Empty; }
        }

        private static Snapshot SelectSource(string root)
        {
            var accountRoot = Path.Combine(root, "WTF", "Account");
            if (!Directory.Exists(accountRoot))
                return new Snapshot { Valid = false, Reason = "Brak WTF/Account." };

            var rows = new List<Snapshot>();
            foreach (var path in Directory.GetFiles(accountRoot, "AuxVmangos.lua", SearchOption.AllDirectories))
            {
                var row = ReadSnapshot(root, path);
                if (row != null && row.Valid) rows.Add(row);
            }
            if (rows.Count == 0)
                return new Snapshot { Valid = false, Reason = "Nie znaleziono pełnego AuxVmangos snapshotu z marketem i parity evidence." };

            rows = rows.OrderByDescending(x => x.DecisionCompared)
                .ThenByDescending(x => x.Scans)
                .ThenByDescending(x => x.LastScanAt)
                .ThenByDescending(x => x.PackedRows)
                .ToList();

            if (rows.Count > 1)
            {
                var a = rows[0];
                var b = rows[1];
                if (a.DecisionCompared == b.DecisionCompared && a.Scans == b.Scans &&
                    a.LastScanAt == b.LastScanAt && a.PackedRows == b.PackedRows)
                {
                    return new Snapshot
                    {
                        Valid = false,
                        Reason = "Dwa źródła AH są równie wiarygodne; fail-closed zamiast zgadywania. source_id=" +
                            a.SourceId + " i " + b.SourceId
                    };
                }
            }
            return rows[0];
        }

        private static Snapshot ReadSnapshot(string root, string path)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) return null;
                var text = File.ReadAllText(path, Encoding.UTF8);
                var packed = ExtractLuaStringField(text, "marketPacked");
                var marketMeta = ExtractLuaTableField(text, "marketMeta");
                var row = new Snapshot
                {
                    Path = path,
                    SourceId = SourceId(root, path),
                    Valid = false
                };
                if (string.IsNullOrWhiteSpace(packed) || !packed.StartsWith("AVM3", StringComparison.Ordinal))
                {
                    row.Reason = "marketPacked nie jest AVM3.";
                    return row;
                }
                row.PackedRows = CountPackedRows(packed);
                if (row.PackedRows <= 0)
                {
                    row.Reason = "marketPacked zawiera tylko nagłówek AVM3.";
                    return row;
                }
                if (string.IsNullOrWhiteSpace(marketMeta))
                {
                    row.Reason = "Brak marketMeta.";
                    return row;
                }

                row.LastScanAt = LuaLong(marketMeta, "lastScanAt");
                row.Items = LuaLong(marketMeta, "items");
                row.Auctions = LuaLong(marketMeta, "auctions");
                if (row.LastScanAt <= 0 || row.Items <= 0 || row.Auctions <= 0)
                {
                    row.Reason = "Snapshot nie ma realnego pełnego marketu (lastScanAt/items/auctions).";
                    return row;
                }

                var parity = ExtractLuaTableField(marketMeta, "shadowParity");
                var evidence = ExtractLuaTableField(marketMeta, "shadowParityEvidence");
                if (string.IsNullOrWhiteSpace(parity) || string.IsNullOrWhiteSpace(evidence))
                {
                    row.Reason = "Brak shadowParity/shadowParityEvidence.";
                    return row;
                }

                row.CompatibilityKey = LuaString(evidence, "compatibilityKey");
                row.Scans = LuaLong(evidence, "scans");
                row.Pages = LuaLong(evidence, "pages");
                row.Records = LuaLong(evidence, "records");
                row.ObserverErrors = LuaLong(evidence, "observerErrors");
                row.DecisionCompared = LuaLong(parity, "decisionCompared");
                row.Mismatches = LuaLong(parity, "evidenceMismatches");
                if (string.IsNullOrWhiteSpace(row.CompatibilityKey))
                {
                    row.Reason = "Brak compatibilityKey.";
                    return row;
                }

                row.Valid = true;
                row.Reason = string.Empty;
                return row;
            }
            catch (Exception ex)
            {
                return new Snapshot { Path = path, SourceId = SourceId(root, path), Valid = false, Reason = ex.GetType().Name + ": " + ex.Message };
            }
        }

        private static long CountPackedRows(string packed)
        {
            if (string.IsNullOrEmpty(packed)) return 0;
            var lines = packed.Replace("\r", string.Empty).Split('\n');
            long count = 0;
            for (var i = 0; i < lines.Length; i++)
            {
                var line = lines[i].Trim();
                if (line.Length == 0 || line == "AVM3") continue;
                count++;
            }
            return count;
        }

        private static string SourceId(string root, string path)
        {
            try
            {
                var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
                var fullPath = Path.GetFullPath(path);
                var relative = fullPath.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase)
                    ? fullPath.Substring(fullRoot.Length)
                    : fullPath;
                relative = relative.Replace('\\', '/').ToLowerInvariant();
                using (var sha = SHA256.Create())
                {
                    var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(relative));
                    var sb = new StringBuilder();
                    for (var i = 0; i < 8; i++) sb.Append(hash[i].ToString("x2"));
                    return sb.ToString();
                }
            }
            catch { return "unknown"; }
        }

        private static long LuaLong(string table, string key)
        {
            if (string.IsNullOrEmpty(table)) return 0;
            var pattern = "\\[\\\"" + Regex.Escape(key) + "\\\"\\]\\s*=\\s*(-?[0-9]+)";
            var match = Regex.Match(table, pattern);
            long value;
            return match.Success && long.TryParse(match.Groups[1].Value, out value) ? value : 0;
        }

        private static string LuaString(string table, string key)
        {
            if (string.IsNullOrEmpty(table)) return string.Empty;
            var marker = "[\"" + key + "\"]";
            var at = table.IndexOf(marker, StringComparison.Ordinal);
            if (at < 0) return string.Empty;
            var eq = table.IndexOf('=', at + marker.Length);
            if (eq < 0) return string.Empty;
            var quote = table.IndexOf('"', eq + 1);
            if (quote < 0) return string.Empty;
            return ReadLuaQuoted(table, quote);
        }

        private static string ExtractLuaStringField(string text, string key)
        {
            var marker = "[\"" + key + "\"]";
            var at = text.IndexOf(marker, StringComparison.Ordinal);
            if (at < 0) return null;
            var eq = text.IndexOf('=', at + marker.Length);
            if (eq < 0) return null;
            var quote = text.IndexOf('"', eq + 1);
            if (quote < 0) return null;
            return ReadLuaQuoted(text, quote);
        }

        private static string ReadLuaQuoted(string text, int openingQuote)
        {
            var sb = new StringBuilder();
            var escaped = false;
            for (var i = openingQuote + 1; i < text.Length; i++)
            {
                var c = text[i];
                if (escaped)
                {
                    if (c == 'n') sb.Append('\n');
                    else if (c == 'r') sb.Append('\r');
                    else if (c == 't') sb.Append('\t');
                    else sb.Append(c);
                    escaped = false;
                    continue;
                }
                if (c == '\\') { escaped = true; continue; }
                if (c == '"') return sb.ToString();
                sb.Append(c);
            }
            return null;
        }

        private static string ExtractLuaTableField(string text, string key)
        {
            if (string.IsNullOrEmpty(text)) return null;
            var marker = "[\"" + key + "\"]";
            var at = text.IndexOf(marker, StringComparison.Ordinal);
            if (at < 0) return null;
            var eq = text.IndexOf('=', at + marker.Length);
            if (eq < 0) return null;
            var open = text.IndexOf('{', eq + 1);
            if (open < 0) return null;

            var depth = 0;
            var inString = false;
            var escaped = false;
            for (var i = open; i < text.Length; i++)
            {
                var c = text[i];
                if (inString)
                {
                    if (escaped) { escaped = false; continue; }
                    if (c == '\\') { escaped = true; continue; }
                    if (c == '"') inString = false;
                    continue;
                }
                if (c == '"') { inString = true; continue; }
                if (c == '{') depth++;
                else if (c == '}')
                {
                    depth--;
                    if (depth == 0) return text.Substring(open, i - open + 1);
                }
            }
            return null;
        }

        private static string BuildReport(string head, Baseline baseline, Snapshot current, string verdict, List<string> reasons)
        {
            var sb = new StringBuilder();
            sb.AppendLine("AH EVIDENCE GATE: " + verdict);
            sb.AppendLine("head_sha=" + (head ?? string.Empty));
            sb.AppendLine("source_id=" + (baseline.source_id ?? string.Empty));
            sb.AppendLine("compatibility_key_before=" + (baseline.compatibility_key ?? string.Empty));
            sb.AppendLine("compatibility_key_after=" + (current.CompatibilityKey ?? string.Empty));
            sb.AppendLine("baseline_utc=" + (baseline.captured_utc ?? string.Empty));
            sb.AppendLine("scans=" + baseline.scans + " -> " + current.Scans + " (delta " + (current.Scans - baseline.scans) + ")");
            sb.AppendLine("pages=" + baseline.pages + " -> " + current.Pages + " (delta " + (current.Pages - baseline.pages) + ")");
            sb.AppendLine("records=" + baseline.records + " -> " + current.Records + " (delta " + (current.Records - baseline.records) + ")");
            sb.AppendLine("decisionCompared=" + baseline.decision_compared + " -> " + current.DecisionCompared + " (delta " + (current.DecisionCompared - baseline.decision_compared) + ")");
            sb.AppendLine("observerErrors=" + current.ObserverErrors);
            sb.AppendLine("mismatches=" + current.Mismatches);
            sb.AppendLine("market_lastScanAt=" + current.LastScanAt + " items=" + current.Items + " auctions=" + current.Auctions + " packedRows=" + current.PackedRows);
            if (reasons.Count > 0) sb.AppendLine("reasons=" + string.Join(",", reasons.ToArray()));
            return sb.ToString();
        }

        private static async Task UploadIssueAsync(string token, string head, string sourceId, string verdict, string report)
        {
            if (string.IsNullOrWhiteSpace(token))
                throw new InvalidOperationException("Brak tokenu GitHub w updaterze — evidence policzone lokalnie, ale nie mogę wysłać Issue.");

            using (var client = new HttpClient())
            {
                client.DefaultRequestHeaders.UserAgent.ParseAdd("WoW112Updater-AHEvidence/1.0");
                client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
                client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Trim());
                client.DefaultRequestHeaders.Add("X-GitHub-Api-Version", "2022-11-28");

                var title = "[AH-EVIDENCE] " + ShortSha(head) + " " + verdict + " " + sourceId;
                var marker = "[ah-evidence:" + sourceId + ":" + DateTime.UtcNow.ToString("yyyyMMddHHmmss") + "]";
                var payload = new Dictionary<string, object>
                {
                    { "title", title },
                    { "body", "```text\n" + report + "```\n\n" + marker }
                };
                using (var request = new HttpRequestMessage(HttpMethod.Post, ApiRoot + "/issues"))
                {
                    request.Content = new StringContent(Json.Serialize(payload), Encoding.UTF8, "application/json");
                    using (var response = await client.SendAsync(request))
                    {
                        var text = await response.Content.ReadAsStringAsync();
                        if (!response.IsSuccessStatusCode)
                            throw new InvalidOperationException("GitHub Issue upload HTTP " + (int)response.StatusCode + ": " + text);
                    }
                }
            }
        }

        private static string ShortSha(string sha)
        {
            if (string.IsNullOrWhiteSpace(sha)) return "unknown";
            sha = sha.Trim();
            return sha.Length <= 8 ? sha : sha.Substring(0, 8);
        }
    }
}

