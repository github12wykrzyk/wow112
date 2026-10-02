#!/usr/bin/env python3
"""Fail closed on the active AuxVmangos AutoSell GUI/state contract."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "AuxVmangos"
TOC = ADDON / "AuxVmangos.toc"
AUTOSELL = ADDON / "AuxVmangos_AutoSell.lua"
FORCE = ADDON / "AuxVmangos_AutoSellForce.lua"
POST_DEFAULTS = ADDON / "AuxVmangos_PostDefaults.lua"


def fail(message: str) -> None:
    print("AUXVMANGOS_AUTOSELL_CONTRACT: FAIL: " + message)
    raise SystemExit(1)


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        fail(f"missing {label}: {needle!r}")


def main() -> int:
    if not TOC.is_file() or not AUTOSELL.is_file() or not POST_DEFAULTS.is_file():
        fail("required AuxVmangos files are missing")
    if FORCE.exists():
        fail("obsolete AuxVmangos_AutoSellForce.lua must not exist in the active source tree")

    toc = TOC.read_text(encoding="utf-8")
    autosell = AUTOSELL.read_text(encoding="utf-8")

    require(toc, "AuxVmangos_AutoSell.lua", "AutoSell TOC entry")
    require(toc, "AuxVmangos_PostDefaults.lua", "PostDefaults TOC entry")
    if "AuxVmangos_AutoSellForce.lua" in toc:
        fail("duplicate AutoSellForce engine is still loaded by TOC")

    require(autosell, "local manualButton = gui.button(controls)", "visible AutoSell-owned button")
    require(autosell, "manualButton:SetText('Check + decide')", "manual action label")
    require(autosell, "manualButton:SetScript('OnClick', manual_request)", "manual action wiring")
    require(autosell, "manualVerifiedAt = {}", "shared manual verification timestamps")
    require(autosell, "R.market[key]", "shared AutoSell market state")
    require(autosell, "MANUAL_PROBE_START", "manual probe diagnostics")
    require(autosell, "MANUAL_PROBE_RESULT", "manual result diagnostics")
    require(autosell, "MANUAL_DONE", "manual completion diagnostics")
    require(autosell, "tab-open-stale", "fresh-owner guarded tab open")
    require(autosell, "if R.ownerCapturePending then capture_owner_page() end", "owner snapshot reuse")
    require(autosell, "stage = manualFresh and 'CANCEL_READY' or 'VERIFY_PRICE'", "manual result decision reuse")

    if "AS.RequestOwnerRefresh('tab-open')" in autosell:
        fail("AutoSell tab still performs unconditional owner refresh")
    if "AVM_AUTOSELL_FORCE" in autosell:
        fail("legacy second AutoSell state machine leaked into canonical AutoSell")

    print("AUXVMANGOS_AUTOSELL_CONTRACT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
