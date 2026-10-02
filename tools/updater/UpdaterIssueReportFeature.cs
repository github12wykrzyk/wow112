using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.Diagnostics;
using System.IO;
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
    internal static class IssueReportFeature
    {
        public static void Attach(Form form)
        {
            if (form == null) return;
            new Controller(form).Attach();
        }

        private sealed class Controller
        {
            private const string Owner = "github12wykrzyk";
            private const string Repo = "wow112";
            private const string ApiRoot = "https://api.github.com/repos/" + Owner + "/" + Repo;
            private const string SearchApiRoot = "https://api.github.com/search/issues";
            private const int AddedHeight = 50;
            private const int GitHubIssueBodySafeChars = 60000;
            private const int GitHubCommentChunkChars = 45000;
            private const int JsonMaxChars = 32 * 1024 * 1024;
            private const int AutoPollMs = 60000;
            private const int AutoDiagMinutes = 5;
            private readonly Form form;
            private readonly TextBox gameDir;
            private readonly RichTextBox log;
            private readonly Label status;
            private readonly Button sendButton = new Button();
            private readonly Button marketDumpButton = new Button();
            private readonly Button tokenButton = new Button();
            private readonly JavaScriptSerializer json = new JavaScriptSerializer();
            private readonly Timer autoTimer = new Timer();
            private bool busy;
            private bool autoTickBusy;
            private DateTime nextAutoDiagUtc = DateTime.MinValue;

            public Controller(Form form)
            {
                this.form = form;
                gameDir = GetPrivateField<TextBox>(form, "gameDir");
                log = GetPrivateField<RichTextBox>(form, "log");
                status = GetPrivateField<Label>(form, "status");
                json.MaxJsonLength = JsonMaxChars;
                json.RecursionLimit = 256;
                autoTimer.Interval = AutoPollMs;
            }

            public void Attach()
            {
                if (gameDir == null) return;
                sendButton.Click += async delegate { await SendReportAsync(false); };
                marketDumpButton.Click += async delegate { await SendMarketDumpAsync(false); };
                tokenButton.Click += delegate { ChangeReportToken(); };
                var host = (IUpdaterHost)form;
                host.RegisterUiControl("report", sendButton);
                host.RegisterUiControl("marketDump", marketDumpButton);
                host.RegisterUiControl("reportToken", tokenButton);

                autoTimer.Tick += async delegate { await AutoSyncAsync(); };
                form.FormClosed += delegate
                {
                    autoTimer.Stop();
                    autoTimer.Dispose();
                };
                autoTimer.Start();
                Log("AUTO DIAG/AH: ON — AH dump po zmianie SavedVariables, DIAG maks. co " + AutoDiagMinutes + " min; ręczne przyciski pozostają awaryjne.");
            }

            private async Task AutoSyncAsync()
            {
                if (autoTickBusy || busy || form.IsDisposed) return;
                if (string.IsNullOrWhiteSpace(LoadReportToken())) return;

                var root = gameDir.Text.Trim();
                if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root)) return;

                autoTickBusy = true;
                try
                {
                    await SendMarketDumpAsync(true);
                    if (DateTime.UtcNow >= nextAutoDiagUtc)
                    {
                        nextAutoDiagUtc = DateTime.UtcNow.AddMinutes(AutoDiagMinutes);
                        await SendReportAsync(true);
                    }
                }
                catch (Exception ex)
                {
                    Log("AUTO telemetry błąd: " + ex.Message);
                }
                finally
                {
                    autoTickBusy = false;
                }
            }

            private async Task SendReportAsync(bool silent)
            {
                string finalStatus = "Gotowy";
                try
                {
                    if (busy) return;
                    var root = gameDir.Text.Trim();
                    if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
                    {
                        if (silent) return;
                        throw new InvalidOperationException("Wybierz istniejący katalog gry.");
                    }
                    root = Path.GetFullPath(root);

                    var reportToken = LoadReportToken();
                    if (string.IsNullOrWhiteSpace(reportToken))
                    {
                        if (silent) return;
                        reportToken = PromptForToken();
                        if (string.IsNullOrWhiteSpace(reportToken))
                        {
                            finalStatus = "Wysyłanie raportu anulowane.";
                            return;
                        }
                        SaveReportToken(reportToken);
                    }

                    if (silent) busy = true;
                    else SetBusy(true, "Tworzenie raportu diagnostycznego...");
                    string headSha;
                    long runId;
                    var bodyCore = BuildReportBody(root, out headSha, out runId);
                    var signatureSeed = BuildSignatureSeed(root, headSha, runId);
                    var signature = Sha256Text(signatureSeed).Substring(0, 12);
                    if (silent && string.Equals(GetAutoStateValue("diag_sha"), signature, StringComparison.OrdinalIgnoreCase))
                        return;
                    var marker = "[diag:" + signature + "]";
                    var title = "[AUTO-DIAG] " + ShortSha(headSha) + " run " + runId + " " + marker;
                    var body = bodyCore + "\n\n---\nDiagnostic signature: `" + signature + "`\nGenerated by WoW112Updater " + UpdaterBuildInfo.Version + ".";
                    var bodySha = Sha256Text(body);
                    var diagnosticChunks = body.Length > GitHubIssueBodySafeChars
                        ? Math.Max(1, (body.Length + GitHubCommentChunkChars - 1) / GitHubCommentChunkChars)
                        : 0;
                    var issueBody = body;
                    if (diagnosticChunks > 0)
                    {
                        var summary = new StringBuilder();
                        summary.AppendLine("## WoW112 automatic diagnostic report");
                        summary.AppendLine();
                        summary.AppendLine("Pełny raport przekracza limit pojedynczego body GitHub Issue i został dołączony poniżej w komentarzach.");
                        summary.AppendLine("Head SHA: `" + headSha + "`");
                        summary.AppendLine("Run ID: " + runId);
                        summary.AppendLine("Diagnostic chars: " + body.Length);
                        summary.AppendLine("Diagnostic SHA256: `" + bodySha + "`");
                        summary.AppendLine("Chunks: " + diagnosticChunks);
                        summary.AppendLine();
                        summary.AppendLine(marker);
                        issueBody = summary.ToString();
                    }

                    using (var client = CreateClient(reportToken))
                    {
                        var existing = await FindExistingIssueAsync(client, marker);
                        if (existing > 0)
                        {
                            finalStatus = "Raport już istnieje jako GitHub Issue #" + existing + ".";
                            SetAutoStateValue("diag_sha", signature);
                            Log(silent ? "AUTO DIAG: zsynchronizowany z istniejącym Issue #" + existing + "." : finalStatus);
                            if (!silent)
                                MessageBox.Show(form, finalStatus, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Information);
                            return;
                        }

                        var payload = new Dictionary<string, object>();
                        payload["title"] = title;
                        payload["body"] = issueBody;
                        using (var request = new HttpRequestMessage(HttpMethod.Post, ApiRoot + "/issues"))
                        {
                            request.Content = new StringContent(json.Serialize(payload), Encoding.UTF8, "application/json");
                            using (var response = await client.SendAsync(request))
                            {
                                var text = await response.Content.ReadAsStringAsync();
                                if (!response.IsSuccessStatusCode)
                                {
                                    HandleAuthenticationFailure(response.StatusCode);
                                    throw BuildIssueApiException(response.StatusCode, text);
                                }
                                var created = AsDictionary(json.DeserializeObject(text));
                                var number = GetLong(created, "number");

                                if (diagnosticChunks > 0)
                                {
                                    for (var i = 0; i < diagnosticChunks; i++)
                                    {
                                        var start = i * GitHubCommentChunkChars;
                                        var count = Math.Min(GitHubCommentChunkChars, body.Length - start);
                                        var chunk = body.Substring(start, count);
                                        var comment = new Dictionary<string, object>();
                                        comment["body"] = "## Diagnostic chunk " + (i + 1) + "/" + diagnosticChunks + "\n\n" + chunk;
                                        using (var chunkRequest = new HttpRequestMessage(HttpMethod.Post, ApiRoot + "/issues/" + number + "/comments"))
                                        {
                                            chunkRequest.Content = new StringContent(json.Serialize(comment), Encoding.UTF8, "application/json");
                                            using (var chunkResponse = await client.SendAsync(chunkRequest))
                                            {
                                                var chunkText = await chunkResponse.Content.ReadAsStringAsync();
                                                if (!chunkResponse.IsSuccessStatusCode)
                                                {
                                                    HandleAuthenticationFailure(chunkResponse.StatusCode);
                                                    throw BuildIssueApiException(chunkResponse.StatusCode, chunkText);
                                                }
                                            }
                                        }
                                        if (i + 1 < diagnosticChunks) await Task.Delay(100);
                                    }
                                }

                                finalStatus = "Raport wysłany jako GitHub Issue #" + number +
                                    (diagnosticChunks > 0 ? " (" + diagnosticChunks + " części)." : ".");
                                SetAutoStateValue("diag_sha", signature);
                                Log(silent ? "AUTO DIAG -> GitHub Issue #" + number + "." : finalStatus);
                                if (!silent)
                                    MessageBox.Show(form, finalStatus, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Information);
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    finalStatus = "Wysyłanie raportu nie powiodło się";
                    Log((silent ? "AUTO DIAG błąd: " : "BŁĄD raportu GitHub: ") + ex.Message);
                    if (!silent)
                        MessageBox.Show(form, ex.Message, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                finally
                {
                    if (silent) busy = false;
                    else SetBusy(false, finalStatus);
                }
            }

            private async Task SendMarketDumpAsync(bool silent)
            {
                string finalStatus = "Gotowy";
                try
                {
                    if (busy) return;
                    var root = gameDir.Text.Trim();
                    if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
                    {
                        if (silent) return;
                        throw new InvalidOperationException("Wybierz istniejący katalog gry.");
                    }
                    root = Path.GetFullPath(root);

                    var reportToken = LoadReportToken();
                    if (string.IsNullOrWhiteSpace(reportToken))
                    {
                        if (silent) return;
                        reportToken = PromptForToken();
                        if (string.IsNullOrWhiteSpace(reportToken))
                        {
                            finalStatus = "Wysyłanie AH dump anulowane.";
                            return;
                        }
                        SaveReportToken(reportToken);
                    }

                    var auxFiles = GetAuxVmangosSavedVariablesFiles(root);
                    string auxFile = null;
                    string marketData = null;
                    string marketFormat = null;
                    string marketMeta = null;
                    foreach (var candidate in auxFiles)
                    {
                        var text = File.ReadAllText(candidate, Encoding.UTF8);
                        var packed = ExtractLuaStringField(text, "marketPacked");
                        if (!string.IsNullOrWhiteSpace(packed))
                        {
                            auxFile = candidate;
                            marketData = packed;
                            marketFormat = "packed-v3";
                            marketMeta = ExtractLuaTableField(text, "marketMeta") ?? "[\"marketMeta\"] = {}";
                            break;
                        }
                        var legacy = ExtractLuaTableField(text, "marketDB");
                        if (string.IsNullOrWhiteSpace(legacy)) continue;
                        auxFile = candidate;
                        marketData = legacy;
                        marketFormat = "legacy-table";
                        marketMeta = ExtractLuaTableField(text, "marketMeta") ?? "[\"marketMeta\"] = {}";
                        break;
                    }
                    if (auxFile == null)
                    {
                        if (silent) return;
                        throw new InvalidOperationException(
                            "Nie znaleziono zapisanego marketPacked/marketDB AuxVmangos. Uruchom pełny MARKET i wykonaj /reload, logout albo zamknij klienta, aby WoW zapisał SavedVariables.");
                    }

                    string headSha = string.Empty;
                    long runId = 0;
                    var installedPath = Path.Combine(root, ".wow112_parallel_updater", "installed.json");
                    if (File.Exists(installedPath))
                    {
                        var installed = AsDictionary(json.DeserializeObject(File.ReadAllText(installedPath, Encoding.UTF8)));
                        headSha = GetString(installed, "head_sha");
                        runId = GetLong(installed, "run_id");
                    }

                    var savedUtc = File.GetLastWriteTimeUtc(auxFile);
                    var dump = "AVM_AH_MARKET_DUMP_V2\n" +
                        "saved_variables_utc=" + savedUtc.ToString("o") + "\n" +
                        "head_sha=" + headSha + "\n" +
                        "run_id=" + runId + "\n" +
                        "updater=" + UpdaterBuildInfo.Version + "\n" +
                        "market_format=" + marketFormat + "\n\n" +
                        marketMeta + "\n\n" + marketData + "\n";
                    var fullSha = Sha256Text(dump);
                    var marketContentSha = Sha256Text(marketFormat + "\n" + marketMeta + "\n" + marketData);
                    if (silent && string.Equals(GetAutoStateValue("ah_content_sha"), marketContentSha, StringComparison.OrdinalIgnoreCase))
                        return;
                    var signature = fullSha.Substring(0, 12);
                    var marker = "[ahdump:" + signature + "]";

                    if (silent) busy = true;
                    else SetBusy(true, "Wysyłanie pełnej historii AH...");
                    using (var client = CreateClient(reportToken))
                    {
                        var existing = await FindExistingIssueAsync(client, marker);
                        if (existing > 0)
                        {
                            finalStatus = "Ten AH dump już istnieje jako GitHub Issue #" + existing + ".";
                            SetAutoStateValue("ah_content_sha", marketContentSha);
                            Log(silent ? "AUTO AH: zsynchronizowany z istniejącym Issue #" + existing + "." : finalStatus);
                            if (!silent)
                                MessageBox.Show(form, finalStatus, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Information);
                            return;
                        }

                        const int ChunkChars = 45000;
                        var chunks = Math.Max(1, (dump.Length + ChunkChars - 1) / ChunkChars);
                        var body = new StringBuilder();
                        body.AppendLine("## WoW112 AH Market Dump");
                        body.AppendLine();
                        body.AppendLine("Head SHA: `" + headSha + "`");
                        body.AppendLine("Run ID: " + runId);
                        body.AppendLine("SavedVariables UTC: " + savedUtc.ToString("o"));
                        body.AppendLine("Payload SHA256: `" + fullSha + "`");
                        body.AppendLine("Payload chars: " + dump.Length);
                        body.AppendLine("Chunks: " + chunks);
                        body.AppendLine();
                        body.AppendLine("Contains only AuxVmangos `marketMeta` plus compact `marketPacked` schema 3 (or legacy `marketDB` fallback). No account path, credentials or unrelated SavedVariables are uploaded.");
                        body.AppendLine("Packed schema 3 stores the same schema-2 snapshot fields without thousands of nested SavedVariables tables. `netDown` remains a net supply-decrease proxy, not proof of a sale.");
                        body.AppendLine();
                        body.AppendLine("If WoW is still open, use `/reload` immediately before sending so SavedVariables includes the newest in-memory market history.");
                        body.AppendLine();
                        body.AppendLine(marker);

                        var payload = new Dictionary<string, object>();
                        payload["title"] = "[AH-DUMP] " + ShortSha(headSha) + " " + savedUtc.ToString("yyyy-MM-dd HH:mm") + "Z " + marker;
                        payload["body"] = body.ToString();
                        long issueNumber;
                        using (var request = new HttpRequestMessage(HttpMethod.Post, ApiRoot + "/issues"))
                        {
                            request.Content = new StringContent(json.Serialize(payload), Encoding.UTF8, "application/json");
                            using (var response = await client.SendAsync(request))
                            {
                                var responseText = await response.Content.ReadAsStringAsync();
                                if (!response.IsSuccessStatusCode)
                                {
                                    HandleAuthenticationFailure(response.StatusCode);
                                    throw BuildIssueApiException(response.StatusCode, responseText);
                                }
                                issueNumber = GetLong(AsDictionary(json.DeserializeObject(responseText)), "number");
                            }
                        }

                        for (var i = 0; i < chunks; i++)
                        {
                            var start = i * ChunkChars;
                            var count = Math.Min(ChunkChars, dump.Length - start);
                            var chunk = dump.Substring(start, count);
                            var comment = new Dictionary<string, object>();
                            comment["body"] = "AH dump chunk " + (i + 1) + "/" + chunks + "\n```text\n" + chunk + "\n```";
                            using (var request = new HttpRequestMessage(HttpMethod.Post, ApiRoot + "/issues/" + issueNumber + "/comments"))
                            {
                                request.Content = new StringContent(json.Serialize(comment), Encoding.UTF8, "application/json");
                                using (var response = await client.SendAsync(request))
                                {
                                    var responseText = await response.Content.ReadAsStringAsync();
                                    if (!response.IsSuccessStatusCode)
                                    {
                                        HandleAuthenticationFailure(response.StatusCode);
                                        throw BuildIssueApiException(response.StatusCode, responseText);
                                    }
                                }
                            }
                            if (i + 1 < chunks) await Task.Delay(100);
                        }

                        finalStatus = "AH Market Dump wysłany jako GitHub Issue #" + issueNumber + " (" + chunks + " części).";
                        SetAutoStateValue("ah_content_sha", marketContentSha);
                        Log(silent ? "AUTO AH -> GitHub Issue #" + issueNumber + " (" + chunks + " części)." : finalStatus);
                        if (!silent)
                            MessageBox.Show(form, finalStatus, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    }
                }
                catch (Exception ex)
                {
                    finalStatus = "Wysyłanie AH dump nie powiodło się";
                    Log((silent ? "AUTO AH błąd: " : "BŁĄD AH dump: ") + ex.Message);
                    if (!silent)
                        MessageBox.Show(form, ex.Message, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                finally
                {
                    if (silent) busy = false;
                    else SetBusy(false, finalStatus);
                }
            }

            private void ChangeReportToken()
            {
                try
                {
                    var value = PromptForToken();
                    if (string.IsNullOrWhiteSpace(value)) return;
                    SaveReportToken(value);
                    Log("Token raportowy został zastąpiony i zapisany przez DPAPI.");
                    MessageBox.Show(form, "Token raportowy zapisany.", "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                catch (Exception ex)
                {
                    Log("BŁĄD zapisu tokenu raportowego: " + ex.Message);
                    MessageBox.Show(form, ex.Message, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }

            private string BuildReportBody(string root, out string headSha, out long runId)
            {
                headSha = string.Empty;
                runId = 0;
                var sb = new StringBuilder();
                sb.AppendLine("## WoW112 automatic diagnostic report");
                sb.AppendLine();
                sb.AppendLine("Target: World of Warcraft 1.12.1 build 5875, Windows x86");
                sb.AppendLine("Updater: " + UpdaterBuildInfo.Version);
                sb.AppendLine("Generated UTC: " + DateTime.UtcNow.ToString("o"));

                var installedPath = Path.Combine(root, ".wow112_parallel_updater", "installed.json");
                Dictionary<string, object> installed = null;
                if (File.Exists(installedPath))
                {
                    installed = AsDictionary(json.DeserializeObject(File.ReadAllText(installedPath, Encoding.UTF8)));
                    headSha = GetString(installed, "head_sha");
                    runId = GetLong(installed, "run_id");
                    sb.AppendLine("Channel: " + GetString(installed, "channel"));
                    sb.AppendLine("Run ID: " + runId);
                    sb.AppendLine("Head SHA: `" + headSha + "`");
                    sb.AppendLine("Artifact: " + GetString(installed, "artifact_name"));
                    sb.AppendLine("Installed UTC: " + GetString(installed, "installed_utc"));
                    sb.AppendLine("Integrity: " + GetString(installed, "integrity_status"));
                }
                else
                {
                    sb.AppendLine("Installed-state metadata: missing");
                }

                var dlls = Path.Combine(root, "dlls.txt");
                if (File.Exists(dlls))
                {
                    sb.AppendLine();
                    sb.AppendLine("### dlls.txt");
                    sb.AppendLine("```text");
                    sb.AppendLine(Sanitize(File.ReadAllText(dlls, Encoding.ASCII), root, 12000));
                    sb.AppendLine("```");
                }

                sb.AppendLine();
                sb.AppendLine("### WoWDiagHub recent logs");
                var files = GetRecentDiagFiles(root);
                if (files.Length == 0)
                {
                    sb.AppendLine("No WoWDiagHub JSONL diagnostic files found.");
                }
                else
                {
                    foreach (var file in files)
                    {
                        sb.AppendLine();
                        sb.AppendLine("#### " + Path.GetFileName(file));
                        sb.AppendLine("```json");
                        sb.AppendLine(Sanitize(TailFile(file, 5000), root, 5000));
                        sb.AppendLine("```");
                    }
                }


                sb.AppendLine();
                sb.AppendLine("### AuxVmangos diagnostics (SavedVariables snapshot)");
                sb.AppendLine("Note: WoW flushes SavedVariables on /reload, logout or client exit. If WoW is still running, this can be the latest flushed snapshot rather than the current in-memory state.");
                var auxFiles = GetAuxVmangosSavedVariablesFiles(root);
                if (auxFiles.Length == 0)
                {
                    sb.AppendLine("No AuxVmangos SavedVariables file found.");
                }
                else
                {
                    foreach (var file in auxFiles)
                    {
                        sb.AppendLine();
                        sb.AppendLine("#### AuxVmangos.lua (UTC " + File.GetLastWriteTimeUtc(file).ToString("o") + ")");
                        sb.AppendLine("```text");
                        sb.AppendLine(Sanitize(ExtractAuxVmangosDiagnostics(file, 70000), root, 18000));
                        sb.AppendLine("```");
                    }
                }

                sb.AppendLine();
                // PositionalSpoof writes a plain-text log in the game directory.
                // Include only a bounded tail; the default WoWDiagHub JSONL report
                // does not contain cast attempts or client-side positional failures.
                sb.AppendLine("### PositionalSpoof recent cast log");
                var positionalLog = Path.Combine(root, "WoWPositionalSpoof_v0_36_NoPP_SmartEnergy700_SmoothStealth_GateGCDFix.log");
                if (File.Exists(positionalLog))
                {
                    sb.AppendLine("```text");
                    sb.AppendLine(Sanitize(TailFile(positionalLog, 8500), root, 8500));
                    sb.AppendLine("```");
                }
                else sb.AppendLine("No PositionalSpoof cast log found in game directory.");
                sb.AppendLine();
                sb.AppendLine("### PP fixed-point diagnostic (bounded tail)");
                var ppFixedLog = Path.Combine(root, "PPFixedPoint_debug.log");
                if (File.Exists(ppFixedLog))
                {
                    sb.AppendLine("```text");
                    sb.AppendLine(Sanitize(TailFile(ppFixedLog, 16000), root, 16000));
                    sb.AppendLine("```");
                }
                else sb.AppendLine("PPFixedPoint_debug.log not found (launch game with the fixed-point candidate first).");

                sb.AppendLine();
                sb.AppendLine("### Character switch diagnostic");
                var charSwitchLog = Path.Combine(root, "CharacterSwitchDiag.log");
                if (File.Exists(charSwitchLog))
                {
                    sb.AppendLine("```text");
                    sb.AppendLine(Sanitize(TailFile(charSwitchLog, 16000), root, 16000));
                    sb.AppendLine("```");
                }
                else sb.AppendLine("CharacterSwitchDiag.log not found.");

                sb.AppendLine();
                sb.AppendLine("### Summon coordinator / slave-worker diagnostics");
                sb.AppendLine("Contract: request_id, source warlock, destination, request/lease state, worker label/PID, target slot, combat gate, READY count, switch timing, ritual/click result and retry reason. Credentials must never be logged.");
                var summonDiagFiles = GetSummonCoordinatorDiagFiles(root);
                if (summonDiagFiles.Length == 0)
                {
                    sb.AppendLine("No SummonCoordinator/SummonWorker diagnostic files found.");
                }
                else
                {
                    foreach (var file in summonDiagFiles)
                    {
                        sb.AppendLine();
                        sb.AppendLine("#### " + Path.GetFileName(file) + " (UTC " + File.GetLastWriteTimeUtc(file).ToString("o") + ")");
                        sb.AppendLine("```text");
                        sb.AppendLine(Sanitize(TailFile(file, 4500), root, 4500));
                        sb.AppendLine("```");
                    }
                }

                sb.AppendLine();
                sb.AppendLine("### TaxiFlight hotkey / flight telemetry (CSV)");
                var taxiFiles = GetRecentTaxiFiles(root);
                if (taxiFiles.Length == 0)
                {
                    sb.AppendLine("No taxi_probe_*.csv diagnostic files found.");
                }
                else
                {
                    foreach (var file in taxiFiles)
                    {
                        sb.AppendLine();
                        sb.AppendLine("#### " + Path.GetFileName(file));
                        sb.AppendLine("```text");
                        sb.AppendLine(Sanitize(TailFile(file, 9500), root, 9500));
                        sb.AppendLine("```");
                    }
                }

                sb.AppendLine();
                sb.AppendLine("### Recent WoW native crash reports (last 72h)");
                var crashFiles = GetRecentCrashFiles(root);
                if (crashFiles.Length == 0)
                {
                    sb.AppendLine("No recent native WoW Errors/*.txt reports found.");
                }
                else
                {
                    foreach (var file in crashFiles)
                    {
                        sb.AppendLine();
                        sb.AppendLine("#### " + Path.GetFileName(file) + " (UTC " + File.GetLastWriteTimeUtc(file).ToString("o") + ")");
                        sb.AppendLine("```text");
                        sb.AppendLine(Sanitize(HeadFile(file, 5000) + "\n--- END OF REPORT ---\n" + TailFile(file, 7000), root, 12500));
                        sb.AppendLine("```");
                    }
                }

                sb.AppendLine();
                sb.AppendLine("### Windows Application Error / WER (last 72h)");
                var windowsErrors = GetRecentWowApplicationErrors(root);
                if (windowsErrors.Length == 0)
                    sb.AppendLine("No matching recent Windows Application Error/WER events accessible.");
                else
                    foreach (var error in windowsErrors) sb.AppendLine(Sanitize(error, root, 5000));

                if (log != null && !string.IsNullOrWhiteSpace(log.Text))
                {
                    sb.AppendLine();
                    sb.AppendLine("### Updater session log (tail)");
                    sb.AppendLine("```text");
                    sb.AppendLine(Sanitize(TailText(log.Text, 5000), root, 5000));
                    sb.AppendLine("```");
                }
                return sb.ToString();
            }

            private string BuildSignatureSeed(string root, string headSha, long runId)
            {
                var sb = new StringBuilder();
                sb.AppendLine("W112-DIAG-SIGNATURE-V2");
                sb.AppendLine(headSha ?? string.Empty);
                sb.AppendLine(runId.ToString());

                var dlls = Path.Combine(root, "dlls.txt");
                if (File.Exists(dlls))
                    sb.AppendLine(Sanitize(File.ReadAllText(dlls, Encoding.ASCII), root, 12000));
                else
                    sb.AppendLine("<no-dlls>");

                var files = GetRecentDiagFiles(root);
                if (files.Length == 0)
                {
                    sb.AppendLine("<no-diag-files>");
                }
                else
                {
                    foreach (var file in files)
                    {
                        sb.AppendLine(Path.GetFileName(file));
                        sb.AppendLine(Sanitize(TailFile(file, 12000), root, 12000));
                    }
                }
                foreach (var auxFile in GetAuxVmangosSavedVariablesFiles(root))
                {
                    sb.AppendLine("AuxVmangos.lua");
                    sb.AppendLine(File.GetLastWriteTimeUtc(auxFile).Ticks.ToString());
                    sb.AppendLine(Sanitize(ExtractAuxVmangosDiagnostics(auxFile, 18000), root, 18000));
                }
                var ppFixedLog = Path.Combine(root, "PPFixedPoint_debug.log");
                if (File.Exists(ppFixedLog))
                    sb.AppendLine(Sanitize(TailFile(ppFixedLog, 16000), root, 16000));
                var charSwitchLog = Path.Combine(root, "CharacterSwitchDiag.log");
                if (File.Exists(charSwitchLog))
                    sb.AppendLine(Sanitize(TailFile(charSwitchLog, 16000), root, 16000));
                foreach (var summonFile in GetSummonCoordinatorDiagFiles(root))
                {
                    sb.AppendLine(Path.GetFileName(summonFile));
                    sb.AppendLine(File.GetLastWriteTimeUtc(summonFile).Ticks.ToString());
                    sb.AppendLine(Sanitize(TailFile(summonFile, 3000), root, 3000));
                }
                foreach (var taxiFile in GetRecentTaxiFiles(root))
                {
                    sb.AppendLine(Path.GetFileName(taxiFile));
                    sb.AppendLine(Sanitize(TailFile(taxiFile, 9500), root, 9500));
                }
                var crashFiles = GetRecentCrashFiles(root);
                foreach (var file in crashFiles)
                {
                    sb.AppendLine(Path.GetFileName(file));
                    sb.AppendLine(File.GetLastWriteTimeUtc(file).Ticks.ToString());
                    sb.AppendLine(Sanitize(HeadFile(file, 2500) + TailFile(file, 2500), root, 5500));
                }
                foreach (var error in GetRecentWowApplicationErrors(root))
                    sb.AppendLine(Sanitize(error, root, 5000));
                return sb.ToString();
            }

            private static string[] GetSummonCoordinatorDiagFiles(string root)
            {
                try
                {
                    if (!Directory.Exists(root)) return new string[0];
                    var files = new List<string>();
                    foreach (var name in new[] { "SummonCoordinator.log", "SummonCoordinator.jsonl" })
                    {
                        var path = Path.Combine(root, name);
                        if (File.Exists(path)) files.Add(path);
                    }
                    files.AddRange(Directory.GetFiles(root, "SummonWorker*.log", SearchOption.TopDirectoryOnly));
                    files.AddRange(Directory.GetFiles(root, "SummonWorker*.jsonl", SearchOption.TopDirectoryOnly));
                    return files
                        .Distinct(StringComparer.OrdinalIgnoreCase)
                        .OrderByDescending(File.GetLastWriteTimeUtc)
                        .Take(4)
                        .ToArray();
                }
                catch { return new string[0]; }
            }

            private static string[] GetRecentCrashFiles(string root)
            {
                try
                {
                    var errorDir = Path.Combine(root, "Errors");
                    if (!Directory.Exists(errorDir)) return new string[0];
                    var cutoff = DateTime.UtcNow.AddHours(-72);
                    return Directory.GetFiles(errorDir, "*.txt", SearchOption.TopDirectoryOnly)
                        .Where(p => File.GetLastWriteTimeUtc(p) >= cutoff)
                        .OrderByDescending(File.GetLastWriteTimeUtc)
                        .Take(2)
                        .ToArray();
                }
                catch { return new string[0]; }
            }

            private static string HeadFile(string path, int maxChars)
            {
                try
                {
                    using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    {
                        var count = (int)Math.Min(stream.Length, Math.Max(4096, maxChars * 3));
                        var bytes = new byte[count];
                        var total = 0;
                        while (total < count)
                        {
                            var read = stream.Read(bytes, total, count - total);
                            if (read <= 0) break;
                            total += read;
                        }
                        var text = Encoding.UTF8.GetString(bytes, 0, total);
                        return text.Length <= maxChars ? text : text.Substring(0, maxChars) + "\n<head truncated>";
                    }
                }
                catch (Exception ex) { return "<crash report read error: " + ex.Message + ">"; }
            }

            private static string[] GetRecentWowApplicationErrors(string root)
            {
                var result = new List<string>();
                try
                {
                    var cutoff = DateTime.Now.AddHours(-72);
                    using (var app = new EventLog("Application"))
                    {
                        var events = app.Entries;
                        var inspected = 0;
                        for (var i = events.Count - 1; i >= 0 && inspected < 512 && result.Count < 2; --i, ++inspected)
                        {
                            var ev = events[i];
                            if (ev.TimeGenerated < cutoff) break;
                            if (ev.EntryType != EventLogEntryType.Error) continue;
                            if (!string.Equals(ev.Source, "Application Error", StringComparison.OrdinalIgnoreCase) &&
                                !string.Equals(ev.Source, "Windows Error Reporting", StringComparison.OrdinalIgnoreCase)) continue;
                            var message = ev.Message ?? string.Empty;
                            if (message.IndexOf("WoW_5875_", StringComparison.OrdinalIgnoreCase) < 0 &&
                                message.IndexOf("WoW.exe", StringComparison.OrdinalIgnoreCase) < 0) continue;
                            result.Add("Event UTC " + ev.TimeGenerated.ToUniversalTime().ToString("o") +
                                ", source " + ev.Source + ", event id " + ev.InstanceId + "\n" +
                                (message.Length <= 4000 ? message : message.Substring(0, 4000) + "\n<event truncated>"));
                        }
                    }
                }
                catch (Exception ex)
                {
                    result.Add("Windows Application log unavailable: " + ex.GetType().Name);
                }
                return result.ToArray();
            }

            private static string[] GetAuxVmangosSavedVariablesFiles(string root)
            {
                try
                {
                    var accountRoot = Path.Combine(root, "WTF", "Account");
                    if (!Directory.Exists(accountRoot)) return new string[0];
                    return Directory.GetFiles(accountRoot, "AuxVmangos.lua", SearchOption.AllDirectories)
                        .Where(p => p.IndexOf(Path.DirectorySeparatorChar + "SavedVariables" + Path.DirectorySeparatorChar,
                            StringComparison.OrdinalIgnoreCase) >= 0)
                        .OrderByDescending(File.GetLastWriteTimeUtc)
                        .Take(2)
                        .ToArray();
                }
                catch { return new string[0]; }
            }

            private static string ExtractAuxVmangosDiagnostics(string path, int maxChars)
            {
                try
                {
                    var text = File.ReadAllText(path, Encoding.UTF8);
                    if (string.IsNullOrEmpty(text)) return "<empty AuxVmangos SavedVariables>";
                    var diag = ExtractLuaTableField(text, "diag");
                    if (string.IsNullOrEmpty(diag))
                        return "AuxVmangos SavedVariables found, but no diagnostic table has been flushed yet.\n" +
                            TailText(text, Math.Min(maxChars, 4000));
                    if (diag.Length <= maxChars) return diag;
                    return diag.Substring(0, maxChars) +
                        "\n<AuxVmangos diag table truncated after " + maxChars + " chars>";
                }
                catch (Exception ex)
                {
                    return "<AuxVmangos diagnostics read error: " + ex.Message + ">";
                }
            }

            private static string ExtractLuaStringField(string text, string key)
            {
                if (string.IsNullOrEmpty(text) || string.IsNullOrEmpty(key)) return null;
                var marker = "[\"" + key + "\"]";
                var markerIndex = text.IndexOf(marker, StringComparison.Ordinal);
                if (markerIndex < 0) return null;
                var eq = text.IndexOf('=', markerIndex + marker.Length);
                if (eq < 0) return null;
                var quote = text.IndexOf('"', eq + 1);
                if (quote < 0) return null;

                var escaped = false;
                for (var i = quote + 1; i < text.Length; i++)
                {
                    var c = text[i];
                    if (escaped) { escaped = false; continue; }
                    if (c == '\\') { escaped = true; continue; }
                    if (c == '"') return text.Substring(markerIndex, i - markerIndex + 1);
                }
                return null;
            }

            private static string ExtractLuaTableField(string text, string key)
            {
                if (string.IsNullOrEmpty(text) || string.IsNullOrEmpty(key)) return null;
                var marker = "[\"" + key + "\"]";
                var markerIndex = text.IndexOf(marker, StringComparison.Ordinal);
                if (markerIndex < 0) return null;
                var eq = text.IndexOf('=', markerIndex + marker.Length);
                if (eq < 0) return null;
                var open = text.IndexOf('{', eq + 1);
                if (open < 0) return null;

                var depth = 0;
                var inString = false;
                var escaped = false;
                for (var i = open; i < text.Length; i++)
                {
                    var c = text[i];
                    if (inString)
                    {
                        if (escaped) { escaped = false; continue; }
                        if (c == '\\') { escaped = true; continue; }
                        if (c == '"') inString = false;
                        continue;
                    }
                    if (c == '"') { inString = true; continue; }
                    if (c == '{') depth++;
                    else if (c == '}')
                    {
                        depth--;
                        if (depth == 0)
                            return text.Substring(markerIndex, i - markerIndex + 1);
                    }
                }
                return null;
            }

            private static string DiagPid(string path)
            {
                var name = Path.GetFileNameWithoutExtension(path) ?? string.Empty;
                var parts = name.Split('_');
                if (parts.Length >= 5 &&
                    string.Equals(parts[0], "remote", StringComparison.OrdinalIgnoreCase) &&
                    string.Equals(parts[1], "service", StringComparison.OrdinalIgnoreCase) &&
                    string.Equals(parts[2], "probe", StringComparison.OrdinalIgnoreCase))
                    return parts[3];
                if (parts.Length >= 4 &&
                    string.Equals(parts[0], "market", StringComparison.OrdinalIgnoreCase) &&
                    string.Equals(parts[1], "worker", StringComparison.OrdinalIgnoreCase))
                    return parts[2];
                return string.Empty;
            }

            private static string[] GetRecentDiagFiles(string root)
            {
                var debugDir = Path.Combine(root, ".wow112_debug");
                if (!Directory.Exists(debugDir)) return new string[0];
                var all = Directory.GetFiles(debugDir, "*.jsonl")
                    .OrderByDescending(File.GetLastWriteTimeUtc)
                    .ToArray();
                var chosen = new List<string>(all.Take(4));

                // Keep RSP and MarketWorker evidence paired by PID. A busy
                // multibox session can otherwise push the worker log just
                // outside the global newest-three window.
                foreach (var seed in chosen.ToArray())
                {
                    var pid = DiagPid(seed);
                    if (string.IsNullOrEmpty(pid)) continue;
                    var mate = all.FirstOrDefault(p =>
                    {
                        var n = Path.GetFileName(p);
                        return (n.StartsWith("market_worker_" + pid + "_", StringComparison.OrdinalIgnoreCase) ||
                                n.StartsWith("remote_service_probe_" + pid + "_", StringComparison.OrdinalIgnoreCase)) &&
                               !string.Equals(p, seed, StringComparison.OrdinalIgnoreCase);
                    });
                    if (!string.IsNullOrEmpty(mate)) chosen.Add(mate);
                }

                chosen.AddRange(all.Where(p => Path.GetFileName(p).StartsWith("market_worker_", StringComparison.OrdinalIgnoreCase)).Take(2));
                chosen.AddRange(all.Where(p => Path.GetFileName(p).StartsWith("remote_service_probe_", StringComparison.OrdinalIgnoreCase)).Take(2));
                return chosen
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .OrderByDescending(File.GetLastWriteTimeUtc)
                    .Take(8)
                    .ToArray();
            }

            private static string[] GetRecentTaxiFiles(string root)
            {
                var debugDir = Path.Combine(root, ".wow112_debug");
                if (!Directory.Exists(debugDir)) return new string[0];
                return Directory.GetFiles(debugDir, "taxi_probe_*.csv")
                    .OrderByDescending(File.GetLastWriteTimeUtc)
                    .Take(2)
                    .ToArray();
            }

            private async Task<long> FindExistingIssueAsync(HttpClient client, string marker)
            {
                // Do not download every open Issue including its body. AH dump Issues can
                // carry large payloads and the old per_page=100 response could exceed the
                // JavaScriptSerializer input limit before a new report was sent.
                var query = "repo:" + Owner + "/" + Repo + " is:issue is:open in:title \"" + marker + "\"";
                var url = SearchApiRoot + "?per_page=5&q=" + Uri.EscapeDataString(query);
                using (var response = await client.GetAsync(url))
                {
                    var text = await response.Content.ReadAsStringAsync();
                    if (!response.IsSuccessStatusCode)
                    {
                        HandleAuthenticationFailure(response.StatusCode);
                        throw BuildIssueApiException(response.StatusCode, text);
                    }
                    var root = AsDictionary(json.DeserializeObject(text));
                    foreach (var item in AsArray(GetValue(root, "items")))
                    {
                        var row = item as Dictionary<string, object>;
                        if (row == null) continue;
                        if (GetString(row, "title").IndexOf(marker, StringComparison.OrdinalIgnoreCase) >= 0)
                            return GetLong(row, "number");
                    }
                }
                return 0;
            }

            private static InvalidOperationException BuildIssueApiException(System.Net.HttpStatusCode statusCode, string responseText)
            {
                var code = (int)statusCode;
                if (code == 403)
                {
                    return new InvalidOperationException(
                        "GitHub odrzucił dostęp do Issues (HTTP 403).\n\n" +
                        "Fine-grained token musi mieć:\n" +
                        "• Repository access: Only select repositories -> wow112\n" +
                        "• Repository permissions -> Issues: Read and write\n" +
                        "• Metadata: Read-only (ustawiane automatycznie)\n\n" +
                        "Updater usunął zapisany token. Po poprawieniu lub utworzeniu tokena kliknij Wyślij raport ponownie.\n\n" +
                        "Szczegóły GitHub: " + TrimForError(responseText));
                }
                if (code == 401)
                {
                    return new InvalidOperationException(
                        "GitHub odrzucił token (HTTP 401). Token jest nieprawidłowy, wygasł albo został cofnięty.\n\n" +
                        "Utwórz/ustaw nowy fine-grained token dla repo wow112 z Issues: Read and write, a potem ponów wysłanie raportu.\n\n" +
                        "Szczegóły GitHub: " + TrimForError(responseText));
                }
                return new InvalidOperationException(
                    "GitHub Issues HTTP " + code + ": " + TrimForError(responseText));
            }

            private static HttpClient CreateClient(string reportToken)
            {
                var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = true });
                client.Timeout = TimeSpan.FromMinutes(2);
                client.DefaultRequestHeaders.UserAgent.ParseAdd("WoW112Updater/" + UpdaterBuildInfo.Version);
                client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
                client.DefaultRequestHeaders.Add("X-GitHub-Api-Version", "2022-11-28");
                client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", reportToken.Trim());
                return client;
            }

            private string PromptForToken()
            {
                using (var dialog = new Form())
                using (var box = new TextBox())
                using (var ok = new Button())
                using (var cancel = new Button())
                {
                    dialog.Text = "GitHub report token";
                    dialog.ClientSize = new Size(620, 150);
                    dialog.StartPosition = FormStartPosition.CenterParent;
                    dialog.FormBorderStyle = FormBorderStyle.FixedDialog;
                    dialog.MaximizeBox = false;
                    dialog.MinimizeBox = false;
                    dialog.Controls.Add(new Label { Text = "Osobny fine-grained token dla repo wow112: Issues = Read and write", Left = 16, Top = 16, AutoSize = true });
                    box.Left = 16;
                    box.Top = 45;
                    box.Width = 588;
                    box.UseSystemPasswordChar = true;
                    dialog.Controls.Add(box);
                    ok.Text = "ZAPISZ";
                    ok.SetBounds(378, 92, 108, 32);
                    ok.DialogResult = DialogResult.OK;
                    cancel.Text = "ANULUJ";
                    cancel.SetBounds(496, 92, 108, 32);
                    cancel.DialogResult = DialogResult.Cancel;
                    dialog.Controls.Add(ok);
                    dialog.Controls.Add(cancel);
                    dialog.AcceptButton = ok;
                    dialog.CancelButton = cancel;
                    return dialog.ShowDialog(form) == DialogResult.OK ? box.Text.Trim() : string.Empty;
                }
            }

            private static string ReportTokenPath()
            {
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "WoW112ParallelUpdater", "report_token.dpapi");
            }

            private static string AutoStatePath()
            {
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "WoW112ParallelUpdater", "report_auto_state.json");
            }

            private Dictionary<string, object> LoadAutoState()
            {
                try
                {
                    var path = AutoStatePath();
                    if (!File.Exists(path)) return new Dictionary<string, object>();
                    return AsDictionary(json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8)));
                }
                catch
                {
                    return new Dictionary<string, object>();
                }
            }

            private string GetAutoStateValue(string key)
            {
                return GetString(LoadAutoState(), key);
            }

            private void SetAutoStateValue(string key, string value)
            {
                try
                {
                    var state = LoadAutoState();
                    state[key] = value ?? string.Empty;
                    state[key + "_utc"] = DateTime.UtcNow.ToString("o");
                    UpdaterSafety.WriteUtf8Atomic(AutoStatePath(), json.Serialize(state), ".tmp", ".previous");
                }
                catch (Exception ex)
                {
                    Log("AUTO telemetry state warning: " + ex.Message);
                }
            }

            private static byte[] ReportEntropy()
            {
                return Encoding.UTF8.GetBytes("WoW112ParallelUpdater-report-token-v1");
            }

            private string LoadReportToken()
            {
                try
                {
                    var path = ReportTokenPath();
                    if (!File.Exists(path)) return string.Empty;
                    var protectedBytes = Convert.FromBase64String(File.ReadAllText(path, Encoding.ASCII));
                    return Encoding.UTF8.GetString(ProtectedData.Unprotect(protectedBytes, ReportEntropy(), DataProtectionScope.CurrentUser));
                }
                catch (Exception ex)
                {
                    Log("Ostrzeżenie: nie udało się odczytać tokenu raportowego: " + ex.Message);
                    DeleteReportToken();
                    return string.Empty;
                }
            }

            private static void SaveReportToken(string value)
            {
                var path = ReportTokenPath();
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                var protectedBytes = ProtectedData.Protect(Encoding.UTF8.GetBytes(value.Trim()), ReportEntropy(), DataProtectionScope.CurrentUser);
                File.WriteAllText(path, Convert.ToBase64String(protectedBytes), Encoding.ASCII);
            }

            private static void DeleteReportToken()
            {
                try
                {
                    var path = ReportTokenPath();
                    if (File.Exists(path)) File.Delete(path);
                }
                catch
                {
                }
            }

            private void HandleAuthenticationFailure(System.Net.HttpStatusCode statusCode)
            {
                var code = (int)statusCode;
                if (code != 401 && code != 403) return;
                DeleteReportToken();
                Log("Token raportowy został odrzucony przez GitHub i usunięty z lokalnego magazynu. Przy następnej próbie updater poprosi o nowy token.");
            }

            private void SetBusy(bool value, string text)
            {
                busy = value;
                ((IUpdaterHost)form).SetBusy(value, text);
            }

            private void Log(string message)
            {
                if (log == null) return;
                log.AppendText("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + message + Environment.NewLine);
                log.SelectionStart = log.TextLength;
                log.ScrollToCaret();
            }

            private static string TailFile(string path, int maxChars)
            {
                try
                {
                    using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    {
                        if (stream.Length == 0) return string.Empty;
                        var maxBytes = Math.Max(4096L, (long)maxChars * 4L);
                        var count = (int)Math.Min(stream.Length, maxBytes);
                        stream.Seek(-count, SeekOrigin.End);
                        var buffer = new byte[count];
                        var total = 0;
                        while (total < count)
                        {
                            var read = stream.Read(buffer, total, count - total);
                            if (read <= 0) break;
                            total += read;
                        }
                        var text = Encoding.UTF8.GetString(buffer, 0, total);
                        return TailText(text, maxChars);
                    }
                }
                catch (Exception ex)
                {
                    return "<read error: " + ex.Message + ">";
                }
            }

            private static string TailText(string text, int maxChars)
            {
                if (string.IsNullOrEmpty(text) || text.Length <= maxChars) return text ?? string.Empty;
                return "<truncated>\n" + text.Substring(text.Length - maxChars);
            }

            private static string Sanitize(string text, string root, int maxChars)
            {
                text = TailText(text, maxChars);
                if (!string.IsNullOrWhiteSpace(root)) text = ReplaceInsensitive(text, root, "<GAME_DIR>");
                var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                if (!string.IsNullOrWhiteSpace(profile)) text = ReplaceInsensitive(text, profile, "<USER_PROFILE>");
                return text;
            }

            private static string ReplaceInsensitive(string text, string value, string replacement)
            {
                if (string.IsNullOrEmpty(text) || string.IsNullOrEmpty(value)) return text ?? string.Empty;
                var sb = new StringBuilder();
                var start = 0;
                while (start < text.Length)
                {
                    var index = text.IndexOf(value, start, StringComparison.OrdinalIgnoreCase);
                    if (index < 0)
                    {
                        sb.Append(text, start, text.Length - start);
                        break;
                    }
                    sb.Append(text, start, index - start);
                    sb.Append(replacement);
                    start = index + value.Length;
                }
                return sb.ToString();
            }

            private static string Sha256Text(string text)
            {
                using (var sha = SHA256.Create())
                {
                    var bytes = sha.ComputeHash(Encoding.UTF8.GetBytes(text ?? string.Empty));
                    var sb = new StringBuilder(bytes.Length * 2);
                    foreach (var b in bytes) sb.Append(b.ToString("x2"));
                    return sb.ToString();
                }
            }

            private static T GetPrivateField<T>(object instance, string name) where T : class
            {
                var field = instance.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic);
                return field == null ? null : field.GetValue(instance) as T;
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

            private static string ShortSha(string sha)
            {
                return string.IsNullOrWhiteSpace(sha) ? "unknown" : sha.Substring(0, Math.Min(8, sha.Length));
            }

            private static string TrimForError(string text)
            {
                if (string.IsNullOrWhiteSpace(text)) return "brak treści odpowiedzi";
                text = text.Replace("\r", " ").Replace("\n", " ").Trim();
                return text.Length <= 300 ? text : text.Substring(0, 300) + "...";
            }
        }
    }
}

