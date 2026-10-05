#!/usr/bin/env python3
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class ProfileTriggerOwnershipTests(unittest.TestCase):
    def _assert_dispatch_owned(self, workflow_name):
        text = (ROOT / ".github" / "workflows" / workflow_name).read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", text)
        self.assertNotIn("'feature/**'", text)
        self.assertIn("- parallel", text)

    def test_autologin_feature_build_is_dispatch_owned(self):
        self._assert_dispatch_owned("build_autologinbridge.yml")

    def test_updater_feature_build_is_dispatch_owned(self):
        self._assert_dispatch_owned("build_updater.yml")

if __name__ == "__main__":
    unittest.main()
