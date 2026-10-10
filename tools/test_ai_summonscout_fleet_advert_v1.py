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
        cls.guard=(ADDON/"SummonScout_FleetAdvertTrustGuard.lua").read_text(encoding="utf-8")
        cls.router=(ADDON/"SummonScout_FallbackRouterHot.lua").read_text(encoding="utf-8")
        cls.toc=(ADDON/"SummonScout.toc").read_text(encoding="utf-8").splitlines()

    def test_cold_load_order(self):
        router=self.toc.index("SummonScout_FallbackRouterHot.lua")
        counter=self.toc.index("SummonScout_FleetCounterCoordinator.lua")
        coord=self.toc.index("SummonScout_FleetAdvertCoordinator.lua")
        guard=self.toc.index("SummonScout_FleetAdvertTrustGuard.lua")
        self.assertLess(router,counter)
        self.assertLess(counter,coord)
        self.assertLess(coord,guard)

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

    def test_advert_uses_live_destination_union(self):
        self.assertIn("function A.destinations()",self.coord)
        self.assertIn("A.destinationCsv()",self.coord)
        self.assertIn('table.concat(labels," / ")',self.coord)

    def test_cross_bot_router_remains_authoritative(self):
        self.assertIn('frControl(master, "R", { customer, destination, frPlayerName() })',self.router)
        self.assertNotIn("InviteByName",self.coord)
        self.assertNotIn("CastSpell",self.coord)

    def test_only_master_can_issue_grants_and_only_master_is_accepted(self):
        self.assertIn("if not A.isMaster() or not A.enabled() then return end",self.coord)
        self.assertIn("not A.same(sender,A.master())",self.coord)
        self.assertIn('A.sendCtl(speaker,"FAG"',self.coord)

    def test_untrusted_provider_heartbeat_is_blocked(self):
        self.assertIn("A.trustedPeer=trusted",self.guard)
        self.assertIn("if not trusted(sender) then",self.guard)
        self.assertIn('h.GetState,"fallbackrouter"',self.guard)
        self.assertIn("f.peers[key]",self.guard)
        self.assertIn("providers[key]",self.guard)

    def test_fleet_mode_fails_closed_without_master(self):
        self.assertIn("if not A.validName(A.master()) then return false end",self.guard)
        self.assertIn("return originalEnabled()",self.guard)

    def test_uncertain_or_failed_grant_never_auto_retries(self):
        self.assertIn("No automatic retry after an uncertain/failed send",self.coord)
        self.assertIn('A.schedule("grant-timeout")',self.coord)
        self.assertNotIn("A.grant() -- retry",self.coord)

    def test_control_packet_and_lua50_safety(self):
        for text in (self.coord,self.guard):
            self.assertIn("[SSFR1]",self.coord)
            self.assertNotIn("table.unpack",text)
            self.assertNotIn("goto ",text)
            self.assertNotIn("continue",text)

if __name__=="__main__": unittest.main()
