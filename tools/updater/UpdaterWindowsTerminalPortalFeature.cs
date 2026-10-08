using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        private const string TerminalWindowsWorkflow = "build_windows_headless_probe.yml";
        private const string TerminalWindowsWorkflowName = "Build Windows WoW112 headless portal";
        private const string TerminalWindowsArtifactPrefix = "WoW112-Windows-Headless-Portal-";
        private const string TerminalWindowsBinaryName = "wow112-headless-windows.exe";
        private readonly Timer terminalWindowsAttachTimer = CreateTerminalWindowsAttachTimer();
        private bool terminalWindowsAttached;
        private bool terminalWindowsBusy;

        private sealed class TerminalWindowsBundle
        {
            public string Path;
            public string GitSha;
            public string Sha256;
        }

        private sealed class TerminalWindowsProbe
        {
            public bool Running;
            public string State;
            public string Tail;
        }

        private static Timer CreateTerminalWindowsAttachTimer()
        {
            var timer = new Timer { Interval = 180 };
            timer.Tick += delegate
            {
                var form = Application.OpenForms.OfType<MainForm>().FirstOrDefault();
                if (form == null || form.IsDisposed || form.Disposing) return;
                if (!form.dashboardReady) return;
                timer.Stop();
                form.AttachWindowsTerminalPortalFeature();
            };
            timer.Start();
            return timer;
        }

        private void AttachWindowsTerminalPortalFeature()
        {
            if (terminalWindowsAttached) return;
            terminalWindowsAttached = true;

            var multibox = featureControls.ContainsKey("multibox") ? featureControls["multibox"] as Button : null;
            var host = multibox == null ? null : multibox.Parent as TableLayoutPanel;
            if (host == null)
            {
                Log("TERMINAL WIN: nie znaleziono paska NARZĘDZIA; przycisk nie został podpięty.");
                return;
            }

            var button = new Button();
            featureControls["terminalWin"] = button;
            ActionButton(button, "TERMINAL WIN");
            detailsTip.SetToolTip(button, "Natywny Windows headless portal clicker — bez Androida i ADB.");
            button.Click += async delegate { await ShowWindowsTerminalPortalAsync(); };

            host.SuspendLayout();
            try
            {
                host.ColumnCount = 8;
                host.ColumnStyles.Clear();
                for (var i = 0; i < 8; i++) host.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 12.5F));
                host.Controls.Add(button, 7, 0);
            }
            finally
            {
                host.ResumeLayout(true);
            }
            Log("TERMINAL WIN gotowy: natywny Windows portal clicker bez ADB.");
        }

        private async Task ShowWindowsTerminalPortalAsync()
        {
            if (terminalWindowsBusy || busy) return;
            if (accountVault == null || accountVault.Data.Accounts.Count == 0)
            {
                MessageBox.Show(this, "Najpierw dodaj konta w „Konta WoW”.", "TERMINAL WIN", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            terminalWindowsBusy = true;
            try
            {
                SetBusy(true, "TERMINAL WIN: sprawdzam natywny worker...");
                var bundle = await EnsureTerminalWindowsBinaryAsync();
                var realm = ResolveTerminalRealmHost();

                using (var dialog = new Form
                {
                    Text = "TERMINAL WIN — native headless portal clickers",
                    ClientSize = new Size(900, 560),
                    MinimumSize = new Size(916, 599),
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
                        Size = new Size(870, 52),
                        Text = "Windows native V1: bez Androida/ADB, osobny proces + PID/log na konto, pierwsza postać automatycznie, portal click + reconnect. Zamknięcie tego okna NIE zatrzymuje workerów. Realm: " + realm
                    };
                    var accounts = new CheckedListBox { Location = new Point(14, 70), Size = new Size(365, 374), CheckOnClick = true, IntegralHeight = false };
                    var states = new ListBox { Location = new Point(393, 70), Size = new Size(491, 374), IntegralHeight = false };
                    var start = new Button { Text = "START zaznaczone", Location = new Point(14, 460), Size = new Size(150, 38) };
                    var stop = new Button { Text = "STOP zaznaczone", Location = new Point(172, 460), Size = new Size(150, 38) };
                    var refresh = new Button { Text = "Odśwież", Location = new Point(330, 460), Size = new Size(112, 38) };
                    var all = new Button { Text = "Wszystkie", Location = new Point(450, 460), Size = new Size(105, 38) };
                    var clear = new Button { Text = "Wyczyść", Location = new Point(563, 460), Size = new Size(105, 38) };
                    var close = new Button { Text = "Zamknij", Location = new Point(676, 460), Size = new Size(208, 38) };
                    var footer = new Label
                    {
                        Location = new Point(14, 510), Size = new Size(870, 34),
                        Text = "Status co 3 s. STOP: worker zamyka world socket; taskkill tylko jako awaryjny fallback."
                    };
                    dialog.Controls.AddRange(new Control[] { info, accounts, states, start, stop, refresh, all, clear, close, footer });

                    var prefPath = Path.Combine(configDir, "terminal_windows_portal_accounts.json");
                    var selectedIds = LoadTerminalSelections(prefPath);
                    var byIndex = new List<WowAccount>();
                    foreach (var account in accountVault.Data.Accounts)
                    {
                        byIndex.Add(account);
                        accounts.Items.Add(account.Label + "  [" + account.Login + "]", selectedIds.Contains(account.Id));
                        states.Items.Add(account.Label + " • sprawdzam...");
                    }

                    Func<Task> refreshStates = async delegate
                    {
                        for (var i = 0; i < byIndex.Count; i++)
                        {
                            try
                            {
                                var probe = await ProbeTerminalWindowsWorkerAsync(byIndex[i]);
                                if (!dialog.IsDisposed && i < states.Items.Count)
                                    states.Items[i] = byIndex[i].Label + " • " + probe.State;
                            }
                            catch (Exception ex)
                            {
                                if (!dialog.IsDisposed && i < states.Items.Count)
                                    states.Items[i] = byIndex[i].Label + " • STATUS ERROR: " + ShortTerminalText(ex.Message, 90);
                            }
                        }
                    };

                    var operationBusy = false;
                    var statusTimer = new Timer { Interval = 3000 };
                    statusTimer.Tick += async delegate
                    {
                        if (operationBusy || dialog.IsDisposed) return;
                        operationBusy = true;
                        try { await refreshStates(); }
                        finally { operationBusy = false; }
                    };
                    dialog.FormClosed += delegate
                    {
                        statusTimer.Stop();
                        var ids = new HashSet<string>(StringComparer.Ordinal);
                        for (var i = 0; i < byIndex.Count; i++) if (accounts.GetItemChecked(i)) ids.Add(byIndex[i].Id);
                        SaveTerminalWindowsSelections(prefPath, ids);
                    };

                    all.Click += delegate { for (var i = 0; i < accounts.Items.Count; i++) accounts.SetItemChecked(i, true); };
                    clear.Click += delegate { for (var i = 0; i < accounts.Items.Count; i++) accounts.SetItemChecked(i, false); };
                    close.Click += delegate { dialog.Close(); };
                    refresh.Click += async delegate
                    {
                        if (operationBusy) return;
                        operationBusy = true;
                        ToggleTerminalButtons(false, start, stop, refresh, all, clear);
                        try { await refreshStates(); }
                        finally { ToggleTerminalButtons(true, start, stop, refresh, all, clear); operationBusy = false; }
                    };
                    start.Click += async delegate
                    {
                        if (operationBusy) return;
                        operationBusy = true;
                        ToggleTerminalButtons(false, start, stop, refresh, all, clear);
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
                                var probe = await StartTerminalWindowsWorkerAsync(bundle.Path, realm, account);
                                states.Items[i] = account.Label + " • " + probe.State;
                                started++;
                            }
                            SaveTerminalWindowsSelections(prefPath, ids);
                            Log("TERMINAL WIN: uruchomiono/przejęto " + started + " workerów.");
                        }
                        catch (Exception ex)
                        {
                            Log("TERMINAL WIN START ERROR: " + ex.Message);
                            MessageBox.Show(dialog, ex.Message, "TERMINAL WIN", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                        finally
                        {
                            ToggleTerminalButtons(true, start, stop, refresh, all, clear);
                            operationBusy = false;
                            await refreshStates();
                        }
                    };
                    stop.Click += async delegate
                    {
                        if (operationBusy) return;
                        operationBusy = true;
                        ToggleTerminalButtons(false, start, stop, refresh, all, clear);
                        try
                        {
                            var stopped = 0;
                            for (var i = 0; i < byIndex.Count; i++)
                            {
                                if (!accounts.GetItemChecked(i)) continue;
                                states.Items[i] = byIndex[i].Label + " • STOPPING";
                                await StopTerminalWindowsWorkerAsync(byIndex[i]);
                                states.Items[i] = byIndex[i].Label + " • STOPPED";
                                stopped++;
                            }
                            Log("TERMINAL WIN: zatrzymano " + stopped + " workerów.");
                        }
                        catch (Exception ex)
                        {
                            Log("TERMINAL WIN STOP ERROR: " + ex.Message);
                            MessageBox.Show(dialog, ex.Message, "TERMINAL WIN", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                        finally
                        {
                            ToggleTerminalButtons(true, start, stop, refresh, all, clear);
                            operationBusy = false;
                        }
                    };

                    SetBusy(false, "TERMINAL WIN gotowy.");
                    await refreshStates();
                    statusTimer.Start();
                    dialog.ShowDialog(this);
                }
            }
            catch (Exception ex)
            {
                SetBusy(false, "TERMINAL WIN: błąd");
                Log("TERMINAL WIN BŁĄD: " + ex.Message);
                MessageBox.Show(this, ex.Message, "TERMINAL WIN", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                terminalWindowsBusy = false;
                if (busy) SetBusy(false, "Gotowy");
            }
        }

        private async Task<TerminalWindowsBundle> EnsureTerminalWindowsBinaryAsync()
        {
            var companionDir = Path.Combine(configDir, "companions", "windows-portal-v3-summoner-invite");
            Directory.CreateDirectory(companionDir);
            var dest = Path.Combine(companionDir, TerminalWindowsBinaryName);
            var stamp = Path.Combine(companionDir, "verified.txt");

            TerminalWindowsBundle cached;
            if (TryLoadTerminalWindowsCachedBinary(dest, stamp, out cached))
            {
                Log("TERMINAL WIN: LOCAL CACHE HIT " + cached.GitSha.Substring(0, 8) + " / " + cached.Sha256.Substring(0, 12) + "…; GitHub pominięty.");
                return cached;
            }

            if (string.IsNullOrWhiteSpace(token.Text))
                throw new InvalidOperationException("Brak lokalnego workera Windows. Wpisz token GitHub jednorazowo, aby pobrać i zweryfikować cache.");

            Log("TERMINAL WIN: cache MISS/INVALID; pobieram zweryfikowany native artifact z GitHub.");
            using (var client = CreateClient())
            {
                var runsUrl = ApiRoot + "/actions/workflows/" + TerminalWindowsWorkflow + "/runs?branch=parallel&per_page=20";
                var runsRoot = AsDictionary(json.DeserializeObject(await GetStringAsync(client, runsUrl)));
                var runs = AsArray(GetValue(runsRoot, "workflow_runs"));
                var run = UpdaterSafety.RequireLatestSuccessfulRun(runs, TerminalWindowsWorkflowName, "parallel");
                var runId = GetLong(run, "id");
                var runSha = GetString(run, "head_sha");
                if (string.IsNullOrWhiteSpace(runSha)) throw new InvalidDataException("Windows workflow nie podał head_sha.");

                var artifactsRoot = AsDictionary(json.DeserializeObject(await GetStringAsync(client, ApiRoot + "/actions/runs/" + runId + "/artifacts?per_page=100")));
                Dictionary<string, object> artifact = null;
                foreach (var item in AsArray(GetValue(artifactsRoot, "artifacts")))
                {
                    var row = AsDictionary(item);
                    if (!GetBool(row, "expired") && string.Equals(GetString(row, "name"), TerminalWindowsArtifactPrefix + runSha, StringComparison.OrdinalIgnoreCase))
                    { artifact = row; break; }
                }
                if (artifact == null) throw new InvalidOperationException("Brak zweryfikowanego Windows headless artifactu dla latest successful parallel.");

                byte[] outer;
                using (var response = await client.GetAsync(GetString(artifact, "archive_download_url"), HttpCompletionOption.ResponseHeadersRead))
                {
                    if (!response.IsSuccessStatusCode) throw new InvalidOperationException("Pobranie Windows artifactu: GitHub HTTP " + (int)response.StatusCode + ".");
                    outer = await response.Content.ReadAsByteArrayAsync();
                }
                var artifactDigest = GetString(artifact, "digest");
                if (!string.IsNullOrWhiteSpace(artifactDigest) && artifactDigest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
                {
                    var expectedOuter = artifactDigest.Substring(7);
                    if (!string.Equals(expectedOuter, TerminalSha256(outer), StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("Windows artifact digest mismatch.");
                }

                byte[] binary = null;
                string buildInfo = null;
                string sums = null;
                using (var ms = new MemoryStream(outer, false))
                using (var zip = new ZipArchive(ms, ZipArchiveMode.Read, false))
                {
                    var binaryEntry = zip.Entries.FirstOrDefault(e => string.Equals(Path.GetFileName(e.FullName), TerminalWindowsBinaryName, StringComparison.OrdinalIgnoreCase));
                    var infoEntry = zip.Entries.FirstOrDefault(e => string.Equals(Path.GetFileName(e.FullName), "BUILD_INFO.txt", StringComparison.OrdinalIgnoreCase));
                    var sumsEntry = zip.Entries.FirstOrDefault(e => string.Equals(Path.GetFileName(e.FullName), "SHA256SUMS.txt", StringComparison.OrdinalIgnoreCase));
                    if (binaryEntry == null || infoEntry == null || sumsEntry == null)
                        throw new InvalidDataException("Windows artifact nie zawiera binary + BUILD_INFO + SHA256SUMS.");
                    binary = ReadTerminalEntry(binaryEntry);
                    buildInfo = Encoding.UTF8.GetString(ReadTerminalEntry(infoEntry));
                    sums = Encoding.UTF8.GetString(ReadTerminalEntry(sumsEntry));
                }

                var binarySha = TerminalSha256(binary);
                if (!Regex.IsMatch(buildInfo, "(?m)^EXACT_SHA=" + Regex.Escape(runSha) + "\\s*$"))
                    throw new InvalidDataException("Windows BUILD_INFO exact SHA mismatch.");
                if (!Regex.IsMatch(buildInfo, "(?mi)^BINARY_SHA256=" + Regex.Escape(binarySha) + "\\s*$"))
                    throw new InvalidDataException("Windows BUILD_INFO binary SHA mismatch.");
                var sumMatch = Regex.Match(sums, "(?mi)^([0-9a-f]{64})\\s+\\*?" + Regex.Escape(TerminalWindowsBinaryName) + "\\s*$");
                if (!sumMatch.Success || !string.Equals(sumMatch.Groups[1].Value, binarySha, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Windows SHA256SUMS binary mismatch.");

                var temp = dest + ".tmp";
                File.WriteAllBytes(temp, binary);
                if (!string.Equals(TerminalSha256(File.ReadAllBytes(temp)), binarySha, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Windows binary SHA mismatch po zapisie.");
                if (File.Exists(dest)) File.Delete(dest);
                File.Move(temp, dest);
                UpdaterSafety.WriteUtf8Atomic(stamp, "GIT_SHA=" + runSha + "\nBINARY_SHA256=" + binarySha + "\nRUN_ID=" + runId + "\n", ".tmp", ".previous");
                Log("TERMINAL WIN binary verified: " + runSha.Substring(0, Math.Min(8, runSha.Length)) + " / run " + runId + ".");
                return new TerminalWindowsBundle { Path = dest, GitSha = runSha, Sha256 = binarySha };
            }
        }

        private bool TryLoadTerminalWindowsCachedBinary(string dest, string stamp, out TerminalWindowsBundle bundle)
        {
            bundle = null;
            if (!File.Exists(dest) || !File.Exists(stamp)) return false;
            try
            {
                var saved = File.ReadAllLines(stamp);
                var savedSha = saved.FirstOrDefault(x => x.StartsWith("GIT_SHA=", StringComparison.Ordinal));
                var savedBin = saved.FirstOrDefault(x => x.StartsWith("BINARY_SHA256=", StringComparison.Ordinal));
                if (savedSha == null || savedBin == null) return false;
                var gitSha = savedSha.Substring("GIT_SHA=".Length).Trim();
                var expected = savedBin.Substring("BINARY_SHA256=".Length).Trim();
                if (!Regex.IsMatch(gitSha, "^[0-9a-fA-F]{40}$") || !Regex.IsMatch(expected, "^[0-9a-fA-F]{64}$")) return false;
                var actual = TerminalSha256(File.ReadAllBytes(dest));
                if (!string.Equals(expected, actual, StringComparison.OrdinalIgnoreCase)) return false;
                bundle = new TerminalWindowsBundle { Path = dest, GitSha = gitSha, Sha256 = actual };
                return true;
            }
            catch { return false; }
        }

        private async Task<TerminalWindowsProbe> StartTerminalWindowsWorkerAsync(string binary, string realmHost, WowAccount account)
        {
            if (account == null) throw new ArgumentNullException("account");
            var password = accountVault.Unprotect(account);
            if (string.IsNullOrEmpty(password)) throw new InvalidDataException("Puste hasło profilu: " + account.Label);
            await StopTerminalWindowsWorkerAsync(account);

            var paths = TerminalWindowsPaths(account);
            var stopFile = paths.Item1 + ".stop";
            try { if (File.Exists(stopFile)) File.Delete(stopFile); } catch { }
            Directory.CreateDirectory(Path.GetDirectoryName(paths.Item1));
            TerminalWindowsProbe last = null;
            for (var attempt = 1; attempt <= 2; attempt++)
            {
                if (File.Exists(paths.Item2)) File.Delete(paths.Item2);
                var wrapper = paths.Item1 + ".cmd";
                File.WriteAllText(wrapper, "@echo off\r\n\"" + binary.Replace("\"", "\"\"") + "\" >> \"" + paths.Item2.Replace("\"", "\"\"") + "\" 2>&1\r\nexit /b %errorlevel%\r\n", Encoding.ASCII);

                var comspec = Environment.GetEnvironmentVariable("ComSpec");
                if (string.IsNullOrWhiteSpace(comspec)) comspec = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
                var psi = new ProcessStartInfo
                {
                    FileName = comspec,
                    Arguments = "/d /c call " + TerminalWindowsQuote(wrapper),
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WorkingDirectory = Path.GetDirectoryName(binary)
                };
                psi.EnvironmentVariables["WOW112_MODE"] = "portal-clicker";
                psi.EnvironmentVariables["WOW112_AUTH_ADDR"] = realmHost + ":3724";
                psi.EnvironmentVariables["WOW112_ACCOUNT"] = account.Login;
                psi.EnvironmentVariables["WOW112_PASSWORD"] = password;
                psi.EnvironmentVariables["WOW112_REALM_INDEX"] = "1";
                psi.EnvironmentVariables["WOW112_SOAK_SECONDS"] = "0";
                psi.EnvironmentVariables["WOW112_RECONNECT_LIMIT"] = "60";
                psi.EnvironmentVariables["WOW112_RECONNECT_DELAY_MS"] = "0";
                psi.EnvironmentVariables["WOW112_PORTAL_ATTEMPTS"] = "3";
                psi.EnvironmentVariables["WOW112_SUMMONER_NAMES"] = GetConfiguredSummonerNamesCsv();
                psi.EnvironmentVariables["WOW112_STOP_FILE"] = stopFile;

                var process = System.Diagnostics.Process.Start(psi);
                if (process == null) throw new InvalidOperationException(account.Label + ": nie udało się uruchomić native workera.");
                File.WriteAllText(paths.Item1, process.Id.ToString(), Encoding.ASCII);
                process.Dispose();

                for (var i = 0; i < 10; i++)
                {
                    await Task.Delay(500);
                    last = await ProbeTerminalWindowsWorkerAsync(account);
                    if (last.Running)
                    {
                        Log("TERMINAL WIN: " + account.Label + " worker ACTIVE/RUNNING (attempt " + attempt + ").");
                        return last;
                    }
                }
                if (attempt < 2)
                {
                    Log("TERMINAL WIN: " + account.Label + " szybki exit, automatyczny retry 1/1: " + TerminalWindowsFailureText(last == null ? "" : last.Tail, 220));
                    await StopTerminalWindowsWorkerAsync(account);
                    await Task.Delay(750);
                }
            }
            throw new InvalidOperationException(account.Label + ": worker nie utrzymał procesu po 2 próbach. " + TerminalWindowsFailureText(last == null ? "" : last.Tail, 300));
        }

        private async Task StopTerminalWindowsWorkerAsync(WowAccount account)
        {
            var paths = TerminalWindowsPaths(account);
            var stopFile = paths.Item1 + ".stop";
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(paths.Item1));
                File.WriteAllText(stopFile, "STOP " + DateTime.UtcNow.ToString("O"), Encoding.ASCII);
            }
            catch { }

            Log("TERMINAL WIN: " + account.Label + " cooperative STOP requested; czekam na zamknięcie world socket.");
            await Task.Delay(1500);

            int pid;
            if (File.Exists(paths.Item1) && int.TryParse(File.ReadAllText(paths.Item1).Trim(), out pid) && pid > 0)
            {
                var wrapperStillRunning = false;
                try
                {
                    using (var process = Process.GetProcessById(pid)) wrapperStillRunning = !process.HasExited;
                }
                catch { wrapperStillRunning = false; }

                if (wrapperStillRunning)
                {
                    try { await RunTerminalProcessAsync("taskkill.exe", new[] { "/PID", pid.ToString(), "/T", "/F" }, 12000); }
                    catch { }
                    await Task.Delay(300);
                }
            }

            try { if (File.Exists(paths.Item1)) File.Delete(paths.Item1); } catch { }
            Log("TERMINAL WIN: " + account.Label + " STOP complete; stop tombstone pozostaje do następnego START.");
        }

        private Task<TerminalWindowsProbe> ProbeTerminalWindowsWorkerAsync(WowAccount account)
        {
            return Task.Run(delegate
            {
                var paths = TerminalWindowsPaths(account);
                var running = false;
                int pid;
                if (File.Exists(paths.Item1) && int.TryParse(File.ReadAllText(paths.Item1).Trim(), out pid) && pid > 0)
                {
                    try
                    {
                        using (var process = Process.GetProcessById(pid)) running = !process.HasExited;
                    }
                    catch { running = false; }
                }

                var tail = ReadTerminalWindowsTail(paths.Item2, 24);
                var state = "STOPPED";
                if (running)
                {
                    if (tail.IndexOf("[PORTAL] USE attempt=", StringComparison.Ordinal) >= 0) state = "CLICKED";
                    else if (tail.IndexOf("[PORTAL] discovered", StringComparison.Ordinal) >= 0) state = "PORTAL FOUND";
                    else if (tail.IndexOf("[PORTAL] CLICKER ACTIVE", StringComparison.Ordinal) >= 0) state = "ACTIVE";
                    else if (tail.IndexOf("SMSG_LOGIN_VERIFY_WORLD", StringComparison.Ordinal) >= 0) state = "WORLD";
                    else state = "RUNNING";
                }
                else if (!string.IsNullOrWhiteSpace(tail)) state = "ERROR/EXIT";
                return new TerminalWindowsProbe { Running = running, State = state, Tail = tail };
            });
        }

        private Tuple<string, string> TerminalWindowsPaths(WowAccount account)
        {
            var source = string.IsNullOrWhiteSpace(account.Id) ? account.Login : account.Id;
            var safe = Regex.Replace(source ?? "account", "[^A-Za-z0-9_.-]+", "_");
            if (safe.Length > 48) safe = safe.Substring(0, 48);
            var dir = Path.Combine(configDir, "terminal_windows");
            return Tuple.Create(Path.Combine(dir, safe + ".pid"), Path.Combine(dir, safe + ".log"));
        }

        private static string ReadTerminalWindowsTail(string path, int maxLines)
        {
            if (!File.Exists(path)) return "";
            try
            {
                var queue = new Queue<string>();
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var reader = new StreamReader(stream, Encoding.UTF8, true))
                {
                    string line;
                    while ((line = reader.ReadLine()) != null)
                    {
                        queue.Enqueue(line);
                        while (queue.Count > maxLines) queue.Dequeue();
                    }
                }
                return string.Join("\n", queue.ToArray());
            }
            catch { return ""; }
        }

        private static string TerminalWindowsFailureText(string value, int max)
        {
            if (string.IsNullOrWhiteSpace(value)) return "brak końcowego logu workera";
            var lines = value.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            for (var i = lines.Length - 1; i >= 0; i--)
            {
                if (lines[i].IndexOf("ERROR", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    lines[i].IndexOf("failed", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    lines[i].IndexOf("out of range", StringComparison.OrdinalIgnoreCase) >= 0)
                    return ShortTerminalText(lines[i], max);
            }
            var text = ShortTerminalText(value, Math.Max(max * 3, max));
            return text.Length <= max ? text : "…" + text.Substring(text.Length - max + 1);
        }

        private void SaveTerminalWindowsSelections(string path, HashSet<string> ids)
        {
            var root = new Dictionary<string, object>();
            root["schema_version"] = 1;
            root["backend"] = "windows-native-v2-stop-safe";
            root["account_ids"] = ids.OrderBy(x => x, StringComparer.Ordinal).ToArray();
            UpdaterSafety.WriteUtf8Atomic(path, json.Serialize(root), ".tmp", ".previous");
        }
    }
}


