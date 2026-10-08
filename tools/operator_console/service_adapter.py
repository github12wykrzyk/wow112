from __future__ import annotations

import argparse
import json
import logging
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from protocol import ContractError, encode_line, make_command, validate_event
from store import EventStore

LOG = logging.getLogger('operator-console')

class ServiceConnector:
    def __init__(self, store: EventStore, host: str, port: int, reconnect_seconds: float = 1.0):
        self.store = store
        self.host = host
        self.port = int(port)
        self.reconnect_seconds = max(0.2, reconnect_seconds)
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._run, name='summon-service-connector', daemon=True)
        self._send_lock = threading.Lock()
        self._sock: socket.socket | None = None
        self.connected = False
        self.connection_since = 0.0
        self.disconnect_reason = ''
        self.reconnect_attempts = 0
        self.invalid_events = 0
        self.duplicates = 0
        self.commands_sent = 0
        self.command_uncertain = 0
        self.last_rx_utc = ''

    def start(self): self.thread.start()
    def stop(self):
        self.stop_event.set()
        self._close_socket()
        self.thread.join(timeout=3)

    def status(self):
        return {
            'connected': self.connected,
            'host': self.host,
            'port': self.port,
            'reconnect_attempts': self.reconnect_attempts,
            'disconnect_reason': self.disconnect_reason,
            'invalid_events': self.invalid_events,
            'duplicates': self.duplicates,
            'commands_sent': self.commands_sent,
            'command_uncertain': self.command_uncertain,
            'last_rx_utc': self.last_rx_utc,
        }

    def send_command(self, command: dict) -> dict:
        payload = encode_line(command)
        with self._send_lock:
            sock = self._sock
            if not self.connected or sock is None:
                raise ConnectionError('Summon Service is disconnected; command not sent')
            try:
                sock.sendall(payload)
                self.commands_sent += 1
                return {'accepted_for_transport': True, 'command_id': command['command_id']}
            except OSError as exc:
                self.command_uncertain += 1
                self.disconnect_reason = f'command send uncertain: {type(exc).__name__}'
                self._close_socket()
                raise ConnectionError('command send result uncertain; automatic retry is disabled') from exc

    def _run(self):
        while not self.stop_event.is_set():
            try:
                self.reconnect_attempts += 1
                sock = socket.create_connection((self.host, self.port), timeout=3)
                sock.settimeout(None)
                with self._send_lock:
                    self._sock = sock
                self.connected = True
                self.connection_since = time.time()
                self.disconnect_reason = ''
                hello = {
                    'kind': 'hello',
                    'schema_version': 1,
                    'consumer': 'operator-console-service-adapter-v1',
                    'resume_after_event_id': self.store.last_event_id(),
                }
                sock.sendall(encode_line(hello))
                self._read_loop(sock)
            except (OSError, ConnectionError) as exc:
                self.disconnect_reason = f'{type(exc).__name__}: {exc}'[:256]
            finally:
                self._close_socket()
            self.stop_event.wait(self.reconnect_seconds)

    def _read_loop(self, sock: socket.socket):
        f = sock.makefile('rb')
        while not self.stop_event.is_set():
            line = f.readline(1_048_577)
            if not line:
                raise ConnectionError('service closed connection')
            if len(line) > 1_048_576:
                self.invalid_events += 1
                raise ConnectionError('oversize service frame')
            try:
                obj = json.loads(line.decode('utf-8'))
            except Exception:
                self.invalid_events += 1
                continue
            if obj.get('kind') in ('hello_ack', 'command_ack'):
                continue
            try:
                event = validate_event(obj)
            except ContractError:
                self.invalid_events += 1
                continue
            self.last_rx_utc = event['ts_utc']
            if not self.store.add_event(event):
                self.duplicates += 1

    def _close_socket(self):
        with self._send_lock:
            sock, self._sock = self._sock, None
            self.connected = False
        if sock:
            try: sock.close()
            except OSError: pass

class ConsoleApp:
    def __init__(self, db_path: Path, upstream_host: str, upstream_port: int, web_root: Path, max_events: int = 500_000):
        self.started = time.time()
        self.store = EventStore(db_path, max_events=max_events)
        self.connector = ServiceConnector(self.store, upstream_host, upstream_port)
        self.web_root = web_root

    def snapshot(self):
        snap = self.store.snapshot(limit=250)
        snap['service'] = self.connector.status()
        snap['adapter_uptime_seconds'] = int(time.time() - self.started)
        snap['schema_version'] = 1
        return snap

    def close(self):
        self.connector.stop()
        self.store.close()

def handler_factory(app: ConsoleApp):
    class Handler(BaseHTTPRequestHandler):
        server_version = 'WoW112OperatorConsole/1'
        def log_message(self, fmt, *args):
            LOG.debug(fmt, *args)

        def _json(self, status, obj):
            data = json.dumps(obj, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
            self.send_response(status)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers(); self.wfile.write(data)

        def do_GET(self):
            u = urlparse(self.path)
            if u.path == '/api/snapshot':
                return self._json(200, app.snapshot())
            if u.path == '/api/events':
                q = parse_qs(u.query)
                return self._json(200, {'events': app.store.recent(
                    limit=int(q.get('limit', ['200'])[0]),
                    event_type=q.get('type', [''])[0],
                    customer=q.get('customer', [''])[0],
                    request_id=q.get('request_id', [''])[0],
                )})
            if u.path == '/api/history':
                q = parse_qs(u.query); customer = q.get('customer', [''])[0]
                return self._json(200, {'customer': customer, 'events': app.store.search_customer(customer)})
            path = 'index.html' if u.path in ('/', '/index.html') else u.path.lstrip('/')
            target = (app.web_root / path).resolve()
            root = app.web_root.resolve()
            if root not in target.parents and target != root:
                return self.send_error(403)
            if not target.is_file():
                return self.send_error(404)
            data = target.read_bytes()
            ctype = 'text/html; charset=utf-8' if target.suffix == '.html' else 'text/plain; charset=utf-8'
            self.send_response(200); self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

        def do_POST(self):
            if urlparse(self.path).path != '/api/command':
                return self.send_error(404)
            try:
                n = int(self.headers.get('Content-Length', '0'))
                if n <= 0 or n > 8192: raise ContractError('invalid request size')
                raw = json.loads(self.rfile.read(n).decode('utf-8'))
                command = make_command(raw.get('type', ''), session_id=raw.get('session_id', ''), customer=raw.get('customer', ''), text=raw.get('text', ''))
                result = app.connector.send_command(command)
                return self._json(202, result)
            except ContractError as exc:
                return self._json(400, {'error': str(exc)})
            except ConnectionError as exc:
                return self._json(503, {'error': str(exc), 'automatic_retry': False})
            except Exception:
                LOG.exception('command endpoint failed')
                return self._json(500, {'error': 'internal error'})
    return Handler

def main(argv=None):
    p = argparse.ArgumentParser(description='WoW112 headless Summon Service operator console adapter')
    p.add_argument('--service-host', default='127.0.0.1')
    p.add_argument('--service-port', type=int, default=58751)
    p.add_argument('--listen-host', default='127.0.0.1')
    p.add_argument('--listen-port', type=int, default=8765)
    p.add_argument('--db', default=str(Path.home() / '.wow112' / 'operator_console' / 'events.sqlite3'))
    p.add_argument('--max-events', type=int, default=500000)
    p.add_argument('--log-level', default='INFO')
    args = p.parse_args(argv)
    logging.basicConfig(level=getattr(logging, args.log_level.upper(), logging.INFO), format='%(asctime)s %(levelname)s %(message)s')
    root = Path(__file__).resolve().parent
    app = ConsoleApp(Path(args.db), args.service_host, args.service_port, root / 'web', args.max_events)
    app.connector.start()
    server = ThreadingHTTPServer((args.listen_host, args.listen_port), handler_factory(app))
    LOG.info('Operator Console listening on http://%s:%s', args.listen_host, args.listen_port)
    try: server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt: pass
    finally:
        server.server_close(); app.close()

if __name__ == '__main__': main()
