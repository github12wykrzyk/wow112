import unittest
from protocol import ContractError, make_command, make_event, validate_event

class ContractTests(unittest.TestCase):
    def test_common_event_contract(self):
        e=make_event('PaymentReceived',event_id='e1',session_id='s',request_id='r',customer='Alice',destination='Hyjal',state='paid',amount_copper=40000,correlation_id='c',metadata={'source':'core'})
        self.assertEqual(validate_event(e)['amount_copper'],40000)
    def test_manual_whisper_requires_explicit_identity(self):
        with self.assertRaises(ContractError): make_command('ManualWhisper',customer='Alice',text='hi')
        with self.assertRaises(ContractError): make_command('ManualWhisper',session_id='s',text='hi')
        c=make_command('ManualWhisper',session_id='s',customer='Alice',text='hi')
        self.assertEqual(c['type'],'ManualWhisper')
    def test_forbidden_command(self):
        with self.assertRaises(ContractError): make_command('Summon',session_id='s')
        with self.assertRaises(ContractError): make_command('TradeAccept',session_id='s')
    def test_redacts_secret_metadata(self):
        e=make_event('ServiceStarted',event_id='e2',metadata={'token':'abc','nested':{'Authorization':'Bearer bad','safe':'ok'}})
        self.assertEqual(e['metadata']['token'],'[REDACTED]')
        self.assertEqual(e['metadata']['nested']['Authorization'],'[REDACTED]')
        self.assertEqual(e['metadata']['nested']['safe'],'ok')
if __name__=='__main__': unittest.main()
