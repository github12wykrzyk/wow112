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


def require_path(rel, kind="file"):
    path = ROOT / rel
    ok = path.is_file() if kind == "file" else path.is_dir()
    if not ok:
        error("missing %s: %s" % (kind, rel))
    return ok


def parse_sha256(rel):
    out = {}
    path = ROOT / rel
    if not path.is_file():
        error("missing SHA256 manifest: %s" % rel)
        return out
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2 or len(parts[0]) != 64:
            error("bad SHA256 line in %s: %s" % (rel, raw))
            continue
        out[parts[1].strip()] = parts[0].lower()
    return out


def read_nonempty_lines(rel):
    path = ROOT / rel
    if not path.is_file():
        error("missing list file: %s" % rel)
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def tracked_files():
    try:
        data = subprocess.check_output(
            ["git", "ls-files"], cwd=str(ROOT), stderr=subprocess.STDOUT, text=True
        )
        return [x.strip() for x in data.splitlines() if x.strip()]
    except Exception as exc:
        warning("could not run git ls-files: %s" % exc)
        return []


def verify_movementcore_archive():
    tool = ROOT / "tools" / "restore_movementcore_source.py"
    if not tool.is_file():
        error("missing MovementCore restore verifier: tools/restore_movementcore_source.py")
        return
    try:
        proc = subprocess.run(
            [sys.executable, str(tool), "--verify-only"],
            cwd=str(ROOT),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
        )
    except Exception as exc:
        error("MovementCore source verification could not run: %s" % exc)
        return
    print(proc.stdout.rstrip())
    if proc.returncode != 0:
        error("canonical V68 MovementCore source archive failed verification")


def verify_movementcore_source(mc, runtime_dlls):
    if mc.get("source_state") != "normal_source":
        error("MovementCore source_state must be normal_source")
        return

    rel = mc.get("source_path")
    expected_hash = str(mc.get("source_sha256", "")).lower()
    expected_size = mc.get("source_size")
    if not rel:
        error("MovementCore source_path missing from CURRENT.json")
        return
    path = ROOT / rel
    if not path.is_file():
        error("canonical MovementCore source file missing: %s" % rel)
        return
    data = path.read_bytes()
    actual_hash = hashlib.sha256(data).hexdigest()
    if len(expected_hash) != 64:
        error("invalid MovementCore source_sha256 in CURRENT.json")
    elif actual_hash != expected_hash:
        error("canonical MovementCore source SHA256 mismatch")
    if not isinstance(expected_size, int) or expected_size <= 0:
        error("invalid MovementCore source_size in CURRENT.json")
    elif len(data) != expected_size:
        error("canonical MovementCore source size mismatch: got %d expected %d" % (len(data), expected_size))

    runtime_item = None
    runtime_name = mc.get("runtime_name")
    for item in runtime_dlls:
        if isinstance(item, dict) and item.get("name") == runtime_name:
            runtime_item = item
            break
    if runtime_item is None:
        error("MovementCore runtime entry not found in runtime/current.json")
        return
    if runtime_item.get("source_state") != "normal_source":
        error("MovementCore runtime source_state is not normal_source")
    if runtime_item.get("source_path") != rel:
        error("MovementCore source_path mismatch between CURRENT.json and runtime/current.json")
    if str(runtime_item.get("source_sha256", "")).lower() != expected_hash:
        error("MovementCore source_sha256 mismatch between CURRENT.json and runtime/current.json")


def verify_canonical_exe(current, runtime, sha_manifest):
    current_exe = current.get("exe", {})
    runtime_exe = runtime.get("exe", {})

    name = current_exe.get("name")
    rel = current_exe.get("path")
    expected_hash = str(current_exe.get("sha256", "")).lower()
    expected_size = current_exe.get("size")
    storage = current_exe.get("storage")

    if not name:
        error("CURRENT.json canonical EXE name is missing")
        return
    if not rel:
        error("CURRENT.json canonical EXE path is missing")
        return
    if Path(rel).name != name:
        error("CURRENT.json EXE path/name mismatch")
    if len(expected_hash) != 64:
        error("CURRENT.json canonical EXE SHA256 is invalid")
    if not isinstance(expected_size, int) or expected_size <= 0:
        error("CURRENT.json canonical EXE size is invalid")
    if storage != "direct_binary":
        error("CURRENT.json canonical EXE storage must be direct_binary")

    if runtime_exe.get("name") != name:
        error("EXE name mismatch between CURRENT.json and runtime/current.json")
    if str(runtime_exe.get("sha256", "")).lower() != expected_hash:
        error("EXE SHA256 mismatch between CURRENT.json and runtime/current.json")

    manifest_hash = sha_manifest.get(name)
    if manifest_hash is None:
        error("canonical EXE missing from SHA256 manifest: %s" % name)
    elif manifest_hash != expected_hash:
        error("canonical EXE SHA256 mismatch between CURRENT.json and SHA256 manifest")

    path = ROOT / rel
    if not path.is_file():
        error("canonical EXE binary missing: %s" % rel)
        return

    data = path.read_bytes()
    actual_hash = hashlib.sha256(data).hexdigest()
    if len(expected_hash) == 64 and actual_hash != expected_hash:
        error("canonical EXE file SHA256 mismatch: got %s expected %s" % (actual_hash, expected_hash))
    if isinstance(expected_size, int) and expected_size > 0 and len(data) != expected_size:
        error("canonical EXE file size mismatch: got %d expected %d" % (len(data), expected_size))


def verify_source_inventory(runtime_dlls):
    allowed = {
        "normal_source",
        "not_indexed_in_repo",
        "binary_verified_reconstruction",
        "functionally_equivalent_reconstruction",
        "exact_source_archived",
    }
    normal = []
    reconstructed = []
    not_indexed = []

    for item in runtime_dlls:
        if not isinstance(item, dict):
            continue

        name = item.get("name", "<unnamed>")
        state = item.get("source_state")
        if state not in allowed:
            error("active DLL has missing/invalid source_state: %s (%r)" % (name, state))
            continue

        if state == "normal_source":
            normal.append(name)
            source_path = item.get("source_path")
            source_hash = str(item.get("source_sha256", "")).lower()
            if not source_path:
                error("normal_source DLL missing source_path: %s" % name)
            elif not (ROOT / source_path).is_file():
                error("normal_source DLL source file missing: %s -> %s" % (name, source_path))
            if len(source_hash) != 64:
                error("normal_source DLL missing/invalid source_sha256: %s" % name)
            continue

        if state == "not_indexed_in_repo":
            not_indexed.append(name)
            continue

        reconstructed.append(name)

        source_path = item.get("source_path")
        if source_path and not (ROOT / source_path).is_file():
            error("reconstructed source file missing: %s -> %s" % (name, source_path))

        restore_doc = item.get("source_restore_doc")
        if restore_doc and not (ROOT / restore_doc).is_file():
            error("source restore doc missing: %s -> %s" % (name, restore_doc))

        binary_audit = item.get("binary_patch_audit")
        if binary_audit and not (ROOT / binary_audit).is_file():
            error("binary audit missing: %s -> %s" % (name, binary_audit))

        reproducer = item.get("binary_reproducer")
        if reproducer and not (ROOT / reproducer).is_file():
            error("binary reproducer missing: %s -> %s" % (name, reproducer))

        archive = item.get("source_archive")
        if archive and not (ROOT / archive).is_file():
            error("source archive missing: %s -> %s" % (name, archive))

        archive_prefix = item.get("source_archive_prefix")
        if archive_prefix:
            matches = list(ROOT.glob(archive_prefix + "*"))
            if not matches:
                error("source archive parts missing: %s -> %s*" % (name, archive_prefix))

    require_path("docs/SOURCE_INVENTORY.md")
    if not_indexed:
        warning("%d/%d active DLLs do not yet have indexed source; see docs/SOURCE_INVENTORY.md" % (
            len(not_indexed), len(runtime_dlls)
        ))
    return len(normal), len(reconstructed), len(not_indexed)


def main():
    current = load_json("CURRENT.json")
    runtime = load_json("runtime/current.json")
    if current is None or runtime is None:
        return 1

    required_current = [
        "stable_baseline",
        "baseline_dir",
        "active_dll_list",
        "runtime_manifest",
        "sha256_manifest",
        "exe",
    ]
    for key in required_current:
        if not current.get(key):
            error("CURRENT.json missing required key: %s" % key)

    if current.get("wow_version") != "1.12.1" or current.get("wow_build") != 5875:
        error("CURRENT.json must target WoW 1.12.1 build 5875")
    if current.get("architecture") != "x86":
        error("CURRENT.json architecture must be x86")

    if current.get("stable_baseline") != runtime.get("baseline"):
        error("baseline mismatch: CURRENT.json=%s runtime/current.json=%s" % (
            current.get("stable_baseline"), runtime.get("baseline")
        ))

    baseline_dir = current.get("baseline_dir", "")
    require_path(baseline_dir, "dir")
    require_path(current.get("active_dll_list", ""))
    require_path(current.get("sha256_manifest", ""))
    require_path(current.get("current_version_doc", "CURRENT_VERSION.md"))

    dll_file_names = read_nonempty_lines(current.get("active_dll_list", ""))
    runtime_dlls = runtime.get("active_dlls", [])
    manifest_names = [x.get("name") for x in runtime_dlls if isinstance(x, dict)]

    if dll_file_names != manifest_names:
        error("active DLL list does not exactly match runtime/current.json order/content")
        print("  dlls.txt: %r" % dll_file_names)
        print("  runtime : %r" % manifest_names)

    sha = parse_sha256(current.get("sha256_manifest", ""))
    for item in runtime_dlls:
        if not isinstance(item, dict):
            error("runtime active_dlls contains non-object entry")
            continue
        name = item.get("name")
        expected = str(item.get("sha256", "")).lower()
        if not name or len(expected) != 64:
            error("bad runtime DLL entry: %r" % item)
            continue
        actual = sha.get(name)
        if actual is None:
            error("DLL missing from SHA256 manifest: %s" % name)
        elif actual != expected:
            error("DLL SHA256 mismatch in manifests: %s" % name)

    exe = runtime.get("exe", {})
    exe_name = exe.get("name")
    exe_hash = str(exe.get("sha256", "")).lower()
    if not exe_name or len(exe_hash) != 64:
        error("runtime/current.json has invalid exe entry")
    else:
        manifest_hash = sha.get(exe_name)
        if manifest_hash is None:
            error("EXE missing from SHA256 manifest: %s" % exe_name)
        elif manifest_hash != exe_hash:
            error("EXE SHA256 mismatch in manifests: %s" % exe_name)

    verify_canonical_exe(current, runtime, sha)

    mc = current.get("movementcore", {})
    restore_doc = mc.get("source_restore_doc")
    if restore_doc:
        require_path(restore_doc)

    verify_movementcore_archive()
    verify_movementcore_source(mc, runtime_dlls)
    source_normal, source_reconstructed, source_missing = verify_source_inventory(runtime_dlls)

    legacy_dir = mc.get("legacy_partial_source_dir")
    if legacy_dir and (ROOT / legacy_dir).is_dir():
        warning("legacy partial MovementCore source still exists at %s; do not treat it as canonical" % legacy_dir)

    banned_suffixes = (".log", ".dmp", ".mdmp")
    for rel in tracked_files():
        if rel.lower().endswith(banned_suffixes):
            error("tracked runtime/debug artifact should not be in Git: %s" % rel)

    print("\nRepository verification summary")
    print("  baseline: %s" % current.get("stable_baseline"))
    print("  active DLLs: %d" % len(runtime_dlls))
    print("  canonical EXE: direct binary verified")
    print("  indexed normal sources: %d" % source_normal)
    print("  reconstructed/archived sources: %d" % source_reconstructed)
    print("  source not indexed: %d" % source_missing)
    print("  MovementCore source: normal .c + verified archive")
    print("  warnings: %d" % len(WARNINGS))
    print("  errors: %d" % len(ERRORS))

    if ERRORS:
        print("RESULT: FAIL")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
