#!/usr/bin/env python3
"""Regression tests for compact per-task AI routing context."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tools.ai_task_context as task_context


class TaskContextTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "runtime").mkdir()
        (self.root / "src" / "AddOns" / "AuxVmangos").mkdir(parents=True)
        (self.root / "src" / "MovementCore").mkdir(parents=True)

        ledger = {
            "experiments": [
                {"id": "old-aux", "branch": "parallel", "modules": ["AuxVmangos"],
                 "dependencies": [], "status": "awaiting_game_test", "observed_head": "1" * 40,
                 "verified_commit": "1" * 40, "package": None},
                {"id": "aux-feature-a", "branch": "feature/aux-a", "modules": ["AuxVmangos"],
                 "dependencies": ["old-aux"], "status": "in_progress", "observed_head": "2" * 40,
                 "verified_commit": None, "package": None},
                {"id": "movement", "branch": "feature/movement", "modules": ["MovementCore"],
                 "dependencies": [], "status": "awaiting_ci", "observed_head": "3" * 40,
                 "verified_commit": None, "package": None},
                {"id": "aux-feature-b", "branch": "feature/aux-b", "modules": ["AuxVmangos"],
                 "dependencies": ["aux-feature-a"], "status": "awaiting_ci", "observed_head": "4" * 40,
                 "verified_commit": "4" * 40,
                 "package": {"verified": True, "commit": "4" * 40, "artifact_id": 123}},
            ]
        }
        parallel = {
            "workflow": ".github/workflows/build_work_candidate.yml",
            "companions": [], "replacements": [],
            "addons": {"roots": ["AuxVmangos"]},
        }
        economy = {
            "dlls": [],
            "addons": {"roots": ["AuxVmangos"]},
            "delivery": {"workflow": ".github/workflows/build_parallel_economy.yml"},
        }
        runtime = {"active_dlls": []}
        for name, obj in (
            ("ai_experiments.json", ledger),
            ("parallel_candidate.json", parallel),
            ("parallel_economy.json", economy),
            ("current.json", runtime),
        ):
            (self.root / "runtime" / name).write_text(json.dumps(obj), encoding="utf-8")

        self.patches = [
            patch.object(task_context, "ROOT", self.root),
            patch.object(task_context, "LEDGER", self.root / "runtime" / "ai_experiments.json"),
            patch.object(task_context, "PARALLEL", self.root / "runtime" / "parallel_candidate.json"),
            patch.object(task_context, "ECONOMY", self.root / "runtime" / "parallel_economy.json"),
            patch.object(task_context, "RUNTIME", self.root / "runtime" / "current.json"),
        ]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.tmp.cleanup()

    def test_aux_context_is_compact_and_economy_aware(self):
        ctx = task_context.build_context("AuxVmangos", "parallel", limit=2, head="a" * 40)
        self.assertEqual(ctx["selected_branch"], "parallel")
        self.assertIn("src/AddOns/AuxVmangos", ctx["source_hints"])
        self.assertTrue(ctx["delivery"]["economy_eligible"])
        self.assertEqual(len(ctx["routing"]["recent_active"]), 2)
        self.assertIn("parallel_exact_sha_economy_pass", ctx["delivery"]["lifecycle"])
        self.assertLess(len(json.dumps(ctx)), 12000)

    def test_recent_experiments_preserve_ledger_recency(self):
        ctx = task_context.build_context("AuxVmangos", "parallel", limit=2, head="b" * 40)
        ids = [row["id"] for row in ctx["routing"]["recent_active"]]
        self.assertEqual(ids, ["aux-feature-b", "aux-feature-a"])

    def test_standard_only_module_does_not_require_economy(self):
        ctx = task_context.build_context("MovementCore", "parallel", limit=4, head="c" * 40)
        self.assertFalse(ctx["delivery"]["economy_eligible"])
        self.assertNotIn("parallel_exact_sha_economy_pass", ctx["delivery"]["lifecycle"])
        self.assertIsNone(ctx["delivery"]["workflows"]["economy"])

    def test_explicit_branch_is_never_rewritten(self):
        ctx = task_context.build_context("AuxVmangos", "feature/example", limit=2, head="d" * 40)
        self.assertEqual(ctx["selected_branch"], "feature/example")
        self.assertEqual(ctx["delivery"]["lifecycle"], [])

    def test_text_output_surfaces_delivery_chain(self):
        ctx = task_context.build_context("AuxVmangos", "parallel", limit=2, head="e" * 40)
        text = task_context.render_text(ctx)
        self.assertIn("feature_exact_sha_preflight_pass", text)
        self.assertIn("test_ready_exact_sha_artifact", text)
        self.assertIn("economy eligible: yes", text)

    def test_limit_fails_closed(self):
        with self.assertRaises(ValueError):
            task_context.build_context("AuxVmangos", "parallel", limit=0, head="f" * 40)


if __name__ == "__main__":
    unittest.main()
