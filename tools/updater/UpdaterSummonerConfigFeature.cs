using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        private static readonly string[] TerminalDefaultSummoners = { "teletanaris", "bolthyjal", "feltaxi" };
        private readonly Timer summonerConfigAttachTimer = CreateSummonerConfigAttachTimer();

        private static Timer CreateSummonerConfigAttachTimer()
        {
            var timer = new Timer { Interval = 250 };
            timer.Tick += delegate
            {
                var main = System.Windows.Forms.Application.OpenForms.OfType<MainForm>().FirstOrDefault();
                if (main == null || main.IsDisposed || main.Disposing || !main.dashboardReady) return;
                foreach (Form dialog in System.Windows.Forms.Application.OpenForms)
                {
                    if (dialog == null || dialog.IsDisposed || dialog.Disposing) continue;
                    if (string.Equals(dialog.Text, "MULTIBOX — World of Warcraft 1.12.1", StringComparison.Ordinal))
                        main.AttachSummonerConfigButton(dialog);
                    else if (string.Equals(dialog.Text, "MULTIBOX TERMINAL — Android headless portal clickers", StringComparison.Ordinal))
                        main.AttachSummonerAwareTerminalStart(dialog);
                }
            };
            timer.Start();
            return timer;
        }

        private void AttachSummonerConfigButton(Form dialog)
        {
            if (dialog.Controls.Find("wow112SummonersButton", true).Length != 0) return;
            var button = new Button
            {
                Name = "wow112SummonersButton",
                Text = "SUMMONERS",
                Location = new Point(260, 414),
                Size = new Size(210, 34)
            };
            button.Click += delegate { ShowSummonerConfig(dialog); };
            dialog.Controls.Add(button);
            button.BringToFront();
        }

        private void AttachSummonerAwareTerminalStart(Form dialog)
        {
            if (dialog.Controls.Find("wow112SummonerStartButton", true).Length != 0) return;
            var original = dialog.Controls.OfType<Button>().FirstOrDefault(x => string.Equals(x.Text, "START zaznaczone", StringComparison.Ordinal));
            if (original == null) return;

            var replacement = new Button
            {
                Name = "wow112SummonerStartButton",
                Text = original.Text,
                Location = original.Location,
                Size = original.Size,
                Anchor = original.Anchor,
                TabIndex = original.TabIndex
            };
            original.Visible = false;
            replacement.Click += async delegate { await RunSummonerAwareTerminalStartAsync(dialog, replacement); };
            dialog.Controls.Add(replacement);
            replacement.BringToFront();
        }

        private List<string> NormalizeSummonerNames(IEnumerable<string> values)
        {
            var result = new List<string>();
            if (values == null) return result;
            foreach (var value in values)
            {
                var name = (value ?? "").Trim().ToLowerInvariant();
                if (!Regex.IsMatch(name, "^[a-z]{2,12}$")) continue;
                if (!result.Any(existing => string.Equals(existing, name, StringComparison.OrdinalIgnoreCase)))
                    result.Add(name);
            }
            return result;
        }

        private string SummonerConfigPath()
        {
            return Path.Combine(configDir, "summoners.json");
        }

        private List<string> LoadSummonerNames()
        {
            var path = SummonerConfigPath();
            if (!File.Exists(path)) return NormalizeSummonerNames(TerminalDefaultSummoners);
            try
            {
                var root = AsDictionary(json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8)));
                var values = new List<string>();
                foreach (var item in AsArray(GetValue(root, "summoners"))) values.Add(Convert.ToString(item));
                return NormalizeSummonerNames(values);
            }
            catch (Exception ex)
            {
                Log("MULTIBOX SUMMONERS: config invalid, fallback default: " + ShortTerminalText(ex.Message, 120));
                return NormalizeSummonerNames(TerminalDefaultSummoners);
            }
        }

        private void SaveSummonerNames(IEnumerable<string> values)
        {
            var names = NormalizeSummonerNames(values);
            var root = new Dictionary<string, object>();
            root["schema_version"] = 1;
            root["summoners"] = names.ToArray();
            UpdaterSafety.WriteUtf8Atomic(SummonerConfigPath(), json.Serialize(root), ".tmp", ".previous");
        }

        private void ShowSummonerConfig(IWin32Window owner)
        {
            using (var dialog = new Form
            {
                Text = "MULTIBOX — SUMMONERS",
                ClientSize = new Size(470, 390),
                MinimumSize = new Size(486, 429),
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
                    Size = new Size(442, 46),
                    Text = "Aktywne nicki summonerów. Terminalowy lvl 1 odda leadera pierwszemu z tej listy, którego znajdzie w party. Po zmianie zrestartuj działające clickery (STOP → START)."
                };
                var list = new ListBox { Location = new Point(14, 66), Size = new Size(442, 215), IntegralHeight = false };
                foreach (var name in LoadSummonerNames()) list.Items.Add(name);
                var input = new TextBox { Location = new Point(14, 294), Size = new Size(226, 25) };
                var add = new Button { Text = "DODAJ", Location = new Point(248, 291), Size = new Size(98, 30) };
                var remove = new Button { Text = "USUŃ", Location = new Point(354, 291), Size = new Size(102, 30) };
                var save = new Button { Text = "ZAPISZ", Location = new Point(248, 338), Size = new Size(98, 34) };
                var close = new Button { Text = "ANULUJ", Location = new Point(354, 338), Size = new Size(102, 34) };

                Action addName = delegate
                {
                    var raw = input.Text.Trim();
                    if (!Regex.IsMatch(raw, "^[A-Za-z]{2,12}$"))
                    {
                        MessageBox.Show(dialog, "Nick musi mieć 2–12 liter.", "SUMMONERS", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        return;
                    }
                    var normalized = raw.ToLowerInvariant();
                    if (!list.Items.Cast<object>().Select(Convert.ToString).Any(x => string.Equals(x, normalized, StringComparison.OrdinalIgnoreCase)))
                        list.Items.Add(normalized);
                    input.Clear();
                    input.Focus();
                };

                add.Click += delegate { addName(); };
                input.KeyDown += delegate(object sender, KeyEventArgs e)
                {
                    if (e.KeyCode != Keys.Enter) return;
                    e.SuppressKeyPress = true;
                    addName();
                };
                remove.Click += delegate
                {
                    if (list.SelectedIndex >= 0) list.Items.RemoveAt(list.SelectedIndex);
                };
                save.Click += delegate
                {
                    var names = list.Items.Cast<object>().Select(Convert.ToString).ToList();
                    SaveSummonerNames(names);
                    Log("MULTIBOX SUMMONERS: saved " + names.Count + " names: " + (names.Count == 0 ? "(none)" : string.Join(",", names.ToArray())) + ".");
                    dialog.DialogResult = DialogResult.OK;
                    dialog.Close();
                };
                close.Click += delegate { dialog.Close(); };

                dialog.Controls.AddRange(new Control[] { info, list, input, add, remove, save, close });
                dialog.AcceptButton = add;
                dialog.CancelButton = close;
                dialog.ShowDialog(owner);
            }
        }

        private async Task RunSummonerAwareTerminalStartAsync(Form dialog, Button startButton)
        {
            if (dialog == null || dialog.IsDisposed || startButton == null || !startButton.Enabled) return;
            if (accountVault == null || accountVault.Data.Accounts.Count == 0) return;

            var accounts = dialog.Controls.OfType<CheckedListBox>().FirstOrDefault();
            var states = dialog.Controls.OfType<ListBox>().FirstOrDefault(x => !(x is CheckedListBox));
            if (accounts == null || states == null) return;

            var selected = new List<int>();
            for (var i = 0; i < accounts.Items.Count && i < accountVault.Data.Accounts.Count; i++)
                if (accounts.GetItemChecked(i)) selected.Add(i);
            if (selected.Count == 0)
            {
                MessageBox.Show(dialog, "Zaznacz co najmniej jedno konto.", "MULTIBOX TERMINAL", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            var buttons = dialog.Controls.OfType<Button>().Where(x => x.Visible).ToArray();
            foreach (var button in buttons) button.Enabled = false;
            try
            {
                var adb = ResolveTerminalAdb();
                var realm = ResolveTerminalRealmHost();
                var summonerCsv = string.Join(",", LoadSummonerNames().ToArray());
                var ids = new HashSet<string>(StringComparer.Ordinal);
                var started = 0;

                foreach (var index in selected)
                {
                    var account = accountVault.Data.Accounts[index];
                    ids.Add(account.Id);
                    if (index < states.Items.Count) states.Items[index] = account.Label + " • STARTING";
                    var probe = await StartTerminalPortalWorkerWithSummonersAsync(adb, realm, account, summonerCsv);
                    if (index < states.Items.Count) states.Items[index] = account.Label + " • " + probe.State;
                    started++;
                }

                SaveTerminalSelections(Path.Combine(configDir, "terminal_portal_accounts.json"), ids);
                Log("MULTIBOX TERMINAL Android: started " + started + " workers; summoners=" + (summonerCsv.Length == 0 ? "none" : summonerCsv) + ".");
            }
            catch (Exception ex)
            {
                Log("MULTIBOX TERMINAL SUMMONER START ERROR: " + ex.Message);
                MessageBox.Show(dialog, ex.Message, "MULTIBOX TERMINAL", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                foreach (var button in buttons) if (!button.IsDisposed) button.Enabled = true;
            }
        }

        private async Task<TerminalPortalProbe> StartTerminalPortalWorkerWithSummonersAsync(string adb, string realmHost, WowAccount account, string summonerCsv)
        {
            if (account == null) throw new ArgumentNullException("account");
            var password = accountVault.Unprotect(account);
            if (string.IsNullOrEmpty(password)) throw new InvalidDataException("Puste hasło profilu: " + account.Label);
            await StopTerminalPortalWorkerAsync(adb, account);

            var paths = TerminalRemotePaths(account);
            TerminalPortalProbe last = null;
            for (var attempt = 1; attempt <= 2; attempt++)
            {
                var env = new List<string>();
                env.Add("WOW112_MODE=" + TerminalShellQuote("portal-clicker"));
                env.Add("WOW112_AUTH_ADDR=" + TerminalShellQuote(realmHost + ":3724"));
                env.Add("WOW112_ACCOUNT=" + TerminalShellQuote(account.Login));
                env.Add("WOW112_PASSWORD=" + TerminalShellQuote(password));
                env.Add("WOW112_REALM_INDEX='1'");
                env.Add("WOW112_SOAK_SECONDS='0'");
                env.Add("WOW112_RECONNECT_LIMIT='60'");
                env.Add("WOW112_RECONNECT_DELAY_MS='0'");
                env.Add("WOW112_PORTAL_ATTEMPTS='3'");
                env.Add("WOW112_SUMMONER_NAMES=" + TerminalShellQuote(summonerCsv ?? ""));

                var launch = "rm -f " + paths.Item2 + " " + paths.Item1 + "; nohup env " + string.Join(" ", env.ToArray()) + " " + TerminalAndroidRemoteBinary + " >" + paths.Item2 + " 2>&1 </dev/null & echo $! >" + paths.Item1;
                var result = await RunTerminalAdbShellAsync(adb, launch, false);
                if (result.ExitCode != 0) throw new InvalidOperationException(account.Label + ": adb launch failed: " + result.Output);

                for (var i = 0; i < 10; i++)
                {
                    await Task.Delay(500);
                    last = await ProbeTerminalPortalWorkerAsync(adb, account);
                    if (last.Running)
                    {
                        Log("MULTIBOX TERMINAL: " + account.Label + " worker ACTIVE/RUNNING (attempt " + attempt + ", summoners=" + (string.IsNullOrEmpty(summonerCsv) ? "none" : summonerCsv) + ").");
                        return last;
                    }
                }
                if (attempt < 2)
                {
                    Log("MULTIBOX TERMINAL: " + account.Label + " szybki exit, automatyczny retry 1/1.");
                    await StopTerminalPortalWorkerAsync(adb, account);
                    await Task.Delay(750);
                }
            }
            throw new InvalidOperationException(account.Label + ": worker nie utrzymał procesu po 2 próbach. " + ShortTerminalText(last == null ? "" : last.Tail, 180));
        }
    }
}
