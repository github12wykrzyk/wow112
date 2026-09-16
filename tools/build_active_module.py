#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

PROCESS_START = time.perf_counter()
ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "runtime/current.json"


def die(msg):
    raise SystemExit(msg)


def sha256_file(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_runtime():
    return json.loads(RUNTIME.read_text(encoding="utf-8"))


def select_item(runtime, query):
    items = runtime.get("active_dlls", [])
    exact = [x for x in items if x.get("name") == query]
    if len(exact) == 1:
        return exact[0]
    q = query.lower()
    partial = [x for x in items if q in str(x.get("name", "")).lower()]
    if len(partial) == 1:
        return partial[0]
    if not partial:
        die(f"no active DLL matches: {query}")
    die("ambiguous active DLL query: %s -> %s" % (query, ", ".join(x["name"] for x in partial)))


def find_vcvars32():
    t0 = time.perf_counter()
    env_root = os.environ.get("VSINSTALLDIR")
    candidates = []
    if env_root:
        candidates.append(Path(env_root) / "VC/Auxiliary/Build/vcvars32.bat")

    pf86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    vswhere = Path(pf86) / "Microsoft Visual Studio/Installer/vswhere.exe"
    if vswhere.is_file():
        try:
            out = subprocess.check_output(
                [
                    str(vswhere),
                    "-latest",
                    "-products",
                    "*",
                    "-requires",
                    "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                    "-property",
                    "installationPath",
                ],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
            if out:
                candidates.append(Path(out) / "VC/Auxiliary/Build/vcvars32.bat")
        except Exception:
            pass

    pf = Path(os.environ.get("ProgramFiles", r"C:\Program Files"))
    for edition in ("Enterprise", "Professional", "Community", "BuildTools"):
        candidates.append(pf / f"Microsoft Visual Studio/2022/{edition}/VC/Auxiliary/Build/vcvars32.bat")

    for p in candidates:
        if p.is_file():
            return p.resolve(), (time.perf_counter() - t0) * 1000.0
    die("Visual Studio x86 toolchain not found (vcvars32.bat)")


def capture_vcvars_env(vcvars):
    t0 = time.perf_counter()
    command = f'call "{vcvars}" >nul && set'
    proc = subprocess.run(
        ["cmd.exe", "/d", "/s", "/c", command],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
    )
    if proc.returncode:
        die(f"vcvars32 initialization failed with exit code {proc.returncode}")
    env = os.environ.copy()
    for raw in proc.stdout.splitlines():
        if "=" in raw:
            key, value = raw.split("=", 1)
            env[key] = value
    return env, (time.perf_counter() - t0) * 1000.0


def find_direct_llvm_tools():
    t0 = time.perf_counter()
    clang = shutil.which("clang-cl")
    lld = shutil.which("lld-link")
    llvm_bin = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "LLVM/bin"
    if not clang:
        p = llvm_bin / "clang-cl.exe"
        if p.is_file():
            clang = str(p)
    if not lld:
        p = llvm_bin / "lld-link.exe"
        if p.is_file():
            lld = str(p)
    if not clang or not lld:
        return None, None, (time.perf_counter() - t0) * 1000.0
    return str(Path(clang).resolve()), str(Path(lld).resolve()), (time.perf_counter() - t0) * 1000.0


def run_timed(cmd, env=None):
    t0 = time.perf_counter()
    proc = subprocess.run(cmd, cwd=str(ROOT), env=env)
    elapsed = (time.perf_counter() - t0) * 1000.0
    if proc.returncode:
        raise RuntimeError(f"command failed ({proc.returncode}): {' '.join(str(x) for x in cmd)}")
    return elapsed


def clang_compile_cmd(clang, source, obj):
    return [
        clang,
        "--target=i686-pc-windows-msvc",
        "/nologo",
        "/c",
        "/O2",
        "/GS-",
        "/GR-",
        "/EHsc-",
        "/Zl",
        "/Brepro",
        "/clang:-fno-builtin",
        f"/Fo{obj}",
        str(source),
    ]


def msvc_compile_cmd(source, obj):
    return [
        "cl",
        "/nologo",
        "/c",
        "/O2",
        "/GS-",
        "/GR-",
        "/EHsc-",
        "/Zl",
        "/Brepro",
        f"/Fo{obj}",
        str(source),
    ]


def link_cmd(linker, obj, output, extra_libs=None):
    cmd = [
        linker,
        "/nologo",
        "/DLL",
        "/MACHINE:X86",
        "/NODEFAULTLIB",
        "/ENTRY:DllMain@12",
        "/Brepro",
        f"/OUT:{output}",
        str(obj),
    ]
    if extra_libs:
        cmd.extend(extra_libs)
    return cmd


def run_legacy_build(profile, source, obj, output):
    vcvars, discovery_ms = find_vcvars32()
    env, init_ms = capture_vcvars_env(vcvars)
    tool_path = env.get("PATH", "")
    linker = shutil.which("link.exe", path=tool_path) or shutil.which("link", path=tool_path)
    if not linker:
        die("MSVC link.exe not found after vcvars32 initialization")
    if profile == "msvc_x86_crtless":
        compiler = shutil.which("cl.exe", path=tool_path) or shutil.which("cl", path=tool_path)
        if not compiler:
            die("MSVC cl.exe not found after vcvars32 initialization")
        compile_cmd = msvc_compile_cmd(source, obj)
        compile_cmd[0] = compiler
        libs = []
    elif profile in ("clangcl_i686_crtless", "clangcl_i686_win32imports"):
        compiler = shutil.which("clang-cl.exe", path=tool_path) or shutil.which("clang-cl", path=tool_path)
        if not compiler:
            die("clang-cl not found after vcvars32 initialization")
        compile_cmd = clang_compile_cmd(compiler, source, obj)
        libs = ["kernel32.lib", "user32.lib", "gdi32.lib"] if profile == "clangcl_i686_win32imports" else []
    else:
        die(f"unsupported build profile: {profile}")
    try:
        compile_ms = run_timed(compile_cmd, env=env)
        link_ms = run_timed(link_cmd(linker, obj, output, libs), env=env)
    except RuntimeError as exc:
        die(str(exc))
    return {
        "mode": "vcvars32",
        "toolchain_discovery_ms": discovery_ms,
        "toolchain_initialization_ms": init_ms,
        "compile_ms": compile_ms,
        "link_ms": link_ms,
        "fallback_reason": None,
    }


def run_direct_clang_crtless(source, obj, output):
    clang, lld, discovery_ms = find_direct_llvm_tools()
    if not clang or not lld:
        raise RuntimeError("direct LLVM tools not found")
    compile_ms = run_timed(clang_compile_cmd(clang, source, obj))
    link_ms = run_timed(link_cmd(lld, obj, output))
    return {
        "mode": "direct_clang_lld",
        "clang_cl": clang,
        "lld_link": lld,
        "toolchain_discovery_ms": discovery_ms,
        "toolchain_initialization_ms": 0.0,
        "compile_ms": compile_ms,
        "link_ms": link_ms,
        "fallback_reason": None,
    }


def pe_info(path):
    data = Path(path).read_bytes()
    if len(data) < 0x40 or data[:2] != b"MZ":
        die(f"output is not a PE file: {path}")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if pe + 24 > len(data) or data[pe:pe + 4] != b"PE\0\0":
        die(f"output has invalid PE header: {path}")
    machine = struct.unpack_from("<H", data, pe + 4)[0]
    if machine != 0x014C:
        die(f"output is not x86 PE32: machine=0x{machine:04X}")
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    if magic != 0x010B:
        die(f"output is not PE32: optional_magic=0x{magic:04X}")
    entry_rva = struct.unpack_from("<I", data, opt + 16)[0]
    import_rva, import_size = struct.unpack_from("<II", data, opt + 96 + 8)
    return {
        "machine": machine,
        "machine_hex": "0x014C",
        "entrypoint_rva": entry_rva,
        "import_directory_rva": import_rva,
        "import_directory_size": import_size,
        "has_import_directory": bool(import_rva or import_size),
        "size": len(data),
    }


def build_one(profile, source, obj, output):
    if profile == "clangcl_i686_crtless":
        try:
            timing = run_direct_clang_crtless(source, obj, output)
        except RuntimeError as exc:
            timing = run_legacy_build(profile, source, obj, output)
            timing["fallback_reason"] = str(exc)
    else:
        timing = run_legacy_build(profile, source, obj, output)

    info = pe_info(output)
    if profile in ("clangcl_i686_crtless", "msvc_x86_crtless") and info["has_import_directory"]:
        die(f"CRT-less profile unexpectedly produced PE imports: {output}")
    if info["entrypoint_rva"] == 0:
        die(f"DLL entrypoint RVA is zero: {output}")
    return timing, info


def benchmark_ab(source, output):
    legacy_out = output.with_name(output.stem + ".legacy_ab.dll")
    legacy_obj = legacy_out.with_suffix(".obj")
    fast_out = output.with_name(output.stem + ".fast_ab.dll")
    fast_obj = fast_out.with_suffix(".obj")

    legacy = run_legacy_build("clangcl_i686_crtless", source, legacy_obj, legacy_out)
    legacy_info = pe_info(legacy_out)
    if legacy_info["has_import_directory"]:
        die("legacy clang CRT-less A/B output unexpectedly has imports")

    legacy_total = legacy["toolchain_discovery_ms"] + legacy["toolchain_initialization_ms"] + legacy["compile_ms"] + legacy["link_ms"]
    try:
        fast = run_direct_clang_crtless(source, fast_obj, fast_out)
        fast_info = pe_info(fast_out)
        fast_total = fast["toolchain_discovery_ms"] + fast["compile_ms"] + fast["link_ms"]
        abi_gate = (
            legacy_info["machine"] == fast_info["machine"] == 0x014C
            and not legacy_info["has_import_directory"]
            and not fast_info["has_import_directory"]
            and legacy_info["entrypoint_rva"] != 0
            and fast_info["entrypoint_rva"] != 0
        )
        direct = {**fast, "pe": fast_info, "sha256": sha256_file(fast_out)}
        direct_error = None
    except (RuntimeError, SystemExit) as exc:
        fast_total = None
        abi_gate = False
        direct = None
        direct_error = str(exc)

    speedup_ms = (legacy_total - fast_total) if fast_total is not None else None
    speedup_percent = ((speedup_ms / legacy_total) * 100.0) if speedup_ms is not None and legacy_total > 0 else None
    return {
        "profile": "clangcl_i686_crtless",
        "legacy": {**legacy, "pe": legacy_info, "sha256": sha256_file(legacy_out)},
        "direct": direct,
        "direct_error": direct_error,
        "legacy_build_path_ms": legacy_total,
        "direct_build_path_ms": fast_total,
        "speedup_ms": speedup_ms,
        "speedup_percent": speedup_percent,
        "abi_gate_pass": abi_gate,
    }


def main():
    ap = argparse.ArgumentParser(description="Build one active WoW 1.12.1/5875 x86 DLL using its verified runtime build recipe.")
    ap.add_argument("--name", help="Exact runtime DLL name or unique substring.")
    ap.add_argument("--list", action="store_true", help="List active modules with verified build recipes.")
    ap.add_argument("--output", help="Optional output DLL path; defaults to build/<runtime-name>.")
    ap.add_argument("--metadata", help="Optional JSON build metadata path.")
    ap.add_argument("--require-runtime-hash", action="store_true", help="Fail unless built bytes equal the current runtime DLL hash.")
    ap.add_argument("--ab-compare", action="store_true", help="Benchmark legacy vcvars/link.exe vs direct clang-cl/lld-link for clangcl_i686_crtless.")
    args = ap.parse_args()

    runtime = load_runtime()
    if args.list:
        for item in runtime.get("active_dlls", []):
            recipe = item.get("build_recipe") or {}
            print(f"{item.get('name')}\t{recipe.get('profile', 'NO_DIRECT_BUILD')}\t{item.get('source_path', '-')}")
        return 0
    if not args.name:
        die("--name is required unless --list is used")

    item = select_item(runtime, args.name)
    recipe = item.get("build_recipe")
    if not isinstance(recipe, dict) or not recipe.get("profile"):
        die(f"active DLL has no verified direct build recipe: {item['name']}")
    source_rel = item.get("source_path")
    if not source_rel:
        die(f"active DLL has no direct source_path: {item['name']}")
    source = (ROOT / source_rel).resolve()
    if not source.is_file():
        die(f"canonical source missing: {source_rel}")

    out = Path(args.output).resolve() if args.output else (ROOT / "build" / item["name"]).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    obj = out.with_suffix(".obj")

    profile = recipe["profile"]
    ab = None
    if args.ab_compare:
        if profile != "clangcl_i686_crtless":
            die("--ab-compare requires clangcl_i686_crtless profile")
        ab = benchmark_ab(source, out)

    t_build = time.perf_counter()
    timing, info = build_one(profile, source, obj, out)
    build_elapsed_ms = (time.perf_counter() - t_build) * 1000.0

    digest = sha256_file(out)
    current = str(item.get("sha256", "")).lower()
    matches = digest == current
    script_elapsed_ms = (time.perf_counter() - PROCESS_START) * 1000.0
    script_startup_ms = max(0.0, script_elapsed_ms - build_elapsed_ms)

    print(f"BUILD_PROFILE={profile}")
    print(f"TOOLCHAIN_MODE={timing['mode']}")
    print(f"SOURCE={source.relative_to(ROOT)}")
    print(f"OUTPUT={out}")
    print("PE_MACHINE=0x014C")
    print(f"PE_IMPORTS={'YES' if info['has_import_directory'] else 'NO'}")
    print(f"ENTRYPOINT_RVA=0x{info['entrypoint_rva']:08X}")
    print(f"SIZE={info['size']}")
    print(f"SHA256={digest}")
    print(f"CURRENT_RUNTIME_SHA256={current}")
    print(f"BYTE_IDENTICAL_CURRENT={'YES' if matches else 'NO'}")
    if args.require_runtime_hash and not matches:
        die("built DLL is not byte-identical to current runtime")

    meta = {
        "runtime_name": item["name"],
        "source_path": source_rel,
        "source_sha256": sha256_file(source),
        "build_profile": profile,
        "toolchain_mode": timing["mode"],
        "output": str(out),
        "output_sha256": digest,
        "output_size": info["size"],
        "current_runtime_sha256": current,
        "byte_identical_current": matches,
        "pe_machine": info["machine_hex"],
        "entrypoint_rva": info["entrypoint_rva"],
        "has_import_directory": info["has_import_directory"],
        "timings_ms": {
            "script_startup": script_startup_ms,
            "toolchain_discovery": timing["toolchain_discovery_ms"],
            "toolchain_initialization": timing["toolchain_initialization_ms"],
            "compile": timing["compile_ms"],
            "link": timing["link_ms"],
            "build_path_total": (
                timing["toolchain_discovery_ms"]
                + timing["toolchain_initialization_ms"]
                + timing["compile_ms"]
                + timing["link_ms"]
            ),
            "process_total": script_elapsed_ms,
        },
        "fallback_reason": timing.get("fallback_reason"),
    }
    if ab is not None:
        meta["ab_compare"] = ab

    if args.metadata:
        mp = Path(args.metadata).resolve()
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    else:
        print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
