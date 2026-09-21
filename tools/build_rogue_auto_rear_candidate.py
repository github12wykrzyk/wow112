#!/usr/bin/env python3
"""Build separate physical auto-rear Rogue PvE comparison against same-SHA full candidate.

The default parallel candidate is untouched. Auto-rear uses real client movement and actual XYZ, not fake coordinates.
"""
import argparse
import copy
import json
from pathlib import Path

from build_rogue_movement_candidate import NAME, build
from verify_candidate_package import (
    deterministic_repack, loader_bytes, read_zip, sha256_bytes, sha256_file
)

ROOT = Path(__file__).resolve().parents[1]


def require(ok, why):
    if not ok:
        raise SystemExit("ROGUE_AUTO_REAR: FAIL: " + why)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sha", required=True)
    ap.add_argument("--source", default="dist/WoW112_WORK_CANDIDATE.zip")
    ap.add_argument("--source-metadata", default="dist/candidate_metadata.json")
    ap.add_argument("--source-summary", default="dist/candidate_summary.json")
    ap.add_argument("--output", default="dist/WoW112_PARALLEL_ROGUE_AUTO_REAR.zip")
    ap.add_argument("--metadata", default="dist/rogue_auto_rear_metadata.json")
    ap.add_argument("--summary", default="dist/rogue_auto_rear_summary.json")
    ap.add_argument("--build-output", default="build/rogue_auto_rear_only.dll")
    args = ap.parse_args()

    src, out = ROOT / args.source, ROOT / args.output
    core_path = ROOT / args.build_output
    meta = json.loads((ROOT / args.source_metadata).read_text(encoding="utf-8"))
    summary = json.loads((ROOT / args.source_summary).read_text(encoding="utf-8"))
    require(len(args.sha) == 40 and meta.get("git_head") == args.sha
            and summary.get("head") == args.sha, "wrong source commit")
    proof = meta.get("final_package_verification") or {}
    require(proof.get("result") == "PASS" and proof.get("loader_exact") is True
            and proof.get("all_binary_entries_pe32_x86") is True
            and summary.get("ready_for_test") is True
            and summary.get("result") == "PASS", "source candidate lacks final proof")
    require(sha256_file(src) == meta.get("package_sha256") ==
            summary.get("package_sha256") == proof.get("package_sha256"),
            "source candidate hash mismatch")
    require(src.stat().st_size == proof.get("package_size"),
            "source candidate size mismatch")
    rows = read_zip(src)
    source_content = dict(rows)
    dlls = [name for name in source_content if name.lower().endswith(".dll")]
    require(NAME in dlls and dlls.count(NAME) == 1
            and source_content.get("dlls.txt") == loader_bytes(dlls),
            "source stack missing canonical core or exact loader list")
    original_core = source_content[NAME]
    previous = [row for row in meta.get("candidate_extra_dlls", [])
                if row.get("name") == NAME]
    require(len(previous) == 1 and previous[0].get("sha256") ==
            sha256_bytes(original_core), "source is not consolidated Rogue core")

    core_path.parent.mkdir(parents=True, exist_ok=True)
    info = build(core_path, rear_auto_path=True)
    new_core = core_path.read_bytes()
    digest = sha256_bytes(new_core)
    require(digest != sha256_bytes(original_core),
            "auto-rear binary identical to synthetic XYZ build")
    require(info.get("machine_hex") == "0x014C" and info.get("entrypoint_rva")
            and info.get("has_import_directory"), "auto-rear DLL not valid PE32 x86")

    require(out.resolve() != src.resolve(), "cannot overwrite normal full candidate")
    out.parent.mkdir(parents=True, exist_ok=True)
    rows = [(name, new_core if name == NAME else content) for name,content in rows]
    deterministic_repack(out, rows)
    variant = {
        "name": "parallel_rogue_auto_rear",
        "branch": "parallel",
        "commit_sha": args.sha,
        "source_full_package_sha256": sha256_file(src),
        "normal_full_core_sha256": sha256_bytes(original_core),
        "experimental_core_sha256": digest,
        "real_xyz_preserved": True,
        "physical_strafe_input": True,
        "user_binding_queried_in_game": True,
        "real_client_facing_tracks_target": True,
        "npc_server_facing_spoofed": False,
        "movement_tick_ms": 50,
        "max_strafe_ms": 2200,
        "abort_if_stalled_or_manual_input": True,
        "other_dlls_same_as_full_candidate": True,
        "pvp_auto_rear_enabled": False,
        "game_runtime_tested": False,
        "purpose": "Compare real physical rear movement versus synthetic XYZ for NPC Backstab",
    }
    row = copy.deepcopy(previous[0])
    row.update({"sha256": digest, "size": len(new_core),
                "pe_machine": info["machine_hex"],
                "entrypoint_rva": info["entrypoint_rva"],
                "has_import_directory": info["has_import_directory"],
                "build_profile": "clangcl_i686_win32imports_three_translation_units_auto_rear",
                "auto_rear_variant": True})
    for obj in (meta, summary):
        obj.pop("final_package_verification", None)
        obj["package"] = out.name
        obj["package_sha256"] = sha256_file(out)
        obj["package_size"] = out.stat().st_size
        obj["candidate_extra_dlls"] = [
            row if item.get("name") == NAME else item
            for item in obj.get("candidate_extra_dlls", [])
        ]
        obj["candidate_extra_dll_count"] = len(obj["candidate_extra_dlls"])
        obj["auto_rear_diagnostic"] = copy.deepcopy(variant)
    (ROOT / args.metadata).write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    (ROOT / args.summary).write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    (ROOT / "dist/ROGUE_AUTO_REAR_TEST.txt").write_text(
        "PARALLEL / AUTO-REAR PvE physical movement pilot\\n"
        "The variant uses actual XYZ and bounded real strafe input, never\\n"
        "synthetic rear-position packets. Standard full-stack ZIP remains in\\n"
        "the SAME commit as rollback comparison.\\n"
        "Requires a single-letter STRAFERIGHT binding, focused WoW window,\\n"
        "no typing, and no manually held movement/ALT/RMB. Stalled motion or\\n"
        "a 2.2-second timeout releases the automated strafe input.\\n"
        "Test a single melee NPC on safe level ground: observe real movement,\\n"
        "Backstab availability and whether the injected key releases promptly.\\n"
        "Do not use for BG/PvP; game behavior is not proven by build success.\\n",
        encoding="ascii",
    )
    print("ROGUE_AUTO_REAR: BUILT", args.sha, digest, sha256_file(out))


if __name__ == "__main__":
    main()
