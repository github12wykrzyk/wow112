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

            // The complete interactive shell is intentionally capped at 600 logical pixels.
            // At the 960px minimum width this still leaves >300px of unobstructed hero artwork.
            var root = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                BackColor = Color.Transparent,
                Padding = new Padding(28, 24, 28, 28),
                ColumnCount = 2,
                RowCount = 2,
                Margin = Padding.Empty
            };
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 600F));
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 116F));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            art.Controls.Add(root);

            var header = new Panel { Dock = DockStyle.Fill, BackColor = Color.Transparent, Margin = Padding.Empty };
            root.Controls.Add(header, 0, 0);
            var title = LabelOf("WoW112 Updater", 27F, CText, FontStyle.Bold, "Georgia");
            title.Location = new Point(10, 2);
            header.Controls.Add(title);
            var sub = LabelOf("World of Warcraft 1.12.1  •  Build 5875", 10F, CMuted, FontStyle.Regular);
            sub.Location = new Point(13, 54);
            header.Controls.Add(sub);
            modernChannelBadge = Badge("TEST / WORK", CCopper);
            modernChannelBadge.Location = new Point(13, 80);
            header.Controls.Add(modernChannelBadge);

            var body = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                BackColor = Color.Transparent,
                ColumnCount = 2,
                RowCount = 1,
                Margin = Padding.Empty
            };
            body.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 142F));
            body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            body.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            root.Controls.Add(body, 0, 1);

            var nav = new SurfacePanel(142, 42)
            {
                Dock = DockStyle.Fill,
                Margin = new Padding(0, 0, 12, 0),
                Padding = new Padding(8, 12, 8, 10)
            };
            body.Controls.Add(nav, 0, 0);

            var navFlow = new FlowLayoutPanel
            {
                Dock = DockStyle.Top,
                Height = 304,
                FlowDirection = FlowDirection.TopDown,
                WrapContents = false,
                BackColor = Color.Transparent,
                Margin = Padding.Empty,
                Padding = Padding.Empty
            };
            nav.Controls.Add(navFlow);
            AddNav(navFlow, "Updater");
            AddNav(navFlow, "Modules");
            AddNav(navFlow, "Settings");
            AddNav(navFlow, "Logs");
            AddNav(navFlow, "About");

            modernTokenBadge = new Label
            {
                Dock = DockStyle.Bottom,
                Height = 50,
                BackColor = Color.Transparent,
                ForeColor = CMuted,
                Font = new Font("Segoe UI Semibold", 8.2F),
                Padding = new Padding(3, 0, 0, 0),
                TextAlign = ContentAlignment.MiddleLeft,
                AutoEllipsis = true
            };
            nav.Controls.Add(modernTokenBadge);

            var host = new SurfacePanel(196, 62)
            {
                Dock = DockStyle.Fill,
                Margin = new Padding(0),
                Padding = Padding.Empty
            };
            body.Controls.Add(host, 1, 0);

            foreach (var key in new[] { "About", "Logs", "Settings", "Modules", "Updater" })
            {
                var page = new Panel { Dock = DockStyle.Fill, BackColor = Color.Transparent, Visible = false };
                modernPages[key] = page;
                host.Controls.Add(page);
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
            var body = PageBody(p, "Updater", "Verified packages from GitHub Actions. Safe, fail-closed installation.");
            var stack = new TableLayoutPanel
            {
                Dock = DockStyle.Top,
                Height = 390,
                BackColor = Color.Transparent,
                ColumnCount = 1,
                RowCount = 5,
                Margin = Padding.Empty,
                Padding = Padding.Empty
            };
            stack.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            stack.RowStyles.Add(new RowStyle(SizeType.Absolute, 102F));
            stack.RowStyles.Add(new RowStyle(SizeType.Absolute, 67F));
            stack.RowStyles.Add(new RowStyle(SizeType.Absolute, 20F));
            stack.RowStyles.Add(new RowStyle(SizeType.Absolute, 118F));
            stack.RowStyles.Add(new RowStyle(SizeType.Absolute, 60F));
            body.Controls.Add(stack);

            var build = new SurfacePanel(176, 46) { Dock = DockStyle.Fill, Margin = new Padding(0, 0, 0, 10), Padding = new Padding(14, 10, 14, 8) };
            stack.Controls.Add(build, 0, 0);
            var buildLayout = new TableLayoutPanel { Dock = DockStyle.Fill, BackColor = Color.Transparent, ColumnCount = 1, RowCount = 2, Margin = Padding.Empty, Padding = Padding.Empty };
            buildLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 27F));
            buildLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            build.Controls.Add(buildLayout);
            var h = LabelOf("Installed build", 10.5F, CText, FontStyle.Bold); h.Dock = DockStyle.Fill; h.TextAlign = ContentAlignment.MiddleLeft; buildLayout.Controls.Add(h, 0, 0);
            localInfo.AutoSize = false; localInfo.Dock = DockStyle.Fill; localInfo.BackColor = Color.Transparent; localInfo.ForeColor = CMuted; localInfo.Font = new Font("Segoe UI Semibold", 9F); localInfo.TextAlign = ContentAlignment.TopLeft; localInfo.AutoEllipsis = true; buildLayout.Controls.Add(localInfo, 0, 1);

            var statusBox = new TableLayoutPanel { Dock = DockStyle.Fill, BackColor = Color.Transparent, ColumnCount = 1, RowCount = 2, Margin = Padding.Empty, Padding = Padding.Empty };
            statusBox.RowStyles.Add(new RowStyle(SizeType.Absolute, 24F));
            statusBox.RowStyles.Add(new RowStyle(SizeType.Absolute, 36F));
            stack.Controls.Add(statusBox, 0, 1);
            var sh = LabelOf("Status", 9F, CMuted, FontStyle.Bold); sh.Dock = DockStyle.Fill; sh.TextAlign = ContentAlignment.MiddleLeft; statusBox.Controls.Add(sh, 0, 0);
            status.AutoSize = false; status.Dock = DockStyle.Fill; status.BackColor = CBack; status.ForeColor = CText; status.Padding = new Padding(10, 0, 8, 0); status.TextAlign = ContentAlignment.MiddleLeft; status.Font = new Font("Segoe UI Semibold", 9.5F); status.AutoEllipsis = true; statusBox.Controls.Add(status, 0, 1);

            var progressHost = new Panel { Dock = DockStyle.Fill, BackColor = Color.Transparent, Margin = new Padding(0, 4, 0, 4), Padding = new Padding(0, 2, 0, 2) };
            stack.Controls.Add(progressHost, 0, 2);
            progress.Dock = DockStyle.Fill;
            progressHost.Controls.Add(progress);

            var actions = new TableLayoutPanel { Dock = DockStyle.Fill, BackColor = Color.Transparent, ColumnCount = 2, RowCount = 2, Margin = Padding.Empty, Padding = Padding.Empty };
            actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 65F));
            actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 35F));
            actions.RowStyles.Add(new RowStyle(SizeType.Absolute, 54F));
            actions.RowStyles.Add(new RowStyle(SizeType.Absolute, 48F));
            stack.Controls.Add(actions, 0, 3);
            StyleButton(updatePlayButton, true, 0, 0, "UPDATE & PLAY"); updatePlayButton.Dock = DockStyle.Fill; updatePlayButton.Margin = new Padding(0, 0, 8, 8); actions.Controls.Add(updatePlayButton, 0, 0);
            StyleButton(launchButton, false, 0, 0, "PLAY WOW"); launchButton.Dock = DockStyle.Fill; launchButton.Margin = new Padding(0, 0, 0, 8); actions.Controls.Add(launchButton, 1, 0);
            var secondary = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, BackColor = Color.Transparent, Margin = Padding.Empty, Padding = Padding.Empty };
            actions.Controls.Add(secondary, 0, 1); actions.SetColumnSpan(secondary, 2);
            StyleButton(updateButton, false, 126, 34, "UPDATE ONLY"); secondary.Controls.Add(updateButton);
            StyleButton(checkButton, false, 154, 34, "CHECK FOR UPDATES"); secondary.Controls.Add(checkButton);

            var hint = new Label
            {
                Text = "TEST follows work. STABLE follows main. Only successful verified workflow artifacts are installed.",
                Dock = DockStyle.Fill,
                BackColor = Color.Transparent,
                ForeColor = CMuted,
                Font = new Font("Segoe UI", 8.3F),
                AutoSize = false,
                TextAlign = ContentAlignment.TopLeft,
                Padding = new Padding(0, 8, 0, 0)
            };
            stack.Controls.Add(hint, 0, 4);
        }

        private void BuildSettings(Panel p, ComboBox realmlist, Button realmlistApply)
        {
            var body = PageBody(p, "Settings", "Game directory, channel, GitHub access and realm selection.");
            var table = new TableLayoutPanel { Dock = DockStyle.Top, Height = 360, ColumnCount = 2, RowCount = 9, BackColor = Color.Transparent, Margin = Padding.Empty, Padding = Padding.Empty };
            table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 68F));
            table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 32F));
            table.RowStyles.Add(new RowStyle(SizeType.Absolute, 23F));
            table.RowStyles.Add(new RowStyle(SizeType.Absolute, 43F));
            table.RowStyles.Add(new RowStyle(SizeType.Absolute, 23F));
            table.RowStyles.Add(new RowStyle(SizeType.Absolute, 43F));
            table.RowStyles.Add(new RowStyle(SizeType.Absolute, 23F));
            table.RowStyles.Add(new RowStyle(SizeType.Absolute, 43F));
            table.RowStyles.Add(new RowStyle(SizeType.Absolute, 23F));
            table.RowStyles.Add(new RowStyle(SizeType.Absolute, 43F));
            table.RowStyles.Add(new RowStyle(SizeType.Absolute, 64F));
            body.Controls.Add(table);

            Field(table, "Game directory", 0); Prep(gameDir); gameDir.Dock = DockStyle.Fill; gameDir.Margin = new Padding(0, 0, 8, 9); table.Controls.Add(gameDir, 0, 1); StyleButton(browseButton, false, 0, 0, "BROWSE..."); browseButton.Dock = DockStyle.Fill; browseButton.Margin = new Padding(0, 0, 0, 9); table.Controls.Add(browseButton, 1, 1);
            Field(table, "Channel", 2); Prep(channel); channel.Dock = DockStyle.Fill; channel.Margin = new Padding(0, 0, 8, 9); table.Controls.Add(channel, 0, 3); StyleButton(saveButton, false, 0, 0, "SAVE"); saveButton.Dock = DockStyle.Fill; saveButton.Margin = new Padding(0, 0, 0, 9); table.Controls.Add(saveButton, 1, 3);
            Field(table, "GitHub token — Contents + Actions (read only)", 4); Prep(token); token.Dock = DockStyle.Fill; token.Margin = new Padding(0, 0, 0, 9); table.Controls.Add(token, 0, 5); table.SetColumnSpan(token, 2);
            Field(table, "Realm", 6);
            if (realmlist != null) { Prep(realmlist); realmlist.Dock = DockStyle.Fill; realmlist.Margin = new Padding(0, 0, 8, 9); table.Controls.Add(realmlist, 0, 7); }
            if (realmlistApply != null) { StyleButton(realmlistApply, false, 0, 0, "APPLY REALM"); realmlistApply.Dock = DockStyle.Fill; realmlistApply.Margin = new Padding(0, 0, 0, 9); table.Controls.Add(realmlistApply, 1, 7); }
            var note = new Label { Text = "The GitHub token is stored locally with Windows DPAPI for the current Windows user.", Dock = DockStyle.Fill, BackColor = Color.Transparent, ForeColor = CMuted, Font = new Font("Segoe UI", 8.3F), AutoSize = false, Padding = new Padding(0, 8, 0, 0) };
            table.Controls.Add(note, 0, 8); table.SetColumnSpan(note, 2);
        }

        private void BuildModules(Panel p, Button verify, Button diagnostics, Button selfUpdate, Button report, Button reportToken)
        {
            var body = PageBody(p, "Modules", "Maintenance, rollback and diagnostics. Gameplay update logic is unchanged.");
            var stack = new TableLayoutPanel { Dock = DockStyle.Top, Height = 355, BackColor = Color.Transparent, ColumnCount = 1, RowCount = 3, Margin = Padding.Empty, Padding = Padding.Empty };
            stack.RowStyles.Add(new RowStyle(SizeType.Absolute, 118F));
            stack.RowStyles.Add(new RowStyle(SizeType.Absolute, 38F));
            stack.RowStyles.Add(new RowStyle(SizeType.Absolute, 188F));
            body.Controls.Add(stack);

            var rb = new SurfacePanel(176, 46) { Dock = DockStyle.Fill, Margin = new Padding(0, 0, 0, 10), Padding = new Padding(14, 10, 14, 10) };
            stack.Controls.Add(rb, 0, 0);
            var rbGrid = new TableLayoutPanel { Dock = DockStyle.Fill, BackColor = Color.Transparent, ColumnCount = 2, RowCount = 2, Margin = Padding.Empty, Padding = Padding.Empty };
            rbGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 68F)); rbGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 32F));
            rbGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 28F)); rbGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 42F));
            rb.Controls.Add(rbGrid);
            var l = LabelOf("Rollback", 10F, CText, FontStyle.Bold); l.Dock = DockStyle.Fill; l.TextAlign = ContentAlignment.MiddleLeft; rbGrid.Controls.Add(l, 0, 0); rbGrid.SetColumnSpan(l, 2);
            Prep(rollbackChoice); rollbackChoice.Dock = DockStyle.Fill; rollbackChoice.Margin = new Padding(0, 0, 8, 0); rbGrid.Controls.Add(rollbackChoice, 0, 1);
            StyleButton(rollbackButton, false, 0, 0, "ROLLBACK"); rollbackButton.Dock = DockStyle.Fill; rollbackButton.Margin = Padding.Empty; rbGrid.Controls.Add(rollbackButton, 1, 1);

            var mh = LabelOf("Maintenance tools", 9.5F, CMuted, FontStyle.Bold); mh.Dock = DockStyle.Fill; mh.TextAlign = ContentAlignment.MiddleLeft; stack.Controls.Add(mh, 0, 1);
            var flow = new FlowLayoutPanel { Dock = DockStyle.Fill, BackColor = Color.Transparent, FlowDirection = FlowDirection.LeftToRight, WrapContents = true, Margin = Padding.Empty, Padding = Padding.Empty, AutoScroll = true };
            stack.Controls.Add(flow, 0, 2);
            AddTool(flow, verify, "VERIFY / REPAIR", 142); AddTool(flow, diagnostics, "DIAGNOSTICS ZIP", 142); AddTool(flow, selfUpdate, "UPDATE UPDATER", 142); AddTool(flow, report, "SEND GITHUB REPORT", 170); AddTool(flow, reportToken, "REPORT TOKEN", 122);
        }

        private void BuildLogs(Panel p)
        {
            var body = PageBody(p, "Logs", "Updater session log. Technical messages are preserved for troubleshooting.");
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, BackColor = Color.Transparent, Margin = Padding.Empty, Padding = Padding.Empty };
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 50F));
            body.Controls.Add(layout);
            log.ReadOnly = true; log.BorderStyle = BorderStyle.FixedSingle; log.BackColor = Color.FromArgb(16, 15, 18); log.ForeColor = CText; log.Font = new Font("Consolas", 9F); log.Dock = DockStyle.Fill; log.Margin = new Padding(0, 0, 0, 10); layout.Controls.Add(log, 0, 0);
            var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, BackColor = Color.Transparent, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, Margin = Padding.Empty, Padding = Padding.Empty };
            layout.Controls.Add(buttons, 0, 1);
            var copy = new Button(); StyleButton(copy, false, 118, 34, "COPY LOG"); copy.Click += delegate { try { if (!string.IsNullOrEmpty(log.Text)) Clipboard.SetText(log.Text); } catch { } }; buttons.Controls.Add(copy);
        }

        private void BuildAbout(Panel p)
        {
            var body = PageBody(p, "About", "Updater information and target runtime.");
            var card = new SurfacePanel(176, 46) { Dock = DockStyle.Top, Height = 236, Padding = new Padding(14, 12, 14, 12), Margin = Padding.Empty };
            body.Controls.Add(card);
            var grid = new TableLayoutPanel { Dock = DockStyle.Fill, BackColor = Color.Transparent, ColumnCount = 2, RowCount = 5, Margin = Padding.Empty, Padding = Padding.Empty };
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 116F)); grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            for (var i = 0; i < 5; i++) grid.RowStyles.Add(new RowStyle(SizeType.Percent, 20F));
            card.Controls.Add(grid);
            AboutLine(grid, 0, "Updater", "v" + UpdaterVersion);
            AboutLine(grid, 1, "Target", "World of Warcraft 1.12.1 build 5875");
            AboutLine(grid, 2, "Architecture", "Windows x86");
            AboutLine(grid, 3, "Repository", "github12wykrzyk/wow112");
            AboutLine(grid, 4, "Safety", "SHA256 verified GitHub Actions artifacts");
        }

        private static Panel PageBody(Panel page, string title, string subtitle)
        {
            page.Padding = new Padding(20, 16, 20, 18);
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, BackColor = Color.Transparent, Margin = Padding.Empty, Padding = Padding.Empty };
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 78F));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            page.Controls.Add(layout);

            var head = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, BackColor = Color.Transparent, Margin = Padding.Empty, Padding = Padding.Empty };
            head.RowStyles.Add(new RowStyle(SizeType.Absolute, 37F)); head.RowStyles.Add(new RowStyle(SizeType.Absolute, 31F)); head.RowStyles.Add(new RowStyle(SizeType.Absolute, 1F));
            layout.Controls.Add(head, 0, 0);
            var a = LabelOf(title, 17F, CText, FontStyle.Bold, "Georgia"); a.Dock = DockStyle.Fill; a.TextAlign = ContentAlignment.MiddleLeft; head.Controls.Add(a, 0, 0);
            var b = new Label { Text = subtitle, Dock = DockStyle.Fill, AutoSize = false, BackColor = Color.Transparent, ForeColor = CMuted, Font = new Font("Segoe UI", 8.6F), TextAlign = ContentAlignment.TopLeft, AutoEllipsis = true }; head.Controls.Add(b, 0, 1);
            var line = new Panel { Dock = DockStyle.Fill, BackColor = Color.FromArgb(83, 32, 20), Margin = Padding.Empty }; head.Controls.Add(line, 0, 2);

            var body = new Panel { Dock = DockStyle.Fill, BackColor = Color.Transparent, Margin = Padding.Empty, Padding = new Padding(0, 10, 0, 0) };
            layout.Controls.Add(body, 0, 1);
            return body;
        }

        private void AddNav(FlowLayoutPanel flow, string name)
        {
            var b = new Button
            {
                Text = name,
                Width = 116,
                Height = 42,
                FlatStyle = FlatStyle.Flat,
                UseVisualStyleBackColor = false,
                BackColor = CPanel,
                ForeColor = CText,
                Font = new Font("Segoe UI Semibold", 9.4F),
                TextAlign = ContentAlignment.MiddleLeft,
                Padding = new Padding(10, 0, 0, 0),
                Margin = new Padding(0, 0, 0, 5),
                Cursor = Cursors.Hand
            };
            b.FlatAppearance.BorderSize = 0;
            b.FlatAppearance.MouseOverBackColor = CPanel2;
            b.Click += delegate { SwitchPage(name); };
            modernNav[name] = b;
            flow.Controls.Add(b);
        }

        private void SwitchPage(string name)
        {
            foreach (var x in modernPages) x.Value.Visible = string.Equals(x.Key, name, StringComparison.OrdinalIgnoreCase);
            foreach (var x in modernNav)
            {
                var on = string.Equals(x.Key, name, StringComparison.OrdinalIgnoreCase);
                x.Value.BackColor = on ? CPanel2 : CPanel;
                x.Value.ForeColor = on ? CGold : CText;
                x.Value.FlatAppearance.BorderSize = on ? 1 : 0;
                x.Value.FlatAppearance.BorderColor = on ? CCopper : CPanel;
            }
            if (modernPages.ContainsKey(name)) modernPages[name].BringToFront();
        }

        private void RefreshBadges()
        {
            if (modernChannelBadge != null)
            {
                modernChannelBadge.Text = IsStable() ? "STABLE / MAIN" : "TEST / WORK";
                modernChannelBadge.BackColor = IsStable() ? Color.FromArgb(76, 101, 68) : CCopper;
            }
            if (modernTokenBadge != null)
            {
                var ok = !string.IsNullOrWhiteSpace(token.Text);
                modernTokenBadge.Text = ok ? "●  GitHub connected" : "○  GitHub token required";
                modernTokenBadge.ForeColor = ok ? Color.FromArgb(135, 207, 151) : CMuted;
            }
        }

        private void TranslateStatus()
        {
            if (translatingStatus) return;
            var t = Translate(status.Text);
            if (t == status.Text) return;
            translatingStatus = true;
            status.Text = t;
            translatingStatus = false;
        }

        private void TranslateLocal()
        {
            if (translatingLocal) return;
            var t = localInfo.Text ?? string.Empty;
            if (t.StartsWith("Lokalnie: wybierz katalog gry", StringComparison.Ordinal)) t = "Local: select the game directory.";
            else if (t.StartsWith("Lokalnie: brak stanu updatera", StringComparison.Ordinal)) t = "Local: no updater state yet (first install or manually copied files).";
            else if (t.StartsWith("Lokalnie:", StringComparison.Ordinal)) t = "Local:" + t.Substring("Lokalnie:".Length);
            if (t == localInfo.Text) return;
            translatingLocal = true;
            localInfo.Text = t;
            translatingLocal = false;
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

        private static Button FindOldButton(IEnumerable<Control> c, string text)
        {
            return c.OfType<Button>().FirstOrDefault(x => string.Equals(x.Text, text, StringComparison.OrdinalIgnoreCase));
        }

        private static Label LabelOf(string text, float size, Color color, FontStyle style, string family = "Segoe UI")
        {
            return new Label { Text = text, AutoSize = true, BackColor = Color.Transparent, ForeColor = color, Font = new Font(family, size, style) };
        }

        private static Label Badge(string text, Color c)
        {
            return new Label { Text = text, AutoSize = false, Size = new Size(116, 24), TextAlign = ContentAlignment.MiddleCenter, BackColor = c, ForeColor = CText, Font = new Font("Segoe UI Semibold", 8F) };
        }

        private static void Field(TableLayoutPanel t, string text, int row)
        {
            var l = LabelOf(text, 8.8F, CMuted, FontStyle.Bold);
            l.Dock = DockStyle.Fill;
            l.TextAlign = ContentAlignment.BottomLeft;
            l.Margin = new Padding(0, 0, 0, 3);
            t.Controls.Add(l, 0, row);
            t.SetColumnSpan(l, 2);
        }

        private static void Prep(TextBox x)
        {
            x.BorderStyle = BorderStyle.FixedSingle;
            x.BackColor = CBack;
            x.ForeColor = CText;
            x.Font = new Font("Segoe UI", 9F);
        }

        private static void Prep(ComboBox x)
        {
            x.FlatStyle = FlatStyle.Flat;
            x.BackColor = CBack;
            x.ForeColor = CText;
            x.Font = new Font("Segoe UI", 9F);
        }

        private static void StyleButton(Button b, bool primary, int w, int h, string text)
        {
            if (b == null) return;
            b.Text = text;
            b.FlatStyle = FlatStyle.Flat;
            b.UseVisualStyleBackColor = false;
            b.BackColor = primary ? CGreen : CPanel2;
            b.ForeColor = primary ? CGold : CText;
            b.Font = new Font("Segoe UI Semibold", primary ? 10F : 8.8F);
            b.Cursor = Cursors.Hand;
            b.FlatAppearance.BorderSize = primary ? 1 : 0;
            b.FlatAppearance.BorderColor = primary ? CGold : CBorder;
            b.FlatAppearance.MouseOverBackColor = primary ? Color.FromArgb(24, 82, 46) : Color.FromArgb(55, 43, 40);
            if (w > 0) b.Width = w;
            if (h > 0) b.Height = h;
            b.Margin = new Padding(0, 0, 8, 8);
        }

        private static void AddTool(FlowLayoutPanel f, Button b, string text, int w)
        {
            if (b == null) return;
            StyleButton(b, false, w, 36, text);
            f.Controls.Add(b);
        }

        private static void AboutLine(TableLayoutPanel p, int row, string n, string v)
        {
            var a = LabelOf(n, 8.8F, CMuted, FontStyle.Bold); a.Dock = DockStyle.Fill; a.TextAlign = ContentAlignment.MiddleLeft; p.Controls.Add(a, 0, row);
            var b = new Label { Text = v, Dock = DockStyle.Fill, AutoSize = false, BackColor = Color.Transparent, ForeColor = CText, Font = new Font("Segoe UI", 8.8F), TextAlign = ContentAlignment.MiddleLeft, AutoEllipsis = true }; p.Controls.Add(b, 1, row);
        }

        private static Image LoadUpdaterArtwork()
        {
            try
            {
                var a = Assembly.GetExecutingAssembly();
                using (var s = a.GetManifestResourceStream("WoW112Updater.Background.jpg"))
                {
                    if (s == null) return null;
                    using (var i = Image.FromStream(s)) return new Bitmap(i);
                }
            }
            catch { return null; }
        }

        private sealed class ArtworkPanel : Panel
        {
            private readonly Image image;

            public ArtworkPanel(Image i)
            {
                image = i;
                DoubleBuffered = true;
                ResizeRedraw = true;
                BackColor = CBack;
            }

            protected override void OnPaintBackground(PaintEventArgs e)
            {
                e.Graphics.Clear(CBack);
                if (image != null && ClientSize.Width > 0 && ClientSize.Height > 0)
                {
                    e.Graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    e.Graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    e.Graphics.CompositingQuality = CompositingQuality.HighQuality;

                    // Fill the window while preserving aspect ratio. Horizontal placement is right-anchored
                    // so the rider and gryphon remain in the safe hero area even when the window is resized.
                    var scale = Math.Max((float)ClientSize.Width / image.Width, (float)ClientSize.Height / image.Height);
                    var w = Math.Max(1, (int)Math.Round(image.Width * scale));
                    var h = Math.Max(1, (int)Math.Round(image.Height * scale));
                    var x = ClientSize.Width - w;
                    var y = (ClientSize.Height - h) / 2;
                    e.Graphics.DrawImage(image, new Rectangle(x, y, w, h));
                }

                // Local readability gradient only under the left launcher shell. The right hero area is untouched.
                var fadeWidth = Math.Min(ClientSize.Width, 690);
                if (fadeWidth > 0)
                {
                    var rect = new Rectangle(0, 0, fadeWidth, ClientSize.Height);
                    using (var b = new LinearGradientBrush(rect, Color.FromArgb(172, CBack), Color.FromArgb(10, CBack), LinearGradientMode.Horizontal))
                        e.Graphics.FillRectangle(b, rect);
                }
            }
        }

        private sealed class SurfacePanel : Panel
        {
            private readonly int alpha;
            private readonly int borderAlpha;

            public SurfacePanel(int surfaceAlpha, int lineAlpha)
            {
                alpha = Math.Max(0, Math.Min(255, surfaceAlpha));
                borderAlpha = Math.Max(0, Math.Min(255, lineAlpha));
                SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
                BackColor = Color.Transparent;
                DoubleBuffered = true;
                ResizeRedraw = true;
            }

            protected override void OnPaintBackground(PaintEventArgs e)
            {
                base.OnPaintBackground(e);
                using (var b = new SolidBrush(Color.FromArgb(alpha, CPanel)))
                    e.Graphics.FillRectangle(b, ClientRectangle);
            }

            protected override void OnPaint(PaintEventArgs e)
            {
                base.OnPaint(e);
                if (borderAlpha <= 0 || ClientSize.Width < 2 || ClientSize.Height < 2) return;
                using (var p = new Pen(Color.FromArgb(borderAlpha, CCopper)))
                {
                    var r = ClientRectangle;
                    r.Width--;
                    r.Height--;
                    e.Graphics.DrawRectangle(p, r);
                }
            }
        }
    }
}
