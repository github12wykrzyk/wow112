import importlib.util
import pathlib
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("summon_terminal_soak_harness", HERE / "harness.py")
harness = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(harness)

class HarnessTests(unittest.TestCase):
    def test_segment_plan_caps_proven_runner_at_20(self):
        self.assertEqual([20], harness.segment_plan(20))
        self.assertEqual([20,20,10], harness.segment_plan(50))
        self.assertEqual([1], harness.segment_plan(0))

    def test_required_headless_primitives_are_present(self):
        missing, forbidden = harness.primitive_audit()
        self.assertEqual([], missing)
        self.assertEqual([], forbidden)

    def test_no_addon_or_gui_primitive_in_required_set(self):
        joined = "\n".join(harness.REQUIRED).lower()
        self.assertNotIn("src/addons", joined)
        self.assertNotIn("operator_console", joined)
        self.assertNotIn("packaging", joined)

    def test_role_log_contract(self):
        self.assertEqual({"customer","summoner","clicker1","clicker2","payer"}, set(harness.ROLE_KEYS))

    def test_proven_runner_is_harness_local(self):
        self.assertEqual(HERE / "Run-ProvenLiveTest.ps1", harness.PROVEN)

if __name__ == "__main__": unittest.main()
