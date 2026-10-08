from __future__ import annotations

import argparse
import json
import socket
import sys
import time
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

from protocol import ContractError, encode_line, make_command, validate_event

TERMINAL_SUMMON = {'SummonCompleted', 'SummonFailed', 'TradeUncertain'}
TERMINAL_PAYMENT = {'PaymentReceived', 'PaymentMissing', 'TradeUncertain'}


@dataclass
class RequestTrace:
    request_id: str
    customer: str = ''
    session_id: str = ''
    destination: str = ''
    correlation_id: str = ''
    types: list[str] = field(default_factory=list)
    events: list[dict] = field(default_factory=list)

    def add(self, event: dict) -> None:
        for key in ('customer', 'session_id', 'destination', 'correlation_id'):
            value = event.get(key, '')
            old = getattr(self, key)
            if value and old and value != old:
                raise AssertionError(f'{self.request_id}: {key} changed from {old!r} to {value!r}')
            if value and not old:
                setattr(self, key, value)
        self.types.append(event['type'])
        self.events.append(event)

    def complete(self) -> bool:
        needed = {'WhisperReceived', 'ParserDecision', 'RequestQueued', 'SummonStarted'}
        if not needed.issubset(self.types):
            return False
        if not TERMINAL_SUMMON.intersection(self.types):
            return False
        if 'SummonCompleted' in self.types:
            if 'PaymentExpected' not in self.types:
                return False
            if not TERMINAL_PAYMENT.intersection(self.types):
                return False
        return True

    def assert_order(self) -> None:
        def before(a: str, b: str) -> None:
            if a in self.types and b in self.types and self.types.index(a) > self.types.index(b):
                raise AssertionError(f'{self.request_id}: {a} arrived after {b}')

        before('WhisperReceived', 'ParserDecision')
        before('ParserDecision', 'RequestQueued')
        before('RequestQueued', 'SummonStarted')
        for terminal in TERMINAL_SUMMON:
            before('SummonStarted', terminal)
        before('SummonCompleted', 'PaymentExpected')
        before('PaymentExpected', 'PaymentReceived')
        before('PaymentExpected', 'PaymentMissing')


class AcceptanceProbe:
    def __init__(self, host: str, port: int, timeout: float, customer: str = ''):
        self.host = host
        self.port = int(port)
        self.timeout = float(timeout)
        self.customer = customer
        self.events: list[dict] = []
        self.event_ids: set[str] = set()
        self.traces: dict[str, RequestTrace] = {}
        self.invalid = 0
        self.duplicates = 0
        self.hello_ack = False
        self.last_event_id = ''

    def _connect(self, resume_after: str = ''):
        sock = socket.create_connection((self.host, self.port), timeout=min(self.timeout, 5.0))
        sock.settimeout(1.0)
        hello = {
            'kind': 'hello',
            'schema_version': 1,
            'consumer': 'operator-console-real-service-acceptance-v1',
            'resume_after_event_id': resume_after,
        }
        sock.sendall(encode_line(hello))
        return sock, sock.makefile('rb')

    def _accept(self, obj: dict) -> None:
        try:
            event = validate_event(obj)
        except ContractError:
            self.invalid += 1
            return
        event_id = event['event_id']
        if event_id in self.event_ids:
            self.duplicates += 1
            return
        self.event_ids.add(event_id)
        self.last_event_id = event_id
        self.events.append(event)
        rid = event.get('request_id', '')
        if rid:
            trace = self.traces.setdefault(rid, RequestTrace(rid))
            trace.add(event)
            trace.assert_order()

    def observe(self, reconnect_once: bool = True) -> RequestTrace | None:
        deadline = time.monotonic() + self.timeout
        sock, stream = self._connect('')
        reconnected = False
        try:
            while time.monotonic() < deadline:
                try:
                    line = stream.readline(1_048_577)
                except socket.timeout:
                    continue
                if not line:
                    raise ConnectionError('Summon Service closed the acceptance connection')
                if len(line) > 1_048_576:
                    raise AssertionError('oversize frame from Summon Service')
                try:
                    obj = json.loads(line.decode('utf-8'))
                except Exception as exc:
                    raise AssertionError('non-JSON frame from Summon Service') from exc
                if obj.get('kind') == 'hello_ack':
                    self.hello_ack = True
                    continue
                if obj.get('kind') == 'command_ack':
                    continue
                self._accept(obj)

                matching = [t for t in self.traces.values() if t.complete() and (not self.customer or t.customer.lower() == self.customer.lower())]
                if matching and (not reconnect_once or reconnected):
                    return matching[-1]

                # Exercise cursor replay once after we have a durable cursor. No command or game mutation is sent.
                if reconnect_once and not reconnected and self.last_event_id and len(self.events) >= 3:
                    cursor = self.last_event_id
                    try:
                        stream.close(); sock.close()
                    finally:
                        sock, stream = self._connect(cursor)
                    reconnected = True
        finally:
            try: stream.close()
            except Exception: pass
            try: sock.close()
            except Exception: pass
        matching = [t for t in self.traces.values() if t.complete() and (not self.customer or t.customer.lower() == self.customer.lower())]
        return matching[-1] if matching else None


def _report(probe: AcceptanceProbe, trace: RequestTrace | None) -> dict:
    result = {
        'schema_version': 1,
        'hello_ack': probe.hello_ack,
        'events_received': len(probe.events),
        'unique_event_ids': len(probe.event_ids),
        'invalid_events': probe.invalid,
        'duplicate_event_ids': probe.duplicates,
        'requests_observed': len(probe.traces),
        'acceptance_pass': False,
        'request': None,
    }
    if trace:
        result['request'] = {
            'request_id': trace.request_id,
            'session_id': trace.session_id,
            'customer': trace.customer,
            'destination': trace.destination,
            'correlation_id': trace.correlation_id,
            'types': trace.types,
        }
    result['acceptance_pass'] = bool(
        probe.hello_ack and trace and trace.complete() and probe.invalid == 0 and probe.duplicates == 0
    )
    return result


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description='Passive real-service acceptance probe for Summon Service V1')
    p.add_argument('--service-host', default='127.0.0.1')
    p.add_argument('--service-port', type=int, default=58751)
    p.add_argument('--timeout', type=float, default=180.0)
    p.add_argument('--customer', default='', help='optional exact customer nick to require')
    p.add_argument('--no-reconnect-check', action='store_true')
    p.add_argument('--json-out', default='')
    args = p.parse_args(argv)

    probe = AcceptanceProbe(args.service_host, args.service_port, args.timeout, args.customer)
    try:
        trace = probe.observe(reconnect_once=not args.no_reconnect_check)
        report = _report(probe, trace)
    except Exception as exc:
        report = {
            'schema_version': 1,
            'acceptance_pass': False,
            'error': f'{type(exc).__name__}: {exc}',
            'events_received': len(probe.events),
            'invalid_events': probe.invalid,
            'duplicate_event_ids': probe.duplicates,
        }

    rendered = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True)
    print(rendered)
    if args.json_out:
        path = Path(args.json_out)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rendered + '\n', encoding='utf-8')
    return 0 if report.get('acceptance_pass') else 2


if __name__ == '__main__':
    sys.exit(main())
