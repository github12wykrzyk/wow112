#!/usr/bin/env python3
import argparse
import base64
import hashlib
import io
import json
import lzma
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STEALTH_NAME = "WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll"
STEALTH_SOURCE = "src/StealthCDGuardian/WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.c"


def sha256_file(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _decode_b64(text):
    clean = "".join(text.split())
    clean += "=" * ((-len(clean)) % 4)
    return base64.b64decode(clean, validate=True)


def b64_xz_from_parts(pattern):
    parts = sorted(ROOT.glob(pattern))
    if not parts:
        raise RuntimeError(f"missing recovery parts: {pattern}")
    texts = [p.read_text(encoding="ascii") for p in parts]
    attempts = []
    try:
        attempts.append(("continuous-base64", _decode_b64("".join(texts))))
    except Exception as exc:
        attempts.append(("continuous-base64-error", exc))
    try:
        attempts.append(("independent-base64-chunks", b"".join(_decode_b64(x) for x in texts)))
    except Exception as exc:
        attempts.append(("independent-base64-chunks-error", exc))

    errors = []
    for mode, payload in attempts:
        if isinstance(payload, Exception):
            errors.append(f"{mode}: {payload}")
            continue
        try:
            return lzma.decompress(payload)
        except Exception as exc:
            errors.append(f"{mode}: {exc}")
    raise RuntimeError(f"cannot decode XZ recovery parts {pattern}: {' | '.join(errors)}")


def b64_xz_single(rel):
    return lzma.decompress(_decode_b64((ROOT / rel).read_text(encoding="ascii")))


def write_bytes(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def run_patch(script_rel, src, dst):
    subprocess.run([sys.executable, str(ROOT / script_rel), str(src), str(dst)], cwd=str(ROOT), check=True)


def archive_member_by_basename(payload, wanted):
    bio = io.BytesIO(payload)
    if zipfile.is_zipfile(bio):
        with zipfile.ZipFile(bio, "r") as zf:
            matches = [n for n in zf.namelist() if Path(n).name == wanted]
            if len(matches) != 1:
                raise RuntimeError(f"bundle ZIP expected one {wanted}, found {matches}")
            return zf.read(matches[0])
    bio.seek(0)
    try:
        with tarfile.open(fileobj=bio, mode="r:*") as tf:
            matches = [m for m in tf.getmembers() if m.isfile() and Path(m.name).name == wanted]
            if len(matches) != 1:
                raise RuntimeError(f"bundle TAR expected one {wanted}, found {[m.name for m in matches]}")
            f = tf.extractfile(matches[0])
            if f is None:
                raise RuntimeError(f"cannot extract {wanted} from TAR")
            return f.read()
    except tarfile.TarError as exc:
        raise RuntimeError("decoded V68 bundle is neither ZIP nor TAR") from exc


def recover_from_v68_bundle(wanted, expected_hash):
    candidates = [
        ("artifacts/V68/bundle/part*.b64", "artifacts/V68/bundle"),
        ("archives/V68_FULL_NO_EXE_BUNDLE_B64/part*.txt", "archives/V68_FULL_NO_EXE_BUNDLE_B64 (deprecated fallback)"),
    ]
    errors = []
    for pattern, label in candidates:
        try:
            payload = b64_xz_from_parts(pattern)
            data = archive_member_by_basename(payload, wanted)
            got = hashlib.sha256(data).hexdigest()
            if got != expected_hash:
                raise RuntimeError(f"{wanted} hash {got} != {expected_hash}")
            return data, label
        except Exception as exc:
            errors.append(f"{label}: {exc}")
    raise RuntimeError("V68 bundle recovery failed for %s: %s" % (wanted, " | ".join(errors)))


def deterministic_zip(output, files):
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for path in files:
            info = zipfile.ZipInfo(path.name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            zf.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def main():
    ap = argparse.ArgumentParser(description="Reconstruct current V68 stack and package a work StealthCDGuardian candidate.")
    ap.add_argument("--candidate-dll", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--metadata", required=True)
    args = ap.parse_args()

    runtime = json.loads((ROOT / "runtime/current.json").read_text(encoding="utf-8"))
    current = json.loads((ROOT / "CURRENT.json").read_text(encoding="utf-8"))
    items = runtime.get("active_dlls", [])
    expected = {item["name"]: item["sha256"].lower() for item in items}
    names = [item["name"] for item in items]
    if STEALTH_NAME not in expected:
        raise SystemExit("StealthCDGuardian is not active in runtime/current.json")

    candidate = Path(args.candidate_dll).resolve()
    if not candidate.is_file():
        raise SystemExit(f"candidate DLL missing: {candidate}")
    candidate_hash = sha256_file(candidate)
    candidate_size = candidate.stat().st_size
    if candidate_hash != expected[STEALTH_NAME]:
        raise SystemExit(f"candidate DLL hash mismatch: built={candidate_hash} runtime={expected[STEALTH_NAME]}")

    recovery_sources = {}
    with tempfile.TemporaryDirectory(prefix="wow112-work-package-") as tmp:
        stage = Path(tmp)

        positional = "WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll"
        data, source = recover_from_v68_bundle(positional, expected[positional])
        write_bytes(stage / positional, data)
        recovery_sources[positional] = source

        direct = {
            "WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll":
                b64_xz_from_parts("artifacts/V67/runtime/WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll.xz.b64.part*"),
            "PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll":
                b64_xz_single("artifacts/V67/runtime/PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll.xz.b64"),
            "MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll":
                b64_xz_from_parts("artifacts/V68/runtime/MovementCore_V68.dll.xz.b64.part*"),
            "WoWPlayerESP_v1_2_range_sweep.dll":
                lzma.decompress((ROOT / "artifacts/V67/runtime/WoWPlayerESP_v1_2_range_sweep.dll.xz").read_bytes()),
        }
        for name, blob in direct.items():
            write_bytes(stage / name, blob)
            recovery_sources[name] = "canonical runtime artifact"

        v13 = stage / "WoWAutoLootPP_v0_13_PP300YD_HU_ATTACKABLE_LEVELGATE3_ONESHOT_SELECTORCHECK.dll"
        write_bytes(v13, b64_xz_from_parts("artifacts/V67/runtime/WoWAutoLootPP_v0_13_PP300YD_HU_ATTACKABLE_LEVELGATE3_ONESHOT_SELECTORCHECK.dll.xz.b64.part*"))
        auto_name = "WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK.dll"
        run_patch("artifacts/AutoLootPP/patch_v013_ONESHOT_to_v014_NOSKIP.py", v13, stage / auto_name)
        v13.unlink()
        recovery_sources[auto_name] = "v0.13 artifact + deterministic reproducer"

        v09 = stage / "WoWLongPickPocket_v0_9_HARDLOS025_FacingOnly.dll"
        write_bytes(v09, b64_xz_from_parts("artifacts/V67/runtime/WoWLongPickPocket_v0_9_HARDLOS025_FacingOnly.dll.xz.b64.part*"))
        long_name = "WoWLongPickPocket_v1_0_ALLRANGE_360FACING_HARDLOS025.dll"
        run_patch("artifacts/LongPickPocket/patch_v09_FacingOnly_to_v10_ALLRANGE_360FACING.py", v09, stage / long_name)
        v09.unlink()
        recovery_sources[long_name] = "v0.9 artifact + deterministic reproducer"

        shutil.copy2(candidate, stage / STEALTH_NAME)
        recovery_sources[STEALTH_NAME] = "fresh deterministic x86 build"

        for name in names:
            path = stage / name
            if not path.is_file():
                raise SystemExit(f"active DLL not reconstructed: {name}")
            got = sha256_file(path)
            if got != expected[name]:
                raise SystemExit(f"runtime hash mismatch for {name}: got={got} expected={expected[name]}")

        exe_name = runtime["exe"]["name"]
        exe_src = ROOT / current["exe"]["path"]
        exe_dst = stage / exe_name
        shutil.copy2(exe_src, exe_dst)
        exe_hash = sha256_file(exe_dst)
        if exe_hash != runtime["exe"]["sha256"].lower():
            raise SystemExit(f"EXE hash mismatch: got={exe_hash} expected={runtime['exe']['sha256']}")

        files = [exe_dst] + [stage / name for name in names]
        output = Path(args.output).resolve()
        deterministic_zip(output, files)

    source = ROOT / STEALTH_SOURCE
    metadata = {
        "candidate_dll": STEALTH_NAME,
        "candidate_sha256": candidate_hash,
        "candidate_size": candidate_size,
        "source_path": STEALTH_SOURCE,
        "source_sha256": sha256_file(source),
        "source_size": source.stat().st_size,
        "package": str(Path(args.output).name),
        "package_sha256": sha256_file(Path(args.output).resolve()),
        "package_size": Path(args.output).resolve().stat().st_size,
        "active_dll_count": len(names),
        "exe": runtime["exe"]["name"],
        "recovery_sources": recovery_sources,
    }
    meta_path = Path(args.metadata).resolve()
    meta_path.parent.mkdir(parents=True, exist_ok=True)
    meta_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metadata, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
