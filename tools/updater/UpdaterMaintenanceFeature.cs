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
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal static class MaintenanceFeature
    {
        public static void Attach(Form form)
        {
            if (form == null) return;
            var host = form as IUpdaterHost;
            if (host == null)
                throw new InvalidOperationException("MainForm nie implementuje IUpdaterHost; maintenance nie może zostać bezpiecznie podłączony.");
            new MaintenanceController(host).Attach();
        }

        private sealed class MaintenanceController
        {
            private const string FeatureVersion = UpdaterBuildInfo.Version;
            private const string Owner = "github12wykrzyk";
            private const string Repo = "wow112";
            private const string ApiRoot = "https://api.github.com/repos/" + Owner + "/" + Repo;
            private const string UpdaterWorkflowName = "Build WoW112 updater";
            private const string UpdaterArtifactPrefix = "WoW112ParallelUpdater-";
            private const int AddedHeight = 62;
            private const int MaxBackups = 10;

            private readonly IUpdaterHost host;
            private readonly Form form;
            private readonly JavaScriptSerializer json = new JavaScriptSerializer();
            private readonly Button verifyRepairButton = new Button();
            private readonly Button diagnosticsButton = new Button();
            private readonly Button selfUpdateButton = new Button();
            private bool attached;
            private bool maintenanceBusy;

            public MaintenanceController(IUpdaterHost host)
            {
                this.host = host ?? throw new ArgumentNullException("host");
                form = host.Window ?? throw new InvalidOperationException("IUpdaterHost.Window nie może być null.");
            }

            public void Attach()
            {
                if (attached) return;
                attached = true;

                verifyRepairButton.Click += async delegate { await VerifyRepairAsync(); };
                diagnosticsButton.Click += delegate { ExportDiagnostics(); };
                selfUpdateButton.Click += async delegate { await SelfUpdateAsync(); };
                host.RegisterUiControl("verify", verifyRepairButton);
                host.RegisterUiControl("diagnostics", diagnosticsButton);
                host.RegisterUiControl("selfUpdate", selfUpdateButton);

                host.GameDirectoryChanged += delegate { StampLocalUpdaterVersion(); };
                StampLocalUpdaterVersion();
                Log("Moduł maintenance v" + FeatureVersion + " gotowy (IUpdaterHost, bez reflection do MainForm).");
            }

            private async Task VerifyRepairAsync()
            {
                string finalStatus = "Gotowy";
                try
                {
                    ValidateGameAndToken();
                    SetBusy(true, "Weryfikacja zainstalowanej paczki...");
                    var root = Path.GetFullPath(host.GameDirectory);
                    var installed = ReadInstalledState(root);
                    if (installed == null)
                        throw new InvalidOperationException("Brak .wow112_parallel_updater/installed.json. Najpierw wykonaj aktualizację updaterem.");

                    var expected = await DownloadExpectedInstalledFilesAsync(installed);
                    var comparison = CompareInstalledFiles(root, installed, expected);
                    if (comparison.BadExpected.Count == 0 && comparison.StaleManaged.Count == 0)
                    {
                        MarkIntegrity(installed, root, false, "ok");
                        finalStatus = "VERIFY OK — pliki są zgodne z zainstalowanym buildem.";
                        Log(finalStatus);
                        return;
                    }

                    Log("VERIFY wykrył problemy: " + comparison.BadExpected.Count + " brakujących/uszkodzonych, " + comparison.StaleManaged.Count + " starych zarządzanych.");
                    foreach (var name in comparison.BadExpected) Log("BAD " + name);
                    foreach (var name in comparison.StaleManaged) Log("STALE " + name);

                    if (IsGameRunning(root))
                        throw new InvalidOperationException("Wykryto pliki wymagające naprawy, ale WoW działa. Zamknij grę i uruchom VERIFY / REPAIR ponownie.");

                    var answer = MessageBox.Show(
                        form,
                        "Wykryto " + (comparison.BadExpected.Count + comparison.StaleManaged.Count) + " problemów z plikami zarządzanymi przez updater.\n\nNaprawić je teraz z dokładnie tego samego zainstalowanego buildu?",
                        "WoW112 Updater — VERIFY / REPAIR",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Question);
                    if (answer != DialogResult.Yes)
                    {
                        finalStatus = "VERIFY: wykryto problemy; naprawa anulowana.";
                        return;
                    }

                    var touched = comparison.BadExpected.Concat(comparison.StaleManaged).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
                    var backupDir = CreateRepairBackup(root, touched, installed);
                    try
                    {
                        foreach (var name in comparison.BadExpected)
                        {
                            var file = expected.First(x => string.Equals(x.Name, name, StringComparison.OrdinalIgnoreCase));
                            var dest = SafeDestination(root, file.Name);
                            var temp = dest + ".wow112repairtmp";
                            File.WriteAllBytes(temp, file.Bytes);
                            if (!string.Equals(Sha256File(temp), file.Sha256, StringComparison.OrdinalIgnoreCase))
                                throw new InvalidOperationException("SHA256 nie zgadza się po zapisie naprawczym: " + file.Name);
                            ReplaceFile(temp, dest);
                            Log("REPAIR " + file.Name);
                        }

                        foreach (var name in comparison.StaleManaged)
                        {
                            var dest = SafeDestination(root, name);
                            if (File.Exists(dest)) File.Delete(dest);
                            Log("DEL " + name + " (stary zarządzany plik)");
                        }

                        var after = CompareInstalledFiles(root, installed, expected);
                        if (after.BadExpected.Count != 0 || after.StaleManaged.Count != 0)
                            throw new InvalidOperationException("Weryfikacja po naprawie nadal wykrywa niespójność.");

                        MarkIntegrity(installed, root, true, "ok");
                        TrimBackups(root, MaxBackups);
                        finalStatus = "REPAIR OK — przywrócono zgodność plików.";
                        Log(finalStatus + " Backup: " + backupDir);
                    }
                    catch
                    {
                        RestoreRepairBackup(root, backupDir);
                        throw;
                    }
                }
                catch (Exception ex)
                {
                    finalStatus = "VERIFY / REPAIR nie powiódł się";
                    Log("BŁĄD maintenance: " + ex.Message);
                    MessageBox.Show(form, ex.Message, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                finally
                {
                    host.RefreshLocalState();
                    SetBusy(false, finalStatus);
                }
            }

            private async Task SelfUpdateAsync()
            {
                string finalStatus = "Gotowy";
                var exitingForUpdate = false;
                try
                {
                    if (maintenanceBusy) return;
                    if (string.IsNullOrWhiteSpace(host.GitHubToken))
                        throw new InvalidOperationException("Wpisz GitHub token z prawem odczytu repozytorium i Actions.");

                    SetBusy(true, "Sprawdzanie aktualizacji updatera...");
                    var remote = await DownloadLatestUpdaterAsync();
                    var currentExe = Assembly.GetExecutingAssembly().Location;
                    var currentSha = Sha256File(currentExe);
                    Log("Updater lokalny: " + currentSha.Substring(0, 12) + "..., zdalny " + remote.Version + ": " + remote.UpdaterSha.Substring(0, 12) + "...");
                    if (string.Equals(currentSha, remote.UpdaterSha, StringComparison.OrdinalIgnoreCase))
                    {
                        finalStatus = "Updater jest aktualny (" + remote.Version + ").";
                        Log(finalStatus);
                        return;
                    }

                    var currentDir = Path.GetDirectoryName(currentExe);
                    var stageDir = Path.Combine(currentDir, ".wow112_parallel_updater", "selfupdate");
                    Directory.CreateDirectory(stageDir);
                    var stagedUpdater = Path.Combine(stageDir, "WoW112ParallelUpdater.next.exe");
                    var bootstrapPath = Path.Combine(stageDir, "WoW112UpdaterBootstrap.exe");
                    File.WriteAllBytes(stagedUpdater, remote.UpdaterBytes);
                    File.WriteAllBytes(bootstrapPath, remote.BootstrapBytes);
                    if (!string.Equals(Sha256File(stagedUpdater), remote.UpdaterSha, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("SHA256 staged updatera nie zgadza się z updater_build.json.");
                    if (!string.Equals(Sha256File(bootstrapPath), remote.BootstrapSha, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("SHA256 bootstrapa nie zgadza się z updater_build.json.");

                    var pid = System.Diagnostics.Process.GetCurrentProcess().Id;
                    var args = "--wait-pid " + pid
                        + " --source " + QuoteArg(stagedUpdater)
                        + " --target " + QuoteArg(currentExe)
                        + " --sha256 " + remote.UpdaterSha
                        + " --restart";
                    System.Diagnostics.Process.Start(new ProcessStartInfo(bootstrapPath, args)
                    {
                        WorkingDirectory = stageDir,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    });

                    finalStatus = "Pobrano updater " + remote.Version + ". Restartuję updater...";
                    Log(finalStatus);
                    exitingForUpdate = true;
                    form.BeginInvoke((MethodInvoker)delegate { System.Windows.Forms.Application.Exit(); });
                }
                catch (Exception ex)
                {
                    finalStatus = "Aktualizacja updatera nie powiodła się";
                    Log("BŁĄD self-update: " + ex.Message);
                    MessageBox.Show(form, ex.Message, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                finally
                {
                    if (!exitingForUpdate) SetBusy(false, finalStatus);
                }
            }

            private void ExportDiagnostics()
            {
                string finalStatus = "Gotowy";
                try
                {
                    if (maintenanceBusy) return;
                    var root = host.GameDirectory;
                    if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
                        throw new InvalidOperationException("Wybierz istniejący katalog gry.");
                    root = Path.GetFullPath(root);
                    SetBusy(true, "Tworzenie diagnostyki...");

                    var outDir = Path.Combine(root, ".wow112_parallel_updater", "diagnostics");
                    Directory.CreateDirectory(outDir);
                    var path = Path.Combine(outDir, "WoW112_diagnostics_" + DateTime.Now.ToString("yyyyMMdd_HHmmss") + ".zip");
                    using (var fs = File.Create(path))
                    using (var zip = new ZipArchive(fs, ZipArchiveMode.Create, false))
                    {
                        var installed = ReadInstalledState(root);
                        if (installed != null)
                            AddText(zip, "installed_sanitized.json", json.Serialize(SanitizeInstalled(installed)));

                        var dllsPath = Path.Combine(root, "dlls.txt");
                        if (File.Exists(dllsPath)) AddFile(zip, dllsPath, "dlls.txt");
                        var realmlistPath = Path.Combine(root, "realmlist.wtf");
                        if (File.Exists(realmlistPath)) AddFile(zip, realmlistPath, "realmlist.wtf");

                        AddText(zip, "updater_info.txt", BuildUpdaterInfo(root));
                        AddText(zip, "managed_hashes.txt", BuildManagedHashes(root, installed));
                        AddText(zip, "backup_index.txt", BuildBackupIndex(root));
                        AddText(zip, "session_log.txt", host.SessionLogText);
                    }

                    finalStatus = "Diagnostyka zapisana: " + path;
                    Log(finalStatus);
                    MessageBox.Show(form, "Gotowe.\n\n" + path + "\n\nZIP nie zawiera tokenu GitHub ani zaszyfrowanego tokenu DPAPI.", "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                catch (Exception ex)
                {
                    finalStatus = "Diagnostyka nie powiodła się";
                    Log("BŁĄD diagnostyki: " + ex.Message);
                    MessageBox.Show(form, ex.Message, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                finally
                {
                    SetBusy(false, finalStatus);
                }
            }

            private async Task<List<ExpectedFile>> DownloadExpectedInstalledFilesAsync(Dictionary<string, object> installed)
            {
                var runId = GetLong(installed, "run_id");
                var artifactName = GetString(installed, "artifact_name");
                var installedChannel = GetString(installed, "channel");
                if (runId <= 0 || string.IsNullOrWhiteSpace(artifactName))
                    throw new InvalidOperationException("installed.json nie zawiera identyfikatora buildu/artifactu.");

                using (var client = CreateClient())
                {
                    var root = AsDictionary(json.DeserializeObject(await GetStringAsync(client, ApiRoot + "/actions/runs/" + runId + "/artifacts?per_page=100")));
                    Dictionary<string, object> artifact = null;
                    foreach (var item in AsArray(GetValue(root, "artifacts")))
                    {
                        var row = AsDictionary(item);
                        if (!GetBool(row, "expired") && string.Equals(GetString(row, "name"), artifactName, StringComparison.OrdinalIgnoreCase))
                        {
                            artifact = row;
                            break;
                        }
                    }
                    if (artifact == null)
                        throw new InvalidOperationException("Artifact zainstalowanego buildu wygasł albo nie jest już dostępny. Wykonaj normalną aktualizację do bieżącego TEST/STABLE.");

                    var outer = await DownloadBytesAsync(client, GetString(artifact, "archive_download_url"));
                    var innerName = string.Equals(installedChannel, "stable", StringComparison.OrdinalIgnoreCase)
                        ? "WoW112_STABLE_CANDIDATE.zip"
                        : "WoW112_WORK_CANDIDATE.zip";
                    byte[] inner;
                    string expectedPackageSha;
                    ExtractCandidate(outer, innerName, out inner, out expectedPackageSha);
                    var gotPackageSha = Sha256(inner);
                    if (!string.Equals(gotPackageSha, expectedPackageSha, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("SHA256 paczki zainstalowanego buildu nie zgadza się z candidate_metadata.json.");
                    return BuildExpectedFiles(inner);
                }
            }

            private async Task<RemoteUpdaterBuild> DownloadLatestUpdaterAsync()
            {
                var branch = "parallel";
                using (var client = CreateClient())
                {
                    var runs = AsArray(GetValue(AsDictionary(json.DeserializeObject(await GetStringAsync(client, ApiRoot + "/actions/runs?branch=" + branch + "&per_page=50"))), "workflow_runs"));
                    var chosen = UpdaterSafety.RequireLatestSuccessfulRun(runs, UpdaterWorkflowName, branch);

                    var runId = GetLong(chosen, "id");
                    var artifacts = AsArray(GetValue(AsDictionary(json.DeserializeObject(await GetStringAsync(client, ApiRoot + "/actions/runs/" + runId + "/artifacts?per_page=100"))), "artifacts"));
                    Dictionary<string, object> artifact = null;
                    foreach (var item in artifacts)
                    {
                        var row = AsDictionary(item);
                        var name = GetString(row, "name");
                        if (!GetBool(row, "expired") && name.StartsWith(UpdaterArtifactPrefix, StringComparison.OrdinalIgnoreCase))
                        {
                            artifact = row;
                            break;
                        }
                    }
                    if (artifact == null) throw new InvalidOperationException("Najnowszy udany workflow updatera nie ma aktywnego artefaktu.");

                    var outer = await DownloadBytesAsync(client, GetString(artifact, "archive_download_url"));
                    using (var ms = new MemoryStream(outer, false))
                    using (var zip = new ZipArchive(ms, ZipArchiveMode.Read, false))
                    {
                        var updaterEntry = FindEntry(zip, "WoW112ParallelUpdater.exe");
                        var bootstrapEntry = FindEntry(zip, "WoW112UpdaterBootstrap.exe");
                        var metaEntry = FindEntry(zip, "updater_build.json");
                        if (updaterEntry == null || bootstrapEntry == null || metaEntry == null)
                            throw new InvalidOperationException("Artifact updatera nie zawiera kompletnego protokołu self-update v1.");

                        var updaterBytes = ReadEntry(updaterEntry);
                        var bootstrapBytes = ReadEntry(bootstrapEntry);
                        var meta = AsDictionary(json.DeserializeObject(Encoding.UTF8.GetString(ReadEntry(metaEntry))));
                        var protocol = GetLong(meta, "self_update_protocol");
                        if (protocol != 1) throw new InvalidOperationException("Nieobsługiwany self_update_protocol: " + protocol);
                        if (!string.Equals(GetString(meta, "channel"), "parallel", StringComparison.Ordinal) ||
                            !string.Equals(GetString(meta, "name"), "WoW112ParallelUpdater.exe", StringComparison.Ordinal))
                            throw new InvalidOperationException("Zablokowano self-update z obcego kanalu updatera.");
                        var updaterSha = GetString(meta, "sha256");
                        var bootstrapSha = GetString(meta, "bootstrap_sha256");
                        if (!UpdaterSafety.IsSha256Hex(updaterSha) || !string.Equals(Sha256(updaterBytes), updaterSha, StringComparison.OrdinalIgnoreCase))
                            throw new InvalidOperationException("SHA256 WoW112Updater.exe nie zgadza się z updater_build.json.");
                        if (!UpdaterSafety.IsSha256Hex(bootstrapSha) || !string.Equals(Sha256(bootstrapBytes), bootstrapSha, StringComparison.OrdinalIgnoreCase))
                            throw new InvalidOperationException("SHA256 bootstrapa nie zgadza się z updater_build.json.");
                        var version = GetString(meta, "updater_version");
                        if (string.IsNullOrWhiteSpace(version))
                            throw new InvalidOperationException("updater_build.json nie zawiera updater_version.");

                        return new RemoteUpdaterBuild
                        {
                            Version = version,
                            UpdaterSha = updaterSha,
                            BootstrapSha = bootstrapSha,
                            UpdaterBytes = updaterBytes,
                            BootstrapBytes = bootstrapBytes
                        };
                    }
                }
            }

            private List<ExpectedFile> BuildExpectedFiles(byte[] packageBytes)
            {
                var files = new List<ExpectedFile>();
                var packageNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                using (var ms = new MemoryStream(packageBytes, false))
                using (var zip = new ZipArchive(ms, ZipArchiveMode.Read, false))
                {
                    foreach (var entry in zip.Entries)
                    {
                        if (string.IsNullOrWhiteSpace(entry.Name)) continue;
                        if (!string.Equals(entry.Name, entry.FullName, StringComparison.Ordinal))
                            throw new InvalidOperationException("Paczka zawiera zagnieżdżoną ścieżkę: " + entry.FullName);
                        if (!packageNames.Add(entry.Name))
                            throw new InvalidOperationException("Paczka zawiera powieloną nazwę pliku (bez rozróżniania wielkości liter): " + entry.Name);
                        var ext = Path.GetExtension(entry.Name).ToLowerInvariant();
                        if (ext != ".dll" && ext != ".exe") continue;
                        files.Add(new ExpectedFile(entry.Name, ReadEntry(entry)));
                    }
                }
                if (!files.Any(x => x.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) || !files.Any(x => x.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)))
                    throw new InvalidOperationException("Paczka zainstalowanego buildu jest niekompletna.");
                var dllList = string.Join("\r\n", files.Where(x => x.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)).Select(x => x.Name).ToArray()) + "\r\n";
                files.Add(new ExpectedFile("dlls.txt", Encoding.ASCII.GetBytes(dllList)));
                return files;
            }

            private ComparisonResult CompareInstalledFiles(string root, Dictionary<string, object> installed, List<ExpectedFile> expected)
            {
                var result = new ComparisonResult();
                foreach (var file in expected)
                {
                    var path = SafeDestination(root, file.Name);
                    if (!File.Exists(path) || !string.Equals(Sha256File(path), file.Sha256, StringComparison.OrdinalIgnoreCase))
                        result.BadExpected.Add(file.Name);
                }

                var expectedNames = new HashSet<string>(expected.Select(x => x.Name), StringComparer.OrdinalIgnoreCase);
                foreach (var item in AsArray(GetValue(installed, "managed_files")))
                {
                    var name = Convert.ToString(item);
                    if (string.IsNullOrWhiteSpace(name) || expectedNames.Contains(name)) continue;
                    if (File.Exists(SafeDestination(root, name))) result.StaleManaged.Add(name);
                }
                return result;
            }

            private string CreateRepairBackup(string root, IList<string> touchedNames, Dictionary<string, object> installed)
            {
                var backupRoot = Path.Combine(root, ".wow112_parallel_updater", "backups");
                Directory.CreateDirectory(backupRoot);
                var dir = Path.Combine(backupRoot, DateTime.Now.ToString("yyyyMMdd_HHmmss_fff") + "_repair_run" + GetLong(installed, "run_id"));
                Directory.CreateDirectory(dir);
                var rows = new ArrayList();
                foreach (var name in touchedNames)
                {
                    var src = SafeDestination(root, name);
                    var existed = File.Exists(src);
                    if (existed) File.Copy(src, Path.Combine(dir, name), true);
                    rows.Add(new Dictionary<string, object> { { "name", name }, { "existed", existed } });
                }
                var manifest = new Dictionary<string, object>();
                manifest["created_utc"] = DateTime.UtcNow.ToString("o");
                manifest["target_run_id"] = GetLong(installed, "run_id");
                manifest["target_head_sha"] = GetString(installed, "head_sha");
                manifest["files"] = rows;
                manifest["previous_installed"] = installed;
                UpdaterSafety.WriteUtf8Atomic(Path.Combine(dir, "backup_manifest.json"), json.Serialize(manifest), ".tmp", ".previous");
                return dir;
            }

            private void RestoreRepairBackup(string root, string dir)
            {
                try
                {
                    var manifest = AsDictionary(json.DeserializeObject(File.ReadAllText(Path.Combine(dir, "backup_manifest.json"), Encoding.UTF8)));
                    foreach (var item in AsArray(GetValue(manifest, "files")))
                    {
                        var row = AsDictionary(item);
                        var name = GetString(row, "name");
                        var dest = SafeDestination(root, name);
                        if (GetBool(row, "existed")) File.Copy(Path.Combine(dir, name), dest, true);
                        else if (File.Exists(dest)) File.Delete(dest);
                    }
                    var previous = GetValue(manifest, "previous_installed") as Dictionary<string, object>;
                    if (previous != null) WriteInstalledState(root, previous);
                    Log("Naprawa została cofnięta z backupu po błędzie.");
                }
                catch (Exception ex)
                {
                    Log("BŁĄD rollbacku naprawy: " + ex.Message);
                }
            }

            private void MarkIntegrity(Dictionary<string, object> installed, string root, bool repaired, string value)
            {
                installed["updater_version"] = FeatureVersion;
                installed["last_verified_utc"] = DateTime.UtcNow.ToString("o");
                installed["integrity_status"] = value;
                if (repaired) installed["last_repair_utc"] = DateTime.UtcNow.ToString("o");
                WriteInstalledState(root, installed);
            }

            private void StampLocalUpdaterVersion()
            {
                try
                {
                    var root = host.GameDirectory;
                    if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root)) return;
                    var installed = ReadInstalledState(root);
                    if (installed == null) return;
                    if (GetString(installed, "updater_version") == FeatureVersion) return;
                    installed["updater_version"] = FeatureVersion;
                    WriteInstalledState(root, installed);
                }
                catch { }
            }

            private void SetBusy(bool value, string text)
            {
                maintenanceBusy = value;
                host.SetBusy(value, text);
            }

            private void ValidateGameAndToken()
            {
                if (maintenanceBusy) throw new InvalidOperationException("Updater już wykonuje operację.");
                if (string.IsNullOrWhiteSpace(host.GameDirectory) || !Directory.Exists(host.GameDirectory))
                    throw new InvalidOperationException("Wybierz istniejący katalog gry.");
                if (string.IsNullOrWhiteSpace(host.GitHubToken))
                    throw new InvalidOperationException("Wpisz GitHub token z prawem odczytu repozytorium i Actions.");
            }

            private HttpClient CreateClient()
            {
                var handler = new HttpClientHandler { AllowAutoRedirect = true };
                var client = new HttpClient(handler);
                client.Timeout = TimeSpan.FromMinutes(3);
                client.DefaultRequestHeaders.UserAgent.ParseAdd("WoW112Updater/" + FeatureVersion);
                client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
                client.DefaultRequestHeaders.Add("X-GitHub-Api-Version", "2022-11-28");
                client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", host.GitHubToken);
                return client;
            }

            private static async Task<string> GetStringAsync(HttpClient client, string url)
            {
                using (var response = await client.GetAsync(url))
                {
                    var text = await response.Content.ReadAsStringAsync();
                    if (!response.IsSuccessStatusCode)
                        throw new InvalidOperationException("GitHub HTTP " + (int)response.StatusCode + ": " + TrimForError(text));
                    return text;
                }
            }

            private static async Task<byte[]> DownloadBytesAsync(HttpClient client, string url)
            {
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

            private void ExtractCandidate(byte[] outer, string innerName, out byte[] inner, out string expectedSha)
            {
                inner = null;
                expectedSha = string.Empty;
                using (var ms = new MemoryStream(outer, false))
                using (var zip = new ZipArchive(ms, ZipArchiveMode.Read, false))
                {
                    var innerEntry = FindEntry(zip, innerName);
                    if (innerEntry == null) throw new InvalidOperationException("Artifact nie zawiera " + innerName + ".");
                    inner = ReadEntry(innerEntry);
                    var metaEntry = FindEntry(zip, "candidate_metadata.json");
                    if (metaEntry == null)
                        throw new InvalidOperationException("Artifact nie zawiera candidate_metadata.json; VERIFY / REPAIR został zablokowany.");
                    var meta = AsDictionary(json.DeserializeObject(Encoding.UTF8.GetString(ReadEntry(metaEntry))));
                    expectedSha = GetString(meta, "package_sha256");
                    if (!UpdaterSafety.IsSha256Hex(expectedSha))
                        throw new InvalidOperationException("candidate_metadata.json nie zawiera poprawnego package_sha256; VERIFY / REPAIR został zablokowany.");
                }
            }

            private static ZipArchiveEntry FindEntry(ZipArchive zip, string fileName)
            {
                return zip.Entries.FirstOrDefault(x => string.Equals(Path.GetFileName(x.FullName), fileName, StringComparison.OrdinalIgnoreCase));
            }

            private Dictionary<string, object> ReadInstalledState(string root)
            {
                var path = Path.Combine(root, ".wow112_parallel_updater", "installed.json");
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
                catch { return null; }
            }

            private void WriteInstalledState(string root, Dictionary<string, object> state)
            {
                var path = Path.Combine(root, ".wow112_parallel_updater", "installed.json");
                UpdaterSafety.WriteUtf8Atomic(path, json.Serialize(state), ".tmp", ".previous");
            }

            private Dictionary<string, object> SanitizeInstalled(Dictionary<string, object> installed)
            {
                var safe = new Dictionary<string, object>();
                var keys = new[] { "schema_version", "updater_version", "channel", "run_id", "head_sha", "artifact_name", "installed_utc", "managed_files", "exe_name", "last_verified_utc", "last_repair_utc", "integrity_status" };
                foreach (var key in keys)
                {
                    if (installed.ContainsKey(key)) safe[key] = installed[key];
                }
                return safe;
            }

            private string BuildUpdaterInfo(string root)
            {
                var exe = Assembly.GetExecutingAssembly().Location;
                var sb = new StringBuilder();
                sb.AppendLine("feature_version=" + FeatureVersion);
                sb.AppendLine("updater_path=" + exe);
                sb.AppendLine("updater_sha256=" + (File.Exists(exe) ? Sha256File(exe) : "missing"));
                sb.AppendLine("game_dir=" + root);
                sb.AppendLine("os=" + Environment.OSVersion);
                sb.AppendLine("clr=" + Environment.Version);
                sb.AppendLine("is_64bit_os=" + Environment.Is64BitOperatingSystem);
                sb.AppendLine("is_64bit_process=" + Environment.Is64BitProcess);
                sb.AppendLine("utc=" + DateTime.UtcNow.ToString("o"));
                return sb.ToString();
            }

            private string BuildManagedHashes(string root, Dictionary<string, object> installed)
            {
                var sb = new StringBuilder();
                if (installed == null) return "installed.json missing\r\n";
                foreach (var item in AsArray(GetValue(installed, "managed_files")))
                {
                    var name = Convert.ToString(item);
                    if (string.IsNullOrWhiteSpace(name)) continue;
                    try
                    {
                        var path = SafeDestination(root, name);
                        if (!File.Exists(path)) sb.AppendLine(name + "\tMISSING");
                        else sb.AppendLine(name + "\t" + new FileInfo(path).Length + "\t" + Sha256File(path));
                    }
                    catch (Exception ex)
                    {
                        sb.AppendLine(name + "\tERROR\t" + ex.Message);
                    }
                }
                return sb.ToString();
            }

            private static string BuildBackupIndex(string root)
            {
                var backupRoot = Path.Combine(root, ".wow112_parallel_updater", "backups");
                if (!Directory.Exists(backupRoot)) return "no backups\r\n";
                return string.Join("\r\n", Directory.GetDirectories(backupRoot).OrderByDescending(x => x, StringComparer.OrdinalIgnoreCase).Select(Path.GetFileName).ToArray()) + "\r\n";
            }

            private static void AddText(ZipArchive zip, string name, string text)
            {
                var entry = zip.CreateEntry(name, CompressionLevel.Optimal);
                using (var stream = entry.Open())
                using (var writer = new StreamWriter(stream, new UTF8Encoding(false))) writer.Write(text ?? string.Empty);
            }

            private static void AddFile(ZipArchive zip, string path, string name)
            {
                var entry = zip.CreateEntry(name, CompressionLevel.Optimal);
                using (var input = File.OpenRead(path))
                using (var output = entry.Open()) input.CopyTo(output);
            }

            private static bool IsGameRunning(string root)
            {
                var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                foreach (var process in System.Diagnostics.Process.GetProcesses())
                {
                    try
                    {
                        var module = process.MainModule;
                        var file = module == null ? null : module.FileName;
                        var name = Path.GetFileName(file);
                        var isWow = string.Equals(name, "WoW.exe", StringComparison.OrdinalIgnoreCase)
                            || (!string.IsNullOrWhiteSpace(name) && name.StartsWith("WoW_", StringComparison.OrdinalIgnoreCase) && name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase));
                        if (isWow && !string.IsNullOrWhiteSpace(file) && Path.GetFullPath(file).StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase)) return true;
                    }
                    catch { }
                    finally { process.Dispose(); }
                }
                return false;
            }

            private static void ReplaceFile(string temp, string destination)
            {
                UpdaterSafety.ReplaceFile(temp, destination, ".wow112repairreplace");
            }

            private static string SafeDestination(string root, string name)
            {
                if (string.IsNullOrWhiteSpace(name) || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || Path.GetFileName(name) != name)
                    throw new InvalidOperationException("Nieprawidłowa nazwa pliku: " + name);
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

            private static string QuoteArg(string value)
            {
                return "\"" + (value ?? string.Empty).Replace("\"", "\\\"") + "\"";
            }

            private static string TrimForError(string text)
            {
                if (string.IsNullOrWhiteSpace(text)) return "brak treści odpowiedzi";
                text = text.Replace("\r", " ").Replace("\n", " ").Trim();
                return text.Length <= 240 ? text : text.Substring(0, 240) + "...";
            }

            private static Dictionary<string, object> AsDictionary(object value)
            {
                var dict = value as Dictionary<string, object>;
                if (dict == null) throw new InvalidOperationException("Nieoczekiwany JSON.");
                return dict;
            }

            private static object[] AsArray(object value)
            {
                if (value == null) return new object[0];
                var array = value as object[];
                if (array != null) return array;
                var list = value as ArrayList;
                return list == null ? new object[0] : list.ToArray();
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
                return value == null ? 0L : Convert.ToInt64(value);
            }

            private static bool GetBool(Dictionary<string, object> dict, string key)
            {
                var value = GetValue(dict, key);
                return value != null && Convert.ToBoolean(value);
            }

            private void Log(string message)
            {
                host.LogMessage(message);
            }

            private void TrimBackups(string root, int keep)
            {
                try
                {
                    var backupRoot = Path.Combine(root, ".wow112_parallel_updater", "backups");
                    if (!Directory.Exists(backupRoot)) return;
                    foreach (var dir in Directory.GetDirectories(backupRoot).OrderByDescending(x => x, StringComparer.OrdinalIgnoreCase).Skip(Math.Max(keep, 1)))
                        Directory.Delete(dir, true);
                }
                catch (Exception ex) { Log("Ostrzeżenie backup cleanup: " + ex.Message); }
            }

            private sealed class ExpectedFile
            {
                public readonly string Name;
                public readonly byte[] Bytes;
                public readonly string Sha256;
                public ExpectedFile(string name, byte[] bytes)
                {
                    Name = name;
                    Bytes = bytes;
                    Sha256 = MaintenanceController.Sha256(bytes);
                }
            }

            private sealed class ComparisonResult
            {
                public readonly List<string> BadExpected = new List<string>();
                public readonly List<string> StaleManaged = new List<string>();
            }

            private sealed class RemoteUpdaterBuild
            {
                public string Version;
                public string UpdaterSha;
                public string BootstrapSha;
                public byte[] UpdaterBytes;
                public byte[] BootstrapBytes;
            }
        }
    }
}

