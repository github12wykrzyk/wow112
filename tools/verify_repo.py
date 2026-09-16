#!/usr/bin/env python3
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

    mc = current.get("movementcore", {})
    source_state = mc.get("source_state")
    restore_doc = mc.get("source_restore_doc")
    if restore_doc:
        require_path(restore_doc)

    verify_movementcore_archive()

    if source_state != "normal_source":
        warning("MovementCore canonical source is verified but not yet committed as a normal .c file (state=%s)" % source_state)

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
    print("  warnings: %d" % len(WARNINGS))
    print("  errors: %d" % len(ERRORS))

    if ERRORS:
        print("RESULT: FAIL")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
