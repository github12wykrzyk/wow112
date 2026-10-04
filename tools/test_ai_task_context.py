#!/usr/bin/env python3
"""Regression tests for compact per-task AI FAST START context."""
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
        runtime_dir = self.root / "runtime"
        runtime_dir.mkdir()
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
        index = {
            "schema_version": 1,
            "source": "runtime/ai_experiments.json",
            "experiments": {
                "old-aux": {"branch": "parallel", "status": "awaiting_game_test",
                            "observed_head": "1" * 40, "verified_commit": "1" * 40,
                            "dependencies": [], "package": None},
                "aux-feature-a": {"branch": "feature/aux-a", "status": "in_progress",
                                  "observed_head": "2" * 40, "verified_commit": None,
                                  "dependencies": ["old-aux"], "package": None},
                "movement": {"branch": "feature/movement", "status": "awaiting_ci",
                             "observed_head": "3" * 40, "verified_commit": None,
                             "dependencies": [], "package": None},
                "aux-feature-b": {"branch": "feature/aux-b", "status": "awaiting_ci",
                                  "observed_head": "4" * 40, "verified_commit": "4" * 40,
                                  "dependencies": ["aux-feature-a"],
                                  "package": {"verified": True, "commit": "4" * 40,
                                              "artifact_id": 123}},
            },
            "modules": {
                "AuxVmangos": {"active": ["aux-feature-a", "aux-feature-b", "old-aux"],
                                "all": ["aux-feature-a", "aux-feature-b", "old-aux"]},
                "MovementCore": {"active": ["movement"], "all": ["movement"]},
            },
        }
        parallel = {
            "workflow": ".github/workflows/build_work_candidate.yml",
            "companions": [],
            "replacements": [
                {"runtime_name": "MovementCore.dll",
                 "sources": ["src/MovementCore/WoWMovementCore_5875_v21_ALT_PRIORITY.c",
                             "src/PVERear360/WoWPVERear360_5875_v1.c"]}
            ],
            "addons": {"roots": ["AuxVmangos"]},
        }
        economy = {
            "dlls": [],
            "addons": {"roots": ["AuxVmangos"]},
            "delivery": {"workflow": ".github/workflows/build_parallel_economy.yml"},
        }
        runtime = {"active_dlls": []}
        policy = {
            "delivery_profiles": {
                "economy": {
                    "workflow": "build_parallel_economy.yml",
                    "required_paths": ["src/AddOns/AuxVmangos/"]
                }
            },
            "diagnostic_hotfix_fast_path": {
                "required_delivery_profiles": ["economy"],
                "allowed_modules": ["AuxVmangos"],
                "allowed_payload_paths": ["src/AddOns/AuxVmangos/Diagnostic.lua"]
            }
        }
        dependency_registry = {
            "hooks": [
                {"resource": "wow5875:0x00600ACA:movement_send_call",
                 "policy": "ordered_chain",
                 "owners": [
                     {"module": "MovementCore.dll",
                      "source": "src/MovementCore/WoWMovementCore_5875_v21_ALT_PRIORITY.c"}
                 ]}
            ]
        }
        for name, obj in (
            ("ai_experiments.json", ledger),
            ("ai_experiment_index.json", index),
            ("parallel_candidate.json", parallel),
            ("parallel_economy.json", economy),
            ("current.json", runtime),
            ("parallel_thread_policy.json", policy),
            ("parallel_dependency_registry.json", dependency_registry),
        ):
            (runtime_dir / name).write_text(json.dumps(obj), encoding="utf-8")

        self.patches = [
            patch.object(task_context, "ROOT", self.root),
            patch.object(task_context, "LEDGER", runtime_dir / "ai_experiments.json"),
            patch.object(task_context, "INDEX", runtime_dir / "ai_experiment_index.json"),
            patch.object(task_context, "PARALLEL", runtime_dir / "parallel_candidate.json"),
            patch.object(task_context, "ECONOMY", runtime_dir / "parallel_economy.json"),
            patch.object(task_context, "RUNTIME", runtime_dir / "current.json"),
            patch.object(task_context, "THREAD_POLICY", runtime_dir / "parallel_thread_policy.json"),
            patch.object(task_context, "DEPENDENCY_REGISTRY",
                         runtime_dir / "parallel_dependency_registry.json"),
        ]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.tmp.cleanup()

    def test_compact_index_is_default_and_economy_aware(self):
        ctx = task_context.build_context("AuxVmangos", "parallel", limit=2, head="a" * 40)
        self.assertEqual(ctx["selected_branch"], "parallel")
        self.assertEqual(ctx["routing"]["source"], "runtime/ai_experiment_index.json")
        self.assertFalse(ctx["routing"]["full_ledger_fallback_used"])
        self.assertIn("src/AddOns/AuxVmangos", ctx["source_hints"])
        self.assertTrue(ctx["delivery"]["economy_eligible"])
        self.assertIn("economy", ctx["delivery"]["profiles"])
        self.assertEqual(len(ctx["routing"]["recent_active"]), 2)
        self.assertIn("parallel_exact_sha_economy_pass", ctx["delivery"]["lifecycle"])
        self.assertLess(len(json.dumps(ctx)), 16000)

    def test_full_ledger_is_fallback_only(self):
        task_context.INDEX.unlink()
        ctx = task_context.build_context("AuxVmangos", "parallel", limit=2, head="b" * 40)
        self.assertEqual(ctx["routing"]["source"], "runtime/ai_experiments.json")
        self.assertTrue(ctx["routing"]["full_ledger_fallback_used"])
        ids = [row["id"] for row in ctx["routing"]["recent_active"]]
        self.assertEqual(ids, ["aux-feature-b", "aux-feature-a"])

    def test_native_shared_risk_surfaces_hook_ownership(self):
        ctx = task_context.build_context("MovementCore", "parallel", limit=4, head="c" * 40)
        self.assertEqual(ctx["risk_class"], "NATIVE_SHARED")
        self.assertTrue(ctx["ownership"])
        self.assertEqual(ctx["ownership"][0]["policy"], "ordered_chain")
        self.assertFalse(ctx["delivery"]["economy_eligible"])
        self.assertNotIn("parallel_exact_sha_economy_pass", ctx["delivery"]["lifecycle"])
        self.assertIsNone(ctx["delivery"]["workflows"]["economy"])

    def test_explicit_diagnostic_intent_only_marks_policy_potential(self):
        ctx = task_context.build_context(
            "AuxVmangos", "parallel", limit=2, head="d" * 40, intent="diagnostic"
        )
        self.assertEqual(ctx["risk_class"], "HOT_DIAGNOSTIC")
        self.assertTrue(ctx["delivery"]["diagnostic_fastpath_potential"])
        self.assertEqual(ctx["delivery"]["standard_gate"], "conditional_policy_check")
        self.assertIn("src/AddOns/AuxVmangos/Diagnostic.lua",
                      ctx["delivery"]["diagnostic_fastpath_allowed_payload_paths"])

    def test_explicit_branch_is_never_rewritten(self):
        ctx = task_context.build_context("AuxVmangos", "feature/example", limit=2, head="e" * 40)
        self.assertEqual(ctx["selected_branch"], "feature/example")
        self.assertEqual(ctx["delivery"]["lifecycle"], [])

    def test_text_output_surfaces_fast_start_and_legacy_economy_signal(self):
        ctx = task_context.build_context("AuxVmangos", "parallel", limit=2, head="f" * 40)
        text = task_context.render_text(ctx)
        self.assertIn("routing source: runtime/ai_experiment_index.json", text)
        self.assertIn("risk: ADDON_LOCAL", text)
        self.assertIn("analysis budget:", text)
        self.assertIn("feature_exact_sha_preflight_pass", text)
        self.assertIn("test_ready_exact_sha_artifact", text)
        self.assertIn("economy eligible: yes", text)

    def test_limit_fails_closed(self):
        with self.assertRaises(ValueError):
            task_context.build_context("AuxVmangos", "parallel", limit=0, head="f" * 40)


if __name__ == "__main__":
    unittest.main()
