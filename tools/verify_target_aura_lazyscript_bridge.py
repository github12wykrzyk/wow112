#!/usr/bin/env python3
"""Verify the TargetAuraReveal -> LazyScript hostile-buff bridge contract."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / "src/TargetAuraReveal/WoWTargetAuraReveal_5875_v1.c"
LAZY = ROOT / "src/LazyScript/upstream/Addons/LazyScript/ParseBuffs.lua"

def fail(message):
    print("TARGET_AURA_LAZYSCRIPT_BRIDGE: FAIL:", message, file=sys.stderr)
    raise SystemExit(1)

native = NATIVE.read_text(encoding="utf-8")
lazy = LAZY.read_text(encoding="utf-8")

for marker in (
    "W112NativeTargetBuffs",
    "applications=",
    "rawSlot=",
    "lazyScript.nativeTargetBuffs=W112NativeTargetBuffs",
    "UNIT_AURA_APPLICATIONS_OFF",
):
    if marker not in native:
        fail("native bridge marker missing: " + marker)

for marker in (
    "function lazyScript.masks.HasNativeTargetBuff",
    "W112NativeTargetBuffs",
    'unitId == "target" and buffOrDebuff == "buff"',
    "GetNativeTargetBuffBySpellId",
    "GetNativeTargetBuffByTitle",
):
    if marker not in lazy:
        fail("LazyScript bridge marker missing: " + marker)

print("TARGET_AURA_LAZYSCRIPT_BRIDGE: PASS")
