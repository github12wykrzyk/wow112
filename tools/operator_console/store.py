from __future__ import annotations

import json
import sqlite3
import threading
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

from protocol import validate_event

class EventStore:
    def __init__(self, path: str | Path, max_events: int = 500_000):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.max_events = max(10_000, int(max_events))
        self._lock = threading.RLock()
        self._db = sqlite3.connect(str(self.path), check_same_thread=False, timeout=30)
        self._db.row_factory = sqlite3.Row
        self._db.execute('PRAGMA journal_mode=WAL')
        self._db.execute('PRAGMA synchronous=NORMAL')
        self._db.executescript('''
        CREATE TABLE IF NOT EXISTS events (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            event_id TEXT NOT NULL UNIQUE,
            ts_utc TEXT NOT NULL,
            type TEXT NOT NULL,
            session_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            customer TEXT NOT NULL,
            destination TEXT NOT NULL,
            state TEXT NOT NULL,
            amount_copper INTEGER NOT NULL,
            correlation_id TEXT NOT NULL,
            severity TEXT NOT NULL,
            metadata_json TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_events_customer_seq ON events(customer, seq DESC);
        CREATE INDEX IF NOT EXISTS idx_events_request_seq ON events(request_id, seq DESC);
        CREATE INDEX IF NOT EXISTS idx_events_type_seq ON events(type, seq DESC);
        CREATE INDEX IF NOT EXISTS idx_events_session_seq ON events(session_id, seq DESC);
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        ''')
        self._db.commit()

    def close(self) -> None:
        with self._lock:
            self._db.close()

    def add_event(self, event: Dict[str, Any]) -> bool:
        event = validate_event(event)
        with self._lock:
            cur = self._db.execute('''
                INSERT OR IGNORE INTO events(
                    event_id, ts_utc, type, session_id, request_id, customer,
                    destination, state, amount_copper, correlation_id, severity, metadata_json
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            ''', self._params(event))
            inserted = cur.rowcount == 1
            if inserted:
                self._db.execute("INSERT INTO meta(key,value) VALUES('last_event_id',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (event['event_id'],))
            self._db.commit()
            return inserted

    def add_events(self, events: Iterable[Dict[str, Any]]) -> int:
        inserted = 0
        last_id: Optional[str] = None
        with self._lock:
            self._db.execute('BEGIN')
            try:
                for raw in events:
                    event = validate_event(raw)
                    cur = self._db.execute('''
                        INSERT OR IGNORE INTO events(event_id, ts_utc, type, session_id, request_id, customer,
                            destination, state, amount_copper, correlation_id, severity, metadata_json)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                    ''', self._params(event))
                    if cur.rowcount == 1:
                        inserted += 1
                        last_id = event['event_id']
                if last_id:
                    self._db.execute("INSERT INTO meta(key,value) VALUES('last_event_id',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (last_id,))
                self._db.commit()
            except Exception:
                self._db.rollback()
                raise
        return inserted

    def _params(self, e: Dict[str, Any]):
        return (
            e['event_id'], e['ts_utc'], e['type'], e['session_id'], e['request_id'], e['customer'],
            e['destination'], e['state'], e['amount_copper'], e['correlation_id'], e['severity'],
            json.dumps(e['metadata'], ensure_ascii=False, separators=(',', ':')),
        )

    def last_event_id(self) -> str:
        with self._lock:
            row = self._db.execute("SELECT value FROM meta WHERE key='last_event_id'").fetchone()
            return row['value'] if row else ''

    def count(self, where: str = '', args=()) -> int:
        sql = 'SELECT COUNT(*) AS n FROM events'
        if where:
            sql += ' WHERE ' + where
        with self._lock:
            return int(self._db.execute(sql, args).fetchone()['n'])

    def recent(self, *, limit: int = 200, event_type: str = '', customer: str = '', request_id: str = '') -> List[Dict[str, Any]]:
        limit = min(max(int(limit), 1), 1000)
        where, args = [], []
        if event_type:
            where.append('type = ?'); args.append(event_type)
        if customer:
            where.append('LOWER(customer) = LOWER(?)'); args.append(customer)
        if request_id:
            where.append('request_id = ?'); args.append(request_id)
        sql = 'SELECT * FROM events'
        if where:
            sql += ' WHERE ' + ' AND '.join(where)
        sql += ' ORDER BY seq DESC LIMIT ?'
        args.append(limit)
        with self._lock:
            rows = self._db.execute(sql, args).fetchall()
        return [self._row(r) for r in rows]

    def search_customer(self, customer: str, limit: int = 500) -> List[Dict[str, Any]]:
        customer = str(customer).strip()
        if not customer:
            return []
        limit = min(max(int(limit), 1), 1000)
        with self._lock:
            rows = self._db.execute('''
                SELECT * FROM events
                WHERE LOWER(customer) = LOWER(?)
                ORDER BY seq DESC LIMIT ?
            ''', (customer, limit)).fetchall()
        return [self._row(r) for r in rows]

    def trim(self) -> int:
        with self._lock:
            total = self.count()
            excess = total - self.max_events
            if excess <= 0:
                return 0
            self._db.execute('DELETE FROM events WHERE seq IN (SELECT seq FROM events ORDER BY seq ASC LIMIT ?)', (excess,))
            self._db.commit()
            return excess

    def snapshot(self, limit: int = 200) -> Dict[str, Any]:
        limit = min(max(int(limit), 1), 500)
        recent = self.recent(limit=limit)
        by_type: Dict[str, int] = {}
        for e in recent:
            by_type[e['type']] = by_type.get(e['type'], 0) + 1
        queue = [e for e in recent if e['type'] in ('RequestQueued', 'SummonStarted', 'SummonCompleted', 'SummonFailed')]
        lifecycle = self.recent(limit=1000)
        latest_by_request = {}
        for e in lifecycle:
            if e['request_id'] and e['type'] in ('RequestQueued', 'SummonStarted', 'SummonCompleted', 'SummonFailed') and e['request_id'] not in latest_by_request:
                latest_by_request[e['request_id']] = e
        waiting = [e for e in latest_by_request.values() if e['type'] == 'RequestQueued']
        active = [e for e in latest_by_request.values() if e['type'] == 'SummonStarted']
        whispers = [e for e in recent if e['type'] in ('WhisperReceived', 'ParserDecision')]
        payments = [e for e in recent if e['type'] in ('PaymentExpected', 'PaymentReceived', 'PaymentMissing', 'TradeUncertain')]
        summons = [e for e in recent if e['type'] in ('RequestQueued', 'SummonStarted', 'SummonCompleted', 'SummonFailed')]
        uncertain = self.count("type = 'TradeUncertain' OR state = 'uncertain' OR LOWER(severity) IN ('error','critical')")
        unpaid = self.count("type = 'PaymentMissing'")
        with self._lock:
            revenue_row = self._db.execute("SELECT COALESCE(SUM(amount_copper),0) AS n FROM events WHERE type='PaymentReceived'").fetchone()
            sessions_row = self._db.execute("SELECT COUNT(DISTINCT session_id) AS n FROM events WHERE session_id <> ''").fetchone()
        revenue = int(revenue_row['n'])
        sessions = int(sessions_row['n'])
        reconnects = self.count("type = 'Reconnect'")
        return {
            'total_events': self.count(),
            'sessions': sessions,
            'reconnects': reconnects,
            'queue_depth': len(waiting),
            'active_summon': active[0] if active else None,
            'revenue_copper': revenue,
            'unpaid': unpaid,
            'uncertain': uncertain,
            'by_type_recent': by_type,
            'events': recent,
            'whispers': whispers[:100],
            'queue': queue[:100],
            'summons': summons[:100],
            'payments': payments[:100],
        }

    @staticmethod
    def _row(r: sqlite3.Row) -> Dict[str, Any]:
        return {
            'seq': r['seq'], 'event_id': r['event_id'], 'ts_utc': r['ts_utc'], 'type': r['type'],
            'session_id': r['session_id'], 'request_id': r['request_id'], 'customer': r['customer'],
            'destination': r['destination'], 'state': r['state'], 'amount_copper': r['amount_copper'],
            'correlation_id': r['correlation_id'], 'severity': r['severity'],
            'metadata': json.loads(r['metadata_json'] or '{}'),
        }
