#!/usr/bin/env python3
"""Regression tests for concurrency-safe Parallel task coordination."""
import copy
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.parallel_task_state import POLICY, TASK_DIR, load_policy, load_tasks, route, summarize, validate_task


class ParallelTaskStateTests(unittest.TestCase):
    def setUp(self):
        self.policy = load_policy()
        self.tasks = load_tasks(self.policy)

    def test_repository_tasks_validate(self):
        self.assertGreaterEqual(len(self.tasks), 1)
        ids = {task["id"] for task in self.tasks}
        self.assertIn("parallel-concurrency-qol-v1", ids)

    def test_summary_reports_active_tasks_without_blocking_parallel_development(self):
        data = summarize(self.tasks, self.policy)
        self.assertGreaterEqual(data["active_task_count"], 1)
        self.assertIn("integration_note", data)

    def test_route_finds_infrastructure_task(self):
        data = route(self.tasks, self.policy, "AI-workflow")
        self.assertTrue(any(task["id"] == "parallel-concurrency-qol-v1" for task in data["active_tasks"]))

    def test_shared_resource_overlap_is_reported_not_rejected(self):
        sample = copy.deepcopy(self.tasks[0])
        sample["id"] = "parallel-concurrency-qol-v2"
        sample["branch"] = "feature/parallel-concurrency-qol-v2"
        validate_task(sample, self.policy)
        data = summarize([self.tasks[0], sample], self.policy)
        self.assertTrue(data["shared_resource_conflicts"])

    def test_invalid_branch_fails_closed(self):
        sample = copy.deepcopy(self.tasks[0])
        sample["branch"] = "parallel"
        with self.assertRaises(ValueError):
            validate_task(sample, self.policy)

    def test_invalid_status_fails_closed(self):
        sample = copy.deepcopy(self.tasks[0])
        sample["status"] = "magic"
        with self.assertRaises(ValueError):
            validate_task(sample, self.policy)

    def test_task_filename_must_match_id(self):
        with self.assertRaises(ValueError):
            validate_task(self.tasks[0], self.policy, "wrong.json")


if __name__ == "__main__":
    unittest.main()
