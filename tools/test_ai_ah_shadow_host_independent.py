#!/usr/bin/env python3
import unittest
from pathlib import Path

from ah_shadow_hot_bundle import (
    BUNDLE_MARKER,
    HOST_NAME,
    transform_summonscout_host,
)

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / "src" / "AddOns" / "SummonScout" / HOST_NAME


class AHShadowHostIndependentTests(unittest.TestCase):
    def test_shadow_bundle_executes_before_summonscout_runtime_guard(self):
        source = HOST.read_bytes()
        transformed = transform_summonscout_host(HOST_NAME, source)

        bundle_pos = transformed.find(BUNDLE_MARKER)
        host_anchor_pos = transformed.find(b"local H = W112_SUMMONSCOUT_HOT")
        guard_return_pos = transformed.find(b"\n    return\n", host_anchor_pos)

        self.assertGreaterEqual(bundle_pos, 0)
        self.assertGreater(host_anchor_pos, bundle_pos)
        self.assertGreater(guard_return_pos, host_anchor_pos)
        self.assertLess(bundle_pos, guard_return_pos)
        self.assertIn(b"AuxEconomyShadow_ParityBridge.lua", transformed[:host_anchor_pos])
        self.assertIn(b"AuxEconomyShadow_ParityExport.lua", transformed[:host_anchor_pos])

    def test_host_source_is_preserved_after_shadow_bundle(self):
        source = HOST.read_bytes().rstrip(b"\r\n")
        transformed = transform_summonscout_host(HOST_NAME, HOST.read_bytes())
        self.assertTrue(transformed.rstrip(b"\r\n").endswith(source))

    def test_non_host_files_are_unchanged(self):
        payload = b"return 123\n"
        self.assertEqual(transform_summonscout_host("Other.lua", payload), payload)


if __name__ == "__main__":
    unittest.main()
