#!/usr/bin/env python3
"""Build a deterministic, no-delete Parallel ECONOMY overlay artifact."""
import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

from ah_shadow_hot_bundle import transform_summonscout_host
from summonscout_hot_transform import transform_file as transform_summonscout_file

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "runtime/parallel_economy.json"
ALLOWED_ADDON_EXT = {".lua", ".toc", ".xml", ".tga", ".blp", ".ttf", ".txt", ".md", ".wav", ".mp3", ".ogg", ".jpg", ".jpeg", ".png"}
EXPECTED_HOT_TRANSFORMS = ["summonscout_hot_transform", "ah_shadow_hot_bundle"]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def inspect_pe(name, data):
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise SystemExit(name + ": not MZ")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if pe + 40 > len(data) or data[pe:pe+4] != b"PE\0\0":
        raise SystemExit(name + ": bad PE")
    machine = struct.unpack_from("<H", data, pe + 4)[0]
    entry = struct.unpack_from("<I", data, pe + 24 + 16)[0]
    if machine != 0x014C or entry == 0:
        raise SystemExit(name + ": not PE32 x86/entrypoint")
    return {"machine": "0x014C", "entrypoint_rva": entry}


def checkout_external(item):
    path = ROOT / "build/economy_external" / item["destination"]
    if path.exists():
        try:
            actual = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip().lower()
        except Exception:
            actual = ""
        if actual != item["commit"].lower():
            shutil.rmtree(path)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "--quiet", "--no-checkout", "https://github.com/" + item["repository"] + ".git", str(path)], check=True)
        subprocess.run(["git", "-C", str(path), "checkout", "--quiet", "--detach", item["commit"]], check=True)
    actual = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip().lower()
    if actual != item["commit"].lower():
        raise SystemExit("external addon SHA mismatch: " + item["destination"])
    return path


def safe_addon_files(root_name, source):
    out = []
    for p in sorted(source.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(source)
        if ".git" in rel.parts or p.name.startswith("."):
            continue
        if p.suffix.lower() not in ALLOWED_ADDON_EXT:
            raise SystemExit("unsupported addon file: " + str(p))
        arc = "Interface/AddOns/" + root_name + "/" + rel.as_posix()
        if ".." in rel.parts or "\\" in arc or ":" in arc:
            raise SystemExit("unsafe addon path: " + arc)
        out.append((arc, p.read_bytes(), "addon"))
    prefix = "Interface/AddOns/" + root_name + "/"
    if not any(name.lower().endswith(".toc") and "/" not in name[len(prefix):] for name, _, _ in out):
        raise SystemExit("addon has no root .toc: " + root_name)
    return out


def safe_hot_host(item):
    runtime_path = item.get("runtime_path")
    source_name = item.get("source")
    transforms = item.get("transforms")
    if not isinstance(runtime_path, str) or not runtime_path.startswith("Interface/AddOns/"):
        raise SystemExit("invalid ECONOMY hot host runtime path")
    if "\\" in runtime_path or ":" in runtime_path or ".." in Path(runtime_path).parts:
        raise SystemExit("unsafe ECONOMY hot host runtime path")
    if Path(runtime_path).suffix.lower() not in ALLOWED_ADDON_EXT:
        raise SystemExit("unsupported ECONOMY hot host extension")
    if not isinstance(source_name, str) or not source_name.startswith("src/AddOns/"):
        raise SystemExit("invalid ECONOMY hot host source")
    if transforms != EXPECTED_HOT_TRANSFORMS:
        raise SystemExit("unsupported ECONOMY hot host transform chain")
    source = ROOT / source_name
    if not source.is_file():
        raise SystemExit("missing ECONOMY hot host source: " + source_name)
    data = source.read_bytes()
    data = transform_summonscout_file(source.name, data)
    data = transform_summonscout_host(source.name, data)
    if len(data) >= 262144:
        raise SystemExit("ECONOMY hot host exceeds native watcher payload cap")
    return runtime_path, data, "addon"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sha", required=True)
    ap.add_argument("--fingerprint", default="dist/economy_fingerprint.json")
    ap.add_argument("--build-dir", default="build/economy")
    ap.add_argument("--output", default="dist/WoW112_PARALLEL_ECONOMY_OVERLAY.zip")
    ap.add_argument("--metadata", default="dist/economy_metadata.json")
    ap.add_argument("--attestation", default="dist/economy_attestation.json")
    args = ap.parse_args()
    if len(args.sha) != 40 or any(c not in "0123456789abcdefABCDEF" for c in args.sha):
        raise SystemExit("invalid exact SHA")
    cfg = json.loads(MANIFEST.read_text(encoding="utf-8"))
    fp = json.loads((ROOT / args.fingerprint).read_text(encoding="utf-8"))
    if fp.get("profile") != "ECONOMY":
        raise SystemExit("invalid ECONOMY fingerprint")

    rows, file_meta, pe_meta = [], [], {}
    build_dir = ROOT / args.build_dir
    expected_dlls = [x["runtime_name"] for x in cfg["dlls"]]
    if cfg["required_loader_order"] != expected_dlls:
        raise SystemExit("economy loader order drift")
    for item in cfg["dlls"]:
        name = item["runtime_name"]
        path = build_dir / name
        if not path.is_file():
            raise SystemExit("missing economy DLL: " + str(path))
        data = path.read_bytes()
        pe_meta[name] = inspect_pe(name, data)
        rows.append((name, data, "dll"))
    for name in cfg["addons"]["roots"]:
        rows.extend(safe_addon_files(name, ROOT / "src/AddOns" / name))
    for item in cfg["addons"].get("external", []):
        rows.extend(safe_addon_files(item["destination"], checkout_external(item)))
    for item in cfg.get("hot_hosts", []):
        rows.append(safe_hot_host(item))

    names = [x[0] for x in rows]
    if len(names) != len({x.lower() for x in names}):
        raise SystemExit("case-insensitive duplicate economy path")
    if any(n.lower().endswith(".exe") or n.lower() == "dlls.txt" for n in names):
        raise SystemExit("ECONOMY overlay must not contain EXE or dlls.txt")
    if [n for n, _, kind in rows if kind == "dll"] != expected_dlls:
        raise SystemExit("economy DLL set/order mismatch")
    for name, data, kind in rows:
        file_meta.append({"name": name, "kind": kind, "sha256": sha(data), "size": len(data)})

    inner_manifest = {
        "schema_version": 1,
        "profile": "ECONOMY",
        "branch": "parallel",
        "commit_sha": args.sha.lower(),
        "profile_fingerprint": fp["profile_fingerprint"],
        "native_fingerprint": fp["native_fingerprint"],
        "addon_fingerprint": fp["addon_fingerprint"],
        "overlay_only": True,
        "allow_deletes": False,
        "required_loader_order": expected_dlls,
        "files": file_meta,
        "pe": pe_meta,
    }
    rows.append(("economy_manifest.json", (json.dumps(inner_manifest, indent=2) + "\n").encode("utf-8"), "manifest"))

    output = ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix="economy-overlay-", suffix=".zip", dir=str(output.parent))
    os.close(fd)
    temp = Path(tmp_name)
    try:
        with ZipFile(temp, "w", compression=ZIP_DEFLATED, compresslevel=9) as z:
            for name, data, _ in rows:
                info = ZipInfo(name, (1980, 1, 1, 0, 0, 0))
                info.compress_type = ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                z.writestr(info, data, compress_type=ZIP_DEFLATED, compresslevel=9)
        with ZipFile(temp) as z:
            if z.testzip() is not None:
                raise SystemExit("economy ZIP CRC failure")
            actual = z.namelist()
            if len(actual) != len({x.lower() for x in actual}):
                raise SystemExit("economy ZIP duplicate path")
        os.replace(temp, output)
    finally:
        if temp.exists():
            temp.unlink()

    package_sha = sha(output.read_bytes())
    metadata = {
        "schema_version": 1, "profile": "ECONOMY", "branch": "parallel",
        "commit_sha": args.sha.lower(), "package_name": output.name,
        "package_sha256": package_sha, "package_size": output.stat().st_size,
        "profile_fingerprint": fp["profile_fingerprint"],
        "native_fingerprint": fp["native_fingerprint"], "addon_fingerprint": fp["addon_fingerprint"],
        "overlay_only": True, "allow_deletes": False,
        "required_loader_order": expected_dlls, "file_count": len(file_meta),
    }
    attestation = {
        "schema_version": 1, "result": "PASS", "profile": "ECONOMY", "branch": "parallel",
        "commit_sha": args.sha.lower(), "package_sha256": package_sha, "package_size": output.stat().st_size,
        "profile_fingerprint": fp["profile_fingerprint"], "overlay_only": True, "allow_deletes": False,
        "all_native_pe32_x86": True, "game_test_accepted": False, "delivery_status": "READY_FOR_GAME_TEST",
    }
    (ROOT / args.metadata).write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    (ROOT / args.attestation).write_text(json.dumps(attestation, indent=2) + "\n", encoding="utf-8")
    print("ECONOMY_PACKAGE: PASS", output, package_sha, "files", len(file_meta))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
