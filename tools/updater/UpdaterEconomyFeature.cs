using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        private const string EconomyWorkflowFile = "build_parallel_economy.yml";
        private int lastEconomyAddonChangeCount;
        private string cachedEconomyFingerprint = string.Empty;
        private bool economyPendingBusy;
        private bool economyPendingFaulted;

        private static string EconomyStatePath(string root) { return Path.Combine(root, ".wow112_parallel_updater", "economy_installed.json"); }
        private static string EconomyPendingRoot(string root) { return Path.Combine(root, ".wow112_parallel_updater", "economy_pending"); }
        private static string EconomyPendingManifestPath(string root) { return Path.Combine(EconomyPendingRoot(root), "pending.json"); }

        private async Task<Dictionary<string, object>> WaitForCurrentHeadEconomyRunAsync(HttpClient client, string branch)
        {
            var deadlineUtc = DateTime.UtcNow.AddMinutes(3);
            var trackedHead = string.Empty;
            var waitingRunId = 0L;
            while (true)
            {
                var branchInfo = AsDictionary(json.DeserializeObject(await GetStringAsync(client, ApiRoot + "/branches/" + branch)));
                var currentHead = GetString(AsDictionary(GetValue(branchInfo, "commit")), "sha");
                UpdaterSafety.RequireCurrentParallelHead(currentHead, currentHead);
                if (!string.Equals(trackedHead, currentHead, StringComparison.OrdinalIgnoreCase))
                {
                    trackedHead = currentHead;
                    waitingRunId = 0L;
                }
                var url = ApiRoot + "/actions/workflows/" + EconomyWorkflowFile + "/runs?branch=" + branch + "&per_page=20";
                var root = AsDictionary(json.DeserializeObject(await GetStringAsync(client, url)));
                var runs = AsArray(GetValue(root, "workflow_runs"));
                var exact = UpdaterSafety.FindRunForHead(runs, EconomyWorkflowName, branch, trackedHead);
                if (exact == null)
                {
                    if (DateTime.UtcNow >= deadlineUtc)
                        return UpdaterSafety.RequireSuccessfulRunForHead(runs, EconomyWorkflowName, branch, trackedHead);
                    status.Text = "ECONOMY " + ShortSha(trackedHead) + " • czekam na fast build...";
                    await Task.Delay(2500);
                    continue;
                }
                var state = GetString(exact, "status");
                if (!string.Equals(state, "completed", StringComparison.OrdinalIgnoreCase) && DateTime.UtcNow < deadlineUtc)
                {
                    var runId = GetLong(exact, "id");
                    if (waitingRunId != runId)
                    {
                        waitingRunId = runId;
                        Log("ECONOMY #" + runId + " dla " + ShortSha(trackedHead) + " jest w toku (" + state + ").");
                    }
                    status.Text = "Trwa ECONOMY fast build " + ShortSha(trackedHead) + "...";
                    await Task.Delay(5000);
                    continue;
                }
                return UpdaterSafety.RequireSuccessfulRunForHead(runs, EconomyWorkflowName, branch, trackedHead);
            }
        }

        private void ExtractEconomyPackage(byte[] outerBytes, string innerZipName, string expectedHeadSha, out byte[] innerBytes, out string expectedSha)
        {
            innerBytes = null;
            expectedSha = string.Empty;
            using (var ms = new MemoryStream(outerBytes, false))
            using (var zip = new ZipArchive(ms, ZipArchiveMode.Read, false))
            {
                var inner = zip.Entries.FirstOrDefault(e => string.Equals(Path.GetFileName(e.FullName), innerZipName, StringComparison.OrdinalIgnoreCase));
                var metaEntry = zip.Entries.FirstOrDefault(e => e.FullName == "economy_metadata.json");
                var attestEntry = zip.Entries.FirstOrDefault(e => e.FullName == "economy_attestation.json");
                if (inner == null || metaEntry == null || attestEntry == null)
                    throw new InvalidOperationException("Artifact ECONOMY nie zawiera kompletnego overlayu/metadanych/attestation.");
                innerBytes = ReadEntry(inner);
                var meta = AsDictionary(json.DeserializeObject(Encoding.UTF8.GetString(ReadEntry(metaEntry))));
                var attest = AsDictionary(json.DeserializeObject(Encoding.UTF8.GetString(ReadEntry(attestEntry))));
                expectedSha = GetString(meta, "package_sha256");
                var size = innerBytes.LongLength;
                if (!UpdaterSafety.IsSha256Hex(expectedSha)
                    || !string.Equals(GetString(meta, "profile"), "ECONOMY", StringComparison.Ordinal)
                    || !string.Equals(GetString(meta, "branch"), "parallel", StringComparison.Ordinal)
                    || !string.Equals(GetString(meta, "commit_sha"), expectedHeadSha, StringComparison.OrdinalIgnoreCase)
                    || GetLong(meta, "package_size") != size || !GetBool(meta, "overlay_only") || GetBool(meta, "allow_deletes"))
                    throw new InvalidOperationException("Metadane ECONOMY nie pasują do exact HEAD/overlay contract.");
                if (!string.Equals(GetString(attest, "result"), "PASS", StringComparison.Ordinal)
                    || !string.Equals(GetString(attest, "profile"), "ECONOMY", StringComparison.Ordinal)
                    || !string.Equals(GetString(attest, "commit_sha"), expectedHeadSha, StringComparison.OrdinalIgnoreCase)
                    || !string.Equals(GetString(attest, "package_sha256"), expectedSha, StringComparison.OrdinalIgnoreCase)
                    || GetLong(attest, "package_size") != size || !GetBool(attest, "overlay_only") || GetBool(attest, "allow_deletes")
                    || !GetBool(attest, "all_native_pe32_x86")
                    || !string.Equals(GetString(attest, "delivery_status"), "READY_FOR_GAME_TEST", StringComparison.Ordinal))
                    throw new InvalidOperationException("Attestation ECONOMY jest niepełne albo niezgodne.");
            }
        }

        private EconomyOverlay ReadEconomyOverlay(byte[] packageBytes, string expectedHeadSha)
        {
            var result = new EconomyOverlay();
            using (var ms = new MemoryStream(packageBytes, false))
            using (var zip = new ZipArchive(ms, ZipArchiveMode.Read, false))
            {
                var manifestEntry = zip.Entries.FirstOrDefault(e => e.FullName == "economy_manifest.json");
                if (manifestEntry == null) throw new InvalidOperationException("ECONOMY overlay nie zawiera economy_manifest.json.");
                var manifest = AsDictionary(json.DeserializeObject(Encoding.UTF8.GetString(ReadEntry(manifestEntry))));
                if (GetLong(manifest, "schema_version") != 1
                    || !string.Equals(GetString(manifest, "profile"), "ECONOMY", StringComparison.Ordinal)
                    || !string.Equals(GetString(manifest, "branch"), "parallel", StringComparison.Ordinal)
                    || !string.Equals(GetString(manifest, "commit_sha"), expectedHeadSha, StringComparison.OrdinalIgnoreCase)
                    || !GetBool(manifest, "overlay_only") || GetBool(manifest, "allow_deletes"))
                    throw new InvalidOperationException("Nieprawidłowy manifest ECONOMY overlay.");
                result.Fingerprint = GetString(manifest, "profile_fingerprint");
                if (!UpdaterSafety.IsSha256Hex(result.Fingerprint)) throw new InvalidOperationException("ECONOMY fingerprint jest nieprawidłowy.");
                foreach (var value in AsArray(GetValue(manifest, "required_loader_order")))
                {
                    var name = Convert.ToString(value);
                    if (string.IsNullOrWhiteSpace(name) || Path.GetFileName(name) != name || !name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("Nieprawidłowy wymagany DLL w ECONOMY.");
                    result.RequiredLoaderOrder.Add(name);
                }
                if (result.RequiredLoaderOrder.Count != 3) throw new InvalidOperationException("ECONOMY wymaga dokładnie trzech DLL.");

                var declared = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var value in AsArray(GetValue(manifest, "files")))
                {
                    var row = AsDictionary(value);
                    var name = GetString(row, "name");
                    var kind = GetString(row, "kind");
                    var expected = GetString(row, "sha256");
                    var expectedSize = GetLong(row, "size");
                    if (!UpdaterSafety.IsSha256Hex(expected) || expectedSize <= 0 || !declared.Add(name))
                        throw new InvalidOperationException("Nieprawidłowy/duplikowany wpis pliku ECONOMY: " + name);
                    if (kind == "dll")
                    {
                        if (Path.GetFileName(name) != name || !name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
                            throw new InvalidOperationException("Nieprawidłowa ścieżka DLL ECONOMY: " + name);
                    }
                    else if (kind == "addon")
                    {
                        if (!UpdaterAddons.IsAddonPath(name)) throw new InvalidOperationException("Nieprawidłowa ścieżka AddOn ECONOMY: " + name);
                    }
                    else throw new InvalidOperationException("Nieznany typ pliku ECONOMY: " + kind);

                    var entry = zip.Entries.FirstOrDefault(e => string.Equals(e.FullName, name, StringComparison.Ordinal));
                    if (entry == null) throw new InvalidOperationException("Brak pliku ECONOMY: " + name);
                    var bytes = ReadEntry(entry);
                    if (bytes.LongLength != expectedSize || !string.Equals(Sha256(bytes), expected, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("SHA/rozmiar ECONOMY nie zgadza się: " + name);
                    result.Files.Add(new PackageFile(name, bytes));
                }
                var actualAssets = zip.Entries.Where(e => e.FullName != "economy_manifest.json" && !string.IsNullOrEmpty(e.Name)).Select(e => e.FullName).ToArray();
                if (actualAssets.Length != declared.Count || actualAssets.Any(x => !declared.Contains(x)))
                    throw new InvalidOperationException("ECONOMY ZIP zawiera pliki spoza manifestu.");
                var dlls = result.Files.Where(x => x.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)).Select(x => x.Name).ToList();
                if (!dlls.SequenceEqual(result.RequiredLoaderOrder, StringComparer.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Kolejność DLL ECONOMY w paczce nie zgadza się z kontraktem.");
            }
            return result;
        }

        private void ValidateEconomyLocalLoader(string root, IList<string> required)
        {
            var path = Path.Combine(root, "dlls.txt");
            if (!File.Exists(path)) throw new InvalidOperationException("ECONOMY wymaga wcześniej zainstalowanego STANDARD z dlls.txt.");
            var local = File.ReadAllLines(path).Select(x => x.Trim()).Where(x => x.Length > 0).ToList();
            var last = -1;
            foreach (var name in required)
            {
                var idx = local.FindIndex(x => string.Equals(x, name, StringComparison.OrdinalIgnoreCase));
                if (idx < 0 || idx <= last || !File.Exists(SafeDestination(root, name)))
                    throw new InvalidOperationException("STANDARD nie spełnia kontraktu ECONOMY (brak/kolejność DLL): " + name + ". Zaktualizuj najpierw STANDARD.");
                if (IsDllInstallDisabled(name)) throw new InvalidOperationException("Wymagany DLL ECONOMY jest wyłączony: " + name + ".");
                last = idx;
            }
        }

        private void InspectEconomyOverlay(byte[] packageBytes, string root, string expectedHeadSha)
        {
            lastDllInspection.Clear();
            lastExeInspection = null;
            lastEconomyAddonChangeCount = 0;
            var overlay = ReadEconomyOverlay(packageBytes, expectedHeadSha);
            cachedEconomyFingerprint = overlay.Fingerprint;
            ValidateEconomyLocalLoader(root, overlay.RequiredLoaderOrder);
            foreach (var file in overlay.Files)
            {
                var path = SafeDestination(root, file.Name);
                var localSha = File.Exists(path) ? Sha256File(path) : string.Empty;
                var changed = !string.Equals(localSha, file.Sha256, StringComparison.OrdinalIgnoreCase);
                if (file.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
                {
                    var state = string.IsNullOrEmpty(localSha) ? "BRAK LOKALNIE" : changed ? "AKTUALIZACJA" : "AKTUALNA";
                    lastDllInspection.Add(new DllUpdateStatus(file.Name, state, changed, localSha, file.Sha256, false));
                }
                else if (changed) lastEconomyAddonChangeCount++;
            }
        }

        private ApplyResult ApplyEconomyOverlay(byte[] packageBytes, RemotePackageInfo remote, string root)
        {
            var overlay = ReadEconomyOverlay(packageBytes, remote.HeadSha);
            ValidateEconomyLocalLoader(root, overlay.RequiredLoaderOrder);
            var changed = new List<PackageFile>();
            foreach (var file in overlay.Files)
            {
                var dest = SafeDestination(root, file.Name);
                if (!File.Exists(dest) || !string.Equals(Sha256File(dest), file.Sha256, StringComparison.OrdinalIgnoreCase))
                {
                    if (file.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) && !IsDllUpdateEnabled(file.Name))
                        throw new InvalidOperationException("ECONOMY wymaga aktualizacji DLL, ale jego przełącznik jest wyłączony: " + file.Name + ".");
                    changed.Add(file);
                }
            }
            if (changed.Count == 0)
            {
                WriteEconomyState(root, remote, overlay, packageBytes);
                ClearEconomyPending(root);
                return new ApplyResult { Changed = 0, Deferred = 0, Unchanged = overlay.Files.Count, ExeChanged = false, BackupDir = string.Empty };
            }

            var backupDir = CreateBackup(root, changed.Select(x => x.Name).ToList(), ReadInstalledState(root), remote);
            var gameRunning = IsGameRunning(root);
            var immediate = new List<PackageFile>();
            var deferred = new List<PackageFile>();
            try
            {
                foreach (var file in changed)
                {
                    if (UpdaterAddons.IsAddonPath(file.Name) || !gameRunning)
                    {
                        ApplyChangedFiles(root, new[] { file });
                        immediate.Add(file);
                    }
                    else if (TryApplyChangedFileLive(root, file)) immediate.Add(file);
                    else deferred.Add(file);
                }
                if (deferred.Count > 0) StageEconomyPending(root, remote, overlay, packageBytes, deferred);
                else
                {
                    WriteEconomyState(root, remote, overlay, packageBytes);
                    ClearEconomyPending(root);
                }
            }
            catch
            {
                if (!string.IsNullOrWhiteSpace(backupDir)) RestoreBackupDirectory(root, backupDir, false);
                throw;
            }
            return new ApplyResult { Changed = immediate.Count, Deferred = deferred.Count, Unchanged = overlay.Files.Count - changed.Count, ExeChanged = false, BackupDir = backupDir };
        }

        private void WriteEconomyState(string root, RemotePackageInfo remote, EconomyOverlay overlay, byte[] packageBytes)
        {
            var state = new Dictionary<string, object>();
            state["schema_version"] = 1; state["profile"] = "ECONOMY"; state["channel"] = "parallel";
            state["run_id"] = remote.RunId; state["head_sha"] = remote.HeadSha; state["artifact_name"] = remote.ArtifactName;
            state["package_sha256"] = Sha256(packageBytes); state["profile_fingerprint"] = overlay.Fingerprint;
            state["installed_utc"] = DateTime.UtcNow.ToString("o"); state["managed_files"] = overlay.Files.Select(x => x.Name).ToArray();
            UpdaterSafety.WriteUtf8Atomic(EconomyStatePath(root), json.Serialize(state), ".tmp", ".previous");
        }

        private void StageEconomyPending(string root, RemotePackageInfo remote, EconomyOverlay overlay, byte[] packageBytes, IList<PackageFile> deferred)
        {
            var pendingRoot = EconomyPendingRoot(root);
            var stage = pendingRoot + ".stage-" + Guid.NewGuid().ToString("N");
            var filesRoot = Path.Combine(stage, "files");
            Directory.CreateDirectory(filesRoot);
            try
            {
                var deferredRows = new ArrayList();
                foreach (var file in deferred)
                {
                    if (Path.GetFileName(file.Name) != file.Name) throw new InvalidOperationException("ECONOMY pending przyjmuje tylko root DLL.");
                    File.WriteAllBytes(Path.Combine(filesRoot, file.Name), file.Bytes);
                    var row = new Dictionary<string, object>(); row["name"] = file.Name; row["sha256"] = file.Sha256; row["size"] = file.Bytes.LongLength;
                    deferredRows.Add(row);
                }
                var allRows = new ArrayList();
                foreach (var file in overlay.Files)
                {
                    var row = new Dictionary<string, object>(); row["name"] = file.Name; row["sha256"] = file.Sha256; row["size"] = file.Bytes.LongLength;
                    allRows.Add(row);
                }
                var pending = new Dictionary<string, object>();
                pending["schema_version"] = 1; pending["profile"] = "ECONOMY"; pending["run_id"] = remote.RunId; pending["head_sha"] = remote.HeadSha;
                pending["artifact_name"] = remote.ArtifactName; pending["package_sha256"] = Sha256(packageBytes); pending["profile_fingerprint"] = overlay.Fingerprint;
                pending["deferred"] = deferredRows; pending["files"] = allRows; pending["required_loader_order"] = overlay.RequiredLoaderOrder.ToArray();
                UpdaterSafety.WriteUtf8Atomic(Path.Combine(stage, "pending.json"), json.Serialize(pending), ".tmp", ".previous");
                if (Directory.Exists(pendingRoot)) Directory.Delete(pendingRoot, true);
                Directory.Move(stage, pendingRoot);
                economyPendingFaulted = false;
                Log("ECONOMY: " + deferred.Count + " DLL oczekuje na zamknięcie WoW; AddOny/odblokowane pliki są już zaktualizowane.");
            }
            catch
            {
                if (Directory.Exists(stage)) Directory.Delete(stage, true);
                throw;
            }
        }

        private void TryFinalizeEconomyPendingUpdate()
        {
            if (busy || economyPendingBusy || economyPendingFaulted) return;
            var root = gameDir.Text.Trim();
            if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root) || IsGameRunning(root)) return;
            var manifestPath = EconomyPendingManifestPath(root);
            if (!File.Exists(manifestPath)) return;
            economyPendingBusy = true;
            SetBusy(true, "Dokańczanie ECONOMY overlay...");
            try
            {
                var manifest = AsDictionary(json.DeserializeObject(File.ReadAllText(manifestPath, Encoding.UTF8)));
                if (GetLong(manifest, "schema_version") != 1 || !string.Equals(GetString(manifest, "profile"), "ECONOMY", StringComparison.Ordinal))
                    throw new InvalidOperationException("Nieprawidłowy pending ECONOMY.");
                var required = AsArray(GetValue(manifest, "required_loader_order")).Select(x => Convert.ToString(x)).ToList();
                ValidateEconomyLocalLoader(root, required);
                var pendingFiles = Path.Combine(EconomyPendingRoot(root), "files");
                foreach (var value in AsArray(GetValue(manifest, "deferred")))
                {
                    var row = AsDictionary(value);
                    var name = GetString(row, "name");
                    var expected = GetString(row, "sha256");
                    var path = Path.Combine(pendingFiles, name);
                    if (Path.GetFileName(name) != name || !File.Exists(path) || !UpdaterSafety.IsSha256Hex(expected))
                        throw new InvalidOperationException("Uszkodzony pending ECONOMY: " + name);
                    var bytes = File.ReadAllBytes(path);
                    if (!string.Equals(Sha256(bytes), expected, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("SHA pending ECONOMY nie zgadza się: " + name);
                    ApplyChangedFiles(root, new[] { new PackageFile(name, bytes) });
                }
                foreach (var value in AsArray(GetValue(manifest, "files")))
                {
                    var row = AsDictionary(value);
                    var name = GetString(row, "name");
                    var expected = GetString(row, "sha256");
                    var dest = SafeDestination(root, name);
                    if (!File.Exists(dest) || !string.Equals(Sha256File(dest), expected, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("ECONOMY final check nie zgadza się: " + name);
                }
                var state = new Dictionary<string, object>();
                state["schema_version"] = 1; state["profile"] = "ECONOMY"; state["channel"] = "parallel";
                state["run_id"] = GetLong(manifest, "run_id"); state["head_sha"] = GetString(manifest, "head_sha"); state["artifact_name"] = GetString(manifest, "artifact_name");
                state["package_sha256"] = GetString(manifest, "package_sha256"); state["profile_fingerprint"] = GetString(manifest, "profile_fingerprint");
                state["installed_utc"] = DateTime.UtcNow.ToString("o");
                state["managed_files"] = AsArray(GetValue(manifest, "files")).Select(x => GetString(AsDictionary(x), "name")).ToArray();
                UpdaterSafety.WriteUtf8Atomic(EconomyStatePath(root), json.Serialize(state), ".tmp", ".previous");
                ClearEconomyPending(root);
                status.Text = "ECONOMY runtime dokończony • " + ShortSha(GetString(state, "head_sha"));
                Log(status.Text);
            }
            catch (Exception ex)
            {
                economyPendingFaulted = true;
                status.Text = "ECONOMY pending wymaga ponowienia — szczegóły w logu.";
                Log("BŁĄD ECONOMY pending: " + ex.Message);
            }
            finally
            {
                economyPendingBusy = false;
                SetBusy(false, status.Text);
                RefreshLocalState();
            }
        }

        private void ClearEconomyPending(string root)
        {
            var path = EconomyPendingRoot(root);
            if (Directory.Exists(path)) Directory.Delete(path, true);
            economyPendingFaulted = false;
        }

        private void ClearEconomyOverlayState(string root)
        {
            try
            {
                var state = EconomyStatePath(root);
                if (File.Exists(state)) File.Delete(state);
                if (File.Exists(state + ".previous")) File.Delete(state + ".previous");
                ClearEconomyPending(root);
            }
            catch (Exception ex) { Log("Ostrzeżenie: nie udało się wyczyścić stanu ECONOMY po pełnej instalacji STANDARD: " + ex.Message); }
        }

        private void AppendEconomyLocalInfo(string root)
        {
            try
            {
                if (File.Exists(EconomyStatePath(root)))
                {
                    var state = AsDictionary(json.DeserializeObject(File.ReadAllText(EconomyStatePath(root), Encoding.UTF8)));
                    localInfo.Text += " • ECONOMY " + ShortSha(GetString(state, "head_sha"));
                }
                if (File.Exists(EconomyPendingManifestPath(root)))
                {
                    var pending = AsDictionary(json.DeserializeObject(File.ReadAllText(EconomyPendingManifestPath(root), Encoding.UTF8)));
                    localInfo.Text += " • ECONOMY OCZEKUJE " + ShortSha(GetString(pending, "head_sha"));
                }
            }
            catch { }
        }

        private sealed class EconomyOverlay
        {
            public readonly List<PackageFile> Files = new List<PackageFile>();
            public readonly List<string> RequiredLoaderOrder = new List<string>();
            public string Fingerprint;
        }
    }
}
