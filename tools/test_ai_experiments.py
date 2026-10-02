#!/usr/bin/env python3
"""Regression tests for fail-closed routing and the experiment evidence ledger."""
import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.ai_experiments import INDEX, LEDGER, build_index, render_index, route, validate
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

    def test_compact_index_is_current_and_omits_heavy_evidence(self):
        expected = build_index(self.data, self.entries)
        stored_text = INDEX.read_text(encoding="utf-8")
        self.assertEqual(json.loads(stored_text), expected)
        self.assertEqual(stored_text, render_index(self.data, self.entries))
        self.assertLess(len(stored_text), len(LEDGER.read_text(encoding="utf-8")))
        for summary in expected["experiments"].values():
            self.assertNotIn("notes", summary)
            self.assertNotIn("tests", summary)
            self.assertNotIn("shared_resources", summary)

    def test_compact_index_module_active_ids_match_ledger(self):
        compact = build_index(self.data, self.entries)
        active_states = {"planned", "in_progress", "awaiting_ci", "awaiting_game_test", "blocked"}
        for module, slot in compact["modules"].items():
            expected = sorted(
                row["id"] for row in self.entries
                if module in row["modules"] and row["status"] in active_states
            )
            self.assertEqual(slot["active"], expected)

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

    def test_game_test_evidence_and_package_provenance(self):
        game_tests = [
            event
            for entry in self.entries
            for event in entry["tests"]
            if event["kind"] == "game"
        ]
        # Real gameplay results belong in the ledger once the user reports
        # them. Keep this regression fail-closed by requiring the same exact
        # SHA/date/non-empty evidence contract enforced by validate(), rather
        # than forbidding game evidence entirely.
        for event in game_tests:
            self.assertIn(event["result"], {"passed", "failed", "inconclusive"})
            self.assertRegex(event["commit"], r"^[0-9a-f]{40}$")
            self.assertRegex(event["date"], r"^\d{4}-\d{2}-\d{2}$")
            self.assertTrue(event["evidence"].strip())

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
