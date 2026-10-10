#!/usr/bin/env python3
"""Static regression contract for fleet-wide SummonScout World adverts."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
ADDON=ROOT/"src"/"AddOns"/"SummonScout"

class FleetAdvertTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.coord=(ADDON/"SummonScout_FleetAdvertCoordinator.lua").read_text(encoding="utf-8")
        cls.canon=(ADDON/"SummonScout_FleetAdvertCanonicalDiscoveryHot.lua").read_text(encoding="utf-8")
        cls.router=(ADDON/"SummonScout_FallbackRouterHot.lua").read_text(encoding="utf-8")
        cls.nowgui=(ADDON/"SummonScout_FleetAdvertNowGuiHot.lua").read_text(encoding="utf-8")
        cls.toc=(ADDON/"SummonScout.toc").read_text(encoding="utf-8").splitlines()

    def test_cold_load_order(self):
        router=self.toc.index("SummonScout_FallbackRouterHot.lua")
        counter=self.toc.index("SummonScout_FleetCounterCoordinator.lua")
        coord=self.toc.index("SummonScout_FleetAdvertCoordinator.lua")
        canon=self.toc.index("SummonScout_FleetAdvertCanonicalDiscoveryHot.lua")
        nowgui=self.toc.index("SummonScout_FleetAdvertNowGuiHot.lua")
        self.assertLess(router,counter)
        self.assertLess(counter,coord)
        self.assertLess(coord,canon)
        self.assertLess(canon,nowgui)
        self.assertNotIn("SummonScout_FleetAdvertTrustGuard.lua",self.toc)

    def test_global_default_cadence_is_five_to_eight_minutes(self):
        self.assertIn("A.DEFAULT_MIN = 300",self.coord)
        self.assertIn("A.DEFAULT_MAX = 480",self.coord)
        self.assertIn("fleetAdvertMinSeconds",self.coord)
        self.assertIn("fleetAdvertMaxSeconds",self.coord)

    def test_legacy_per_client_scheduler_is_suppressed_without_flipping_gui_preference(self):
        self.assertIn("function A.suppressLegacyScheduler()",self.coord)
        self.assertIn("s.nextSpamAt=floor",self.coord)
        self.assertNotIn("SummonScoutDB.spamEnabled=false",self.coord)

    def test_rotation_avoids_immediate_repeat(self):
        self.assertIn("not A.same(p[i],A.lastSpeaker)",self.coord)
        self.assertIn("A.lastSpeaker=speaker",self.coord)

    def test_canonical_router_provider_state_is_single_discovery_truth(self):
        self.assertIn('h.GetState, "fallbackrouter"',self.canon)
        self.assertIn('type(f.providers) == "table"',self.canon)
        self.assertIn("A.heartbeat = function() return end",self.canon)
        self.assertIn("A.onHeartbeat = function() return end",self.canon)

    def test_master_never_reuses_client_side_stale_directory(self):
        self.assertIn("A.isMaster()",self.canon)
        self.assertIn("f.directory = {}",self.canon)
        self.assertIn("DIRECTORY_TTL = 55",self.canon)
        self.assertIn('string.sub(raw, 1, 9) == "[SSFR1] D"',self.canon)

    def test_destination_labels_are_canonical_and_title_cased(self):
        for expected in ('tanaris = "Tanaris"','hyjal = "Hyjal"','silithus = "Silithus"',
                         'winterspring = "Winterspring"','hydraxian = "Hydraxis"'):
            self.assertIn(expected,self.canon)
        self.assertIn("api.GetLocationCatalog = function()",self.canon)

    def test_cross_bot_router_remains_authoritative(self):
        self.assertIn('frControl(master, "R", { customer, destination, frPlayerName() })',self.router)
        self.assertNotIn("InviteByName",self.coord)
        self.assertNotIn("CastSpell",self.coord)

    def test_only_master_can_issue_grants_and_only_master_is_accepted(self):
        self.assertIn("if not A.isMaster() or not A.enabled() then return end",self.coord)
        self.assertIn("not A.same(sender,A.master())",self.coord)
        self.assertIn('A.sendCtl(speaker,"FAG"',self.coord)

    def test_fleet_mode_fails_closed_without_master(self):
        self.assertIn("if not A.validName(A.master()) then return false end",self.canon)
        self.assertIn("return originalEnabled()",self.canon)

    def test_uncertain_or_failed_grant_never_auto_retries(self):
        self.assertIn("No automatic retry after an uncertain/failed send",self.coord)
        self.assertIn('A.schedule("grant-timeout")',self.coord)
        self.assertNotIn("A.grant() -- retry",self.coord)

    def test_now_gui_is_reload_probe_based(self):
        self.assertIn("Fleet Advert NOW",self.nowgui)
        self.assertIn("createButton()",self.nowgui)
        self.assertIn("nextProbe",self.nowgui)

    def test_control_packet_and_lua50_safety(self):
        for text in (self.coord,self.canon,self.nowgui):
            self.assertNotIn("table.unpack",text)
            self.assertNotIn("goto ",text)
            self.assertNotIn("continue",text)

if __name__=="__main__": unittest.main()
