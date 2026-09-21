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
        private const string StableWorkflowName = "Build stable candidate";
        private const string TestArtifactPrefix = "WoW112-WORK-CANDIDATE-";
        private const string StableArtifactPrefix = "WoW112-STABLE-CANDIDATE-";
        private const string TestInnerZip = "WoW112_WORK_CANDIDATE.zip";
        private const string StableInnerZip = "WoW112_STABLE_CANDIDATE.zip";
        private const string UpdaterVersion = UpdaterBuildInfo.Version;
        private const int MaxBackups = 10;

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
        private readonly Button browseButton = new Button();
        private readonly Button saveButton = new Button();
        private readonly JavaScriptSerializer json = new JavaScriptSerializer();
        private readonly string configDir;
        private readonly string configPath;
        private RemotePackageInfo lastRemote;
        private bool busy;

        public MainForm()
        {
            Text = "WoW112 Updater v" + UpdaterVersion;
            ClientSize = new Size(860, 660);
            MinimumSize = new Size(860, 660);
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 9F);

            configDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "WoW112Updater");
            if (Environment.GetCommandLineArgs().Contains("--ui-smoke"))
                configDir = Path.Combine(Path.GetTempPath(), "WoW112UiSmoke-" + Guid.NewGuid().ToString("N"));
            configPath = Path.Combine(configDir, "config.json");

            BuildUi();
            LoadConfig();
            RefreshLocalState();
        }

        private void BuildUi()
        {
            channel.DropDownStyle = ComboBoxStyle.DropDownList;
            channel.Items.AddRange(new object[] { "TEST (work)", "STABLE (main)" });
            channel.SelectedIndex = 0;
            rollbackChoice.DropDownStyle = ComboBoxStyle.DropDownList;
            token.UseSystemPasswordChar = true;
            browseButton.Click += BrowseButton_Click;
            checkButton.Click += async delegate { await CheckAsync(); };
            updateButton.Click += async delegate { await UpdateAsync(); };
            updatePlayButton.Click += async delegate { await UpdateAndPlayAsync(); };
            launchButton.Click += delegate { LaunchGame(); };
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
                if (selected == "stable") channel.SelectedIndex = 1;
                LoadDllUpdatePreferences(root);
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
                root["channel"] = IsStable() ? "stable" : "test";
                root["token_dpapi"] = protectedToken;
                root["dll_update_enabled"] = GetDllUpdatePreferencesForSave();
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
            return channel.SelectedIndex == 1;
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
                ShowRemoteDllSummary();
                var installed = ReadInstalledState();
                Log("Najnowszy build: " + ShortSha(lastRemote.HeadSha) + " / run " + lastRemote.RunId);

                var dllChanges = LastDllChangeCount;
                var enabledDllChanges = LastEnabledDllChangeCount;
                var skippedDllChanges = dllChanges - enabledDllChanges;
                var exeChanged = lastExeInspection == null || lastExeInspection.HasChange;
                if (exeChanged || dllChanges > 0)
                {
                    status.Text = "EXE: " + (lastExeInspection == null ? "NIE SPRAWDZONO" : lastExeInspection.State)
                        + " • DLL: " + enabledDllChanges + " do aktualizacji"
                        + (skippedDllChanges > 0 ? " • " + skippedDllChanges + " pominiętych" : string.Empty);
                    Log("EXE " + (exeChanged ? "wymaga aktualizacji" : "jest aktualny")
                        + "; DLL: " + dllChanges + " zmian, aktywne: " + enabledDllChanges + ".");
                }
                else if (installed != null && GetLong(installed, "run_id") == lastRemote.RunId && GetString(installed, "channel") == lastRemote.Channel)
                {
                    status.Text = "Masz najnowszą wersję " + lastRemote.Channel.ToUpperInvariant() + " • EXE i DLL aktualne.";
                    Log("EXE i każda DLL odpowiadają najnowszemu artefaktowi.");
                }
                else
                {
                    status.Text = "Nowy build dostępny • EXE i DLL bez zmian.";
                    Log("Nowy artefakt jest dostępny, ale SHA256 EXE i wszystkich DLL już są zgodne.");
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
                if (IsGameRunning(gameDir.Text.Trim()))
                    throw new InvalidOperationException("Gra działa z tego katalogu. Zamknij WoW przed aktualizacją.");

                SaveConfig(false);
                SetBusy(true, "Pobieranie najnowszej paczki...");
                lastRemote = await FindLatestPackageAsync();
                ShowRemotePackage();
                var innerBytes = await GetVerifiedPackageBytesAsync(lastRemote);
                InspectDllPackage(innerBytes, gameDir.Text.Trim());
                ShowRemoteDllSummary();
                var installRoot = Path.GetFullPath(gameDir.Text.Trim());
                var installRemote = lastRemote;
                status.Text = "Instalowanie zweryfikowanych plików...";
                var addonFiles = new List<UpdaterAddonAsset>(cachedVerifiedAddons);
                var result = await Task.Run(() => ApplyPackage(innerBytes, installRemote, installRoot, addonFiles));
                status.Text = result.Changed == 0
                    ? "EXE i pozostałe pliki już były aktualne."
                    : "Aktualizacja zakończona: " + result.Changed + " plików"
                        + (result.ExeChanged ? " (w tym EXE)." : ".");
                Log("Gotowe. Zmieniono: " + result.Changed + ", bez zmian: " + result.Unchanged
                    + "; EXE: " + (result.ExeChanged ? "zaktualizowany" : "bez zmian") + ".");
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
            if (!status.Text.StartsWith("Aktualizacja nie powiodła", StringComparison.OrdinalIgnoreCase))
            {
                status.Text = "Gotowe. Uruchamiam WoW...";
                LaunchGame();
            }
        }

        private async Task<RemotePackageInfo> FindLatestPackageAsync()
        {
            var stable = IsStable();
            var branch = stable ? "main" : "work";
            var workflowName = stable ? StableWorkflowName : TestWorkflowName;
            var prefix = stable ? StableArtifactPrefix : TestArtifactPrefix;
            var innerName = stable ? StableInnerZip : TestInnerZip;

            using (var client = CreateClient())
            {
                var runsUrl = ApiRoot + "/actions/runs?branch=" + branch + "&per_page=50";
                var runsRoot = AsDictionary(json.DeserializeObject(await GetStringAsync(client, runsUrl)));
                var runs = AsArray(GetValue(runsRoot, "workflow_runs"));
                Dictionary<string, object> chosen;
                try
                {
                    chosen = UpdaterSafety.RequireLatestSuccessfulRun(runs, workflowName, branch);
                }
                catch (InvalidOperationException)
                {
                    if (stable && !runs.Any(item => string.Equals(GetString(item as Dictionary<string, object>, "name"), workflowName, StringComparison.Ordinal)))
                        throw new InvalidOperationException("Kanał STABLE nie ma jeszcze opublikowanej paczki updatera. Na razie wybierz TEST (work).");
                    throw;
                }

                var runId = GetLong(chosen, "id");
                var artifactsRoot = AsDictionary(json.DeserializeObject(await GetStringAsync(client, ApiRoot + "/actions/runs/" + runId + "/artifacts?per_page=100")));
                var artifacts = AsArray(GetValue(artifactsRoot, "artifacts"));
                Dictionary<string, object> artifact = null;
                foreach (var item in artifacts)
                {
                    var row = AsDictionary(item);
                    var name = GetString(row, "name");
                    var expired = GetBool(row, "expired");
                    if (!expired && name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                    {
                        artifact = row;
                        break;
                    }
                }
                if (artifact == null) throw new InvalidOperationException("Najnowszy udany workflow nie ma aktywnego artefaktu " + prefix + "*." );

                return new RemotePackageInfo
                {
                    Channel = stable ? "stable" : "test",
                    RunId = runId,
                    HeadSha = GetString(chosen, "head_sha"),
                    ArtifactName = GetString(artifact, "name"),
                    DownloadUrl = GetString(artifact, "archive_download_url"),
                    InnerZipName = innerName
                };
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

        private void ExtractInnerPackage(byte[] outerBytes, string innerZipName, out byte[] innerBytes, out string expectedSha)
        {
            innerBytes = null;
            expectedSha = string.Empty;
            using (var ms = new MemoryStream(outerBytes, false))
            using (var zip = new ZipArchive(ms, ZipArchiveMode.Read, false))
            {
                var inner = zip.Entries.FirstOrDefault(e => string.Equals(Path.GetFileName(e.FullName), innerZipName, StringComparison.OrdinalIgnoreCase));
                if (inner == null) throw new InvalidOperationException("Artefakt nie zawiera " + innerZipName + ".");
                innerBytes = ReadEntry(inner);

                var metaEntry = zip.Entries.FirstOrDefault(e => string.Equals(Path.GetFileName(e.FullName), "candidate_metadata.json", StringComparison.OrdinalIgnoreCase));
                if (metaEntry == null)
                    throw new InvalidOperationException("Artefakt nie zawiera candidate_metadata.json; instalacja została zablokowana.");
                var metaText = Encoding.UTF8.GetString(ReadEntry(metaEntry));
                var meta = AsDictionary(json.DeserializeObject(metaText));
                expectedSha = GetString(meta, "package_sha256");
                if (!UpdaterSafety.IsSha256Hex(expectedSha))
                    throw new InvalidOperationException("candidate_metadata.json nie zawiera poprawnego package_sha256; instalacja została zablokowana.");
            }
        }

        private ApplyResult ApplyPackage(byte[] packageBytes, RemotePackageInfo remote, string root, IList<UpdaterAddonAsset> addonFiles)
        {
            if (IsGameRunning(root)) throw new InvalidOperationException("Gra działa. Zamknij WoW przed instalacją.");
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
            // Validated independently against addon_metadata.json and the source build SHA.
            // Addons are never entered into dlls.txt, and unrelated AddOns are untouched.
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
                if (IsDllUpdateEnabled(file.Name))
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
                if (!IsDllUpdateEnabled(oldName) && File.Exists(dest) && !finalDllNames.Contains(oldName, StringComparer.OrdinalIgnoreCase))
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
                && (!name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) || IsDllUpdateEnabled(name))).ToList();

            var backupDir = string.Empty;
            if (changed.Count > 0 || stale.Count > 0)
            {
                backupDir = CreateBackup(root, changed.Select(f => f.Name).Concat(stale).Distinct(StringComparer.OrdinalIgnoreCase).ToList(), oldState, remote);
            }

            try
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

                foreach (var name in stale)
                {
                    File.Delete(SafeDestination(root, name));
                    Log("DEL " + name + " (stary zarządzany plik)");
                }

                var exeName = files.First(f => f.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)).Name;
                WriteInstalledState(root, remote, newManaged.ToList(), exeName);
            }
            catch
            {
                if (!string.IsNullOrWhiteSpace(backupDir)) RestoreBackupDirectory(root, backupDir, false);
                throw;
            }

            return new ApplyResult { Changed = changed.Count + stale.Count, Unchanged = files.Count - changed.Count,
                ExeChanged = changed.Any(f => f.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)),
                BackupDir = backupDir };
        }

        private string CreateBackup(string root, IList<string> touchedNames, Dictionary<string, object> oldState, RemotePackageInfo remote)
        {
            var backupRoot = Path.Combine(root, ".wow112_updater", "backups");
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

            var backupRoot = Path.Combine(root, ".wow112_updater", "backups");
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
                var backupRoot = Path.Combine(root, ".wow112_updater", "backups");
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
                    var backupRoot = Path.Combine(root, ".wow112_updater", "backups");
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
            return Path.Combine(root, ".wow112_updater", "installed.json");
        }

        private void LaunchGame()
        {
            try
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
                var game = Process.Start(new ProcessStartInfo(exe) { WorkingDirectory = root, UseShellExecute = true });
                Log("Uruchomiono: " + Path.GetFileName(exe));
                RememberGameSession(game);
            }
            catch (Exception ex)
            {
                Log("BŁĄD: " + ex.Message);
                MessageBox.Show(this, ex.Message, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
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

