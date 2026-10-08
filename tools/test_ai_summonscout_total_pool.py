import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"
POOL = ADDON / "SummonScout_TotalPoolHot.lua"
TOC = ADDON / "SummonScout.toc"


class SummonScoutTotalPoolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pool = POOL.read_text(encoding="utf-8")
        cls.toc = TOC.read_text(encoding="utf-8")

    def test_exact_operator_pool_is_declared(self):
        for destination in ("silithus", "winterspring", "hydraxian", "hyjal"):
            self.assertIn('"%s"' % destination, self.pool)
        self.assertIn(
            'W112_SUMMONSCOUT_TOTAL_POOL_CSV = "silithus,winterspring,hydraxian,hyjal"',
            self.pool,
        )

    def test_total_pool_overlays_fallback_directory(self):
        self.assertIn('F.directory = F.directory or {}', self.pool)
        self.assertIn('F.directory[id] = true', self.pool)
        self.assertIn('F.totalPool[id] = true', self.pool)

    def test_module_loads_after_router_before_info_guard(self):
        router = self.toc.index("SummonScout_FallbackRouterHubAckHot.lua")
        pool = self.toc.index("SummonScout_TotalPoolHot.lua")
        guard = self.toc.index("SummonScout_DestinationInfoGuardHot.lua")
        self.assertLess(router, pool)
        self.assertLess(pool, guard)


if __name__ == "__main__":
    unittest.main()
