#!/usr/bin/env python3
import json
import unittest
from pathlib import Path

from ah_shadow_hot_bundle import ORDER, build_bundle

ROOT = Path(__file__).resolve().parents[1]
SHADOW = ROOT / "src" / "AddOns" / "AuxEconomyShadow"
RUNTIME = ROOT / "runtime" / "ah_consolidation_shadow_v2.json"


class AHDirectLiveAuthorityTests(unittest.TestCase):
    def test_direct_live_route_is_loaded_after_cutover(self):
        self.assertIn("AuxEconomyShadow_DirectLive.lua", ORDER)
        self.assertLess(ORDER.index("AuxEconomyShadow_Cutover.lua"), ORDER.index("AuxEconomyShadow_DirectLive.lua"))
        self.assertLess(ORDER.index("AuxEconomyShadow_DirectLive.lua"), ORDER.index("AuxEconomyShadow_HotPayload.lua"))
        bundle = build_bundle()
        self.assertIn(b"1-active-auxvmangos", bundle)
        self.assertIn(b"user-authorized-direct-live", bundle)

    def test_direct_live_disarms_shadow_without_mutating_aux_live_settings(self):
        text = (SHADOW / "AuxEconomyShadow_DirectLive.lua").read_text(encoding="utf-8")
        self.assertIn("AVM_DB.shadowCutoverWanted = false", text)
        self.assertIn("W112_AH_SHADOW_CUTOVER_SET", text)
        self.assertIn('authoritative = "AuxVmangos"', text)
        self.assertIn('shadowRole = "observer-only"', text)
        self.assertNotIn("AVM_DB.auxArbLive =", text)
        self.assertNotIn("AVM_DB.auxArbEnabled =", text)

    def test_runtime_contract_declares_auxvmangos_authority(self):
        data = json.loads(RUNTIME.read_text(encoding="utf-8"))
        self.assertFalse(data["delivery"]["cutover_allowed"])
        self.assertEqual(data["delivery"]["cutover_mode"], "disabled-user-authorized-direct-live")
        self.assertEqual(data["delivery"]["authoritative_live_module"], "AuxVmangos")
        self.assertEqual(data["stage"], "direct_live_active_shadow_observer")
        self.assertFalse(data["safety"]["may_submit_transactions"])
        self.assertTrue(data["safety"]["real_actions_hard_locked"])


if __name__ == "__main__":
    unittest.main()
