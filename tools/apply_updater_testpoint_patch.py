from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, got {count}: {old!r}")
    p.write_text(text.replace(old, new, 1), encoding="utf-8")


replace_once(
    "tools/updater/WoW112Updater.cs",
    'var branch = "parallel";',
    'var branch = "parallel-testpoint";'
)
replace_once(
    "tools/updater/WoW112Updater.cs",
    'await GetStringAsync(client, ApiRoot + "/branches/parallel")))',
    'await GetStringAsync(client, ApiRoot + "/branches/parallel-testpoint")))'
)
replace_once(
    "tools/updater/WoW112Updater.cs",
    'var url = ApiRoot + "/actions/runs?branch=" + branch + "&per_page=50";\n                var root = AsDictionary(json.DeserializeObject(await GetStringAsync(client, url)));\n                var runs = AsArray(GetValue(root, "workflow_runs"));\n                var exact = UpdaterSafety.FindRunForHead(runs, workflowName, branch, trackedHead);',
    'var runBranch = string.Equals(branch, "parallel-testpoint", StringComparison.Ordinal) ? "parallel" : branch;\n                var url = ApiRoot + "/actions/runs?branch=" + runBranch + "&per_page=50";\n                var root = AsDictionary(json.DeserializeObject(await GetStringAsync(client, url)));\n                var runs = AsArray(GetValue(root, "workflow_runs"));\n                var exact = UpdaterSafety.FindRunForHead(runs, workflowName, runBranch, trackedHead);'
)
replace_once(
    "tools/updater/WoW112Updater.cs",
    'return UpdaterSafety.RequireSuccessfulRunForHead(runs, workflowName, branch, trackedHead);',
    'return UpdaterSafety.RequireSuccessfulRunForHead(runs, workflowName, runBranch, trackedHead);'
)
replace_once(
    "tools/updater/WoW112Updater.cs",
    'runs, workflowName, branch, trackedHead);',
    'runs, workflowName, runBranch, trackedHead);'
)
replace_once(
    "tools/updater/UpdaterEconomyFeature.cs",
    'var url = ApiRoot + "/actions/workflows/" + EconomyWorkflowFile + "/runs?branch=" + branch + "&per_page=20";\n                var root = AsDictionary(json.DeserializeObject(await GetStringAsync(client, url)));\n                var runs = AsArray(GetValue(root, "workflow_runs"));\n                var exact = UpdaterSafety.FindRunForHead(runs, EconomyWorkflowName, branch, trackedHead);',
    'var runBranch = string.Equals(branch, "parallel-testpoint", StringComparison.Ordinal) ? "parallel" : branch;\n                var url = ApiRoot + "/actions/workflows/" + EconomyWorkflowFile + "/runs?branch=" + runBranch + "&per_page=20";\n                var root = AsDictionary(json.DeserializeObject(await GetStringAsync(client, url)));\n                var runs = AsArray(GetValue(root, "workflow_runs"));\n                var exact = UpdaterSafety.FindRunForHead(runs, EconomyWorkflowName, runBranch, trackedHead);'
)
replace_once(
    "tools/updater/UpdaterEconomyFeature.cs",
    'return UpdaterSafety.RequireSuccessfulRunForHead(runs, EconomyWorkflowName, branch, trackedHead);',
    'return UpdaterSafety.RequireSuccessfulRunForHead(runs, EconomyWorkflowName, runBranch, trackedHead);'
)
replace_once(
    "tools/updater/UpdaterSafety.cs",
    'public const string Version = "2.10-parallel.2";',
    'public const string Version = "2.10-parallel.3";'
)
replace_once(
    "tools/updater/UpdaterSafety.cs",
    '"HEAD parallel zmienił się lub jest nieprawidłowy (paczka: " +',
    '"Punkt dostawy parallel-testpoint zmienił się lub jest nieprawidłowy (paczka: " +'
)
replace_once(
    "src/AddOns/SummonScout/SummonScout_PostPaymentOfferHot.lua",
    'DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SummonScout PING]|r direct-prefix hot-test received")',
    'DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SummonScout PING]|r updater-testpoint-ping-v1 received")'
)

print("PATCH_OK")
