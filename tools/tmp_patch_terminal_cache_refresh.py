from pathlib import Path

path = Path('tools/updater/UpdaterWindowsTerminalPortalFeature.cs')
text = path.read_text(encoding='utf-8')

old1 = '''            TerminalWindowsBundle cached;
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
'''
new1 = '''            TerminalWindowsBundle cached;
            var cachedValid = TryLoadTerminalWindowsCachedBinary(dest, stamp, out cached);
            if (string.IsNullOrWhiteSpace(token.Text))
            {
                if (cachedValid)
                {
                    Log("TERMINAL WIN: LOCAL CACHE VERIFIED " + cached.GitSha.Substring(0, 8) + " / " + cached.Sha256.Substring(0, 12) + "…; brak tokenu — pomijam tylko sprawdzenie aktualizacji.");
                    return cached;
                }
                throw new InvalidOperationException("Brak lokalnego workera Windows. Wpisz token GitHub jednorazowo, aby pobrać i zweryfikować cache.");
            }

            using (var client = CreateClient())
            {
'''
if text.count(old1) != 1:
    raise SystemExit(f'expected cache-first block exactly once, found {text.count(old1)}')
text = text.replace(old1, new1, 1)

old2 = '''                var runsUrl = ApiRoot + "/actions/workflows/" + TerminalWindowsWorkflow + "/runs?branch=parallel&per_page=20";
                var runsRoot = AsDictionary(json.DeserializeObject(await GetStringAsync(client, runsUrl)));
                var runs = AsArray(GetValue(runsRoot, "workflow_runs"));
                var run = UpdaterSafety.RequireLatestSuccessfulRun(runs, TerminalWindowsWorkflowName, "parallel");
                var runId = GetLong(run, "id");
                var runSha = GetString(run, "head_sha");
                if (string.IsNullOrWhiteSpace(runSha)) throw new InvalidDataException("Windows workflow nie podał head_sha.");

'''
new2 = '''                long runId;
                string runSha;
                try
                {
                    var runsUrl = ApiRoot + "/actions/workflows/" + TerminalWindowsWorkflow + "/runs?branch=parallel&per_page=20";
                    var runsRoot = AsDictionary(json.DeserializeObject(await GetStringAsync(client, runsUrl)));
                    var runs = AsArray(GetValue(runsRoot, "workflow_runs"));
                    var run = UpdaterSafety.RequireLatestSuccessfulRun(runs, TerminalWindowsWorkflowName, "parallel");
                    runId = GetLong(run, "id");
                    runSha = GetString(run, "head_sha");
                    if (string.IsNullOrWhiteSpace(runSha)) throw new InvalidDataException("Windows workflow nie podał head_sha.");
                }
                catch (Exception ex)
                {
                    if (!cachedValid) throw;
                    Log("TERMINAL WIN: update check FAILED; używam zweryfikowanego cache " + cached.GitSha.Substring(0, 8) + ": " + ShortTerminalText(ex.Message, 160));
                    return cached;
                }

                if (cachedValid && string.Equals(cached.GitSha, runSha, StringComparison.OrdinalIgnoreCase))
                {
                    Log("TERMINAL WIN: CACHE CURRENT " + cached.GitSha.Substring(0, 8) + " / latest successful run " + runId + "; download pominięty.");
                    return cached;
                }
                if (cachedValid)
                    Log("TERMINAL WIN: CACHE STALE " + cached.GitSha.Substring(0, 8) + " -> " + runSha.Substring(0, Math.Min(8, runSha.Length)) + "; pobieram aktualny worker.");
                else
                    Log("TERMINAL WIN: cache MISS/INVALID; pobieram zweryfikowany native artifact z GitHub.");

'''
if text.count(old2) != 1:
    raise SystemExit(f'expected workflow lookup block exactly once, found {text.count(old2)}')
text = text.replace(old2, new2, 1)
path.write_text(text, encoding='utf-8')
print('cache refresh exact replacements PASS')
