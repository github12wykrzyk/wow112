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
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        private const string TerminalAndroidWorkflow = "build_android_headless_probe.yml";
        private const string TerminalAndroidWorkflowName = "Build Android WoW112 headless probe";
        private const string TerminalAndroidArtifactPrefix = "WoW112-Android-Headless-POC05-";
        private const string TerminalAndroidBinaryName = "wow112-headless-android-probe";
        private const string TerminalAndroidRemoteBinary = "/data/local/tmp/wow112-headless-android-probe";
        private readonly Timer terminalPortalAttachTimer = CreateTerminalPortalAttachTimer();
        private bool terminalPortalAttached;
        private bool terminalPortalBusy;

        private sealed class TerminalAndroidBundle
        {
            public string Path;
            public string GitSha;
            public string Sha256;
        }

        private sealed class TerminalCommandResult
        {
            public int ExitCode;
            public string Output;
        }

        private sealed class TerminalPortalProbe
        {
            public bool Running;
            public string State;
            public string Tail;
        }

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
            var multibox = featureControls.ContainsKey("multibox") ? featureControls["multibox"] as Button : null;
            if (multibox != null)
            {
                var menu = multibox.ContextMenuStrip ?? new ContextMenuStrip();
                var terminalItem = new ToolStripMenuItem("Terminal portal clickers (Android headless)");
                terminalItem.Click += async delegate { await ShowTerminalPortalAsync(); };
                menu.Items.Add(terminalItem);
                multibox.ContextMenuStrip = menu;
            }
            Log("MULTIBOX TERMINAL Android gotowy: PPM na MULTIBOX -> Terminal portal clickers.");
        }

        private async Task ShowTerminalPortalAsync()
        {
            if (terminalPortalBusy || busy) return;
            if (accountVault == null || accountVault.Data.Accounts.Count == 0)
            {
                MessageBox.Show(this, "Najpierw dodaj konta w „Konta WoW”.", "MULTIBOX TERMINAL", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            terminalPortalBusy = true;
            try
            {
                SetBusy(true, "MULTIBOX TERMINAL: sprawdzam lokalny Android headless...");
                var bundle = await EnsureTerminalPortalAndroidBinaryAsync();
                var adb = ResolveTerminalAdb();
                await PrepareTerminalPortalAndroidAsync(adb, bundle);
                var realm = ResolveTerminalRealmHost();

                using (var dialog = new Form
                {
                    Text = "MULTIBOX TERMINAL — Android headless portal clickers",
                    ClientSize = new Size(860, 540),
                    MinimumSize = new Size(876, 579),
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
                        Location = new Point(14, 12), Size = new Size(830, 48),
                        Text = "Android headless V5: jeden shared executable, osobny PID/log na konto, pierwsza postać automatycznie, World z realm listy. Zamknięcie tego okna NIE zatrzymuje workerów. Realm: " + realm
                    };
                    var accounts = new CheckedListBox { Location = new Point(14, 66), Size = new Size(350, 365), CheckOnClick = true, IntegralHeight = false };
                    var states = new ListBox { Location = new Point(378, 66), Size = new Size(466, 365), IntegralHeight = false };
                    var start = new Button { Text = "START zaznaczone", Location = new Point(14, 446), Size = new Size(145, 38) };
                    var stop = new Button { Text = "STOP zaznaczone", Location = new Point(167, 446), Size = new Size(145, 38) };
                    var refresh = new Button { Text = "Odśwież", Location = new Point(320, 446), Size = new Size(112, 38) };
                    var all = new Button { Text = "Wszystkie", Location = new Point(440, 446), Size = new Size(105, 38) };
                    var clear = new Button { Text = "Wyczyść", Location = new Point(553, 446), Size = new Size(105, 38) };
                    var close = new Button { Text = "Zamknij", Location = new Point(666, 446), Size = new Size(178, 38) };
                    var footer = new Label
                    {
                        Location = new Point(14, 495), Size = new Size(830, 32),
                        Text = "Status odświeża się co 3 s. Start ma retry + grace period; pojedynczy worker nie może zamknąć loadera."
                    };
                    dialog.Controls.AddRange(new Control[] { info, accounts, states, start, stop, refresh, all, clear, close, footer });

                    var prefPath = Path.Combine(configDir, "terminal_portal_accounts.json");
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
                                var probe = await ProbeTerminalPortalWorkerAsync(adb, byIndex[i]);
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
                        SaveTerminalSelections(prefPath, ids);
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
                                var probe = await StartTerminalPortalWorkerAsync(adb, realm, account);
                                states.Items[i] = account.Label + " • " + probe.State;
                                started++;
                            }
                            SaveTerminalSelections(prefPath, ids);
                            Log("MULTIBOX TERMINAL Android: uruchomiono/przejęto " + started + " workerów.");
                        }
                        catch (Exception ex)
                        {
                            Log("MULTIBOX TERMINAL START ERROR: " + ex.Message);
                            MessageBox.Show(dialog, ex.Message, "MULTIBOX TERMINAL", MessageBoxButtons.OK, MessageBoxIcon.Error);
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
                                await StopTerminalPortalWorkerAsync(adb, byIndex[i]);
                                states.Items[i] = byIndex[i].Label + " • STOPPED";
                                stopped++;
                            }
                            Log("MULTIBOX TERMINAL Android: zatrzymano " + stopped + " workerów.");
                        }
                        catch (Exception ex)
                        {
                            Log("MULTIBOX TERMINAL STOP ERROR: " + ex.Message);
                            MessageBox.Show(dialog, ex.Message, "MULTIBOX TERMINAL", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                        finally
                        {
                            ToggleTerminalButtons(true, start, stop, refresh, all, clear);
                            operationBusy = false;
                        }
                    };

                    SetBusy(false, "MULTIBOX TERMINAL Android gotowy.");
                    await refreshStates();
                    statusTimer.Start();
                    dialog.ShowDialog(this);
                }
            }
            catch (Exception ex)
            {
                SetBusy(false, "MULTIBOX TERMINAL: błąd");
                Log("MULTIBOX TERMINAL Android BŁĄD: " + ex.Message);
                MessageBox.Show(this, ex.Message, "MULTIBOX TERMINAL", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                terminalPortalBusy = false;
                if (busy) SetBusy(false, "Gotowy");
            }
        }

        private static void ToggleTerminalButtons(bool enabled, params Button[] buttons)
        {
            foreach (var button in buttons) if (button != null && !button.IsDisposed) button.Enabled = enabled;
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

        private async Task<TerminalAndroidBundle> EnsureTerminalPortalAndroidBinaryAsync()
        {
            var companionDir = Path.Combine(configDir, "companions", "android-portal");
            Directory.CreateDirectory(companionDir);
            var dest = Path.Combine(companionDir, TerminalAndroidBinaryName);
            var stamp = Path.Combine(companionDir, "verified.txt");

            TerminalAndroidBundle cached;
            if (TryLoadTerminalPortalCachedBinary(dest, stamp, out cached))
            {
                Log("MULTIBOX TERMINAL: LOCAL CACHE HIT " + cached.GitSha.Substring(0, 8) + " / " + cached.Sha256.Substring(0, 12) + "…; GitHub pominięty.");
                return cached;
            }

            if (string.IsNullOrWhiteSpace(token.Text))
                throw new InvalidOperationException("Brak poprawnej lokalnej binarki Android portal clickera. Wpisz token GitHub jednorazowo, aby pobrać i zweryfikować cache.");

            Log("MULTIBOX TERMINAL: local cache MISS/INVALID; pobieram zweryfikowaną binarkę z GitHub jako fallback.");
            using (var client = CreateClient())
            {
                var runsUrl = ApiRoot + "/actions/workflows/" + TerminalAndroidWorkflow + "/runs?branch=parallel&per_page=20";
                var runsRoot = AsDictionary(json.DeserializeObject(await GetStringAsync(client, runsUrl)));
                var runs = AsArray(GetValue(runsRoot, "workflow_runs"));
                var run = UpdaterSafety.RequireLatestSuccessfulRun(runs, TerminalAndroidWorkflowName, "parallel");
                var runId = GetLong(run, "id");
                var runSha = GetString(run, "head_sha");
                if (string.IsNullOrWhiteSpace(runSha)) throw new InvalidDataException("Android workflow nie podał head_sha.");

                var artifactsRoot = AsDictionary(json.DeserializeObject(await GetStringAsync(client, ApiRoot + "/actions/runs/" + runId + "/artifacts?per_page=100")));
                Dictionary<string, object> artifact = null;
                foreach (var item in AsArray(GetValue(artifactsRoot, "artifacts")))
                {
                    var row = AsDictionary(item);
                    if (!GetBool(row, "expired") && string.Equals(GetString(row, "name"), TerminalAndroidArtifactPrefix + runSha, StringComparison.OrdinalIgnoreCase))
                    { artifact = row; break; }
                }
                if (artifact == null) throw new InvalidOperationException("Brak zweryfikowanego Android headless artifactu dla latest successful parallel.");

                byte[] outer;
                using (var response = await client.GetAsync(GetString(artifact, "archive_download_url"), HttpCompletionOption.ResponseHeadersRead))
                {
                    if (!response.IsSuccessStatusCode) throw new InvalidOperationException("Pobranie Android artifactu: GitHub HTTP " + (int)response.StatusCode + ".");
                    outer = await response.Content.ReadAsByteArrayAsync();
                }
                var artifactDigest = GetString(artifact, "digest");
                if (!string.IsNullOrWhiteSpace(artifactDigest) && artifactDigest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
                {
                    var expectedOuter = artifactDigest.Substring(7);
                    if (!string.Equals(expectedOuter, TerminalSha256(outer), StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("Android artifact digest mismatch.");
                }

                byte[] binary = null;
                string buildInfo = null;
                string sums = null;
                using (var ms = new MemoryStream(outer, false))
                using (var zip = new ZipArchive(ms, ZipArchiveMode.Read, false))
                {
                    var binaryEntry = zip.Entries.FirstOrDefault(e => string.Equals(Path.GetFileName(e.FullName), TerminalAndroidBinaryName, StringComparison.Ordinal));
                    var infoEntry = zip.Entries.FirstOrDefault(e => string.Equals(Path.GetFileName(e.FullName), "BUILD_INFO.txt", StringComparison.OrdinalIgnoreCase));
                    var sumsEntry = zip.Entries.FirstOrDefault(e => string.Equals(Path.GetFileName(e.FullName), "SHA256SUMS.txt", StringComparison.OrdinalIgnoreCase));
                    if (binaryEntry == null || infoEntry == null || sumsEntry == null)
                        throw new InvalidDataException("Android artifact nie zawiera binary + BUILD_INFO + SHA256SUMS.");
                    binary = ReadTerminalEntry(binaryEntry);
                    buildInfo = Encoding.UTF8.GetString(ReadTerminalEntry(infoEntry));
                    sums = Encoding.UTF8.GetString(ReadTerminalEntry(sumsEntry));
                }

                var binarySha = TerminalSha256(binary);
                if (!Regex.IsMatch(buildInfo, "(?m)^EXACT_SHA=" + Regex.Escape(runSha) + "\\s*$"))
                    throw new InvalidDataException("Android BUILD_INFO exact SHA mismatch.");
                if (!Regex.IsMatch(buildInfo, "(?mi)^BINARY_SHA256=" + Regex.Escape(binarySha) + "\\s*$"))
                    throw new InvalidDataException("Android BUILD_INFO binary SHA mismatch.");
                var sumMatch = Regex.Match(sums, "(?mi)^([0-9a-f]{64})\\s+\\*?" + Regex.Escape(TerminalAndroidBinaryName) + "\\s*$");
                if (!sumMatch.Success || !string.Equals(sumMatch.Groups[1].Value, binarySha, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Android SHA256SUMS binary mismatch.");

                var temp = dest + ".tmp";
                File.WriteAllBytes(temp, binary);
                if (!string.Equals(TerminalSha256(File.ReadAllBytes(temp)), binarySha, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Android binary SHA mismatch po zapisie.");
                if (File.Exists(dest)) File.Delete(dest);
                File.Move(temp, dest);
                UpdaterSafety.WriteUtf8Atomic(stamp, "GIT_SHA=" + runSha + "\nBINARY_SHA256=" + binarySha + "\nRUN_ID=" + runId + "\n", ".tmp", ".previous");
                Log("Android portal binary verified: " + runSha.Substring(0, Math.Min(8, runSha.Length)) + " / run " + runId + ".");
                return new TerminalAndroidBundle { Path = dest, GitSha = runSha, Sha256 = binarySha };
            }
        }

        private bool TryLoadTerminalPortalCachedBinary(string dest, string stamp, out TerminalAndroidBundle bundle)
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
                if (!Regex.IsMatch(gitSha, "^[0-9a-fA-F]{40}$") || !Regex.IsMatch(expected, "^[0-9a-fA-F]{64}$"))
                    return false;

                var actual = TerminalSha256(File.ReadAllBytes(dest));
                if (!string.Equals(expected, actual, StringComparison.OrdinalIgnoreCase))
                {
                    Log("MULTIBOX TERMINAL: local cache SHA256 mismatch; GitHub fallback wymagany.");
                    return false;
                }

                bundle = new TerminalAndroidBundle { Path = dest, GitSha = gitSha, Sha256 = actual };
                return true;
            }
            catch (Exception ex)
            {
                Log("MULTIBOX TERMINAL: local cache validation error: " + ShortTerminalText(ex.Message, 140));
                return false;
            }
        }

        private string ResolveTerminalAdb()
        {
            var candidates = new List<string>();
            candidates.Add(Path.Combine(System.Windows.Forms.Application.StartupPath, "platform-tools", "adb.exe"));
            candidates.Add(Path.Combine(System.Windows.Forms.Application.StartupPath, "adb.exe"));
            var sdkRoot = Environment.GetEnvironmentVariable("ANDROID_SDK_ROOT");
            var androidHome = Environment.GetEnvironmentVariable("ANDROID_HOME");
            var localApp = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (!string.IsNullOrWhiteSpace(sdkRoot)) candidates.Add(Path.Combine(sdkRoot, "platform-tools", "adb.exe"));
            if (!string.IsNullOrWhiteSpace(androidHome)) candidates.Add(Path.Combine(androidHome, "platform-tools", "adb.exe"));
            if (!string.IsNullOrWhiteSpace(localApp)) candidates.Add(Path.Combine(localApp, "Android", "Sdk", "platform-tools", "adb.exe"));
            foreach (var candidate in candidates) if (!string.IsNullOrWhiteSpace(candidate) && File.Exists(candidate)) return candidate;
            return "adb.exe";
        }

        private async Task PrepareTerminalPortalAndroidAsync(string adb, TerminalAndroidBundle bundle)
        {
            Log("MULTIBOX TERMINAL: ADB 1/4 start-server...");
            var start = await RunTerminalProcessAsync(adb, new[] { "start-server" }, 15000);
            if (start.ExitCode != 0) throw new InvalidOperationException("adb start-server: " + start.Output);

            Log("MULTIBOX TERMINAL: ADB 2/4 wait-for-device (max 20 s)...");
            var wait = await RunTerminalProcessAsync(adb, new[] { "wait-for-device" }, 20000);
            if (wait.ExitCode != 0) throw new InvalidOperationException("adb wait-for-device: " + wait.Output);

            var remoteTemp = TerminalAndroidRemoteBinary + ".new." + bundle.GitSha.Substring(0, Math.Min(8, bundle.GitSha.Length));
            Log("MULTIBOX TERMINAL: ADB 3/4 push shared executable...");
            var push = await RunTerminalProcessAsync(adb, new[] { "push", bundle.Path, remoteTemp }, 30000);
            if (push.ExitCode != 0) throw new InvalidOperationException("adb push Android binary: " + push.Output);

            Log("MULTIBOX TERMINAL: ADB 4/4 install shared executable...");
            var install = await RunTerminalAdbShellAsync(adb, "chmod 755 " + remoteTemp + " && mv -f " + remoteTemp + " " + TerminalAndroidRemoteBinary, false);
            if (install.ExitCode != 0) throw new InvalidOperationException("adb install Android binary: " + install.Output);
            Log("MULTIBOX TERMINAL: Android/ADB READY, shared executable " + bundle.Sha256.Substring(0, 12) + "…");
        }

        private async Task<TerminalPortalProbe> StartTerminalPortalWorkerAsync(string adb, string realmHost, WowAccount account)
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
                var launch = "rm -f " + paths.Item2 + " " + paths.Item1 + "; nohup env " + string.Join(" ", env.ToArray()) + " " + TerminalAndroidRemoteBinary + " >" + paths.Item2 + " 2>&1 </dev/null & echo $! >" + paths.Item1;
                var result = await RunTerminalAdbShellAsync(adb, launch, false);
                if (result.ExitCode != 0) throw new InvalidOperationException(account.Label + ": adb launch failed: " + result.Output);

                for (var i = 0; i < 10; i++)
                {
                    await Task.Delay(500);
                    last = await ProbeTerminalPortalWorkerAsync(adb, account);
                    if (last.Running)
                    {
                        Log("MULTIBOX TERMINAL: " + account.Label + " worker ACTIVE/RUNNING (attempt " + attempt + ").");
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

        private async Task StopTerminalPortalWorkerAsync(string adb, WowAccount account)
        {
            var paths = TerminalRemotePaths(account);
            var command = "if [ -f " + paths.Item1 + " ]; then P=$(cat " + paths.Item1 + "); if [ -n \"$P\" ]; then kill $P 2>/dev/null || true; fi; fi; rm -f " + paths.Item1;
            await RunTerminalAdbShellAsync(adb, command, true);
        }

        private async Task<TerminalPortalProbe> ProbeTerminalPortalWorkerAsync(string adb, WowAccount account)
        {
            var paths = TerminalRemotePaths(account);
            var command = "P=$(cat " + paths.Item1 + " 2>/dev/null); if [ -n \"$P\" ] && kill -0 $P 2>/dev/null; then echo __RUNNING__; else echo __DEAD__; fi; tail -n 16 " + paths.Item2 + " 2>/dev/null";
            var result = await RunTerminalAdbShellAsync(adb, command, true);
            var text = result.Output ?? "";
            var running = text.IndexOf("__RUNNING__", StringComparison.Ordinal) >= 0;
            var state = "STOPPED";
            if (running)
            {
                if (text.IndexOf("[PORTAL] USE attempt=", StringComparison.Ordinal) >= 0) state = "CLICKED";
                else if (text.IndexOf("[PORTAL] discovered", StringComparison.Ordinal) >= 0) state = "PORTAL FOUND";
                else if (text.IndexOf("[PORTAL] CLICKER ACTIVE", StringComparison.Ordinal) >= 0) state = "ACTIVE";
                else if (text.IndexOf("SMSG_LOGIN_VERIFY_WORLD", StringComparison.Ordinal) >= 0) state = "WORLD";
                else state = "RUNNING";
            }
            else if (text.IndexOf("__DEAD__", StringComparison.Ordinal) >= 0 && text.Replace("__DEAD__", "").Trim().Length > 0) state = "ERROR/EXIT";
            return new TerminalPortalProbe { Running = running, State = state, Tail = text.Replace("__RUNNING__", "").Replace("__DEAD__", "").Trim() };
        }

        private Tuple<string, string> TerminalRemotePaths(WowAccount account)
        {
            var source = string.IsNullOrWhiteSpace(account.Id) ? account.Login : account.Id;
            var bytes = Encoding.UTF8.GetBytes(source ?? "account");
            string key;
            using (var sha = SHA256.Create())
            {
                var hash = sha.ComputeHash(bytes);
                var sb = new StringBuilder(24);
                for (var i = 0; i < 12; i++) sb.Append(hash[i].ToString("x2"));
                key = sb.ToString();
            }
            var prefix = "/data/local/tmp/wow112_portal_" + key;
            return Tuple.Create(prefix + ".pid", prefix + ".log");
        }

        private async Task<TerminalCommandResult> RunTerminalAdbShellAsync(string adb, string command, bool ignoreExitCode)
        {
            var result = await RunTerminalProcessAsync(adb, new[] { "shell", command }, 20000);
            if (!ignoreExitCode && result.ExitCode != 0) throw new InvalidOperationException("adb shell failed (" + result.ExitCode + "): " + result.Output);
            return result;
        }

        private static Task<TerminalCommandResult> RunTerminalProcessAsync(string fileName, string[] args, int timeoutMs)
        {
            return Task.Run(delegate
            {
                var psi = new ProcessStartInfo
                {
                    FileName = fileName,
                    Arguments = string.Join(" ", args.Select(TerminalWindowsQuote).ToArray()),
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                using (var process = Process.Start(psi))
                {
                    if (process == null) throw new InvalidOperationException("Nie udało się uruchomić: " + fileName);
                    var stdoutTask = process.StandardOutput.ReadToEndAsync();
                    var stderrTask = process.StandardError.ReadToEndAsync();
                    if (!process.WaitForExit(timeoutMs))
                    {
                        try { process.Kill(); } catch { }
                        try { process.WaitForExit(2000); } catch { }
                        throw new TimeoutException(Path.GetFileName(fileName) + " timeout po " + timeoutMs + " ms.");
                    }
                    var stdout = stdoutTask.GetAwaiter().GetResult();
                    var stderr = stderrTask.GetAwaiter().GetResult();
                    var output = (stdout + (string.IsNullOrWhiteSpace(stderr) ? "" : ("\n" + stderr))).Trim();
                    return new TerminalCommandResult { ExitCode = process.ExitCode, Output = output };
                }
            });
        }

        private static string TerminalWindowsQuote(string value)
        {
            if (value == null) return "\"\"";
            if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '\"' }) < 0) return value;
            var sb = new StringBuilder();
            sb.Append('\"');
            var slashes = 0;
            foreach (var ch in value)
            {
                if (ch == '\\') { slashes++; continue; }
                if (ch == '\"')
                {
                    sb.Append('\\', slashes * 2 + 1);
                    sb.Append('\"');
                    slashes = 0;
                    continue;
                }
                if (slashes > 0) { sb.Append('\\', slashes); slashes = 0; }
                sb.Append(ch);
            }
            if (slashes > 0) sb.Append('\\', slashes * 2);
            sb.Append('\"');
            return sb.ToString();
        }

        private static string TerminalShellQuote(string value)
        {
            if (value == null) return "''";
            return "'" + value.Replace("'", "'\\''") + "'";
        }

        private static string ShortTerminalText(string value, int max)
        {
            if (string.IsNullOrWhiteSpace(value)) return "";
            var text = Regex.Replace(value, "\\s+", " ").Trim();
            return text.Length <= max ? text : text.Substring(0, max) + "…";
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
            root["schema_version"] = 2;
            root["backend"] = "android-detached-v5";
            root["account_ids"] = ids.OrderBy(x => x, StringComparer.Ordinal).ToArray();
            UpdaterSafety.WriteUtf8Atomic(path, json.Serialize(root), ".tmp", ".previous");
        }
    }
}