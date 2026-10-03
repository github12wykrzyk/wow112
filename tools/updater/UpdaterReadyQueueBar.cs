using System;
using System.Drawing;
using System.Text;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        private readonly Label githubReadyQueueBadge = new Label();
        private bool githubReadyQueueAttached;

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            AttachGitHubReadyQueueBar();
        }

        private void AttachGitHubReadyQueueBar()
        {
            if (githubReadyQueueAttached || githubPipelineBadge == null || githubPipelineBadge.IsDisposed) return;
            var grid = githubPipelineBadge.Parent as TableLayoutPanel;
            if (grid == null) return;

            githubReadyQueueAttached = true;
            grid.RowCount = 3;
            grid.RowStyles.Clear();
            grid.RowStyles.Add(new RowStyle(SizeType.Percent, 33.34F));
            grid.RowStyles.Add(new RowStyle(SizeType.Percent, 33.33F));
            grid.RowStyles.Add(new RowStyle(SizeType.Percent, 33.33F));

            PrepareLabel(githubReadyQueueBadge);
            githubReadyQueueBadge.Font = new Font("Segoe UI", 8.4F, FontStyle.Bold);
            githubReadyQueueBadge.Margin = new Padding(3, 1, 3, 1);
            githubReadyQueueBadge.Padding = new Padding(6, 0, 3, 0);
            githubReadyQueueBadge.TextAlign = ContentAlignment.MiddleLeft;
            githubReadyQueueBadge.AutoEllipsis = true;
            grid.Controls.Add(githubReadyQueueBadge, 0, 2);

            githubMonitorButton.TextChanged += delegate { RefreshGitHubReadyQueueBar(); };
            channel.SelectedIndexChanged += delegate { RefreshGitHubReadyQueueBar(); };
            RefreshGitHubReadyQueueBar();
        }

        private void RefreshGitHubReadyQueueBar()
        {
            if (!githubReadyQueueAttached || githubReadyQueueBadge.IsDisposed) return;

            var section = ReadyQueueSection(githubMonitorReport);
            var count = 0;
            var first = string.Empty;
            if (!string.IsNullOrWhiteSpace(section))
            {
                foreach (var raw in section.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    var line = raw.Trim();
                    if (line.StartsWith("GOTOWE / CZEKA NA RUCH", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(line, "brak", StringComparison.OrdinalIgnoreCase))
                        continue;
                    if (line.IndexOf("READY→PARALLEL", StringComparison.OrdinalIgnoreCase) < 0 &&
                        line.IndexOf("READY→UPDATE", StringComparison.OrdinalIgnoreCase) < 0)
                        continue;
                    count++;
                    if (string.IsNullOrWhiteSpace(first)) first = line;
                }
            }

            var ready = count > 0;
            githubReadyQueueBadge.BackColor = ready ? Color.FromArgb(34, 67, 112) : Color.FromArgb(45, 49, 58);
            githubReadyQueueBadge.ForeColor = ready ? Color.FromArgb(174, 211, 255) : Muted;
            githubReadyQueueBadge.Text = ready
                ? "GOTOWE / CZEKA NA WRZUCENIE   " + count + (string.IsNullOrWhiteSpace(first) ? string.Empty : "   |   " + ReadyQueueCompact(first))
                : "GOTOWE / CZEKA NA WRZUCENIE   0";
            detailsTip.SetToolTip(githubReadyQueueBadge,
                ready
                    ? "Gotowe elementy wymagające kolejnego ruchu przed testem w grze:\n" + section
                    : "Brak zweryfikowanych elementów czekających na integrację do PARALLEL lub lokalną aktualizację gry.");
        }

        private static string ReadyQueueSection(string report)
        {
            if (string.IsNullOrWhiteSpace(report)) return string.Empty;
            const string marker = "GOTOWE / CZEKA NA RUCH (";
            var start = report.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
            if (start < 0) return string.Empty;
            var end = report.IndexOf("\nCURRENT-HEAD FAIL", start, StringComparison.OrdinalIgnoreCase);
            if (end < 0) end = report.Length;
            return report.Substring(start, end - start).Trim();
        }

        private static string ReadyQueueCompact(string line)
        {
            if (string.IsNullOrWhiteSpace(line)) return string.Empty;
            var text = line.Replace("READY→PARALLEL", "→ PARALLEL")
                .Replace("READY→UPDATE ECONOMY", "→ UPDATE ECONOMY")
                .Replace("READY→UPDATE STANDARD", "→ UPDATE STANDARD")
                .Trim();
            if (text.Length > 55) text = text.Substring(0, 52) + "...";
            return text;
        }
    }
}
