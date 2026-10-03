#!/usr/bin/env python3
"""Regression tests for concurrency-safe Parallel task coordination."""
import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.parallel_task_state import (
    feature_check,
    load_policy,
    load_tasks,
    mark_integrated,
    queue_check,
    route,
    summarize,
    validate_task,
    write_github_output,
)


class ParallelTaskStateTests(unittest.TestCase):
    def setUp(self):
        self.policy = load_policy()
        self.tasks = load_tasks(self.policy)

    def enforcement_task(self):
        return next(task for task in self.tasks if task["id"] == "parallel-task-enforcement-v1")

    def queue_task(self):
        return next(task for task in self.tasks if task["id"] == "parallel-integration-queue-v1")

    def test_repository_tasks_validate(self):
        ids = {task["id"] for task in self.tasks}
        self.assertIn("parallel-concurrency-qol-v1", ids)
        self.assertIn("parallel-integration-queue-v1", ids)
        self.assertIn("parallel-task-enforcement-v1", ids)

    def test_previous_queue_task_is_integrated(self):
        task = self.queue_task()
        self.assertEqual(task["status"], "integrated")
        self.assertEqual(task["integrated_feature_sha"], "62fb94415068ce69eca6aab59b043d94edb17c7d")

    def test_enforcement_task_is_active_and_queue_eligible(self):
        task = self.enforcement_task()
        self.assertIn(task["status"], self.policy["active_statuses"])
        result = queue_check(self.tasks, task["branch"])
        self.assertTrue(result["eligible"])
        self.assertEqual(result["reason"], "opt_in_ready")

    def test_summary_reports_active_tasks_without_blocking_parallel_development(self):
        data = summarize(self.tasks, self.policy)
        self.assertGreaterEqual(data["active_task_count"], 1)
        self.assertIn("integration_note", data)

    def test_route_finds_current_infrastructure_task(self):
        data = route(self.tasks, self.policy, "AI-workflow")
        self.assertTrue(any(task["id"] == "parallel-task-enforcement-v1" for task in data["active_tasks"]))

    def test_shared_resource_overlap_is_reported_not_rejected(self):
        sample = copy.deepcopy(self.enforcement_task())
        sample["id"] = "parallel-task-enforcement-v2"
        sample["branch"] = "feature/parallel-task-enforcement-v2"
        sample["auto_integrate"] = False
        sample["status"] = "coding"
        validate_task(sample, self.policy)
        data = summarize([self.enforcement_task(), sample], self.policy)
        self.assertTrue(data["shared_resource_conflicts"])

    def test_invalid_branch_fails_closed(self):
        sample = copy.deepcopy(self.enforcement_task())
        sample["branch"] = "parallel"
        with self.assertRaises(ValueError):
            validate_task(sample, self.policy)

    def test_invalid_status_fails_closed(self):
        sample = copy.deepcopy(self.enforcement_task())
        sample["status"] = "magic"
        with self.assertRaises(ValueError):
            validate_task(sample, self.policy)

    def test_auto_integration_requires_ready_status(self):
        sample = copy.deepcopy(self.enforcement_task())
        sample["status"] = "coding"
        with self.assertRaises(ValueError):
            validate_task(sample, self.policy)

    def test_queue_blocks_unresolved_dependency(self):
        tasks = copy.deepcopy(self.tasks)
        queue = next(task for task in tasks if task["id"] == "parallel-integration-queue-v1")
        queue["status"] = "coding"
        result = queue_check(tasks, self.enforcement_task()["branch"])
        self.assertFalse(result["eligible"])
        self.assertEqual(result["reason"], "dependency_pending_parallel-integration-queue-v1")

    def test_queue_is_opt_in_and_profile_gate_fail_closed(self):
        sample = copy.deepcopy(self.enforcement_task())
        sample["auto_integrate"] = False
        self.assertFalse(queue_check([sample], sample["branch"])["eligible"])
        sample["auto_integrate"] = True
        sample["dependencies"] = []
        self.assertTrue(queue_check([sample], sample["branch"])["eligible"])
        sample["delivery_profiles"] = ["economy"]
        result = queue_check([sample], sample["branch"])
        self.assertFalse(result["eligible"])
        self.assertEqual(result["reason"], "profile_gate_requires_manual")
        self.assertFalse(queue_check([sample], "feature/unregistered")["eligible"])

    def test_feature_record_enforcement_is_merge_base_gated(self):
        legacy = feature_check(
            self.tasks,
            self.policy,
            "feature/old-open-branch",
            "0" * 40,
            marker_present=False,
        )
        self.assertFalse(legacy["required"])
        with self.assertRaises(ValueError):
            feature_check(
                self.tasks,
                self.policy,
                "feature/new-unregistered-branch",
                "1" * 40,
                marker_present=True,
            )
        current = feature_check(
            self.tasks,
            self.policy,
            self.enforcement_task()["branch"],
            "2" * 40,
            marker_present=True,
        )
        self.assertTrue(current["required"])
        self.assertEqual(current["task_id"], "parallel-task-enforcement-v1")

    def test_mark_integrated_closes_task_in_place(self):
        task = copy.deepcopy(self.enforcement_task())
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / (task["id"] + ".json")
            path.write_text(json.dumps(task, indent=2) + "\n", encoding="utf-8")
            updated = mark_integrated(
                [task],
                self.policy,
                task["id"],
                "a" * 40,
                task_dir=Path(tmp),
            )
            self.assertEqual(updated["status"], "integrated")
            self.assertFalse(updated["auto_integrate"])
            self.assertEqual(updated["integrated_feature_sha"], "a" * 40)
            saved = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(saved["status"], "integrated")

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
            validate_task(self.enforcement_task(), self.policy, "wrong.json")


if __name__ == "__main__":
    unittest.main()
