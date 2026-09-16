#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import lzma
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STEALTH_NAME = "WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll"
STEALTH_SOURCE = "src/StealthCDGuardian/WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.c"


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def b64_xz_from_parts(pattern):
    parts = sorted(ROOT.glob(pattern))
    if not parts:
        raise SystemExit(f"missing recovery parts: {pattern}")
    text = "".join("".join(p.read_text(encoding="ascii").split()) for p in parts)
    return lzma.decompress(base64.b64decode(text, validate=True))


def b64_xz_single(rel):
    text = "".join((ROOT / rel).read_text(encoding="ascii").split())
    return lzma.decompress(base64.b64decode(text, validate=True))


def write_bytes(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def run_patch(script_rel, src, dst):
    subprocess.run([sys.executable, str(ROOT / script_rel), str(src), str(dst)], cwd=str(ROOT), check=True)


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

    stealth_item = next(x for x in items if x.get("name") == STEALTH_NAME)
    build_meta = stealth_item.get("candidate_build") or {}
    pinned_hash = str(build_meta.get("sha256", "")).lower()
    if pinned_hash and candidate_hash != pinned_hash:
        raise SystemExit(f"candidate DLL hash mismatch: built={candidate_hash} metadata={pinned_hash}")

    with tempfile.TemporaryDirectory(prefix="wow112-work-package-") as tmp:
        stage = Path(tmp)

        restore = {
            "WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll":
                b64_xz_from_parts("artifacts/V67/runtime/WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll.xz.b64.part*"),
            "WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll":
                b64_xz_from_parts("artifacts/V67/runtime/WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll.xz.b64.part*"),
            "PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll":
                b64_xz_single("artifacts/V67/runtime/PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll.xz.b64"),
            "MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll":
                b64_xz_from_parts("artifacts/V68/runtime/MovementCore_V68.dll.xz.b64.part*"),
            "WoWPlayerESP_v1_2_range_sweep.dll":
                lzma.decompress((ROOT / "artifacts/V67/runtime/WoWPlayerESP_v1_2_range_sweep.dll.xz").read_bytes()),
        }
        for name, data in restore.items():
            write_bytes(stage / name, data)

        v13 = stage / "WoWAutoLootPP_v0_13_PP300YD_HU_ATTACKABLE_LEVELGATE3_ONESHOT_SELECTORCHECK.dll"
        write_bytes(v13, b64_xz_from_parts("artifacts/V67/runtime/WoWAutoLootPP_v0_13_PP300YD_HU_ATTACKABLE_LEVELGATE3_ONESHOT_SELECTORCHECK.dll.xz.b64.part*"))
        auto_name = "WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK.dll"
        run_patch("artifacts/AutoLootPP/patch_v013_ONESHOT_to_v014_NOSKIP.py", v13, stage / auto_name)
        v13.unlink()

        v09 = stage / "WoWLongPickPocket_v0_9_HARDLOS025_FacingOnly.dll"
        write_bytes(v09, b64_xz_from_parts("artifacts/V67/runtime/WoWLongPickPocket_v0_9_HARDLOS025_FacingOnly.dll.xz.b64.part*"))
        long_name = "WoWLongPickPocket_v1_0_ALLRANGE_360FACING_HARDLOS025.dll"
        run_patch("artifacts/LongPickPocket/patch_v09_FacingOnly_to_v10_ALLRANGE_360FACING.py", v09, stage / long_name)
        v09.unlink()

        shutil.copy2(candidate, stage / STEALTH_NAME)

        for name in names:
            path = stage / name
            if not path.is_file():
                raise SystemExit(f"active DLL not reconstructed: {name}")
            got = sha256_file(path)
            if name != STEALTH_NAME and got != expected[name]:
                raise SystemExit(f"runtime hash mismatch for {name}: got={got} expected={expected[name]}")
            if name == STEALTH_NAME and pinned_hash and got != expected[name]:
                raise SystemExit(f"runtime/current.json Stealth hash does not match pinned candidate: got={got} runtime={expected[name]}")

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
        "runtime_expected_before_or_after_build": expected[STEALTH_NAME],
        "package": str(Path(args.output).name),
        "package_sha256": sha256_file(Path(args.output).resolve()),
        "package_size": Path(args.output).resolve().stat().st_size,
        "active_dll_count": len(names),
        "exe": runtime["exe"]["name"],
    }
    meta_path = Path(args.metadata).resolve()
    meta_path.parent.mkdir(parents=True, exist_ok=True)
    meta_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metadata, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
