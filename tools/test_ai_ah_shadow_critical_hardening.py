#!/usr/bin/env python3
import json
import unittest
from pathlib import Path

from ah_shadow_hot_bundle import (
    ATOMIC_BEGIN_MARKER,
    ATOMIC_END_MARKER,
    BUNDLE_PROTOCOL_REVISION,
    ORDER,
    build_bundle,
)

ROOT = Path(__file__).resolve().parents[1]
SHADOW = ROOT / "src" / "AddOns" / "AuxEconomyShadow"
TASK = ROOT / "runtime" / "parallel_tasks" / "ah-consolidation-critical-hardening-v1.json"


class AHShadowCriticalHardeningTests(unittest.TestCase):
    def test_atomic_bundle_and_anchor_contract(self):
        bundle = build_bundle()
        self.assertEqual(BUNDLE_PROTOCOL_REVISION, "v3-atomic-critical-hardening")
        self.assertEqual(bundle.count(ATOMIC_BEGIN_MARKER), 1)
        self.assertEqual(bundle.count(ATOMIC_END_MARKER), 1)
        self.assertLess(bundle.find(ATOMIC_BEGIN_MARKER), bundle.find(ATOMIC_END_MARKER))
        self.assertEqual(bundle.count(b"BeginHotPayload("), 1)
        self.assertEqual(bundle.count(b"EndHotPayload("), 1)
        self.assertLess(bundle.find(b"-- END AuxEconomyShadow_Anchor.lua"), bundle.find(ATOMIC_BEGIN_MARKER))
        self.assertLess(bundle.find(b"-- BEGIN AuxEconomyShadow_HotPayload.lua"), bundle.find(ATOMIC_END_MARKER))
        self.assertEqual(ORDER[0], "AuxEconomyShadow_Anchor.lua")

        anchor = (SHADOW / "AuxEconomyShadow_Anchor.lua").read_text(encoding="utf-8")
        for token in (
            "R.schemaVersion = 3",
            "cloneValue",
            "prepareGenerationState",
            "hardenCoordinator",
            "hardenAutoSell",
            "hardenParity",
            "hardenTransactionGuard",
            "bestActionable",
            "CutoverGate",
            "rollbackBatchSideEffects",
            "lastHotAppliedGeneration",
            "minDecisionComparisons",
            "maxShadowExtra",
            "maxShadowMiss",
            "maxDifferentCandidate",
            "maxLifecycleDiff",
        ):
            self.assertIn(token, anchor)

    def test_hot_payload_has_no_nested_batch(self):
        hot = (SHADOW / "AuxEconomyShadow_HotPayload.lua").read_text(encoding="utf-8")
        self.assertNotIn("BeginHotPayload(", hot)
        self.assertNotIn("EndHotPayload(", hot)
        self.assertIn("ReplaceModule", hot)

    def test_task_declares_economy_delivery_gate(self):
        task = json.loads(TASK.read_text(encoding="utf-8"))
        self.assertEqual(task["branch"], "feature/ah-consolidation-critical-hardening-v1")
        self.assertEqual(task["base_parallel_sha"], "4a0205fbc8091e8d172b0da6537d5ac8366e446c")
        self.assertEqual(task["status"], "coding")
        self.assertFalse(task["auto_integrate"])
        self.assertIn("economy", task["delivery_profiles"])


if __name__ == "__main__":
    unittest.main()
