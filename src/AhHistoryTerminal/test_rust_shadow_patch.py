#!/usr/bin/env python3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "probes" / "Wow112HeadlessAndroid" / "src" / "world_poc07.rs"
PATCH = ROOT / "probes" / "Wow112HeadlessAndroid" / "tools" / "poc08_history_shadow_capture_patch.py"


class RustShadowPatchTests(unittest.TestCase):
    def test_patch_applies_once_to_real_shared_request_source(self):
        with tempfile.TemporaryDirectory() as td:
            target = Path(td) / "world_poc07.rs"
            target.write_text(SOURCE.read_text(encoding="utf-8"), encoding="utf-8")
            subprocess.run([sys.executable, str(PATCH), str(target)], check=True)
            text = target.read_text(encoding="utf-8")
            self.assertEqual(text.count("fn poc08_history_shadow_capture_page("), 1)
            self.assertEqual(text.count("poc08_history_shadow_capture_page(label, page, &payload, &records);"), 1)
            self.assertIn("best_effort_no_mutation_coupling", text)
            self.assertIn("buy_retry_signal=NO", text)
            self.assertIn("revalidation_window", text)
            second = subprocess.run([sys.executable, str(PATCH), str(target)], capture_output=True, text=True)
            self.assertNotEqual(second.returncode, 0)


if __name__ == "__main__":
    unittest.main()
