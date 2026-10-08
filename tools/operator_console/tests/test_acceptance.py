import threading
import unittest

import mock_service
from acceptance import AcceptanceProbe, RequestTrace, _report
from protocol import make_event


class AcceptanceTests(unittest.TestCase):
    def setUp(self):
        mock_service.STATE = mock_service.State()
        self.server = mock_service.Server(('127.0.0.1', 0), mock_service.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': 0.05}, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def test_passive_probe_validates_reconnect_and_full_paid_lifecycle(self):
        mock_service.emit_cycle(1)
        probe = AcceptanceProbe('127.0.0.1', self.server.server_address[1], 3.0, 'Player01')
        trace = probe.observe(reconnect_once=True)
        report = _report(probe, trace)
        self.assertTrue(report['acceptance_pass'])
        self.assertTrue(report['hello_ack'])
        self.assertEqual(report['invalid_events'], 0)
        self.assertEqual(report['duplicate_event_ids'], 0)
        self.assertEqual(report['request']['customer'], 'Player01')
        self.assertIn('SummonCompleted', report['request']['types'])
        self.assertIn('PaymentReceived', report['request']['types'])

    def test_trace_rejects_identity_drift(self):
        trace = RequestTrace('req-1')
        trace.add(make_event('WhisperReceived', request_id='req-1', session_id='s1', customer='Alice', correlation_id='c1'))
        with self.assertRaises(AssertionError):
            trace.add(make_event('ParserDecision', request_id='req-1', session_id='s1', customer='Bob', correlation_id='c1'))

    def test_trace_requires_payment_after_completed_summon(self):
        trace = RequestTrace('req-2')
        for event_type in ('WhisperReceived', 'ParserDecision', 'RequestQueued', 'SummonStarted', 'SummonCompleted'):
            trace.add(make_event(event_type, request_id='req-2', session_id='s1', customer='Alice', correlation_id='c2'))
        self.assertFalse(trace.complete())
        trace.add(make_event('PaymentExpected', request_id='req-2', session_id='s1', customer='Alice', correlation_id='c2'))
        trace.add(make_event('PaymentMissing', request_id='req-2', session_id='s1', customer='Alice', correlation_id='c2'))
        self.assertTrue(trace.complete())
        trace.assert_order()


if __name__ == '__main__':
    unittest.main()
