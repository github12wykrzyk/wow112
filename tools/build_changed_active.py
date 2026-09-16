#!/usr/bin/env python3
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "runtime/current.json"
BUILDER = ROOT / "tools/build_active_module.py"
PACKAGER = ROOT / "tools/package_current.py"


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
    proc = subprocess.run(cmd, cwd=str(ROOT))
    if proc.returncode:
        raise SystemExit(proc.returncode)


def main():
    ap = argparse.ArgumentParser(
        description="Build only changed active WoW 1.12.1/5875 x86 modules, then package one candidate stack."
    )
    ap.add_argument("--base", help="Previous commit SHA used to detect changed active sources.")
    ap.add_argument("--all", action="store_true", help="Build every active DLL with a verified direct recipe.")
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
    force_all_paths = {
        "tools/build_active_module.py",
        "tools/build_changed_active.py",
        ".github/workflows/build_work_candidate.yml",
        "runtime/current.json",
    }
    force_all = args.all or bool(force_all_paths.intersection(changed))

    if force_all:
        selected = list(by_source.values())
    else:
        selected = [by_source[p] for p in changed if p in by_source]

    relevant_infra = {
        "tools/build_active_module.py",
        "tools/build_changed_active.py",
        "tools/package_current.py",
        "runtime/current.json",
        "CURRENT.json",
        ".github/workflows/build_work_candidate.yml",
    }
    relevant = bool(selected) or bool(relevant_infra.intersection(changed)) or any(
        p.startswith("artifacts/runtime_cache/") for p in changed
    ) or args.all

    output_dir = (ROOT / args.output_dir).resolve()
    package = (ROOT / args.package).resolve()
    package_metadata = (ROOT / args.package_metadata).resolve()
    summary_path = (ROOT / args.summary).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    summary_path.parent.mkdir(parents=True, exist_ok=True)

    built = []
    overrides = []
    if relevant:
        for item in selected:
            name = item["name"]
            out = output_dir / name
            meta = output_dir / (safe_name(name) + ".json")
            run_checked(
                [
                    sys.executable,
                    str(BUILDER),
                    "--name",
                    name,
                    "--output",
                    str(out),
                    "--metadata",
                    str(meta),
                ]
            )
            build_meta = json.loads(meta.read_text(encoding="utf-8"))
            built.append(build_meta)
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
        run_checked(package_cmd)

    summary = {
        "schema_version": 1,
        "base": resolved_base,
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=str(ROOT), text=True).strip(),
        "changed_files": changed,
        "force_all": force_all,
        "relevant": relevant,
        "active_source_changes": [x["name"] for x in selected],
        "built_count": len(built),
        "built": built,
        "package": str(package.relative_to(ROOT)) if relevant else None,
        "package_sha256": sha256_file(package) if relevant and package.is_file() else None,
        "package_metadata": str(package_metadata.relative_to(ROOT)) if relevant else None,
    }
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
