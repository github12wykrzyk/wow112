using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        private const string DefaultTerminalSummoners = "teletanaris,bolthyjal,feltaxi";
        private readonly Timer summonersAttachTimer = CreateSummonersAttachTimer();
        private bool summonersAttached;

        private sealed class SummonersConfigData
        {
            public int Version { get; set; }
            public List<string> Names { get; set; }
        }

        private static Timer CreateSummonersAttachTimer()
        {
            var timer = new Timer { Interval = 180 };
            timer.Tick += delegate
            {
                var form = System.Windows.Forms.Application.OpenForms.OfType<MainForm>().FirstOrDefault();
                if (form == null || form.IsDisposed || form.Disposing) return;
                if (!form.dashboardReady) return;
                timer.Stop();
                form.AttachSummonersFeature();
            };
            timer.Start();
            return timer;
        }

        private void AttachSummonersFeature()
        {
            if (summonersAttached) return;
            summonersAttached = true;
            var multibox = featureControls.ContainsKey("multibox") ? featureControls["multibox"] as Button : null;
            if (multibox == null) return;

            var menu = multibox.ContextMenuStrip ?? new ContextMenuStrip();
            if (menu.Items.Count > 0) menu.Items.Add(new ToolStripSeparator());
            var item = new ToolStripMenuItem("Summoners...");
            item.Click += delegate { ShowSummonersConfig(); };
            menu.Items.Add(item);
            multibox.ContextMenuStrip = menu;
            Log("MULTIBOX SUMMONERS gotowy: PPM na MULTIBOX -> Summoners...");
        }

        private string SummonersConfigPath()
        {
            return Path.Combine(configDir, "summoners.json");
        }

        private static List<string> NormalizeSummonerNames(IEnumerable<string> values)
        {
            var result = new List<string>();
            if (values == null) return result;
            foreach (var raw in values)
            {
                var name = (raw ?? "").Trim().ToLowerInvariant();
                if (name.Length == 0) continue;
                if (!Regex.IsMatch(name, "^[a-z][a-z'-]{1,23}$"))
                    throw new InvalidDataException("Nieprawidłowy nick summoner'a: " + raw + ". Dozwolone: litery, apostrof i myślnik; 2-24 znaki.");
                if (!result.Contains(name, StringComparer.OrdinalIgnoreCase)) result.Add(name);
                if (result.Count > 32) throw new InvalidDataException("Maksymalnie 32 summonerów.");
            }
            return result;
        }

        private List<string> LoadConfiguredSummonerNames()
        {
            var path = SummonersConfigPath();
            if (!File.Exists(path))
                return NormalizeSummonerNames(DefaultTerminalSummoners.Split(','));

            try
            {
                if (new FileInfo(path).Length > 64 * 1024)
                    throw new InvalidDataException("summoners.json jest zbyt duży.");
                var loaded = json.Deserialize<SummonersConfigData>(File.ReadAllText(path, Encoding.UTF8));
                if (loaded == null || loaded.Version != 1 || loaded.Names == null)
                    throw new InvalidDataException("Nieprawidłowy format summoners.json.");
                var names = NormalizeSummonerNames(loaded.Names);
                if (names.Count == 0)
                    throw new InvalidDataException("Lista summonerów nie może być pusta.");
                return names;
            }
            catch (Exception ex)
            {
                Log("MULTIBOX SUMMONERS config error; używam fallbacku: " + ex.Message);
                return NormalizeSummonerNames(DefaultTerminalSummoners.Split(','));
            }
        }

        private void SaveConfiguredSummonerNames(IEnumerable<string> values)
        {
            var names = NormalizeSummonerNames(values);
            if (names.Count == 0) throw new InvalidDataException("Dodaj co najmniej jednego summoner'a.");
            var data = new SummonersConfigData { Version = 1, Names = names };
            UpdaterSafety.WriteUtf8Atomic(SummonersConfigPath(), json.Serialize(data), ".tmp", ".previous");
            Log("MULTIBOX SUMMONERS zapisano: " + string.Join(",", names.ToArray()));
        }

        private string GetConfiguredSummonerNamesCsv()
        {
            return string.Join(",", LoadConfiguredSummonerNames().ToArray());
        }

        private void ShowSummonersConfig()
        {
            using (var dialog = new Form
            {
                Text = "MULTIBOX — Summoners",
                ClientSize = new Size(520, 420),
                FormBorderStyle = FormBorderStyle.FixedDialog,
                MaximizeBox = false,
                MinimizeBox = false,
                StartPosition = FormStartPosition.CenterParent,
                AutoScaleMode = AutoScaleMode.Dpi,
                Font = new Font("Segoe UI", 9F)
            })
            {
                var info = new Label
                {
                    Location = new Point(14, 12),
                    Size = new Size(490, 48),
                    Text = "Lista postaci, którym terminalowe lvl1 clickery mogą automatycznie oddać party leadera. Zmiana działa dla nowych START/RESTART workerów."
                };
                var list = new ListBox { Location = new Point(14, 68), Size = new Size(490, 220) };
                var name = new TextBox { Location = new Point(14, 300), Size = new Size(250, 27) };
                var add = new Button { Text = "DODAJ", Location = new Point(274, 297), Size = new Size(105, 32) };
                var remove = new Button { Text = "USUŃ", Location = new Point(389, 297), Size = new Size(115, 32) };
                var defaults = new Button { Text = "DOMYŚLNE", Location = new Point(14, 344), Size = new Size(115, 36) };
                var save = new Button { Text = "ZAPISZ", Location = new Point(274, 344), Size = new Size(105, 36) };
                var close = new Button { Text = "ANULUJ", Location = new Point(389, 344), Size = new Size(115, 36) };
                var footer = new Label
                {
                    Location = new Point(14, 390),
                    Size = new Size(490, 22),
                    ForeColor = Color.DimGray,
                    Text = "Config lokalny: %APPDATA%\\WoW112ParallelUpdater\\summoners.json"
                };
                dialog.Controls.AddRange(new Control[] { info, list, name, add, remove, defaults, save, close, footer });

                Action<IEnumerable<string>> fill = delegate(IEnumerable<string> names)
                {
                    list.Items.Clear();
                    foreach (var value in names) list.Items.Add(value);
                };
                fill(LoadConfiguredSummonerNames());

                Action addName = delegate
                {
                    try
                    {
                        var normalized = NormalizeSummonerNames(new[] { name.Text });
                        if (normalized.Count == 0) return;
                        var value = normalized[0];
                        var exists = false;
                        foreach (var item in list.Items)
                            if (string.Equals(Convert.ToString(item), value, StringComparison.OrdinalIgnoreCase)) { exists = true; break; }
                        if (!exists) list.Items.Add(value);
                        name.Clear();
                        name.Focus();
                    }
                    catch (Exception ex)
                    {
                        MessageBox.Show(dialog, ex.Message, "Summoners", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    }
                };

                add.Click += delegate { addName(); };
                name.KeyDown += delegate(object sender, KeyEventArgs e)
                {
                    if (e.KeyCode != Keys.Enter) return;
                    e.SuppressKeyPress = true;
                    addName();
                };
                remove.Click += delegate
                {
                    if (list.SelectedIndex >= 0) list.Items.RemoveAt(list.SelectedIndex);
                };
                defaults.Click += delegate { fill(DefaultTerminalSummoners.Split(',')); };
                close.Click += delegate { dialog.Close(); };
                save.Click += delegate
                {
                    try
                    {
                        var values = new List<string>();
                        foreach (var item in list.Items) values.Add(Convert.ToString(item));
                        SaveConfiguredSummonerNames(values);
                        MessageBox.Show(dialog,
                            "Zapisano. Uruchom ponownie wybrane terminal portal clickery, aby dostały nową listę.",
                            "Summoners", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        dialog.Close();
                    }
                    catch (Exception ex)
                    {
                        MessageBox.Show(dialog, ex.Message, "Summoners", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                };

                dialog.ShowDialog(this);
            }
        }
    }
}
