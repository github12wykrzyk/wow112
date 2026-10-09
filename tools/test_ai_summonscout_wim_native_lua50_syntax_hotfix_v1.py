import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"
MODULE = ADDON / "SummonScout_WhisperRelayWimNativeHot.lua"
PACKAGER = ROOT / "tools" / "package_lazyrogue_addons.py"


def load_packager():
    spec = importlib.util.spec_from_file_location("package_lazyrogue_addons_test", PACKAGER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SummonScoutWimNativeLua50SyntaxHotfixV1(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = MODULE.read_text(encoding="utf-8")
        cls.packager = load_packager()
        host = ADDON / "SummonScout_WhisperConfirmSpam.lua"
        cls.packaged = cls.packager.package_bytes("SummonScout", host).decode("utf-8")

    def test_source_uses_lua50_compatible_multi_local_declaration(self):
        self.assertIn(
            'local V, P, W = "2-native-whisper-wim-lua50fix2", "[SSWR1]", H.GetState("whisperrelaywim")',
            self.source,
        )
        self.assertNotIn(
            'local V="2-native-whisper-wim", P="[SSWR1]", W=',
            self.source,
        )

    def test_source_avoids_named_assignments_inside_local_declaration(self):
        self.assertIn('local sid=trim(box.W112RelaySid or "")', self.source)
        self.assertIn('local s=trim(box.W112RelaySummoner or "")', self.source)
        self.assertIn('local c=trim(box.W112RelayCustomer or "")', self.source)
        self.assertIn('local sid=f[1] or ""', self.source)
        self.assertIn('local idx=tonumber(f[2]) or 0', self.source)
        self.assertIn('local k=low(sender).."|"..sid', self.source)
        self.assertNotIn(
            'local sid=trim(box.W112RelaySid or ""), s=trim(box.W112RelaySummoner or ""), c=trim(box.W112RelayCustomer or "")',
            self.source,
        )
        self.assertNotIn(
            'local sid=f[1] or "", idx=tonumber(f[2]) or 0, k=low(sender).."|"..sid',
            self.source,
        )

    def test_final_hot_fanout_contains_fixed_declarations(self):
        marker = "W112 HOT FANOUT BEGIN SummonScout_WhisperRelayWimNativeHot.lua"
        self.assertIn(marker, self.packaged)
        start = self.packaged.index(marker)
        end = self.packaged.index(
            "W112 HOT FANOUT END SummonScout_WhisperRelayWimNativeHot.lua", start
        )
        block = self.packaged[start:end]
        self.assertIn(
            'local V, P, W = "2-native-whisper-wim-lua50fix2", "[SSWR1]", H.GetState("whisperrelaywim")',
            block,
        )
        self.assertIn('local sid=trim(box.W112RelaySid or "")', block)
        self.assertIn('local idx=tonumber(f[2]) or 0', block)
        self.assertNotIn(
            'local V="2-native-whisper-wim", P="[SSWR1]", W=',
            block,
        )
        self.assertNotIn(
            'local sid=trim(box.W112RelaySid or ""), s=trim(box.W112RelaySummoner or ""), c=trim(box.W112RelayCustomer or "")',
            block,
        )
        self.assertNotIn(
            'local sid=f[1] or "", idx=tonumber(f[2]) or 0, k=low(sender).."|"..sid',
            block,
        )

    def test_fix_does_not_add_transport_send_path(self):
        self.assertNotIn("SendChatMessage", self.source)


if __name__ == "__main__":
    unittest.main()
