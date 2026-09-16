#!/usr/bin/env python3
import argparse
import hashlib
import json
import lzma
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def decode_xz(path):
    return lzma.decompress(Path(path).read_bytes())


def parse_overrides(values):
    out = {}
    for raw in values:
        if "=" not in raw:
            raise SystemExit(f"bad --override {raw!r}; expected NAME=PATH")
        name, path = raw.split("=", 1)
        name = name.strip()
        path = path.strip()
        if not name or not path:
            raise SystemExit(f"bad --override {raw!r}; expected NAME=PATH")
        if name in out:
            raise SystemExit(f"duplicate --override for {name}")
        out[name] = Path(path).resolve()
    return out


def deterministic_zip(output, files):
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for path in files:
            info = zipfile.ZipInfo(path.name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            zf.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def git_head():
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=str(ROOT), stderr=subprocess.DEVNULL, text=True
        ).strip()
    except Exception:
        return None


def restore_dll(item, overrides):
    name = item["name"]
    expected = str(item["sha256"]).lower()

    if name in overrides:
        path = overrides[name]
        if not path.is_file():
            raise SystemExit(f"override DLL missing: {name} -> {path}")
        data = path.read_bytes()
        source = f"override:{path}"
    else:
        artifact = item.get("binary_artifact")
        if not isinstance(artifact, dict):
            raise SystemExit(f"active DLL has no binary_artifact and no override: {name}")
        if artifact.get("kind") != "xz":
            raise SystemExit(f"unsupported binary_artifact kind for {name}: {artifact.get('kind')!r}")
        rel = artifact.get("path")
        if not rel:
            raise SystemExit(f"binary_artifact path missing: {name}")
        path = ROOT / rel
        if not path.is_file():
            raise SystemExit(f"binary_artifact missing: {name} -> {rel}")
        if str(artifact.get("sha256", "")).lower() != expected:
            raise SystemExit(f"binary_artifact SHA metadata mismatch: {name}")
        data = decode_xz(path)
        expected_size = artifact.get("size")
        if expected_size is not None and len(data) != expected_size:
            raise SystemExit(
                f"binary_artifact size mismatch: {name} got={len(data)} expected={expected_size}"
            )
        source = rel

    got = sha256_bytes(data)
    if got != expected:
        raise SystemExit(f"runtime hash mismatch for {name}: got={got} expected={expected}")
    return data, source


def main():
    ap = argparse.ArgumentParser(
        description="Package the active runtime from runtime/current.json using self-contained binary artifacts."
    )
    ap.add_argument("--output", required=True)
    ap.add_argument("--metadata", required=True)
    ap.add_argument(
        "--override",
        action="append",
        default=[],
        metavar="NAME=PATH",
        help="Use a freshly built DLL for one active runtime name instead of its cached binary artifact.",
    )
    args = ap.parse_args()

    runtime = json.loads((ROOT / "runtime/current.json").read_text(encoding="utf-8"))
    current = json.loads((ROOT / "CURRENT.json").read_text(encoding="utf-8"))
    items = runtime.get("active_dlls", [])
    names = [x.get("name") for x in items if isinstance(x, dict)]
    if len(items) != len(names) or any(not x for x in names):
        raise SystemExit("invalid runtime/current.json active_dlls")
    if len(set(names)) != len(names):
        raise SystemExit("duplicate active DLL name in runtime/current.json")

    overrides = parse_overrides(args.override)
    unknown = sorted(set(overrides) - set(names))
    if unknown:
        raise SystemExit("override names are not active runtime DLLs: " + ", ".join(unknown))

    output = Path(args.output).resolve()
    metadata_path = Path(args.metadata).resolve()
    restore_sources = {}
    dll_meta = []

    with tempfile.TemporaryDirectory(prefix="wow112-package-") as td:
        stage = Path(td)

        for item in items:
            name = item["name"]
            data, source = restore_dll(item, overrides)
            dst = stage / name
            dst.write_bytes(data)
            restore_sources[name] = source
            dll_meta.append(
                {
                    "name": name,
                    "sha256": sha256_bytes(data),
                    "size": len(data),
                    "source": source,
                    "override": name in overrides,
                }
            )

        exe_name = runtime.get("exe", {}).get("name")
        exe_hash = str(runtime.get("exe", {}).get("sha256", "")).lower()
        current_exe = current.get("exe", {})
        exe_rel = current_exe.get("path")
        if current_exe.get("name") != exe_name:
            raise SystemExit("EXE name mismatch between CURRENT.json and runtime/current.json")
        if str(current_exe.get("sha256", "")).lower() != exe_hash:
            raise SystemExit("EXE hash mismatch between CURRENT.json and runtime/current.json")
        if not exe_rel:
            raise SystemExit("CURRENT.json EXE path missing")
        exe_src = ROOT / exe_rel
        if not exe_src.is_file():
            raise SystemExit(f"canonical EXE missing: {exe_rel}")
        got_exe = sha256_file(exe_src)
        if got_exe != exe_hash:
            raise SystemExit(f"canonical EXE hash mismatch: got={got_exe} expected={exe_hash}")
        exe_dst = stage / exe_name
        shutil.copy2(exe_src, exe_dst)

        files = [exe_dst] + [stage / name for name in names]
        deterministic_zip(output, files)

    metadata = {
        "schema_version": 1,
        "git_head": git_head(),
        "baseline": runtime.get("baseline"),
        "wow_build": runtime.get("wow_build"),
        "package": output.name,
        "package_sha256": sha256_file(output),
        "package_size": output.stat().st_size,
        "exe": {
            "name": exe_name,
            "sha256": exe_hash,
            "size": (ROOT / current_exe["path"]).stat().st_size,
        },
        "active_dll_count": len(items),
        "active_dlls": dll_meta,
        "restore_sources": restore_sources,
    }
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()
