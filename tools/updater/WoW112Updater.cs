using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    internal sealed partial class MainForm : Form
    {
        private const string Owner = "github12wykrzyk";
        private const string Repo = "wow112";
        private const string ApiRoot = "https://api.github.com/repos/" + Owner + "/" + Repo;
        private const string TestWorkflowName = "Build work candidate";
        private const string EconomyWorkflowName = "Build parallel economy";
        private const string StableWorkflowName = "Build stable candidate";
        private const string TestArtifactPrefix = "WoW112-WORK-CANDIDATE-";
        private const string EconomyArtifactPrefix = "WoW112-PARALLEL-ECONOMY-";
        private const string StableArtifactPrefix = "WoW112-STABLE-CANDIDATE-";
        private const string TestInnerZip = "WoW112_WORK_CANDIDATE.zip";
        private const string EconomyInnerZip = "WoW112_PARALLEL_ECONOMY_OVERLAY.zip";
        private const string AngleInnerZip = "WoW112_PARALLEL_ROGUE_ANGLE_ONLY.zip";
        private const string AutoRearInnerZip = "WoW112_PARALLEL_ROGUE_AUTO_REAR.zip";
        private const string StableInnerZip = "WoW112_STABLE_CANDIDATE.zip";
        private const string UpdaterVersion = UpdaterBuildInfo.Version;
        private const int MaxBackups = 10;
        private const uint KillReloadCommand = 0xFFFFFFFEu;
        private const int KillReloadTimeoutMs = 15000;
        private const int KillReloadSettleMs = 1000;

        private readonly TextBox gameDir = new TextBox();
        private readonly TextBox token = new TextBox();
        private readonly ComboBox channel = new ComboBox();
        private readonly ComboBox rollbackChoice = new ComboBox();
        private readonly Label localInfo = new Label();
        private readonly Label status = new Label();
        private readonly RichTextBox log = new RichTextBox();
        private readonly ProgressBar progress = new ProgressBar();
        private readonly Button checkButton = new Button();
        private readonly Button updateButton = new Button();
        private readonly Button updatePlayButton = new Button();
        private readonly Button rollbackButton = new Button();
        private readonly Button launchButton = new Button();
        private readonly Button killAllButton = new Button();
        private readonly Button browseButton = new Button();
        private readonly Button saveButton = new Button();
        private readonly JavaScriptSerializer json = new JavaScriptSerializer();
        private readonly string configDir;
        private readonly string configPath;
        private RemotePackageInfo lastRemote;
        private bool busy;
        private bool lastUpdateDeferredRuntime;
        private bool pendingApplyBusy;
        private bool pendingApplyFaulted;
        private readonly Timer pendingApplyTimer = new Timer();

        public MainForm()
        {
            Text = "WoW112 PARALLEL Updater v" + UpdaterVersion;
            ClientSize = new Size(860, 660);
            MinimumSize = new Size(860, 660);
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 9F);

            configDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "WoW112ParallelUpdater");
            if (Environment.GetCommandLineArgs().Contains("--ui-smoke"))
                configDir = Path.Combine(Path.GetTempPath(), "WoW112ParallelUiSmoke-" + Guid.NewGuid().ToString("N"));
            configPath = Path.Combine(configDir, "config.json");

            BuildUi();
            LoadConfig();
            RefreshLocalState();

            pendingApplyTimer.Interval = 2000;
            pendingApplyTimer.Tick += delegate { TryFinalizePendingUpdate(); TryFinalizeEconomyPendingUpdate(); };
            pendingApplyTimer.Start();
            Shown += delegate { TryFinalizePendingUpdate(); TryFinalizeEconomyPendingUpdate(); };
        }

        private void BuildUi()
        {
            channel.DropDownStyle = ComboBoxStyle.DropDownList;
            channel.Items.AddRange(new object[] { "PARALLEL / STANDARD", "PARALLEL / ECONOMY", "PARALLEL / ANGLE-ONLY PvE", "PARALLEL / AUTO-REAR PvE" });
            channel.SelectedIndex = 0;
            rollbackChoice.DropDownStyle = ComboBoxStyle.DropDownList;
            token.UseSystemPasswordChar = true;
            browseButton.Click += BrowseButton_Click;
            checkButton.Click += async delegate { await CheckAsync(); };
            updateButton.Click += async delegate { await UpdateAsync(); };
            updatePlayButton.Click += async delegate { await UpdateAndPlayAsync(); };
            launchButton.Click += delegate { LaunchGame(); };
            killAllButton.Click += async delegate { await KillAllGameInstancesAsync(); };
            rollbackButton.Click += delegate { Rollback(); };
            saveButton.Click += delegate { SaveConfig(true); };
            status.Text = "Gotowy";
            log.ReadOnly = true;
        }

        private void BrowseButton_Click(object sender, EventArgs e)
        {
            using (var dialog = new FolderBrowserDialog())
            {
                dialog.Description = "Wybierz główny katalog World of Warcraft 1.12.1";
                dialog.SelectedPath = Directory.Exists(gameDir.Text) ? gameDir.Text : Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    gameDir.Text = dialog.SelectedPath;
                    SaveConfig(false);
                    RefreshLocalState();
                }
            }
        }

        private void SetBusy(bool value, string text)
        {
            busy = value;
            progress.Visible = true;
            progress.Style = value ? ProgressBarStyle.Marquee : ProgressBarStyle.Continuous;
            progress.MarqueeAnimationSpeed = value ? 25 : 0;
            progress.Value = 0;
            SetDashboardBusy(value);
            checkButton.Enabled = !value;
            updateButton.Enabled = !value;
            updatePlayButton.Enabled = !value;
            rollbackButton.Enabled = !value && rollbackChoice.Items.Count > 0;
            rollbackChoice.Enabled = !value && rollbackChoice.Items.Count > 0;
            launchButton.Enabled = !value;
            killAllButton.Enabled = !value;
            browseButton.Enabled = !value;
            saveButton.Enabled = !value;
            channel.Enabled = !value;
            status.Text = text;
            Cursor = value ? Cursors.WaitCursor : Cursors.Default;
        }

        private void Log(string message)
        {
            if (InvokeRequired) { BeginInvoke(new Action<string>(Log), message); return; }
            log.AppendText("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + message + Environment.NewLine);
            log.SelectionStart = log.TextLength;
            log.ScrollToCaret();
        }

        private void LoadConfig()
        {
            try
            {
                if (!File.Exists(configPath)) return;
                var root = AsDictionary(json.DeserializeObject(File.ReadAllText(configPath, Encoding.UTF8)));
                gameDir.Text = GetString(root, "game_dir");
                var selected = GetString(root, "channel");
                // This dedicated updater never adopts the original stable/work channel.
                var variant = GetString(root, "package_variant");
                channel.SelectedIndex = string.Equals(variant, "auto-rear", StringComparison.Ordinal) ? 3
                    : string.Equals(variant, "angle-only", StringComparison.Ordinal) ? 2
                    : string.Equals(variant, "economy", StringComparison.Ordinal) ? 1 : 0;
                LoadDllUpdatePreferences(root);
                LoadDllInstallDisabled(root);
                var protectedToken = GetString(root, "token_dpapi");
                if (!string.IsNullOrWhiteSpace(protectedToken))
                {
                    var raw = ProtectedData.Unprotect(Convert.FromBase64String(protectedToken), Entropy(), DataProtectionScope.CurrentUser);
                    token.Text = Encoding.UTF8.GetString(raw);
                }
            }
            catch (Exception ex)
            {
                Log("Nie udało się odczytać konfiguracji: " + ex.Message);
            }
        }

        private void SaveConfig(bool announce)
        {
            try
            {
                Directory.CreateDirectory(configDir);
                var protectedToken = string.Empty;
                if (!string.IsNullOrWhiteSpace(token.Text))
                {
                    protectedToken = Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(token.Text.Trim()), Entropy(), DataProtectionScope.CurrentUser));
                }
                var root = new Dictionary<string, object>();
                root["game_dir"] = gameDir.Text.Trim();
                root["channel"] = "parallel";
                root["package_variant"] = IsAutoRear() ? "auto-rear" : IsAngleOnly() ? "angle-only" : IsEconomy() ? "economy" : "full";
                root["token_dpapi"] = protectedToken;
                root["dll_update_enabled"] = GetDllUpdatePreferencesForSave();
                root["dll_install_disabled"] = GetDllInstallDisabledForSave();
                File.WriteAllText(configPath, json.Serialize(root), Encoding.UTF8);
                if (announce) Log("Ustawienia zapisane lokalnie.");
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Nie udało się zapisać ustawień:\n" + ex.Message, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private static byte[] Entropy()
        {
            return Encoding.UTF8.GetBytes("WoW112Updater-v1-private-repo-token");
        }

        private bool IsStable()
        {
            return false; // No route to main or work from this updater.
        }

        private bool IsEconomy() { return channel.SelectedIndex == 1; }
        private bool IsAngleOnly() { return channel.SelectedIndex == 2; }
        private bool IsAutoRear() { return channel.SelectedIndex == 3; }
        private static bool IsEconomyPackage(string name)
        {
            return string.Equals(name, EconomyInnerZip, StringComparison.OrdinalIgnoreCase);
        }
        private static bool IsAutoRearPackage(string name)
        {
            return string.Equals(name, AutoRearInnerZip, StringComparison.OrdinalIgnoreCase);
        }
        private static bool IsAnglePackage(string name)
        {
            return string.Equals(name, AngleInnerZip, StringComparison.OrdinalIgnoreCase);
        }

        private void ValidateInputs()
        {
            if (busy) throw new InvalidOperationException("Updater już wykonuje operację.");
            if (string.IsNullOrWhiteSpace(gameDir.Text) || !Directory.Exists(gameDir.Text.Trim()))
                throw new InvalidOperationException("Wybierz istniejący katalog gry.");
            if (string.IsNullOrWhiteSpace(token.Text))
                throw new InvalidOperationException("Wpisz GitHub token z prawem odczytu repozytorium i Actions.");
        }

        private async Task CheckAsync()
        {
            try
            {
                ValidateInputs();
                SaveConfig(false);
                SetBusy(true, "Sprawdzanie GitHuba...");
                lastRemote = await FindLatestPackageAsync();
                ShowRemotePackage();
                await InspectRemoteDllsAsync(lastRemote);
                await EnsureCurrentParallelHeadAsync(lastRemote);
                ShowRemoteDllSummary();
                var installed = ReadInstalledState();
                Log("Najnowszy build: " + ShortSha(lastRemote.HeadSha) + " / run " + lastRemote.RunId);

                var dllChanges = LastDllChangeCount;
                var enabledDllChanges = LastEnabledDllChangeCount;
                var skippedDllChanges = dllChanges - enabledDllChanges;
                var exeChanged = !IsEconomy() && (lastExeInspection == null || lastExeInspection.HasChange);
                var addonChanges = IsEconomy() ? lastEconomyAddonChangeCount : cachedVerifiedAddons.Count(addon =>
                {
                    var path = SafeDestination(gameDir.Text.Trim(), addon.Name);
                    return !File.Exists(path) ||
                        !string.Equals(Sha256File(path), Sha256(addon.Bytes), StringComparison.OrdinalIgnoreCase);
                });
                if (exeChanged || dllChanges > 0 || addonChanges > 0)
                {
                    if (IsEconomy())
                    {
                        status.Text = "ECONOMY • DLL: " + enabledDllChanges + " do aktualizacji"
                            + (skippedDllChanges > 0 ? " • " + skippedDllChanges + " pominiętych" : string.Empty)
                            + " • AddOny: " + addonChanges + " plików";
                        Log("ECONOMY: DLL " + dllChanges + " zmian, aktywne: " + enabledDllChanges
                            + "; AddOny: " + addonChanges + " plików do aktualizacji.");
                    }
                    else
                    {
                        status.Text = "EXE: " + (lastExeInspection == null ? "NIE SPRAWDZONO" : lastExeInspection.State)
                            + " • DLL: " + enabledDllChanges + " do aktualizacji"
                            + (skippedDllChanges > 0 ? " • " + skippedDllChanges + " pominiętych" : string.Empty)
                            + " • LS/LazyRogue: " + addonChanges + " plików do aktualizacji";
                        Log("EXE " + (exeChanged ? "wymaga aktualizacji" : "jest aktualny")
                            + "; DLL: " + dllChanges + " zmian, aktywne: " + enabledDllChanges
                            + "; dodatki LS/LazyRogue: " + addonChanges + " plików do aktualizacji.");
                    }
                }
                else if (IsEconomy())
                {
                    status.Text = "ECONOMY jest aktualny • overlay " + ShortSha(lastRemote.HeadSha) + ".";
                    Log("ECONOMY: wszystkie pliki overlayu odpowiadają najnowszemu artefaktowi.");
                }
                else if (installed != null && GetLong(installed, "run_id") == lastRemote.RunId && GetString(installed, "channel") == lastRemote.Channel)
                {
                    status.Text = "Masz najnowszą wersję " + lastRemote.Channel.ToUpperInvariant() + " • EXE, DLL i dodatki aktualne.";
                    Log("EXE, wszystkie DLL i pliki LS/LazyRogue odpowiadają najnowszemu artefaktowi.");
                }
                else
                {
                    status.Text = "Nowy build dostępny • EXE, DLL i dodatki bez zmian.";
                    Log("Nowy artefakt jest dostępny, ale SHA256 EXE, DLL i dodatków już są zgodne.");
                }
            }
            catch (Exception ex)
            {
                ShowRemoteFailure(ex);
                status.Text = "Błąd sprawdzania aktualizacji — szczegóły w logu";
                Log("BŁĄD: " + ex.Message);
            }
            finally
            {
                RefreshLocalState();
                SetBusy(false, status.Text);
            }
        }

        private async Task UpdateAsync()
        {
            try
            {
                ValidateInputs();
                var updateRoot = gameDir.Text.Trim();
                lastUpdateDeferredRuntime = false;
                if (IsGameRunning(updateRoot))
                    Log("LIVE UPDATE: WoW działa. AddOny oraz pliki root inne niż EXE spróbuję zaktualizować od razu; tylko pliki faktycznie zablokowane przez Windows i EXE zapiszę jako oczekujące.");

                SaveConfig(false);
                SetBusy(true, "Pobieranie najnowszej paczki...");
                lastRemote = await FindLatestPackageAsync();
                ShowRemotePackage();
                var innerBytes = await GetVerifiedPackageBytesAsync(lastRemote);
                if (IsEconomy()) InspectEconomyOverlay(innerBytes, gameDir.Text.Trim(), lastRemote.HeadSha);
                else InspectDllPackage(innerBytes, gameDir.Text.Trim());
                ShowRemoteDllSummary();
                // A newer push can happen during download or while comparing local DLLs.
                // Recheck immediately before applying any changes or writing a backup.
                await EnsureCurrentParallelHeadAsync(lastRemote);
                var installRoot = Path.GetFullPath(gameDir.Text.Trim());
                var installRemote = lastRemote;
                status.Text = "Instalowanie zweryfikowanych plików...";
                var addonFiles = new List<UpdaterAddonAsset>(cachedVerifiedAddons);
                var result = IsEconomy()
                    ? await Task.Run(() => ApplyEconomyOverlay(innerBytes, installRemote, installRoot))
                    : await Task.Run(() => ApplyPackage(innerBytes, installRemote, installRoot, addonFiles));
                lastUpdateDeferredRuntime = result.Deferred > 0;
                if (result.Deferred > 0)
                {
                    status.Text = "LIVE UPDATE: " + result.Changed + " plików zaktualizowano teraz; " + result.Deferred + " zablokowanych/EXE oczekuje na zamknięcie WoW.";
                    Log("LIVE UPDATE: aktywne instancje nie są zamykane. DLL/TXT i inne pliki root są podmieniane od razu, gdy Windows na to pozwala; tylko zablokowane pliki oraz EXE czekają na zamknięcie ostatniej instancji.");
                }
                else
                {
                    status.Text = result.Changed == 0
                        ? (IsEconomy() ? "ECONOMY już był aktualny." : "EXE i pozostałe pliki już były aktualne.")
                        : (IsEconomy() ? "ECONOMY zaktualizowany: " + result.Changed + " plików."
                            : "Aktualizacja zakończona: " + result.Changed + " plików"
                                + (result.ExeChanged ? " (w tym EXE)." : "."));
                }
                Log("Gotowe. Zmieniono teraz: " + result.Changed + ", oczekuje runtime: " + result.Deferred
                    + ", bez zmian: " + result.Unchanged
                    + "; EXE: " + (result.ExeChanged ? (result.Deferred > 0 ? "oczekuje" : "zaktualizowany") : "bez zmian") + ".");
                if (!string.IsNullOrWhiteSpace(result.BackupDir)) Log("Backup: " + result.BackupDir);
                TrimBackups(gameDir.Text.Trim(), MaxBackups);
                RefreshLocalState();
            }
            catch (Exception ex)
            {
                ShowRemoteFailure(ex);
                status.Text = "Aktualizacja nie powiodła się";
                Log("BŁĄD: " + ex.Message);
                MessageBox.Show(this, ex.Message, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                SetBusy(false, status.Text);
            }
        }

        private async Task UpdateAndPlayAsync()
        {
            await UpdateAsync();
            if (status.Text.StartsWith("Aktualizacja nie powiodła", StringComparison.OrdinalIgnoreCase))
                return;
            if (lastUpdateDeferredRuntime)
            {
                status.Text = "Runtime oczekuje na zamknięcie aktywnych instancji. Nie uruchamiam nowego klienta na starej wersji.";
                Log("UPDATE + PLAY: pomijam start nowej instancji, bo zweryfikowany runtime jest jeszcze oczekujący.");
                return;
            }

            status.Text = "Gotowe. Uruchamiam WoW...";
            LaunchGame();
        }

        private async Task<RemotePackageInfo> FindLatestPackageAsync()
        {
            var stable = IsStable();
            var branch = "parallel";
            var workflowName = stable ? StableWorkflowName : (IsEconomy() ? EconomyWorkflowName : TestWorkflowName);
            var prefix = stable ? StableArtifactPrefix : (IsEconomy() ? EconomyArtifactPrefix : TestArtifactPrefix);
            var innerName = stable ? StableInnerZip : (IsEconomy() ? EconomyInnerZip : IsAutoRear() ? AutoRearInnerZip
                : IsAngleOnly() ? AngleInnerZip : TestInnerZip);

            using (var client = CreateClient())
            {
                // Resolve the branch HEAD first, then wait only for the workflow of that
                // exact SHA. GitHub can expose a new branch HEAD a few seconds before the
                // corresponding Actions run appears; selecting "latest run" first creates
                // a TOCTOU race and can momentarily pick the previous successful package.
                for (var attempt = 0; attempt < 3; attempt++)
                {
                    var chosen = IsEconomy()
                        ? await WaitForCurrentHeadEconomyRunAsync(client, branch)
                        : await WaitForCurrentHeadSuccessfulRunAsync(client, workflowName, branch);
                    var runId = GetLong(chosen, "id");
                    var chosenSha = GetString(chosen, "head_sha");

                    var branchInfo = AsDictionary(json.DeserializeObject(
                        await GetStringAsync(client, ApiRoot + "/branches/" + branch)));
                    var currentHead = GetString(AsDictionary(GetValue(branchInfo, "commit")), "sha");
                    if (!string.Equals(chosenSha, currentHead, StringComparison.OrdinalIgnoreCase))
                    {
                        Log("HEAD Parallel zmienił się podczas wyboru paczki (" +
                            ShortSha(chosenSha) + " -> " + ShortSha(currentHead) +
                            "). Ponawiam automatycznie dla nowego HEAD.");
                        status.Text = "Parallel dostał nowy commit • czekam na jego build...";
                        continue;
                    }

                    var artifactsRoot = AsDictionary(json.DeserializeObject(
                        await GetStringAsync(client, ApiRoot + "/actions/runs/" + runId + "/artifacts?per_page=100")));
                    var artifacts = AsArray(GetValue(artifactsRoot, "artifacts"));
                    Dictionary<string, object> artifact = null;
                    foreach (var item in artifacts)
                    {
                        var row = AsDictionary(item);
                        var name = GetString(row, "name");
                        var expired = GetBool(row, "expired");
                        if (!expired && string.Equals(name, prefix + chosenSha, StringComparison.OrdinalIgnoreCase))
                        {
                            artifact = row;
                            break;
                        }
                    }
                    if (artifact == null)
                        throw new InvalidOperationException("Najnowszy udany workflow nie ma aktywnego artefaktu " + prefix + "*.");

                    return new RemotePackageInfo
                    {
                        Channel = "parallel",
                        RunId = runId,
                        HeadSha = chosenSha,
                        ArtifactName = GetString(artifact, "name"),
                        DownloadUrl = GetString(artifact, "archive_download_url"),
                        InnerZipName = innerName
                    };
                }

                throw new InvalidOperationException(
                    "HEAD Parallel zmieniał się podczas przygotowywania aktualizacji. " +
                    "Updater nie zainstaluje starszej paczki; spróbuj ponownie po zakończeniu bieżącego builda.");
            }
        }

        // Recheck the live branch after verifying the artifact; a head change
        // between selection and installation must never silently deploy an old ZIP.
        private async Task EnsureCurrentParallelHeadAsync(RemotePackageInfo remote)
        {
            if (remote == null || !string.Equals(remote.Channel, "parallel", StringComparison.Ordinal))
                throw new InvalidOperationException("Updater obsługuje wyłącznie kanał parallel.");
            using (var client = CreateClient())
            {
                var branchInfo = AsDictionary(json.DeserializeObject(
                    await GetStringAsync(client, ApiRoot + "/branches/parallel")));
                var head = GetString(AsDictionary(GetValue(branchInfo, "commit")), "sha");
                UpdaterSafety.RequireCurrentParallelHead(remote.HeadSha, head);
            }
        }

        private async Task<Dictionary<string, object>> WaitForCurrentHeadSuccessfulRunAsync(
            HttpClient client, string workflowName, string branch)
        {
            var deadlineUtc = DateTime.UtcNow.AddMinutes(3);
            var trackedHead = string.Empty;
            var waitingRunId = 0L;

            while (true)
            {
                var branchInfo = AsDictionary(json.DeserializeObject(
                    await GetStringAsync(client, ApiRoot + "/branches/" + branch)));
                var currentHead = GetString(AsDictionary(GetValue(branchInfo, "commit")), "sha");
                // Reuse the strict SHA validator without weakening the existing stale-package gate.
                UpdaterSafety.RequireCurrentParallelHead(currentHead, currentHead);

                if (!string.Equals(trackedHead, currentHead, StringComparison.OrdinalIgnoreCase))
                {
                    if (!string.IsNullOrEmpty(trackedHead))
                        Log("Wykryto nowszy HEAD Parallel: " + ShortSha(trackedHead) +
                            " -> " + ShortSha(currentHead) + ". Czekam na jego własny build.");
                    trackedHead = currentHead;
                    waitingRunId = 0L;
                }

                var url = ApiRoot + "/actions/runs?branch=" + branch + "&per_page=50";
                var root = AsDictionary(json.DeserializeObject(await GetStringAsync(client, url)));
                var runs = AsArray(GetValue(root, "workflow_runs"));
                var exact = UpdaterSafety.FindRunForHead(runs, workflowName, branch, trackedHead);

                if (exact == null)
                {
                    if (DateTime.UtcNow >= deadlineUtc)
                        return UpdaterSafety.RequireSuccessfulRunForHead(runs, workflowName, branch, trackedHead);

                    status.Text = "Nowy HEAD " + ShortSha(trackedHead) +
                        " • czekam na uruchomienie jego builda...";
                    Log("HEAD Parallel " + ShortSha(trackedHead) +
                        " jest już widoczny, ale jego workflow jeszcze nie pojawił się w Actions. Czekam 3 s.");
                    await Task.Delay(3000);
                    continue;
                }

                var state = GetString(exact, "status");
                if (!string.Equals(state, "completed", StringComparison.OrdinalIgnoreCase)
                    && DateTime.UtcNow < deadlineUtc)
                {
                    var runId = GetLong(exact, "id");
                    if (waitingRunId != runId)
                    {
                        waitingRunId = runId;
                        Log("Build Parallel #" + runId + " dla HEAD " + ShortSha(trackedHead) +
                            " jest w toku (" + state + "). Czekam automatycznie; starszych paczek nie instaluję.");
                    }
                    status.Text = "Trwa build " + ShortSha(trackedHead) + " • sprawdzam co 8 s...";
                    await Task.Delay(8000);
                    continue;
                }

                var chosen = UpdaterSafety.RequireSuccessfulRunForHead(
                    runs, workflowName, branch, trackedHead);
                if (waitingRunId != 0)
                    Log("Build Parallel #" + GetLong(chosen, "id") + " dla HEAD " +
                        ShortSha(trackedHead) + " zakończony sukcesem; pobieram zweryfikowaną paczkę.");
                return chosen;
            }
        }

        private HttpClient CreateClient()
        {
            var handler = new HttpClientHandler { AllowAutoRedirect = true };
            var client = new HttpClient(handler);
            client.Timeout = TimeSpan.FromMinutes(3);
            client.DefaultRequestHeaders.UserAgent.ParseAdd("WoW112Updater/" + UpdaterVersion);
            client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
            client.DefaultRequestHeaders.Add("X-GitHub-Api-Version", "2022-11-28");
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Text.Trim());
            return client;
        }

        private async Task<string> GetStringAsync(HttpClient client, string url)
        {
            using (var response = await client.GetAsync(url))
            {
                var text = await response.Content.ReadAsStringAsync();
                if (!response.IsSuccessStatusCode)
                {
                    SetConnectionState((int)response.StatusCode == 401 || (int)response.StatusCode == 403
                        ? "GitHub: brak autoryzacji / dostępu" : "GitHub: błąd odpowiedzi");
                    throw new InvalidOperationException("GitHub HTTP " + (int)response.StatusCode + ": " + TrimForError(text));
                }
                SetConnectionState("GitHub: połączono");
                return text;
            }
        }

        private async Task<byte[]> DownloadBytesAsync(string url)
        {
            using (var client = CreateClient())
            using (var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead))
            {
                if (!response.IsSuccessStatusCode)
                {
                    var text = await response.Content.ReadAsStringAsync();
                    throw new InvalidOperationException("Pobieranie artefaktu: GitHub HTTP " + (int)response.StatusCode + ": " + TrimForError(text));
                }
                return await response.Content.ReadAsByteArrayAsync();
            }
        }

        private void ExtractInnerPackage(byte[] outerBytes, string innerZipName, string expectedHeadSha, out byte[] innerBytes, out string expectedSha)
        {
            innerBytes = null;
            expectedSha = string.Empty;
            using (var ms = new MemoryStream(outerBytes, false))
            using (var zip = new ZipArchive(ms, ZipArchiveMode.Read, false))
            {
                var inner = zip.Entries.FirstOrDefault(e => string.Equals(Path.GetFileName(e.FullName), innerZipName, StringComparison.OrdinalIgnoreCase));
                if (inner == null) throw new InvalidOperationException("Artefakt nie zawiera " + innerZipName + ".");
                innerBytes = ReadEntry(inner);

                var angle = IsAnglePackage(innerZipName);
                var autoRear = IsAutoRearPackage(innerZipName);
                var metadataFile = autoRear ? "rogue_auto_rear_metadata.json" : angle ? "rogue_angle_metadata.json" : "candidate_metadata.json";
                var summaryFile = autoRear ? "rogue_auto_rear_summary.json" : angle ? "rogue_angle_summary.json" : "candidate_summary.json";
                var finalFile = autoRear ? "rogue_auto_rear_final_verification.json" : angle ? "rogue_angle_final_verification.json" : "final_package_verification.json";
                var attestationFile = autoRear ? "rogue_auto_rear_attestation.json" : angle ? "rogue_angle_attestation.json" : "candidate_attestation.json";
                var metaEntry = zip.Entries.FirstOrDefault(e => string.Equals(Path.GetFileName(e.FullName), metadataFile, StringComparison.OrdinalIgnoreCase));
                if (metaEntry == null)
                    throw new InvalidOperationException("Artefakt nie zawiera " + metadataFile + "; instalacja została zablokowana.");
                var metaText = Encoding.UTF8.GetString(ReadEntry(metaEntry));
                var meta = AsDictionary(json.DeserializeObject(metaText));
                if (angle)
                {
                    var angleProof = AsDictionary(GetValue(meta, "angle_only_diagnostic"));
                    if (!string.Equals(GetString(angleProof, "name"), "parallel_rogue_angle_only", StringComparison.Ordinal)
                        || !string.Equals(GetString(angleProof, "commit_sha"), expectedHeadSha, StringComparison.OrdinalIgnoreCase)
                        || !GetBool(angleProof, "real_xyz_preserved") || !GetBool(angleProof, "player_orientation_only")
                        || GetBool(angleProof, "npc_server_facing_spoofed"))
                        throw new InvalidOperationException("Paczka ANGLE-ONLY nie ma zgodnego manifestu wariantu; instalacja zablokowana.");
                }
                if (autoRear)
                {
                    var autoProof = AsDictionary(GetValue(meta, "auto_rear_diagnostic"));
                    if (!string.Equals(GetString(autoProof, "name"), "parallel_rogue_auto_rear", StringComparison.Ordinal)
                        || !string.Equals(GetString(autoProof, "commit_sha"), expectedHeadSha, StringComparison.OrdinalIgnoreCase)
                        || !GetBool(autoProof, "real_xyz_preserved") || !GetBool(autoProof, "physical_strafe_input")
                        || GetBool(autoProof, "npc_server_facing_spoofed"))
                        throw new InvalidOperationException("Paczka AUTO-REAR nie ma zgodnego manifestu wariantu; instalacja zablokowana.");
                }
                expectedSha = GetString(meta, "package_sha256");
                if (!UpdaterSafety.IsSha256Hex(expectedSha))
                    throw new InvalidOperationException(metadataFile + " nie zawiera poprawnego package_sha256; instalacja została zablokowana.");

                if (expectedHeadSha.Length != 40 || !string.Equals(GetString(meta, "git_head"), expectedHeadSha, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Paczka nie pochodzi z commita wybranego runu CI.");
                var proof = AsDictionary(GetValue(meta, "final_package_verification"));
                if (!string.Equals(GetString(proof, "result"), "PASS", StringComparison.Ordinal)
                    || !string.Equals(GetString(proof, "package_sha256"), expectedSha, StringComparison.OrdinalIgnoreCase)
                    || !GetBool(proof, "loader_exact") || !GetBool(proof, "all_binary_entries_pe32_x86"))
                    throw new InvalidOperationException("Paczka nie zawiera zgodnego raportu FINAL_PACKAGE: PASS.");

                var reportEntry = zip.Entries.FirstOrDefault(e => e.FullName == finalFile);
                var summaryEntry = zip.Entries.FirstOrDefault(e => e.FullName == summaryFile);
                var attestationEntry = zip.Entries.FirstOrDefault(e => e.FullName == attestationFile);
                if (reportEntry == null || summaryEntry == null || attestationEntry == null)
                    throw new InvalidOperationException("Brakuje raportu FINAL_PACKAGE, podsumowania lub " + attestationFile + ".");
                var report = AsDictionary(json.DeserializeObject(Encoding.UTF8.GetString(ReadEntry(reportEntry))));
                var summary = AsDictionary(json.DeserializeObject(Encoding.UTF8.GetString(ReadEntry(summaryEntry))));
                var attestation = AsDictionary(json.DeserializeObject(Encoding.UTF8.GetString(ReadEntry(attestationEntry))));
                var packageSize = innerBytes.LongLength;
                if (GetLong(meta, "package_size") != packageSize
                    || GetLong(proof, "package_size") != packageSize
                    || !string.Equals(GetString(report, "result"), "PASS", StringComparison.Ordinal)
                    || !string.Equals(GetString(report, "package_sha256"), expectedSha, StringComparison.OrdinalIgnoreCase)
                    || GetLong(report, "package_size") != packageSize
                    || !string.Equals(GetString(summary, "head"), expectedHeadSha, StringComparison.OrdinalIgnoreCase)
                    || !string.Equals(GetString(summary, "result"), "PASS", StringComparison.Ordinal)
                    || !GetBool(summary, "ready_for_test")
                    || !string.Equals(GetString(summary, "package_sha256"), expectedSha, StringComparison.OrdinalIgnoreCase)
                    || GetLong(summary, "package_size") != packageSize)
                    throw new InvalidOperationException("Raport końcowy, commit, rozmiar i metadane paczki nie są spójne.");
                UpdaterSafety.RequireCandidateAttestation(attestation, expectedHeadSha, expectedSha, packageSize);
            }
        }

        private ApplyResult ApplyPackage(byte[] packageBytes, RemotePackageInfo remote, string root, IList<UpdaterAddonAsset> addonFiles)
        {
            var gameRunning = IsGameRunning(root);
            var files = new List<PackageFile>();
            var packageNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (var ms = new MemoryStream(packageBytes, false))
            using (var zip = new ZipArchive(ms, ZipArchiveMode.Read, false))
            {
                foreach (var entry in zip.Entries)
                {
                    if (string.IsNullOrWhiteSpace(entry.Name)) continue;
                    if (!string.Equals(entry.FullName, entry.Name, StringComparison.Ordinal))
                        throw new InvalidOperationException("Paczka zawiera zagnieżdżoną lub niebezpieczną ścieżkę: " + entry.FullName);
                    if (!packageNames.Add(entry.Name))
                        throw new InvalidOperationException("Paczka zawiera powieloną nazwę pliku (bez rozróżniania wielkości liter): " + entry.Name);
                    var ext = Path.GetExtension(entry.Name).ToLowerInvariant();
                    if (ext != ".dll" && ext != ".exe") continue;
                    var bytes = ReadEntry(entry);
                    files.Add(new PackageFile(entry.Name, bytes));
                }
            }
            if (!files.Any(f => f.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException("Paczka nie zawiera WoW.exe/canonical WoW executable.");
            if (!files.Any(f => f.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException("Paczka nie zawiera DLL-i.");

            foreach (var addon in addonFiles)
            {
                if (!packageNames.Add(addon.Name))
                    throw new InvalidOperationException("Konflikt nazwy pliku dodatku: " + addon.Name);
                files.Add(new PackageFile(addon.Name, addon.Bytes));
            }

            var oldState = ReadInstalledState(root);
            var oldManaged = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (oldState != null)
            {
                foreach (var value in AsArray(GetValue(oldState, "managed_files")))
                {
                    var name = Convert.ToString(value);
                    if (!string.IsNullOrWhiteSpace(name)) oldManaged.Add(name);
                }
            }

            var remoteDlls = files.Where(f => f.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)).ToList();
            var remoteDllNames = new HashSet<string>(remoteDlls.Select(f => f.Name), StringComparer.OrdinalIgnoreCase);
            var installFiles = new List<PackageFile>();
            var finalDllNames = new List<string>();

            foreach (var file in files)
            {
                if (!file.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
                {
                    installFiles.Add(file);
                    continue;
                }

                var dest = SafeDestination(root, file.Name);
                if (IsDllInstallDisabled(file.Name))
                {
                    Log("DISABLED " + file.Name + " (nie instaluję ani nie aktywuję)");
                }
                else if (IsDllUpdateEnabled(file.Name))
                {
                    installFiles.Add(file);
                    finalDllNames.Add(file.Name);
                }
                else if (File.Exists(dest))
                {
                    finalDllNames.Add(file.Name);
                    Log("HOLD " + file.Name + " (aktualizacja DLL wyłączona; zachowuję lokalną wersję)");
                }
                else
                {
                    Log("SKIP " + file.Name + " (aktualizacja DLL wyłączona; brak lokalnego pliku)");
                }
            }

            foreach (var oldName in oldManaged.Where(name => name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) && !remoteDllNames.Contains(name)))
            {
                var dest = SafeDestination(root, oldName);
                if (!IsDllInstallDisabled(oldName) && !IsDllUpdateEnabled(oldName) && File.Exists(dest) && !finalDllNames.Contains(oldName, StringComparer.OrdinalIgnoreCase))
                {
                    finalDllNames.Add(oldName);
                    Log("HOLD " + oldName + " (DLL nie ma już w paczce, ale usunięcie jest wyłączone)");
                }
            }

            var dllList = finalDllNames.Count == 0 ? string.Empty : string.Join("\r\n", finalDllNames.ToArray()) + "\r\n";
            installFiles.Add(new PackageFile("dlls.txt", Encoding.ASCII.GetBytes(dllList)));
            files = installFiles;

            var newManaged = new HashSet<string>(files.Select(f => f.Name), StringComparer.OrdinalIgnoreCase);
            foreach (var name in finalDllNames) newManaged.Add(name);

            var changed = new List<PackageFile>();
            foreach (var file in files)
            {
                var dest = SafeDestination(root, file.Name);
                if (!File.Exists(dest) || !string.Equals(Sha256File(dest), file.Sha256, StringComparison.OrdinalIgnoreCase))
                    changed.Add(file);
            }
            var stale = oldManaged.Where(name =>
                !newManaged.Contains(name)
                && File.Exists(SafeDestination(root, name))
                && (!name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) || IsDllInstallDisabled(name) || IsDllUpdateEnabled(name))).ToList();

            var exeName = files.First(f => f.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)).Name;

            if (gameRunning)
            {
                // Running clients keep their already mapped DLL image. We still update the on-disk
                // root whenever Windows permits it, so future launches get the new bytes without
                // forcing the current clients to exit. Only the EXE and genuinely locked files
                // fall back to the existing verified pending-runtime transaction.
                var immediateChanged = new List<PackageFile>();
                var deferredChanged = changed.Where(f => f.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)).ToList();
                var immediateStale = new List<string>();
                var deferredStale = stale.Where(name => name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)).ToList();
                var liveChangedCandidates = changed.Where(f =>
                    !f.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                    && !string.Equals(f.Name, "dlls.txt", StringComparison.OrdinalIgnoreCase)).ToList();
                var dllManifestCandidates = changed.Where(f =>
                    string.Equals(f.Name, "dlls.txt", StringComparison.OrdinalIgnoreCase)).ToList();
                var liveStaleCandidates = stale.Where(name =>
                    !name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)).ToList();

                var liveTouched = liveChangedCandidates.Select(f => f.Name)
                    .Concat(dllManifestCandidates.Select(f => f.Name))
                    .Concat(liveStaleCandidates)
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .ToList();
                var backupDir = string.Empty;
                if (liveTouched.Count > 0)
                    backupDir = CreateBackup(root, liveTouched, oldState, remote);

                try
                {
                    foreach (var file in liveChangedCandidates)
                    {
                        if (UpdaterAddons.IsAddonPath(file.Name))
                        {
                            ApplyChangedFiles(root, new[] { file });
                            immediateChanged.Add(file);
                        }
                        else if (TryApplyChangedFileLive(root, file))
                        {
                            immediateChanged.Add(file);
                        }
                        else
                        {
                            deferredChanged.Add(file);
                        }
                    }

                    foreach (var name in liveStaleCandidates)
                    {
                        if (UpdaterAddons.IsAddonPath(name))
                        {
                            ApplyStaleFiles(root, new[] { name });
                            immediateStale.Add(name);
                        }
                        else if (TryApplyStaleFileLive(root, name))
                        {
                            immediateStale.Add(name);
                        }
                        else
                        {
                            deferredStale.Add(name);
                        }
                    }

                    // Do not publish a new dlls.txt while any DLL replacement/removal is still
                    // pending. This keeps new updater-launched clients from seeing a manifest
                    // that refers to a partially applied DLL set.
                    var dllRuntimeDeferred = deferredChanged.Any(f =>
                            f.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
                        || deferredStale.Any(name =>
                            name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase));

                    foreach (var file in dllManifestCandidates)
                    {
                        if (dllRuntimeDeferred)
                        {
                            deferredChanged.Add(file);
                            Log("LIVE DEFER " + file.Name + " (czeka razem z zablokowanym zestawem DLL)");
                        }
                        else if (TryApplyChangedFileLive(root, file))
                        {
                            immediateChanged.Add(file);
                        }
                        else
                        {
                            deferredChanged.Add(file);
                        }
                    }

                    if (deferredChanged.Count > 0 || deferredStale.Count > 0)
                        StagePendingRuntime(root, remote, deferredChanged, deferredStale, newManaged.ToList(), exeName);
                    else
                    {
                        ClearPendingUpdate(root);
                        WriteInstalledState(root, remote, newManaged.ToList(), exeName);
                    }
                    ClearEconomyOverlayState(root);
                }
                catch
                {
                    if (!string.IsNullOrWhiteSpace(backupDir)) RestoreBackupDirectory(root, backupDir, false);
                    throw;
                }

                return new ApplyResult
                {
                    Changed = immediateChanged.Count + immediateStale.Count,
                    Deferred = deferredChanged.Count + deferredStale.Count,
                    Unchanged = files.Count - changed.Count,
                    ExeChanged = changed.Any(f => f.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)),
                    BackupDir = backupDir
                };
            }

            var fullBackupDir = string.Empty;
            if (changed.Count > 0 || stale.Count > 0)
                fullBackupDir = CreateBackup(root, changed.Select(f => f.Name).Concat(stale).Distinct(StringComparer.OrdinalIgnoreCase).ToList(), oldState, remote);

            try
            {
                ApplyChangedFiles(root, changed);
                ApplyStaleFiles(root, stale);
                WriteInstalledState(root, remote, newManaged.ToList(), exeName);
                ClearPendingUpdate(root);
                ClearEconomyOverlayState(root);
            }
            catch
            {
                if (!string.IsNullOrWhiteSpace(fullBackupDir)) RestoreBackupDirectory(root, fullBackupDir, false);
                throw;
            }

            return new ApplyResult
            {
                Changed = changed.Count + stale.Count,
                Deferred = 0,
                Unchanged = files.Count - changed.Count,
                ExeChanged = changed.Any(f => f.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)),
                BackupDir = fullBackupDir
            };
        }

        private void ApplyChangedFiles(string root, IList<PackageFile> changed)
        {
            foreach (var file in changed)
            {
                var dest = SafeDestination(root, file.Name);
                var temp = dest + ".wow112tmp";
                Directory.CreateDirectory(Path.GetDirectoryName(dest));
                File.WriteAllBytes(temp, file.Bytes);
                if (!string.Equals(Sha256File(temp), file.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Błąd SHA256 po zapisie pliku tymczasowego: " + file.Name);
                ReplaceFile(temp, dest);
                if (!string.Equals(Sha256File(dest), file.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Błąd SHA256 po instalacji: " + file.Name);
                Log("OK  " + file.Name);
            }
        }

        private void ApplyStaleFiles(string root, IList<string> stale)
        {
            foreach (var name in stale)
            {
                File.Delete(SafeDestination(root, name));
                Log("DEL " + name + " (stary zarządzany plik)");
            }
        }

        private bool TryApplyChangedFileLive(string root, PackageFile file)
        {
            var dest = SafeDestination(root, file.Name);
            var temp = dest + ".wow112tmp";
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(dest));
                if (File.Exists(temp)) File.Delete(temp);
                File.WriteAllBytes(temp, file.Bytes);
                if (!string.Equals(Sha256File(temp), file.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Błąd SHA256 po zapisie pliku tymczasowego: " + file.Name);
                ReplaceFile(temp, dest);
                if (!string.Equals(Sha256File(dest), file.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Błąd SHA256 po LIVE instalacji: " + file.Name);
                Log("LIVE OK  " + file.Name);
                return true;
            }
            catch (IOException ex)
            {
                try { if (File.Exists(temp)) File.Delete(temp); } catch { }
                Log("LIVE DEFER " + file.Name + " (Windows blokuje zapis: " + ex.Message + ")");
                return false;
            }
            catch (UnauthorizedAccessException ex)
            {
                try { if (File.Exists(temp)) File.Delete(temp); } catch { }
                Log("LIVE DEFER " + file.Name + " (brak dostępu/blokada: " + ex.Message + ")");
                return false;
            }
        }

        private bool TryApplyStaleFileLive(string root, string name)
        {
            try
            {
                File.Delete(SafeDestination(root, name));
                Log("LIVE DEL " + name + " (stary zarządzany plik)");
                return true;
            }
            catch (IOException ex)
            {
                Log("LIVE DEFER DEL " + name + " (Windows blokuje usunięcie: " + ex.Message + ")");
                return false;
            }
            catch (UnauthorizedAccessException ex)
            {
                Log("LIVE DEFER DEL " + name + " (brak dostępu/blokada: " + ex.Message + ")");
                return false;
            }
        }

        private static string PendingRoot(string root)
        {
            return Path.Combine(root, ".wow112_parallel_updater", "pending");
        }

        private static string PendingManifestPath(string root)
        {
            return Path.Combine(PendingRoot(root), "pending.json");
        }

        private void StagePendingRuntime(string root, RemotePackageInfo remote, IList<PackageFile> changed,
            IList<string> stale, IList<string> managedFiles, string exeName)
        {
            var pendingRoot = PendingRoot(root);
            var parent = Path.GetDirectoryName(pendingRoot);
            Directory.CreateDirectory(parent);
            var stage = pendingRoot + ".stage-" + Guid.NewGuid().ToString("N");
            var stageFiles = Path.Combine(stage, "files");
            Directory.CreateDirectory(stageFiles);

            try
            {
                var fileRows = new ArrayList();
                foreach (var file in changed)
                {
                    ValidatePendingRuntimeName(file.Name);
                    var path = Path.Combine(stageFiles, file.Name);
                    File.WriteAllBytes(path, file.Bytes);
                    if (!string.Equals(Sha256File(path), file.Sha256, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("LIVE UPDATE: SHA256 pliku oczekującego nie zgadza się: " + file.Name);
                    var row = new Dictionary<string, object>();
                    row["name"] = file.Name;
                    row["sha256"] = file.Sha256;
                    fileRows.Add(row);
                }

                var manifest = new Dictionary<string, object>();
                manifest["schema_version"] = 1;
                manifest["created_utc"] = DateTime.UtcNow.ToString("o");
                manifest["channel"] = remote.Channel;
                manifest["run_id"] = remote.RunId;
                manifest["head_sha"] = remote.HeadSha;
                manifest["exe_name"] = exeName;
                manifest["files"] = fileRows;
                manifest["stale"] = new ArrayList(stale.Cast<object>().ToArray());
                manifest["managed_files"] = new ArrayList(managedFiles.Cast<object>().ToArray());
                UpdaterSafety.WriteUtf8Atomic(Path.Combine(stage, "pending.json"), json.Serialize(manifest), ".tmp", ".previous");

                if (Directory.Exists(pendingRoot)) Directory.Delete(pendingRoot, true);
                Directory.Move(stage, pendingRoot);
                pendingApplyFaulted = false;
                Log("LIVE UPDATE: runtime oczekuje na bezpieczne dokończenie • " + ShortSha(remote.HeadSha)
                    + " • pliki " + changed.Count + " • usunięcia " + stale.Count + ".");
            }
            catch
            {
                if (Directory.Exists(stage)) Directory.Delete(stage, true);
                throw;
            }
        }

        private static void ValidatePendingRuntimeName(string name)
        {
            if (string.IsNullOrWhiteSpace(name)
                || UpdaterAddons.IsAddonPath(name)
                || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0
                || Path.GetFileName(name) != name)
                throw new InvalidOperationException("LIVE UPDATE: nieprawidłowa nazwa pliku runtime: " + name);
        }

        private void ClearPendingUpdate(string root)
        {
            var pendingRoot = PendingRoot(root);
            if (Directory.Exists(pendingRoot)) Directory.Delete(pendingRoot, true);
            pendingApplyFaulted = false;
        }

        private string ReadPendingHeadSha(string root)
        {
            try
            {
                var path = PendingManifestPath(root);
                if (!File.Exists(path)) return string.Empty;
                var manifest = AsDictionary(json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8)));
                return GetString(manifest, "head_sha");
            }
            catch
            {
                return "?";
            }
        }

        private void TryFinalizePendingUpdate()
        {
            if (busy || pendingApplyBusy || pendingApplyFaulted) return;
            var root = gameDir.Text.Trim();
            if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root)) return;
            var manifestPath = PendingManifestPath(root);
            if (!File.Exists(manifestPath) || IsGameRunning(root)) return;

            pendingApplyBusy = true;
            SetBusy(true, "Dokańczanie oczekującej aktualizacji runtime...");
            string backupDir = null;
            try
            {
                var manifest = AsDictionary(json.DeserializeObject(File.ReadAllText(manifestPath, Encoding.UTF8)));
                if (GetLong(manifest, "schema_version") != 1)
                    throw new InvalidOperationException("LIVE UPDATE: nieobsługiwany manifest oczekującego runtime.");

                var remote = new RemotePackageInfo
                {
                    Channel = GetString(manifest, "channel"),
                    RunId = GetLong(manifest, "run_id"),
                    HeadSha = GetString(manifest, "head_sha")
                };
                if (remote.HeadSha.Length != 40 || !remote.HeadSha.All(Uri.IsHexDigit))
                    throw new InvalidOperationException("LIVE UPDATE: nieprawidłowy commit oczekującego runtime.");

                var pendingRoot = PendingRoot(root);
                var pendingFiles = Path.Combine(pendingRoot, "files");
                var changed = new List<PackageFile>();
                foreach (var item in AsArray(GetValue(manifest, "files")))
                {
                    var row = AsDictionary(item);
                    var name = GetString(row, "name");
                    var expected = GetString(row, "sha256");
                    ValidatePendingRuntimeName(name);
                    if (!UpdaterSafety.IsSha256Hex(expected))
                        throw new InvalidOperationException("LIVE UPDATE: nieprawidłowy SHA256 dla " + name + ".");
                    var path = Path.Combine(pendingFiles, name);
                    if (!File.Exists(path))
                        throw new InvalidOperationException("LIVE UPDATE: brakuje oczekującego pliku " + name + ".");
                    var bytes = File.ReadAllBytes(path);
                    var file = new PackageFile(name, bytes);
                    if (!string.Equals(file.Sha256, expected, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("LIVE UPDATE: zmieniony plik oczekujący " + name + ".");
                    changed.Add(file);
                }

                var stale = new List<string>();
                foreach (var item in AsArray(GetValue(manifest, "stale")))
                {
                    var name = Convert.ToString(item);
                    ValidatePendingRuntimeName(name);
                    stale.Add(name);
                }

                var managed = new List<string>();
                foreach (var item in AsArray(GetValue(manifest, "managed_files")))
                {
                    var name = Convert.ToString(item);
                    if (!string.IsNullOrWhiteSpace(name)) managed.Add(name);
                }
                var exeName = GetString(manifest, "exe_name");
                ValidatePendingRuntimeName(exeName);

                var oldState = ReadInstalledState(root);
                var touched = changed.Select(f => f.Name).Concat(stale).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
                if (touched.Count > 0)
                    backupDir = CreateBackup(root, touched, oldState, remote);

                try
                {
                    ApplyChangedFiles(root, changed);
                    ApplyStaleFiles(root, stale);
                    WriteInstalledState(root, remote, managed, exeName);
                    ClearPendingUpdate(root);
                }
                catch
                {
                    if (!string.IsNullOrWhiteSpace(backupDir)) RestoreBackupDirectory(root, backupDir, false);
                    throw;
                }

                status.Text = "Oczekujący runtime zainstalowany • " + ShortSha(remote.HeadSha);
                Log("LIVE UPDATE: dokończono runtime po zamknięciu ostatniej instancji WoW • " + ShortSha(remote.HeadSha) + ".");
                TrimBackups(root, MaxBackups);
            }
            catch (Exception ex)
            {
                pendingApplyFaulted = true;
                status.Text = "Oczekujący runtime wymaga ponowienia — szczegóły w logu.";
                Log("BŁĄD LIVE UPDATE: " + ex.Message);
            }
            finally
            {
                pendingApplyBusy = false;
                SetBusy(false, status.Text);
                RefreshLocalState();
            }
        }

        private string CreateBackup(string root, IList<string> touchedNames, Dictionary<string, object> oldState, RemotePackageInfo remote)
        {
            var backupRoot = Path.Combine(root, ".wow112_parallel_updater", "backups");
            Directory.CreateDirectory(backupRoot);
            var dir = Path.Combine(backupRoot, DateTime.Now.ToString("yyyyMMdd_HHmmss") + "_run" + remote.RunId);
            Directory.CreateDirectory(dir);

            var rows = new ArrayList();
            foreach (var name in touchedNames)
            {
                var src = SafeDestination(root, name);
                var existed = File.Exists(src);
                if (existed)
                {
                    var backupPath = Path.Combine(dir, name.Replace('/', Path.DirectorySeparatorChar));
                    Directory.CreateDirectory(Path.GetDirectoryName(backupPath));
                    File.Copy(src, backupPath, true);
                }
                var row = new Dictionary<string, object>();
                row["name"] = name;
                row["existed"] = existed;
                rows.Add(row);
            }
            var manifest = new Dictionary<string, object>();
            manifest["created_utc"] = DateTime.UtcNow.ToString("o");
            manifest["target_run_id"] = remote.RunId;
            manifest["target_head_sha"] = remote.HeadSha;
            manifest["files"] = rows;
            manifest["previous_installed"] = oldState;
            UpdaterSafety.WriteUtf8Atomic(Path.Combine(dir, "backup_manifest.json"), json.Serialize(manifest), ".tmp", ".previous");
            return dir;
        }

        private void RefreshLocalState()
        {
            rollbackChoice.Items.Clear();
            var root = gameDir.Text.Trim();
            if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
            {
                localInfo.Text = "Lokalnie: wybierz katalog gry.";
                rollbackButton.Enabled = false;
                rollbackChoice.Enabled = false;
                return;
            }

            var installed = ReadInstalledState();
            if (installed == null)
            {
                localInfo.Text = "Lokalnie: brak stanu updatera (pierwsza instalacja lub ręcznie kopiowane pliki).";
            }
            else
            {
                DateTime when;
                var whenText = DateTime.TryParse(GetString(installed, "installed_utc"), out when)
                    ? " • " + when.ToLocalTime().ToString("yyyy-MM-dd HH:mm")
                    : string.Empty;
                localInfo.Text = "Lokalnie: " + GetString(installed, "channel").ToUpperInvariant()
                    + " • run " + GetLong(installed, "run_id")
                    + " • " + ShortSha(GetString(installed, "head_sha"))
                    + whenText;
            }

            var pendingHead = ReadPendingHeadSha(root);
            if (!string.IsNullOrWhiteSpace(pendingHead))
                localInfo.Text += " • RUNTIME OCZEKUJE " + ShortSha(pendingHead);
            AppendEconomyLocalInfo(root);

            var backupRoot = Path.Combine(root, ".wow112_parallel_updater", "backups");
            if (Directory.Exists(backupRoot))
            {
                foreach (var dir in Directory.GetDirectories(backupRoot).OrderByDescending(x => x, StringComparer.OrdinalIgnoreCase))
                {
                    var choice = ReadBackupChoice(dir);
                    if (choice != null) rollbackChoice.Items.Add(choice);
                }
            }
            if (rollbackChoice.Items.Count > 0) rollbackChoice.SelectedIndex = 0;
            rollbackButton.Enabled = !busy && rollbackChoice.Items.Count > 0;
            rollbackChoice.Enabled = !busy && rollbackChoice.Items.Count > 0;
        }

        private BackupChoice ReadBackupChoice(string dir)
        {
            try
            {
                var manifestPath = Path.Combine(dir, "backup_manifest.json");
                if (!File.Exists(manifestPath)) return null;
                var manifest = AsDictionary(json.DeserializeObject(File.ReadAllText(manifestPath, Encoding.UTF8)));
                var previous = GetValue(manifest, "previous_installed") as Dictionary<string, object>;
                var label = previous == null
                    ? "Stan sprzed pierwszej instalacji updatera"
                    : GetString(previous, "channel").ToUpperInvariant() + " run " + GetLong(previous, "run_id")
                        + " • " + ShortSha(GetString(previous, "head_sha"));
                label += " • " + Path.GetFileName(dir);
                return new BackupChoice(dir, label);
            }
            catch
            {
                return null;
            }
        }

        private void TrimBackups(string root, int keep)
        {
            try
            {
                var backupRoot = Path.Combine(root, ".wow112_parallel_updater", "backups");
                if (!Directory.Exists(backupRoot)) return;
                var dirs = Directory.GetDirectories(backupRoot).OrderByDescending(x => x, StringComparer.OrdinalIgnoreCase).ToArray();
                foreach (var dir in dirs.Skip(Math.Max(keep, 1))) Directory.Delete(dir, true);
            }
            catch (Exception ex)
            {
                Log("Ostrzeżenie: nie udało się przyciąć historii backupów: " + ex.Message);
            }
        }

        private void Rollback()
        {
            try
            {
                if (busy) return;
                var root = gameDir.Text.Trim();
                if (!Directory.Exists(root)) throw new InvalidOperationException("Wybierz katalog gry.");
                if (IsGameRunning(root)) throw new InvalidOperationException("Zamknij WoW przed rollbackiem.");
                var choice = rollbackChoice.SelectedItem as BackupChoice;
                string dir = choice == null ? null : choice.Path;
                if (dir == null)
                {
                    var backupRoot = Path.Combine(root, ".wow112_parallel_updater", "backups");
                    if (Directory.Exists(backupRoot))
                        dir = Directory.GetDirectories(backupRoot).OrderByDescending(x => x, StringComparer.OrdinalIgnoreCase).FirstOrDefault();
                }
                if (dir == null) throw new InvalidOperationException("Brak backupów updatera.");
                RestoreBackupDirectory(root, dir, true);
                status.Text = "Rollback zakończony.";
                Log("Rollback OK: " + dir);
                RefreshLocalState();
            }
            catch (Exception ex)
            {
                status.Text = "Rollback nie powiódł się";
                Log("BŁĄD: " + ex.Message);
                MessageBox.Show(this, ex.Message, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void RestoreBackupDirectory(string root, string dir, bool consume)
        {
            var manifestPath = Path.Combine(dir, "backup_manifest.json");
            if (!File.Exists(manifestPath)) throw new InvalidOperationException("Backup nie ma manifestu: " + dir);
            var manifest = AsDictionary(json.DeserializeObject(File.ReadAllText(manifestPath, Encoding.UTF8)));
            foreach (var item in AsArray(GetValue(manifest, "files")))
            {
                var row = AsDictionary(item);
                var name = GetString(row, "name");
                var existed = GetBool(row, "existed");
                var dest = SafeDestination(root, name);
                if (existed)
                {
                    var src = Path.Combine(dir, name);
                    if (!File.Exists(src)) throw new InvalidOperationException("Backup pliku jest niekompletny: " + name);
                    Directory.CreateDirectory(Path.GetDirectoryName(dest));
                    File.Copy(src, dest, true);
                }
                else if (File.Exists(dest))
                {
                    File.Delete(dest);
                }
            }

            var previous = GetValue(manifest, "previous_installed") as Dictionary<string, object>;
            var installedPath = InstalledStatePath(root);
            if (previous != null)
            {
                UpdaterSafety.WriteUtf8Atomic(installedPath, json.Serialize(previous), ".tmp", ".previous");
            }
            else if (File.Exists(installedPath))
            {
                File.Delete(installedPath);
            }

            if (consume) Directory.Delete(dir, true);
        }

        private void WriteInstalledState(string root, RemotePackageInfo remote, IList<string> managedFiles, string exeName)
        {
            var state = new Dictionary<string, object>();
            state["schema_version"] = 2;
            state["updater_version"] = UpdaterVersion;
            state["channel"] = remote.Channel;
            state["run_id"] = remote.RunId;
            state["head_sha"] = remote.HeadSha;
            state["artifact_name"] = remote.ArtifactName;
            state["installed_utc"] = DateTime.UtcNow.ToString("o");
            state["managed_files"] = managedFiles.ToArray();
            state["exe_name"] = exeName;
            var path = InstalledStatePath(root);
            UpdaterSafety.WriteUtf8Atomic(path, json.Serialize(state), ".tmp", ".previous");
        }

        private Dictionary<string, object> ReadInstalledState()
        {
            return ReadInstalledState(gameDir.Text.Trim());
        }

        private Dictionary<string, object> ReadInstalledState(string root)
        {
            if (string.IsNullOrWhiteSpace(root)) return null;
            var path = InstalledStatePath(root);
            var current = TryReadInstalledStateFile(path);
            if (current != null) return current;
            return TryReadInstalledStateFile(path + ".previous");
        }

        private Dictionary<string, object> TryReadInstalledStateFile(string path)
        {
            try
            {
                if (!File.Exists(path)) return null;
                return AsDictionary(json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8)));
            }
            catch
            {
                return null;
            }
        }

        private static string InstalledStatePath(string root)
        {
            return Path.Combine(root, ".wow112_parallel_updater", "installed.json");
        }

        private static void ConfigureAutoLoginEnvironment(ProcessStartInfo startInfo, WowAccount account, bool autoFirstCharacter = false)
        {
            if (startInfo == null) throw new ArgumentNullException("startInfo");
            if (account == null) return;
            if (string.IsNullOrWhiteSpace(account.Login))
                throw new InvalidDataException("Profil nie ma loginu.");
            if (Encoding.UTF8.GetByteCount(account.Login) >= 64)
                throw new InvalidDataException("Login jest za długi dla klienta WoW 1.12.1.");
            if (string.IsNullOrWhiteSpace(account.ProtectedPassword))
                throw new InvalidDataException("Profil nie ma zaszyfrowanego hasła.");
            if (account.ProtectedPassword.Length >= 2048)
                throw new InvalidDataException("Zaszyfrowane hasło profilu jest za duże.");

            // EnvironmentVariables require direct CreateProcess semantics.
            startInfo.UseShellExecute = false;
            startInfo.EnvironmentVariables["WOW112_AUTOLOGIN_ACCOUNT"] = account.Login;
            startInfo.EnvironmentVariables["WOW112_AUTOLOGIN_BLOB"] = account.ProtectedPassword;
            startInfo.EnvironmentVariables.Remove("WOW112_AUTOCHAR_FIRST");
            if (autoFirstCharacter)
                startInfo.EnvironmentVariables["WOW112_AUTOCHAR_FIRST"] = "1";
        }

        private static string LowSpecConfigName(WowAccount account)
        {
            if (account == null) throw new ArgumentNullException("account");
            var seed = (account.Id ?? string.Empty) + "\n" + (account.Login ?? string.Empty);
            using (var sha = SHA256.Create())
            {
                var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(seed));
                return string.Format("{0:X2}{1:X2}{2:X2}.wtf", hash[0], hash[1], hash[2]);
            }
        }

        private static string PrepareLowSpecConfig(string root, WowAccount account, bool backgroundSound)
        {
            if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
                throw new InvalidOperationException("Brak katalogu gry dla profilu LOW.");
            if (account == null || !account.LowSpec)
                throw new InvalidOperationException("Profil nie jest oznaczony jako LOW.");

            var wtf = Path.Combine(root, "WTF");
            Directory.CreateDirectory(wtf);
            var basePath = Path.Combine(wtf, "Config.wtf");
            var baseText = File.Exists(basePath) ? File.ReadAllText(basePath, Encoding.UTF8) : string.Empty;
            if (baseText.Length > 2 * 1024 * 1024)
                throw new InvalidDataException("WTF\\Config.wtf jest nieoczekiwanie duży.");

            var sb = new StringBuilder(baseText.TrimEnd('\0', '\r', '\n'));
            if (sb.Length > 0) sb.Append("\r\n");
            var low = new[]
            {
                new[] { "gxWindow", "1" },
                new[] { "gxMaximize", "0" },
                new[] { "gxResolution", "800x600" },
                new[] { "gxVSync", "0" },
                new[] { "gxTripleBuffer", "0" },
                new[] { "gxFixLag", "0" },
                new[] { "gxCursor", "1" },
                new[] { "lod", "1" },
                new[] { "farclip", "177" },
                new[] { "shadowLevel", "1" },
                new[] { "smallCull", "0.001" },
                new[] { "baseMip", "1" },
                new[] { "spellEffectLevel", "0" },
                new[] { "weatherDensity", "0" },
                new[] { "anisotropic", "1" },
                new[] { "pixelShaders", "0" },
                new[] { "specular", "0" },
                new[] { "ffxGlow", "0" },
                new[] { "ffxDeath", "0" },
                new[] { "M2UseShaders", "1" },
                new[] { "M2UsePixelShaders", "0" },
                new[] { "useWeatherShaders", "0" },
                new[] { "trilinear", "0" },
                new[] { "frillDensity", "1" },
                new[] { "lodDist", "50" },
                new[] { "DistCull", "1" },
                new[] { "textureLodDist", "80" },
                new[] { "particleDensity", "0.25" },
                new[] { "unitDrawDist", "100" },
                new[] { "mapShadows", "0" },
                new[] { "doodadAnim", "0" },
                new[] { "M2BatchDoodads", "1" },
                new[] { "M2UseThreads", "1" }
            };
            foreach (var kv in low)
                sb.Append("SET ").Append(kv[0]).Append(" \"").Append(kv[1]).Append("\"\r\n");

            if (!backgroundSound)
            {
                var muted = new[]
                {
                    new[] { "MasterSoundEffects", "0" },
                    new[] { "EnableAmbience", "0" },
                    new[] { "EnableMusic", "0" },
                    new[] { "MasterVolume", "0" },
                    new[] { "SoundVolume", "0" },
                    new[] { "MusicVolume", "0" },
                    new[] { "AmbienceVolume", "0" }
                };
                foreach (var kv in muted)
                    sb.Append("SET ").Append(kv[0]).Append(" \"").Append(kv[1]).Append("\"\r\n");
            }

            var name = LowSpecConfigName(account);
            var path = Path.Combine(wtf, name);
            UpdaterSafety.WriteUtf8Atomic(path, sb.ToString(), ".tmp", ".previous");
            return name;
        }

        private System.Diagnostics.Process StartGameProcess(WowAccount autoLoginAccount = null, bool backgroundSound = false, bool autoFirstCharacter = false)
        {
            var root = gameDir.Text.Trim();
            if (!Directory.Exists(root)) throw new InvalidOperationException("Wybierz katalog gry.");
            var state = ReadInstalledState();
            var exeName = state == null ? string.Empty : GetString(state, "exe_name");
            string exe = null;
            if (!string.IsNullOrWhiteSpace(exeName) && File.Exists(Path.Combine(root, exeName))) exe = Path.Combine(root, exeName);
            if (exe == null)
            {
                var candidates = Directory.GetFiles(root, "*.exe")
                    .Where(p => Path.GetFileName(p).StartsWith("WoW", StringComparison.OrdinalIgnoreCase))
                    .OrderBy(p => string.Equals(Path.GetFileName(p), "WoW.exe", StringComparison.OrdinalIgnoreCase) ? 0 : 1)
                    .ToArray();
                exe = candidates.FirstOrDefault();
            }
            if (exe == null) throw new InvalidOperationException("Nie znalazłem WoW*.exe w wybranym katalogu.");

            var startInfo = new ProcessStartInfo(exe) { WorkingDirectory = root, UseShellExecute = true };
            ConfigureAutoLoginEnvironment(startInfo, autoLoginAccount, autoFirstCharacter);
            var reloginOnlyAccount = autoLoginAccount == null && accountVault != null ? accountVault.Selected : null;
            var reloginHandoff = ConfigureReloginHandoffEnvironment(startInfo, reloginOnlyAccount);
            string lowConfig = null;
            if (autoLoginAccount != null && autoLoginAccount.LowSpec)
            {
                lowConfig = PrepareLowSpecConfig(root, autoLoginAccount, backgroundSound);
                startInfo.Arguments = backgroundSound ? "-windowed -800x600" : "-windowed -800x600 -nosound";
            }
            var game = autoLoginAccount == null
                ? Process.Start(startInfo)
                : Process.Start(startInfo, lowConfig, backgroundSound);
            if (game == null) throw new InvalidOperationException("Windows nie zwrócił procesu uruchomionej gry.");
            PublishReloginHandoff(reloginHandoff, reloginOnlyAccount);
            if (autoLoginAccount != null && autoLoginAccount.LowSpec)
            {
                try { game.PriorityClass = ProcessPriorityClass.BelowNormal; }
                catch (Exception ex) { Log("LOW SPEC: nie udało się obniżyć priorytetu PID " + game.Id + ": " + ex.GetType().Name); }
            }
            Log("Uruchomiono: " + Path.GetFileName(exe) + " (PID " + game.Id + ")" +
                (autoLoginAccount == null ? "." : " • profil " + autoLoginAccount.Label + " • native autologin" +
                    (autoLoginAccount.LowSpec ? " • LOW CFG " + lowConfig + " • 800x600/WINDOWED" : "") +
                    (backgroundSound ? " • BG SOUND" : "") +
                    (autoFirstCharacter ? " • AUTO POSTAĆ 1." : ".")));
            return game;
        }

        private void LaunchGame()
        {
            try
            {
                var game = StartGameProcess();
                RememberGameSession(game);
            }
            catch (Exception ex)
            {
                Log("BŁĄD: " + ex.Message);
                MessageBox.Show(this, ex.Message, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private async Task KillAllGameInstancesAsync()
        {
            if (busy) return;
            var root = gameDir.Text.Trim();
            if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
            {
                MessageBox.Show(this, "Wybierz istniejący katalog gry.", "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            root = Path.GetFullPath(root);
            var initialPids = GetGameProcessIds(root);
            if (initialPids.Count == 0)
            {
                status.Text = "Brak uruchomionych instancji WoW z tego katalogu.";
                Log(status.Text);
                return;
            }

            var legacyPids = initialPids
                .Where(pid => SummonWorkerChannel.ProbeProtocolVersion(pid) != SummonWorkerVersion)
                .ToList();
            var legacyMigration = legacyPids.Count != 0;

            var answer = MessageBox.Show(
                this,
                legacyMigration
                    ? "Wykryto stare instancje WoW, które nie mają jeszcze workera ReloadUI v" + SummonWorkerVersion + ".\n\n"
                        + "Procesy: " + initialPids.Count + " • stare/niezgodne: " + legacyPids.Count + "\n"
                        + "To jest jednorazowa migracja po aktualizacji. Updater wyśle wszystkim klientom NORMALNE zamknięcie okna WoW "
                        + "(bez Kill), poczeka aż procesy same się zakończą, a następnie sfinalizuje oczekujący runtime.\n\n"
                        + "Przy kolejnych uruchomieniach przycisk wróci do trybu ReloadUI → ACK → Kill."
                    : "Zakończyć wszystkie instancje WoW z wybranego katalogu?\n\n"
                        + "Procesy: " + initialPids.Count + "\n"
                        + "Najpierw updater wymusi ReloadUI() w KAŻDEJ instancji i poczeka na potwierdzenie zakończenia reloadu. "
                        + "Dopiero potem wykona twardy Kill().\n\n"
                        + "Jeśli choć jedna instancja nie potwierdzi reloadu, żaden działający klient nie zostanie zabity.",
                legacyMigration
                    ? "WoW112 Updater — JEDNORAZOWA MIGRACJA RUNTIME"
                    : "WoW112 Updater — RELOAD + ZABIJ WSZYSTKIE",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button2);
            if (answer != DialogResult.Yes)
            {
                status.Text = "Reload + zabicie instancji anulowane.";
                return;
            }

            var finalStatus = "Gotowy";
            var enteredBusy = false;
            var reservedCoordinator = false;
            try
            {
                if (summonCoordinatorBusy)
                    throw new InvalidOperationException("Koordynator slave jest zajęty. Poczekaj na zakończenie bieżącej operacji i spróbuj ponownie.");

                summonCoordinatorBusy = true;
                reservedCoordinator = true;
                enteredBusy = true;

                if (legacyMigration)
                {
                    SetBusy(true, "Jednorazowa migracja: bezpieczne zamykanie starych klientów...");
                    await GracefullyCloseLegacyGameProcessesAsync(root, initialPids);
                    finalStatus = "Stare instancje zamknięte normalnie. Finalizuję nowy runtime.";
                    Log(finalStatus);
                }
                else
                {
                    SetBusy(true, "ReloadUI we wszystkich instancjach WoW...");
                    await ReloadGameProcessesAsync(root, initialPids);

                    var currentPids = GetGameProcessIds(root);
                    var unexpected = currentPids.Where(pid => !initialPids.Contains(pid)).ToList();
                    if (unexpected.Count != 0)
                        throw new InvalidOperationException("W trakcie operacji uruchomiono nową instancję WoW (PID "
                            + string.Join(", ", unexpected.Select(x => x.ToString()).ToArray())
                            + "). Kill anulowany, bo ta instancja nie przeszła ReloadUI.");

                    var killTargets = currentPids.Where(initialPids.Contains).ToList();
                    SetBusy(true, "Reload potwierdzony. Zamykanie instancji WoW...");
                    int failed;
                    var killed = KillGameProcesses(root, killTargets, out failed);
                    if (failed != 0)
                        throw new InvalidOperationException("Nie udało się zakończyć wszystkich przeładowanych instancji WoW. Zakończono: "
                            + killed + ", błędy: " + failed + ".");

                    if (GetGameProcessIds(root).Count != 0)
                        throw new InvalidOperationException("Po operacji nadal działa instancja WoW z wybranego katalogu. Nie była objęta potwierdzonym zestawem ReloadUI.");

                    finalStatus = "ReloadUI potwierdzony; zakończono wszystkie instancje WoW (" + killed + ").";
                    Log(finalStatus);
                }
            }
            catch (Exception ex)
            {
                finalStatus = "Reload + zabijanie instancji nie powiodło się";
                Log("BŁĄD RELOAD + ZABIJ WSZYSTKIE: " + ex.Message);
                MessageBox.Show(this, ex.Message, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                if (reservedCoordinator) summonCoordinatorBusy = false;
                if (enteredBusy) SetBusy(false, finalStatus);
            }

            if (!IsGameRunning(root))
                TryFinalizePendingUpdate();
        }

        private async Task GracefullyCloseLegacyGameProcessesAsync(string root, IList<int> pids)
        {
            var original = new HashSet<int>(pids);
            var current = GetGameProcessIds(root);
            var unexpected = current.Where(pid => !original.Contains(pid)).ToList();
            if (unexpected.Count != 0)
                throw new InvalidOperationException("W trakcie przygotowania migracji uruchomiono nową instancję WoW (PID "
                    + string.Join(", ", unexpected.Select(x => x.ToString()).ToArray())
                    + "). Migracja anulowana przed zamykaniem.");

            // Preflight every target before closing any window so a missing/non-GUI
            // process cannot cause an avoidable half-migration.
            foreach (var pid in pids)
            {
                if (!IsGameProcessAliveInRoot(pid, root)) continue;
                using (var process = System.Diagnostics.Process.GetProcessById(pid))
                {
                    if (process.MainWindowHandle == IntPtr.Zero)
                        throw new InvalidOperationException("PID " + pid
                            + ": nie znaleziono głównego okna WoW. Jednorazowa migracja została anulowana bez użycia Kill().");
                }
            }

            foreach (var pid in pids)
            {
                if (!IsGameProcessAliveInRoot(pid, root)) continue;
                using (var process = System.Diagnostics.Process.GetProcessById(pid))
                {
                    if (!process.CloseMainWindow())
                        throw new InvalidOperationException("PID " + pid
                            + ": Windows nie przyjął normalnego zamknięcia okna. Nie użyłem Kill().");
                    Log("MIGRACJA RUNTIME: wysłano normalne zamknięcie do PID " + pid + ".");
                }
            }

            var started = Environment.TickCount;
            var nextRetry = 2000;
            while (unchecked(Environment.TickCount - started) < 35000)
            {
                var remaining = pids.Where(pid => IsGameProcessAliveInRoot(pid, root)).ToList();
                if (remaining.Count == 0)
                {
                    await Task.Delay(500);
                    return;
                }

                var elapsed = unchecked(Environment.TickCount - started);
                if (elapsed >= nextRetry)
                {
                    foreach (var pid in remaining)
                    {
                        try
                        {
                            using (var process = System.Diagnostics.Process.GetProcessById(pid))
                            {
                                if (!process.HasExited) process.CloseMainWindow();
                            }
                        }
                        catch { }
                    }
                    nextRetry += 2000;
                }

                await Task.Delay(100);
            }

            var stuck = pids.Where(pid => IsGameProcessAliveInRoot(pid, root)).OrderBy(pid => pid).ToArray();
            throw new InvalidOperationException("Stare klienty nie zamknęły się normalnie w 35 s. Nadal działa PID: "
                + string.Join(", ", stuck.Select(x => x.ToString()).ToArray())
                + ". Nie użyłem Kill(); zamknij ewentualne okno potwierdzenia w grze i kliknij przycisk ponownie.");
        }

        private async Task ReloadGameProcessesAsync(string root, IList<int> pids)
        {
            var channels = new Dictionary<int, SummonWorkerChannel>();
            try
            {
                foreach (var pid in pids)
                {
                    if (!IsGameProcessAliveInRoot(pid, root))
                        throw new InvalidOperationException("PID " + pid + " zakończył się przed wysłaniem ReloadUI.");

                    var channel = SummonWorkerChannel.TryOpen(pid);
                    if (channel == null)
                    {
                        var foundProtocol = SummonWorkerChannel.ProbeProtocolVersion(pid);
                        if (foundProtocol != 0 && foundProtocol != SummonWorkerVersion)
                            throw new InvalidOperationException("PID " + pid + ": stary CharacterSwitch worker (protokół v"
                                + foundProtocol + ", wymagany v" + SummonWorkerVersion
                                + "). Zaktualizuj runtime i uruchom tę instancję ponownie; żadna instancja nie została zabita.");
                        throw new InvalidOperationException("PID " + pid
                            + ": brak zgodnego CharacterSwitch worker v" + SummonWorkerVersion
                            + ". Zaktualizuj runtime i uruchom tę instancję ponownie; żadna instancja nie została zabita.");
                    }

                    var snapshot = channel.Read();
                    if (!HeartbeatFresh(snapshot))
                    {
                        channel.Dispose();
                        throw new InvalidOperationException("PID " + pid + ": CharacterSwitch worker nie odpowiada; kill został anulowany.");
                    }
                    if (snapshot.InWorld != 1)
                    {
                        channel.Dispose();
                        throw new InvalidOperationException("PID " + pid + ": klient nie jest aktualnie w świecie; nie mogę potwierdzić ReloadUI.");
                    }
                    if (snapshot.CommandSeq != snapshot.AckSeq)
                    {
                        channel.Dispose();
                        throw new InvalidOperationException("PID " + pid + ": worker wykonuje inną komendę; kill został anulowany.");
                    }
                    channels.Add(pid, channel);
                }

                var seq = NewSummonRequestSeq();
                foreach (var item in channels)
                    item.Value.SendRaw(seq, KillReloadCommand);

                Log("RELOAD+KILL: wysłano ReloadUI do " + channels.Count + " instancji • seq " + seq + ".");
                var pending = new HashSet<int>(channels.Keys);
                var started = Environment.TickCount;
                while (pending.Count != 0 && unchecked(Environment.TickCount - started) < KillReloadTimeoutMs)
                {
                    foreach (var pid in pending.ToArray())
                    {
                        if (!IsGameProcessAliveInRoot(pid, root))
                            throw new InvalidOperationException("PID " + pid + " zakończył się przed potwierdzeniem ReloadUI; kill pozostałych anulowany.");

                        var snapshot = channels[pid].Read();
                        if (snapshot.AckSeq != seq) continue;

                        if (snapshot.CommandSlot != KillReloadCommand || snapshot.Error != 0 || snapshot.State == 5)
                            throw new InvalidOperationException("PID " + pid + ": ReloadUI nie został potwierdzony"
                                + " (state=" + snapshot.State + ", error=" + snapshot.Error + "). Kill anulowany.");

                        pending.Remove(pid);
                        Log("RELOAD+KILL: PID " + pid + " potwierdził zakończenie ReloadUI.");
                    }

                    if (pending.Count != 0)
                        await Task.Delay(50);
                }

                if (pending.Count != 0)
                    throw new InvalidOperationException("Timeout ReloadUI dla PID: "
                        + string.Join(", ", pending.OrderBy(x => x).Select(x => x.ToString()).ToArray())
                        + ". Żaden klient nie został zabity.");

                status.Text = "ReloadUI potwierdzony we wszystkich instancjach. Finalizuję zapis...";
                await Task.Delay(KillReloadSettleMs);
            }
            finally
            {
                foreach (var channel in channels.Values) channel.Dispose();
            }
        }

        private static List<int> GetGameProcessIds(string root)
        {
            var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            var result = new List<int>();
            foreach (var process in System.Diagnostics.Process.GetProcesses())
            {
                try
                {
                    var module = process.MainModule;
                    var file = module == null ? null : module.FileName;
                    if (IsGameProcessPath(file, fullRoot)) result.Add(process.Id);
                }
                catch { }
                finally { process.Dispose(); }
            }
            result.Sort();
            return result;
        }

        private static bool IsGameProcessAliveInRoot(int pid, string root)
        {
            try
            {
                using (var process = System.Diagnostics.Process.GetProcessById(pid))
                {
                    if (process.HasExited) return false;
                    var module = process.MainModule;
                    var file = module == null ? null : module.FileName;
                    var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                    return IsGameProcessPath(file, fullRoot);
                }
            }
            catch
            {
                return false;
            }
        }

        private static int KillGameProcesses(string root, IList<int> pids, out int failed)
        {
            var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            var killed = 0;
            failed = 0;
            foreach (var pid in pids.Distinct().ToArray())
            {
                try
                {
                    using (var process = System.Diagnostics.Process.GetProcessById(pid))
                    {
                        if (process.HasExited) continue;
                        var module = process.MainModule;
                        var file = module == null ? null : module.FileName;
                        if (!IsGameProcessPath(file, fullRoot))
                        {
                            ++failed;
                            continue;
                        }

                        process.Kill();
                        if (!process.WaitForExit(5000))
                        {
                            ++failed;
                            continue;
                        }
                        ++killed;
                    }
                }
                catch (ArgumentException)
                {
                    // Process already exited naturally after confirmed ReloadUI.
                }
                catch
                {
                    ++failed;
                }
            }
            return killed;
        }

        private static bool IsGameProcessPath(string file, string fullRoot)
        {
            if (string.IsNullOrWhiteSpace(file)) return false;
            var fullPath = Path.GetFullPath(file);
            var name = Path.GetFileName(fullPath);
            var isWow = string.Equals(name, "WoW.exe", StringComparison.OrdinalIgnoreCase)
                || (name.StartsWith("WoW_", StringComparison.OrdinalIgnoreCase)
                    && name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase));
            return isWow && fullPath.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsGameRunning(string root)
        {
            var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            foreach (var process in Process.GetProcesses())
            {
                try
                {
                    var file = process.MainModule == null ? null : process.MainModule.FileName;
                    if (!string.IsNullOrWhiteSpace(file) && Path.GetFullPath(file).StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase)) return true;
                }
                catch { }
                finally { process.Dispose(); }
            }
            return false;
        }

        private static void ReplaceFile(string temp, string destination)
        {
            UpdaterSafety.ReplaceFile(temp, destination, ".wow112replace");
        }

        private static string SafeDestination(string root, string name)
        {
            if (UpdaterAddons.IsAddonPath(name)) return UpdaterAddons.SafeAddonDestination(root, name);
            if (string.IsNullOrWhiteSpace(name) || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || Path.GetFileName(name) != name)
                throw new InvalidOperationException("Nieprawidłowa nazwa pliku w paczce: " + name);
            var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            var dest = Path.GetFullPath(Path.Combine(root, name));
            if (!dest.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Niebezpieczna ścieżka: " + name);
            return dest;
        }

        private static byte[] ReadEntry(ZipArchiveEntry entry)
        {
            using (var input = entry.Open())
            using (var output = new MemoryStream())
            {
                input.CopyTo(output);
                return output.ToArray();
            }
        }

        private static string Sha256(byte[] bytes)
        {
            using (var sha = SHA256.Create()) return ToHex(sha.ComputeHash(bytes));
        }

        private static string Sha256File(string path)
        {
            using (var sha = SHA256.Create())
            using (var stream = File.OpenRead(path)) return ToHex(sha.ComputeHash(stream));
        }

        private static string ToHex(byte[] bytes)
        {
            var sb = new StringBuilder(bytes.Length * 2);
            foreach (var b in bytes) sb.Append(b.ToString("x2"));
            return sb.ToString();
        }

        private static Dictionary<string, object> AsDictionary(object value)
        {
            var dict = value as Dictionary<string, object>;
            if (dict == null) throw new InvalidOperationException("Nieoczekiwany JSON z GitHuba.");
            return dict;
        }

        private static object[] AsArray(object value)
        {
            if (value == null) return new object[0];
            var array = value as object[];
            if (array != null) return array;
            var list = value as ArrayList;
            if (list != null) return list.ToArray();
            return new object[0];
        }

        private static object GetValue(Dictionary<string, object> dict, string key)
        {
            object value;
            return dict != null && dict.TryGetValue(key, out value) ? value : null;
        }

        private static string GetString(Dictionary<string, object> dict, string key)
        {
            var value = GetValue(dict, key);
            return value == null ? string.Empty : Convert.ToString(value);
        }

        private static long GetLong(Dictionary<string, object> dict, string key)
        {
            var value = GetValue(dict, key);
            if (value == null) return 0L;
            return Convert.ToInt64(value);
        }

        private static bool GetBool(Dictionary<string, object> dict, string key)
        {
            var value = GetValue(dict, key);
            if (value == null) return false;
            return Convert.ToBoolean(value);
        }

        private static string TrimForError(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return "brak treści odpowiedzi";
            text = text.Replace("\r", " ").Replace("\n", " ").Trim();
            return text.Length <= 240 ? text : text.Substring(0, 240) + "...";
        }

        private static string ShortSha(string sha)
        {
            return string.IsNullOrWhiteSpace(sha) ? "?" : sha.Substring(0, Math.Min(8, sha.Length));
        }

        private static string FormatBytes(long bytes)
        {
            if (bytes >= 1024L * 1024L) return (bytes / (1024.0 * 1024.0)).ToString("0.0") + " MB";
            if (bytes >= 1024L) return (bytes / 1024.0).ToString("0.0") + " KB";
            return bytes + " B";
        }

        private sealed class RemotePackageInfo
        {
            public string Channel;
            public long RunId;
            public string HeadSha;
            public string ArtifactName;
            public string DownloadUrl;
            public string InnerZipName;
        }

        private sealed class PackageFile
        {
            public readonly string Name;
            public readonly byte[] Bytes;
            public readonly string Sha256;
            public PackageFile(string name, byte[] bytes)
            {
                Name = name;
                Bytes = bytes;
                Sha256 = MainForm.Sha256(bytes);
            }
        }

        private sealed class ApplyResult
        {
            public int Changed;
            public int Deferred;
            public int Unchanged;
            public bool ExeChanged;
            public string BackupDir;
        }

        private sealed class BackupChoice
        {
            public readonly string Path;
            public readonly string Label;

            public BackupChoice(string path, string label)
            {
                Path = path;
                Label = label;
            }

            public override string ToString()
            {
                return Label;
            }
        }
    }
}

