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
        private readonly Timer githubMonitorTimer = new Timer { Interval = 60000 };
        private readonly Button githubMonitorButton = new Button();
        private Form githubMonitorWindow;
        private RichTextBox githubMonitorText;
        private bool githubMonitorInFlight;
        private string githubMonitorReport = "Monitor GitHub: jeszcze nie sprawdzono.";

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
                Text = "Monitor GitHub — wow112 (co 60 sekund)",
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
                    githubMonitorButton.Text = "GH: brak tokenu";
                    return;
                }
                githubMonitorButton.Text = "GH: sprawdzam";
                var result = new StringBuilder();
                result.AppendLine("WOW112 / GITHUB — " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " (czas lokalny)");
                result.AppendLine("Kontrola co 60 s przy uruchomionym updaterze. Brak aktywności GH nie wyklucza pracy AI poza repo.");
                result.AppendLine();
                bool failed = false;
                using (var client = CreateClient())
                {
                    client.Timeout = TimeSpan.FromSeconds(18);
                    foreach (string branch in new[] { "work", "parallel", "main" })
                    {
                        try
                        {
                            var branchData = await GetStringAsync(client, ApiRoot + "/branches/" + branch);
                            var runData = await GetStringAsync(client, ApiRoot + "/actions/runs?branch=" + branch + "&per_page=30");
                            result.AppendLine(MonitorBranchLine(branch, branchData, runData));
                        }
                        catch (Exception ex)
                        {
                            failed = true;
                            result.AppendLine(branch.ToUpperInvariant() + ": BŁĄD odczytu GitHub: " + MonitorShort(ex.Message, 180));
                            result.AppendLine();
                        }
                        githubMonitorReport = result.ToString();
                        if (githubMonitorText != null && !githubMonitorText.IsDisposed)
                            githubMonitorText.Text = githubMonitorReport;
                    }
                }
                githubMonitorButton.Text = failed ? "GH: błąd" : "GH: " + DateTime.Now.ToString("HH:mm");
                detailsTip.SetToolTip(githubMonitorButton, failed ? "Część odczytów nie powiodła się. Otwórz monitor." : "Ostatnia kontrola: " + DateTime.Now.ToString("HH:mm:ss"));
            }
            catch (Exception ex)
            {
                githubMonitorReport = "Monitor: błąd połączenia z GitHub: " + MonitorShort(ex.Message, 180);
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
