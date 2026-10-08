import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOTFIX = ROOT / "src" / "AddOns" / "SummonScout" / "SummonScout_FallbackRouterHubAckHot.lua"
TOC = ROOT / "src" / "AddOns" / "SummonScout" / "SummonScout.toc"


class SummonScoutTotalPoolHotfixTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.hotfix = HOTFIX.read_text(encoding="utf-8")
        cls.toc = TOC.read_text(encoding="utf-8")

    def test_exact_total_pool_is_canonical(self):
        self.assertIn('local TOTAL_POOL = { "silithus", "winterspring", "hydraxian", "hyjal" }', self.hotfix)
        self.assertIn('W112_SUMMONSCOUT_TOTAL_POOL_CSV = "silithus,winterspring,hydraxian,hyjal"', self.hotfix)

    def test_pool_is_seeded_into_router_directory(self):
        self.assertIn("F.totalPool[id] = true", self.hotfix)
        self.assertIn("F.directory[id] = true", self.hotfix)

    def test_provider_ownership_is_learned_from_existing_hello_protocol(self):
        self.assertIn('parts[1] ~= "H"', self.hotfix)
        self.assertIn("rememberServices(a2 or \"\", services)", self.hotfix)
        self.assertIn("SummonScoutDB.totalPoolOwners", self.hotfix)

    def test_last_known_owner_is_reseeded_without_bypassing_ack(self):
        self.assertIn("F.providers[id]", self.hotfix)
        self.assertIn("totalPoolSticky = true", self.hotfix)
        self.assertIn('if tostring(status or "") == "1" then', self.hotfix)
        self.assertIn('is currently unavailable. Please try again shortly.', self.hotfix)

    def test_existing_hot_module_path_is_reused(self):
        self.assertIn("SummonScout_FallbackRouterHubAckHot.lua", self.toc)
        self.assertNotIn("SummonScout_TotalPoolHot.lua", self.toc)


if __name__ == "__main__":
    unittest.main()
