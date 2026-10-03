#!/usr/bin/env python3
"""Regression tests for concurrency-safe Parallel task coordination."""
import copy
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.parallel_task_state import load_policy, load_tasks, queue_check, route, summarize, validate_task, write_github_output


class ParallelTaskStateTests(unittest.TestCase):
    def setUp(self):
        self.policy = load_policy()
        self.tasks = load_tasks(self.policy)

    def active_task(self):
        return next(task for task in self.tasks if task["id"] == "parallel-integration-queue-v1")

    def test_repository_tasks_validate(self):
        ids = {task["id"] for task in self.tasks}
        self.assertIn("parallel-concurrency-qol-v1", ids)
        self.assertIn("parallel-integration-queue-v1", ids)

    def test_stage1_is_closed_and_stage2_is_active(self):
        first = next(task for task in self.tasks if task["id"] == "parallel-concurrency-qol-v1")
        self.assertEqual(first["status"], "done")
        self.assertIn(self.active_task()["status"], self.policy["active_statuses"])

    def test_summary_reports_active_tasks_without_blocking_parallel_development(self):
        data = summarize(self.tasks, self.policy)
        self.assertGreaterEqual(data["active_task_count"], 1)
        self.assertIn("integration_note", data)

    def test_route_finds_current_infrastructure_task(self):
        data = route(self.tasks, self.policy, "AI-workflow")
        self.assertTrue(any(task["id"] == "parallel-integration-queue-v1" for task in data["active_tasks"]))

    def test_shared_resource_overlap_is_reported_not_rejected(self):
        sample = copy.deepcopy(self.active_task())
        sample["id"] = "parallel-integration-queue-v2"
        sample["branch"] = "feature/parallel-integration-queue-v2"
        sample["auto_integrate"] = False
        validate_task(sample, self.policy)
        data = summarize([self.active_task(), sample], self.policy)
        self.assertTrue(data["shared_resource_conflicts"])

    def test_invalid_branch_fails_closed(self):
        sample = copy.deepcopy(self.active_task())
        sample["branch"] = "parallel"
        with self.assertRaises(ValueError):
            validate_task(sample, self.policy)

    def test_invalid_status_fails_closed(self):
        sample = copy.deepcopy(self.active_task())
        sample["status"] = "magic"
        with self.assertRaises(ValueError):
            validate_task(sample, self.policy)

    def test_auto_integration_requires_ready_status(self):
        sample = copy.deepcopy(self.active_task())
        sample["status"] = "coding"
        sample["auto_integrate"] = True
        with self.assertRaises(ValueError):
            validate_task(sample, self.policy)

    def test_queue_is_opt_in_and_fail_closed(self):
        sample = copy.deepcopy(self.active_task())
        sample["auto_integrate"] = False
        self.assertFalse(queue_check([sample], sample["branch"])["eligible"])
        sample["auto_integrate"] = True
        self.assertTrue(queue_check([sample], sample["branch"])["eligible"])
        sample["delivery_profiles"] = ["economy"]
        result = queue_check([sample], sample["branch"])
        self.assertFalse(result["eligible"])
        self.assertEqual(result["reason"], "profile_gate_requires_manual")
        self.assertFalse(queue_check([sample], "feature/unregistered")["eligible"])

    def test_queue_github_output_is_stable(self):
        result = {"eligible": True, "task_id": "task-a", "reason": "opt_in_ready"}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "out.txt"
            write_github_output(path, result)
            self.assertEqual(
                path.read_text(encoding="utf-8"),
                "eligible=true\ntask_id=task-a\nreason=opt_in_ready\n",
            )

    def test_task_filename_must_match_id(self):
        with self.assertRaises(ValueError):
            validate_task(self.active_task(), self.policy, "wrong.json")


if __name__ == "__main__":
    unittest.main()
