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
TASK = ROOT / "runtime" / "parallel_tasks" / "ah-consolidation-critical-hardening-v1-r2.json"
POLICY = ROOT / "runtime" / "parallel_thread_policy.json"
PREFLIGHT_WORKFLOW = ROOT / ".github" / "workflows" / "parallel_feature_preflight.yml"
BUNDLE_BUILDER = ROOT / "tools" / "ah_shadow_hot_bundle.py"


class AHShadowCriticalHardeningTests(unittest.TestCase):
    def test_atomic_bundle_and_anchor_contract(self):
        bundle = build_bundle()
        self.assertEqual(BUNDLE_PROTOCOL_REVISION, "v5-host-independent-shadow")
        self.assertEqual(bundle.count(ATOMIC_BEGIN_MARKER), 1)
        self.assertEqual(bundle.count(ATOMIC_END_MARKER), 1)
        self.assertLess(bundle.find(ATOMIC_BEGIN_MARKER), bundle.find(ATOMIC_END_MARKER))
        self.assertEqual(bundle.count(b"W112_AH_SHADOW.BeginHotPayload("), 1)
        self.assertEqual(bundle.count(b"W112_AH_SHADOW.EndHotPayload("), 1)
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

    def test_lua50_guard_is_preserved(self):
        builder = BUNDLE_BUILDER.read_text(encoding="utf-8")
        self.assertIn("LUA51_LENGTH_OPERATOR", builder)
        self.assertIn("_assert_lua50_compatible", builder)
        self.assertNotIn("out[#out + 1]", (SHADOW / "AuxEconomyShadow_Parity.lua").read_text(encoding="utf-8"))

    def test_hot_payload_has_no_nested_batch(self):
        hot = (SHADOW / "AuxEconomyShadow_HotPayload.lua").read_text(encoding="utf-8")
        self.assertNotIn("BeginHotPayload(", hot)
        self.assertNotIn("EndHotPayload(", hot)
        self.assertIn("ReplaceModule", hot)

    def test_task_declares_exact_successor_and_economy_gate(self):
        task = json.loads(TASK.read_text(encoding="utf-8"))
        self.assertEqual(task["branch"], "feature/ah-consolidation-critical-hardening-v1-r2")
        self.assertEqual(task["base_parallel_sha"], "ef8dc204e8f2f8e7b808a38b2aa3a4b776fd9116")
        self.assertEqual(task["status"], "integrated")
        self.assertEqual(task["integrated_feature_sha"], "89e2d4b06d436b05bea6a3f45a624a7c6ba253cc")
        self.assertFalse(task["auto_integrate"])
        self.assertIn("economy", task["delivery_profiles"])

    def test_shadow_paths_are_economy_routed(self):
        policy = json.loads(POLICY.read_text(encoding="utf-8"))
        paths = set(policy["delivery_profiles"]["economy"]["required_paths"])
        for path in (
            "src/AddOns/AuxEconomyShadow/",
            "tools/ah_shadow_hot_bundle.py",
            "tools/verify_ah_consolidation_shadow_v2.py",
            "runtime/ah_consolidation_shadow_v2.json",
        ):
            self.assertIn(path, paths)

    def test_declared_profile_gate_does_not_require_auto_integration(self):
        workflow = PREFLIGHT_WORKFLOW.read_text(encoding="utf-8")
        profile_block = workflow.split("  profile_gates:", 1)[1].split("\n  integrate:", 1)[0]
        self.assertIn("needs.preflight.outputs.delivery_profiles != ''", profile_block)
        self.assertNotIn("needs.preflight.outputs.auto_integrate == 'true'", profile_block)
        integrate_block = workflow.split("\n  integrate:", 1)[1]
        self.assertIn("needs.preflight.outputs.auto_integrate == 'true'", integrate_block)


if __name__ == "__main__":
    unittest.main()
