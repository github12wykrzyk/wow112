#!/usr/bin/env python3
"""Build separate angle-only Rogue PvE comparison against same-SHA full candidate.

The default parallel candidate is untouched. Angle experiment sends player's
orientation only, retaining real XYZ; it cannot change the server's NPC facing.
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
        raise SystemExit("ROGUE_ANGLE: FAIL: " + why)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sha", required=True)
    ap.add_argument("--source", default="dist/WoW112_WORK_CANDIDATE.zip")
    ap.add_argument("--source-metadata", default="dist/candidate_metadata.json")
    ap.add_argument("--source-summary", default="dist/candidate_summary.json")
    ap.add_argument("--output", default="dist/WoW112_PARALLEL_ROGUE_ANGLE_ONLY.zip")
    ap.add_argument("--metadata", default="dist/rogue_angle_metadata.json")
    ap.add_argument("--summary", default="dist/rogue_angle_summary.json")
    ap.add_argument("--build-output", default="build/rogue_angle_only.dll")
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
    info = build(core_path, rear_angle_only=True)
    new_core = core_path.read_bytes()
    digest = sha256_bytes(new_core)
    require(digest != sha256_bytes(original_core),
            "angle-only binary identical to XYZ spoof build")
    require(info.get("machine_hex") == "0x014C" and info.get("entrypoint_rva")
            and info.get("has_import_directory"), "angle-only DLL not valid PE32 x86")

    require(out.resolve() != src.resolve(), "cannot overwrite normal full candidate")
    out.parent.mkdir(parents=True, exist_ok=True)
    rows = [(name, new_core if name == NAME else content) for name,content in rows]
    deterministic_repack(out, rows)
    variant = {
        "name": "parallel_rogue_angle_only",
        "branch": "parallel",
        "commit_sha": args.sha,
        "source_full_package_sha256": sha256_file(src),
        "normal_full_core_sha256": sha256_bytes(original_core),
        "experimental_core_sha256": digest,
        "real_xyz_preserved": True,
        "player_orientation_only": True,
        "npc_server_facing_spoofed": False,
        "refresh_ms": 50,
        "other_dlls_same_as_full_candidate": True,
        "pvp_angle_experiment_enabled": False,
        "game_runtime_tested": False,
        "purpose": "Compare local facing-only packets against XYZ positional spoof for stationary NPC Backstab",
    }
    row = copy.deepcopy(previous[0])
    row.update({"sha256": digest, "size": len(new_core),
                "pe_machine": info["machine_hex"],
                "entrypoint_rva": info["entrypoint_rva"],
                "has_import_directory": info["has_import_directory"],
                "build_profile": "clangcl_i686_win32imports_three_translation_units_angle_only",
                "angle_only_variant": True})
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
        obj["angle_only_diagnostic"] = copy.deepcopy(variant)
    (ROOT / args.metadata).write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    (ROOT / args.summary).write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    (ROOT / "dist/ROGUE_ANGLE_ONLY_TEST.txt").write_text(
        "PARALLEL ANGLE-ONLY DIAGNOSTIC (NPC PvE only)\\n"
        "Compare with WoW112_WORK_CANDIDATE.zip from the SAME commit.\\n"
        "The only binary change is consolidated MovementCore: the angle variant\\n"
        "keeps real XYZ and changes only your outgoing facing/orientation.\\n"
        "The server NPC's facing is NOT modified. A positional Backstab rejection\\n"
        "can therefore remain even when client-facing checks are bypassed.\\n"
        "Install in a CLEAN separate test folder / verified updater that removes\\n"
        "inactive DLLs. Use the matching LazyScript addons from this artifact.\\n"
        "Test stationary NPC Backstab, report real successes/errors and diagnostics.\\n"
        "Do not use for BG/PvP. Do not promote until separately accepted in game.\\n",
        encoding="ascii"
    )
    print("ROGUE_ANGLE: BUILT", args.sha, digest, sha256_file(out))


if __name__ == "__main__":
    main()
