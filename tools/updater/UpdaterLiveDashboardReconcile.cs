using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace WoW112Updater
{
    // Reconciles the compact GitHub dashboard against live refs instead of retaining
    // historical workflow outcomes. It also exposes an exact local file-delta counter
    // for the verified Parallel artifact selected by the updater.
    internal sealed partial class MainForm
    {
        private const int LiveDashboardRefreshSeconds = 30;
        private const int LiveFailureRetentionMinutes = 30;
        private const int LiveReadyRetentionMinutes = 240;

        private readonly Label githubLiveFilesBadge = new Label();
        private readonly Dictionary<string, bool> liveResolvedCache = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        private bool liveDashboardAttached;
        private bool liveDashboardInFlight;
        private bool liveFilesCheckInFlight;
        private DateTime liveDashboardLastUtc = DateTime.MinValue;
        private DateTime liveFilesLastAttemptUtc = DateTime.MinValue;
        private string liveFilesCheckedKey = string.Empty;
        private string liveFilesAttemptedKey = string.Empty;

        private sealed class LiveGateRow
        {
            public string Branch;
            public string Head;
            public string State;
            public string Workflow;
            public long RunId;
            public DateTime UpdatedUtc;
            public bool Promote;
        }

        private sealed class LiveQueueState
        {
            public string ParallelHead;
            public int FailCount;
            public int RunCount;
            public int ReadyCount;
            public int IntegrationReadyCount;
            public string FirstIntegration;
            public readonly List<string> DetailRows = new List<string>();
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            Shown += delegate
            {
                // UpdaterReadyQueueBar attaches after base.OnShown(). Queue this so the
                // fourth row is added after that three-row layout is complete.
                if (IsDisposed) return;
                BeginInvoke(new Action(AttachLiveDashboardReconcile));
            };
        }

        private void AttachLiveDashboardReconcile()
        {
            if (liveDashboardAttached || githubPipelineBadge == null || githubPipelineBadge.IsDisposed) return;
            var grid = githubPipelineBadge.Parent as TableLayoutPanel;
            if (grid == null) return;

            liveDashboardAttached = true;
            grid.RowCount = 4;
            grid.RowStyles.Clear();
            for (var i = 0; i < 4; i++) grid.RowStyles.Add(new RowStyle(SizeType.Percent, 25F));

            PrepareLabel(githubLiveFilesBadge);
            githubLiveFilesBadge.Name = "githubLiveFilesBadge";
            githubLiveFilesBadge.AccessibleName = "Live update files ready";
            githubLiveFilesBadge.Font = new Font("Segoe UI", 8.4F, FontStyle.Bold);
            githubLiveFilesBadge.Margin = new Padding(3, 1, 3, 1);
            githubLiveFilesBadge.Padding = new Padding(6, 0, 3, 0);
            githubLiveFilesBadge.TextAlign = ContentAlignment.MiddleLeft;
            githubLiveFilesBadge.AutoEllipsis = true;
            grid.Controls.Add(githubLiveFilesBadge, 0, 3);

            SetLiveFilesVisual(
                Color.FromArgb(45, 49, 58), Muted,
                "LIVE UPDATE   PLIKI: SPRAWDZAM...",
                "Belka pokaże liczbę plików z aktualnego zweryfikowanego PARALLEL, które faktycznie różnią się od wybranego katalogu gry.");

            githubMonitorButton.TextChanged += async delegate
            {
                if (!liveDashboardAttached || IsDisposed) return;
                if (githubMonitorButton.Text.IndexOf("sprawdzam", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    SetReadyQueueVisual(
                        Color.FromArgb(45, 49, 58), Muted,
                        "DOSTAWA DO GRY   ODŚWIEŻAM STAN LIVE...",
                        "Poprzednie liczniki są chwilowo ukryte, aby historyczny wynik nie udawał aktualnego stanu.");
                }
                await ScheduleLiveDashboardRefreshAsync(false);
            };
            channel.SelectedIndexChanged += async delegate
            {
                InvalidateLiveFilesCache();
                await ScheduleLiveDashboardRefreshAsync(true);
            };
            gameDir.TextChanged += async delegate
            {
                InvalidateLiveFilesCache();
                await ScheduleLiveDashboardRefreshAsync(true);
            };
            status.TextChanged += delegate { RefreshLiveFilesFromCache(); };

            if (!Array.Exists(Environment.GetCommandLineArgs(), a => a == "--ui-smoke"))
                _ = ScheduleLiveDashboardRefreshAsync(true);
        }

        private void InvalidateLiveFilesCache()
        {
            liveFilesCheckedKey = string.Empty;
            liveFilesAttemptedKey = string.Empty;
            liveFilesLastAttemptUtc = DateTime.MinValue;
        }

        private async Task ScheduleLiveDashboardRefreshAsync(bool force)
        {
            await Task.Delay(180);
            if (!liveDashboardAttached || IsDisposed || liveDashboardInFlight) return;
            if (githubMonitorButton.Text.IndexOf("sprawdzam", StringComparison.OrdinalIgnoreCase) >= 0) return;
            if (!force && DateTime.UtcNow - liveDashboardLastUtc < TimeSpan.FromSeconds(LiveDashboardRefreshSeconds))
            {
                RefreshLiveFilesFromCache();
                return;
            }
            await RefreshLiveDashboardAsync();
        }

        private async Task RefreshLiveDashboardAsync()
        {
            if (liveDashboardInFlight) return;
            liveDashboardInFlight = true;
            try
            {
                if (token == null || string.IsNullOrWhiteSpace(token.Text))
                {
                    SetGitHubPipelineBadge("IDLE", "GH LIVE   BRAK TOKENU", "Brak tokenu GitHub — stan live nie może zostać uznany za aktualny.");
                    SetReadyQueueVisual(Color.FromArgb(45, 49, 58), Muted,
                        "DOSTAWA DO GRY   BRAK DANYCH LIVE",
                        "Wpisz token GitHub, aby dashboard mógł zweryfikować bieżące refy i workflow.");
                    SetLiveFilesVisual(Color.FromArgb(45, 49, 58), Muted,
                        "LIVE UPDATE   PLIKI: BRAK DANYCH",
                        "Bez tokenu nie można ustalić zweryfikowanego artefaktu bieżącego PARALLEL.");
                    return;
                }

                using (var client = CreateClient())
                {
                    client.Timeout = TimeSpan.FromSeconds(25);
                    var parallelJson = await GetStringAsync(client, ApiRoot + "/branches/parallel");
                    var parallelRoot = AsDictionary(json.DeserializeObject(parallelJson));
                    var parallelHead = GetString(AsDictionary(GetValue(parallelRoot, "commit")), "sha");
                    if (string.IsNullOrWhiteSpace(parallelHead))
                        throw new InvalidOperationException("GH LIVE: brak HEAD parallel.");

                    var allRunsJson = await GetStringAsync(client, ApiRoot + "/actions/runs?per_page=100");
                    var parallelRunsJson = await GetStringAsync(client, ApiRoot + "/actions/runs?branch=parallel&per_page=50");
                    var live = await BuildLiveQueueStateAsync(client, parallelHead, allRunsJson);
                    ApplyLivePipelineVisual(live);

                    var workflow = IsEconomy() ? EconomyWorkflowName : TestWorkflowName;
                    var buildState = MonitorExactWorkflowState(parallelRunsJson, workflow, "parallel", parallelHead);
                    ApplyLiveDeliveryVisual(live, parallelHead, buildState);
                    await RefreshLiveFilesForHeadAsync(parallelHead, buildState);
                }
            }
            catch (Exception ex)
            {
                // Never retain an old red/yellow count after a failed refresh. Unknown is
                // safer and materially different from pretending the previous snapshot is live.
                SetGitHubPipelineBadge("IDLE", "GH LIVE   STAN NIEZNANY", "Błąd świeżego odczytu GitHub: " + ex.Message);
                SetReadyQueueVisual(Color.FromArgb(45, 49, 58), Color.FromArgb(255, 199, 128),
                    "DOSTAWA DO GRY   STAN NIEZNANY — ODCZYT LIVE NIEUDANY",
                    "Stare liczniki zostały wyczyszczone. Błąd świeżego odczytu: " + ex.Message);
                if (!liveFilesCheckInFlight)
                    SetLiveFilesVisual(Color.FromArgb(45, 49, 58), Color.FromArgb(255, 199, 128),
                        "LIVE UPDATE   PLIKI: STAN NIEZNANY",
                        "Nie udało się potwierdzić aktualnego artefaktu: " + ex.Message);
            }
            finally
            {
                liveDashboardLastUtc = DateTime.UtcNow;
                liveDashboardInFlight = false;
            }
        }

        private async Task<LiveQueueState> BuildLiveQueueStateAsync(HttpClient client, string parallelHead, string runsJson)
        {
            var state = new LiveQueueState { ParallelHead = parallelHead };
            var root = AsDictionary(json.DeserializeObject(runsJson));
            var newestByBranch = new Dictionary<string, LiveGateRow>(StringComparer.OrdinalIgnoreCase);
            var now = DateTime.UtcNow;

            foreach (var item in AsArray(GetValue(root, "workflow_runs")))
            {
                var run = item as Dictionary<string, object>;
                if (run == null) continue;
                var workflow = GetString(run, "name");
                var branch = GetString(run, "head_branch");
                var feature = branch.StartsWith("feature/", StringComparison.OrdinalIgnoreCase)
                    && string.Equals(workflow, "Parallel feature preflight", StringComparison.Ordinal);
                var promote = branch.StartsWith("promote/", StringComparison.OrdinalIgnoreCase)
                    && string.Equals(workflow, "Pre-promote stable", StringComparison.Ordinal);
                if (!feature && !promote) continue;
                if (newestByBranch.ContainsKey(branch)) continue;

                DateTime updatedUtc;
                if (!DateTime.TryParse(GetString(run, "updated_at"), CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out updatedUtc))
                    updatedUtc = now;

                var statusText = GetString(run, "status");
                var conclusion = GetString(run, "conclusion");
                var completed = string.Equals(statusText, "completed", StringComparison.OrdinalIgnoreCase);
                var liveState = !completed
                    ? "RUN"
                    : IsFailedConclusion(conclusion) ? "FAIL"
                    : string.Equals(conclusion, "success", StringComparison.OrdinalIgnoreCase) ? "READY" : "OTHER";

                // GH LIVE is an operational view, not an archive. Completed failures age
                // out quickly; a successful but genuinely unintegrated feature stays visible
                // much longer. Integration itself clears it immediately below.
                var age = now - updatedUtc;
                if (liveState == "FAIL" && age > TimeSpan.FromMinutes(LiveFailureRetentionMinutes)) continue;
                if (liveState == "READY" && age > TimeSpan.FromMinutes(LiveReadyRetentionMinutes)) continue;
                if (liveState == "OTHER") continue;

                newestByBranch[branch] = new LiveGateRow
                {
                    Branch = branch,
                    Head = GetString(run, "head_sha"),
                    State = liveState,
                    Workflow = workflow,
                    RunId = GetLong(run, "id"),
                    UpdatedUtc = updatedUtc,
                    Promote = promote
                };
            }

            foreach (var pair in newestByBranch)
            {
                var row = pair.Value;
                if (string.IsNullOrWhiteSpace(row.Head)) continue;
                try
                {
                    var branchJson = await GetStringAsync(client, ApiRoot + "/branches/" + Uri.EscapeDataString(row.Branch));
                    var branchRoot = AsDictionary(json.DeserializeObject(branchJson));
                    var currentHead = GetString(AsDictionary(GetValue(branchRoot, "commit")), "sha");
                    if (!string.Equals(currentHead, row.Head, StringComparison.OrdinalIgnoreCase))
                        continue; // superseded run; wait for the gate of the new exact HEAD

                    if (!row.Promote && await LiveFeatureResolvedAsync(client, row.Head, parallelHead))
                        continue; // already integrated, including one metadata-only tail commit

                    if (row.State == "FAIL") state.FailCount++;
                    else if (row.State == "RUN") state.RunCount++;
                    else if (row.State == "READY")
                    {
                        state.ReadyCount++;
                        if (!row.Promote)
                        {
                            state.IntegrationReadyCount++;
                            if (string.IsNullOrWhiteSpace(state.FirstIntegration)) state.FirstIntegration = row.Branch;
                        }
                    }

                    if (state.DetailRows.Count < 14)
                        state.DetailRows.Add(row.State + "  " + row.Branch + "  " + MonitorShort(row.Head, 10) + "  run " + row.RunId);
                }
                catch
                {
                    // Deleted/unreadable refs are not current actionable items. The next
                    // 30-second snapshot can pick them up again if they become readable.
                }
            }
            return state;
        }

        private async Task<bool> LiveFeatureResolvedAsync(HttpClient client, string featureHead, string parallelHead)
        {
            var cacheKey = featureHead + ">" + parallelHead;
            bool cached;
            if (liveResolvedCache.TryGetValue(cacheKey, out cached)) return cached;

            var resolved = false;
            try
            {
                var compare = await GetStringAsync(client, ApiRoot + "/compare/" + featureHead + "..." + parallelHead);
                resolved = MonitorFeatureIsIntegrated(compare, featureHead);
                if (!resolved)
                {
                    // Integration queue can append a branch-local lease/task bookkeeping
                    // commit after the actual payload commit was merged. Treat exactly one
                    // metadata-only tail as resolved when its parent is already in Parallel.
                    var commitJson = await GetStringAsync(client, ApiRoot + "/commits/" + featureHead);
                    var commit = AsDictionary(json.DeserializeObject(commitJson));
                    var files = AsArray(GetValue(commit, "files"));
                    var metadataOnly = files.Length > 0;
                    foreach (var item in files)
                    {
                        var file = item as Dictionary<string, object>;
                        var name = file == null ? string.Empty : GetString(file, "filename");
                        if (!IsLiveDashboardMetadataPath(name))
                        {
                            metadataOnly = false;
                            break;
                        }
                    }
                    var parents = AsArray(GetValue(commit, "parents"));
                    if (metadataOnly && parents.Length > 0)
                    {
                        var parent = GetString(AsDictionary(parents[0]), "sha");
                        if (!string.IsNullOrWhiteSpace(parent))
                        {
                            var parentCompare = await GetStringAsync(client, ApiRoot + "/compare/" + parent + "..." + parallelHead);
                            resolved = MonitorFeatureIsIntegrated(parentCompare, parent);
                        }
                    }
                }
            }
            catch
            {
                resolved = false;
            }
            liveResolvedCache[cacheKey] = resolved;
            return resolved;
        }

        private static bool IsLiveDashboardMetadataPath(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return false;
            return path.StartsWith("runtime/parallel_tasks/", StringComparison.OrdinalIgnoreCase)
                || string.Equals(path, "runtime/ai_experiments.json", StringComparison.OrdinalIgnoreCase)
                || string.Equals(path, "runtime/parallel_candidate.json", StringComparison.OrdinalIgnoreCase)
                || string.Equals(path, "runtime/parallel_dependency_registry.json", StringComparison.OrdinalIgnoreCase);
        }

        private void ApplyLivePipelineVisual(LiveQueueState state)
        {
            var visualState = state.FailCount > 0 ? "FAIL"
                : state.RunCount > 0 ? "RUNNING"
                : state.ReadyCount > 0 ? "VERIFIED"
                : "IDLE";
            var text = "GH LIVE   FAIL " + state.FailCount + " | RUN " + state.RunCount + " | READY " + state.ReadyCount;
            var detail = new StringBuilder();
            detail.AppendLine("Tylko aktualne HEAD-y feature/promote. Zintegrowane i superseded refy są usuwane z widoku dynamicznie.");
            detail.AppendLine("FAIL znika po integracji/supersede albo po " + LiveFailureRetentionMinutes + " min jako historia; READY po integracji albo po " + LiveReadyRetentionMinutes + " min.");
            if (state.DetailRows.Count == 0) detail.Append("Brak bieżących pozycji.");
            else foreach (var row in state.DetailRows) detail.AppendLine(row);
            SetGitHubPipelineBadge(visualState, text, detail.ToString().TrimEnd());
        }

        private void ApplyLiveDeliveryVisual(LiveQueueState live, string parallelHead, string buildState)
        {
            var profile = ReadyQueueProfileName();
            var shortHead = MonitorShort(parallelHead, 8);
            var standardOrEconomy = !IsAngleOnly() && !IsAutoRear();
            var installed = standardOrEconomy && MonitorSelectedDeliveryInstalled(parallelHead);

            if (string.Equals(buildState, "READY", StringComparison.OrdinalIgnoreCase) && !installed)
            {
                SetReadyQueueVisual(
                    Color.FromArgb(34, 67, 112), Color.FromArgb(174, 211, 255),
                    "DOSTAWA DO GRY   GOTOWE DO UPDATE   " + profile + "   " + shortHead +
                        (live.IntegrationReadyCount > 0 ? "   | +" + live.IntegrationReadyCount + " CZEKA→PARALLEL" : string.Empty),
                    "Aktualny PARALLEL ma zweryfikowany build profilu " + profile + ". Stan jest liczony z bieżącego HEAD, nie z historycznych workflow.");
                return;
            }

            if (live.IntegrationReadyCount > 0)
            {
                SetReadyQueueVisual(
                    Color.FromArgb(96, 74, 31), Color.FromArgb(255, 217, 128),
                    "DOSTAWA DO GRY   CZEKA NA INTEGRACJĘ   " + live.IntegrationReadyCount +
                        (string.IsNullOrWhiteSpace(live.FirstIntegration) ? string.Empty : "   |   → PARALLEL " + ReadyQueueCompact(live.FirstIntegration)),
                    "Pokazywane są wyłącznie niezintegrowane feature z PREFLIGHT PASS na ich aktualnym HEAD. Po integracji pozycja znika automatycznie.");
                return;
            }

            if (installed)
            {
                SetReadyQueueVisual(
                    Color.FromArgb(32, 77, 50), Color.FromArgb(164, 245, 181),
                    "DOSTAWA DO GRY   ZAINSTALOWANE / GOTOWE DO TESTU   " + profile + "   " + shortHead,
                    "Lokalny stan profilu odpowiada dokładnie aktualnemu PARALLEL " + parallelHead + ".");
                return;
            }

            if (string.Equals(buildState, "BUILDING", StringComparison.OrdinalIgnoreCase))
            {
                SetReadyQueueVisual(
                    Color.FromArgb(61, 65, 78), Color.FromArgb(210, 216, 232),
                    "DOSTAWA DO GRY   BUILD W TOKU   " + profile + "   " + shortHead,
                    "Aktualny HEAD Parallel jeszcze buduje profil " + profile + ". Stary artefakt nie jest pokazywany jako gotowy.");
                return;
            }

            if (string.Equals(buildState, "FAIL", StringComparison.OrdinalIgnoreCase))
            {
                SetReadyQueueVisual(
                    Color.FromArgb(91, 45, 45), Color.FromArgb(255, 176, 176),
                    "DOSTAWA DO GRY   BUILD FAIL   " + profile + "   " + shortHead,
                    "Build bieżącego HEAD Parallel dla profilu " + profile + " zakończył się błędem.");
                return;
            }

            SetReadyQueueVisual(
                Color.FromArgb(45, 49, 58), Muted,
                "DOSTAWA DO GRY   BRAK GOTOWYCH ZMIAN   " + profile + "   " + shortHead,
                "Brak aktualnego feature czekającego na integrację i brak potwierdzonego nowego artefaktu do lokalnej aktualizacji.");
        }

        private async Task RefreshLiveFilesForHeadAsync(string parallelHead, string buildState)
        {
            if (!liveDashboardAttached || githubLiveFilesBadge.IsDisposed) return;
            var root = gameDir == null ? string.Empty : gameDir.Text.Trim();
            if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
            {
                SetLiveFilesVisual(Color.FromArgb(45, 49, 58), Muted,
                    "LIVE UPDATE   PLIKI: WYBIERZ KATALOG GRY",
                    "Licznik jest różnicą SHA256 między zweryfikowanym artefaktem a wybranym katalogiem gry.");
                return;
            }

            if (!string.Equals(buildState, "READY", StringComparison.OrdinalIgnoreCase))
            {
                SetLiveFilesVisual(Color.FromArgb(45, 49, 58), Muted,
                    "LIVE UPDATE   PLIKI: CZEKA NA BUILD   " + MonitorShort(parallelHead, 8),
                    "Licznik nie używa poprzedniego artefaktu. Czeka na zweryfikowany build dokładnego HEAD Parallel.");
                return;
            }

            var key = ReadyQueueProfileName() + "|" + parallelHead + "|" + Path.GetFullPath(root).ToLowerInvariant();
            if (string.Equals(liveFilesCheckedKey, key, StringComparison.Ordinal))
            {
                RefreshLiveFilesFromCache();
                return;
            }

            if (busy || liveFilesCheckInFlight)
            {
                SetLiveFilesVisual(Color.FromArgb(45, 49, 58), Color.FromArgb(210, 216, 232),
                    "LIVE UPDATE   PLIKI: SPRAWDZANIE W TOKU...",
                    "Updater jest zajęty. Licznik odświeży się po zakończeniu bieżącej operacji.");
                return;
            }

            if (string.Equals(liveFilesAttemptedKey, key, StringComparison.Ordinal)
                && DateTime.UtcNow - liveFilesLastAttemptUtc < TimeSpan.FromMinutes(2))
            {
                SetLiveFilesVisual(Color.FromArgb(45, 49, 58), Color.FromArgb(255, 199, 128),
                    "LIVE UPDATE   PLIKI: PONOWIENIE ZA CHWILĘ",
                    "Poprzedni automatyczny odczyt tego samego HEAD nie potwierdził artefaktu. Ponowienie jest ograniczone do raz na 2 minuty.");
                return;
            }

            liveFilesCheckInFlight = true;
            liveFilesAttemptedKey = key;
            liveFilesLastAttemptUtc = DateTime.UtcNow;
            SetLiveFilesVisual(Color.FromArgb(34, 67, 112), Color.FromArgb(174, 211, 255),
                "LIVE UPDATE   PLIKI: LICZĘ RÓŻNICE SHA256...",
                "Pobieram i weryfikuję artefakt dokładnego HEAD, a następnie porównuję EXE/DLL/AddOny z lokalnym katalogiem.");
            try
            {
                await CheckAsync();
                if (lastRemote != null && string.Equals(lastRemote.HeadSha, parallelHead, StringComparison.OrdinalIgnoreCase))
                {
                    liveFilesCheckedKey = key;
                    RefreshLiveFilesFromCache();
                }
                else
                {
                    SetLiveFilesVisual(Color.FromArgb(45, 49, 58), Color.FromArgb(255, 199, 128),
                        "LIVE UPDATE   PLIKI: NIE POTWIERDZONO ARTEFAKTU",
                        "Automatyczny check nie zakończył się artefaktem dokładnego HEAD " + parallelHead + ". Stary wynik nie jest używany.");
                }
            }
            finally
            {
                liveFilesCheckInFlight = false;
            }
        }

        private void RefreshLiveFilesFromCache()
        {
            if (!liveDashboardAttached || githubLiveFilesBadge.IsDisposed || string.IsNullOrWhiteSpace(liveFilesCheckedKey)) return;
            try
            {
                var root = gameDir.Text.Trim();
                if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root) || lastRemote == null) return;
                var expectedKey = ReadyQueueProfileName() + "|" + lastRemote.HeadSha + "|" + Path.GetFullPath(root).ToLowerInvariant();
                if (!string.Equals(liveFilesCheckedKey, expectedKey, StringComparison.Ordinal)) return;

                var dll = LastEnabledDllChangeCount;
                var exe = !IsEconomy() && lastExeInspection != null && lastExeInspection.HasChange ? 1 : 0;
                var addons = IsEconomy() ? lastEconomyAddonChangeCount : cachedVerifiedAddons.Count(addon =>
                {
                    var path = SafeDestination(root, addon.Name);
                    return !File.Exists(path) || !string.Equals(Sha256File(path), Sha256(addon.Bytes), StringComparison.OrdinalIgnoreCase);
                });
                var total = dll + exe + addons;

                if (total > 0)
                {
                    SetLiveFilesVisual(
                        Color.FromArgb(34, 67, 112), Color.FromArgb(174, 211, 255),
                        "LIVE UPDATE   PLIKI GOTOWE DO POBRANIA/UPDATE: " + total +
                            "   | DLL " + dll + " | EXE " + exe + " | ADDONY " + addons,
                        "Dokładny HEAD: " + lastRemote.HeadSha + " / run " + lastRemote.RunId +
                            ". Licznik obejmuje tylko pliki faktycznie różniące się lokalnym SHA256 i aktywne wg ustawień DLL.");
                }
                else
                {
                    SetLiveFilesVisual(
                        Color.FromArgb(32, 77, 50), Color.FromArgb(164, 245, 181),
                        "LIVE UPDATE   PLIKI GOTOWE DO POBRANIA/UPDATE: 0   | LOKALNIE AKTUALNE",
                        "EXE, aktywne DLL i pliki AddOnów odpowiadają zweryfikowanemu artefaktowi " + MonitorShort(lastRemote.HeadSha, 12) + ".");
                }
            }
            catch (Exception ex)
            {
                SetLiveFilesVisual(Color.FromArgb(45, 49, 58), Color.FromArgb(255, 199, 128),
                    "LIVE UPDATE   PLIKI: BŁĄD PORÓWNANIA",
                    ex.Message);
            }
        }

        private void SetLiveFilesVisual(Color back, Color fore, string text, string detail)
        {
            if (githubLiveFilesBadge == null || githubLiveFilesBadge.IsDisposed) return;
            githubLiveFilesBadge.BackColor = back;
            githubLiveFilesBadge.ForeColor = fore;
            githubLiveFilesBadge.Text = text;
            detailsTip.SetToolTip(githubLiveFilesBadge, detail + "\nOdczyt: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
        }
    }
}
