from __future__ import annotations

import hashlib
import json
import re
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable, Iterator, Mapping, Optional

SCHEMA_VERSION = 1
DB_SCHEMA_VERSION = 2
EVENT_TYPES = {
    "ServiceStarted",
    "SessionReady",
    "WhisperReceived",
    "ParserDecision",
    "RequestQueued",
    "SummonStarted",
    "SummonCompleted",
    "SummonFailed",
    "PaymentExpected",
    "PaymentReceived",
    "PaymentMissing",
    "TradeUncertain",
    "Reconnect",
    "ServiceStopped",
}
REQUEST_EVENT_TYPES = {
    "RequestQueued",
    "SummonStarted",
    "SummonCompleted",
    "SummonFailed",
    "PaymentExpected",
    "PaymentReceived",
    "PaymentMissing",
    "TradeUncertain",
}
REQUIRED_KEYS = {
    "schema_version",
    "event_id",
    "ts_utc",
    "type",
    "session_id",
    "request_id",
    "customer",
    "destination",
    "state",
    "amount_copper",
    "correlation_id",
    "severity",
    "metadata",
}
DURATION_RE = re.compile(r"^(\d+)(s|m|h|d)$", re.IGNORECASE)


class LedgerError(RuntimeError):
    pass


class EventValidationError(LedgerError):
    pass


class EventConflictError(LedgerError):
    pass


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def utc_text(value: datetime) -> str:
    if value.tzinfo is None:
        raise EventValidationError("UTC timestamp must be timezone-aware")
    return value.astimezone(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def parse_utc(value: str) -> datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise EventValidationError("ts_utc must be ISO-8601 UTC ending in Z")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as exc:
        raise EventValidationError("invalid ts_utc: %s" % value) from exc
    return parsed.astimezone(timezone.utc)


def parse_since(value: Optional[str], now: Optional[datetime] = None) -> Optional[str]:
    if value is None:
        return None
    value = value.strip()
    match = DURATION_RE.fullmatch(value)
    if match:
        amount = int(match.group(1))
        unit = match.group(2).lower()
        delta = {
            "s": timedelta(seconds=amount),
            "m": timedelta(minutes=amount),
            "h": timedelta(hours=amount),
            "d": timedelta(days=amount),
        }[unit]
        return utc_text((now or utc_now()) - delta)
    return utc_text(parse_utc(value))


def _clean_optional(value: Any, field: str) -> Optional[str]:
    if value is None:
        return None
    if not isinstance(value, str):
        raise EventValidationError("%s must be string or null" % field)
    value = value.strip()
    return value or None


def _canonical_event(event: Mapping[str, Any]) -> dict[str, Any]:
    missing = sorted(REQUIRED_KEYS - set(event))
    if missing:
        raise EventValidationError("missing event keys: %s" % ", ".join(missing))
    if event.get("schema_version") != SCHEMA_VERSION:
        raise EventValidationError("unsupported event schema_version")

    event_id = _clean_optional(event.get("event_id"), "event_id")
    if not event_id or len(event_id) > 160:
        raise EventValidationError("event_id must be non-empty and <=160 chars")
    event_type = _clean_optional(event.get("type"), "type")
    if event_type not in EVENT_TYPES:
        raise EventValidationError("unsupported event type: %r" % event_type)

    ts = utc_text(parse_utc(event.get("ts_utc")))
    session_id = _clean_optional(event.get("session_id"), "session_id")
    request_id = _clean_optional(event.get("request_id"), "request_id")
    customer = _clean_optional(event.get("customer"), "customer")
    destination = _clean_optional(event.get("destination"), "destination")
    state = _clean_optional(event.get("state"), "state")
    correlation_id = _clean_optional(event.get("correlation_id"), "correlation_id")
    severity = _clean_optional(event.get("severity"), "severity") or "info"

    amount = event.get("amount_copper")
    if not isinstance(amount, int) or isinstance(amount, bool) or amount < 0:
        raise EventValidationError("amount_copper must be a non-negative integer")

    metadata = event.get("metadata")
    if metadata is None:
        metadata = {}
    if not isinstance(metadata, dict):
        raise EventValidationError("metadata must be an object")

    if event_type in REQUEST_EVENT_TYPES and not request_id:
        raise EventValidationError("%s requires request_id" % event_type)
    if event_type in {"PaymentExpected", "PaymentReceived"} and amount <= 0:
        raise EventValidationError("%s requires amount_copper > 0" % event_type)

    return {
        "schema_version": SCHEMA_VERSION,
        "event_id": event_id,
        "ts_utc": ts,
        "type": event_type,
        "session_id": session_id,
        "request_id": request_id,
        "customer": customer,
        "destination": destination,
        "state": state,
        "amount_copper": amount,
        "correlation_id": correlation_id,
        "severity": severity,
        "metadata": metadata,
    }


def _payload_json(event: Mapping[str, Any]) -> str:
    return json.dumps(event, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _payload_hash(payload_json: str) -> str:
    return hashlib.sha256(payload_json.encode("utf-8")).hexdigest()


def _iter_sql_statements(script: str) -> Iterator[str]:
    current: list[str] = []
    for line in script.splitlines(True):
        current.append(line)
        candidate = "".join(current).strip()
        if candidate and sqlite3.complete_statement(candidate):
            yield candidate
            current = []
    trailing = "".join(current).strip()
    if trailing:
        if not sqlite3.complete_statement(trailing):
            raise LedgerError("incomplete SQL migration statement")
        yield trailing


class Ledger:
    def __init__(self, db_path: str | Path):
        self.db_path = Path(db_path)
        if str(db_path) != ":memory:":
            self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(str(db_path), timeout=10.0)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA foreign_keys=ON")
        self.conn.execute("PRAGMA busy_timeout=10000")
        self.conn.execute("PRAGMA synchronous=FULL")
        if str(db_path) != ":memory:":
            self.conn.execute("PRAGMA journal_mode=WAL")
        self._migrate()

    def close(self) -> None:
        self.conn.close()

    def __enter__(self) -> "Ledger":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    @contextmanager
    def _transaction(self) -> Iterator[None]:
        self.conn.execute("BEGIN IMMEDIATE")
        try:
            yield
        except Exception:
            self.conn.rollback()
            raise
        else:
            self.conn.commit()

    def _migrate(self) -> None:
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS schema_migrations ("
            "version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at_utc TEXT NOT NULL)"
        )
        self.conn.commit()
        migration_dir = Path(__file__).with_name("migrations")
        files = sorted(migration_dir.glob("*.sql"))
        if not files:
            raise LedgerError("no migrations found at %s" % migration_dir)
        applied = {
            int(row[0]) for row in self.conn.execute("SELECT version FROM schema_migrations")
        }
        for path in files:
            try:
                version = int(path.name.split("_", 1)[0])
            except (ValueError, IndexError) as exc:
                raise LedgerError("invalid migration filename: %s" % path.name) from exc
            if version in applied:
                continue
            script = path.read_text(encoding="utf-8")
            with self._transaction():
                for statement in _iter_sql_statements(script):
                    self.conn.execute(statement)
                self.conn.execute(
                    "INSERT INTO schema_migrations(version,name,applied_at_utc) VALUES(?,?,?)",
                    (version, path.name, utc_text(utc_now())),
                )
        current = self.schema_version()
        if current != DB_SCHEMA_VERSION:
            raise LedgerError("database schema_version=%d, expected=%d" % (current, DB_SCHEMA_VERSION))

    def schema_version(self) -> int:
        row = self.conn.execute("SELECT COALESCE(MAX(version),0) FROM schema_migrations").fetchone()
        return int(row[0])

    def ingest_event(self, event: Mapping[str, Any]) -> str:
        return self.ingest_many([event])[0]

    def ingest_many(self, events: Iterable[Mapping[str, Any]]) -> list[str]:
        canonical_events = [_canonical_event(event) for event in events]
        results: list[str] = []
        touched: set[str] = set()
        with self._transaction():
            for event in canonical_events:
                result = self._insert_event_locked(event)
                results.append(result)
                if result == "inserted" and event["request_id"]:
                    touched.add(event["request_id"])
            for request_id in sorted(touched):
                self._refresh_request_locked(request_id)
        return results

    def _insert_event_locked(self, event: Mapping[str, Any]) -> str:
        payload_json = _payload_json(event)
        payload_hash = _payload_hash(payload_json)
        existing = self.conn.execute(
            "SELECT payload_hash FROM events WHERE event_id=?", (event["event_id"],)
        ).fetchone()
        if existing:
            if existing["payload_hash"] == payload_hash:
                return "duplicate"
            raise EventConflictError("event_id replay has different payload: %s" % event["event_id"])

        request_id = event["request_id"]
        if request_id:
            self._protect_request_identity_locked(event)

        try:
            self.conn.execute(
                "INSERT INTO events("
                "event_id,schema_version,ts_utc,type,session_id,request_id,customer,destination,state,"
                "amount_copper,correlation_id,severity,metadata_json,payload_hash,ingested_at_utc"
                ") VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    event["event_id"],
                    event["schema_version"],
                    event["ts_utc"],
                    event["type"],
                    event["session_id"],
                    request_id,
                    event["customer"],
                    event["destination"],
                    event["state"],
                    event["amount_copper"],
                    event["correlation_id"],
                    event["severity"],
                    json.dumps(event["metadata"], ensure_ascii=False, sort_keys=True, separators=(",", ":")),
                    payload_hash,
                    utc_text(utc_now()),
                ),
            )
        except sqlite3.IntegrityError as exc:
            raise EventConflictError("event violates ledger identity constraint: %s" % exc) from exc
        return "inserted"

    def _protect_request_identity_locked(self, event: Mapping[str, Any]) -> None:
        request_id = event["request_id"]
        correlation_id = event["correlation_id"]
        if correlation_id:
            other = self.conn.execute(
                "SELECT request_id FROM requests WHERE correlation_id=? AND request_id<>?",
                (correlation_id, request_id),
            ).fetchone()
            if other:
                raise EventConflictError(
                    "correlation_id %s already belongs to request_id %s" % (correlation_id, other["request_id"])
                )

        row = self.conn.execute("SELECT * FROM requests WHERE request_id=?", (request_id,)).fetchone()
        now = utc_text(utc_now())
        if row is None:
            self.conn.execute(
                "INSERT INTO requests("
                "request_id,correlation_id,session_id,customer,destination,summon_state,payment_state,"
                "expected_copper,paid_copper,updated_at_utc"
                ") VALUES(?,?,?,?,?,'pending','pending',0,0,?)",
                (
                    request_id,
                    correlation_id,
                    event["session_id"],
                    event["customer"],
                    event["destination"],
                    now,
                ),
            )
            return

        def conflicts(field: str, *, casefold: bool = False) -> bool:
            old = row[field]
            new = event[field]
            if old is None or new is None:
                return False
            if casefold:
                return str(old).casefold() != str(new).casefold()
            return old != new

        for field, casefold in (
            ("correlation_id", False),
            ("customer", True),
            ("destination", True),
        ):
            if conflicts(field, casefold=casefold):
                raise EventConflictError(
                    "request_id %s identity conflict on %s: %r != %r"
                    % (request_id, field, row[field], event[field])
                )

        updates: list[str] = []
        values: list[Any] = []
        for field in ("correlation_id", "session_id", "customer", "destination"):
            if row[field] is None and event[field] is not None:
                updates.append(field + "=?")
                values.append(event[field])
        if updates:
            updates.append("updated_at_utc=?")
            values.append(now)
            values.append(request_id)
            self.conn.execute(
                "UPDATE requests SET %s WHERE request_id=?" % ",".join(updates), values
            )

    def _refresh_request_locked(self, request_id: str) -> None:
        events = self.conn.execute(
            "SELECT * FROM events WHERE request_id=? ORDER BY ts_utc,event_id", (request_id,)
        ).fetchall()
        if not events:
            return

        summon_state = "pending"
        started_at = completed_at = failed_at = None
        expected_copper = 0
        paid_copper = 0
        payment_state = "pending"
        last_payment_at = None
        payment_marker: Optional[tuple[str, str, str]] = None

        for row in events:
            event_type = row["type"]
            ts = row["ts_utc"]
            if event_type == "SummonStarted":
                started_at = started_at or ts
                summon_state = "started"
            elif event_type == "SummonCompleted":
                completed_at = completed_at or ts
                summon_state = "completed"
            elif event_type == "SummonFailed":
                failed_at = failed_at or ts
                summon_state = "failed"

            if event_type == "PaymentExpected":
                expected_copper = int(row["amount_copper"])
            elif event_type == "PaymentReceived":
                paid_copper += int(row["amount_copper"])
                last_payment_at = ts
                payment_marker = (ts, row["event_id"], "received")
            elif event_type == "PaymentMissing":
                payment_marker = (ts, row["event_id"], "missing")
            elif event_type == "TradeUncertain":
                payment_marker = (ts, row["event_id"], "uncertain")

        if payment_marker and payment_marker[2] == "uncertain":
            payment_state = "uncertain"
        elif expected_copper > 0:
            if paid_copper >= expected_copper:
                payment_state = "paid"
            elif paid_copper > 0 or (payment_marker and payment_marker[2] == "missing"):
                payment_state = "unpaid"
            else:
                payment_state = "pending"
        elif paid_copper > 0:
            payment_state = "paid"
        elif payment_marker and payment_marker[2] == "missing":
            payment_state = "unpaid"

        self.conn.execute(
            "UPDATE requests SET summon_state=?,payment_state=?,expected_copper=?,paid_copper=?,"
            "started_at_utc=?,completed_at_utc=?,failed_at_utc=?,last_payment_at_utc=?,last_event_at_utc=?,"
            "updated_at_utc=? WHERE request_id=?",
            (
                summon_state,
                payment_state,
                expected_copper,
                paid_copper,
                started_at,
                completed_at,
                failed_at,
                last_payment_at,
                events[-1]["ts_utc"],
                utc_text(utc_now()),
                request_id,
            ),
        )

    def request(self, request_id: str) -> Optional[dict[str, Any]]:
        row = self.conn.execute("SELECT * FROM requests WHERE request_id=?", (request_id,)).fetchone()
        if not row:
            return None
        events = self.conn.execute(
            "SELECT event_id,ts_utc,type,state,amount_copper,severity,metadata_json "
            "FROM events WHERE request_id=? ORDER BY ts_utc,event_id",
            (request_id,),
        ).fetchall()
        result = dict(row)
        result["events"] = [self._event_row(row) for row in events]
        return result

    @staticmethod
    def _event_row(row: sqlite3.Row) -> dict[str, Any]:
        result = dict(row)
        if "metadata_json" in result:
            result["metadata"] = json.loads(result.pop("metadata_json"))
        return result

    def find_player(self, name: str, since_utc: Optional[str] = None, limit: int = 100) -> dict[str, Any]:
        params: list[Any] = [name]
        where = "customer = ? COLLATE NOCASE"
        if since_utc:
            where += " AND last_event_at_utc >= ?"
            params.append(since_utc)
        params.append(limit)
        requests = [
            dict(row)
            for row in self.conn.execute(
                "SELECT * FROM requests WHERE %s ORDER BY last_event_at_utc DESC LIMIT ?" % where,
                params,
            )
        ]
        pay_params: list[Any] = [name]
        pay_where = "type='PaymentReceived' AND customer = ? COLLATE NOCASE"
        if since_utc:
            pay_where += " AND ts_utc >= ?"
            pay_params.append(since_utc)
        payments = [
            dict(row)
            for row in self.conn.execute(
                "SELECT event_id,ts_utc,request_id,correlation_id,session_id,destination,amount_copper "
                "FROM events WHERE %s ORDER BY ts_utc DESC" % pay_where,
                pay_params,
            )
        ]
        return {
            "customer": name,
            "since_utc": since_utc,
            "request_count": len(requests),
            "payment_count": len(payments),
            "paid_total_copper": sum(int(row["amount_copper"]) for row in payments),
            "requests": requests,
            "payments": payments,
        }

    def payments(
        self,
        since_utc: Optional[str] = None,
        player: Optional[str] = None,
        session_id: Optional[str] = None,
        limit: int = 1000,
    ) -> list[dict[str, Any]]:
        where = ["type='PaymentReceived'"]
        params: list[Any] = []
        if since_utc:
            where.append("ts_utc >= ?")
            params.append(since_utc)
        if player:
            where.append("customer = ? COLLATE NOCASE")
            params.append(player)
        if session_id:
            where.append("session_id = ?")
            params.append(session_id)
        params.append(limit)
        return [
            dict(row)
            for row in self.conn.execute(
                "SELECT event_id,ts_utc,session_id,request_id,customer,destination,amount_copper,correlation_id "
                "FROM events WHERE %s ORDER BY ts_utc DESC,event_id DESC LIMIT ?" % " AND ".join(where),
                params,
            )
        ]

    def revenue(
        self,
        *,
        since_utc: Optional[str] = None,
        until_utc: Optional[str] = None,
        session_id: Optional[str] = None,
    ) -> dict[str, Any]:
        where = ["type='PaymentReceived'"]
        params: list[Any] = []
        if since_utc:
            where.append("ts_utc >= ?")
            params.append(since_utc)
        if until_utc:
            where.append("ts_utc < ?")
            params.append(until_utc)
        if session_id:
            where.append("session_id = ?")
            params.append(session_id)
        row = self.conn.execute(
            "SELECT COUNT(*) AS payments,COALESCE(SUM(amount_copper),0) AS revenue_copper "
            "FROM events WHERE %s" % " AND ".join(where),
            params,
        ).fetchone()
        return {
            "since_utc": since_utc,
            "until_utc": until_utc,
            "session_id": session_id,
            "payments": int(row["payments"]),
            "revenue_copper": int(row["revenue_copper"]),
        }

    def revenue_today(self, now: Optional[datetime] = None) -> dict[str, Any]:
        current = (now or utc_now()).astimezone(timezone.utc)
        start = current.replace(hour=0, minute=0, second=0, microsecond=0)
        end = start + timedelta(days=1)
        return self.revenue(since_utc=utc_text(start), until_utc=utc_text(end))

    def _state_rows(self, payment_state: str, limit: int = 1000) -> list[dict[str, Any]]:
        return [
            dict(row)
            for row in self.conn.execute(
                "SELECT * FROM requests WHERE payment_state=? ORDER BY last_event_at_utc DESC LIMIT ?",
                (payment_state, limit),
            )
        ]

    def unpaid(self, limit: int = 1000) -> list[dict[str, Any]]:
        return self._state_rows("unpaid", limit)

    def uncertain(self, limit: int = 1000) -> list[dict[str, Any]]:
        return self._state_rows("uncertain", limit)

    def stats(self, now: Optional[datetime] = None) -> dict[str, Any]:
        current = (now or utc_now()).astimezone(timezone.utc)
        counters = self.conn.execute(
            "SELECT "
            "(SELECT COUNT(*) FROM events) AS event_count,"
            "(SELECT COUNT(*) FROM requests) AS request_count,"
            "(SELECT COUNT(*) FROM requests WHERE payment_state='paid') AS paid_requests,"
            "(SELECT COUNT(*) FROM requests WHERE payment_state='unpaid') AS unpaid_requests,"
            "(SELECT COUNT(*) FROM requests WHERE payment_state='uncertain') AS uncertain_requests,"
            "(SELECT COUNT(*) FROM requests WHERE summon_state='failed') AS failed_summons"
        ).fetchone()
        sessions = [
            dict(row)
            for row in self.conn.execute(
                "SELECT session_id,COUNT(*) AS payments,COALESCE(SUM(amount_copper),0) AS revenue_copper "
                "FROM events WHERE type='PaymentReceived' AND session_id IS NOT NULL "
                "GROUP BY session_id ORDER BY revenue_copper DESC,session_id LIMIT 100"
            )
        ]
        return {
            **{key: int(counters[key]) for key in counters.keys()},
            "schema_version": self.schema_version(),
            "revenue_today": self.revenue_today(current),
            "revenue_last_hour": self.revenue(since_utc=utc_text(current - timedelta(hours=1))),
            "revenue_by_session": sessions,
        }
