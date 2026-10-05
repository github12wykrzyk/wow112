#!/usr/bin/env python3
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class StartupContractVNextTests(unittest.TestCase):
    def test_machine_routing_uses_one_canonical_main(self):
        index = json.loads((ROOT / "AI_INDEX.json").read_text(encoding="utf-8"))
        current = json.loads((ROOT / "CURRENT.json").read_text(encoding="utf-8"))
        self.assertEqual(index["branches"]["canonical"], "main")
        self.assertEqual(index["branches"]["development"], "main")
        self.assertEqual(index["branches"]["delivery_alias"], "parallel")
        self.assertEqual(current["canonical_branch"], "main")
        self.assertEqual(current["working_branch"], "main")

    def test_chat_fast_path_is_minimal(self):
        agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
        self.assertIn("Do **not** enumerate all branches", agents)
        self.assertIn("Do **not** read `runtime/ai_experiment_index.json` by default", agents)
        self.assertIn("No progress chatter by default", agents)
        self.assertIn("Broad archaeology is justified only by a concrete trigger", agents)
        self.assertIn("Repository-wide audits are nightly/manual/PR/release work", agents)
        index = json.loads((ROOT / "AI_INDEX.json").read_text(encoding="utf-8"))
        self.assertEqual(index["chat_execution_policy"]["default_communication"], "final_only")
        self.assertFalse(index["chat_execution_policy"]["api_calls_for_ping"])

    def test_prose_uses_optimistic_cas_not_serialized_queue(self):
        paths = [
            ROOT / "AGENTS.md",
            ROOT / "AI_START_HERE.md",
            ROOT / "PROJECT_INSTRUCTIONS.md",
            ROOT / "docs" / "DEVELOPMENT_WORKFLOW.md",
            ROOT / "docs" / "AI_ITERATION_WORKFLOW.md",
            ROOT / "docs" / "PARALLEL_CONTROL_PLANE.md",
        ]
        combined = "\n".join(p.read_text(encoding="utf-8") for p in paths)
        self.assertIn("optimistic CAS", combined)
        self.assertNotIn("serialized canonical integration queue", combined)
        self.assertNotIn("let the serialized queue", combined.lower())

    def test_integration_policy_matches_runtime_thread_policy(self):
        integration = json.loads((ROOT / "runtime" / "parallel_integration_policy.json").read_text(encoding="utf-8"))
        thread = json.loads((ROOT / "runtime" / "parallel_thread_policy.json").read_text(encoding="utf-8"))
        self.assertEqual(integration["canonical_branch"], "main")
        self.assertEqual(integration["delivery_alias_branch"], "parallel")
        self.assertEqual(integration["mode"], "concurrent_optimistic_atomic_cas")
        self.assertEqual(thread["auto_integration"]["queue_model"], "optimistic_atomic_cas")
        self.assertIsNone(thread["auto_integration"]["queue_concurrency_group"])
        update = integration["integration_transaction"]["ref_update"]
        self.assertEqual(update["targets"], ["main", "parallel"])
        self.assertTrue(update["atomic"])
        self.assertFalse(update["force"])

    def test_task_context_and_preflight_target_main(self):
        index = json.loads((ROOT / "AI_INDEX.json").read_text(encoding="utf-8"))
        self.assertIn("ai_task_context_fast.py", index["commands"]["task_context"])
        self.assertIn("--branch main", index["commands"]["task_context"])
        self.assertIn("--base origin/main", index["commands"]["parallel_feature_preflight"])

if __name__ == "__main__":
    unittest.main()
