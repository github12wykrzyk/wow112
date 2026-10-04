#!/usr/bin/env python3
import json
import re
import unittest
from pathlib import Path

from ah_shadow_hot_bundle import ORDER, build_bundle

ROOT = Path(__file__).resolve().parents[1]
SHADOW = ROOT / "src" / "AddOns" / "AuxEconomyShadow"
TASK = ROOT / "runtime" / "parallel_tasks" / "ah-cutover-authoritative-gate-v1.json"


class AHCutoverAuthoritativeGateTests(unittest.TestCase):
    def test_cutover_is_hot_bundled_after_parity_export(self):
        self.assertIn("AuxEconomyShadow_Cutover.lua", ORDER)
        self.assertLess(ORDER.index("AuxEconomyShadow_ParityExport.lua"), ORDER.index("AuxEconomyShadow_Cutover.lua"))
        self.assertLess(ORDER.index("AuxEconomyShadow_Cutover.lua"), ORDER.index("AuxEconomyShadow_HotPayload.lua"))
        bundle = build_bundle()
        self.assertIn(b"2-authoritative-approval-gate", bundle)
        self.assertIn(b"v6-cutover-authoritative-gate", bundle)

    def test_cutover_requires_current_positive_exact_match(self):
        text = (SHADOW / "AuxEconomyShadow_Cutover.lua").read_text(encoding="utf-8")
        for token in (
            'BASELINE_EVIDENCE_ISSUE = 309',
            'BASELINE_DECISIONS = 1214',
            'positive-match-required',
            'candidate-not-matched',
            'recorded-parity-mismatch',
            'maxShadowExtra = 0',
            'maxShadowMiss = 0',
            'maxDifferentCandidate = 0',
            'maxLifecycleDiff = 0',
            'bridge.HooksIntact',
            'observerErrors',
            'PlaceAuctionBid = state.bidWrapper',
            'state.previousPlaceAuctionBid',
            'pcall(state.previousPlaceAuctionBid',
        ):
            self.assertIn(token, text)

    def test_cutover_fixes_scan_done_selected_alias_without_touching_active_avm(self):
        text = (SHADOW / "AuxEconomyShadow_Cutover.lua").read_text(encoding="utf-8")
        self.assertIn("result.selected = result.selectedPostscan", text)
        self.assertNotIn("AVM_AuxArbScanDone =", text)
        self.assertNotIn("AVM_AuxArbPageDone =", text)
        self.assertNotIn("QueryAuctionItems(", text)
        self.assertNotIn("CancelAuction(", text)
        self.assertNotIn("StartAuction(", text)
        self.assertNotIn("CreateFrame(", text)
        self.assertNotIn("SetScript(", text)

    def test_parity_export_feeds_cutover_with_decision_pair(self):
        text = (SHADOW / "AuxEconomyShadow_ParityExport.lua").read_text(encoding="utf-8")
        self.assertIn('R.GetModule("cutover")', text)
        self.assertIn("cutover.ObserveDecision", text)
        self.assertIn("active, shadow, at, note", text)

    def test_transaction_guard_is_armable_but_anchor_still_gates_enable(self):
        guard = (SHADOW / "AuxEconomyShadow_TransactionGuard.lua").read_text(encoding="utf-8")
        anchor = (SHADOW / "AuxEconomyShadow_Anchor.lua").read_text(encoding="utf-8")
        self.assertIn('REVISION = "2-cutover-armable"', guard)
        self.assertIn("state.realActionsEnabled = enabled and true or false", guard)
        self.assertIn("MarkDispatched", guard)
        self.assertIn("Reconcile", guard)
        self.assertNotIn("shadow-real-actions-locked", guard)
        self.assertIn("parity.CutoverGate(policy)", anchor)
        self.assertIn('return false, "parity-gate:" .. tostring(reason)', anchor)

    def test_lua50_and_cutover_syntax_surface(self):
        for name in (
            "AuxEconomyShadow_Cutover.lua",
            "AuxEconomyShadow_TransactionGuard.lua",
            "AuxEconomyShadow_ParityExport.lua",
        ):
            text = (SHADOW / name).read_text(encoding="utf-8")
            for line in text.splitlines():
                code = line.split("--", 1)[0]
                self.assertIsNone(re.search(r"#\s*[A-Za-z_(]", code), msg=name + ": " + line)
            for forbidden in (
                "!=",
                "ok Arm",
                "ready Reason",
                'publish("blocked-mismatch"\n',
                'error("utover',
            ):
                self.assertNotIn(forbidden, text, msg=name + ": " + forbidden)

    def test_task_is_isolated_and_economy_gated(self):
        task = json.loads(TASK.read_text(encoding="utf-8"))
        self.assertEqual(task["branch"], "feature/ah-cutover-authoritative-gate-v1")
        self.assertEqual(task["base_parallel_sha"], "9b743815820bf68dcff2f4c483b3d430ac954de7")
        self.assertEqual(task["status"], "preflight")
        self.assertFalse(task["auto_integrate"])
        self.assertEqual(task["delivery_profiles"], ["economy"])
        self.assertIn("AuxEconomyShadow", task["modules"])
        self.assertIn("AuxVmangos", task["modules"])
        self.assertIn("resource:auxvmangos-real-action-gate", task["lease"]["scopes"])


if __name__ == "__main__":
    unittest.main()
