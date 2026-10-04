using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        private const string TerminalPortalExeName = "WoW112TerminalPortalClicker.exe";
        private const string TerminalUpdaterWorkflow = "build_updater.yml";
        private const string TerminalUpdaterWorkflowName = "Build WoW112 updater";
        private const string TerminalUpdaterArtifactPrefix = "WoW112ParallelUpdater-";
        private readonly Button terminalPortalButton = new Button();
        private readonly Timer terminalPortalAttachTimer = CreateTerminalPortalAttachTimer();
        private bool terminalPortalAttached;
        private bool terminalPortalBusy;

        private static Timer CreateTerminalPortalAttachTimer()
        {
            var timer = new Timer { Interval = 150 };
            timer.Tick += delegate
            {
                var form = System.Windows.Forms.Application.OpenForms.OfType<MainForm>().FirstOrDefault();
                if (form == null || form.IsDisposed || form.Disposing) return;
                if (!form.dashboardReady) return;
                timer.Stop();
                form.AttachTerminalPortalFeature();
            };
            timer.Start();
            return timer;
        }

        private void AttachTerminalPortalFeature()
        {
            if (terminalPortalAttached) return;
            terminalPortalAttached = true;
            terminalPortalButton.Click += async delegate { await ShowTerminalPortalAsync(); };
            featureControls["terminalPortal"] = terminalPortalButton;
            var multibox = featureControls.ContainsKey("multibox") ? featureControls["multibox"] as Button : null;
            var tools = multibox == null ? null : multibox.Parent as TableLayoutPanel;
            if (tools != null)
            {
                tools.SuspendLayout();
                tools.ColumnCount = 8;
                tools.ColumnStyles.Clear();
                for (var i = 0; i < 8; i++) tools.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 12.5F));
                tools.Controls.Add(ActionButton(terminalPortalButton, "MULTIBOX TERMINAL"), 7, 0);
                tools.ResumeLayout(true);
            }
            Log("MULTIBOX TERMINAL gotowy: headless portal-clicker, bez graficznego klienta WoW.");
        }

        private async Task ShowTerminalPortalAsync()
        {
            if (terminalPortalBusy || busy) return;
            if (accountVault == null || accountVault.Data.Accounts.Count == 0)
            {
                MessageBox.Show(this, "Najpierw dodaj konta w „Konta WoW”.", "MULTIBOX TERMINAL", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            if (string.IsNullOrWhiteSpace(token.Text))
            {
                MessageBox.Show(this, "Wpisz token GitHub, aby updater mógł pobrać zweryfikowany terminal companion.", "MULTIBOX TERMINAL", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            terminalPortalBusy = true;
            try
            {
                SetBusy(true, "MULTIBOX TERMINAL: weryfikuję companion EXE...");
                var exe = await EnsureTerminalPortalCompanionAsync();
                var realm = ResolveTerminalRealmHost();
                using (var dialog = new Form
                {
                    Text = "MULTIBOX TERMINAL — portal clickers",
                    ClientSize = new Size(720, 470),
                    MinimumSize = new Size(736, 509),
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
                        Location = new Point(14, 12), Size = new Size(690, 42),
                        Text = "Tryb terminalowy nie uruchamia WoW.exe. Loguje konto bez GUI, utrzymuje world session, automatycznie reconnectuje i używa valid Summoning Portal. Realm: " + realm
                    };
                    var accounts = new CheckedListBox { Location = new Point(14, 62), Size = new Size(300, 320), CheckOnClick = true, IntegralHeight = false };
                    var states = new ListBox { Location = new Point(328, 62), Size = new Size(376, 320), IntegralHeight = false };
                    var launch = new Button { Text = "URUCHOM TERMINAL", Location = new Point(328, 396), Size = new Size(180, 36) };
                    var all = new Button { Text = "Zaznacz wszystkie", Location = new Point(14, 396), Size = new Size(142, 36) };
                    var clear = new Button { Text = "Wyczyść", Location = new Point(164, 396), Size = new Size(120, 36) };
                    var close = new Button { Text = "Zamknij", Location = new Point(516, 396), Size = new Size(188, 36) };
                    dialog.Controls.AddRange(new Control[] { info, accounts, states, launch, all, clear, close });

                    var prefPath = Path.Combine(configDir, "terminal_portal_accounts.json");
                    var selectedIds = LoadTerminalSelections(prefPath);
                    var byIndex = new List<WowAccount>();
                    foreach (var account in accountVault.Data.Accounts)
                    {
                        byIndex.Add(account);
                        accounts.Items.Add(account.Label + "  [" + account.Login + "]", selectedIds.Contains(account.Id));
                        states.Items.Add(account.Label + " • gotowy");
                    }
                    all.Click += delegate { for (var i = 0; i < accounts.Items.Count; i++) accounts.SetItemChecked(i, true); };
                    clear.Click += delegate { for (var i = 0; i < accounts.Items.Count; i++) accounts.SetItemChecked(i, false); };
                    close.Click += delegate { dialog.Close(); };
                    launch.Click += delegate
                    {
                        try
                        {
                            var ids = new HashSet<string>(StringComparer.Ordinal);
                            var started = 0;
                            for (var i = 0; i < byIndex.Count; i++)
                            {
                                if (!accounts.GetItemChecked(i)) continue;
                                var account = byIndex[i];
                                ids.Add(account.Id);
                                states.Items[i] = account.Label + " • STARTING";
                                System.Windows.Forms.Application.DoEvents();
                                var process = StartTerminalPortalProcess(exe, realm, account);
                                accountSessions.Add(new WowAccountSession { Game = process, AccountId = account.Id });
                                states.Items[i] = account.Label + " • PID " + process.Id + " • TERMINAL / AUTORECONNECT";
                                started++;
                            }
                            SaveTerminalSelections(prefPath, ids);
                            Log("MULTIBOX TERMINAL: uruchomiono " + started + " procesów headless.");
                        }
                        catch (Exception ex)
                        {
                            MessageBox.Show(dialog, ex.Message, "MULTIBOX TERMINAL", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                    };
                    SetBusy(false, "MULTIBOX TERMINAL gotowy.");
                    dialog.ShowDialog(this);
                }
            }
            catch (Exception ex)
            {
                SetBusy(false, "MULTIBOX TERMINAL: błąd");
                Log("MULTIBOX TERMINAL BŁĄD: " + ex.Message);
                MessageBox.Show(this, ex.Message, "MULTIBOX TERMINAL", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                terminalPortalBusy = false;
                if (busy) SetBusy(false, "Gotowy");
            }
        }

        private System.Diagnostics.Process StartTerminalPortalProcess(string exePath, string realmHost, WowAccount account)
        {
            if (account == null) throw new ArgumentNullException("account");
            var password = accountVault.Unprotect(account);
            if (string.IsNullOrEmpty(password)) throw new InvalidDataException("Puste hasło profilu: " + account.Label);
            var psi = new ProcessStartInfo(exePath)
            {
                WorkingDirectory = Path.GetDirectoryName(exePath),
                UseShellExecute = false,
                CreateNoWindow = false
            };
            psi.EnvironmentVariables["WOW112_ACCOUNT"] = account.Login;
            psi.EnvironmentVariables["WOW112_PASSWORD"] = password;
            psi.EnvironmentVariables["WOW112_AUTH_ADDR"] = realmHost + ":3724";
            psi.EnvironmentVariables["WOW112_HEADLESS_MODE"] = "portal";
            psi.EnvironmentVariables["WOW112_SOAK_SECONDS"] = "0";
            psi.EnvironmentVariables["WOW112_RECONNECT_LIMIT"] = "60";
            psi.EnvironmentVariables["WOW112_RECONNECT_DELAY_MS"] = "2000";
            var process = System.Diagnostics.Process.Start(psi);
            if (process == null) throw new InvalidOperationException("Windows nie uruchomił terminal portal clickera.");
            return process;
        }

        private string ResolveTerminalRealmHost()
        {
            var root = gameDir.Text.Trim();
            if (!Directory.Exists(root)) throw new InvalidOperationException("Wybierz katalog gry z poprawnym realmlist.wtf.");
            var path = Path.Combine(root, "realmlist.wtf");
            if (!File.Exists(path)) throw new InvalidOperationException("Brak realmlist.wtf.");
            var text = File.ReadAllText(path, Encoding.UTF8);
            var match = Regex.Match(text, "(?im)^\\s*SET\\s+realmList\\s+\"([^\"]+)\"");
            if (!match.Success) throw new InvalidOperationException("Nie udało się odczytać hosta z realmlist.wtf.");
            var host = match.Groups[1].Value.Trim();
            if (host.Length == 0 || host.Contains("/") || host.Contains("\\") || host.Contains(" "))
                throw new InvalidOperationException("Nieprawidłowy host realmlist dla terminala.");
            if (host.Contains(":")) host = host.Split(':')[0];
            return host;
        }

        private async Task<string> EnsureTerminalPortalCompanionAsync()
        {
            var companionDir = Path.Combine(configDir, "companions");
            Directory.CreateDirectory(companionDir);
            using (var client = CreateClient())
            {
                var runsUrl = ApiRoot + "/actions/workflows/" + TerminalUpdaterWorkflow + "/runs?branch=parallel&per_page=20";
                var runsRoot = AsDictionary(json.DeserializeObject(await GetStringAsync(client, runsUrl)));
                var runs = AsArray(GetValue(runsRoot, "workflow_runs"));
                var run = UpdaterSafety.RequireLatestSuccessfulRun(runs, TerminalUpdaterWorkflowName, "parallel");
                var runId = GetLong(run, "id");
                var runSha = GetString(run, "head_sha");
                var artifactsRoot = AsDictionary(json.DeserializeObject(await GetStringAsync(client, ApiRoot + "/actions/runs/" + runId + "/artifacts?per_page=100")));
                Dictionary<string, object> artifact = null;
                foreach (var item in AsArray(GetValue(artifactsRoot, "artifacts")))
                {
                    var row = AsDictionary(item);
                    if (!GetBool(row, "expired") && string.Equals(GetString(row, "name"), TerminalUpdaterArtifactPrefix + runSha, StringComparison.OrdinalIgnoreCase))
                    { artifact = row; break; }
                }
                if (artifact == null) throw new InvalidOperationException("Zweryfikowany updater PARALLEL nie ma terminal companion artifactu. Funkcja nie jest jeszcze dostarczona na parallel.");
                byte[] outer;
                using (var response = await client.GetAsync(GetString(artifact, "archive_download_url"), HttpCompletionOption.ResponseHeadersRead))
                {
                    if (!response.IsSuccessStatusCode) throw new InvalidOperationException("Pobranie terminal companion: GitHub HTTP " + (int)response.StatusCode + ".");
                    outer = await response.Content.ReadAsByteArrayAsync();
                }
                byte[] exeBytes = null;
                Dictionary<string, object> meta = null;
                using (var ms = new MemoryStream(outer, false))
                using (var zip = new ZipArchive(ms, ZipArchiveMode.Read, false))
                {
                    var exeEntry = zip.Entries.FirstOrDefault(e => string.Equals(Path.GetFileName(e.FullName), TerminalPortalExeName, StringComparison.OrdinalIgnoreCase));
                    var metaEntry = zip.Entries.FirstOrDefault(e => string.Equals(Path.GetFileName(e.FullName), "updater_build.json", StringComparison.OrdinalIgnoreCase));
                    if (exeEntry == null || metaEntry == null) throw new InvalidOperationException("Artifact updatera nie zawiera terminal portal companion + metadanych.");
                    exeBytes = ReadTerminalEntry(exeEntry);
                    meta = AsDictionary(json.DeserializeObject(Encoding.UTF8.GetString(ReadTerminalEntry(metaEntry))));
                }
                var expectedName = GetString(meta, "terminal_portal_name");
                var expectedSha = GetString(meta, "terminal_portal_sha256");
                var expectedMachine = GetString(meta, "terminal_portal_pe_machine");
                if (!string.Equals(GetString(meta, "git_sha"), runSha, StringComparison.OrdinalIgnoreCase)
                    || !string.Equals(GetString(meta, "channel"), "parallel", StringComparison.Ordinal)
                    || !string.Equals(expectedName, TerminalPortalExeName, StringComparison.OrdinalIgnoreCase)
                    || !UpdaterSafety.IsSha256Hex(expectedSha)
                    || !string.Equals(expectedSha, TerminalSha256(exeBytes), StringComparison.OrdinalIgnoreCase)
                    || !string.Equals(expectedMachine, "0x014C", StringComparison.OrdinalIgnoreCase)
                    || GetLong(meta, "terminal_portal_size") != exeBytes.LongLength)
                    throw new InvalidOperationException("Terminal companion nie przeszedł provenance/SHA/x86 gate.");
                var dest = Path.Combine(companionDir, TerminalPortalExeName);
                var temp = dest + ".tmp";
                File.WriteAllBytes(temp, exeBytes);
                if (!string.Equals(TerminalSha256(File.ReadAllBytes(temp)), expectedSha, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Terminal companion nie przeszedł weryfikacji po zapisie.");
                UpdaterSafety.ReplaceFile(temp, dest, ".previous");
                Log("Terminal companion verified: " + runSha.Substring(0, 8) + " / run " + runId + ".");
                return dest;
            }
        }

        private static byte[] ReadTerminalEntry(ZipArchiveEntry entry)
        {
            using (var input = entry.Open())
            using (var output = new MemoryStream()) { input.CopyTo(output); return output.ToArray(); }
        }

        private static string TerminalSha256(byte[] bytes)
        {
            using (var sha = SHA256.Create())
            {
                var hash = sha.ComputeHash(bytes);
                var sb = new StringBuilder(hash.Length * 2);
                foreach (var b in hash) sb.Append(b.ToString("x2"));
                return sb.ToString();
            }
        }

        private HashSet<string> LoadTerminalSelections(string path)
        {
            try
            {
                if (!File.Exists(path)) return new HashSet<string>(StringComparer.Ordinal);
                var root = AsDictionary(json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8)));
                var ids = new HashSet<string>(StringComparer.Ordinal);
                foreach (var item in AsArray(GetValue(root, "account_ids")))
                { var id = Convert.ToString(item); if (!string.IsNullOrWhiteSpace(id)) ids.Add(id); }
                return ids;
            }
            catch { return new HashSet<string>(StringComparer.Ordinal); }
        }

        private void SaveTerminalSelections(string path, HashSet<string> ids)
        {
            var root = new Dictionary<string, object>();
            root["schema_version"] = 1;
            root["account_ids"] = ids.OrderBy(x => x, StringComparer.Ordinal).ToArray();
            UpdaterSafety.WriteUtf8Atomic(path, json.Serialize(root), ".tmp", ".previous");
        }
    }
}
