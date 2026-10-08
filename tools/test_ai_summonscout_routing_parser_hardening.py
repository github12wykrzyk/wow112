import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"


class SummonScoutRoutingParserHardeningContract(unittest.TestCase):
    def text(self, name):
        return (ADDON / name).read_text(encoding="utf-8")

    def test_world_parser_has_shorthand_and_multidestination_guards(self):
        text = self.text("SummonScout_RosterOwnershipHot.lua")
        self.assertIn('local VERSION = "6-world-intent-multidest-guard"', text)
        self.assertIn('local WORLD_BUYER_CUES = {', text)
        for cue in ('"wtb"', '"need"', '"lf"', '"pls"', '"port"', '"taxi"'):
            self.assertIn(cue, text)
        self.assertIn('return tostring(message or "") .. " summon", true, locations, nil', text)
        self.assertIn('"multiple-destinations"', text)
        self.assertIn('SummonScoutDB.autoInvite = false', text)

    def test_postpay_direct_prefix_is_route_guarded_without_blocking_fallback(self):
        text = self.text("SummonScout_PostPaymentRouteGuardHot.lua")
        self.assertIn('reason == "other-location" or reason == "ambiguous-location"', text)
        self.assertIn('return true, "commerce-chatter"', text)
        self.assertIn('H.modules["postpay"] = nil', text)
        self.assertIn('H.modules["postpay"] = postpay', text)
        self.assertIn('return OWN_BASE()', text)

    def test_route_guard_loads_last(self):
        toc = self.text("SummonScout.toc").splitlines()
        guard = toc.index("SummonScout_PostPaymentRouteGuardHot.lua")
        error_guard = toc.index("SummonScout_CoreErrorGuardHot.lua")
        destination_guard = toc.index("SummonScout_DestinationInfoGuardHot.lua")
        self.assertGreater(guard, error_guard)
        self.assertGreater(guard, destination_guard)


if __name__ == "__main__":
    unittest.main()
