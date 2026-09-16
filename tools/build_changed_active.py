#!/usr/bin/env python3
import argparse
import hashlib
import json
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

PROCESS_START = time.perf_counter()
ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "runtime/current.json"
BUILDER = ROOT / "tools/build_active_module.py"
PACKAGER = ROOT / "tools/package_current.py"
FAST_VERIFY = ROOT / "tools/verify_current.py"
RUNTIME_VERIFY = ROOT / "tools/verify_runtime_artifacts.py"
SYMBOL_VERIFY = ROOT / "tools/verify_verified_symbols.py"
CONTROLHUB_SOURCE = ROOT / "src/WoWControlHub/WoWControlHub_v1.c"
CONTROLHUB_SPEEDFLOOR_SOURCE = "src/SpeedFloor/WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG_RECONSTRUCTED.c"


def norm(path):
    return str(path).replace("\\", "/")


def sha256_file(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def git_has_commit(ref):
    if not ref or set(ref) == {"0"}:
        return False
    proc = subprocess.run(
        ["git", "cat-file", "-e", f"{ref}^{{commit}}"],
        cwd=str(ROOT),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return proc.returncode == 0


def changed_files(base):
    resolved = base if git_has_commit(base) else None
    if resolved:
        cmd = ["git", "diff", "--name-only", resolved, "HEAD"]
    else:
        if not git_has_commit("HEAD^"):
            return [], None
        resolved = "HEAD^"
        cmd = ["git", "diff", "--name-only", "HEAD^", "HEAD"]
    data = subprocess.check_output(cmd, cwd=str(ROOT), text=True)
    return sorted({norm(x.strip()) for x in data.splitlines() if x.strip()}), resolved


def safe_name(name):
    return "".join(c if c.isalnum() or c in "._-" else "_" for c in name)


def run_checked(cmd):
    print("RUN:", " ".join(str(x) for x in cmd))
    t0 = time.perf_counter()
    proc = subprocess.run(cmd, cwd=str(ROOT))
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    if proc.returncode:
        raise SystemExit(proc.returncode)
    return elapsed_ms


def run_gate(path, name):
    t0 = time.perf_counter()
    proc = subprocess.run(
        [sys.executable, str(path)],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
    )
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    result = {
        "name": name,
        "result": "PASS" if proc.returncode == 0 else "FAIL",
        "returncode": proc.returncode,
        "elapsed_ms": elapsed_ms,
    }
    if proc.returncode:
        result["stdout"] = proc.stdout[-12000:]
        result["stderr"] = proc.stderr[-12000:]
    return result


def run_fast_gates():
    gates = [
        (FAST_VERIFY, "verify_current"),
        (RUNTIME_VERIFY, "verify_runtime_artifacts"),
        (SYMBOL_VERIFY, "verify_verified_symbols"),
    ]
    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=len(gates)) as pool:
        futures = [pool.submit(run_gate, path, name) for path, name in gates]
        results = [f.result() for f in futures]
    wall_ms = (time.perf_counter() - t0) * 1000.0
    for result in results:
        print(f"{result['name']}: {result['result']} ({result['elapsed_ms']:.1f} ms)")
        if result["result"] != "PASS":
            if result.get("stdout"):
                print(result["stdout"])
            if result.get("stderr"):
                print(result["stderr"], file=sys.stderr)
    if any(x["result"] != "PASS" for x in results):
        raise SystemExit("fast verification gate failed")
    return results, wall_ms


def main():
    ap = argparse.ArgumentParser(
        description="Build changed active WoW 1.12.1/5875 x86 modules and package one candidate stack."
    )
    ap.add_argument("--base", help="Previous commit SHA used to detect changed active sources.")
    ap.add_argument("--all", action="store_true", help="Audit-build every active DLL; unchanged modules are not candidate overrides.")
    ap.add_argument("--output-dir", default="build")
    ap.add_argument("--package", default="dist/WoW112_WORK_CANDIDATE.zip")
    ap.add_argument("--package-metadata", default="dist/candidate_metadata.json")
    ap.add_argument("--summary", default="dist/candidate_summary.json")
    args = ap.parse_args()

    runtime = json.loads(RUNTIME.read_text(encoding="utf-8"))
    items = [x for x in runtime.get("active_dlls", []) if isinstance(x, dict)]
    by_source = {
        norm(x.get("source_path")): x
        for x in items
        if x.get("source_path") and isinstance(x.get("build_recipe"), dict)
    }

    changed, resolved_base = changed_files(args.base)
    source_selected = [by_source[p] for p in changed if p in by_source]

    # Candidate-only companion dependency: while the optional ControlHub pilot is
    # present, every produced candidate must contain the ABI-enabled SpeedFloor,
    # even when the current edit touched only ControlHub or another module.
    # This does not mutate stable runtime hashes and is reported separately from
    # genuinely changed active modules.
    candidate_required = []
    if CONTROLHUB_SOURCE.is_file():
        speed_item = by_source.get(CONTROLHUB_SPEEDFLOOR_SOURCE)
        if speed_item is None:
            raise SystemExit("ControlHub pilot requires canonical SpeedFloor source routing")
        if speed_item not in source_selected:
            candidate_required.append(speed_item)

    force_all_paths = {
        "tools/build_active_module.py",
        "tools/build_changed_active.py",
        ".github/workflows/build_work_candidate.yml",
        "runtime/current.json",
    }
    force_all = args.all or bool(force_all_paths.intersection(changed))

    selected_for_candidate = list(source_selected)
    for item in candidate_required:
        if item not in selected_for_candidate:
            selected_for_candidate.append(item)
    audit_selected = list(by_source.values()) if force_all else list(selected_for_candidate)

    relevant_infra = {
        "tools/build_active_module.py",
        "tools/build_changed_active.py",
        "tools/build_controlhub_candidate.py",
        "tools/package_current.py",
        "tools/verify_verified_symbols.py",
        "runtime/verified_symbols_5875.json",
        "runtime/current.json",
        "CURRENT.json",
        ".github/workflows/build_work_candidate.yml",
        "src/common/W112ControlAPI.h",
        "src/WoWControlHub/WoWControlHub_v1.c",
    }
    relevant = bool(audit_selected) or bool(relevant_infra.intersection(changed)) or any(
        p.startswith("artifacts/runtime_cache/") for p in changed
    ) or args.all

    output_dir = (ROOT / args.output_dir).resolve()
    package = (ROOT / args.package).resolve()
    package_metadata = (ROOT / args.package_metadata).resolve()
    summary_path = (ROOT / args.summary).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    summary_path.parent.mkdir(parents=True, exist_ok=True)

    gates, gate_wall_ms = run_fast_gates()

    source_override_names = {x["name"] for x in selected_for_candidate}
    built = []
    overrides = []
    build_driver_wall_ms = 0.0
    ab_name = None
    if "tools/build_active_module.py" in changed:
        for item in audit_selected:
            recipe = item.get("build_recipe") or {}
            if recipe.get("profile") == "clangcl_i686_crtless" and "SpeedFloor" in item.get("source_path", ""):
                ab_name = item["name"]
                break
        if ab_name is None:
            for item in audit_selected:
                recipe = item.get("build_recipe") or {}
                if recipe.get("profile") == "clangcl_i686_crtless":
                    ab_name = item["name"]
                    break

    package_driver_ms = 0.0
    package_meta = None
    if relevant:
        for item in audit_selected:
            name = item["name"]
            out = output_dir / name
            meta = output_dir / (safe_name(name) + ".json")
            cmd = [
                sys.executable,
                str(BUILDER),
                "--name",
                name,
                "--output",
                str(out),
                "--metadata",
                str(meta),
            ]
            if name == ab_name:
                cmd.append("--ab-compare")
            build_driver_wall_ms += run_checked(cmd)
            build_meta = json.loads(meta.read_text(encoding="utf-8"))
            built.append(build_meta)
            if name in source_override_names:
                overrides.append((name, out))

        package_cmd = [
            sys.executable,
            str(PACKAGER),
            "--output",
            str(package),
            "--metadata",
            str(package_metadata),
        ]
        for name, path in overrides:
            package_cmd.extend(["--override", f"{name}={path}"])
        package_driver_ms = run_checked(package_cmd)
        package_meta = json.loads(package_metadata.read_text(encoding="utf-8"))

    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=str(ROOT), text=True).strip()
    ready = bool(
        relevant
        and package.is_file()
        and package_meta
        and all(x["result"] == "PASS" for x in gates)
        and package_meta.get("exe", {}).get("in_zip_root")
        and package_meta.get("all_active_dlls_in_zip_root")
    )
    build_rows = [
        {
            "runtime_name": x["runtime_name"],
            "build_profile": x["build_profile"],
            "toolchain_mode": x.get("toolchain_mode"),
            "pe_machine": x.get("pe_machine"),
            "candidate_sha256": x["output_sha256"],
            "stable_current_sha256": x["current_runtime_sha256"],
            "byte_identical_current": x["byte_identical_current"],
            "has_import_directory": x.get("has_import_directory"),
            "timings_ms": x.get("timings_ms", {}),
            "fallback_reason": x.get("fallback_reason"),
        }
        for x in built
    ]
    ab_compare = next((x.get("ab_compare") for x in built if x.get("ab_compare")), None)

    summary = {
        "schema_version": 3,
        "head": head,
        "base": resolved_base,
        "result": "PASS" if ready else "FAIL",
        "ready_for_test": ready,
        "verification": {
            "fast_gate_wall_ms": gate_wall_ms,
            **{x["name"]: {"result": x["result"], "elapsed_ms": x["elapsed_ms"]} for x in gates},
            "deep_audit": {
                "status": "skipped",
                "reason": "work candidate fast path; deep audit is reserved for stable promotion/recovery changes",
            },
        },
        "changed_files": changed,
        "force_all": force_all,
        "relevant": relevant,
        "changed_active_modules": [x["name"] for x in source_selected],
        "candidate_required_modules": [x["name"] for x in candidate_required],
        "audit_build_count": len(built),
        "audit_builds": build_rows,
        "candidate_override_count": len(overrides),
        "candidate_override_names": [name for name, _ in overrides],
        "active_dll_count": package_meta.get("active_dll_count") if package_meta else len(items),
        "exact_byte_cache_count": package_meta.get("exact_byte_cache_count") if package_meta else None,
        "exact_byte_cache_names": package_meta.get("exact_byte_cache_names") if package_meta else [],
        "package": str(package.relative_to(ROOT)) if relevant else None,
        "package_sha256": sha256_file(package) if relevant and package.is_file() else None,
        "package_size": package.stat().st_size if relevant and package.is_file() else None,
        "package_metadata": str(package_metadata.relative_to(ROOT)) if relevant else None,
        "zip_root_entries": package_meta.get("zip_root_entries") if package_meta else [],
        "active_wow_exe_in_root": package_meta.get("exe", {}).get("in_zip_root") if package_meta else False,
        "all_active_dlls_in_root": package_meta.get("all_active_dlls_in_zip_root") if package_meta else False,
        "package_timings_ms": package_meta.get("timings_ms", {}) if package_meta else {},
        "driver_timings_ms": {
            "fast_verification_wall": gate_wall_ms,
            "build_subprocess_wall": build_driver_wall_ms,
            "package_subprocess_wall": package_driver_ms,
            "candidate_process_total": (time.perf_counter() - PROCESS_START) * 1000.0,
        },
        "ab_compare": ab_compare,
    }
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    if not ready:
        raise SystemExit("candidate summary verdict is not READY_FOR_TEST")
    return 0


if __name__ == "__main__":
    sys.exit(main())
