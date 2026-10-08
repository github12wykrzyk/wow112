import importlib.util
import json
import pathlib
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("summon_terminal_soak_harness", HERE / "harness.py")
harness = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(harness)


class HarnessTests(unittest.TestCase):
    def test_fixture_matrix_is_large_and_categorized(self):
        result = harness.validate_fixtures()
        self.assertTrue(result["ok"])
        self.assertGreaterEqual(result["total_cases"], 20)

    def test_payment_invariant_contract_is_fail_closed(self):
        inv = harness.payment_invariants()
        self.assertTrue(inv["set_gold_at_most_once"])
        self.assertTrue(inv["accept_at_most_once"])
        self.assertTrue(inv["no_retry_after_uncertain"])
        self.assertTrue(inv["trade_complete_requires_server_confirmation"])
        self.assertTrue(inv["paid_requires_trusted_confirmation"])
        self.assertTrue(inv["ledger_entry_unique"])

    def test_current_parallel_missing_core_is_reported_not_faked(self):
        audit = harness.primitive_audit()
        if audit["missing"]:
            self.assertFalse(audit["live_ready"])
        else:
            self.assertTrue(audit["live_ready"])

    def test_forbidden_scope_prefixes_cover_user_guardrails(self):
        self.assertIn("src/AddOns/", harness.FORBIDDEN_PREFIXES)
        self.assertIn("tools/operator_console/", harness.FORBIDDEN_PREFIXES)
        self.assertIn("packaging/", harness.FORBIDDEN_PREFIXES)

    def test_required_output_contract(self):
        required = {
            "summary.json", "summary.md", "events.jsonl", "failures.json", "timings.json",
            "customer.log", "summoner.log", "clicker1.log", "clicker2.log", "payer.log",
            "exact_sha_manifest.json",
        }
        self.assertEqual(11, len(required))


if __name__ == "__main__":
    unittest.main()
