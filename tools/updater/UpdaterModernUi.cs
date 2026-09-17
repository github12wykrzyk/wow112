using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        private bool modernUiReady;
        private readonly Dictionary<string, Panel> modernPages = new Dictionary<string, Panel>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, Button> modernNav = new Dictionary<string, Button>(StringComparer.OrdinalIgnoreCase);
        private Label modernChannelBadge;
        private Label modernTokenBadge;
        private bool translatingStatus;
        private bool translatingLocal;

        private static readonly Color CBack = Color.FromArgb(23, 22, 26);
        private static readonly Color CPanel = Color.FromArgb(33, 28, 29);
        private static readonly Color CPanel2 = Color.FromArgb(41, 34, 36);
        private static readonly Color CText = Color.FromArgb(248, 241, 213);
        private static readonly Color CMuted = Color.FromArgb(205, 190, 166);
        private static readonly Color CGold = Color.FromArgb(223, 163, 95);
        private static readonly Color CCopper = Color.FromArgb(207, 120, 66);
        private static readonly Color CBorder = Color.FromArgb(126, 51, 31);
        private static readonly Color CGreen = Color.FromArgb(17, 67, 38);

        protected override void OnLoad(EventArgs e)
        {
            if (!modernUiReady)
            {
                BuildModernUi();
                modernUiReady = true;
            }
            base.OnLoad(e);
        }

        private void BuildModernUi()
        {
            SuspendLayout();
            var old = Controls.Cast<Control>().ToArray();
            var realmlist = old.OfType<ComboBox>().FirstOrDefault(x => !ReferenceEquals(x, channel) && !ReferenceEquals(x, rollbackChoice));
            var realmlistApply = FindOldButton(old, "USTAW REALMLIST");
            var verify = FindOldButton(old, "VERIFY / REPAIR");
            var diagnostics = FindOldButton(old, "DIAGNOSTYKA ZIP");
            var selfUpdate = FindOldButton(old, "AKTUALIZUJ UPDATER");
            var report = FindOldButton(old, "WYŚLIJ RAPORT");
            var reportToken = FindOldButton(old, "TOKEN RAPORTU");
            Controls.Clear();

            Text = "WoW112 Updater v" + UpdaterVersion;
            ClientSize = new Size(1080, 760);
            MinimumSize = new Size(960, 700);
            StartPosition = FormStartPosition.CenterScreen;
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = new Font("Segoe UI", 9F);
            BackColor = CBack;
            DoubleBuffered = true;

            var art = new ArtworkPanel(LoadUpdaterArtwork()) { Dock = DockStyle.Fill };
            Controls.Add(art);

            var title = LabelOf("WoW112 Updater", 27F, CText, FontStyle.Bold, "Georgia");
            title.Location = new Point(42, 28);
            art.Controls.Add(title);
            var sub = LabelOf("World of Warcraft 1.12.1  •  Build 5875", 10F, CMuted, FontStyle.Regular);
            sub.Location = new Point(46, 80);
            art.Controls.Add(sub);
            modernChannelBadge = Badge("TEST / WORK", CCopper);
            modernChannelBadge.Location = new Point(46, 108);
            art.Controls.Add(modernChannelBadge);

            var nav = new FramePanel { Left = 28, Top = 150, Width = 180, Height = 550, Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left, BackColor = CPanel };
            art.Controls.Add(nav);
            var navFlow = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 330, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(10, 14, 10, 0), BackColor = Color.Transparent };
            nav.Controls.Add(navFlow);
            AddNav(navFlow, "Updater");
            AddNav(navFlow, "Modules");
            AddNav(navFlow, "Settings");
            AddNav(navFlow, "Logs");
            AddNav(navFlow, "About");
            modernTokenBadge = new Label { Dock = DockStyle.Bottom, Height = 54, BackColor = CPanel2, ForeColor = CMuted, Font = new Font("Segoe UI Semibold", 8.5F), Padding = new Padding(10, 0, 8, 0), TextAlign = ContentAlignment.MiddleLeft };
            nav.Controls.Add(modernTokenBadge);

            var host = new FramePanel { Left = 224, Top = 150, Width = 620, Height = 550, Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left, BackColor = CPanel };
            art.Controls.Add(host);
            foreach (var key in new[] { "About", "Logs", "Settings", "Modules", "Updater" })
            {
                var p = new Panel { Dock = DockStyle.Fill, BackColor = CPanel, Visible = false };
                modernPages[key] = p;
                host.Controls.Add(p);
            }

            BuildHome(modernPages["Updater"]);
            BuildSettings(modernPages["Settings"], realmlist, realmlistApply);
            BuildModules(modernPages["Modules"], verify, diagnostics, selfUpdate, report, reportToken);
            BuildLogs(modernPages["Logs"]);
            BuildAbout(modernPages["About"]);

            status.TextChanged += delegate { TranslateStatus(); };
            localInfo.TextChanged += delegate { TranslateLocal(); };
            token.TextChanged += delegate { RefreshBadges(); };
            channel.SelectedIndexChanged += delegate { RefreshBadges(); };
            TranslateStatus();
            TranslateLocal();
            RefreshBadges();
            SwitchPage("Updater");
            ResumeLayout(true);
        }

        private void BuildHome(Panel p)
        {
            Header(p, "Updater", "Verified packages from GitHub Actions. Safety checks remain fail-closed.");
            var build = new FramePanel { Left = 26, Top = 102, Width = 566, Height = 116, Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right, BackColor = CPanel2 };
            p.Controls.Add(build);
            var h = LabelOf("Installed build", 11F, CText, FontStyle.Bold); h.Location = new Point(18, 14); build.Controls.Add(h);
            localInfo.AutoSize = false; localInfo.SetBounds(18, 42, 525, 55); localInfo.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right; localInfo.BackColor = Color.Transparent; localInfo.ForeColor = CMuted; localInfo.Font = new Font("Segoe UI Semibold", 9.3F); build.Controls.Add(localInfo);

            var sh = LabelOf("Status", 11F, CText, FontStyle.Bold); sh.Location = new Point(28, 242); p.Controls.Add(sh);
            status.AutoSize = false; status.SetBounds(28, 272, 556, 38); status.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right; status.BackColor = CBack; status.ForeColor = CText; status.Padding = new Padding(12, 0, 8, 0); status.TextAlign = ContentAlignment.MiddleLeft; status.Font = new Font("Segoe UI Semibold", 10F); p.Controls.Add(status);
            progress.SetBounds(28, 319, 556, 12); progress.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right; p.Controls.Add(progress);

            var actions = new FlowLayoutPanel { Left = 28, Top = 356, Width = 556, Height = 105, Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right, BackColor = Color.Transparent, WrapContents = true };
            p.Controls.Add(actions);
            StyleButton(updatePlayButton, true, 190, 46, "UPDATE & PLAY"); actions.Controls.Add(updatePlayButton);
            StyleButton(launchButton, false, 135, 46, "PLAY WOW"); actions.Controls.Add(launchButton);
            StyleButton(updateButton, false, 120, 38, "UPDATE ONLY"); actions.Controls.Add(updateButton);
            StyleButton(checkButton, false, 160, 38, "CHECK FOR UPDATES"); actions.Controls.Add(checkButton);

            var hint = LabelOf("TEST follows work. STABLE follows main. The newest workflow must pass before installation.", 8.5F, CMuted, FontStyle.Regular);
            hint.Left = 30; hint.Top = 474; p.Controls.Add(hint);
        }

        private void BuildSettings(Panel p, ComboBox realmlist, Button realmlistApply)
        {
            Header(p, "Settings", "Game directory, update channel, GitHub access and realm selection.");
            var table = new TableLayoutPanel { Left = 28, Top = 105, Width = 555, Height = 350, Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right, ColumnCount = 2, RowCount = 8, BackColor = Color.Transparent };
            table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 76F)); table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 24F));
            table.RowStyles.Add(new RowStyle(SizeType.Absolute, 27F)); table.RowStyles.Add(new RowStyle(SizeType.Absolute, 42F)); table.RowStyles.Add(new RowStyle(SizeType.Absolute, 27F)); table.RowStyles.Add(new RowStyle(SizeType.Absolute, 42F)); table.RowStyles.Add(new RowStyle(SizeType.Absolute, 27F)); table.RowStyles.Add(new RowStyle(SizeType.Absolute, 42F)); table.RowStyles.Add(new RowStyle(SizeType.Absolute, 27F)); table.RowStyles.Add(new RowStyle(SizeType.Absolute, 45F));
            p.Controls.Add(table);
            Field(table, "Game directory", 0); Prep(gameDir); gameDir.Dock = DockStyle.Fill; table.Controls.Add(gameDir, 0, 1); StyleButton(browseButton, false, 112, 30, "BROWSE..."); browseButton.Anchor = AnchorStyles.Left; table.Controls.Add(browseButton, 1, 1);
            Field(table, "Channel", 2); Prep(channel); channel.Dock = DockStyle.Fill; table.Controls.Add(channel, 0, 3); StyleButton(saveButton, false, 112, 30, "SAVE"); saveButton.Anchor = AnchorStyles.Left; table.Controls.Add(saveButton, 1, 3);
            Field(table, "GitHub token — Contents + Actions (read only)", 4); Prep(token); token.Dock = DockStyle.Fill; table.Controls.Add(token, 0, 5); table.SetColumnSpan(token, 2);
            Field(table, "Realm", 6);
            if (realmlist != null) { Prep(realmlist); realmlist.Dock = DockStyle.Fill; table.Controls.Add(realmlist, 0, 7); }
            if (realmlistApply != null) { StyleButton(realmlistApply, false, 112, 30, "APPLY REALM"); realmlistApply.Anchor = AnchorStyles.Left; table.Controls.Add(realmlistApply, 1, 7); }
            var note = LabelOf("Tokens are stored locally with Windows DPAPI for the current Windows user.", 8.5F, CMuted, FontStyle.Regular); note.Left = 30; note.Top = 470; p.Controls.Add(note);
        }

        private void BuildModules(Panel p, Button verify, Button diagnostics, Button selfUpdate, Button report, Button reportToken)
        {
            Header(p, "Modules", "Maintenance, rollback and diagnostics. Gameplay update logic is unchanged.");
            var rb = new FramePanel { Left = 26, Top = 105, Width = 566, Height = 110, Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right, BackColor = CPanel2 };
            p.Controls.Add(rb);
            var l = LabelOf("Rollback", 10.5F, CText, FontStyle.Bold); l.Location = new Point(16, 12); rb.Controls.Add(l);
            rollbackChoice.SetBounds(16, 44, 390, 28); rollbackChoice.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right; Prep(rollbackChoice); rb.Controls.Add(rollbackChoice);
            StyleButton(rollbackButton, false, 125, 30, "ROLLBACK"); rollbackButton.Left = 420; rollbackButton.Top = 42; rollbackButton.Anchor = AnchorStyles.Top | AnchorStyles.Right; rb.Controls.Add(rollbackButton);
            var mh = LabelOf("Maintenance tools", 10.5F, CText, FontStyle.Bold); mh.Location = new Point(28, 242); p.Controls.Add(mh);
            var flow = new FlowLayoutPanel { Left = 28, Top = 274, Width = 555, Height = 170, Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right, BackColor = Color.Transparent, WrapContents = true };
            p.Controls.Add(flow);
            AddTool(flow, verify, "VERIFY / REPAIR", 160); AddTool(flow, diagnostics, "DIAGNOSTICS ZIP", 160); AddTool(flow, selfUpdate, "UPDATE UPDATER", 160); AddTool(flow, report, "SEND GITHUB REPORT", 190); AddTool(flow, reportToken, "REPORT TOKEN", 135);
        }

        private void BuildLogs(Panel p)
        {
            Header(p, "Logs", "Updater session log. Technical messages are preserved for troubleshooting.");
            log.ReadOnly = true; log.BorderStyle = BorderStyle.FixedSingle; log.BackColor = Color.FromArgb(16, 15, 18); log.ForeColor = CText; log.Font = new Font("Consolas", 9F); log.SetBounds(28, 110, 555, 340); log.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right; p.Controls.Add(log);
            var copy = new Button(); StyleButton(copy, false, 120, 34, "COPY LOG"); copy.Left = 28; copy.Top = 470; copy.Anchor = AnchorStyles.Bottom | AnchorStyles.Left; copy.Click += delegate { try { if (!string.IsNullOrEmpty(log.Text)) Clipboard.SetText(log.Text); } catch { } }; p.Controls.Add(copy);
        }

        private void BuildAbout(Panel p)
        {
            Header(p, "About", "A focused updater and launcher for the WoW112 project.");
            var card = new FramePanel { Left = 28, Top = 112, Width = 555, Height = 235, Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right, BackColor = CPanel2 };
            p.Controls.Add(card);
            AboutLine(card, "Updater", "v" + UpdaterVersion, 24); AboutLine(card, "Target", "World of Warcraft 1.12.1 build 5875", 62); AboutLine(card, "Architecture", "Windows x86", 100); AboutLine(card, "Repository", "github12wykrzyk/wow112", 138); AboutLine(card, "Safety", "SHA256 verified GitHub Actions artifacts", 176);
        }

        private void Header(Panel p, string title, string sub)
        {
            var a = LabelOf(title, 18F, CText, FontStyle.Bold, "Georgia"); a.Location = new Point(26, 22); p.Controls.Add(a);
            var b = LabelOf(sub, 9F, CMuted, FontStyle.Regular); b.Location = new Point(28, 62); p.Controls.Add(b);
            var line = new Panel { Left = 28, Top = 88, Width = 555, Height = 1, Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right, BackColor = CBorder }; p.Controls.Add(line);
        }

        private void AddNav(FlowLayoutPanel flow, string name)
        {
            var b = new Button { Text = name, Width = 148, Height = 45, FlatStyle = FlatStyle.Flat, UseVisualStyleBackColor = false, BackColor = CPanel, ForeColor = CText, Font = new Font("Segoe UI Semibold", 10F), TextAlign = ContentAlignment.MiddleLeft, Padding = new Padding(16, 0, 0, 0), Margin = new Padding(0, 0, 0, 6), Cursor = Cursors.Hand };
            b.FlatAppearance.BorderSize = 0; b.FlatAppearance.MouseOverBackColor = CPanel2; b.Click += delegate { SwitchPage(name); }; modernNav[name] = b; flow.Controls.Add(b);
        }

        private void SwitchPage(string name)
        {
            foreach (var x in modernPages) x.Value.Visible = string.Equals(x.Key, name, StringComparison.OrdinalIgnoreCase);
            foreach (var x in modernNav) { var on = string.Equals(x.Key, name, StringComparison.OrdinalIgnoreCase); x.Value.BackColor = on ? CPanel2 : CPanel; x.Value.ForeColor = on ? CGold : CText; x.Value.FlatAppearance.BorderSize = on ? 1 : 0; x.Value.FlatAppearance.BorderColor = on ? CCopper : CPanel; }
            if (modernPages.ContainsKey(name)) modernPages[name].BringToFront();
        }

        private void RefreshBadges()
        {
            if (modernChannelBadge != null) { modernChannelBadge.Text = IsStable() ? "STABLE / MAIN" : "TEST / WORK"; modernChannelBadge.BackColor = IsStable() ? Color.FromArgb(76, 101, 68) : CCopper; }
            if (modernTokenBadge != null) { var ok = !string.IsNullOrWhiteSpace(token.Text); modernTokenBadge.Text = ok ? "●  GitHub connected" : "○  GitHub token required"; modernTokenBadge.ForeColor = ok ? Color.FromArgb(135, 207, 151) : CMuted; }
        }

        private void TranslateStatus()
        {
            if (translatingStatus) return;
            var t = Translate(status.Text);
            if (t == status.Text) return;
            translatingStatus = true; status.Text = t; translatingStatus = false;
        }

        private void TranslateLocal()
        {
            if (translatingLocal) return;
            var t = localInfo.Text ?? string.Empty;
            if (t.StartsWith("Lokalnie: wybierz katalog gry", StringComparison.Ordinal)) t = "Local: select the game directory.";
            else if (t.StartsWith("Lokalnie: brak stanu updatera", StringComparison.Ordinal)) t = "Local: no updater state yet (first install or manually copied files).";
            else if (t.StartsWith("Lokalnie:", StringComparison.Ordinal)) t = "Local:" + t.Substring("Lokalnie:".Length);
            if (t == localInfo.Text) return;
            translatingLocal = true; localInfo.Text = t; translatingLocal = false;
        }

        private static string Translate(string t)
        {
            if (string.IsNullOrEmpty(t)) return t;
            if (t == "Gotowy") return "Ready";
            if (t == "Sprawdzanie GitHuba...") return "Checking GitHub...";
            if (t.StartsWith("Masz najnowszą wersję", StringComparison.Ordinal)) return "You have the latest selected channel build.";
            if (t.StartsWith("Dostępna aktualizacja", StringComparison.Ordinal)) return "Update available: " + t.Substring(t.LastIndexOf(':') + 1).Trim();
            if (t == "Błąd sprawdzania aktualizacji") return "Update check failed";
            if (t == "Pobieranie najnowszej paczki...") return "Downloading latest package...";
            if (t == "Pliki już były aktualne.") return "Files are already up to date.";
            if (t.StartsWith("Aktualizacja zakończona:", StringComparison.Ordinal)) return t.Replace("Aktualizacja zakończona:", "Update complete:").Replace(" plików.", " files.");
            if (t == "Aktualizacja nie powiodła się") return "Update failed";
            if (t == "Gotowe. Uruchamiam WoW...") return "Ready. Launching WoW...";
            if (t == "Rollback zakończony.") return "Rollback complete.";
            if (t == "Rollback nie powiódł się") return "Rollback failed";
            if (t == "Weryfikacja zainstalowanej paczki...") return "Verifying installed package...";
            if (t.StartsWith("VERIFY OK", StringComparison.Ordinal)) return "VERIFY OK — installed files match the selected build.";
            if (t.StartsWith("REPAIR OK", StringComparison.Ordinal)) return "REPAIR OK — file integrity restored.";
            if (t == "VERIFY / REPAIR nie powiódł się") return "VERIFY / REPAIR failed";
            if (t == "Sprawdzanie aktualizacji updatera...") return "Checking updater update...";
            if (t.StartsWith("Updater jest aktualny", StringComparison.Ordinal)) return "Updater is up to date.";
            if (t == "Aktualizacja updatera nie powiodła się") return "Updater update failed";
            if (t == "Tworzenie diagnostyki...") return "Creating diagnostics...";
            if (t.StartsWith("Diagnostyka zapisana:", StringComparison.Ordinal)) return t.Replace("Diagnostyka zapisana:", "Diagnostics saved:");
            if (t == "Diagnostyka nie powiodła się") return "Diagnostics failed";
            if (t == "Tworzenie raportu diagnostycznego...") return "Creating diagnostic report...";
            if (t.StartsWith("Raport wysłany", StringComparison.Ordinal)) return "Report sent to GitHub.";
            if (t == "Wysyłanie raportu nie powiodło się") return "Report upload failed";
            return t;
        }

        private static Button FindOldButton(IEnumerable<Control> c, string text) { return c.OfType<Button>().FirstOrDefault(x => string.Equals(x.Text, text, StringComparison.OrdinalIgnoreCase)); }
        private static Label LabelOf(string text, float size, Color color, FontStyle style, string family = "Segoe UI") { return new Label { Text = text, AutoSize = true, BackColor = Color.Transparent, ForeColor = color, Font = new Font(family, size, style) }; }
        private static Label Badge(string text, Color c) { return new Label { Text = text, AutoSize = false, Size = new Size(118, 24), TextAlign = ContentAlignment.MiddleCenter, BackColor = c, ForeColor = CText, Font = new Font("Segoe UI Semibold", 8F) }; }
        private static void Field(TableLayoutPanel t, string text, int row) { var l = LabelOf(text, 9F, CMuted, FontStyle.Bold); l.Dock = DockStyle.Fill; l.TextAlign = ContentAlignment.BottomLeft; l.Margin = new Padding(0, 0, 0, 4); t.Controls.Add(l, 0, row); t.SetColumnSpan(l, 2); }
        private static void Prep(TextBox x) { x.BorderStyle = BorderStyle.FixedSingle; x.BackColor = CBack; x.ForeColor = CText; x.Font = new Font("Segoe UI", 9F); }
        private static void Prep(ComboBox x) { x.FlatStyle = FlatStyle.Flat; x.BackColor = CBack; x.ForeColor = CText; x.Font = new Font("Segoe UI", 9F); }
        private static void StyleButton(Button b, bool primary, int w, int h, string text) { b.Text = text; b.FlatStyle = FlatStyle.Flat; b.UseVisualStyleBackColor = false; b.BackColor = primary ? CGreen : CPanel2; b.ForeColor = primary ? CGold : CText; b.Font = new Font("Segoe UI Semibold", primary ? 10F : 9F); b.Cursor = Cursors.Hand; b.FlatAppearance.BorderSize = 1; b.FlatAppearance.BorderColor = primary ? CGold : CBorder; b.FlatAppearance.MouseOverBackColor = primary ? Color.FromArgb(24, 82, 46) : Color.FromArgb(55, 43, 40); b.Width = w; b.Height = h; b.Margin = new Padding(0, 0, 10, 10); }
        private static void AddTool(FlowLayoutPanel f, Button b, string text, int w) { if (b == null) return; StyleButton(b, false, w, 38, text); f.Controls.Add(b); }
        private static void AboutLine(Control p, string n, string v, int y) { var a = LabelOf(n, 9F, CMuted, FontStyle.Bold); a.Location = new Point(18, y); p.Controls.Add(a); var b = LabelOf(v, 9.2F, CText, FontStyle.Regular); b.Location = new Point(150, y); p.Controls.Add(b); }

        private static Image LoadUpdaterArtwork()
        {
            try { var a = Assembly.GetExecutingAssembly(); using (var s = a.GetManifestResourceStream("WoW112Updater.Background.jpg")) { if (s == null) return null; using (var i = Image.FromStream(s)) return new Bitmap(i); } }
            catch { return null; }
        }

        private sealed class ArtworkPanel : Panel
        {
            private readonly Image image;
            public ArtworkPanel(Image i) { image = i; DoubleBuffered = true; ResizeRedraw = true; BackColor = CBack; }
            protected override void OnPaintBackground(PaintEventArgs e)
            {
                e.Graphics.Clear(CBack);
                if (image != null)
                {
                    e.Graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    var scale = Math.Min((float)ClientSize.Width / image.Width, (float)ClientSize.Height / image.Height);
                    var w = (int)Math.Round(image.Width * scale); var h = (int)Math.Round(image.Height * scale); var x = (ClientSize.Width - w) / 2; var y = (ClientSize.Height - h) / 2;
                    e.Graphics.DrawImage(image, new Rectangle(x, y, w, h));
                }
                var dw = Math.Max(1, (int)(ClientSize.Width * 0.79));
                using (var b = new LinearGradientBrush(new Point(0, 0), new Point(dw, 0), Color.FromArgb(210, 18, 16, 19), Color.FromArgb(20, 18, 16, 19))) e.Graphics.FillRectangle(b, 0, 0, dw, ClientSize.Height);
                using (var b = new LinearGradientBrush(new Point(0, Math.Max(0, ClientSize.Height - 170)), new Point(0, ClientSize.Height), Color.FromArgb(0, 16, 14, 17), Color.FromArgb(145, 16, 14, 17))) e.Graphics.FillRectangle(b, 0, Math.Max(0, ClientSize.Height - 170), ClientSize.Width, 170);
            }
        }

        private sealed class FramePanel : Panel
        {
            public FramePanel() { DoubleBuffered = true; ResizeRedraw = true; }
            protected override void OnPaint(PaintEventArgs e) { base.OnPaint(e); using (var a = new Pen(Color.FromArgb(83, 32, 20))) using (var b = new Pen(Color.FromArgb(130, CCopper))) { var r = ClientRectangle; r.Width--; r.Height--; e.Graphics.DrawRectangle(a, r); if (r.Width > 5 && r.Height > 5) { r.Inflate(-2, -2); e.Graphics.DrawRectangle(b, r); } } }
        }
    }
}
