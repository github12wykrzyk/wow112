from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
ADDON=ROOT/"src"/"AddOns"/"SummonScout"

class BuyOfferTradeHotfixTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.toc=(ADDON/"SummonScout.toc").read_text(encoding="utf-8")
        cls.buy=(ADDON/"SummonScout_WhisperBuy.lua").read_text(encoding="utf-8")
        cls.offer=(ADDON/"SummonScout_PostPaymentAlwaysOffer.lua").read_text(encoding="utf-8")
        cls.trade=(ADDON/"SummonScout_TradeAfterSummon.lua").read_text(encoding="utf-8")

    def test_modules_are_loaded_cold(self):
        self.assertIn("## Version: 1.71", self.toc)
        self.assertIn("SummonScout_WhisperBuy.lua", self.toc)
        self.assertIn("SummonScout_PostPaymentAlwaysOffer.lua", self.toc)
        self.assertIn("SummonScout_TradeAfterSummon.lua", self.toc)

    def test_buy_uses_canonical_classifier_and_invite_path(self):
        self.assertIn('if n == "buy" then return true, true end', self.buy)
        self.assertIn('string.sub(n, 1, 4) == "buy "', self.buy)
        self.assertIn('api.whisperInviteDecision', self.buy)
        self.assertIn('api.tryWhisperInvite', self.buy)
        self.assertNotIn('InviteByName', self.buy)

    def test_payment_watchdog_has_full_fixed_fleet(self):
        for value in ('id="hyjal"', 'id="hydraxian"', 'id="winterspring"', 'id="silithus"', 'id="tanaris"'):
            self.assertIn(value, self.offer)
        self.assertIn('SummonScoutDB.paymentLog', self.offer)
        self.assertIn('we also summon to ', self.offer.lower())
        self.assertNotIn('postPaymentOfferEnabled', self.offer)

    def test_payment_watchdog_dedupes_against_existing_complete_offer(self):
        self.assertIn('CHAT_MSG_WHISPER_INFORM', self.offer)
        self.assertIn('aoCompleteOffer', self.offer)
        self.assertIn('item.confirmed=true', self.offer)
        self.assertIn('MAX_ATTEMPTS = 2', self.offer)

    def test_trade_watchdog_waits_six_seconds_and_is_bounded(self):
        self.assertIn('OPEN_DELAY = 6.0', self.trade)
        self.assertIn('MAX_ATTEMPTS = 2', self.trade)
        self.assertIn('InitiateTrade,unit', self.trade)
        self.assertIn('CheckInteractDistance,unit,2', self.trade)
        self.assertNotIn('TargetByName', self.trade)

    def test_trade_watchdog_only_arms_after_started_summon_finishes(self):
        self.assertIn('S.prevStarted', self.trade)
        self.assertIn('and (active=="" or not taSame(active,S.prevActiveName))', self.trade)
        self.assertIn('taSchedule(S.prevActiveName)', self.trade)
        self.assertIn('TRADE_REQUEST', self.trade)
        self.assertIn('TRADE_SHOW', self.trade)

    def test_lua50_safety(self):
        for text in (self.buy,self.offer,self.trade):
            self.assertNotIn('table.unpack',text)
            self.assertNotIn('goto ',text)
            self.assertNotIn('continue',text)

if __name__ == "__main__":
    unittest.main()
