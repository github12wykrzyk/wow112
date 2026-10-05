import unittest


def allow(exposures, buyout, deid, materials, epoch, session,
          session_cap=100000, rolling_cap=200000, deid_cap=50000,
          material_cap=50000, max_epoch=3):
    active = [e for e in exposures if e['status'] in ('UNKNOWN','CONFIRMED')]
    if sum(e['buyout'] for e in active if e['session']==session) + buyout > session_cap: return False
    if sum(e['buyout'] for e in active) + buyout > rolling_cap: return False
    if sum(e['buyout'] for e in active if e['deid']==deid) + buyout > deid_cap: return False
    if sum(1 for e in active if e['epoch']==epoch) >= max_epoch: return False
    for m in materials:
        if sum(e['buyout'] for e in active if m in e['materials']) + buyout > material_cap: return False
    return True


class RiskControllerTests(unittest.TestCase):
    def e(self, buyout=80000, status='CONFIRMED', deid=7, materials=(11174,), epoch=1, session='A'):
        return dict(buyout=buyout,status=status,deid=deid,materials=set(materials),epoch=epoch,session=session)

    def test_reconnect_after_8g_same_session_blocks_3g(self):
        self.assertFalse(allow([self.e()], 30000, 8, {11175}, 2, 'A'))

    def test_restart_after_8g_still_hits_rolling_exposure(self):
        self.assertFalse(allow([self.e(buyout=80000)], 130000, 8, {11175}, 2, 'B'))

    def test_unknown_counts_as_exposure(self):
        self.assertFalse(allow([self.e(buyout=40000,status='UNKNOWN')], 20000, 7, {11174}, 2, 'B'))

    def test_30_same_material_trips_material_cap(self):
        xs=[self.e(buyout=2000,session=f'S{i}',epoch=i) for i in range(25)]
        self.assertFalse(allow(xs, 1000, 7, {11174}, 99, 'Z'))

    def test_epoch_limit(self):
        xs=[self.e(buyout=1000,deid=i+1,materials=(100+i,),epoch=5,session=f'S{i}') for i in range(3)]
        self.assertFalse(allow(xs, 1000, 8, {11175}, 5, 'Z'))

    def test_different_material_under_caps_allowed(self):
        xs=[self.e(buyout=1000)]
        self.assertTrue(allow(xs, 1000, 8, {11175}, 2, 'B'))


if __name__ == '__main__': unittest.main()
