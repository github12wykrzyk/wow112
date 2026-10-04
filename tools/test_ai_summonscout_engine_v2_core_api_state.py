#!/usr/bin/env python3
"""Contract tests for SummonScout Engine V2 P0.3b core-native API/state."""
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"
CORE = ADDON / "SummonScout.lua"
FOUNDATION = ADDON / "SummonScout_EngineV2FoundationHot.lua"


class SummonScoutCoreApiStateContract(unittest.TestCase):
    def text(self, path):
        return path.read_text(encoding="utf-8")

    def test_core_exports_api_and_state_before_event_handler(self):
        core = self.text(CORE)
        api = core.index("W112_SUMMONSCOUT_API_V1 = EventAPI")
        state = core.index("W112_SUMMONSCOUT_STATE = SS")
        version = core.index("W112_SUMMONSCOUT_API_VERSION = 1")
        native = core.index("W112_SUMMONSCOUT_CORE_API_NATIVE = true")
        handler = core.index('frame:SetScript("OnEvent", function()')
        self.assertLess(api, handler)
        self.assertLess(state, handler)
        self.assertLess(version, handler)
        self.assertLess(native, handler)

    def test_foundation_resolves_core_native_surface_without_api_state_walkers(self):
        foundation = self.text(FOUNDATION)
        self.assertIn("local api = W112_SUMMONSCOUT_API_V1", foundation)
        self.assertIn("local state = W112_SUMMONSCOUT_STATE", foundation)
        self.assertNotIn("local function fFindApi", foundation)
        self.assertNotIn("local function fFindState", foundation)
        self.assertNotIn('return fFindApi(frame:GetScript("OnEvent")', foundation)
        self.assertNotIn("fFindState(candidates", foundation)

    def test_legacy_introspection_is_now_only_for_remaining_compat_hooks(self):
        foundation = self.text(FOUNDATION)
        self.assertIn("debug.getupvalue", foundation)
        self.assertIn("debug.setupvalue", foundation)
        self.assertIn("local function fResolveCompat", foundation)
        self.assertIn("api.InstallLocationRootMatcher", foundation)
        self.assertIn("api.InstallRosterQueueGuard", foundation)
        self.assertIn('local VERSION = "p0.3b-core-api-state"', foundation)
        self.assertIn("W112_SUMMONSCOUT_COMPAT_VERSION = 4", foundation)
        self.assertIn("api.compatVersion = 4", foundation)

    def test_hot_transform_accepts_core_native_export_anchor(self):
        transform_path = ROOT / "tools" / "summonscout_hot_transform.py"
        spec = importlib.util.spec_from_file_location("summonscout_hot_transform", transform_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        transformed = module.transform_core(CORE.read_bytes()).decode("utf-8")
        self.assertIn("W112_SUMMONSCOUT_CORE_API_NATIVE = true", transformed)
        self.assertIn("if hotReload then EventAPI.setDefaults() end", transformed)
        self.assertLess(
            transformed.index("W112_SUMMONSCOUT_CORE_API_NATIVE = true"),
            transformed.index("if hotReload then EventAPI.setDefaults() end"),
        )


if __name__ == "__main__":
    unittest.main()
