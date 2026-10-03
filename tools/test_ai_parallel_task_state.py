#!/usr/bin/env python3
"""Regression tests for concurrency-safe Parallel task coordination."""
import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.parallel_ci_dispatch import parse_profiles, selected_workflows
from tools.parallel_task_state import (
    feature_check,
    load_policy,
    load_tasks,
    mark_integrated,
    profile_check,
    queue_check,
    required_profiles_for_paths,
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

    def ready_task(self, ident="synthetic-ready", profiles=None, dependencies=None):
        task = copy.deepcopy(self.enforcement_task())
        task["id"] = ident
        task["branch"] = "feature/" + ident
        task["status"] = "ready_for_integration"
        task["auto_integrate"] = True
        task["dependencies"] = list(dependencies or [])
        task["delivery_profiles"] = list(profiles or [])
        task.pop("integrated_feature_sha", None)
        return task

    def test_repository_tasks_validate(self):
        ids = {task["id"] for task in self.tasks}
        self.assertIn("parallel-concurrency-qol-v1", ids)
        self.assertIn("parallel-integration-queue-v1", ids)
        self.assertIn("parallel-task-enforcement-v1", ids)
        self.assertIn("parallel-post-integration-standard-v1", ids)

    def test_foundational_queue_tasks_are_integrated(self):
        self.assertEqual(self.queue_task()["status"], "integrated")
        self.assertEqual(self.enforcement_task()["status"], "integrated")

    def test_summary_reports_synthetic_active_tasks(self):
        data = summarize([self.ready_task()], self.policy)
        self.assertEqual(data["active_task_count"], 1)
        self.assertIn("integration_note", data)

    def test_route_finds_synthetic_active_task(self):
        task = self.ready_task()
        data = route([task], self.policy, task["modules"][0])
        self.assertEqual(data["active_tasks"][0]["id"], task["id"])

    def test_shared_resource_overlap_is_reported_not_rejected(self):
        first = self.ready_task("synthetic-a")
        second = self.ready_task("synthetic-b")
        second["auto_integrate"] = False
        second["status"] = "coding"
        validate_task(first, self.policy)
        validate_task(second, self.policy)
        data = summarize([first, second], self.policy)
        self.assertTrue(data["shared_resource_conflicts"])

    def test_invalid_branch_fails_closed(self):
        sample = self.ready_task()
        sample["branch"] = "parallel"
        with self.assertRaises(ValueError):
            validate_task(sample, self.policy)

    def test_invalid_status_fails_closed(self):
        sample = self.ready_task()
        sample["status"] = "magic"
        with self.assertRaises(ValueError):
            validate_task(sample, self.policy)

    def test_auto_integration_requires_ready_status(self):
        sample = self.ready_task()
        sample["status"] = "coding"
        with self.assertRaises(ValueError):
            validate_task(sample, self.policy)

    def test_unsupported_delivery_profile_fails_closed(self):
        sample = self.ready_task(profiles=["magic"])
        with self.assertRaises(ValueError):
            validate_task(sample, self.policy)

    def test_queue_blocks_unresolved_dependency(self):
        dep = self.ready_task("synthetic-dependency")
        dep["status"] = "coding"
        dep["auto_integrate"] = False
        child = self.ready_task("synthetic-child", dependencies=[dep["id"]])
        result = queue_check([dep, child], child["branch"])
        self.assertFalse(result["eligible"])
        self.assertEqual(result["reason"], "dependency_pending_" + dep["id"])

    def test_queue_accepts_declared_profile_gate(self):
        sample = self.ready_task(profiles=["economy"])
        result = queue_check([sample], sample["branch"])
        self.assertTrue(result["eligible"])
        self.assertEqual(result["delivery_profiles"], ["economy"])
        sample["auto_integrate"] = False
        self.assertFalse(queue_check([sample], sample["branch"])["eligible"])
        self.assertFalse(queue_check([sample], "feature/unregistered")["eligible"])

    def test_required_profile_routing(self):
        self.assertEqual(
            required_profiles_for_paths(self.policy, ["src/AHThrottleNative/foo.c"]),
            ["economy"],
        )
        self.assertEqual(
            required_profiles_for_paths(self.policy, ["tools/updater/WoW112Updater.cs"]),
            ["updater"],
        )
        self.assertEqual(
            required_profiles_for_paths(self.policy, ["src/AutoLoginBridge/x.c"]),
            ["autologinbridge"],
        )

    def test_profile_check_fails_when_routed_profile_missing(self):
        task = self.ready_task()
        with self.assertRaises(ValueError):
            profile_check(
                [task], self.policy, task["branch"], "1" * 40,
                ["src/AHThrottleNative/foo.c"], marker_present=True,
            )
        task["delivery_profiles"] = ["economy"]
        result = profile_check(
            [task], self.policy, task["branch"], "1" * 40,
            ["src/AHThrottleNative/foo.c"], marker_present=True,
        )
        self.assertEqual(result["required_profiles"], ["economy"])

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

    def test_legacy_profile_check_is_grandfathered(self):
        result = profile_check(
            self.tasks,
            self.policy,
            "feature/old-open-branch",
            "0" * 40,
            ["src/AHThrottleNative/foo.c"],
            marker_present=False,
        )
        self.assertFalse(result["required"])

    def test_mark_integrated_closes_task_in_place(self):
        task = self.ready_task()
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

    def test_queue_github_output_includes_profiles(self):
        result = {
            "eligible": True,
            "task_id": "task-a",
            "reason": "opt_in_ready",
            "delivery_profiles": ["economy", "updater"],
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "out.txt"
            write_github_output(path, result)
            self.assertEqual(
                path.read_text(encoding="utf-8"),
                "eligible=true\ntask_id=task-a\nreason=opt_in_ready\ndelivery_profiles=economy,updater\n",
            )

    def test_dispatch_profile_parser_and_workflow_selection(self):
        self.assertEqual(parse_profiles("economy,updater,economy"), ["economy", "updater"])
        selected = selected_workflows(True, ["economy", "autologinbridge"])
        self.assertEqual(selected[0][0], "standard")
        self.assertEqual([item[0] for item in selected[1:]], ["economy", "autologinbridge"])
        with self.assertRaises(ValueError):
            parse_profiles("unknown")

    def test_task_filename_must_match_id(self):
        with self.assertRaises(ValueError):
            validate_task(self.ready_task(), self.policy, "wrong.json")


if __name__ == "__main__":
    unittest.main()
