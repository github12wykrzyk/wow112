#!/usr/bin/env python3
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class StartupContractVNextTests(unittest.TestCase):
    def test_machine_routing_uses_one_canonical_main(self):
        index = json.loads((ROOT / "AI_INDEX.json").read_text(encoding="utf-8"))
        current = json.loads((ROOT / "CURRENT.json").read_text(encoding="utf-8"))
        branches = index["branches"]
        self.assertEqual(branches["canonical"], "main")
        self.assertEqual(branches["development"], "main")
        self.assertEqual(branches["delivery_alias"], "parallel")
        self.assertEqual(current["canonical_branch"], "main")
        self.assertEqual(current["working_branch"], "main")
        self.assertEqual(current["delivery_alias_branch"], "parallel")
        self.assertEqual(current["branch_model"], "canonical_main_with_parallel_delivery_alias")

    def test_startup_prose_does_not_restore_multiworld_model(self):
        agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
        start = (ROOT / "AI_START_HERE.md").read_text(encoding="utf-8")
        dev = (ROOT / "docs" / "DEVELOPMENT_WORKFLOW.md").read_text(encoding="utf-8")
        combined = "\n".join((agents, start, dev))
        forbidden = (
            "`main` = last accepted stable state only",
            "`work` = existing development candidate",
            "`parallel` = independent alternative",
            "work must contain current main",
            "existing parallel divergence",
        )
        for phrase in forbidden:
            with self.subTest(phrase=phrase):
                self.assertNotIn(phrase, combined)
        self.assertIn("canonical integration trunk", combined)
        self.assertIn("exact compatibility/delivery alias", combined)

    def test_normal_path_is_targeted_and_failure_driven(self):
        agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
        self.assertIn("Do **not** enumerate all branches", agents)
        self.assertIn("Broad archaeology is justified only by a concrete trigger", agents)
        self.assertIn("Repository-wide audits are nightly/manual/PR/release work", agents)

    def test_integration_policy_targets_main_and_atomic_alias(self):
        policy = json.loads((ROOT / "runtime" / "parallel_integration_policy.json").read_text(encoding="utf-8"))
        self.assertEqual(policy["canonical_branch"], "main")
        self.assertEqual(policy["delivery_alias_branch"], "parallel")
        update = policy["integration_transaction"]["ref_update"]
        self.assertEqual(update["targets"], ["main", "parallel"])
        self.assertTrue(update["atomic"])
        self.assertFalse(update["force"])

    def test_leases_are_not_hot_path_requirement(self):
        policy = json.loads((ROOT / "runtime" / "parallel_thread_policy.json").read_text(encoding="utf-8"))
        self.assertEqual(policy["canonical_branch"], "main")
        self.assertEqual(policy["lease_policy"]["required_statuses"], [])
        auto = policy["auto_integration"]
        self.assertEqual(auto["queue_model"], "optimistic_atomic_cas")
        self.assertIsNone(auto["queue_concurrency_group"])
        self.assertEqual(auto["cas_retry_limit"], 6)

    def test_preflight_command_targets_main(self):
        index = json.loads((ROOT / "AI_INDEX.json").read_text(encoding="utf-8"))
        self.assertIn("--base origin/main", index["commands"]["parallel_feature_preflight"])
        self.assertIn("--branch main", index["commands"]["task_context"])


if __name__ == "__main__":
    unittest.main()
