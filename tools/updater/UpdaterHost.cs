using System;
using System.Collections.Generic;
using System.Drawing;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace WoW112Updater
{
    // Compile-time contract between MainForm and optional updater features.
    // Features must not discover MainForm private fields/methods via reflection.
    internal interface IUpdaterHost
    {
        Form Window { get; }
        string GameDirectory { get; }
        string GitHubToken { get; }
        bool IsStableChannel { get; }
        string SessionLogText { get; }
        string[] DisabledDllNames { get; }
        event EventHandler GameDirectoryChanged;
        void RegisterUiControl(string key, Control control);
        void SetBusy(bool value, string text);
        void SetStatus(string text);
        void LogMessage(string message);
        void RefreshLocalState();
    }

    internal sealed partial class MainForm : IUpdaterHost
    {
        private sealed class GitHubLiveWaitItem
        {
            public string Kind;
            public string Branch;
            public string Head;
            public long RunId;
        }

        private readonly Timer githubLiveOverviewTimer = CreateGitHubLiveOverviewTimer();
        private bool githubLiveOverviewBusy;
        private bool githubLiveOverviewHooked;

        private static Timer CreateGitHubLiveOverviewTimer()
        {
            var timer = new Timer { Interval = 1200 };
            timer.Tick += async delegate
            {
                var mainHandle = System.Diagnostics.Process.GetCurrentProcess().MainWindowHandle;
                var form = mainHandle == IntPtr.Zero ? null : Control.FromHandle(mainHandle) as MainForm;
                if (form == null) form = Form.ActiveForm as MainForm;
                if (form == null || form.IsDisposed || form.Disposing) return;
                timer.Interval = 10000;
                await form.RefreshGitHubLiveOverviewAsync();
            };
            timer.Start();
            return timer;
        }

        private static string GitHubLiveRunKey(Dictionary<string, object> run)
        {
            return GetString(run, "name") + "\n" + GetString(run, "head_branch") + "\n" + GetString(run, "head_sha");
        }

        private static string GitHubLiveRunState(Dictionary<string, object> run)
        {
            if (run == null) return "MISSING";
            var status = GetString(run, "status");
            var conclusion = GetString(run, "conclusion");
            if (!string.Equals(status, "completed", StringComparison.OrdinalIgnoreCase))
                return string.Equals(status, "in_progress", StringComparison.OrdinalIgnoreCase) ? "RUNNING" : "PENDING";
            if (IsFailedConclusion(conclusion)) return "FAIL";
            if (string.Equals(conclusion, "success", StringComparison.OrdinalIgnoreCase)) return "PASS";
            return "UNKNOWN";
        }

        private static Dictionary<string, object> GitHubLiveFindRun(
            Dictionary<string, Dictionary<string, object>> latest,
            string workflow,
            string branch,
            string head)
        {
            Dictionary<string, object> run;
            return latest.TryGetValue(workflow + "\n" + branch + "\n" + head, out run) ? run : null;
        }

        private async Task<List<Dictionary<string, object>>> GitHubLiveFetchBranchesAsync(HttpClient client)
        {
            var rows = new List<Dictionary<string, object>>();
            for (var page = 1; page <= 3; page++)
            {
                var text = await GetStringAsync(client, ApiRoot + "/branches?per_page=100&page=" + page);
                var pageRows = AsArray(json.DeserializeObject(text));
                foreach (var item in pageRows)
                {
                    var row = item as Dictionary<string, object>;
                    if (row != null) rows.Add(row);
                }
                if (pageRows.Length < 100) break;
            }
            return rows;
        }

        private async Task<List<Dictionary<string, object>>> GitHubLiveFetchRunsAsync(HttpClient client)
        {
            var rows = new List<Dictionary<string, object>>();
            for (var page = 1; page <= 3; page++)
            {
                var text = await GetStringAsync(client, ApiRoot + "/actions/runs?per_page=100&page=" + page);
                var root = AsDictionary(json.DeserializeObject(text));
                var pageRows = AsArray(GetValue(root, "workflow_runs"));
                foreach (var item in pageRows)
                {
                    var row = item as Dictionary<string, object>;
                    if (row != null) rows.Add(row);
                }
                if (pageRows.Length < 100) break;
            }
            return rows;
        }

        private async Task<HashSet<string>> GitHubLiveFetchParallelParentsAsync(HttpClient client, string parallelHead)
        {
            var integrated = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (!string.IsNullOrWhiteSpace(parallelHead)) integrated.Add(parallelHead);
            var text = await GetStringAsync(client, ApiRoot + "/commits?sha=parallel&per_page=100");
            foreach (var item in AsArray(json.DeserializeObject(text)))
            {
                var row = item as Dictionary<string, object>;
                if (row == null) continue;
                var sha = GetString(row, "sha");
                if (!string.IsNullOrWhiteSpace(sha)) integrated.Add(sha);
                foreach (var parentItem in AsArray(GetValue(row, "parents")))
                {
                    var parent = parentItem as Dictionary<string, object>;
                    var parentSha = parent == null ? string.Empty : GetString(parent, "sha");
                    if (!string.IsNullOrWhiteSpace(parentSha)) integrated.Add(parentSha);
                }
            }
            return integrated;
        }

        private static void GitHubLiveAppendRun(StringBuilder text, string prefix, Dictionary<string, object> run)
        {
            text.Append(prefix)
                .Append(MonitorShort(GetString(run, "name"), 42)).Append(" | ")
                .Append(MonitorShort(GetString(run, "head_branch"), 38)).Append(" | ")
                .Append(MonitorShort(GetString(run, "head_sha"), 8)).Append(" | ")
                .Append(GetString(run, "status"));
            var conclusion = GetString(run, "conclusion");
            if (!string.IsNullOrWhiteSpace(conclusion)) text.Append('/').Append(conclusion);
            text.Append(" | run ").Append(GetLong(run, "id")).AppendLine();
        }

        private static void GitHubLiveSetPipelineVisual(Label badge, string state, string text, string detail, ToolTip tooltip)
        {
            if (badge == null || badge.IsDisposed) return;
            var idle = state == "IDLE";
            var fail = state == "FAIL";
            var running = state == "RUNNING";
            var ready = state == "READY";
            badge.BackColor = idle ? Color.FromArgb(32, 77, 50)
                : fail ? Color.FromArgb(96, 39, 43)
                : running ? Color.FromArgb(96, 74, 31)
                : ready ? Color.FromArgb(34, 67, 112)
                : Color.FromArgb(45, 49, 58);
            badge.ForeColor = idle ? Color.FromArgb(164, 245, 181)
                : fail ? Color.FromArgb(255, 166, 166)
                : running ? Color.FromArgb(255, 217, 128)
                : ready ? Color.FromArgb(174, 211, 255)
                : Color.FromArgb(178, 184, 197);
            badge.Text = text;
            tooltip.SetToolTip(badge, detail + "\nOdczyt: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
        }

        private void GitHubLiveMaskHealthyBranches(bool idle)
        {
            foreach (var pair in githubMonitorBadges)
            {
                var badge = pair.Value;
                if (badge == null || badge.IsDisposed) continue;
                var healthy = badge.Text.IndexOf(" READY ", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    badge.Text.IndexOf(" STABLE ", StringComparison.OrdinalIgnoreCase) >= 0;
                if (!healthy) continue;
                badge.BackColor = idle ? Color.FromArgb(32, 77, 50) : Color.FromArgb(45, 49, 58);
                badge.ForeColor = idle ? Color.FromArgb(164, 245, 181) : Muted;
            }
        }

        private async Task RefreshGitHubLiveOverviewAsync()
        {
            if (githubLiveOverviewBusy || IsDisposed || Disposing) return;
            githubLiveOverviewBusy = true;
            githubMonitorTimer.Stop();
            try
            {
                if (!githubLiveOverviewHooked)
                {
                    githubLiveOverviewHooked = true;
                    githubMonitorButton.Click += async delegate { await RefreshGitHubLiveOverviewAsync(); };
                }

                if (string.IsNullOrWhiteSpace(token.Text))
                {
                    foreach (var monitored in MonitoredBranches)
                        SetGitHubMonitorBadge(monitored, "UNKNOWN", string.Empty, "Brak tokenu GitHub.");
                    GitHubLiveSetPipelineVisual(githubPipelineBadge, "UNKNOWN", "GH LIVE   BRAK TOKENU", "Wpisz token GitHub, aby monitorować repo.", detailsTip);
                    githubMonitorButton.Text = "GH: brak tokenu";
                    return;
                }

                using (var client = CreateClient())
                {
                    client.Timeout = TimeSpan.FromSeconds(18);
                    var branches = await GitHubLiveFetchBranchesAsync(client);
                    var runs = await GitHubLiveFetchRunsAsync(client);

                    var branchHeads = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    foreach (var row in branches)
                    {
                        var name = GetString(row, "name");
                        var commit = AsDictionary(GetValue(row, "commit"));
                        var sha = GetString(commit, "sha");
                        if (!string.IsNullOrWhiteSpace(name) && !string.IsNullOrWhiteSpace(sha)) branchHeads[name] = sha;
                    }

                    var latestRuns = new Dictionary<string, Dictionary<string, object>>(StringComparer.OrdinalIgnoreCase);
                    foreach (var run in runs)
                    {
                        var key = GitHubLiveRunKey(run);
                        if (!latestRuns.ContainsKey(key)) latestRuns[key] = run;
                    }

                    string parallelHead;
                    branchHeads.TryGetValue("parallel", out parallelHead);
                    var integratedHeads = await GitHubLiveFetchParallelParentsAsync(client, parallelHead);

                    foreach (var monitored in MonitoredBranches)
                    {
                        string head;
                        if (!branchHeads.TryGetValue(monitored, out head))
                        {
                            SetGitHubMonitorBadge(monitored, "UNKNOWN", string.Empty, "Nie znaleziono brancha w odczycie GitHub.");
                            continue;
                        }
                        var expected = string.Equals(monitored, "main", StringComparison.OrdinalIgnoreCase)
                            ? StableWorkflowName : TestWorkflowName;
                        var run = GitHubLiveFindRun(latestRuns, expected, monitored, head);
                        var state = GitHubLiveRunState(run);
                        var badgeState = state == "PASS" ? "SUCCESS"
                            : state == "RUNNING" ? "RUNNING"
                            : state == "PENDING" ? "PENDING"
                            : state == "FAIL" ? "FAIL" : "UNKNOWN";
                        var detail = monitored + " / HEAD " + head;
                        if (run == null)
                            detail += "\nBrak exact-HEAD workflow " + expected + ".";
                        else
                            detail += "\nWorkflow: " + GetString(run, "name") + "\nRun: " + GetLong(run, "id") +
                                "\nStatus: " + GetString(run, "status") + " / " + GetString(run, "conclusion");
                        SetGitHubMonitorBadge(monitored, badgeState, head, detail);
                    }

                    var activeRuns = new List<Dictionary<string, object>>();
                    var currentFailures = new List<Dictionary<string, object>>();
                    foreach (var run in latestRuns.Values)
                    {
                        var state = GitHubLiveRunState(run);
                        if (state == "RUNNING" || state == "PENDING") activeRuns.Add(run);
                        if (state != "FAIL") continue;
                        var branch = GetString(run, "head_branch");
                        string currentHead;
                        if (branchHeads.TryGetValue(branch, out currentHead) &&
                            string.Equals(currentHead, GetString(run, "head_sha"), StringComparison.OrdinalIgnoreCase))
                            currentFailures.Add(run);
                    }

                    var waiting = new List<GitHubLiveWaitItem>();
                    foreach (var pair in branchHeads)
                    {
                        var branch = pair.Key;
                        var head = pair.Value;
                        var feature = branch.StartsWith("feature/", StringComparison.OrdinalIgnoreCase);
                        var promote = branch.StartsWith("promote/", StringComparison.OrdinalIgnoreCase);
                        if (!feature && !promote) continue;
                        var gateName = promote ? "Pre-promote stable" : "Parallel feature preflight";
                        var gate = GitHubLiveFindRun(latestRuns, gateName, branch, head);
                        if (GitHubLiveRunState(gate) != "PASS") continue;
                        if (promote)
                        {
                            waiting.Add(new GitHubLiveWaitItem { Kind = "READY→MAIN", Branch = branch, Head = head, RunId = GetLong(gate, "id") });
                            continue;
                        }
                        if (!integratedHeads.Contains(head))
                            waiting.Add(new GitHubLiveWaitItem { Kind = "READY→PARALLEL", Branch = branch, Head = head, RunId = GetLong(gate, "id") });
                    }

                    if (!string.IsNullOrWhiteSpace(parallelHead))
                    {
                        var fullRun = GitHubLiveFindRun(latestRuns, TestWorkflowName, "parallel", parallelHead);
                        var fullReady = GitHubLiveRunState(fullRun) == "PASS";
                        var profileReady = fullReady;
                        if (profileReady && IsEconomy())
                        {
                            var economyRun = GitHubLiveFindRun(latestRuns, EconomyWorkflowName, "parallel", parallelHead);
                            profileReady = GitHubLiveRunState(economyRun) == "PASS";
                        }
                        if (profileReady && !MonitorSelectedDeliveryInstalled(parallelHead))
                            waiting.Add(new GitHubLiveWaitItem
                            {
                                Kind = IsEconomy() ? "READY→UPDATE ECONOMY" : "READY→UPDATE STANDARD",
                                Branch = "parallel",
                                Head = parallelHead,
                                RunId = fullRun == null ? 0 : GetLong(fullRun, "id")
                            });
                    }

                    var failCount = currentFailures.Count;
                    var runCount = activeRuns.Count;
                    var readyCount = waiting.Count;
                    var overall = failCount > 0 ? "FAIL" : runCount > 0 ? "RUNNING" : readyCount > 0 ? "READY" : "IDLE";
                    var summary = failCount > 0
                        ? "GH LIVE   FAIL " + failCount + "   | RUN " + runCount + "   | READY " + readyCount
                        : runCount > 0
                            ? "GH LIVE   RUN " + runCount + "   | READY " + readyCount
                            : readyCount > 0
                                ? "GH LIVE   READY " + readyCount + "   | CZEKA NA RUCH"
                                : "GH LIVE   IDLE   | NIC NIE CZEKA";

                    var report = new StringBuilder();
                    report.AppendLine("WOW112 / GITHUB LIVE — " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " (czas lokalny)");
                    report.AppendLine("ZIELONY = brak aktywnych workflow, brak gotowych feature/promote i brak gotowego Parallel do aktualizacji.");
                    report.AppendLine("ŻÓŁTY = coś trwa. NIEBIESKI = coś jest gotowe i czeka. CZERWONY = current-HEAD FAIL.");
                    report.AppendLine();
                    report.AppendLine("PODSUMOWANIE: " + summary);
                    report.AppendLine("PARALLEL: " + (string.IsNullOrWhiteSpace(parallelHead) ? "?" : parallelHead));
                    report.AppendLine();

                    report.AppendLine("AKTYWNE WORKFLOW (" + activeRuns.Count + "):");
                    if (activeRuns.Count == 0) report.AppendLine("  brak");
                    else
                    {
                        var shown = 0;
                        foreach (var run in activeRuns)
                        {
                            GitHubLiveAppendRun(report, "  RUN  ", run);
                            if (++shown >= 40) { report.AppendLine("  ... dalsze aktywne runy pominięte w oknie"); break; }
                        }
                    }
                    report.AppendLine();

                    report.AppendLine("GOTOWE / CZEKA NA RUCH (" + waiting.Count + "):");
                    if (waiting.Count == 0) report.AppendLine("  brak");
                    else
                    {
                        foreach (var item in waiting)
                            report.AppendLine("  " + item.Kind + "  " + item.Branch + "  " + MonitorShort(item.Head, 12) +
                                (item.RunId > 0 ? "  run " + item.RunId : string.Empty));
                    }
                    report.AppendLine();

                    report.AppendLine("CURRENT-HEAD FAIL (" + currentFailures.Count + "):");
                    if (currentFailures.Count == 0) report.AppendLine("  brak");
                    else
                    {
                        foreach (var run in currentFailures) GitHubLiveAppendRun(report, "  FAIL ", run);
                    }
                    report.AppendLine();

                    report.AppendLine("OSTATNIE RUNY GH:");
                    var recent = 0;
                    foreach (var run in runs)
                    {
                        GitHubLiveAppendRun(report, "  " + GitHubLiveRunState(run).PadRight(7) + " ", run);
                        if (++recent >= 25) break;
                    }

                    GitHubLiveSetPipelineVisual(githubPipelineBadge, overall, summary, report.ToString(), detailsTip);
                    GitHubLiveMaskHealthyBranches(overall == "IDLE");
                    githubMonitorReport = report.ToString();
                    if (githubMonitorText != null && !githubMonitorText.IsDisposed)
                        githubMonitorText.Text = githubMonitorReport;
                    githubMonitorButton.Text = failCount > 0 ? "GH: FAIL " + failCount
                        : runCount > 0 ? "GH: RUN " + runCount
                        : readyCount > 0 ? "GH: READY " + readyCount : "GH: idle";
                    detailsTip.SetToolTip(githubMonitorButton, "GitHub LIVE: " + summary + "\nOstatni odczyt: " + DateTime.Now.ToString("HH:mm:ss"));
                }
            }
            catch (Exception ex)
            {
                GitHubLiveSetPipelineVisual(githubPipelineBadge, "FAIL", "GH LIVE   BŁĄD ODCZYTU", MonitorShort(ex.Message, 240), detailsTip);
                GitHubLiveMaskHealthyBranches(false);
                githubMonitorReport = "GitHub LIVE: błąd odczytu: " + ex.Message;
                githubMonitorButton.Text = "GH: błąd";
                if (githubMonitorText != null && !githubMonitorText.IsDisposed)
                    githubMonitorText.Text = githubMonitorReport;
            }
            finally
            {
                githubLiveOverviewBusy = false;
            }
        }

        void IUpdaterHost.RegisterUiControl(string key, Control control)
        {
            featureControls.Add(key, control);
        }

        Form IUpdaterHost.Window
        {
            get { return this; }
        }

        string IUpdaterHost.GameDirectory
        {
            get { return gameDir.Text.Trim(); }
        }

        string IUpdaterHost.GitHubToken
        {
            get { return token.Text.Trim(); }
        }

        bool IUpdaterHost.IsStableChannel
        {
            get { return IsStable(); }
        }

        string[] IUpdaterHost.DisabledDllNames
        {
            get { return GetDllInstallDisabledForSave(); }
        }

        string IUpdaterHost.SessionLogText
        {
            get { return log.Text ?? string.Empty; }
        }

        event EventHandler IUpdaterHost.GameDirectoryChanged
        {
            add { gameDir.TextChanged += value; }
            remove { gameDir.TextChanged -= value; }
        }

        void IUpdaterHost.SetBusy(bool value, string text)
        {
            SetBusy(value, text);
        }

        void IUpdaterHost.SetStatus(string text)
        {
            status.Text = text ?? string.Empty;
        }

        void IUpdaterHost.LogMessage(string message)
        {
            Log(message);
        }

        void IUpdaterHost.RefreshLocalState()
        {
            RefreshLocalState();
        }
    }
}
