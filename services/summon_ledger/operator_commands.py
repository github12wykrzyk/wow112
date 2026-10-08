from __future__ import annotations

import hashlib
import json
import sqlite3
import uuid
from pathlib import Path
from typing import Any, Mapping, Optional

from .ledger import utc_now, utc_text

COMMAND_SCHEMA_VERSION = 1
COMMAND_TYPES = {"Pause", "Resume", "ManualWhisper"}


class CommandError(RuntimeError):
    pass


class CommandValidationError(CommandError):
    pass


class CommandConflictError(CommandError):
    pass


def _clean_optional(value: Any, field: str) -> Optional[str]:
    if value is None:
        return None
    if not isinstance(value, str):
        raise CommandValidationError(f"{field} must be string or null")
    value = value.strip()
    return value or None


def _canonical_command(command: Mapping[str, Any]) -> dict[str, Any]:
    command_type = _clean_optional(command.get("type"), "type")
    if command_type not in COMMAND_TYPES:
        raise CommandValidationError(f"unsupported command type: {command_type!r}")

    command_id = _clean_optional(command.get("command_id"), "command_id") or str(uuid.uuid4())
    if len(command_id) > 160:
        raise CommandValidationError("command_id must be <=160 chars")

    customer = _clean_optional(command.get("customer"), "customer")
    message = _clean_optional(command.get("message"), "message")
    correlation_id = _clean_optional(command.get("correlation_id"), "correlation_id")
    metadata = command.get("metadata") or {}
    if not isinstance(metadata, dict):
        raise CommandValidationError("metadata must be an object")

    if command_type == "ManualWhisper":
        if not customer:
            raise CommandValidationError("ManualWhisper requires customer")
        if not message:
            raise CommandValidationError("ManualWhisper requires message")
        if len(message) > 255:
            raise CommandValidationError("ManualWhisper message must be <=255 chars")
    elif customer is not None or message is not None:
        raise CommandValidationError(f"{command_type} does not accept customer/message")

    return {
        "schema_version": COMMAND_SCHEMA_VERSION,
        "command_id": command_id,
        "ts_utc": _clean_optional(command.get("ts_utc"), "ts_utc") or utc_text(utc_now()),
        "type": command_type,
        "customer": customer,
        "message": message,
        "correlation_id": correlation_id,
        "metadata": metadata,
    }


def _payload_json(value: Mapping[str, Any]) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _payload_hash(value: Mapping[str, Any]) -> str:
    return hashlib.sha256(_payload_json(value).encode("utf-8")).hexdigest()


class OperatorCommandQueue:
    """Durable command-intent queue. It never performs game/network mutations itself."""

    def __init__(self, db_path: str | Path):
        self.db_path = Path(db_path)
        self.conn = sqlite3.connect(str(db_path), timeout=10.0)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA busy_timeout=10000")
        if str(db_path) != ":memory:":
            self.conn.execute("PRAGMA journal_mode=WAL")
        self._ensure_schema()

    def close(self) -> None:
        self.conn.close()

    def __enter__(self) -> "OperatorCommandQueue":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def _ensure_schema(self) -> None:
        self.conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS operator_commands (
                command_id TEXT PRIMARY KEY,
                schema_version INTEGER NOT NULL,
                ts_utc TEXT NOT NULL,
                type TEXT NOT NULL CHECK(type IN ('Pause','Resume','ManualWhisper')),
                customer TEXT,
                message TEXT,
                correlation_id TEXT,
                metadata_json TEXT NOT NULL,
                payload_hash TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','consumed')),
                consumed_at_utc TEXT,
                created_at_utc TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_operator_commands_status_time
                ON operator_commands(status, ts_utc, command_id);
            CREATE INDEX IF NOT EXISTS idx_operator_commands_correlation
                ON operator_commands(correlation_id);
            """
        )
        self.conn.commit()

    def enqueue(self, command: Mapping[str, Any]) -> tuple[str, dict[str, Any]]:
        canonical = _canonical_command(command)
        payload_hash = _payload_hash(canonical)
        existing = self.conn.execute(
            "SELECT payload_hash FROM operator_commands WHERE command_id=?",
            (canonical["command_id"],),
        ).fetchone()
        if existing:
            if existing["payload_hash"] == payload_hash:
                return "duplicate", canonical
            raise CommandConflictError(
                f"command_id replay has different payload: {canonical['command_id']}"
            )

        self.conn.execute(
            "INSERT INTO operator_commands(command_id,schema_version,ts_utc,type,customer,message,"
            "correlation_id,metadata_json,payload_hash,status,created_at_utc) "
            "VALUES(?,?,?,?,?,?,?,?,?,'pending',?)",
            (
                canonical["command_id"],
                canonical["schema_version"],
                canonical["ts_utc"],
                canonical["type"],
                canonical["customer"],
                canonical["message"],
                canonical["correlation_id"],
                json.dumps(canonical["metadata"], ensure_ascii=False, sort_keys=True, separators=(",", ":")),
                payload_hash,
                utc_text(utc_now()),
            ),
        )
        self.conn.commit()
        return "inserted", canonical

    def pending(self, limit: int = 100) -> list[dict[str, Any]]:
        rows = self.conn.execute(
            "SELECT * FROM operator_commands WHERE status='pending' ORDER BY ts_utc,command_id LIMIT ?",
            (max(1, min(limit, 10000)),),
        ).fetchall()
        return [self._row(row) for row in rows]

    def mark_consumed(self, command_id: str) -> bool:
        cursor = self.conn.execute(
            "UPDATE operator_commands SET status='consumed', consumed_at_utc=? "
            "WHERE command_id=? AND status='pending'",
            (utc_text(utc_now()), command_id),
        )
        self.conn.commit()
        return cursor.rowcount == 1

    @staticmethod
    def _row(row: sqlite3.Row) -> dict[str, Any]:
        value = dict(row)
        value["metadata"] = json.loads(value.pop("metadata_json"))
        value.pop("payload_hash", None)
        return value
