from __future__ import annotations

import hashlib
import json
import sqlite3
from pathlib import Path
from typing import Any, Iterable

from .ledger import utc_now, utc_text
from .operator_commands import OperatorCommandQueue

EXPORT_SCHEMA_VERSION = 1


def _json_line(value: dict[str, Any]) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> int:
    count = 0
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(_json_line(row))
            count += 1
    return count


def export_bundle(db_path: str | Path, output_dir: str | Path) -> dict[str, Any]:
    """Create a cloud-neutral, checksummed export bundle. No upload or secret handling occurs here."""
    db_path = Path(db_path)
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Ensure command sidecar schema exists before export.
    with OperatorCommandQueue(db_path):
        pass

    conn = sqlite3.connect(str(db_path), timeout=10.0)
    conn.row_factory = sqlite3.Row
    try:
        events_path = output_dir / "events.jsonl"
        requests_path = output_dir / "requests.jsonl"
        commands_path = output_dir / "operator_commands.jsonl"

        event_rows = []
        for row in conn.execute("SELECT * FROM events ORDER BY ts_utc,event_id"):
            value = dict(row)
            value["metadata"] = json.loads(value.pop("metadata_json"))
            event_rows.append(value)

        request_rows = [dict(row) for row in conn.execute("SELECT * FROM requests ORDER BY request_id")]

        command_rows = []
        for row in conn.execute("SELECT * FROM operator_commands ORDER BY ts_utc,command_id"):
            value = dict(row)
            value["metadata"] = json.loads(value.pop("metadata_json"))
            value.pop("payload_hash", None)
            command_rows.append(value)

        counts = {
            "events": _write_jsonl(events_path, event_rows),
            "requests": _write_jsonl(requests_path, request_rows),
            "operator_commands": _write_jsonl(commands_path, command_rows),
        }

        cursor_row = conn.execute(
            "SELECT ts_utc,event_id FROM events ORDER BY ts_utc DESC,event_id DESC LIMIT 1"
        ).fetchone()
        cursor = None if cursor_row is None else {
            "ts_utc": cursor_row["ts_utc"],
            "event_id": cursor_row["event_id"],
        }

        schema_row = conn.execute("SELECT COALESCE(MAX(version),0) AS version FROM schema_migrations").fetchone()
        manifest = {
            "export_schema_version": EXPORT_SCHEMA_VERSION,
            "ledger_db_schema_version": int(schema_row["version"]),
            "command_schema_version": 1,
            "exported_at_utc": utc_text(utc_now()),
            "source_db_name": db_path.name,
            "cursor": cursor,
            "counts": counts,
            "files": {
                "events.jsonl": {"sha256": _sha256(events_path)},
                "requests.jsonl": {"sha256": _sha256(requests_path)},
                "operator_commands.jsonl": {"sha256": _sha256(commands_path)},
            },
        }
        manifest_path = output_dir / "manifest.json"
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        return manifest
    finally:
        conn.close()
