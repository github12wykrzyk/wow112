#!/usr/bin/env python3
"""Run branch-local fast gates and compile only native sources changed vs integration base."""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "runtime/current.json"
MANIFEST = ROOT / "runtime/parallel_candidate.json"

CORE_NATIVE_GATES = [
    ["tools/verify_current.py"],
    ["tools/verify_runtime_artifacts.py"],
    ["tools/verify_verified_symbols.py"],
    ["tools/verify_parallel_dependency_registry.py"],
    ["tools/verify_candidate_source_scope.py"],
    ["tools/verify_parallel_candidate_manifest.py"],
]

INFRA_EXACT = {
    "CURRENT.json",
    "AI_INDEX.json",
    "runtime/current.json",
    "runtime/work_candidate.json",
    "runtime/parallel_candidate.json",
    "runtime/parallel_economy.json",
    "runtime/parallel_dependency_registry.json",
    "runtime/parallel_integration_policy.json",
    "runtime/parallel_testpoint_policy.json",
    "runtime/parallel_thread_policy.json",
    "runtime/work_base_dlls.txt",
}

ECONOMY_PREFIXES = (
    "src/AHThrottleNative/",
    "src/AddOns/AuxEconomyShadow/",
    "src/AddOns/AuxVmangos/",
    "AuxVmangos/",
    "addons/AuxVmangos/",
    "AHThrottleTest/",
    "addons/AHThrottleTest/",
    "AuxFastBridge/",
    "addons/AuxFastBridge/",
)

SUMMON_PREFIXES = (
    "src/AddOns/SummonScout/",
)

GUI_PREFIXES = (
    "src/WoWPlayerESP/",
)

TARGET_AURA_PREFIXES = (
    "src/TargetAura",
    "src/LazyScript/",
)

NATIVE_SUFFIXES = (".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".asm", ".s")


def run(args):
    cmd = [sys.executable, *args]
    print("RUN:", " ".join(cmd))
    result = subprocess.run(cmd, cwd=ROOT)
    if result.returncode:
        raise SystemExit(result.returncode)


def git(args, check=True):
    result = subprocess.run(
        ["git", *args], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if check and result.returncode:
        raise RuntimeError("git %s failed: %s" % (" ".join(args), result.stderr.strip()))
    return result


def merge_base_once(base):
    result = git(["merge-base", base, "HEAD"], check=False)
    value = result.stdout.strip()
    if result.returncode == 0 and len(value) == 40:
        return value
    return None


def remote_branch_from_base(base):
    for prefix in ("refs/remotes/origin/", "origin/"):
        if base.startswith(prefix):
            return base[len(prefix):]
    return None


def ensure_merge_base(base, branch):
    """Prefer shallow history; deepen only when the feature fork point is missing."""
    value = merge_base_once(base)
    if value:
        return value

    shallow = git(["rev-parse", "--is-shallow-repository"], check=False).stdout.strip().lower() == "true"
    if not shallow:
        raise RuntimeError("cannot resolve merge-base between %s and HEAD" % base)

    base_branch = remote_branch_from_base(base)
    refspecs = []
    if branch and branch.startswith("feature/"):
        refspecs.append("+refs/heads/%s:refs/remotes/origin/%s" % (branch, branch))
    if base_branch:
        refspecs.append("+refs/heads/%s:refs/remotes/origin/%s" % (base_branch, base_branch))
    if not refspecs:
        raise RuntimeError("cannot deepen shallow checkout safely for base %s" % base)

    for deepen in (32, 128, 512):
        print("PARALLEL_FEATURE_PREFLIGHT: shallow merge-base missing; deepen=%d" % deepen)
        result = git(["fetch", "--deepen=%d" % deepen, "origin", *refspecs], check=False)
        if result.returncode:
            print("PARALLEL_FEATURE_PREFLIGHT: deepen fetch warning: " + result.stderr.strip())
        value = merge_base_once(base)
        if value:
            print("PARALLEL_FEATURE_PREFLIGHT: merge-base recovered without full history")
            return value

    print("PARALLEL_FEATURE_PREFLIGHT: shallow fallback -> full relevant refs")
    # --unshallow can reject explicit refspecs on some Git versions. First
    # complete the shallow repository, then refresh just feature/base refs.
    result = git(["fetch", "--unshallow", "origin"], check=False)
    if result.returncode:
        print("PARALLEL_FEATURE_PREFLIGHT: unshallow warning: " + result.stderr.strip())
    git(["fetch", "origin", *refspecs], check=True)
    value = merge_base_once(base)
    if not value:
        raise RuntimeError("cannot resolve merge-base after safe shallow fallback")
    return value


def diff_paths(base, branch):
    merge_base = ensure_merge_base(base, branch)
    raw = git(["diff", "--name-only", merge_base, "HEAD"]).stdout
    return sorted({x.strip().replace("\\", "/") for x in raw.splitlines() if x.strip()}), merge_base


def resolve_branch(explicit):
    if explicit:
        return explicit
    env_branch = os.environ.get("GITHUB_HEAD_REF") or os.environ.get("GITHUB_REF_NAME")
    if env_branch:
        return env_branch
    return git(["branch", "--show-current"]).stdout.strip()


def has_prefix(changed, prefixes):
    return any(any(path.startswith(prefix) for prefix in prefixes) for path in changed)


def changed_native(changed):
    return any(path.startswith("src/") and path.lower().endswith(NATIVE_SUFFIXES) for path in changed)


def infrastructure_changed(changed):
    return any(
        path.startswith("tools/")
        or path.startswith(".github/")
        or path in INFRA_EXACT
        or path.startswith("runtime/ai_")
        for path in changed
    )


def select_gates(changed):
    """Return only gates whose protected subsystem can be affected by this diff."""
    selected = []
    reasons = []
    infra = infrastructure_changed(changed)
    native = changed_native(changed)

    if infra or native:
        selected.extend(CORE_NATIVE_GATES)
        reasons.append("core/native")

    economy = has_prefix(changed, ECONOMY_PREFIXES) or any(
        path in {"runtime/parallel_economy.json", "tools/verify_parallel_economy_manifest.py"}
        for path in changed
    )
    if economy or infra:
        selected.append(["tools/verify_parallel_economy_manifest.py"])
        reasons.append("economy")

    autosell = has_prefix(changed, ("src/AddOns/AuxVmangos/", "AuxVmangos/", "addons/AuxVmangos/"))
    if autosell or infra:
        selected.append(["tools/verify_auxvmangos_autosell_contract.py"])
        reasons.append("aux-autosell")

    gui = has_prefix(changed, GUI_PREFIXES)
    if gui or infra:
        selected.extend([
            ["tools/verify_parallel_gui_abi.py"],
            ["tools/verify_parallel_gui_contract.py"],
        ])
        reasons.append("playeresp-gui")

    summon = has_prefix(changed, SUMMON_PREFIXES)
    if summon or infra:
        selected.append(["tools/verify_summonscout_lua_upvalues.py"])
        reasons.append("summonscout")

    target_aura = has_prefix(changed, TARGET_AURA_PREFIXES)
    if target_aura or infra:
        selected.append(["tools/verify_target_aura_lazyscript_bridge.py"])
        reasons.append("target-aura/lazyscript")

    ai_ledger = any(path == "runtime/ai_experiments.json" or path == "tools/ai_experiments.py" for path in changed)
    if ai_ledger or infra:
        selected.append(["tools/ai_experiments.py", "validate"])
        reasons.append("ai-routing")

    deduped = []
    seen = set()
    for gate in selected:
        key = tuple(gate)
        if key not in seen:
            seen.add(key)
            deduped.append(gate)
    return deduped, sorted(set(reasons)), infra


def verify_changed_text(changed):
    """Cheap fail-closed sanity for edited text payloads before subsystem gates."""
    text_suffixes = (".lua", ".py", ".yml", ".yaml", ".json", ".md", ".txt", ".c", ".h")
    checked = 0
    for rel in changed:
        if not rel.lower().endswith(text_suffixes):
            continue
        path = ROOT / rel
        if not path.is_file():
            continue
        data = path.read_bytes()
        if b"\x00" in data:
            raise SystemExit("PARALLEL_FEATURE_PREFLIGHT: FAIL NUL byte in " + rel)
        text = data.decode("utf-8")
        if any(marker in text for marker in ("<<<<<<< ", "=======\n", ">>>>>>> ")):
            raise SystemExit("PARALLEL_FEATURE_PREFLIGHT: FAIL unresolved merge marker in " + rel)
        checked += 1
    print("PARALLEL_FEATURE_PREFLIGHT: text_sanity=%d" % checked)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="origin/parallel")
    ap.add_argument("--branch")
    args = ap.parse_args()

    branch = resolve_branch(args.branch)
    changed, merge_base = diff_paths(args.base, branch)
    print("PARALLEL_FEATURE_PREFLIGHT: merge_base=" + merge_base)
    print("PARALLEL_FEATURE_PREFLIGHT: branch=" + (branch or "<detached>"))
    print("PARALLEL_FEATURE_PREFLIGHT: changed=" + json.dumps(changed))

    if branch.startswith("feature/"):
        run([
            "tools/parallel_task_state.py",
            "feature-check",
            "--branch", branch,
            "--merge-base", merge_base,
        ])
        run([
            "tools/parallel_task_state.py",
            "profile-check",
            "--branch", branch,
            "--merge-base", merge_base,
            "--changed-json", json.dumps(changed, separators=(",", ":")),
        ])

    verify_changed_text(changed)
    gates, reasons, infra = select_gates(changed)
    print("PARALLEL_FEATURE_PREFLIGHT: routed_reasons=" + (",".join(reasons) if reasons else "minimal"))
    print("PARALLEL_FEATURE_PREFLIGHT: routed_gates=" + json.dumps([" ".join(x) for x in gates]))

    # The AI/workflow unit suite protects orchestration code, not every gameplay
    # Lua/native micro-iteration. Run it only when orchestration itself changes.
    if infra:
        run(["-m", "unittest", "discover", "-s", "tools", "-p", "test_ai_*.py", "-v"])
    else:
        print("PARALLEL_FEATURE_PREFLIGHT: SKIP global test_ai_* (no infra/tooling diff)")

    for gate in gates:
        run(gate)

    runtime = json.loads(RUNTIME.read_text(encoding="utf-8"))
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    force_active = any(
        p.startswith("src/common/") or p in ("tools/build_active_module.py", "runtime/current.json")
        for p in changed
    )
    active = []
    for item in runtime.get("active_dlls", []):
        source = item.get("source_path")
        recipe = item.get("build_recipe")
        if not source or not isinstance(recipe, dict) or not recipe.get("profile"):
            continue
        source = source.replace("\\", "/")
        if force_active or source in changed:
            active.append((source, item["name"]))

    for source, name in active:
        safe = "".join(c if c.isalnum() or c in "._-" else "_" for c in name)
        run([
            "tools/build_active_module.py", "--name", name,
            "--output", "build/preflight/" + name,
            "--metadata", "build/preflight/" + safe + ".json",
        ])

    force_companions = any(
        p in ("tools/build_parallel_companion.py", "runtime/parallel_candidate.json")
        or p.startswith("src/common/")
        for p in changed
    )
    companions = []
    for item in manifest.get("companions", []):
        sources = [x.replace("\\", "/") for x in item.get("sources", [])]
        if force_companions or any(x in changed for x in sources):
            companions.append(item["runtime_name"])

    for name in companions:
        safe = "".join(c if c.isalnum() or c in "._-" else "_" for c in name)
        run([
            "tools/build_parallel_companion.py", "--name", name,
            "--output", "build/preflight/" + name,
            "--metadata", "build/preflight/" + safe + ".json",
        ])

    print(
        "PARALLEL_FEATURE_PREFLIGHT: PASS "
        + f"(mode={'infra' if infra else 'targeted'}, gates={len(gates)}, "
        + f"active_builds={len(active)}, companion_builds={len(companions)})"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as exc:
        print("PARALLEL_FEATURE_PREFLIGHT: FAIL: " + str(exc), file=sys.stderr)
        sys.exit(1)
