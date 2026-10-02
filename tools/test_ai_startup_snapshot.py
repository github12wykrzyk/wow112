#!/usr/bin/env python3
"""Regression tests for the generated AI startup fast-path snapshot."""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.ai_startup_snapshot import ROOT, SNAPSHOT, SOURCES, build_snapshot, git_blob_sha1, render_snapshot


class StartupSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = json.loads(SNAPSHOT.read_text(encoding="utf-8"))

    def test_snapshot_is_exact_generated_projection(self):
        self.assertEqual(self.snapshot, build_snapshot())
        self.assertEqual(SNAPSHOT.read_text(encoding="utf-8"), render_snapshot())

    def test_all_canonical_source_identities_match(self):
        self.assertEqual(set(self.snapshot["source_files"]), set(SOURCES))
        for relpath in SOURCES:
            data = (ROOT / relpath).read_bytes()
            self.assertEqual(self.snapshot["source_files"][relpath]["git_blob_sha1"], git_blob_sha1(data))

    def test_fast_path_is_fail_closed(self):
        required = set(self.snapshot["fast_path"]["full_startup_required_for"])
        expected = {
            "stable promotion or promote/** work",
            "editing any startup source file, snapshot or generator",
            "recovery after unknown or ambiguous write/transport state",
            "snapshot missing, stale, mismatched or unverifiable",
            "authority or branch ambiguity not resolved by compact state",
        }
        self.assertTrue(expected.issubset(required))
        self.assertTrue(self.snapshot["fast_path"]["verification"]["same_head_required"])
        self.assertTrue(self.snapshot["fast_path"]["verification"]["fallback_if_unverifiable"])

    def test_snapshot_is_materially_smaller_than_full_startup(self):
        full_size = sum((ROOT / relpath).stat().st_size for relpath in SOURCES)
        self.assertLess(SNAPSHOT.stat().st_size, full_size * 0.60)


if __name__ == "__main__":
    unittest.main()
