#!/usr/bin/env python3
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRIMARY = ROOT / "src/AddOns/SummonScout/SummonScout_PostPaymentOfferHot.lua"
FALLBACK = ROOT / "src/AddOns/SummonScout/SummonScout_PostPaymentFallbackHot.lua"


class SummonScoutPostpayLiveDestinationsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.primary = PRIMARY.read_text(encoding="utf-8")
        cls.fallback = FALLBACK.read_text(encoding="utf-8")

    def test_primary_uses_live_fallback_router_directory(self):
        self.assertIn('H.GetState("fallbackrouter")', self.primary)
        self.assertIn("F.directory", self.primary)
        self.assertIn("F.providers", self.primary)
        self.assertIn("POSTPAY_PROVIDER_TTL = 38.0", self.primary)

    def test_primary_excludes_own_service_and_formats_all_other_routes(self):
        self.assertIn("ppLocalServiceSet", self.primary)
        self.assertIn("localServices[id]", self.primary)
        self.assertIn("ppJoinLabels", self.primary)
        self.assertIn('hyjal = "Hyjal"', self.primary)
        self.assertIn('hydraxian = "Hydraxis"', self.primary)
        self.assertIn('winterspring = "Winterspring"', self.primary)
        self.assertIn('"Thanks. We also summon to "', self.primary)

    def test_no_static_three_destination_marketing_remains(self):
        stale = "Hyjal, Hydraxis and Winterspring"
        self.assertNotIn(stale, self.primary)
        self.assertNotIn(stale, self.fallback)

    def test_zero_other_routes_fails_safe_to_thank_only(self):
        self.assertIn("POSTPAY_THANK_MESSAGES", self.primary)
        self.assertIn('return "Thank you!"', self.fallback)
        self.assertIn("never advertise a destination whose provider state we cannot verify", self.fallback)

    def test_fallback_reuses_primary_dynamic_builder_and_detector(self):
        self.assertIn("H.BuildPostPaymentOfferMessage", self.primary)
        self.assertIn("H.IsPostPaymentOfferMessage", self.primary)
        self.assertIn("H.BuildPostPaymentOfferMessage", self.fallback)
        self.assertIn("H.IsPostPaymentOfferMessage", self.fallback)
        self.assertIn('string.find(s, "we also summon to ", 1, true)', self.fallback)

    def test_lua50_surface_stays_conservative(self):
        for source in (self.primary, self.fallback):
            self.assertNotIn("#", source)
            self.assertNotIn("ipairs(", source)
            self.assertNotIn("goto ", source)


if __name__ == "__main__":
    unittest.main()
