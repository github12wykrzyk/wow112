#!/usr/bin/env python3
import unittest

import package_lazyrogue_addons as addons


class SummonScoutHotFanoutTests(unittest.TestCase):
    def test_unwatched_hot_modules_are_fanned_out_through_watched_whisper_host(self):
        host = addons.SUMMONSCOUT_ROOT / addons.HOT_FANOUT_HOST
        packaged = addons.package_bytes("SummonScout", host)
        modules = addons.hot_fanout_modules()

        self.assertTrue(modules)
        self.assertIn(addons.FANOUT_BEGIN_MARKER, packaged)
        self.assertIn(addons.FANOUT_END_MARKER, packaged)
        self.assertIn(b'W112_SUMMONSCOUT_HOT.modules["whisperconfirm"] ~= nil', packaged)
        self.assertLess(len(packaged), addons.HOT_PAYLOAD_CAP)
        self.assertIn(
            b"-- W112 HOT FANOUT BEGIN SummonScout_RosterOwnershipHot.lua",
            packaged,
        )

        for name in modules:
            marker = ("-- W112 HOT FANOUT BEGIN " + name).encode("utf-8")
            self.assertEqual(packaged.count(marker), 1, name)

        for name in addons.DIRECT_WATCHED_OR_HOSTED:
            marker = ("-- W112 HOT FANOUT BEGIN " + name).encode("utf-8")
            self.assertNotIn(marker, packaged)

    def test_every_non_direct_hot_source_is_declared_in_toc(self):
        declared = set(addons.hot_fanout_modules())
        discovered = {
            path.name
            for path in addons.SUMMONSCOUT_ROOT.glob("SummonScout_*Hot.lua")
            if path.name not in addons.DIRECT_WATCHED_OR_HOSTED
        }
        self.assertEqual(declared, discovered)

    def test_fanout_is_cold_load_guarded(self):
        host = addons.SUMMONSCOUT_ROOT / addons.HOT_FANOUT_HOST
        packaged = addons.package_bytes("SummonScout", host)
        guard = packaged.find(b"local __w112_hot_fanout_reload")
        fanout = packaged.find(addons.FANOUT_BEGIN_MARKER)
        self.assertGreaterEqual(guard, 0)
        self.assertGreater(fanout, guard)
        self.assertIn(b"if __w112_hot_fanout_reload then", packaged)

    def test_fanout_uses_lua50_safe_named_wrappers(self):
        host = addons.SUMMONSCOUT_ROOT / addons.HOT_FANOUT_HOST
        packaged = addons.package_bytes("SummonScout", host)
        modules = addons.hot_fanout_modules()

        # WoW 1.12 Lua 5.0 rejects consecutive `(function() ... end)()`
        # statements as ambiguous function-call/new-statement syntax.
        self.assertNotIn(b"\n    (function()\n", packaged)
        self.assertNotIn(b"end)()\n    -- W112 HOT FANOUT END", packaged)

        for index, _name in enumerate(modules, start=1):
            wrapper = "__w112_hot_fanout_module_" + str(index)
            self.assertIn(("    local function " + wrapper + "()\n").encode("utf-8"), packaged)
            self.assertIn(("\n    " + wrapper + "()\n").encode("utf-8"), packaged)


if __name__ == "__main__":
    unittest.main()
