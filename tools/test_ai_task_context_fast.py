#!/usr/bin/env python3
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import tools.ai_task_context_fast as fast

class FastTaskContextTests(unittest.TestCase):
    def test_default_contract_never_reads_experiment_ledger(self):
        self.assertNotIn("ai_experiment", Path(fast.__file__).read_text(encoding="utf-8").lower())

    def test_build_targets_main_and_optimistic_cas(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "runtime").mkdir()
            (root / "src" / "AddOns" / "SummonScout").mkdir(parents=True)
            (root / "runtime" / "current.json").write_text(json.dumps({"active_dlls": []}), encoding="utf-8")
            (root / "runtime" / "parallel_candidate.json").write_text(json.dumps({"companions": [], "replacements": []}), encoding="utf-8")
            (root / "runtime" / "parallel_thread_policy.json").write_text(json.dumps({"delivery_profiles": {}}), encoding="utf-8")
            with patch.object(fast, "ROOT", root), \
                 patch.object(fast, "RUNTIME", root / "runtime" / "current.json"), \
                 patch.object(fast, "PARALLEL", root / "runtime" / "parallel_candidate.json"), \
                 patch.object(fast, "POLICY", root / "runtime" / "parallel_thread_policy.json"), \
                 patch.object(fast, "resolve_head", return_value="a" * 40):
                ctx = fast.build("SummonScout")
            self.assertEqual(ctx["selected_branch"], "main")
            self.assertEqual(ctx["risk"], "ADDON_LOCAL")
            self.assertFalse(ctx["experiment_ledger_read"])
            self.assertIn("optimistic_cas_revalidate_against_live_main", ctx["lifecycle"])

if __name__ == "__main__":
    unittest.main()
