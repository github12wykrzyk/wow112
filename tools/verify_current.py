#!/usr/bin/env python3
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ERRORS = []
WARNINGS = []


def error(msg):
    ERRORS.append(msg)
    print("ERROR: " + msg)


def warning(msg):
    WARNINGS.append(msg)
    print("WARNING: " + msg)


def load_json(rel):
    path = ROOT / rel
    if not path.is_file():
        error("missing file: %s" % rel)
        return None
    try:
        with path.open("r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as exc:
        error("invalid JSON %s: %s" % (rel, exc))
        return None


def require_file(rel):
    if not rel or not (ROOT / rel).is_file():
        error("missing file: %s" % rel)
        return False
    return True


def require_dir(rel):
    if not rel or not (ROOT / rel).is_dir():
        error("missing directory: %s" % rel)
        return False
    return True


def file_sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_nonempty_lines(rel):
    path = ROOT / rel
    if not path.is_file():
        error("missing list file: %s" % rel)
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def parse_sha256(rel):
    result = {}
    path = ROOT / rel
    if not path.is_file():
        error("missing SHA256 manifest: %s" % rel)
        return result
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2 or len(parts[0]) != 64:
            error("bad SHA256 line in %s: %s" % (rel, raw))
            continue
        name = parts[1].strip()
        if name in result:
            error("duplicate SHA256 manifest entry: %s" % name)
        result[name] = parts[0].lower()
    return result


def tracked_files():
    try:
        data = subprocess.check_output(["git", "ls-files"], cwd=str(ROOT), stderr=subprocess.STDOUT, text=True)
        return [line.strip() for line in data.splitlines() if line.strip()]
    except Exception as exc:
        warning("could not run git ls-files: %s" % exc)
        return []


def verify_ai_contract(index, current):
    if index.get("schema_version") != 1:
        error("AI_INDEX.json schema_version must be 1")
    target = index.get("target", {})
    if target.get("version") != "1.12.1" or target.get("build") != 5875 or target.get("architecture") != "x86":
        error("AI_INDEX.json target must be WoW 1.12.1 build 5875 x86")
    branches = index.get("branches", {})
    if branches.get("stable") != current.get("stable_branch"):
        error("AI_INDEX stable branch does not match CURRENT.json")
    if branches.get("development") != current.get("working_branch"):
        error("AI_INDEX development branch does not match CURRENT.json")
    canonical = index.get("canonical", {})
    if canonical.get("current_state") != "CURRENT.json":
        error("AI_INDEX canonical current_state must be CURRENT.json")
    if canonical.get("runtime_manifest") != current.get("runtime_manifest"):
        error("AI_INDEX runtime pointer does not match CURRENT.json")
    if canonical.get("source_root") != current.get("canonical_source_root"):
        error("AI_INDEX source_root does not match CURRENT.json")
    for rel in index.get("read_order", []):
        require_file(rel)
    for key in ("source_inventory", "project_rules"):
        rel = canonical.get(key)
        if rel:
            require_file(rel)
    require_dir(canonical.get("source_root"))
    if current.get("ai_entrypoint") != "AI_START_HERE.md":
        error("CURRENT.json ai_entrypoint must be AI_START_HERE.md")
    if current.get("ai_index") != "AI_INDEX.json":
        error("CURRENT.json ai_index must be AI_INDEX.json")


def verify_exe(current, runtime, sha_manifest):
    current_exe = current.get("exe", {})
    runtime_exe = runtime.get("exe", {})
    name = current_exe.get("name")
    rel = current_exe.get("path")
    expected_hash = str(current_exe.get("sha256", "")).lower()
    expected_size = current_exe.get("size")
    if runtime_exe.get("name") != name:
        error("EXE name mismatch between CURRENT.json and runtime/current.json")
    if str(runtime_exe.get("sha256", "")).lower() != expected_hash:
        error("EXE SHA256 mismatch between CURRENT.json and runtime/current.json")
    if current_exe.get("storage") != "direct_binary":
        error("CURRENT.json EXE storage must be direct_binary")
    manifest_hash = sha_manifest.get(name)
    if manifest_hash is None:
        error("canonical EXE missing from SHA256 manifest: %s" % name)
    elif manifest_hash != expected_hash:
        error("canonical EXE hash differs between CURRENT.json and SHA256 manifest")
    if not rel or not require_file(rel):
        return
    path = ROOT / rel
    actual_hash = file_sha256(path)
    if len(expected_hash) != 64:
        error("CURRENT.json EXE SHA256 is invalid")
    elif actual_hash != expected_hash:
        error("canonical EXE file SHA256 mismatch: %s" % rel)
    if not isinstance(expected_size, int) or expected_size <= 0:
        error("CURRENT.json EXE size is invalid")
    elif path.stat().st_size != expected_size:
        error("canonical EXE size mismatch: got %d expected %d" % (path.stat().st_size, expected_size))


def verify_source_item(item):
    name = item.get("name", "<unnamed>")
    state = item.get("source_state")
    allowed = {
        "normal_source",
        "not_indexed_in_repo",
        "binary_verified_reconstruction",
        "functionally_equivalent_reconstruction",
        "exact_source_archived",
    }
    if state not in allowed:
        error("active DLL has invalid source_state: %s (%r)" % (name, state))
        return
    source_path = item.get("source_path")
    source_hash = str(item.get("source_sha256", "")).lower()
    source_size = item.get("source_size")
    if state == "normal_source" and not source_path:
        error("normal_source DLL missing source_path: %s" % name)
    if source_path:
        normalized = source_path.replace("\\", "/")
        if not normalized.startswith("src/"):
            error("active canonical source_path must live under src/: %s -> %s" % (name, source_path))
        if require_file(source_path):
            path = ROOT / source_path
            if source_hash:
                if len(source_hash) != 64:
                    error("invalid source_sha256: %s" % name)
                elif file_sha256(path) != source_hash:
                    error("source SHA256 mismatch: %s -> %s" % (name, source_path))
            elif state == "normal_source":
                warning("normal source has no source_sha256: %s" % name)
            if source_size is not None:
                if not isinstance(source_size, int) or source_size <= 0:
                    error("invalid source_size: %s" % name)
                elif path.stat().st_size != source_size:
                    error("source size mismatch: %s got %d expected %d" % (name, path.stat().st_size, source_size))
    for field in ("source_restore_doc", "binary_patch_audit", "binary_reproducer", "source_archive", "source_restore_tool"):
        rel = item.get(field)
        if rel:
            require_file(rel)
    prefix = item.get("source_archive_prefix")
    if prefix and not list(ROOT.glob(prefix + "*")):
        error("source archive parts missing: %s -> %s*" % (name, prefix))


def verify_runtime(current, runtime, sha_manifest):
    if current.get("stable_baseline") != runtime.get("baseline"):
        error("baseline mismatch: CURRENT.json=%s runtime/current.json=%s" % (current.get("stable_baseline"), runtime.get("baseline")))
    if runtime.get("wow_build") != 5875:
        error("runtime/current.json wow_build must be 5875")
    dll_names = read_nonempty_lines(current.get("active_dll_list"))
    items = runtime.get("active_dlls", [])
    runtime_names = [x.get("name") for x in items if isinstance(x, dict)]
    if len(items) != len(runtime_names):
        error("runtime/current.json active_dlls contains non-object entries")
    if runtime_names != dll_names:
        error("active DLL order/content differs between dlls.txt and runtime/current.json")
    seen = set()
    for item in items:
        if not isinstance(item, dict):
            continue
        name = item.get("name")
        expected = str(item.get("sha256", "")).lower()
        if not name:
            error("active DLL missing name")
            continue
        if name in seen:
            error("duplicate active DLL in runtime/current.json: %s" % name)
        seen.add(name)
        if len(expected) != 64:
            error("active DLL has invalid SHA256: %s" % name)
        manifest_hash = sha_manifest.get(name)
        if manifest_hash is None:
            error("active DLL missing from SHA256 manifest: %s" % name)
        elif manifest_hash != expected:
            error("active DLL hash differs between runtime and SHA256 manifest: %s" % name)
        verify_source_item(item)
    return len(items)


def verify_current_metadata(current):
    required = (
        "project", "wow_version", "wow_build", "architecture", "stable_baseline", "status",
        "working_branch", "stable_branch", "baseline_dir", "active_dll_list", "runtime_manifest",
        "sha256_manifest", "current_version_doc", "canonical_source_root", "ai_entrypoint", "ai_index", "exe",
    )
    for key in required:
        if current.get(key) in (None, ""):
            error("CURRENT.json missing required key: %s" % key)
    if current.get("wow_version") != "1.12.1" or current.get("wow_build") != 5875 or current.get("architecture") != "x86":
        error("CURRENT.json target must be WoW 1.12.1 build 5875 x86")
    require_dir(current.get("baseline_dir"))
    require_file(current.get("active_dll_list"))
    require_file(current.get("runtime_manifest"))
    require_file(current.get("sha256_manifest"))
    require_file(current.get("current_version_doc"))
    require_dir(current.get("canonical_source_root"))
    require_file(current.get("ai_entrypoint"))
    require_file(current.get("ai_index"))


def main():
    index = load_json("AI_INDEX.json")
    current = load_json("CURRENT.json")
    if index is None or current is None:
        return 1
    verify_current_metadata(current)
    verify_ai_contract(index, current)
    runtime = load_json(current.get("runtime_manifest", "runtime/current.json"))
    if runtime is None:
        return 1
    sha_manifest = parse_sha256(current.get("sha256_manifest", ""))
    active_count = verify_runtime(current, runtime, sha_manifest)
    verify_exe(current, runtime, sha_manifest)
    banned_suffixes = (".log", ".dmp", ".mdmp")
    for rel in tracked_files():
        if rel.lower().endswith(banned_suffixes):
            error("tracked runtime/debug artifact should not be in Git: %s" % rel)
    print("\nFast current-state verification summary")
    print("  target: WoW 1.12.1 build 5875 x86")
    print("  baseline: %s" % current.get("stable_baseline"))
    print("  active DLLs: %d" % active_count)
    print("  canonical source root: %s" % current.get("canonical_source_root"))
    print("  AI entrypoint: %s" % current.get("ai_entrypoint"))
    print("  warnings: %d" % len(WARNINGS))
    print("  errors: %d" % len(ERRORS))
    if ERRORS:
        print("RESULT: FAIL")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
