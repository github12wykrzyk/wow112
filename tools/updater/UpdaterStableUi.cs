using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        private readonly Dictionary<string, Control> featureControls = new Dictionary<string, Control>();
        private readonly Dictionary<Control, bool> enabledBeforeBusy = new Dictionary<Control, bool>();
        private readonly ToolTip detailsTip = new ToolTip { AutoPopDelay = 20000 };
        private readonly Label connectionInfo = new Label();
        private readonly Label remoteInfo = new Label();
        private readonly Button tokenSettings = new Button();
        private readonly Button dllUpdatesButton = new Button();
        private bool dashboardReady;
        private static readonly Color Canvas = Color.FromArgb(21, 23, 28);
        private static readonly Color Surface = Color.FromArgb(30, 33, 40);
        private static readonly Color Ink = Color.FromArgb(235, 237, 242);
        private static readonly Color Muted = Color.FromArgb(170, 179, 193);
        private static readonly Color Gold = Color.FromArgb(223, 182, 115);

        internal void BuildDashboard()
        {
            if (dashboardReady) return;
            SuspendLayout();
            AutoScaleDimensions = new SizeF(96, 96);
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = new Font("Segoe UI", 9F);
            BackColor = Canvas;
            ForeColor = Ink;
            ClientSize = new Size(1040, 680);
            MinimumSize = new Size(976, 659);
            FormBorderStyle = FormBorderStyle.Sizable;
            MaximizeBox = true;
            DoubleBuffered = true;
            var root = Grid(1, 5);
            root.Padding = new Padding(16);
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 72));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 136));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 192));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 104));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            Controls.Add(root);

            var header = Grid(2, 1);
            header.ColumnStyles.Clear();
            header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 450));
            root.Controls.Add(header, 0, 0);
            var heading = Grid(1, 3);
            heading.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
            heading.RowStyles.Add(new RowStyle(SizeType.Absolute, 18));
            heading.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            heading.Controls.Add(TextLabel("WoW112", 21, Gold, true), 0, 0);
            heading.Controls.Add(TextLabel("Updater " + UpdaterVersion + "  •  World of Warcraft 1.12.1 / 5875", 9, Muted), 0, 1);
            PrepareLabel(connectionInfo); heading.Controls.Add(connectionInfo, 0, 2);
            header.Controls.Add(heading, 0, 0);
            header.Controls.Add(BuildGitHubMonitorHeader(), 1, 0);

            var config = Card("KONFIGURACJA", 3);
            root.Controls.Add(config, 0, 1);
            var path = Grid(3, 1); Columns(path, 98, -1, 112);
            path.Controls.Add(TextLabel("Katalog gry", 9, Muted), 0, 0);
            PrepareInput(gameDir); path.Controls.Add(gameDir, 1, 0);
            path.Controls.Add(ActionButton(browseButton, "Wybierz…"), 2, 0);
            config.Controls.Add(path, 0, 1);
            var choices = Grid(5, 1); Columns(choices, 98, 180, 70, -1, 112);
            choices.Controls.Add(TextLabel("Kanał", 9, Muted), 0, 0);
            PrepareInput(channel); choices.Controls.Add(channel, 1, 0);
            choices.Controls.Add(TextLabel("Serwer", 9, Muted), 2, 0);
            PrepareInput(featureControls["realm"]); choices.Controls.Add(featureControls["realm"], 3, 0);
            choices.Controls.Add(ActionButton((Button)featureControls["realmApply"], "Zastosuj"), 4, 0);
            config.Controls.Add(choices, 0, 2);
            var auth = Grid(4, 1); Columns(auth, -1, 156, 156, 112);
            auth.Controls.Add(TextLabel("Dostęp GitHub jest zapisany lokalnie i chroniony przez Windows.", 9, Muted), 0, 0);
            auth.Controls.Add(ActionButton(tokenSettings, "Token GitHub"), 1, 0);
            auth.Controls.Add(ActionButton((Button)featureControls["reportToken"], "Token raportów"), 2, 0);
            auth.Controls.Add(ActionButton(saveButton, "Zapisz"), 3, 0);
            config.Controls.Add(auth, 0, 3);
            tokenSettings.Click += delegate { EditAccessToken(); };

            featureControls["dllUpdates"] = dllUpdatesButton;
            dllUpdatesButton.Click += async delegate { await ShowDllUpdateDialogAsync(); };

            var update = Card("AKTUALIZACJA", 4);
            update.RowStyles.Clear();
            foreach (var height in new[] { 22F, 64F, 32F, 10F, 40F }) update.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
            root.Controls.Add(update, 0, 2);
            var builds = Grid(2, 1);
            builds.Controls.Add(BuildInfo("Zainstalowano", localInfo), 0, 0);
            builds.Controls.Add(BuildInfo("Dostępne", remoteInfo), 1, 0);
            update.Controls.Add(builds, 0, 1);
            PrepareLabel(status); status.Font = new Font("Segoe UI", 9.5F, FontStyle.Bold);
            update.Controls.Add(status, 0, 2);
            progress.Dock = DockStyle.Fill; progress.Margin = new Padding(4, 1, 4, 3);
            progress.Style = ProgressBarStyle.Continuous;
            update.Controls.Add(progress, 0, 3);
            var actions = Grid(5, 1); actions.ColumnStyles.Clear();
            foreach (float width in new[] { 16F, 16F, 18F, 30F, 20F }) actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, width));
            actions.Controls.Add(ActionButton(checkButton, "Sprawdź"), 0, 0);
            actions.Controls.Add(ActionButton(dllUpdatesButton, "DLL-e"), 1, 0);
            actions.Controls.Add(ActionButton(updateButton, "Aktualizuj"), 2, 0);
            actions.Controls.Add(ActionButton(updatePlayButton, "Aktualizuj i uruchom", true), 3, 0);
            actions.Controls.Add(ActionButton(launchButton, "Uruchom grę"), 4, 0);
            update.Controls.Add(actions, 0, 4);

            var tools = Card("NARZĘDZIA", 2); root.Controls.Add(tools, 0, 3);
            var utilities = Grid(5, 1);
            string[] keys = { "verify", "diagnostics", "report", "selfUpdate", "accounts" };
            string[] captions = { "Sprawdź / napraw", "Diagnostyka ZIP", "Wyślij raport", "Aktualizuj updater", "Konta WoW" };
            for (int i = 0; i < keys.Length; i++) utilities.Controls.Add(ActionButton((Button)featureControls[keys[i]], captions[i]), i, 0);
            tools.Controls.Add(utilities, 0, 1);
            var backups = Grid(3, 1); Columns(backups, 120, -1, 140);
            backups.Controls.Add(TextLabel("Przywróć kopię", 9, Muted), 0, 0);
            PrepareInput(rollbackChoice); backups.Controls.Add(rollbackChoice, 1, 0);
            backups.Controls.Add(ActionButton(rollbackButton, "Przywróć"), 2, 0);
            tools.Controls.Add(backups, 0, 2);

            var logs = Grid(1, 2); logs.Margin = new Padding(0, 6, 0, 0);
            logs.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
            logs.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            root.Controls.Add(logs, 0, 4);
            var logHead = Grid(4, 1); Columns(logHead, -1, 130, 100, 100);
            logHead.Controls.Add(TextLabel("DZIENNIK SESJI", 9, Muted, true), 0, 0);
            logHead.Controls.Add(ActionButton(githubMonitorButton, "Monitor GH"), 1, 0);
            githubMonitorButton.Click += delegate { ShowGitHubMonitor(); };
            var copy = ActionButton(new Button(), "Kopiuj"); copy.Click += delegate { CopyText(log.Text); };
            var expand = ActionButton(new Button(), "Powiększ"); expand.Click += delegate { ExpandLog(); };
            logHead.Controls.Add(copy, 2, 0); logHead.Controls.Add(expand, 3, 0);
            logs.Controls.Add(logHead, 0, 0);
            log.Dock = DockStyle.Fill; log.BackColor = Canvas; log.ForeColor = Muted;
            log.Font = new Font("Consolas", 9F); log.BorderStyle = BorderStyle.FixedSingle;
            log.Margin = new Padding(4, 3, 4, 0); logs.Controls.Add(log, 0, 1);

            dashboardReady = true;
            token.TextChanged += delegate { ResetRemote(true); };
            gameDir.TextChanged += delegate { ResetRemote(false); RefreshLocalState(); };
            channel.SelectedIndexChanged += delegate { ResetRemote(false); SaveConfig(false); };
            gameDir.Leave += delegate { SaveConfig(false); };
            status.TextChanged += delegate { UpdateStatusStyle(); };
            localInfo.TextChanged += delegate { detailsTip.SetToolTip(localInfo, localInfo.Text); };
            FormClosing += delegate(object sender, FormClosingEventArgs e)
            {
                if (busy && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; status.Text = "Poczekaj na zakończenie bieżącej operacji."; }
            };
            FormClosed += delegate { detailsTip.Dispose(); token.Dispose(); };
            Shown += delegate { FitWorkingArea(); StartGitHubMonitor(); };
            DpiChanged += delegate { BeginInvoke(new Action(FitWorkingArea)); };
            ResetRemote(true);
            RefreshLocalState();
            ResumeLayout(true);
        }

        private void FitWorkingArea()
        {
            var area = Screen.FromControl(this).WorkingArea;
            // Keep the window visible without rebuilding or repositioning child controls.
            if (MinimumSize.Width > area.Width || MinimumSize.Height > area.Height) MinimumSize = Size.Empty;
            Size = new Size(Math.Min(Width, area.Width), Math.Min(Height, area.Height));
            Location = new Point(Math.Max(area.Left, Math.Min(Left, area.Right - Width)), Math.Max(area.Top, Math.Min(Top, area.Bottom - Height)));
        }

        private static TableLayoutPanel Grid(int columns, int rows)
        {
            var grid = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = columns, RowCount = rows, Margin = Padding.Empty, Padding = Padding.Empty, BackColor = Color.Transparent };
            for (int i = 0; i < columns; i++) grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F / columns));
            if (rows == 1) grid.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            return grid;
        }
        private static void Columns(TableLayoutPanel grid, params int[] widths)
        {
            grid.ColumnStyles.Clear();
            foreach (int width in widths) grid.ColumnStyles.Add(new ColumnStyle(width < 0 ? SizeType.Percent : SizeType.Absolute, width < 0 ? 100 : width));
        }
        private static TableLayoutPanel Card(string title, int contentRows)
        {
            var card = Grid(1, contentRows + 1); card.BackColor = Surface;
            card.Padding = new Padding(8, 4, 8, 4); card.Margin = new Padding(0, 0, 0, 8);
            card.RowStyles.Add(new RowStyle(SizeType.Absolute, 22));
            for (int i = 0; i < contentRows; i++) card.RowStyles.Add(new RowStyle(SizeType.Percent, 100F / contentRows));
            card.Controls.Add(TextLabel(title, 8.5F, Gold, true), 0, 0);
            return card;
        }
        private static Label TextLabel(string text, float size, Color color, bool bold = false)
        {
            var label = new Label { Text = text }; PrepareLabel(label);
            label.Font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular); label.ForeColor = color;
            return label;
        }
        private static void PrepareLabel(Label label)
        {
            label.AutoSize = false; label.Dock = DockStyle.Fill; label.Margin = new Padding(4, 0, 4, 0);
            label.ForeColor = Ink; label.TextAlign = ContentAlignment.MiddleLeft; label.AutoEllipsis = true;
        }
        private static Control BuildInfo(string title, Label value)
        {
            var card = Grid(1, 2); card.RowStyles.Add(new RowStyle(SizeType.Absolute, 20));
            card.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            card.Controls.Add(TextLabel(title, 9, Muted, true), 0, 0);
            PrepareLabel(value); value.TextAlign = ContentAlignment.TopLeft; card.Controls.Add(value, 0, 1);
            return card;
        }
        private static void PrepareInput(Control input)
        {
            input.Dock = DockStyle.Fill; input.Margin = new Padding(4, 3, 4, 3);
            input.BackColor = Canvas; input.ForeColor = Ink;
            var combo = input as ComboBox; if (combo != null) combo.FlatStyle = FlatStyle.Flat;
            var box = input as TextBox; if (box != null) box.BorderStyle = BorderStyle.FixedSingle;
        }
        private static Button ActionButton(Button button, string text, bool primary = false)
        {
            button.Text = text; button.Dock = DockStyle.Fill; button.Margin = new Padding(4, 2, 4, 2);
            button.FlatStyle = FlatStyle.Flat; button.UseVisualStyleBackColor = false; button.UseMnemonic = false;
            button.BackColor = primary ? Color.FromArgb(46, 89, 67) : Color.FromArgb(42, 46, 55);
            button.ForeColor = primary ? Color.White : Ink;
            button.FlatAppearance.BorderColor = primary ? Gold : Color.FromArgb(62, 68, 79);
            button.FlatAppearance.MouseOverBackColor = primary ? Color.FromArgb(58, 107, 81) : Color.FromArgb(56, 62, 73);
            button.Font = new Font("Segoe UI", 9F, primary ? FontStyle.Bold : FontStyle.Regular);
            button.Cursor = Cursors.Hand; return button;
        }
        private void ResetRemote(bool resetConnection)
        {
            lastRemote = null;
            ResetDllUpdateInspection();
            remoteInfo.Text = "Nie sprawdzono — wybierz Sprawdź.";
            detailsTip.SetToolTip(remoteInfo, remoteInfo.Text);
            if (resetConnection) SetConnectionState(string.IsNullOrWhiteSpace(token.Text) ? "GitHub: brak tokenu" : "GitHub: token niesprawdzony");
        }
        private void SetConnectionState(string text)
        {
            connectionInfo.Text = text;
            connectionInfo.ForeColor = text == "GitHub: połączono" ? Color.FromArgb(139, 207, 159) : Gold;
            detailsTip.SetToolTip(connectionInfo, text);
        }
        private void ShowRemotePackage()
        {
            remoteInfo.Text = lastRemote.Channel.ToUpperInvariant() + " • " + ShortSha(lastRemote.HeadSha) + " • run " + lastRemote.RunId + "\nBuild zakończony pomyślnie";
            detailsTip.SetToolTip(remoteInfo, remoteInfo.Text);
        }
        private void ShowRemoteFailure(Exception error)
        {
            lastRemote = null; remoteInfo.Text = error.Message;
            detailsTip.SetToolTip(remoteInfo, error.Message);
            if (error is System.Net.Http.HttpRequestException || error is System.Threading.Tasks.TaskCanceledException)
                SetConnectionState("GitHub: błąd połączenia");
        }
        private void UpdateStatusStyle()
        {
            var text = status.Text.ToLowerInvariant();
            status.ForeColor = text.Contains("błąd") || text.Contains("nie powiod") ? Color.FromArgb(255, 151, 151)
                : busy ? Gold : Ink;
            detailsTip.SetToolTip(status, status.Text);
        }
        private void SetDashboardBusy(bool value)
        {
            var targets = featureControls.Values.Concat(new Control[] { gameDir, tokenSettings }).ToArray();
            if (value)
            {
                if (enabledBeforeBusy.Count == 0)
                    foreach (var control in targets) { enabledBeforeBusy[control] = control.Enabled; control.Enabled = false; }
            }
            else
            {
                foreach (var item in enabledBeforeBusy) item.Key.Enabled = item.Value;
                enabledBeforeBusy.Clear();
            }
        }
        private void EditAccessToken()
        {
            using (var dialog = new Form { Text = "Dostęp do GitHuba", ClientSize = new Size(560, 162), Font = Font, BackColor = Surface, ForeColor = Ink, StartPosition = FormStartPosition.CenterParent, FormBorderStyle = FormBorderStyle.FixedDialog, MinimizeBox = false, MaximizeBox = false, AutoScaleMode = AutoScaleMode.Dpi })
            {
                var grid = Grid(1, 3); grid.Padding = new Padding(16);
                grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 42)); grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 34)); grid.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
                grid.Controls.Add(TextLabel("Token tylko do odczytu repozytorium: Contents + Actions.\nZapis chroniony przez Windows DPAPI.", 9, Muted), 0, 0);
                var box = new TextBox { Text = token.Text, UseSystemPasswordChar = true }; PrepareInput(box); grid.Controls.Add(box, 0, 1);
                var buttons = Grid(2, 1); var cancel = ActionButton(new Button(), "Anuluj"); cancel.DialogResult = DialogResult.Cancel;
                var save = ActionButton(new Button(), "Zapisz token", true); save.DialogResult = DialogResult.OK;
                buttons.Controls.Add(cancel, 0, 0); buttons.Controls.Add(save, 1, 0); grid.Controls.Add(buttons, 0, 2);
                dialog.Controls.Add(grid); dialog.AcceptButton = save; dialog.CancelButton = cancel;
                if (dialog.ShowDialog(this) == DialogResult.OK) { token.Text = box.Text.Trim(); SaveConfig(true); }
            }
        }
        private void CopyText(string text)
        {
            try { if (!string.IsNullOrEmpty(text)) Clipboard.SetText(text); }
            catch (Exception ex) { Log("Nie udało się skopiować: " + ex.Message); }
        }
        private void ExpandLog()
        {
            using (var dialog = new Form { Text = "Dziennik sesji", Size = new Size(900, 550), StartPosition = FormStartPosition.CenterParent, Font = Font, BackColor = Canvas })
            {
                var full = new RichTextBox { Dock = DockStyle.Fill, ReadOnly = true, Text = log.Text, BackColor = Canvas, ForeColor = Ink, Font = log.Font };
                EventHandler refresh = delegate { full.Text = log.Text; full.SelectionStart = full.TextLength; full.ScrollToCaret(); };
                log.TextChanged += refresh;
                try { dialog.Controls.Add(full); dialog.ShowDialog(this); }
                finally { log.TextChanged -= refresh; }
            }
        }
    }
}
