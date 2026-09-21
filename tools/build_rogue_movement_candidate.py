#!/usr/bin/env python3
"""Build consolidated Rogue MovementCore from canonical V21 + PVERear360 (x86)."""
import argparse
import json
import os
import shutil
import struct
import subprocess
import tempfile
import zipfile
from pathlib import Path
from build_active_module import capture_vcvars_env, find_vcvars32, pe_info, sha256_file

ROOT = Path(__file__).resolve().parents[1]
NAME = "MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll"
OLD = "WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll"
SEPARATE = "WoWPVERear360_5875_v1.dll"
SOURCES = (
    "src/RogueMovementCore/WoWRogueMovementCore_Movement.c",
    "src/RogueMovementCore/WoWRogueMovementCore_Rear.c",
    "src/RogueMovementCore/WoWRogueMovementCore_Entry.c",
)
CANONICAL = (
    "src/MovementCore/WoWMovementCore_5875_v21_ALT_PRIORITY.c",
    "src/MovementCore/WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c",
    "src/PVERear360/WoWPVERear360_5875_v1.c",
    "src/common/W112ControlAPI.h",
)

def exported_names(path):
    data = path.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    opt = pe + 24
    section_table = opt + struct.unpack_from("<H", data, pe + 20)[0]
    section_count = struct.unpack_from("<H", data, pe + 6)[0]
    def offset(rva):
        for i in range(section_count):
            row = section_table + i * 40
            virtual_size, virtual_addr, raw_size, raw_ptr = struct.unpack_from("<IIII", data, row + 8)
            if virtual_addr <= rva < virtual_addr + max(virtual_size, raw_size):
                return raw_ptr + rva - virtual_addr
        raise SystemExit("unmapped PE export RVA")
    export_rva = struct.unpack_from("<I", data, opt + 96)[0]
    if not export_rva:
        raise SystemExit("consolidated Rogue DLL has no PE export directory")
    directory = offset(export_rva)
    count = struct.unpack_from("<I", data, directory + 24)[0]
    names = offset(struct.unpack_from("<I", data, directory + 32)[0])
    result = set()
    for i in range(count):
        name_offset = offset(struct.unpack_from("<I", data, names + 4 * i)[0])
        name_end = data.find(bytes([0]), name_offset)
        if name_end < 0:
            raise SystemExit("unterminated PE export name")
        result.add(data[name_offset:name_end].decode("ascii"))
    return result

def build(output):
    vcvars, _ = find_vcvars32()
    env, _ = capture_vcvars_env(vcvars)
    compiler = shutil.which("clang-cl.exe", path=env.get("PATH", "")) or shutil.which("clang-cl", path=env.get("PATH", ""))
    linker = shutil.which("link.exe", path=env.get("PATH", ""))
    if not compiler or not linker:
        raise SystemExit("x86 clang-cl and MSVC link.exe are required")
    objs = []
    for i, source in enumerate(SOURCES):
        obj = output.parent / ("rogue_movement_%d.obj" % i)
        cmd = [compiler, "--target=i686-pc-windows-msvc", "/nologo", "/c", "/O2",
               "/GS-", "/GR-", "/EHsc-", "/Zl", "/Brepro", "/clang:-fno-builtin",
               "/Fo" + str(obj), str(ROOT / source)]
        subprocess.run(cmd, cwd=ROOT, env=env, check=True)
        objs.append(obj)
    cmd = [linker, "/nologo", "/DLL", "/MACHINE:X86", "/NODEFAULTLIB",
           "/ENTRY:DllMain@12", "/Brepro", "/OUT:" + str(output)]
    cmd += [str(obj) for obj in objs]
    cmd += ["kernel32.lib", "user32.lib", "gdi32.lib"]
    subprocess.run(cmd, cwd=ROOT, env=env, check=True)
    info = pe_info(output)
    if info["machine_hex"] != "0x014C" or not info["entrypoint_rva"] or not info["has_import_directory"]:
        raise SystemExit("consolidated Rogue DLL failed PE32/x86/Win32-import gate")
    exports = exported_names(output)
    required = {
        "W112_Control_GetModuleV1", "MovementCore_CoordFlags",
        "MovementCore_CoordAcquireRear", "MovementCore_CoordReleaseRear",
        "MovementCore_GetAltPriorityInstalled", "PVERear360_GameWindowTick",
        "PVERear360_GetStatus", "PVERear360_GetPulseCount",
    }
    if required - exports:
        raise SystemExit("consolidated Rogue DLL missing ABI exports: " + ", ".join(sorted(required - exports)))
    return info

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", default="dist/WoW112_WORK_CANDIDATE.zip")
    ap.add_argument("--package-metadata", default="dist/candidate_metadata.json")
    ap.add_argument("--summary", default="dist/candidate_summary.json")
    ap.add_argument("--build-metadata", default="dist/rogue_movement_build.json")
    ap.add_argument("--output", default="build/" + NAME)
    args = ap.parse_args()
    package, meta_path, summary_path, output = (
        ROOT / args.package, ROOT / args.package_metadata,
        ROOT / args.summary, ROOT / args.output,
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    if not summary.get("ready_for_test") or summary.get("result") != "PASS":
        raise SystemExit("base package must pass fast gates")
    for source in SOURCES + CANONICAL:
        if not (ROOT / source).is_file():
            raise SystemExit("missing canonical source " + source)
    info = build(output)
    with zipfile.ZipFile(package, "r") as src:
        names = src.namelist()
        if NAME not in names or OLD in names or SEPARATE in names:
            raise SystemExit("base package has wrong cast-hook owner set")
        if names.count(NAME) != 1 or len(names) != len(set(names)):
            raise SystemExit("duplicate DLL in base package")
        rows = [(n, output.read_bytes() if n == NAME else src.read(n))
                for n in names if n != "dlls.txt"]
    dlls = [n for n, _ in rows if n.lower().endswith(".dll")]
    loader = ("\r\n".join(dlls) + "\r\n").encode("ascii")
    rows.append(("dlls.txt", loader))
    with tempfile.NamedTemporaryFile(prefix="rogue-", suffix=".zip", dir=package.parent, delete=False) as f:
        temp = Path(f.name)
    try:
        with zipfile.ZipFile(temp, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as dst:
            for name, data in rows:
                zi = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                zi.compress_type = zipfile.ZIP_DEFLATED
                zi.external_attr = 0o100644 << 16
                dst.writestr(zi, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        os.replace(temp, package)
    finally:
        if temp.exists():
            temp.unlink()
    module = {
        "name": NAME,
        "source_path": SOURCES[0],
        "source_inputs": {p: sha256_file(ROOT / p) for p in SOURCES + CANONICAL},
        "build_profile": "clangcl_i686_win32imports_three_translation_units",
        "sha256": sha256_file(output),
        "size": output.stat().st_size,
        "pe_machine": info["machine_hex"],
        "entrypoint_rva": info["entrypoint_rva"],
        "has_import_directory": info["has_import_directory"],
        "module_id": "movementcore",
        "embedded_rear_module_id": "pve_rear360",
        "game_window_tick": "ESP WndProc only; worker posts message",
        "server_side_acceptance": "not verified; requires in-game test",
    }
    if any(n in dlls for n in (OLD, SEPARATE)) or dlls.count(NAME) != 1:
        raise SystemExit("duplicate cast-hook owner after repack")
    extras = [x for x in meta.get("candidate_extra_dlls", []) if x.get("name") != NAME] + [module]
    digest, size = sha256_file(package), package.stat().st_size
    loader_meta = {"name": "dlls.txt", "generated_from_candidate_zip": True,
                   "dll_count": len(dlls), "dlls": dlls}
    for obj in (meta, summary):
        obj["candidate_extra_dlls"] = extras
        obj["candidate_extra_dll_count"] = len(extras)
        obj["package_sha256"] = digest
        obj["package_size"] = size
        obj["zip_root_entries"] = [n for n, _ in rows]
        obj["loader_manifest"] = loader_meta
        obj["rogue_movement_pilot"] = {"module": NAME, "embedded_rear360": True,
            "legacy_positional_loaded": False, "independent_rear360_loaded": False,
            "server_acceptance_verified": False}
        hub = obj.get("controlhub_pilot")
        if isinstance(hub, dict):
            hub["providers"] = [NAME if p == SEPARATE else p for p in hub.get("providers", [])]
    if not summary.get("ready_for_test"):
        raise SystemExit("base summary lost ready_for_test")
    meta_path.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    build_meta = dict(module, candidate_package_sha256=digest, candidate_package_size=size,
                      loader_manifest=loader_meta)
    (ROOT / args.build_metadata).write_text(json.dumps(build_meta, indent=2) + "\n", encoding="utf-8")
    print("ROGUE_MOVEMENT_BUILD: PASS", NAME, info["machine_hex"], digest)

if __name__ == "__main__":
    main()
