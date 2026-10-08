import tempfile,time,unittest
from pathlib import Path
from protocol import make_event
from store import EventStore

class StoreTests(unittest.TestCase):
    def setUp(self): self.t=tempfile.TemporaryDirectory(); self.s=EventStore(Path(self.t.name)/'events.db')
    def tearDown(self): self.s.close(); self.t.cleanup()
    def test_dedupe_and_search(self):
        e=make_event('PaymentReceived',event_id='pay-1',customer='Alice',state='paid',amount_copper=40000)
        self.assertTrue(self.s.add_event(e)); self.assertFalse(self.s.add_event(e)); self.assertEqual(self.s.count(),1); self.assertEqual(self.s.search_customer('alice')[0]['amount_copper'],40000)
    def test_snapshot_queue_and_active_summon(self):
        self.s.add_event(make_event('RequestQueued',event_id='q1',request_id='r1',customer='Alice',destination='Hyjal',state='waiting'))
        self.s.add_event(make_event('SummonStarted',event_id='a1',request_id='r2',customer='Bob',destination='Azshara',state='active'))
        snap=self.s.snapshot()
        self.assertEqual(snap['queue_depth'],1)
        self.assertEqual(snap['active_summon']['customer'],'Bob')
    def test_historical_payment_timestamp_preserved(self):
        ts='2026-10-08T06:00:00.000Z'
        self.s.add_event(make_event('PaymentReceived',event_id='old-pay',customer='Alice',amount_copper=40000,ts_utc=ts,state='paid'))
        self.assertEqual(self.s.search_customer('Alice')[0]['ts_utc'],ts)
    def test_50k_performance_and_bounded_query(self):
        rows=[make_event('WhisperReceived',event_id=f'e-{i}',customer=f'P{i%100}',metadata={'text':'need one'}) for i in range(50000)]
        t=time.perf_counter(); n=self.s.add_events(rows); elapsed=time.perf_counter()-t
        self.assertEqual(n,50000); self.assertLess(elapsed,15.0)
        t=time.perf_counter(); recent=self.s.recent(limit=50000); q=time.perf_counter()-t
        self.assertEqual(len(recent),1000); self.assertLess(q,2.0)
        self.assertEqual(self.s.add_events(rows),0)
if __name__=='__main__': unittest.main()
