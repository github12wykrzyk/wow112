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
AH_SESSION = ADDON / "AuxVmangos_AutoSellAHSession.lua"
LIFECYCLE = ADDON / "AuxVmangos_AutoSellLifecycle.lua"


def fail(message: str) -> None:
    print("AUXVMANGOS_AUTOSELL_CONTRACT: FAIL: " + message)
    raise SystemExit(1)


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        fail(f"missing {label}: {needle!r}")


def main() -> int:
    if not TOC.is_file() or not AUTOSELL.is_file() or not POST_DEFAULTS.is_file() or not AH_SESSION.is_file() or not LIFECYCLE.is_file():
        fail("required AuxVmangos files are missing")
    if FORCE.exists():
        fail("obsolete AuxVmangos_AutoSellForce.lua must not exist in the active source tree")

    toc = TOC.read_text(encoding="utf-8")
    autosell = AUTOSELL.read_text(encoding="utf-8")
    ah_session = AH_SESSION.read_text(encoding="utf-8")
    lifecycle = LIFECYCLE.read_text(encoding="utf-8")

    require(toc, "AuxVmangos_AutoSell.lua", "AutoSell TOC entry")
    require(toc, "AuxVmangos_PostDefaults.lua", "PostDefaults TOC entry")
    require(toc, "AuxVmangos_AutoSellAHSession.lua", "AutoSell AH-session compatibility TOC entry")
    require(toc, "AuxVmangos_AutoSellLifecycle.lua", "AutoSell lifecycle TOC entry")
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

    require(ah_session, "if not (AVM and AVM.open) then return false end", "canonical AVM.open session gate")
    require(ah_session, "tostring(tab.name or '') == 'AutoSell'", "AutoSell-only visibility scope")
    require(ah_session, "C.originalIsVisible = AuctionFrame.IsVisible", "original AuctionFrame visibility preservation")
    require(ah_session, "return C.originalIsVisible(self)", "non-AutoSell visibility fallback")

    require(lifecycle, "AVM_DB.auxLoopRequested", "persistent loop intent")
    require(lifecycle, "scan_or_transaction_active", "separate active scan/transaction state")
    require(lifecycle, "LOOP OFF zapisany; bieżący scan/transaction kończy się normalnie", "graceful loop-off contract")
    require(lifecycle, "p.auctionSignature = pending_signature(slot, p)", "concrete pending auction identity")
    require(lifecycle, "p.mailBagBaseline = bag_quantity(itemKey)", "pre-mail bag baseline")
    require(lifecycle, "AVM_DB.autoSellLastMailEventAt", "mailbox retrieval evidence")
    require(lifecycle, "p.mailBagDelta >= count", "repost bag delta gate")
    require(lifecycle, "p.ownerGone = false", "repost withheld before mail evidence")

    if "AS.RequestOwnerRefresh('tab-open')" in autosell:
        fail("AutoSell tab still performs unconditional owner refresh")
    if "AVM_AUTOSELL_FORCE" in autosell:
        fail("legacy second AutoSell state machine leaked into canonical AutoSell")

    print("AUXVMANGOS_AUTOSELL_CONTRACT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
