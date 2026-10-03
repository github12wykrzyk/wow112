using System;
using System.Drawing;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        private readonly Label githubReadyQueueBadge = new Label();
        private bool githubReadyQueueAttached;

        private sealed class ReadyQueueSnapshot
        {
            public string ParallelHead;
            public string Section;
            public int IntegrationCount;
            public int UpdateCount;
            public string FirstIntegration;
            public string FirstUpdate;
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            AttachGitHubReadyQueueBar();
            if (Array.Exists(Environment.GetCommandLineArgs(), a => a == "--ui-smoke"))
                AssertGitHubReadyQueueBarSmoke();
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
            githubReadyQueueBadge.Name = "githubReadyQueueBadge";
            githubReadyQueueBadge.AccessibleName = "Stan dostawy do gry";
            githubReadyQueueBadge.Font = new Font("Segoe UI", 8.4F, FontStyle.Bold);
            githubReadyQueueBadge.Margin = new Padding(3, 1, 3, 1);
            githubReadyQueueBadge.Padding = new Padding(6, 0, 3, 0);
            githubReadyQueueBadge.TextAlign = ContentAlignment.MiddleLeft;
            githubReadyQueueBadge.AutoEllipsis = true;
            grid.Controls.Add(githubReadyQueueBadge, 0, 2);

            githubMonitorButton.TextChanged += delegate { RefreshGitHubReadyQueueBar(); };
            channel.SelectedIndexChanged += delegate { RefreshGitHubReadyQueueBar(); };
            gameDir.TextChanged += delegate { RefreshGitHubReadyQueueBar(); };
            RefreshGitHubReadyQueueBar();
        }

        private void RefreshGitHubReadyQueueBar()
        {
            if (!githubReadyQueueAttached || githubReadyQueueBadge.IsDisposed) return;

            var snapshot = ParseReadyQueueReport(githubMonitorReport);
            var profile = ReadyQueueProfileName();
            var shortHead = string.IsNullOrWhiteSpace(snapshot.ParallelHead)
                ? "?" : MonitorShort(snapshot.ParallelHead, 8);
            var standardOrEconomy = !IsAngleOnly() && !IsAutoRear();
            var installed = standardOrEconomy && !string.IsNullOrWhiteSpace(snapshot.ParallelHead)
                && MonitorSelectedDeliveryInstalled(snapshot.ParallelHead);

            if (snapshot.UpdateCount > 0)
            {
                SetReadyQueueVisual(
                    Color.FromArgb(34, 67, 112),
                    Color.FromArgb(174, 211, 255),
                    "DOSTAWA DO GRY   GOTOWE DO UPDATE   " + profile + "   " + shortHead +
                        (snapshot.IntegrationCount > 0 ? "   | +" + snapshot.IntegrationCount + " CZEKA→PARALLEL" : string.Empty),
                    "GOTOWE DLA CIEBIE: zweryfikowany build " + profile + " dla PARALLEL " + shortHead +
                        " czeka na lokalną aktualizację. Użyj Aktualizuj / Aktualizuj i uruchom.\n\n" + snapshot.Section);
                return;
            }

            if (snapshot.IntegrationCount > 0)
            {
                SetReadyQueueVisual(
                    Color.FromArgb(96, 74, 31),
                    Color.FromArgb(255, 217, 128),
                    "DOSTAWA DO GRY   CZEKA NA INTEGRACJĘ   " + snapshot.IntegrationCount +
                        (string.IsNullOrWhiteSpace(snapshot.FirstIntegration) ? string.Empty : "   |   " + ReadyQueueCompact(snapshot.FirstIntegration)),
                    "PREFLIGHT PASS, ale zmiana nie jest jeszcze częścią PARALLEL. To etap po stronie AI — nie jest jeszcze gotowa do testu w grze.\n\n" + snapshot.Section);
                return;
            }

            if (installed)
            {
                SetReadyQueueVisual(
                    Color.FromArgb(32, 77, 50),
                    Color.FromArgb(164, 245, 181),
                    "DOSTAWA DO GRY   ZAINSTALOWANE / GOTOWE DO TESTU   " + profile + "   " + shortHead,
                    "Lokalny stan " + profile + " wskazuje dokładnie aktualny PARALLEL " + snapshot.ParallelHead +
                        ". Zweryfikowany build jest zainstalowany i można go testować w grze.");
                return;
            }

            SetReadyQueueVisual(
                Color.FromArgb(45, 49, 58),
                Muted,
                "DOSTAWA DO GRY   BRAK GOTOWYCH ZMIAN   " + profile,
                standardOrEconomy
                    ? "Brak zweryfikowanej zmiany czekającej na integrację lub lokalną aktualizację. Aktywne buildy i błędy są pokazane w belce GH LIVE powyżej."
                    : "Dla profili porównawczych ANGLE-ONLY / AUTO-REAR belka nie deklaruje stanu ZAINSTALOWANE bez osobnego manifestu profilu. Aktywne buildy i błędy są pokazane w belce GH LIVE powyżej.");
        }

        private void SetReadyQueueVisual(Color back, Color fore, string text, string detail)
        {
            githubReadyQueueBadge.BackColor = back;
            githubReadyQueueBadge.ForeColor = fore;
            githubReadyQueueBadge.Text = text;
            detailsTip.SetToolTip(githubReadyQueueBadge, detail + "\nOdczyt: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
        }

        private string ReadyQueueProfileName()
        {
            return IsEconomy() ? "ECONOMY"
                : IsAngleOnly() ? "ANGLE-ONLY"
                : IsAutoRear() ? "AUTO-REAR"
                : "STANDARD";
        }

        private static ReadyQueueSnapshot ParseReadyQueueReport(string report)
        {
            var snapshot = new ReadyQueueSnapshot();
            if (string.IsNullOrWhiteSpace(report)) return snapshot;

            foreach (var raw in report.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
            {
                var line = raw.Trim();
                if (line.StartsWith("PARALLEL:", StringComparison.OrdinalIgnoreCase))
                    snapshot.ParallelHead = line.Substring("PARALLEL:".Length).Trim();
            }

            snapshot.Section = ReadyQueueSection(report);
            if (string.IsNullOrWhiteSpace(snapshot.Section)) return snapshot;

            foreach (var raw in snapshot.Section.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
            {
                var line = raw.Trim();
                if (line.StartsWith("GOTOWE / CZEKA NA RUCH", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(line, "brak", StringComparison.OrdinalIgnoreCase))
                    continue;

                if (line.IndexOf("READY→UPDATE", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    snapshot.UpdateCount++;
                    if (string.IsNullOrWhiteSpace(snapshot.FirstUpdate)) snapshot.FirstUpdate = line;
                }
                else if (line.IndexOf("READY→PARALLEL", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    snapshot.IntegrationCount++;
                    if (string.IsNullOrWhiteSpace(snapshot.FirstIntegration)) snapshot.FirstIntegration = line;
                }
            }
            return snapshot;
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

        private void AssertGitHubReadyQueueBarSmoke()
        {
            if (!githubReadyQueueAttached || githubReadyQueueBadge.Parent == null || !githubReadyQueueBadge.Visible)
                throw new Exception("Delivery-to-game status bar is not attached to the visible GitHub header");

            const string sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
            var fake = "WOW112 / GITHUB LIVE\nPARALLEL: " + sha + "\n\n" +
                "GOTOWE / CZEKA NA RUCH (2):\n" +
                "  READY→PARALLEL  feature/smoke-ready  bbbbbbbbbbbb  run 11\n" +
                "  READY→UPDATE STANDARD  parallel  aaaaaaaaaaaa  run 12\n\n" +
                "CURRENT-HEAD FAIL (0):\n  brak\n";
            var parsed = ParseReadyQueueReport(fake);
            if (parsed.IntegrationCount != 1 || parsed.UpdateCount != 1 ||
                !string.Equals(parsed.ParallelHead, sha, StringComparison.OrdinalIgnoreCase) ||
                parsed.Section.IndexOf("READY→UPDATE STANDARD", StringComparison.OrdinalIgnoreCase) < 0)
                throw new Exception("Delivery-to-game status parser failed");
        }
    }
}
