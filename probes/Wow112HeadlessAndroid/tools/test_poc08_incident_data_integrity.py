import unittest


def safe_price(raw, anchor, history_n, confidence=3, min_history=3, shock_bps=2000):
    if confidence < 2 or history_n < min_history or anchor <= 0:
        return 0
    max_allowed = anchor * (10000 + shock_bps) // 10000
    return raw if raw <= max_allowed else 0


def independent_epochs(timestamps, epoch_s=900, max_age_s=21600, now=100000):
    return len({t // epoch_s for t in timestamps if 0 <= now - t <= max_age_s})


class IncidentDataIntegrityTests(unittest.TestCase):
    def test_lesser_59_to_80_quarantined(self):
        self.assertEqual(safe_price(8000, 5900, 3), 0)

    def test_double_price_thin_material_blocks(self):
        self.assertEqual(safe_price(12000, 6000, 3, confidence=2), 0)

    def test_4_to_6_listings_does_not_replace_history_requirement(self):
        self.assertEqual(safe_price(6500, 6000, 0, confidence=3), 0)

    def test_no_history_blocks(self):
        self.assertEqual(safe_price(6000, 0, 0), 0)

    def test_history_exists_but_not_loaded_blocks(self):
        self.assertEqual(safe_price(6000, 6000, 0), 0)

    def test_stale_history_is_not_counted(self):
        self.assertEqual(independent_epochs([100000-21601, 100000-30000]), 0)

    def test_same_epoch_restart_spam_is_one_observation(self):
        self.assertEqual(independent_epochs([99001, 99002, 99003]), 1)

    def test_stack_unit_ceiling(self):
        buyout, count = 100, 3
        self.assertEqual((buyout + count - 1) // count, 34)

    def test_downward_move_accepted(self):
        self.assertEqual(safe_price(4500, 5900, 3), 4500)

    def test_twenty_percent_boundary_accepted(self):
        self.assertEqual(safe_price(7080, 5900, 3), 7080)

    def test_above_twenty_percent_blocked(self):
        self.assertEqual(safe_price(7081, 5900, 3), 0)


if __name__ == '__main__':
    unittest.main()
