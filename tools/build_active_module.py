#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import struct
import subprocess
import sys
from pathlib import Path

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
            return p.resolve()
    die("Visual Studio x86 toolchain not found (vcvars32.bat)")


def cmd_quote(path):
    return '"' + str(path).replace('"', '""') + '"'


def run_build(vcvars, profile, source, obj, output):
    extra_libs = ""
    if profile == "msvc_x86_crtless":
        compile_cmd = (
            f'cl /nologo /c /O2 /GS- /GR- /EHsc- /Zl /Brepro '
            f'/Fo{cmd_quote(obj)} {cmd_quote(source)}'
        )
    elif profile in ("clangcl_i686_crtless", "clangcl_i686_win32imports"):
        compile_cmd = (
            f'clang-cl --target=i686-pc-windows-msvc /nologo /c /O2 /GS- /GR- /EHsc- '
            f'/Zl /Brepro /clang:-fno-builtin /Fo{cmd_quote(obj)} {cmd_quote(source)}'
        )
        if profile == "clangcl_i686_win32imports":
            extra_libs = " kernel32.lib user32.lib gdi32.lib"
    else:
        die(f"unsupported build profile: {profile}")

    link_cmd = (
        f'link /nologo /DLL /MACHINE:X86 /NODEFAULTLIB /ENTRY:DllMain@12 /Brepro '
        f'/OUT:{cmd_quote(output)} {cmd_quote(obj)}{extra_libs}'
    )
    command = f'call {cmd_quote(vcvars)} >nul && {compile_cmd} && {link_cmd}'
    print(f"BUILD_PROFILE={profile}")
    print(f"SOURCE={source.relative_to(ROOT)}")
    print(f"OUTPUT={output}")
    proc = subprocess.run(["cmd.exe", "/d", "/s", "/c", command], cwd=str(ROOT))
    if proc.returncode:
        die(f"build failed with exit code {proc.returncode}")


def verify_pe_x86(path):
    data = Path(path).read_bytes()
    if len(data) < 0x40 or data[:2] != b"MZ":
        die(f"output is not a PE file: {path}")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if pe + 6 > len(data) or data[pe:pe+4] != b"PE\0\0":
        die(f"output has invalid PE header: {path}")
    machine = struct.unpack_from("<H", data, pe + 4)[0]
    if machine != 0x014C:
        die(f"output is not x86 PE32: machine=0x{machine:04X}")
    return len(data)


def main():
    ap = argparse.ArgumentParser(description="Build one active WoW 1.12.1/5875 x86 DLL using its verified runtime build recipe.")
    ap.add_argument("--name", help="Exact runtime DLL name or unique substring.")
    ap.add_argument("--list", action="store_true", help="List active modules with verified build recipes.")
    ap.add_argument("--output", help="Optional output DLL path; defaults to build/<runtime-name>.")
    ap.add_argument("--metadata", help="Optional JSON build metadata path.")
    ap.add_argument("--require-runtime-hash", action="store_true", help="Fail unless built bytes equal the current runtime DLL hash.")
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
    vcvars = find_vcvars32()
    run_build(vcvars, recipe["profile"], source, obj, out)
    size = verify_pe_x86(out)
    digest = sha256_file(out)
    current = str(item.get("sha256", "")).lower()
    matches = digest == current
    print("PE_MACHINE=x86")
    print(f"SIZE={size}")
    print(f"SHA256={digest}")
    print(f"CURRENT_RUNTIME_SHA256={current}")
    print(f"BYTE_IDENTICAL_CURRENT={'YES' if matches else 'NO'}")
    if args.require_runtime_hash and not matches:
        die("built DLL is not byte-identical to current runtime")

    if args.metadata:
        meta = {
            "runtime_name": item["name"],
            "source_path": source_rel,
            "source_sha256": sha256_file(source),
            "build_profile": recipe["profile"],
            "output": str(out),
            "output_sha256": digest,
            "output_size": size,
            "current_runtime_sha256": current,
            "byte_identical_current": matches,
        }
        mp = Path(args.metadata).resolve()
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
