#!/usr/bin/env python3
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class ProfileTriggerOwnershipTests(unittest.TestCase):
    def test_autologin_feature_build_is_dispatch_owned(self):
        text = (ROOT / ".github" / "workflows" / "build_autologinbridge.yml").read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", text)
        self.assertNotIn("'feature/**'", text)
        self.assertIn("- parallel", text)

if __name__ == "__main__":
    unittest.main()
