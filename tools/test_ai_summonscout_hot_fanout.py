#!/usr/bin/env python3
import unittest
from pathlib import Path

import summonscout_hot_transform as hot


class SummonScoutHotFanoutTests(unittest.TestCase):
    def test_unwatched_hot_modules_are_fanned_out_through_watched_whisper_host(self):
        source = (hot.ADDON_ROOT / hot.WHISPER_HOST_NAME).read_bytes()
        transformed = hot.transform_file(hot.WHISPER_HOST_NAME, source)
        modules = hot.hot_fanout_modules()

        self.assertTrue(modules)
        self.assertIn(hot.FANOUT_BEGIN_MARKER, transformed)
        self.assertIn(hot.FANOUT_END_MARKER, transformed)
        self.assertIn(b'W112_SUMMONSCOUT_HOT.modules["whisperconfirm"] ~= nil', transformed)
        self.assertLess(len(transformed), hot.HOT_PAYLOAD_CAP)

        for name in modules:
            marker = ("-- W112 HOT FANOUT BEGIN " + name).encode("utf-8")
            self.assertEqual(transformed.count(marker), 1, name)

        for name in hot.DIRECT_WATCHED_OR_HOSTED:
            marker = ("-- W112 HOT FANOUT BEGIN " + name).encode("utf-8")
            self.assertNotIn(marker, transformed)

    def test_every_non_direct_hot_source_is_declared_in_toc(self):
        declared = set(hot.hot_fanout_modules())
        discovered = {
            path.name
            for path in hot.ADDON_ROOT.glob("SummonScout_*Hot.lua")
            if path.name not in hot.DIRECT_WATCHED_OR_HOSTED
        }
        self.assertEqual(declared, discovered)

    def test_other_files_are_not_transformed(self):
        payload = b"print('unchanged')\n"
        self.assertEqual(hot.transform_file("Unrelated.lua", payload), payload)


if __name__ == "__main__":
    unittest.main()
