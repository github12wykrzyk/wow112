from pathlib import Path

p = Path('tools/updater/WoW112Updater.cs')
s = p.read_text(encoding='utf-8')


def rep(old, new, label):
    global s
    if old not in s:
        raise SystemExit('missing updater patch anchor: ' + label)
    if s.count(old) != 1:
        raise SystemExit('non-unique updater patch anchor: ' + label)
    s = s.replace(old, new, 1)


rep(
    '        private const string StableInnerZip = "WoW112_STABLE_CANDIDATE.zip";\n',
    '        private const string StableInnerZip = "WoW112_STABLE_CANDIDATE.zip";\n'
    '        private const string UpdaterVersion = "1.1";\n'
    '        private const int MaxBackups = 10;\n',
    'version constants')

rep(
    '        private readonly ComboBox channel = new ComboBox();\n'
    '        private readonly Label status = new Label();\n',
    '        private readonly ComboBox channel = new ComboBox();\n'
    '        private readonly ComboBox rollbackChoice = new ComboBox();\n'
    '        private readonly Label localInfo = new Label();\n'
    '        private readonly Label status = new Label();\n',
    'state controls')

rep(
    '        private readonly Button updateButton = new Button();\n'
    '        private readonly Button rollbackButton = new Button();\n',
    '        private readonly Button updateButton = new Button();\n'
    '        private readonly Button updatePlayButton = new Button();\n'
    '        private readonly Button rollbackButton = new Button();\n',
    'update play field')

rep(
    '            Text = "WoW112 Updater";\n'
    '            ClientSize = new Size(820, 610);\n'
    '            MinimumSize = new Size(820, 610);\n',
    '            Text = "WoW112 Updater v" + UpdaterVersion;\n'
    '            ClientSize = new Size(860, 660);\n'
    '            MinimumSize = new Size(860, 660);\n',
    'window')

rep(
    '            BuildUi();\n'
    '            LoadConfig();\n',
    '            BuildUi();\n'
    '            LoadConfig();\n'
    '            RefreshLocalState();\n',
    'initial refresh')

rep(
    '            var title = new Label { Text = "WoW112 Updater", Font = new Font("Segoe UI Semibold", 18F), AutoSize = true, Left = 20, Top = 16 };\n',
    '            var title = new Label { Text = "WoW112 Updater v" + UpdaterVersion, Font = new Font("Segoe UI Semibold", 18F), AutoSize = true, Left = 20, Top = 16 };\n',
    'title')

rep('            gameDir.SetBounds(20, 86, 660, 26);\n', '            gameDir.SetBounds(20, 86, 700, 26);\n', 'game dir width')
rep('            browseButton.SetBounds(690, 84, 108, 30);\n', '            browseButton.SetBounds(730, 84, 108, 30);\n', 'browse')
rep('            token.SetBounds(218, 146, 460, 28);\n', '            token.SetBounds(218, 146, 500, 28);\n', 'token width')
rep('            saveButton.SetBounds(690, 144, 108, 30);\n', '            saveButton.SetBounds(730, 144, 108, 30);\n', 'save')

old_ui = '''            Controls.Add(note);\n\n            checkButton.Text = "SPRAWDŹ";\n            checkButton.SetBounds(20, 215, 140, 38);\n            checkButton.Click += async delegate { await CheckAsync(); };\n            Controls.Add(checkButton);\n\n            updateButton.Text = "AKTUALIZUJ";\n            updateButton.SetBounds(170, 215, 140, 38);\n            updateButton.Click += async delegate { await UpdateAsync(); };\n            Controls.Add(updateButton);\n\n            rollbackButton.Text = "ROLLBACK";\n            rollbackButton.SetBounds(320, 215, 140, 38);\n            rollbackButton.Click += delegate { Rollback(); };\n            Controls.Add(rollbackButton);\n\n            launchButton.Text = "URUCHOM WOW";\n            launchButton.SetBounds(470, 215, 150, 38);\n            launchButton.Click += delegate { LaunchGame(); };\n            Controls.Add(launchButton);\n\n            status.Text = "Gotowy";\n            status.AutoSize = false;\n            status.SetBounds(20, 266, 778, 26);\n            status.Font = new Font("Segoe UI Semibold", 10F);\n            Controls.Add(status);\n\n            progress.SetBounds(20, 296, 778, 18);\n            progress.Style = ProgressBarStyle.Marquee;\n            progress.MarqueeAnimationSpeed = 25;\n            progress.Visible = false;\n            Controls.Add(progress);\n\n            log.ReadOnly = true;\n            log.BackColor = Color.White;\n            log.Font = new Font("Consolas", 9F);\n            log.SetBounds(20, 326, 778, 260);\n            Controls.Add(log);\n'''
new_ui = '''            Controls.Add(note);\n\n            localInfo.AutoSize = false;\n            localInfo.SetBounds(20, 204, 818, 24);\n            localInfo.Font = new Font("Segoe UI Semibold", 9F);\n            Controls.Add(localInfo);\n\n            checkButton.Text = "SPRAWDŹ";\n            checkButton.SetBounds(20, 238, 125, 38);\n            checkButton.Click += async delegate { await CheckAsync(); };\n            Controls.Add(checkButton);\n\n            updateButton.Text = "AKTUALIZUJ";\n            updateButton.SetBounds(155, 238, 125, 38);\n            updateButton.Click += async delegate { await UpdateAsync(); };\n            Controls.Add(updateButton);\n\n            updatePlayButton.Text = "UPDATE + PLAY";\n            updatePlayButton.SetBounds(290, 238, 160, 38);\n            updatePlayButton.Font = new Font("Segoe UI Semibold", 9F);\n            updatePlayButton.Click += async delegate { await UpdateAndPlayAsync(); };\n            Controls.Add(updatePlayButton);\n\n            launchButton.Text = "URUCHOM WOW";\n            launchButton.SetBounds(460, 238, 150, 38);\n            launchButton.Click += delegate { LaunchGame(); };\n            Controls.Add(launchButton);\n\n            Controls.Add(new Label { Text = "Cofnij do:", AutoSize = true, Left = 22, Top = 294 });\n            rollbackChoice.DropDownStyle = ComboBoxStyle.DropDownList;\n            rollbackChoice.SetBounds(90, 289, 570, 28);\n            Controls.Add(rollbackChoice);\n\n            rollbackButton.Text = "ROLLBACK";\n            rollbackButton.SetBounds(670, 287, 168, 32);\n            rollbackButton.Click += delegate { Rollback(); };\n            Controls.Add(rollbackButton);\n\n            status.Text = "Gotowy";\n            status.AutoSize = false;\n            status.SetBounds(20, 332, 818, 26);\n            status.Font = new Font("Segoe UI Semibold", 10F);\n            Controls.Add(status);\n\n            progress.SetBounds(20, 362, 818, 18);\n            progress.Style = ProgressBarStyle.Marquee;\n            progress.MarqueeAnimationSpeed = 25;\n            progress.Visible = false;\n            Controls.Add(progress);\n\n            log.ReadOnly = true;\n            log.BackColor = Color.White;\n            log.Font = new Font("Consolas", 9F);\n            log.SetBounds(20, 392, 818, 245);\n            Controls.Add(log);\n'''
rep(old_ui, new_ui, 'main UI')

rep(
    '                    gameDir.Text = dialog.SelectedPath;\n'
    '                    SaveConfig(false);\n',
    '                    gameDir.Text = dialog.SelectedPath;\n'
    '                    SaveConfig(false);\n'
    '                    RefreshLocalState();\n',
    'browse refresh')

rep(
    '            checkButton.Enabled = !value;\n'
    '            updateButton.Enabled = !value;\n'
    '            rollbackButton.Enabled = !value;\n'
    '            launchButton.Enabled = !value;\n',
    '            checkButton.Enabled = !value;\n'
    '            updateButton.Enabled = !value;\n'
    '            updatePlayButton.Enabled = !value;\n'
    '            rollbackButton.Enabled = !value && rollbackChoice.Items.Count > 0;\n'
    '            rollbackChoice.Enabled = !value && rollbackChoice.Items.Count > 0;\n'
    '            launchButton.Enabled = !value;\n',
    'busy controls')

rep(
    '            finally\n'
    '            {\n'
    '                SetBusy(false, status.Text);\n'
    '            }\n'
    '        }\n\n'
    '        private async Task UpdateAsync()\n',
    '            finally\n'
    '            {\n'
    '                RefreshLocalState();\n'
    '                SetBusy(false, status.Text);\n'
    '            }\n'
    '        }\n\n'
    '        private async Task UpdateAsync()\n',
    'check refresh')

rep(
    '                Log("Gotowe. Zmieniono: " + result.Changed + ", bez zmian: " + result.Unchanged + ".");\n'
    '                if (!string.IsNullOrWhiteSpace(result.BackupDir)) Log("Backup: " + result.BackupDir);\n',
    '                Log("Gotowe. Zmieniono: " + result.Changed + ", bez zmian: " + result.Unchanged + ".");\n'
    '                if (!string.IsNullOrWhiteSpace(result.BackupDir)) Log("Backup: " + result.BackupDir);\n'
    '                TrimBackups(gameDir.Text.Trim(), MaxBackups);\n'
    '                RefreshLocalState();\n',
    'post update')

rep(
    '        private async Task<RemotePackageInfo> FindLatestPackageAsync()\n',
    '''        private async Task UpdateAndPlayAsync()\n        {\n            await UpdateAsync();\n            if (!status.Text.StartsWith("Aktualizacja nie powiodła", StringComparison.OrdinalIgnoreCase))\n            {\n                status.Text = "Gotowe. Uruchamiam WoW...";\n                LaunchGame();\n            }\n        }\n\n        private async Task<RemotePackageInfo> FindLatestPackageAsync()\n''',
    'update and play')

rep(
    '        private void Rollback()\n        {\n',
    '''        private void RefreshLocalState()\n        {\n            rollbackChoice.Items.Clear();\n            var root = gameDir.Text.Trim();\n            if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))\n            {\n                localInfo.Text = "Lokalnie: wybierz katalog gry.";\n                rollbackButton.Enabled = false;\n                rollbackChoice.Enabled = false;\n                return;\n            }\n\n            var installed = ReadInstalledState();\n            if (installed == null)\n            {\n                localInfo.Text = "Lokalnie: brak stanu updatera (pierwsza instalacja lub ręcznie kopiowane pliki).";\n            }\n            else\n            {\n                DateTime when;\n                var whenText = DateTime.TryParse(GetString(installed, "installed_utc"), out when)\n                    ? " • " + when.ToLocalTime().ToString("yyyy-MM-dd HH:mm")\n                    : string.Empty;\n                localInfo.Text = "Lokalnie: " + GetString(installed, "channel").ToUpperInvariant()\n                    + " • run " + GetLong(installed, "run_id")\n                    + " • " + ShortSha(GetString(installed, "head_sha"))\n                    + whenText;\n            }\n\n            var backupRoot = Path.Combine(root, ".wow112_updater", "backups");\n            if (Directory.Exists(backupRoot))\n            {\n                foreach (var dir in Directory.GetDirectories(backupRoot).OrderByDescending(x => x, StringComparer.OrdinalIgnoreCase))\n                {\n                    var choice = ReadBackupChoice(dir);\n                    if (choice != null) rollbackChoice.Items.Add(choice);\n                }\n            }\n            if (rollbackChoice.Items.Count > 0) rollbackChoice.SelectedIndex = 0;\n            rollbackButton.Enabled = !busy && rollbackChoice.Items.Count > 0;\n            rollbackChoice.Enabled = !busy && rollbackChoice.Items.Count > 0;\n        }\n\n        private BackupChoice ReadBackupChoice(string dir)\n        {\n            try\n            {\n                var manifestPath = Path.Combine(dir, "backup_manifest.json");\n                if (!File.Exists(manifestPath)) return null;\n                var manifest = AsDictionary(json.DeserializeObject(File.ReadAllText(manifestPath, Encoding.UTF8)));\n                var previous = GetValue(manifest, "previous_installed") as Dictionary<string, object>;\n                var label = previous == null\n                    ? "Stan sprzed pierwszej instalacji updatera"\n                    : GetString(previous, "channel").ToUpperInvariant() + " run " + GetLong(previous, "run_id")\n                        + " • " + ShortSha(GetString(previous, "head_sha"));\n                label += " • " + Path.GetFileName(dir);\n                return new BackupChoice(dir, label);\n            }\n            catch\n            {\n                return null;\n            }\n        }\n\n        private void TrimBackups(string root, int keep)\n        {\n            try\n            {\n                var backupRoot = Path.Combine(root, ".wow112_updater", "backups");\n                if (!Directory.Exists(backupRoot)) return;\n                var dirs = Directory.GetDirectories(backupRoot).OrderByDescending(x => x, StringComparer.OrdinalIgnoreCase).ToArray();\n                foreach (var dir in dirs.Skip(Math.Max(keep, 1))) Directory.Delete(dir, true);\n            }\n            catch (Exception ex)\n            {\n                Log("Ostrzeżenie: nie udało się przyciąć historii backupów: " + ex.Message);\n            }\n        }\n\n        private void Rollback()\n        {\n''',
    'local state methods')

rep(
    '                var backupRoot = Path.Combine(root, ".wow112_updater", "backups");\n'
    '                if (!Directory.Exists(backupRoot)) throw new InvalidOperationException("Brak backupów updatera.");\n'
    '                var dir = Directory.GetDirectories(backupRoot).OrderByDescending(x => x, StringComparer.OrdinalIgnoreCase).FirstOrDefault();\n'
    '                if (dir == null) throw new InvalidOperationException("Brak backupów updatera.");\n'
    '                RestoreBackupDirectory(root, dir, true);\n'
    '                status.Text = "Rollback zakończony.";\n'
    '                Log("Rollback OK: " + dir);\n',
    '''                var choice = rollbackChoice.SelectedItem as BackupChoice;\n                string dir = choice == null ? null : choice.Path;\n                if (dir == null)\n                {\n                    var backupRoot = Path.Combine(root, ".wow112_updater", "backups");\n                    if (Directory.Exists(backupRoot))\n                        dir = Directory.GetDirectories(backupRoot).OrderByDescending(x => x, StringComparer.OrdinalIgnoreCase).FirstOrDefault();\n                }\n                if (dir == null) throw new InvalidOperationException("Brak backupów updatera.");\n                RestoreBackupDirectory(root, dir, true);\n                status.Text = "Rollback zakończony.";\n                Log("Rollback OK: " + dir);\n                RefreshLocalState();\n''',
    'selected rollback')

rep(
    '            state["schema_version"] = 1;\n'
    '            state["channel"] = remote.Channel;\n',
    '            state["schema_version"] = 2;\n'
    '            state["updater_version"] = UpdaterVersion;\n'
    '            state["channel"] = remote.Channel;\n',
    'installed state version')

rep(
    '''        private sealed class ApplyResult\n        {\n            public int Changed;\n            public int Unchanged;\n            public string BackupDir;\n        }\n''',
    '''        private sealed class ApplyResult\n        {\n            public int Changed;\n            public int Unchanged;\n            public string BackupDir;\n        }\n\n        private sealed class BackupChoice\n        {\n            public readonly string Path;\n            public readonly string Label;\n\n            public BackupChoice(string path, string label)\n            {\n                Path = path;\n                Label = label;\n            }\n\n            public override string ToString()\n            {\n                return Label;\n            }\n        }\n''',
    'backup choice')

p.write_text(s, encoding='utf-8')
print('patched', p)
