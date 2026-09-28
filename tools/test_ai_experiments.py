#!/usr/bin/env python3
"""Regression tests for fail-closed routing and the experiment evidence ledger."""
import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.ai_experiments import LEDGER, route, validate
import json


class ExperimentRoutingTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads(LEDGER.read_text(encoding="utf-8"))
        self.entries = validate(self.data)

    def test_real_entries_validate(self):
        expected_ids = {row["id"] for row in self.data["experiments"]}
        actual_ids = {row["id"] for row in self.entries}
        self.assertEqual(actual_ids, expected_ids)
        self.assertEqual(len(self.entries), len(self.data["experiments"]))

    def test_explicit_parallel_does_not_switch_to_work(self):
        self.assertEqual(route(self.entries, "MovementCore", "parallel")["branch"], "parallel")

    def test_unselected_shared_module_is_ambiguous(self):
        self.assertEqual(route(self.entries, "MovementCore")["decision"], "ambiguous")

    def test_unique_existing_experiment_is_reused(self):
        self.assertEqual(route(self.entries, "RogueMovementCore")["branch"], "parallel")

    def test_new_module_requests_isolated_feature(self):
        found = route(self.entries, "NewModule")
        self.assertEqual(found["decision"], "new_feature")
        self.assertIsNone(found["branch"])

    def test_no_direct_main_or_promotion_route(self):
        for branch in ("main", "promote/move"):
            with self.subTest(branch=branch), self.assertRaises(ValueError):
                route(self.entries, "MovementCore", branch)

    def test_no_invented_game_test_or_package(self):
        game_tests = [
            event
            for entry in self.entries
            for event in entry["tests"]
            if event["kind"] == "game"
        ]
        self.assertEqual(game_tests, [])

        for entry in self.entries:
            package = entry["package"]
            if package is None:
                continue
            self.assertTrue(package["verified"])
            self.assertEqual(package["commit"], entry["verified_commit"])
            self.assertTrue(any(
                event["kind"] == "package"
                and event["result"] == "passed"
                and event["commit"] == package["commit"]
                for event in entry["tests"]
            ))

    def test_unknown_dependency_fails(self):
        obj = copy.deepcopy(self.data)
        obj["experiments"][0]["dependencies"] = ["missing-experiment"]
        with self.assertRaises(ValueError):
            validate(obj)

    def test_dependency_cycle_fails(self):
        obj = copy.deepcopy(self.data)
        obj["experiments"][0]["dependencies"] = ["parallel-rogue"]
        obj["experiments"][1]["dependencies"] = ["work-runtime"]
        with self.assertRaises(ValueError):
            validate(obj)

    def test_invalid_test_evidence_fails(self):
        obj = copy.deepcopy(self.data)
        obj["experiments"][0]["tests"] = [{"kind": "game", "result": "passed",
                                            "commit": "a" * 40, "date": "2026-09-21",
                                            "evidence": ""}]
        with self.assertRaises(ValueError):
            validate(obj)


if __name__ == "__main__":
    unittest.main()
