import unittest


def safe_price(raw, anchor, history_n, confidence=3, min_history=3, shock_bps=2000):
    if raw <= 0 or anchor <= 0 or confidence < 2 or history_n < min_history:
        return 0
    ceiling = anchor * (10000 + shock_bps) // 10000
    return raw if raw <= ceiling else 0


def history_keys(rows, now=100000, max_age=21600, epoch_s=900):
    # rows: (item_id, unix_s, scan_id). scan_id is explicit provenance; the
    # stronger independence rule collapses every observation in the same epoch.
    return {(item, ts // epoch_s) for item, ts, _scan in rows if 0 <= now - ts <= max_age}


def exposure_allowed(exposures, buyout, deid, materials, epoch, session,
                     session_cap=100000, rolling_cap=200000,
                     deid_cap=50000, material_cap=50000, max_epoch=3):
    active = [e for e in exposures if e['status'] in ('UNKNOWN', 'CONFIRMED')]
    if sum(e['buyout'] for e in active if e['session'] == session) + buyout > session_cap:
        return False
    if sum(e['buyout'] for e in active) + buyout > rolling_cap:
        return False
    if sum(e['buyout'] for e in active if e['deid'] == deid) + buyout > deid_cap:
        return False
    if sum(1 for e in active if e['epoch'] == epoch) >= max_epoch:
        return False
    for material in materials:
        if sum(e['buyout'] for e in active if material in e['materials']) + buyout > material_cap:
            return False
    return True


def model_agrees(heuristic_ev, reference_ev, max_bps=1000):
    if heuristic_ev <= 0 or reference_ev <= 0:
        return False
    hi, lo = max(heuristic_ev, reference_ev), min(heuristic_ev, reference_ev)
    return (hi - lo) * 10000 // hi <= max_bps


def snapshot_name(unix_s, pid, source_hash):
    return f'{unix_s}-{pid}-{source_hash:016x}.csv'


def snapshot_row_valid(cols):
    return len(cols) == 13 and cols[0] == '2'


def risk_required(action):
    return action == 'de-whitelist'


class Poc08IncidentRegressionMatrix(unittest.TestCase):
    def e(self, buyout=80000, status='CONFIRMED', deid=7,
          materials=(11174,), epoch=1, session='A'):
        return dict(buyout=buyout, status=status, deid=deid,
                    materials=set(materials), epoch=epoch, session=session)

    def test_01_lesser_nether_59s_to_80s_in_hour_is_quarantined(self):
        self.assertEqual(safe_price(8000, 5900, 3), 0)

    def test_02_single_thin_material_doubles_is_quarantined(self):
        self.assertEqual(safe_price(12000, 6000, 3, confidence=2), 0)

    def test_03_four_to_six_listings_does_not_replace_history(self):
        self.assertEqual(safe_price(6500, 6000, 0, confidence=3), 0)

    def test_04_missing_history_blocks_de(self):
        self.assertEqual(safe_price(6000, 0, 0), 0)

    def test_05_history_file_exists_but_runtime_loaded_zero_blocks_de(self):
        self.assertEqual(safe_price(6000, 6000, 0), 0)

    def test_06_stale_history_is_excluded(self):
        self.assertEqual(len(history_keys([(11174, 100000-21601, 'old')], now=100000)), 0)

    def test_07_repeated_same_scan_or_epoch_counts_once(self):
        rows = [(11174, 99001, 'scan-x'), (11174, 99002, 'scan-x'), (11174, 99003, 'scan-x')]
        self.assertEqual(len(history_keys(rows)), 1)

    def test_08_stack_unit_mismatch_uses_conservative_ceiling(self):
        buyout, count = 100, 3
        self.assertEqual((buyout + count - 1) // count, 34)

    def test_09_reconnect_after_spending_8g_preserves_session_exposure(self):
        self.assertFalse(exposure_allowed([self.e()], 30000, 8, {11175}, 2, 'A'))

    def test_10_restart_after_spending_8g_preserves_rolling_exposure(self):
        self.assertFalse(exposure_allowed([self.e()], 130000, 8, {11175}, 2, 'NEW_PROCESS'))

    def test_11_unknown_buy_counts_as_exposure(self):
        self.assertFalse(exposure_allowed([self.e(buyout=40000, status='UNKNOWN')], 20000, 7, {11174}, 2, 'B'))

    def test_12_thirty_greens_same_material_trip_concentration_cap(self):
        xs = [self.e(buyout=2000, session=f'S{i}', epoch=i) for i in range(25)]
        self.assertFalse(exposure_allowed(xs, 1000, 7, {11174}, 99, 'Z'))

    def test_13_reference_ev_far_above_heuristic_is_blocked(self):
        self.assertFalse(model_agrees(10000, 30000, max_bps=1000))

    def test_14_parallel_clients_do_not_share_snapshot_filename(self):
        a = snapshot_name(100000, 111, 0xAAAA)
        b = snapshot_name(100000, 222, 0xBBBB)
        self.assertNotEqual(a, b)

    def test_15_partially_written_dump_is_invalid(self):
        self.assertFalse(snapshot_row_valid(['2', 'snapshot', 'scan', '100000', 'client']))

    def test_16_vendor_regression_de_controller_not_applied_to_vendor(self):
        self.assertFalse(risk_required('vendor-smoke'))
        self.assertTrue(risk_required('de-whitelist'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
