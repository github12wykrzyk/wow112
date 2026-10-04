#!/usr/bin/env python3
import unittest
from pathlib import Path

from ah_shadow_hot_bundle import (
    BUNDLE_END,
    BUNDLE_MARKER,
    HOST_NAME,
    transform_summonscout_host,
)

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / "src" / "AddOns" / "SummonScout" / HOST_NAME


class AHShadowHostIndependentTests(unittest.TestCase):
    def test_shadow_bundle_executes_before_summonscout_runtime_guard(self):
        source = HOST.read_bytes().rstrip(b"\r\n")
        transformed = transform_summonscout_host(HOST_NAME, HOST.read_bytes())

        bundle_pos = transformed.find(BUNDLE_MARKER)
        bundle_end_pos = transformed.find(BUNDLE_END)
        host_pos = transformed.find(source)
        host_anchor_pos = transformed.find(b"local H = W112_SUMMONSCOUT_HOT", host_pos)

        self.assertGreaterEqual(bundle_pos, 0)
        self.assertGreater(bundle_end_pos, bundle_pos)
        self.assertGreater(host_pos, bundle_end_pos)
        self.assertGreaterEqual(host_anchor_pos, host_pos)
        self.assertIn(b"AuxEconomyShadow_ParityBridge.lua", transformed[:host_pos])
        self.assertIn(b"AuxEconomyShadow_ParityExport.lua", transformed[:host_pos])

    def test_host_source_is_preserved_after_shadow_bundle(self):
        source = HOST.read_bytes().rstrip(b"\r\n")
        transformed = transform_summonscout_host(HOST_NAME, HOST.read_bytes())
        self.assertTrue(transformed.rstrip(b"\r\n").endswith(source))

    def test_non_host_files_are_unchanged(self):
        payload = b"return 123\n"
        self.assertEqual(transform_summonscout_host("Other.lua", payload), payload)


if __name__ == "__main__":
    unittest.main()
