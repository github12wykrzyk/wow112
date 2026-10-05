using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed class TeleStationUiConfig
    {
        public string Id { get; set; }
        public bool Enabled { get; set; }
        public string WarlockAccountId { get; set; }
        public string HelperAAccountId { get; set; }
        public string HelperBAccountId { get; set; }
    }

    internal sealed class TeleUiConfig
    {
        public int Version { get; set; }
        public bool EmergencyPaused { get; set; }
        public bool AutoReply { get; set; }
        public bool AutoInvite { get; set; }
        public bool AutoSummon { get; set; }
        public List<TeleStationUiConfig> Stations { get; set; }
    }

    internal sealed partial class MainForm
    {
        // Deliberately false until TELE-03 party RX and TELE-04 invite runtime evidence pass.
        private const bool TeleRuntimeEnabled = false;
        private readonly Timer teleAttachTimer = CreateTeleAttachTimer();
        private bool teleAttached;
        private readonly JavaScriptSerializer teleJson = new JavaScriptSerializer();

        private static Timer CreateTeleAttachTimer()
        {
            var timer = new Timer { Interval = 180 };
            timer.Tick += delegate
            {
                var form = Application.OpenForms.OfType<MainForm>().FirstOrDefault();
                if (form == null || form.IsDisposed || form.Disposing) return;
                if (!form.dashboardReady) return;
                timer.Stop();
                form.AttachTeleFeature();
            };
            timer.Start();
            return timer;
        }

        private void AttachTeleFeature()
        {
            if (teleAttached) return;
            teleAttached = true;
            var multibox = featureControls.ContainsKey("multibox") ? featureControls["multibox"] as Button : null;
            if (multibox == null)
            {
                Log("TELE UI: brak kontrolki MULTIBOX; panel nie został podpięty.");
                return;
            }
            var menu = multibox.ContextMenuStrip ?? new ContextMenuStrip();
            var item = new ToolStripMenuItem("TELE headless control plane" + (TeleRuntimeEnabled ? "" : " (runtime locked)"));
            item.Click += delegate { ShowTeleControlPlane(); };
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(item);
            multibox.ContextMenuStrip = menu;
            Log("TELE UI gotowy: PPM na MULTIBOX -> TELE headless control plane. Runtime mutations: " + (TeleRuntimeEnabled ? "ENABLED" : "LOCKED") + ".");
        }

        private string TeleConfigPath()
        {
            return Path.Combine(configDir, "tele_config.json");
        }

        private static TeleUiConfig DefaultTeleConfig()
        {
            return new TeleUiConfig
            {
                Version = 1,
                EmergencyPaused = true,
                AutoReply = false,
                AutoInvite = false,
                AutoSummon = false,
                Stations = new List<TeleStationUiConfig>
                {
                    new TeleStationUiConfig { Id = "hyjal", Enabled = false },
                    new TeleStationUiConfig { Id = "hydraxian", Enabled = false },
                    new TeleStationUiConfig { Id = "winterspring", Enabled = false },
                }
            };
        }

        private TeleUiConfig LoadTeleConfig()
        {
            var path = TeleConfigPath();
            if (!File.Exists(path)) return DefaultTeleConfig();
            if (new FileInfo(path).Length > 256 * 1024) throw new InvalidDataException("TELE config jest zbyt duży.");
            var cfg = teleJson.Deserialize<TeleUiConfig>(File.ReadAllText(path, Encoding.UTF8));
            if (cfg == null || cfg.Version != 1 || cfg.Stations == null || cfg.Stations.Count != 3)
                throw new InvalidDataException("Nieprawidłowy TELE config.");
            var expected = new HashSet<string>(new[] { "hyjal", "hydraxian", "winterspring" }, StringComparer.OrdinalIgnoreCase);
            if (cfg.Stations.Any(x => x == null || string.IsNullOrWhiteSpace(x.Id) || !expected.Remove(x.Id)) || expected.Count != 0)
                throw new InvalidDataException("TELE config ma nieprawidłowe/duplikowane stacje.");
            ValidateTeleConfig(cfg);
            return cfg;
        }

        private void SaveTeleConfig(TeleUiConfig cfg)
        {
            ValidateTeleConfig(cfg);
            Directory.CreateDirectory(configDir);
            UpdaterSafety.WriteUtf8Atomic(TeleConfigPath(), teleJson.Serialize(cfg), ".tmp", ".previous");
        }

        private void ValidateTeleConfig(TeleUiConfig cfg)
        {
            if (cfg == null || cfg.Version != 1 || cfg.Stations == null)
                throw new InvalidDataException("Nieprawidłowy TELE config.");

            var known = accountVault == null
                ? new HashSet<string>(StringComparer.Ordinal)
                : new HashSet<string>(accountVault.Data.Accounts.Select(a => a.Id), StringComparer.Ordinal);
            var activeRoles = new HashSet<string>(StringComparer.Ordinal);
            foreach (var station in cfg.Stations)
            {
                if (station == null || string.IsNullOrWhiteSpace(station.Id))
                    throw new InvalidDataException("TELE station config jest pusty.");
                foreach (var id in new[] { station.WarlockAccountId, station.HelperAAccountId, station.HelperBAccountId })
                {
                    if (string.IsNullOrWhiteSpace(id)) continue;
                    if (accountVault != null && !known.Contains(id))
                        throw new InvalidDataException("TELE wskazuje konto, którego nie ma już w vault: " + id);
                    if (station.Enabled && !activeRoles.Add(id))
                        throw new InvalidDataException("Jedno konto nie może pełnić dwóch aktywnych ról TELE jednocześnie.");
                }
                if (station.Enabled && (string.IsNullOrWhiteSpace(station.WarlockAccountId)
                    || string.IsNullOrWhiteSpace(station.HelperAAccountId)
                    || string.IsNullOrWhiteSpace(station.HelperBAccountId)))
                    throw new InvalidDataException("Aktywna stacja TELE wymaga Warlock + Helper A + Helper B.");
            }
            if (!TeleRuntimeEnabled && (cfg.AutoReply || cfg.AutoInvite || cfg.AutoSummon))
                throw new InvalidDataException("TELE runtime jest zablokowany; auto-akcje muszą pozostać OFF.");
        }

        private string TeleAccountLabel(string id)
        {
            if (string.IsNullOrWhiteSpace(id)) return "—";
            if (accountVault == null) return "[vault unavailable]";
            var account = accountVault.Data.Accounts.FirstOrDefault(a => string.Equals(a.Id, id, StringComparison.Ordinal));
            return account == null ? "[missing]" : account.Label + " [" + account.Login + "]";
        }

        private static string TeleStationLabel(string id)
        {
            if (string.Equals(id, "hyjal", StringComparison.OrdinalIgnoreCase)) return "Hyjal";
            if (string.Equals(id, "hydraxian", StringComparison.OrdinalIgnoreCase)) return "Hydraxian / Azshara";
            if (string.Equals(id, "winterspring", StringComparison.OrdinalIgnoreCase)) return "Winterspring";
            return id ?? "?";
        }

        private void ShowTeleControlPlane()
        {
            if (busy) return;
            TeleUiConfig cfg;
            try { cfg = LoadTeleConfig(); }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Nie udało się odczytać TELE config. Dane nie zostały nadpisane.\n\n" + ex.Message,
                    "TELE", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            using (var dialog = new Form
            {
                Text = "TELE — Headless Summon Control Plane",
                ClientSize = new Size(1040, 650),
                MinimumSize = new Size(1056, 689),
                FormBorderStyle = FormBorderStyle.FixedDialog,
                MaximizeBox = false,
                MinimizeBox = false,
                StartPosition = FormStartPosition.CenterParent,
                AutoScaleMode = AutoScaleMode.Dpi,
                Font = new Font("Segoe UI", 9F),
                BackColor = Color.FromArgb(28, 28, 32),
                ForeColor = Color.Gainsboro
            })
            {
                var runtime = new Label
                {
                    Location = new Point(14, 12), Size = new Size(1012, 42),
                    BackColor = TeleRuntimeEnabled ? Color.FromArgb(28, 82, 48) : Color.FromArgb(96, 55, 35),
                    ForeColor = Color.White,
                    Font = new Font("Segoe UI Semibold", 10F, FontStyle.Bold),
                    TextAlign = ContentAlignment.MiddleLeft,
                    Padding = new Padding(12, 0, 8, 0),
                    Text = TeleRuntimeEnabled
                        ? "TELE RUNTIME ENABLED"
                        : "TELE RUNTIME LOCKED — UI/config only. Czekamy na party RX + guarded invite runtime evidence."
                };

                var stationList = new ListView
                {
                    Location = new Point(14, 80), Size = new Size(1012, 180),
                    View = View.Details, FullRowSelect = true, GridLines = true,
                    HideSelection = false, MultiSelect = false, BackColor = Color.FromArgb(36, 36, 42), ForeColor = Color.Gainsboro
                };
                stationList.Columns.Add("STATION", 155);
                stationList.Columns.Add("ENABLED", 75);
                stationList.Columns.Add("WARLOCK", 240);
                stationList.Columns.Add("HELPER A", 240);
                stationList.Columns.Add("HELPER B", 240);

                var configure = new Button { Text = "CONFIGURE ROLES", Location = new Point(14, 272), Size = new Size(160, 36) };
                var refresh = new Button { Text = "REFRESH", Location = new Point(182, 272), Size = new Size(110, 36) };
                var emergency = new CheckBox { Text = "EMERGENCY PAUSE", Location = new Point(320, 280), Size = new Size(160, 24), Checked = cfg.EmergencyPaused, ForeColor = Color.Gainsboro };
                var autoReply = new CheckBox { Text = "Auto Reply", Location = new Point(505, 280), Size = new Size(105, 24), Checked = cfg.AutoReply, Enabled = TeleRuntimeEnabled, ForeColor = Color.Gainsboro };
                var autoInvite = new CheckBox { Text = "Auto Invite", Location = new Point(620, 280), Size = new Size(105, 24), Checked = cfg.AutoInvite, Enabled = TeleRuntimeEnabled, ForeColor = Color.Gainsboro };
                var autoSummon = new CheckBox { Text = "Auto Summon", Location = new Point(735, 280), Size = new Size(115, 24), Checked = cfg.AutoSummon, Enabled = TeleRuntimeEnabled, ForeColor = Color.Gainsboro };
                var master = new Button { Text = TeleRuntimeEnabled ? "TELE MASTER OFF" : "TELE MASTER LOCKED", Location = new Point(862, 272), Size = new Size(164, 36), Enabled = TeleRuntimeEnabled };

                var diagTitle = new Label { Text = "WHISPERS / DECISIONS — runtime diagnostics", Location = new Point(14, 327), Size = new Size(500, 22), Font = new Font("Segoe UI Semibold", 9F, FontStyle.Bold) };
                var whispers = new ListView
                {
                    Location = new Point(14, 352), Size = new Size(1012, 220),
                    View = View.Details, FullRowSelect = true, GridLines = true,
                    BackColor = Color.FromArgb(36, 36, 42), ForeColor = Color.Gainsboro
                };
                whispers.Columns.Add("PLAYER", 150);
                whispers.Columns.Add("MESSAGE", 285);
                whispers.Columns.Add("INTENT", 135);
                whispers.Columns.Add("DEST", 130);
                whispers.Columns.Add("CONF", 70);
                whispers.Columns.Add("ACTION", 210);
                var placeholder = new ListViewItem(new[] { "—", "runtime not connected", "—", "—", "—", "NO ACTION" });
                whispers.Items.Add(placeholder);

                var footer = new Label
                {
                    Location = new Point(14, 586), Size = new Size(840, 50),
                    ForeColor = Color.Silver,
                    Text = "Safety: credentials stay in existing DPAPI WowAccountVault. tele_config.json stores account IDs/roles only. " +
                        "Unknown whisper target: append-only JSONL. Runtime workers are not started by this UI build."
                };
                var save = new Button { Text = "SAVE", Location = new Point(862, 586), Size = new Size(78, 38) };
                var close = new Button { Text = "CLOSE", Location = new Point(948, 586), Size = new Size(78, 38) };

                dialog.Controls.AddRange(new Control[] {
                    runtime, stationList, configure, refresh, emergency, autoReply, autoInvite, autoSummon, master,
                    diagTitle, whispers, footer, save, close
                });

                Action refreshStations = delegate
                {
                    stationList.Items.Clear();
                    foreach (var station in cfg.Stations)
                    {
                        var row = new ListViewItem(TeleStationLabel(station.Id));
                        row.SubItems.Add(station.Enabled ? "YES" : "NO");
                        row.SubItems.Add(TeleAccountLabel(station.WarlockAccountId));
                        row.SubItems.Add(TeleAccountLabel(station.HelperAAccountId));
                        row.SubItems.Add(TeleAccountLabel(station.HelperBAccountId));
                        row.Tag = station;
                        stationList.Items.Add(row);
                    }
                };
                refreshStations();

                refresh.Click += delegate { refreshStations(); };
                close.Click += delegate { dialog.Close(); };
                emergency.CheckedChanged += delegate { cfg.EmergencyPaused = emergency.Checked; };
                autoReply.CheckedChanged += delegate { cfg.AutoReply = autoReply.Checked; };
                autoInvite.CheckedChanged += delegate { cfg.AutoInvite = autoInvite.Checked; };
                autoSummon.CheckedChanged += delegate { cfg.AutoSummon = autoSummon.Checked; };
                save.Click += delegate
                {
                    try
                    {
                        SaveTeleConfig(cfg);
                        Log("TELE config zapisany. Runtime=" + (TeleRuntimeEnabled ? "ENABLED" : "LOCKED") + ", emergency=" + cfg.EmergencyPaused + ".");
                        MessageBox.Show(dialog, "TELE config zapisany.", "TELE", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    }
                    catch (Exception ex)
                    {
                        MessageBox.Show(dialog, ex.Message, "TELE config", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                };
                configure.Click += delegate
                {
                    if (stationList.SelectedItems.Count != 1)
                    {
                        MessageBox.Show(dialog, "Wybierz jedną stację.", "TELE", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        return;
                    }
                    var station = stationList.SelectedItems[0].Tag as TeleStationUiConfig;
                    if (station != null && EditTeleStation(dialog, cfg, station)) refreshStations();
                };

                dialog.ShowDialog(this);
            }
        }

        private bool EditTeleStation(Form owner, TeleUiConfig cfg, TeleStationUiConfig station)
        {
            if (accountVault == null)
            {
                MessageBox.Show(owner, "Account vault jest niedostępny. TELE config nie został zmieniony.", "TELE", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }
            using (var dialog = new Form
            {
                Text = "TELE role config — " + TeleStationLabel(station.Id),
                ClientSize = new Size(560, 290),
                FormBorderStyle = FormBorderStyle.FixedDialog,
                MaximizeBox = false,
                MinimizeBox = false,
                StartPosition = FormStartPosition.CenterParent,
                AutoScaleMode = AutoScaleMode.Dpi,
                Font = new Font("Segoe UI", 9F)
            })
            {
                var enabled = new CheckBox { Text = "Station enabled", Location = new Point(18, 18), Size = new Size(180, 24), Checked = station.Enabled };
                var warlock = new ComboBox { Location = new Point(170, 70), Size = new Size(360, 28), DropDownStyle = ComboBoxStyle.DropDownList };
                var helperA = new ComboBox { Location = new Point(170, 116), Size = new Size(360, 28), DropDownStyle = ComboBoxStyle.DropDownList };
                var helperB = new ComboBox { Location = new Point(170, 162), Size = new Size(360, 28), DropDownStyle = ComboBoxStyle.DropDownList };
                var ok = new Button { Text = "SAVE", Location = new Point(342, 228), Size = new Size(90, 36) };
                var cancel = new Button { Text = "CANCEL", Location = new Point(440, 228), Size = new Size(90, 36), DialogResult = DialogResult.Cancel };
                dialog.Controls.AddRange(new Control[] {
                    enabled,
                    new Label { Text = "Warlock", Location = new Point(18, 74), Size = new Size(140, 22) }, warlock,
                    new Label { Text = "Helper A", Location = new Point(18, 120), Size = new Size(140, 22) }, helperA,
                    new Label { Text = "Helper B", Location = new Point(18, 166), Size = new Size(140, 22) }, helperB,
                    ok, cancel
                });

                var rows = new List<KeyValuePair<string, string>> { new KeyValuePair<string, string>("", "— none —") };
                rows.AddRange(accountVault.Data.Accounts.Select(a => new KeyValuePair<string, string>(a.Id, a.Label + " [" + a.Login + "]")));
                FillTeleAccountCombo(warlock, rows, station.WarlockAccountId);
                FillTeleAccountCombo(helperA, rows, station.HelperAAccountId);
                FillTeleAccountCombo(helperB, rows, station.HelperBAccountId);

                var accepted = false;
                ok.Click += delegate
                {
                    var before = new TeleStationUiConfig {
                        Id = station.Id, Enabled = station.Enabled, WarlockAccountId = station.WarlockAccountId,
                        HelperAAccountId = station.HelperAAccountId, HelperBAccountId = station.HelperBAccountId
                    };
                    station.Enabled = enabled.Checked;
                    station.WarlockAccountId = TeleComboId(warlock);
                    station.HelperAAccountId = TeleComboId(helperA);
                    station.HelperBAccountId = TeleComboId(helperB);
                    try
                    {
                        ValidateTeleConfig(cfg);
                        accepted = true;
                        dialog.Close();
                    }
                    catch (Exception ex)
                    {
                        station.Enabled = before.Enabled;
                        station.WarlockAccountId = before.WarlockAccountId;
                        station.HelperAAccountId = before.HelperAAccountId;
                        station.HelperBAccountId = before.HelperBAccountId;
                        MessageBox.Show(dialog, ex.Message, "TELE role config", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                };
                dialog.CancelButton = cancel;
                dialog.ShowDialog(owner);
                return accepted;
            }
        }

        private static void FillTeleAccountCombo(ComboBox combo, List<KeyValuePair<string, string>> rows, string selectedId)
        {
            combo.Items.Clear();
            var selected = 0;
            for (var i = 0; i < rows.Count; i++)
            {
                combo.Items.Add(rows[i]);
                if (string.Equals(rows[i].Key, selectedId ?? "", StringComparison.Ordinal)) selected = i;
            }
            combo.DisplayMember = "Value";
            combo.ValueMember = "Key";
            combo.SelectedIndex = selected;
        }

        private static string TeleComboId(ComboBox combo)
        {
            if (combo.SelectedItem is KeyValuePair<string, string>)
                return ((KeyValuePair<string, string>)combo.SelectedItem).Key;
            return string.Empty;
        }
    }
}
