#!/usr/bin/env python3
"""Regression contract for Tanaris full-service + Teletanaris fixed pair ownership."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
ADDON=ROOT/"src"/"AddOns"/"SummonScout"

class TanarisFullServiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.core=(ADDON/"SummonScout.lua").read_text(encoding="utf-8")
        cls.pairs=(ADDON/"SummonScout_SlaveMasterPairHot.lua").read_text(encoding="utf-8")
        cls.tanaris=(ADDON/"SummonScout_TanarisFullServiceHot.lua").read_text(encoding="utf-8")
        cls.hub=(ADDON/"SummonScout_FallbackRouterHubAckHot.lua").read_text(encoding="utf-8")
        cls.toc=(ADDON/"SummonScout.toc").read_text(encoding="utf-8").splitlines()

    def test_core_catalog_already_recognizes_tanaris(self):
        self.assertIn('id="tanaris", label="Tanaris"', self.core)

    def test_pair_module_loaded_and_owns_both_tanaris_slaves(self):
        self.assertIn("SummonScout_SlaveMasterPairHot.lua", self.toc)
        self.assertIn('tanarisone="Teletanaris"', self.pairs)
        self.assertIn('tanaristwo="Teletanaris"', self.pairs)
        self.assertIn('teletanaris={"Tanarisone","Tanaristwo"}', self.pairs)
        self.assertIn('local MASTER_INITIATED = { teletanaris=true }', self.pairs)

    def test_master_bootstraps_and_repairs_missing_slaves(self):
        self.assertIn("inviteMissingSlaves(player,MASTER_INITIATED[player] and true or false)", self.pairs)
        self.assertIn("InviteByName(slave)", self.pairs)
        self.assertIn('if key(master)~="teletanaris" then inviteMaster(master) end', self.pairs)

    def test_trusted_accept_and_leader_handoff_preserved(self):
        self.assertIn('H.RegisterEvent("PARTY_INVITE_REQUEST")', self.pairs)
        self.assertIn("AcceptGroup()", self.pairs)
        self.assertIn("PromoteByName(name)", self.pairs)
        self.assertIn("local ok,relation=trusted", self.pairs)

    def test_tanaris_is_in_total_fallback_pool(self):
        self.assertIn('"tanaris" }', self.hub)
        self.assertIn('id=="tanaris"', self.hub)
        self.assertIn('silithus,winterspring,hydraxian,hyjal,tanaris', self.hub)
        self.assertIn('if id=="tanaris" then return "Tanaris" end', self.hub)

    def test_tanaris_fleet_patch_is_loaded_after_coordinator(self):
        fleet=self.toc.index("SummonScout_FleetCounterCoordinator.lua")
        patch=self.toc.index("SummonScout_TanarisFullServiceHot.lua")
        self.assertGreater(patch,fleet)
        self.assertIn('C.EXPECTED={"hydraxian","hyjal","winterspring","silithus","tanaris"}', self.tanaris)
        self.assertIn('C.ALLOWED.tanaris=true', self.tanaris)
        self.assertIn('C.LABEL.tanaris="TANARIS"', self.tanaris)
        self.assertIn('fleetCounterRolloutVersion=2', self.tanaris)

    def test_teletanaris_defaults_to_tanaris_service_without_overriding_specific_config(self):
        self.assertIn('if me()=="teletanaris" then', self.tanaris)
        self.assertIn('if service=="" or service=="all" then SummonScoutDB.service=TANARIS end', self.tanaris)

    def test_pair_slaves_are_never_customer_invite_targets(self):
        self.assertIn("inviteBlacklist.tanarisone", self.pairs)
        self.assertIn("inviteBlacklist.tanaristwo", self.pairs)

    def test_lua50_safety(self):
        for text in (self.pairs,self.tanaris,self.hub):
            self.assertNotIn("table.unpack",text)
            self.assertNotIn("goto ",text)
            self.assertNotIn("continue",text)

if __name__=="__main__": unittest.main()
