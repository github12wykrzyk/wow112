#!/usr/bin/env python3
"""Regression tests for the diagnostic ECONOMY hotfix classifier."""
import unittest

from tools.parallel_diagnostic_fastpath import classify


class ParallelDiagnosticFastPathTests(unittest.TestCase):
    def setUp(self):
        self.config = {
            "opt_in_field": "diagnostic_hotfix_fast_path",
            "required_delivery_profiles": ["economy"],
            "allowed_modules": ["AuxEconomyShadow"],
            "allowed_payload_paths": [
                "src/AddOns/AuxEconomyShadow/AuxEconomyShadow_ParityExport.lua",
                "src/AddOns/AuxEconomyShadow/AuxEconomyShadow_HotPayload.lua",
            ],
            "forbidden_added_tokens": [
                "transaction",
                "ownership",
                "cutover",
                "placeauctionbid",
                "startauction",
                "cancelauction",
                "queryauctionitems",
                "buyout",
                "autosell",
            ],
        }
        self.task_id = "diag-safe"
        self.task_path = "runtime/parallel_tasks/diag-safe.json"
        self.payload = "src/AddOns/AuxEconomyShadow/AuxEconomyShadow_ParityExport.lua"
        self.task = {
            "id": self.task_id,
            "branch": "feature/diag-safe",
            "modules": ["AuxEconomyShadow"],
            "delivery_profiles": ["economy"],
            "diagnostic_hotfix_fast_path": True,
        }

    def run_classify(self, task=None, paths=None, added=None):
        return classify(
            task or dict(self.task),
            self.config,
            self.task_id,
            paths or [self.task_path, self.payload],
            added or {self.payload: 'frame:AddMessage("ping")'},
        )

    def test_no_opt_in_requires_standard(self):
        task = dict(self.task)
        task.pop("diagnostic_hotfix_fast_path")
        result = self.run_classify(task=task)
        self.assertTrue(result["require_standard"])
        self.assertEqual(result["reason"], "not_opted_in")

    def test_allowlisted_diagnostic_payload_skips_standard(self):
        result = self.run_classify()
        self.assertFalse(result["require_standard"])
        self.assertTrue(result["fast_path"])

    def test_wrong_profile_requires_standard(self):
        task = dict(self.task)
        task["delivery_profiles"] = ["economy", "updater"]
        result = self.run_classify(task=task)
        self.assertTrue(result["require_standard"])
        self.assertEqual(result["reason"], "delivery_profile_mismatch")

    def test_unallowlisted_module_requires_standard(self):
        task = dict(self.task)
        task["modules"] = ["AuxEconomyShadow", "AHThrottleNative"]
        result = self.run_classify(task=task)
        self.assertTrue(result["require_standard"])
        self.assertEqual(result["reason"], "module_not_allowlisted")

    def test_unallowlisted_lua_requires_standard(self):
        bid = "src/AddOns/AuxEconomyShadow/AuxEconomyShadow_Bid.lua"
        result = self.run_classify(paths=[self.task_path, bid], added={bid: "local x = 1"})
        self.assertTrue(result["require_standard"])
        self.assertEqual(result["reason"], "path_not_allowlisted")

    def test_forbidden_added_token_requires_standard(self):
        result = self.run_classify(added={self.payload: "QueryAuctionItems(\"Runecloth\")"})
        self.assertTrue(result["require_standard"])
        self.assertEqual(result["reason"], "forbidden_added_token:queryauctionitems")

    def test_task_record_only_requires_standard(self):
        result = self.run_classify(paths=[self.task_path], added={})
        self.assertTrue(result["require_standard"])
        self.assertEqual(result["reason"], "no_hot_payload_change")


if __name__ == "__main__":
    unittest.main()
