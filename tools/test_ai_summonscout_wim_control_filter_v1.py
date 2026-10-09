import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "src" / "AddOns" / "SummonScout" / "SummonScout_WhisperRelaySpamGuardHot.lua"


class SummonScoutWimControlFilterV1(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = GUARD.read_text(encoding="utf-8")

    def test_transport_families_are_blocked_but_master_reports_are_visible(self):
        self.assertIn('local WIM_FILTER_PATTERN = "%[SSWR1%]"', self.lua)
        self.assertIn('local WIM_FALLBACK_FILTER_PATTERN = "%[SSFR1%]"', self.lua)
        self.assertIn('local LEGACY_WIM_MASTER_FILTER_PATTERN = "%[SSI "', self.lua)
        self.assertIn('WIM_Filters[WIM_FILTER_PATTERN] = "Block"', self.lua)
        self.assertIn('WIM_Filters[WIM_FALLBACK_FILTER_PATTERN] = "Block"', self.lua)
        self.assertNotIn('WIM_Filters[LEGACY_WIM_MASTER_FILTER_PATTERN] = "Block"', self.lua)
        self.assertIn('WIM_Filters[LEGACY_WIM_MASTER_FILTER_PATTERN] = nil', self.lua)

    def test_filter_self_repairs_on_update(self):
        start = self.lua.index("local function sgWrappedOnUpdate()")
        end = self.lua.index("local function sgWrappedOnEvent", start)
        self.assertIn("sgInstallWimSuppression()", self.lua[start:end])

    def test_no_new_send_path(self):
        self.assertNotIn("SendChatMessage", self.lua)


if __name__ == "__main__":
    unittest.main()
