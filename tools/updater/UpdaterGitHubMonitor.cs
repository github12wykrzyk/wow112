using System;
using System.Collections.Generic;
using System.Drawing;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace WoW112Updater
{
    // Observer-only GitHub monitor. Never blocks game launch or changes installed files.
    internal sealed partial class MainForm
    {
        private readonly Timer githubMonitorTimer = new Timer { Interval = 10000 };
        private readonly Button githubMonitorButton = new Button();
        private Form githubMonitorWindow;
        private RichTextBox githubMonitorText;
        private bool githubMonitorInFlight;
        private string githubMonitorReport = "Monitor GitHub: jeszcze nie sprawdzono.";
        private static readonly string[] MonitoredBranches = { "work", "parallel", "main" };
        private readonly Dictionary<string, Label> githubMonitorBadges = new Dictionary<string, Label>
        {
            { "work", new Label() }, { "parallel", new Label() }, { "main", new Label() }
        };

        private TableLayoutPanel BuildGitHubMonitorHeader()
        {
            var grid = Grid(1, MonitoredBranches.Length);
            grid.RowStyles.Clear();
            for (int i = 0; i < MonitoredBranches.Length; i++)
            {
                grid.RowStyles.Add(new RowStyle(SizeType.Percent, 100F / MonitoredBranches.Length));
                var branch = MonitoredBranches[i];
                var badge = githubMonitorBadges[branch];
                PrepareLabel(badge);
                badge.Font = new Font("Segoe UI", 9F, FontStyle.Bold);
                badge.Margin = new Padding(3, 1, 3, 1);
                badge.Padding = new Padding(6, 0, 3, 0);
                SetGitHubMonitorBadge(branch, "UNKNOWN", "", "Oczekiwanie na pierwszy odczyt GitHub.");
                grid.Controls.Add(badge, 0, i);
            }
            return grid;
        }

        private sealed class MonitorBadgeState
        {
            public string Status;
            public string Head;
            public string Detail;
        }

        // Only runs on the exact branch HEAD may result in a green badge.
        private static MonitorBadgeState MonitorBranchBadge(string branch, string branchJson, string runsJson)
        {
            var serializer = new System.Web.Script.Serialization.JavaScriptSerializer();
            var root = AsDictionary(serializer.DeserializeObject(branchJson));
            var head = GetString(AsDictionary(GetValue(root, "commit")), "sha");
            if (string.IsNullOrWhiteSpace(head)) throw new InvalidOperationException("Brak HEAD: " + branch);
            var runs = AsDictionary(serializer.DeserializeObject(runsJson));
            var expectedWorkflow = string.Equals(branch, "main", StringComparison.OrdinalIgnoreCase)
                ? StableWorkflowName : TestWorkflowName;
            Dictionary<string, object> active = null, failed = null, passed = null;
            var seenExpectedWorkflow = false;
            foreach (var item in AsArray(GetValue(runs, "workflow_runs")))
            {
                var run = item as Dictionary<string, object>;
                if (run == null || !string.Equals(GetString(run, "head_sha"), head, StringComparison.OrdinalIgnoreCase)) continue;
                if (!string.Equals(GetString(run, "name"), expectedWorkflow, StringComparison.Ordinal)) continue;
                if (seenExpectedWorkflow) continue; // API is newest-first: only the latest run of the branch's authoritative workflow counts.
                seenExpectedWorkflow = true;
                var status = GetString(run, "status");
                var conclusion = GetString(run, "conclusion");
                if (!string.Equals(status, "completed", StringComparison.OrdinalIgnoreCase))
                {
                    if (active == null) active = run;
                }
                else if (string.Equals(conclusion, "failure", StringComparison.OrdinalIgnoreCase) ||
                         string.Equals(conclusion, "cancelled", StringComparison.OrdinalIgnoreCase) ||
                         string.Equals(conclusion, "timed_out", StringComparison.OrdinalIgnoreCase) ||
                         string.Equals(conclusion, "action_required", StringComparison.OrdinalIgnoreCase))
                {
                    if (failed == null) failed = run;
                }
                else if (string.Equals(conclusion, "success", StringComparison.OrdinalIgnoreCase))
                {
                    if (passed == null) passed = run;
                }
            }
            var selected = active ?? failed ?? passed;
            if (selected == null)
                return new MonitorBadgeState { Status = "UNKNOWN", Head = head,
                    Detail = branch + " / HEAD " + head + ": brak workflow " + expectedWorkflow +
                        " na aktualnym SHA. Inne workflow (np. Guardian) nie wpływają na badge brancha." };
            var state = active != null
                ? (string.Equals(GetString(selected, "status"), "in_progress", StringComparison.OrdinalIgnoreCase) ? "RUNNING" : "PENDING")
                : failed != null ? "FAIL" : "SUCCESS";
            return new MonitorBadgeState { Status = state, Head = head,
                Detail = branch + " / HEAD " + head + "\nWorkflow: " + GetString(selected, "name") +
                "\nRun: " + GetLong(selected, "id") + "\nStatus: " + GetString(selected, "status") +
                " / " + GetString(selected, "conclusion") +
                "\nTo status CI, nie potwierdzenie kompletnej paczki." };
        }

        private void SetGitHubMonitorBadge(string branch, string state, string head, string detail)
        {
            Label badge;
            if (!githubMonitorBadges.TryGetValue(branch, out badge) || badge.IsDisposed) return;
            bool green = state == "SUCCESS", yellow = state == "PENDING" || state == "RUNNING", red = state == "FAIL";
            badge.BackColor = green ? Color.FromArgb(32, 77, 50)
                : yellow ? Color.FromArgb(96, 74, 31)
                : red ? Color.FromArgb(96, 39, 43) : Color.FromArgb(45, 49, 58);
            badge.ForeColor = green ? Color.FromArgb(164, 245, 181)
                : yellow ? Color.FromArgb(255, 217, 128)
                : red ? Color.FromArgb(255, 166, 166) : Muted;
            badge.Text = branch.ToUpperInvariant() + "   " + state + "   " +
                (string.IsNullOrEmpty(head) ? "HEAD ?" : MonitorShort(head, 8)) +
                "   " + (string.IsNullOrEmpty(head) ? "—" : DateTime.Now.ToString("HH:mm:ss"));
            detailsTip.SetToolTip(badge, detail + "\nOdczyt: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
        }

        private void StartGitHubMonitor()
        {
            if (Array.Exists(Environment.GetCommandLineArgs(), a => a == "--ui-smoke")) return;
            githubMonitorTimer.Tick += async delegate { await RefreshGitHubMonitorAsync(); };
            githubMonitorTimer.Start();
            var unused = RefreshGitHubMonitorAsync();
            FormClosed += delegate
            {
                githubMonitorTimer.Stop();
                githubMonitorTimer.Dispose();
                if (githubMonitorWindow != null && !githubMonitorWindow.IsDisposed)
                    githubMonitorWindow.Close();
            };
        }

        private void ShowGitHubMonitor()
        {
            if (githubMonitorWindow != null && !githubMonitorWindow.IsDisposed)
            {
                githubMonitorWindow.Activate();
                return;
            }
            var window = new Form
            {
                Text = "Monitor GitHub — wow112 (co 10 sekund)",
                StartPosition = FormStartPosition.CenterParent,
                ClientSize = new Size(730, 470),
                MinimumSize = new Size(560, 360),
                BackColor = Canvas,
                ForeColor = Ink,
                Font = Font
            };
            var panel = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(12), ColumnCount = 1, RowCount = 2 };
            panel.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 42F));
            var output = new RichTextBox
            {
                Dock = DockStyle.Fill,
                ReadOnly = true,
                WordWrap = true,
                BackColor = Surface,
                ForeColor = Ink,
                Font = new Font("Consolas", 9F),
                Text = githubMonitorReport
            };
            var refresh = new Button { Dock = DockStyle.Right, Width = 170, Text = "Odśwież teraz" };
            ActionButton(refresh, "Odśwież teraz");
            refresh.Click += async delegate { await RefreshGitHubMonitorAsync(); };
            panel.Controls.Add(output, 0, 0);
            panel.Controls.Add(refresh, 0, 1);
            window.Controls.Add(panel);
            githubMonitorWindow = window;
            githubMonitorText = output;
            window.FormClosed += delegate { githubMonitorWindow = null; githubMonitorText = null; };
            window.Show(this);
        }

        private static string MonitorShort(string value, int max)
        {
            if (string.IsNullOrEmpty(value)) return "?";
            value = value.Replace("\r", " ").Replace("\n", " ").Trim();
            return value.Length > max ? value.Substring(0, max) + "…" : value;
        }

        // Pure parser: it must not mistake an older successful build for the current HEAD.
        private static string MonitorBranchLine(string branch, string branchJson, string runsJson)
        {
            var serializer = new System.Web.Script.Serialization.JavaScriptSerializer();
            var branchRoot = AsDictionary(serializer.DeserializeObject(branchJson));
            var commit = AsDictionary(GetValue(branchRoot, "commit"));
            var sha = GetString(commit, "sha");
            var commitDetails = AsDictionary(GetValue(commit, "commit"));
            var message = MonitorShort(GetString(commitDetails, "message"), 100);
            var runsRoot = AsDictionary(serializer.DeserializeObject(runsJson));
            var runs = AsArray(GetValue(runsRoot, "workflow_runs"));
            var expected = branch == "main" ? StableWorkflowName : TestWorkflowName;
            Dictionary<string, object> candidate = null;
            Dictionary<string, object> active = null;
            foreach (var item in runs)
            {
                var run = item as Dictionary<string, object>;
                if (run == null) continue;
                string state = GetString(run, "status");
                if (active == null && (state == "queued" || state == "in_progress" || state == "waiting" || state == "requested" || state == "pending"))
                    active = run;
                if (candidate == null && GetString(run, "name") == expected) candidate = run;
            }
            var text = new StringBuilder();
            text.AppendLine(branch.ToUpperInvariant() + "  HEAD " + MonitorShort(sha, 8) + "  " + message);
            if (active != null)
                text.AppendLine("  AKTYWNY: " + MonitorShort(GetString(active, "name"), 50) + " / " + GetString(active, "status") +
                    " / " + MonitorShort(GetString(active, "head_sha"), 8));
            if (candidate == null)
                text.AppendLine("  Build: brak ostatniego workflow " + expected + " w pobranych wynikach.");
            else
            {
                string runSha = GetString(candidate, "head_sha");
                string result = GetString(candidate, "status") == "completed"
                    ? GetString(candidate, "conclusion") : GetString(candidate, "status");
                text.AppendLine("  Build: " + result + " / " + MonitorShort(runSha, 8) +
                    (runSha == sha ? " (aktualny HEAD)" : " (STARSZY SHA — brak potwierdzenia builda HEAD)") +
                    " / run " + GetLong(candidate, "id"));
            }
            return text.ToString();
        }

        private async Task RefreshGitHubMonitorAsync()
        {
            if (githubMonitorInFlight || IsDisposed || Disposing) return;
            githubMonitorInFlight = true;
            try
            {
                if (string.IsNullOrWhiteSpace(token.Text))
                {
                    githubMonitorReport = "Monitor wymaga zapisanego tokenu GitHub (Contents: Read, Actions: Read).";
                    foreach (var monitored in MonitoredBranches) SetGitHubMonitorBadge(monitored, "UNKNOWN", "", "Brak tokenu GitHub.");
                    githubMonitorButton.Text = "GH: brak tokenu";
                    return;
                }
                githubMonitorButton.Text = "GH: sprawdzam";
                var result = new StringBuilder();
                result.AppendLine("WOW112 / GITHUB — " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " (czas lokalny)");
                result.AppendLine("Kontrola co 10 s przy uruchomionym updaterze. Brak aktywności GH nie wyklucza pracy AI poza repo.");
                result.AppendLine();
                bool failed = false;
                using (var client = CreateClient())
                {
                    client.Timeout = TimeSpan.FromSeconds(18);
                    foreach (string branch in MonitoredBranches)
                    {
                        try
                        {
                            var branchData = await GetStringAsync(client, ApiRoot + "/branches/" + branch);
                            var runData = await GetStringAsync(client, ApiRoot + "/actions/runs?branch=" + branch + "&per_page=30");
                            var badge = MonitorBranchBadge(branch, branchData, runData);
                            SetGitHubMonitorBadge(branch, badge.Status, badge.Head, badge.Detail);
                            result.AppendLine(MonitorBranchLine(branch, branchData, runData));
                        }
                        catch (Exception ex)
                        {
                            failed = true;
                            SetGitHubMonitorBadge(branch, "UNKNOWN", "", "Błąd odczytu: " + MonitorShort(ex.Message, 180));
                            result.AppendLine(branch.ToUpperInvariant() + ": BŁĄD odczytu GitHub: " + MonitorShort(ex.Message, 180));
                            result.AppendLine();
                        }
                        githubMonitorReport = result.ToString();
                        if (githubMonitorText != null && !githubMonitorText.IsDisposed)
                            githubMonitorText.Text = githubMonitorReport;
                    }
                    // Feature and promotion refs are visible for experiment routing only.
                    // Never interpret their HEAD as an installable Parallel candidate.
                    try
                    {
                        var branchRows = AsArray(json.DeserializeObject(await GetStringAsync(client,
                            ApiRoot + "/branches?per_page=100")));
                        var experimentRefs = new List<string>();
                        foreach (var item in branchRows)
                        {
                            var row = AsDictionary(item);
                            var name = GetString(row, "name");
                            if (!name.StartsWith("feature/", StringComparison.OrdinalIgnoreCase) &&
                                !name.StartsWith("promote/", StringComparison.OrdinalIgnoreCase)) continue;
                            var commit = AsDictionary(GetValue(row, "commit"));
                            experimentRefs.Add(name + "  HEAD " + MonitorShort(GetString(commit, "sha"), 8));
                        }
                        experimentRefs.Sort(StringComparer.OrdinalIgnoreCase);
                        result.AppendLine("EKSPERYMENTY / PROMOCJE (podgląd, nie są instalowane):");
                        if (experimentRefs.Count == 0) result.AppendLine("  Brak widocznych branchy feature/* i promote/*.");
                        foreach (var line in experimentRefs) result.AppendLine("  " + line);
                        if (branchRows.Length == 100) result.AppendLine("  Lista może być niepełna: GitHub zwrócił limit 100 branchy.");
                    }
                    catch (Exception ex)
                    {
                        failed = true;
                        result.AppendLine("Eksperymenty: błąd odczytu GitHub: " + MonitorShort(ex.Message, 180));
                    }
                    githubMonitorReport = result.ToString();
                    if (githubMonitorText != null && !githubMonitorText.IsDisposed)
                        githubMonitorText.Text = githubMonitorReport;
                }
                githubMonitorButton.Text = failed ? "GH: błąd" : "GH: " + DateTime.Now.ToString("HH:mm");
                detailsTip.SetToolTip(githubMonitorButton, failed ? "Część odczytów nie powiodła się. Otwórz monitor." : "Ostatnia kontrola: " + DateTime.Now.ToString("HH:mm:ss"));
            }
            catch (Exception ex)
            {
                githubMonitorReport = "Monitor: błąd połączenia z GitHub: " + MonitorShort(ex.Message, 180);
                foreach (var monitored in MonitoredBranches) SetGitHubMonitorBadge(monitored, "UNKNOWN", "", githubMonitorReport);
                githubMonitorButton.Text = "GH: błąd";
                if (githubMonitorText != null && !githubMonitorText.IsDisposed)
                    githubMonitorText.Text = githubMonitorReport;
            }
            finally
            {
                githubMonitorInFlight = false;
                if (githubMonitorText != null && !githubMonitorText.IsDisposed)
                    githubMonitorText.Text = githubMonitorReport;
            }
        }
    }
}
