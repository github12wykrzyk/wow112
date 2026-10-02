#!/usr/bin/env python3
"""Validate the declarative Parallel ECONOMY overlay contract."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "runtime/parallel_economy.json"
PARALLEL = ROOT / "runtime/parallel_candidate.json"
SHA = re.compile(r"^[0-9a-fA-F]{40}$")


def fail(msg):
    raise SystemExit("PARALLEL_ECONOMY_MANIFEST: FAIL: " + msg)


def main():
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    full = json.loads(PARALLEL.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1 or data.get("branch") != "parallel" or data.get("profile") != "ECONOMY":
        fail("invalid schema/branch/profile")
    delivery = data.get("delivery") or {}
    if delivery.get("overlay_only") is not True or delivery.get("allow_deletes") is not False:
        fail("overlay must be no-delete")
    if delivery.get("inner_zip") != "WoW112_PARALLEL_ECONOMY_OVERLAY.zip":
        fail("unexpected inner ZIP")
    dlls = data.get("dlls")
    order = data.get("required_loader_order")
    if not isinstance(dlls, list) or len(dlls) != 3 or order != [x.get("runtime_name") for x in dlls]:
        fail("DLL order must exactly match the three economy DLL declarations")
    companions = {x.get("runtime_name"): x for x in full.get("companions", [])}
    for item in dlls:
        name, source, profile = item.get("runtime_name"), item.get("source"), item.get("profile")
        if name not in companions:
            fail("economy DLL is not a declared parallel companion: " + str(name))
        declared = companions[name]
        if declared.get("sources") != [source] or declared.get("profile") != profile:
            fail("economy DLL source/profile differs from parallel candidate: " + name)
        if not (ROOT / source).is_file():
            fail("missing DLL source: " + source)
    addons = data.get("addons") or {}
    roots = addons.get("roots")
    if not isinstance(roots, list) or len(roots) != len(set(roots)) or not roots:
        fail("invalid addon roots")
    for name in roots:
        root = ROOT / "src/AddOns" / name
        if not root.is_dir() or not any(x.is_file() and x.suffix.lower() == ".toc" for x in root.iterdir()):
            fail("missing local addon root/.toc: " + name)
    ext = addons.get("external")
    if not isinstance(ext, list) or len(ext) != 1:
        fail("expected exactly one pinned external aux addon")
    row = ext[0]
    if row.get("destination") != "aux-addon" or row.get("repository") != "shirsig/aux-addon-vanilla" or not SHA.fullmatch(str(row.get("commit") or "")):
        fail("invalid external aux pin")
    print("PARALLEL_ECONOMY_MANIFEST: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
