#!/usr/bin/env python3
"""Validate the declarative Parallel ECONOMY overlay contract."""
import json
import re
from pathlib import Path

from ah_shadow_hot_bundle import BUNDLE_MARKER, HOST_NAME, transform_summonscout_host
from summonscout_hot_transform import transform_file as transform_summonscout_file

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "runtime/parallel_economy.json"
PARALLEL = ROOT / "runtime/parallel_candidate.json"
SHA = re.compile(r"^[0-9a-fA-F]{40}$")
EXPECTED_HOT_RUNTIME = "Interface/AddOns/SummonScout/SummonScout_PostPaymentOfferHot.lua"
EXPECTED_HOT_SOURCE = "src/AddOns/SummonScout/SummonScout_PostPaymentOfferHot.lua"
EXPECTED_TRANSFORMS = ["summonscout_hot_transform", "ah_shadow_hot_bundle"]
EXPECTED_FP_FILES = ["tools/summonscout_hot_transform.py", "tools/ah_shadow_hot_bundle.py"]
EXPECTED_FP_ROOTS = ["src/AddOns/AuxEconomyShadow"]


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
    if not isinstance(dlls, list) or not dlls:
        fail("economy DLL declarations must be a non-empty list")
    names = [x.get("runtime_name") for x in dlls]
    if len(names) != len(set(names)) or order != names:
        fail("DLL order must exactly match the unique economy DLL declarations")
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

    hot_hosts = data.get("hot_hosts")
    if not isinstance(hot_hosts, list) or len(hot_hosts) != 1:
        fail("expected exactly one ECONOMY hot host")
    hot = hot_hosts[0]
    if hot.get("runtime_path") != EXPECTED_HOT_RUNTIME or hot.get("source") != EXPECTED_HOT_SOURCE:
        fail("unexpected ECONOMY hot host path/source")
    if hot.get("transforms") != EXPECTED_TRANSFORMS:
        fail("unexpected ECONOMY hot host transform chain")
    if hot.get("fingerprint_files") != EXPECTED_FP_FILES or hot.get("fingerprint_roots") != EXPECTED_FP_ROOTS:
        fail("hot host fingerprint coverage drift")
    if not isinstance(hot.get("purpose"), str) or not hot.get("purpose"):
        fail("hot host purpose missing")
    source_path = ROOT / EXPECTED_HOT_SOURCE
    if not source_path.is_file() or source_path.name != HOST_NAME:
        fail("hot host source missing or filename drifted")
    for path in EXPECTED_FP_FILES:
        if not (ROOT / path).is_file():
            fail("hot host fingerprint file missing: " + path)
    for path in EXPECTED_FP_ROOTS:
        if not (ROOT / path).is_dir():
            fail("hot host fingerprint root missing: " + path)

    auto = [x for x in full.get("companions", []) if x.get("runtime_name") == "WoWAutoLoginBridge_5875_v1.dll"]
    if len(auto) != 1 or len(auto[0].get("sources", [])) != 1:
        fail("exact AutoLoginBridge hot watcher declaration missing")
    watcher_path = ROOT / auto[0]["sources"][0]
    watcher_text = watcher_path.read_text(encoding="utf-8")
    if "SummonScout\\\\SummonScout_PostPaymentOfferHot.lua" not in watcher_text:
        fail("AutoLoginBridge no longer watches ECONOMY hot host")

    packed = transform_summonscout_file(HOST_NAME, source_path.read_bytes())
    packed = transform_summonscout_host(HOST_NAME, packed)
    if packed.count(BUNDLE_MARKER) != 1:
        fail("transformed ECONOMY hot host does not contain exactly one AH bundle")
    if len(packed) >= 262144:
        fail("transformed ECONOMY hot host exceeds native watcher payload cap")

    print("PARALLEL_ECONOMY_MANIFEST: PASS")
    print("hot_host=" + EXPECTED_HOT_RUNTIME)
    print("hot_fix_requires_close=false reload=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
