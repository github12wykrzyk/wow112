#!/usr/bin/env python3
import json
import unittest
from pathlib import Path

from parallel_delivery_route import classify

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / "runtime/parallel_delivery_routing.json").read_text(encoding="utf-8"))


def task(profiles=None):
    return {
        "id": "route-test",
        "branch": "feature/route-test",
        "delivery_profiles": list(profiles or []),
    }


class ParallelDeliveryRouteTests(unittest.TestCase):
    def test_docs_and_task_record_skip_standard(self):
        result = classify(
            task(), CONFIG, "route-test",
            ["docs/ROUTING.md", "runtime/parallel_tasks/route-test.json"],
        )
        self.assertFalse(result["require_standard"])
        self.assertEqual(result["reason"], "validation_only")

    def test_economy_only_uses_profile_without_standard(self):
        result = classify(
            task(["economy"]), CONFIG, "route-test",
            ["src/AddOns/AuxVmangos/AuxVmangos.lua", "runtime/parallel_tasks/route-test.json"],
        )
        self.assertFalse(result["require_standard"])
        self.assertEqual(result["profiles_used"], ["economy"])

    def test_economy_source_without_declared_profile_fails_closed(self):
        result = classify(
            task(), CONFIG, "route-test",
            ["src/AddOns/AuxVmangos/AuxVmangos.lua", "runtime/parallel_tasks/route-test.json"],
        )
        self.assertTrue(result["require_standard"])
        self.assertIn("src/AddOns/AuxVmangos/AuxVmangos.lua", result["uncovered_paths"])

    def test_updater_only_uses_profile_without_standard(self):
        result = classify(
            task(["updater"]), CONFIG, "route-test",
            ["tools/updater/WoW112Updater.cs", "runtime/parallel_tasks/route-test.json"],
        )
        self.assertFalse(result["require_standard"])
        self.assertEqual(result["profiles_used"], ["updater"])

    def test_autologinbridge_only_uses_profile_without_standard(self):
        result = classify(
            task(["autologinbridge"]), CONFIG, "route-test",
            ["src/AutoLoginBridge/WoWAutoLoginBridge_5875_v1_HOTPROBE.c", "runtime/parallel_tasks/route-test.json"],
        )
        self.assertFalse(result["require_standard"])
        self.assertEqual(result["profiles_used"], ["autologinbridge"])

    def test_cross_profile_change_runs_both_profiles_without_standard(self):
        result = classify(
            task(["economy", "updater"]), CONFIG, "route-test",
            [
                "src/AddOns/AuxFastBridge/AuxFastBridge.lua",
                "tools/updater/WoW112Updater.cs",
                "runtime/parallel_tasks/route-test.json",
            ],
        )
        self.assertFalse(result["require_standard"])
        self.assertEqual(result["profiles_used"], ["economy", "updater"])

    def test_generic_summonscout_lua_still_requires_standard(self):
        result = classify(
            task(), CONFIG, "route-test",
            ["src/AddOns/SummonScout/SummonScout.lua", "runtime/parallel_tasks/route-test.json"],
        )
        self.assertTrue(result["require_standard"])

    def test_native_core_requires_standard(self):
        result = classify(
            task(), CONFIG, "route-test",
            ["src/MovementCore/WoWMovementCore_5875_v21_ALT_PRIORITY.c", "runtime/parallel_tasks/route-test.json"],
        )
        self.assertTrue(result["require_standard"])

    def test_mixed_economy_and_native_requires_standard(self):
        result = classify(
            task(["economy"]), CONFIG, "route-test",
            [
                "src/AddOns/AuxVmangos/AuxVmangos.lua",
                "src/MovementCore/WoWMovementCore_5875_v21_ALT_PRIORITY.c",
                "runtime/parallel_tasks/route-test.json",
            ],
        )
        self.assertTrue(result["require_standard"])
        self.assertEqual(result["profiles_used"], ["economy"])

    def test_routing_control_file_requires_standard(self):
        result = classify(
            task(), CONFIG, "route-test",
            ["runtime/parallel_delivery_routing.json", "runtime/parallel_tasks/route-test.json"],
        )
        self.assertTrue(result["require_standard"])

    def test_empty_diff_never_shortcuts(self):
        self.assertTrue(classify(task(), CONFIG, "route-test", [])["require_standard"])


if __name__ == "__main__":
    unittest.main()
