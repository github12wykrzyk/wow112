from __future__ import annotations

import argparse
import json
import socketserver
import threading
import time
from collections import deque

from protocol import encode_line, make_event

class State:
    def __init__(self, max_history=100000):
        self.lock = threading.RLock(); self.events = deque(maxlen=max_history); self.clients = set(); self.paused = False; self.seq = 0
    def append(self, event):
        with self.lock:
            self.events.append(event); clients = list(self.clients)
        dead=[]
        for c in clients:
            try: c.wfile.write(encode_line(event)); c.wfile.flush()
            except Exception: dead.append(c)
        with self.lock:
            for c in dead: self.clients.discard(c)
    def replay_after(self, event_id):
        with self.lock: rows=list(self.events)
        if not event_id: return rows
        for i,e in enumerate(rows):
            if e['event_id']==event_id: return rows[i+1:]
        return rows

STATE=State()

class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        first=self.rfile.readline(1_048_577)
        if not first: return
        try: hello=json.loads(first.decode('utf-8'))
        except Exception: return
        if hello.get('kind')!='hello': return
        self.wfile.write(encode_line({'kind':'hello_ack','schema_version':1,'replay':True})); self.wfile.flush()
        for e in STATE.replay_after(hello.get('resume_after_event_id','')):
            self.wfile.write(encode_line(e))
        self.wfile.flush()
        with STATE.lock: STATE.clients.add(self)
        try:
            for line in self.rfile:
                try: obj=json.loads(line.decode('utf-8'))
                except Exception: continue
                if obj.get('kind')!='command': continue
                typ=obj.get('type')
                if typ=='Pause': STATE.paused=True
                elif typ=='Resume': STATE.paused=False
                elif typ=='ManualWhisper':
                    pass
                self.wfile.write(encode_line({'kind':'command_ack','schema_version':1,'command_id':obj.get('command_id'),'accepted':True})); self.wfile.flush()
        finally:
            with STATE.lock: STATE.clients.discard(self)

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address=True; daemon_threads=True

def emit_cycle(i:int):
    customer=f'Player{i%37:02d}'; dest=('Hyjal','Azshara','Winterspring')[i%3]; sid=f'session-{i%3+1}'; rid=f'req-{i:08d}'; corr=f'corr-{i:08d}'
    raw=f'{customer}: need one {dest.lower()}'
    STATE.append(make_event('WhisperReceived', session_id=sid, request_id=rid, customer=customer, destination=dest, state='received', correlation_id=corr, metadata={'text':raw}))
    STATE.append(make_event('ParserDecision', session_id=sid, request_id=rid, customer=customer, destination=dest, state='accepted', correlation_id=corr, metadata={'raw':raw,'normalized':raw.lower(),'result':'summon_request','reason':'canonical_mock_decision'}))
    STATE.append(make_event('RequestQueued', session_id=sid, request_id=rid, customer=customer, destination=dest, state='waiting', correlation_id=corr))
    STATE.append(make_event('SummonStarted', session_id=sid, request_id=rid, customer=customer, destination=dest, state='active', correlation_id=corr))
    if i%11==0:
        STATE.append(make_event('TradeUncertain', session_id=sid, request_id=rid, customer=customer, destination=dest, state='uncertain', correlation_id=corr, severity='warning', metadata={'reason':'mock uncertain trade outcome'}))
    else:
        STATE.append(make_event('SummonCompleted', session_id=sid, request_id=rid, customer=customer, destination=dest, state='completed', correlation_id=corr))
        STATE.append(make_event('PaymentExpected', session_id=sid, request_id=rid, customer=customer, destination=dest, state='expected', correlation_id=corr, amount_copper=0))
        if i%5:
            STATE.append(make_event('PaymentReceived', session_id=sid, request_id=rid, customer=customer, destination=dest, state='paid', correlation_id=corr, amount_copper=40000))
        else:
            STATE.append(make_event('PaymentMissing', session_id=sid, request_id=rid, customer=customer, destination=dest, state='unpaid', correlation_id=corr, severity='warning'))

def generator(interval:float):
    STATE.append(make_event('ServiceStarted', state='running', metadata={'mock':True}))
    i=0
    while True:
        if not STATE.paused:
            emit_cycle(i); i+=1
        time.sleep(interval)

def main(argv=None):
    p=argparse.ArgumentParser(); p.add_argument('--host',default='127.0.0.1'); p.add_argument('--port',type=int,default=58751); p.add_argument('--interval',type=float,default=1.0); p.add_argument('--burst',type=int,default=0)
    a=p.parse_args(argv)
    if a.burst:
        STATE.append(make_event('ServiceStarted',state='running',metadata={'mock':True,'burst':a.burst}))
        for i in range(a.burst): emit_cycle(i)
    else: threading.Thread(target=generator,args=(a.interval,),daemon=True).start()
    with Server((a.host,a.port),Handler) as s: s.serve_forever(poll_interval=.2)
if __name__=='__main__': main()
