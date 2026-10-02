using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
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
        private static readonly string[] MonitoredBranches = { "parallel", "work", "main" };
        private readonly Dictionary<string, Label> githubMonitorBadges = new Dictionary<string, Label>
        {
            { "parallel", new Label() }, { "work", new Label() }, { "main", new Label() }
        };
        private readonly Label githubPipelineBadge = new Label();

        private TableLayoutPanel BuildGitHubMonitorHeader()
        {
            var grid = Grid(1, 2);
            grid.RowStyles.Clear();
            grid.RowStyles.Add(new RowStyle(SizeType.Percent, 50F));
            grid.RowStyles.Add(new RowStyle(SizeType.Percent, 50F));

            var branches = Grid(MonitoredBranches.Length, 1);
            branches.ColumnStyles.Clear();
            for (int i = 0; i < MonitoredBranches.Length; i++)
            {
                branches.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F / MonitoredBranches.Length));
                var branch = MonitoredBranches[i];
                var badge = githubMonitorBadges[branch];
                PrepareLabel(badge);
                badge.Font = new Font("Segoe UI", 8.1F, FontStyle.Bold);
                badge.Margin = new Padding(i == 0 ? 3 : 1, 1, i == MonitoredBranches.Length - 1 ? 3 : 1, 1);
                badge.Padding = new Padding(3, 0, 2, 0);
                badge.TextAlign = ContentAlignment.MiddleCenter;
                badge.AutoEllipsis = true;
                SetGitHubMonitorBadge(branch, "UNKNOWN", "", "Oczekiwanie na pierwszy odczyt GitHub.");
                branches.Controls.Add(badge, i, 0);
            }
            grid.Controls.Add(branches, 0, 0);

            PrepareLabel(githubPipelineBadge);
            githubPipelineBadge.Font = new Font("Segoe UI", 8.4F, FontStyle.Bold);
            githubPipelineBadge.Margin = new Padding(3, 1, 3, 1);
            githubPipelineBadge.Padding = new Padding(6, 0, 3, 0);
            githubPipelineBadge.TextAlign = ContentAlignment.MiddleLeft;
            githubPipelineBadge.AutoEllipsis = true;
            SetGitHubPipelineBadge("IDLE", "PIPELINE   IDLE", "Brak ostatniej aktywności feature/promote z exact-HEAD gate.");
            grid.Controls.Add(githubPipelineBadge, 0, 1);
            return grid;
        }

        private sealed class MonitorBadgeState
        {
            public string Status;
            public string Head;
            public string Detail;
        }

        private sealed class PipelineRunState
        {
            public string Branch;
            public string Head;
            public string Status;
            public string Workflow;
            public long RunId;
            public int Order;
        }

        private sealed class PipelineBadgeState
        {
            public string Status;
            public string Text;
            public string Detail;
            public string FocusBranch;
            public string FocusHead;
            public bool FocusIsPromote;
        }

        // Work/parallel require an authoritative run on the exact HEAD. Main keeps the
        // newest stable workflow as its stable-runtime signal when later HEAD commits do
        // not trigger Build stable candidate (for example updater/Guardian-only changes).
        private static MonitorBadgeState MonitorBranchBadge(string branch, string branchJson, string runsJson)
        {
            var serializer = new System.Web.Script.Serialization.JavaScriptSerializer();
            var root = AsDictionary(serializer.DeserializeObject(branchJson));
            var head = GetString(AsDictionary(GetValue(root, "commit")), "sha");
            if (string.IsNullOrWhiteSpace(head)) throw new InvalidOperationException("Brak HEAD: " + branch);
            var runs = AsDictionary(serializer.DeserializeObject(runsJson));
            var expectedWorkflow = string.Equals(branch, "main", StringComparison.OrdinalIgnoreCase)
                ? StableWorkflowName : TestWorkflowName;
            Dictionary<string, object> active = null, failed = null, passed = null, latestExpected = null;
            var seenExpectedWorkflow = false;
            foreach (var item in AsArray(GetValue(runs, "workflow_runs")))
            {
                var run = item as Dictionary<string, object>;
                if (run == null || !string.Equals(GetString(run, "name"), expectedWorkflow, StringComparison.Ordinal)) continue;
                if (latestExpected == null) latestExpected = run;
                if (!string.Equals(GetString(run, "head_sha"), head, StringComparison.OrdinalIgnoreCase)) continue;
                if (seenExpectedWorkflow) continue;
                seenExpectedWorkflow = true;
                var status = GetString(run, "status");
                var conclusion = GetString(run, "conclusion");
                if (!string.Equals(status, "completed", StringComparison.OrdinalIgnoreCase))
                    active = run;
                else if (IsFailedConclusion(conclusion))
                    failed = run;
                else if (string.Equals(conclusion, "success", StringComparison.OrdinalIgnoreCase))
                    passed = run;
            }
            var selected = active ?? failed ?? passed;
            if (selected == null && string.Equals(branch, "main", StringComparison.OrdinalIgnoreCase) && latestExpected != null)
            {
                var stableStatus = GetString(latestExpected, "status");
                var stableConclusion = GetString(latestExpected, "conclusion");
                var state = !string.Equals(stableStatus, "completed", StringComparison.OrdinalIgnoreCase)
                    ? (string.Equals(stableStatus, "in_progress", StringComparison.OrdinalIgnoreCase) ? "RUNNING" : "PENDING")
                    : IsFailedConclusion(stableConclusion) ? "FAIL"
                    : string.Equals(stableConclusion, "success", StringComparison.OrdinalIgnoreCase) ? "SUCCESS" : "UNKNOWN";
                return new MonitorBadgeState
                {
                    Status = state,
                    Head = head,
                    Detail = "main / HEAD " + head +
                        "\nAktualny HEAD nie ma własnego Build stable candidate." +
                        "\nOstatni stable workflow: " + MonitorShort(GetString(latestExpected, "head_sha"), 12) +
                        " / run " + GetLong(latestExpected, "id") +
                        " / " + stableStatus + " / " + stableConclusion +
                        "\nBelka STABLE opisuje ostatni zweryfikowany stable runtime; bieżący HEAD repo pozostaje pokazany osobno."
                };
            }
            if (selected == null)
                return new MonitorBadgeState
                {
                    Status = "UNKNOWN",
                    Head = head,
                    Detail = branch + " / HEAD " + head + ": brak workflow " + expectedWorkflow +
                        " na aktualnym SHA. Inne workflow (np. Guardian) nie wpływają na badge brancha."
                };
            var selectedState = active != null
                ? (string.Equals(GetString(selected, "status"), "in_progress", StringComparison.OrdinalIgnoreCase) ? "RUNNING" : "PENDING")
                : failed != null ? "FAIL" : "SUCCESS";
            return new MonitorBadgeState
            {
                Status = selectedState,
                Head = head,
                Detail = branch + " / HEAD " + head + "\nWorkflow: " + GetString(selected, "name") +
                    "\nRun: " + GetLong(selected, "id") + "\nStatus: " + GetString(selected, "status") +
                    " / " + GetString(selected, "conclusion") +
                    "\nWork/Parallel: success dotyczy dokładnego HEAD i autorytatywnego workflow kandydata."
            };
        }

        private static bool IsFailedConclusion(string conclusion)
        {
            return string.Equals(conclusion, "failure", StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(conclusion, "cancelled", StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(conclusion, "timed_out", StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(conclusion, "action_required", StringComparison.OrdinalIgnoreCase);
        }

        private static int PipelinePriority(string state)
        {
            if (state == "FAIL") return 0;
            if (state == "RUNNING" || state == "PENDING") return 1;
            if (state == "PASS") return 2;
            return 3;
        }

        private static PipelineBadgeState MonitorPipelineBadge(string branchesJson, string runsJson)
        {
            var serializer = new System.Web.Script.Serialization.JavaScriptSerializer();
            var branchRows = AsArray(serializer.DeserializeObject(branchesJson));
            var runsRoot = AsDictionary(serializer.DeserializeObject(runsJson));
            var runs = AsArray(GetValue(runsRoot, "workflow_runs"));
            var items = new List<PipelineRunState>();

            foreach (var item in branchRows)
            {
                var row = AsDictionary(item);
                var pipelineBranch = GetString(row, "name");
                var isFeature = pipelineBranch.StartsWith("feature/", StringComparison.OrdinalIgnoreCase);
                var isPromote = pipelineBranch.StartsWith("promote/", StringComparison.OrdinalIgnoreCase);
                if (!isFeature && !isPromote) continue;
                var head = GetString(AsDictionary(GetValue(row, "commit")), "sha");
                if (string.IsNullOrWhiteSpace(head)) continue;
                var expected = isPromote ? "Pre-promote stable" : "Parallel feature preflight";
                Dictionary<string, object> matched = null;
                var order = int.MaxValue;
                for (var i = 0; i < runs.Length; i++)
                {
                    var run = runs[i] as Dictionary<string, object>;
                    if (run == null) continue;
                    if (!string.Equals(GetString(run, "head_branch"), pipelineBranch, StringComparison.Ordinal)) continue;
                    if (!string.Equals(GetString(run, "head_sha"), head, StringComparison.OrdinalIgnoreCase)) continue;
                    if (!string.Equals(GetString(run, "name"), expected, StringComparison.Ordinal)) continue;
                    matched = run;
                    order = i;
                    break;
                }
                if (matched == null) continue;

                var runStatus = GetString(matched, "status");
                var conclusion = GetString(matched, "conclusion");
                var state = !string.Equals(runStatus, "completed", StringComparison.OrdinalIgnoreCase)
                    ? (string.Equals(runStatus, "in_progress", StringComparison.OrdinalIgnoreCase) ? "RUNNING" : "PENDING")
                    : IsFailedConclusion(conclusion) ? "FAIL"
                    : string.Equals(conclusion, "success", StringComparison.OrdinalIgnoreCase) ? "PASS" : "UNKNOWN";
                items.Add(new PipelineRunState
                {
                    Branch = pipelineBranch,
                    Head = head,
                    Status = state,
                    Workflow = expected,
                    RunId = GetLong(matched, "id"),
                    Order = order
                });
            }

            if (items.Count == 0)
                return new PipelineBadgeState
                {
                    Status = "IDLE",
                    Text = "PIPELINE   IDLE",
                    Detail = "Brak feature/promote z exact-HEAD gate w 100 najnowszych workflow runach. Historyczne branche nie zaśmiecają belki."
                };

            items.Sort(delegate(PipelineRunState a, PipelineRunState b)
            {
                var priority = PipelinePriority(a.Status).CompareTo(PipelinePriority(b.Status));
                return priority != 0 ? priority : a.Order.CompareTo(b.Order);
            });
            var focus = items[0];
            var anyFail = items.Exists(x => x.Status == "FAIL");
            var anyActive = items.Exists(x => x.Status == "RUNNING" || x.Status == "PENDING");
            var isFocusPromote = focus.Branch.StartsWith("promote/", StringComparison.OrdinalIgnoreCase);
            var overall = anyFail ? "FAIL" : anyActive ? "RUNNING" : isFocusPromote ? "PASS" : "VERIFIED";
            var leaf = focus.Branch.Substring(focus.Branch.IndexOf('/') + 1);
            var text = (isFocusPromote ? "PROMOTE " : "FEATURE ") + MonitorShort(leaf, 24) + "   " +
                (isFocusPromote ? "PRE-PROMOTE " : "PREFLIGHT ") + focus.Status + "   " + MonitorShort(focus.Head, 8);
            if (items.Count > 1) text += "   | +" + (items.Count - 1);

            var detail = new StringBuilder();
            detail.AppendLine("FEATURE / PROMOTE — exact HEAD gates:");
            foreach (var x in items)
                detail.AppendLine(x.Branch + "  " + x.Status + "  " + MonitorShort(x.Head, 12) +
                    "  run " + x.RunId + "  [" + x.Workflow + "]");
            detail.Append("Feature/promote są tylko podglądem; updater instaluje wyłącznie zweryfikowany Parallel.");
            return new PipelineBadgeState
            {
                Status = overall,
                Text = text,
                Detail = detail.ToString(),
                FocusBranch = focus.Branch,
                FocusHead = focus.Head,
                FocusIsPromote = isFocusPromote
            };
        }

        private static string MonitorExactWorkflowState(string runsJson, string workflowName, string branch, string head)
        {
            var serializer = new System.Web.Script.Serialization.JavaScriptSerializer();
            var root = AsDictionary(serializer.DeserializeObject(runsJson));
            foreach (var item in AsArray(GetValue(root, "workflow_runs")))
            {
                var run = item as Dictionary<string, object>;
                if (run == null) continue;
                if (!string.Equals(GetString(run, "name"), workflowName, StringComparison.Ordinal)) continue;
                if (!string.Equals(GetString(run, "head_branch"), branch, StringComparison.Ordinal)) continue;
                if (!string.Equals(GetString(run, "head_sha"), head, StringComparison.OrdinalIgnoreCase)) continue;
                var runStatus = GetString(run, "status");
                var conclusion = GetString(run, "conclusion");
                if (!string.Equals(runStatus, "completed", StringComparison.OrdinalIgnoreCase)) return "BUILDING";
                if (IsFailedConclusion(conclusion)) return "FAIL";
                if (string.Equals(conclusion, "success", StringComparison.OrdinalIgnoreCase)) return "READY";
                return "WAITING";
            }
            return "WAITING";
        }

        private static bool MonitorFeatureIsIntegrated(string compareJson, string featureHead)
        {
            var serializer = new System.Web.Script.Serialization.JavaScriptSerializer();
            var root = AsDictionary(serializer.DeserializeObject(compareJson));
            var mergeBase = GetString(AsDictionary(GetValue(root, "merge_base_commit")), "sha");
            return string.Equals(mergeBase, featureHead, StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(GetString(root, "status"), "identical", StringComparison.OrdinalIgnoreCase);
        }

        private bool MonitorSelectedDeliveryInstalled(string parallelHead)
        {
            try
            {
                var root = gameDir.Text.Trim();
                if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root)) return false;
                var statePath = IsEconomy() ? EconomyStatePath(root) : InstalledStatePath(root);
                var pendingPath = IsEconomy() ? EconomyPendingManifestPath(root) : PendingManifestPath(root);
                if (!File.Exists(statePath) || File.Exists(pendingPath)) return false;
                var state = AsDictionary(json.DeserializeObject(File.ReadAllText(statePath, Encoding.UTF8)));
                return string.Equals(GetString(state, "head_sha"), parallelHead, StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        private async Task<PipelineBadgeState> EnrichFeatureDeliveryAsync(HttpClient client, PipelineBadgeState pipeline, string parallelHead, string allRunsJson)
        {
            if (pipeline == null || pipeline.FocusIsPromote || pipeline.Status != "VERIFIED" ||
                string.IsNullOrWhiteSpace(pipeline.FocusHead) || string.IsNullOrWhiteSpace(parallelHead))
                return pipeline;

            var leaf = pipeline.FocusBranch.Substring(pipeline.FocusBranch.IndexOf('/') + 1);
            var compareJson = await GetStringAsync(client, ApiRoot + "/compare/" + pipeline.FocusHead + "..." + parallelHead);
            if (!MonitorFeatureIsIntegrated(compareJson, pipeline.FocusHead))
            {
                pipeline.Status = "WAITING";
                pipeline.Text = "FEATURE " + MonitorShort(leaf, 24) + "   VERIFIED " + MonitorShort(pipeline.FocusHead, 8) + "   | WAITING INTEGRATION";
                pipeline.Detail += "\n\nDOSTARCZENIE: PREFLIGHT PASS, ale feature nie jest jeszcze w aktualnym PARALLEL " +
                    MonitorShort(parallelHead, 12) + ". NIE JEST GOTOWY DO TESTU.";
                return pipeline;
            }

            var full = MonitorExactWorkflowState(allRunsJson, TestWorkflowName, "parallel", parallelHead);
            if (full == "FAIL")
            {
                pipeline.Status = "FAIL";
                pipeline.Text = "FEATURE " + MonitorShort(leaf, 24) + "   INTEGRATED   | PARALLEL BUILD FAIL";
                pipeline.Detail += "\n\nDOSTARCZENIE: feature jest w PARALLEL, ale exact-HEAD Build work candidate nie przeszedł.";
                return pipeline;
            }
            if (full != "READY")
            {
                pipeline.Status = "BUILDING";
                pipeline.Text = "FEATURE " + MonitorShort(leaf, 24) + "   INTEGRATED   | BUILDING PARALLEL";
                pipeline.Detail += "\n\nDOSTARCZENIE: feature jest w PARALLEL; czekam na exact-HEAD Build work candidate.";
                return pipeline;
            }

            var profile = "STANDARD";
            if (IsEconomy())
            {
                profile = "ECONOMY";
                var economy = MonitorExactWorkflowState(allRunsJson, EconomyWorkflowName, "parallel", parallelHead);
                if (economy == "FAIL")
                {
                    pipeline.Status = "FAIL";
                    pipeline.Text = "FEATURE " + MonitorShort(leaf, 24) + "   INTEGRATED   | ECONOMY BUILD FAIL";
                    pipeline.Detail += "\n\nDOSTARCZENIE: pełny PARALLEL przeszedł, ale ECONOMY exact-HEAD nie przeszedł.";
                    return pipeline;
                }
                if (economy != "READY")
                {
                    pipeline.Status = "BUILDING";
                    pipeline.Text = "FEATURE " + MonitorShort(leaf, 24) + "   INTEGRATED   | BUILDING ECONOMY";
                    pipeline.Detail += "\n\nDOSTARCZENIE: pełny PARALLEL przeszedł; czekam na ECONOMY exact-HEAD.";
                    return pipeline;
                }
            }

            if (MonitorSelectedDeliveryInstalled(parallelHead))
            {
                pipeline.Status = "INSTALLED";
                pipeline.Text = "FEATURE " + MonitorShort(leaf, 24) + "   INSTALLED / READY TO TEST   " + MonitorShort(parallelHead, 8);
                pipeline.Detail += "\n\nDOSTARCZENIE: " + profile + " dla exact PARALLEL HEAD jest zweryfikowany i zainstalowany lokalnie.";
            }
            else
            {
                pipeline.Status = "READY";
                pipeline.Text = "FEATURE " + MonitorShort(leaf, 24) + "   TEST READY IN " + profile + "   " + MonitorShort(parallelHead, 8);
                pipeline.Detail += "\n\nDOSTARCZENIE: " + profile + " dla exact PARALLEL HEAD jest zweryfikowany. Aktualizacja nie jest jeszcze zainstalowana lokalnie.";
            }
            return pipeline;
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
            var displayState = state == "SUCCESS"
                ? (string.Equals(branch, "main", StringComparison.OrdinalIgnoreCase) ? "STABLE" : "READY")
                : state == "RUNNING" ? "RUN"
                : state == "PENDING" ? "WAIT"
                : state == "UNKNOWN" ? "NO BUILD" : state;
            badge.Text = branch.ToUpperInvariant() + "  " + displayState + "  " +
                (string.IsNullOrEmpty(head) ? "?" : MonitorShort(head, 8));
            detailsTip.SetToolTip(badge, detail + "\nOdczyt: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
        }

        private void SetGitHubPipelineBadge(string state, string text, string detail)
        {
            if (githubPipelineBadge.IsDisposed) return;
            bool green = state == "PASS" || state == "READY" || state == "INSTALLED";
            bool yellow = state == "PENDING" || state == "RUNNING" || state == "VERIFIED" ||
                state == "WAITING" || state == "BUILDING";
            bool red = state == "FAIL";
            githubPipelineBadge.BackColor = green ? Color.FromArgb(32, 77, 50)
                : yellow ? Color.FromArgb(96, 74, 31)
                : red ? Color.FromArgb(96, 39, 43) : Color.FromArgb(45, 49, 58);
            githubPipelineBadge.ForeColor = green ? Color.FromArgb(164, 245, 181)
                : yellow ? Color.FromArgb(255, 217, 128)
                : red ? Color.FromArgb(255, 166, 166) : Muted;
            githubPipelineBadge.Text = text;
            detailsTip.SetToolTip(githubPipelineBadge, detail + "\nOdczyt: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
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
                    SetGitHubPipelineBadge("IDLE", "PIPELINE   BRAK TOKENU", "Brak tokenu GitHub.");
                    githubMonitorButton.Text = "GH: brak tokenu";
                    return;
                }
                githubMonitorButton.Text = "GH: sprawdzam";
                var result = new StringBuilder();
                result.AppendLine("WOW112 / GITHUB — " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " (czas lokalny)");
                result.AppendLine("Kontrola co 10 s przy uruchomionym updaterze. Brak aktywności GH nie wyklucza pracy AI poza repo.");
                result.AppendLine();
                bool failed = false;
                string parallelHead = string.Empty;
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
                            if (string.Equals(branch, "parallel", StringComparison.OrdinalIgnoreCase)) parallelHead = badge.Head;
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
                    // Second compact bar: recent exact-HEAD feature/promote gates only.
                    // Historical refs remain hidden from the header so two rows stay useful.
                    try
                    {
                        var branchesJson = await GetStringAsync(client, ApiRoot + "/branches?per_page=100");
                        var allRunsJson = await GetStringAsync(client, ApiRoot + "/actions/runs?per_page=100");
                        var pipeline = MonitorPipelineBadge(branchesJson, allRunsJson);
                        if (pipeline.Status == "VERIFIED" && !pipeline.FocusIsPromote)
                        {
                            try
                            {
                                pipeline = await EnrichFeatureDeliveryAsync(client, pipeline, parallelHead, allRunsJson);
                            }
                            catch (Exception ex)
                            {
                                pipeline.Status = "VERIFIED";
                                pipeline.Text += "   | DELIVERY UNKNOWN";
                                pipeline.Detail += "\n\nNie udało się potwierdzić integracji/dostarczenia: " + MonitorShort(ex.Message, 180) +
                                    "\nStan pozostaje niezielony: sam PREFLIGHT PASS nie oznacza gotowości do testu.";
                            }
                        }
                        SetGitHubPipelineBadge(pipeline.Status, pipeline.Text, pipeline.Detail);
                        result.AppendLine();
                        result.AppendLine(pipeline.Detail);
                        if (AsArray(json.DeserializeObject(branchesJson)).Length == 100)
                            result.AppendLine("Lista branchy może być niepełna: GitHub zwrócił limit 100.");
                    }
                    catch (Exception ex)
                    {
                        failed = true;
                        SetGitHubPipelineBadge("IDLE", "PIPELINE   BŁĄD ODCZYTU", "Błąd odczytu feature/promote: " + MonitorShort(ex.Message, 180));
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
                SetGitHubPipelineBadge("IDLE", "PIPELINE   BŁĄD ODCZYTU", githubMonitorReport);
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
