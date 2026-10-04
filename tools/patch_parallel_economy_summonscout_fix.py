#!/usr/bin/env python3
"""Inject the SummonScout stack-overflow hotfix into the ECONOMY overlay.

Fast-path delivery only: adds the updated SummonScout.toc and the dedicated
WhisperConfirm stack fix without broadening ECONOMY to the full SummonScout tree.
"""
import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
PATCHES = (
    (
        "Interface/AddOns/SummonScout/SummonScout.toc",
        ROOT / "src/AddOns/SummonScout/SummonScout.toc",
    ),
    (
        "Interface/AddOns/SummonScout/SummonScout_WhisperConfirmStackFixHot.lua",
        ROOT / "src/AddOns/SummonScout/SummonScout_WhisperConfirmStackFixHot.lua",
    ),
)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def zipinfo(name):
    info = ZipInfo(name, (1980, 1, 1, 0, 0, 0))
    info.compress_type = ZIP_DEFLATED
    info.external_attr = 0o100644 << 16
    return info


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sha", required=True)
    ap.add_argument("--package", default="dist/WoW112_PARALLEL_ECONOMY_OVERLAY.zip")
    ap.add_argument("--metadata", default="dist/economy_metadata.json")
    ap.add_argument("--attestation", default="dist/economy_attestation.json")
    args = ap.parse_args()

    if len(args.sha) != 40 or any(c not in "0123456789abcdefABCDEF" for c in args.sha):
        raise SystemExit("invalid exact SHA")

    package = ROOT / args.package
    metadata_path = ROOT / args.metadata
    attestation_path = ROOT / args.attestation
    if not package.is_file() or not metadata_path.is_file() or not attestation_path.is_file():
        raise SystemExit("ECONOMY package/metadata/attestation missing")

    additions = {}
    for runtime_name, source in PATCHES:
        if not source.is_file():
            raise SystemExit("missing SummonScout fast-track source: " + str(source))
        data = source.read_bytes()
        if not data:
            raise SystemExit("empty SummonScout fast-track source: " + str(source))
        additions[runtime_name] = data

    with ZipFile(package, "r") as z:
        if z.testzip() is not None:
            raise SystemExit("ECONOMY ZIP CRC failure before SummonScout patch")
        rows = {item.filename: z.read(item.filename) for item in z.infolist()}

    manifest_name = "economy_manifest.json"
    if manifest_name not in rows:
        raise SystemExit("ECONOMY inner manifest missing")
    manifest = json.loads(rows[manifest_name].decode("utf-8"))
    files = manifest.get("files")
    if not isinstance(files, list):
        raise SystemExit("ECONOMY inner files manifest invalid")

    by_name = {str(item.get("name", "")).lower(): item for item in files if isinstance(item, dict)}
    for runtime_name, data in additions.items():
        key = runtime_name.lower()
        entry = {
            "name": runtime_name,
            "kind": "addon",
            "sha256": sha256(data),
            "size": len(data),
        }
        if key in by_name:
            old = by_name[key]
            old.clear()
            old.update(entry)
        else:
            files.append(entry)
            by_name[key] = entry
        rows[runtime_name] = data

    manifest["files"] = files
    manifest["summonscout_fast_track"] = "whisper-stack-fix-v1"
    rows[manifest_name] = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")

    fd, temp_name = tempfile.mkstemp(prefix="economy-summonscout-", suffix=".zip", dir=str(package.parent))
    os.close(fd)
    temp = Path(temp_name)
    try:
        with ZipFile(temp, "w", compression=ZIP_DEFLATED, compresslevel=9) as z:
            for name in sorted(rows, key=str.lower):
                z.writestr(zipinfo(name), rows[name], compress_type=ZIP_DEFLATED, compresslevel=9)
        with ZipFile(temp, "r") as z:
            if z.testzip() is not None:
                raise SystemExit("ECONOMY ZIP CRC failure after SummonScout patch")
            names = z.namelist()
            if len(names) != len({name.lower() for name in names}):
                raise SystemExit("ECONOMY ZIP duplicate path after SummonScout patch")
        os.replace(temp, package)
    finally:
        if temp.exists():
            temp.unlink()

    package_bytes = package.read_bytes()
    package_sha = sha256(package_bytes)
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    metadata["commit_sha"] = args.sha.lower()
    metadata["package_sha256"] = package_sha
    metadata["package_size"] = len(package_bytes)
    metadata["file_count"] = len(files)
    metadata["summonscout_fast_track"] = "whisper-stack-fix-v1"
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

    attestation = json.loads(attestation_path.read_text(encoding="utf-8"))
    attestation["commit_sha"] = args.sha.lower()
    attestation["package_sha256"] = package_sha
    attestation["package_size"] = len(package_bytes)
    attestation["summonscout_fast_track"] = "whisper-stack-fix-v1"
    attestation_path.write_text(json.dumps(attestation, indent=2) + "\n", encoding="utf-8")

    print("ECONOMY_SUMMONSCOUT_FAST_TRACK: PASS", package, package_sha, "files", len(files))
    for runtime_name in additions:
        print("  +", runtime_name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
