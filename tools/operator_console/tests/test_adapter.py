import json,socket,tempfile,threading,time,unittest
from pathlib import Path
from protocol import encode_line,make_event
from service_adapter import ServiceConnector
from store import EventStore

class ReplayServer(threading.Thread):
    def __init__(self,events):
        super().__init__(daemon=True); self.events=events; self.ready=threading.Event(); self.stop_evt=threading.Event(); self.port=0; self.handshakes=[]
    def run(self):
        s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',0)); s.listen(); s.settimeout(.2); self.port=s.getsockname()[1]; self.ready.set()
        while not self.stop_evt.is_set():
            try:c,_=s.accept()
            except socket.timeout:continue
            c.settimeout(1); f=c.makefile('rb'); line=f.readline();
            if not line: c.close(); continue
            h=json.loads(line); self.handshakes.append(h); cursor=h.get('resume_after_event_id',''); start=0
            if cursor:
                for i,e in enumerate(self.events):
                    if e['event_id']==cursor:start=i+1;break
            c.sendall(encode_line({'kind':'hello_ack','schema_version':1}))
            for e in self.events[start:]: c.sendall(encode_line(e))
            time.sleep(.1); c.close()
        s.close()
    def stop(self): self.stop_evt.set(); self.join(2)


class CommandServer(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True); self.ready=threading.Event(); self.stop_evt=threading.Event(); self.port=0; self.command=None
    def run(self):
        s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',0)); s.listen(); self.port=s.getsockname()[1]; self.ready.set()
        c,_=s.accept(); f=c.makefile('rb'); f.readline(); c.sendall(encode_line({'kind':'hello_ack','schema_version':1}))
        line=f.readline();
        if line: self.command=json.loads(line)
        time.sleep(.1); c.close(); s.close()

class AdapterTests(unittest.TestCase):
    def test_manual_whisper_transport(self):
        from protocol import make_command
        srv=CommandServer(); srv.start(); srv.ready.wait(2)
        with tempfile.TemporaryDirectory() as d:
            store=EventStore(Path(d)/'db.sqlite3'); c=ServiceConnector(store,'127.0.0.1',srv.port,reconnect_seconds=.2); c.start()
            deadline=time.time()+2
            while time.time()<deadline and not c.connected: time.sleep(.02)
            result=c.send_command(make_command('ManualWhisper',session_id='session-1',customer='Alice',text='hello'))
            self.assertTrue(result['accepted_for_transport'])
            deadline=time.time()+2
            while time.time()<deadline and srv.command is None: time.sleep(.02)
            self.assertEqual(srv.command['type'],'ManualWhisper'); self.assertEqual(srv.command['session_id'],'session-1'); self.assertEqual(srv.command['customer'],'Alice')
            c.stop(); store.close()

    def test_uncertain_send_hard_stops_without_retry(self):
        from protocol import make_command
        class FailingSocket:
            def __init__(self): self.calls=0; self.closed=False
            def sendall(self, payload):
                self.calls += 1
                raise OSError('synthetic uncertain send')
            def close(self): self.closed=True
        with tempfile.TemporaryDirectory() as d:
            store=EventStore(Path(d)/'db.sqlite3'); c=ServiceConnector(store,'127.0.0.1',9)
            sock=FailingSocket(); c._sock=sock; c.connected=True
            with self.assertRaises(ConnectionError): c.send_command(make_command('Pause'))
            self.assertEqual(sock.calls,1)
            self.assertEqual(c.command_uncertain,1)
            self.assertFalse(c.connected)
            self.assertTrue(sock.closed)
            store.close()
    def test_reconnect_cursor_and_dedupe(self):
        events=[make_event('WhisperReceived',event_id=f'e{i}',customer='Alice') for i in range(5)]
        srv=ReplayServer(events); srv.start(); srv.ready.wait(2)
        with tempfile.TemporaryDirectory() as d:
            store=EventStore(Path(d)/'db.sqlite3'); store.add_events(events[:2]); c=ServiceConnector(store,'127.0.0.1',srv.port,reconnect_seconds=.2); c.start()
            deadline=time.time()+4
            while time.time()<deadline and store.count()<5: time.sleep(.05)
            self.assertEqual(store.count(),5); self.assertTrue(any(h.get('resume_after_event_id')=='e1' for h in srv.handshakes))
            c.stop(); store.close()
        srv.stop()
if __name__=='__main__':unittest.main()
