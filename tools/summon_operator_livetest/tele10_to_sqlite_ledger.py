from __future__ import annotations

import argparse
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from services.summon_ledger.ledger import Ledger


def utc_from_unix(value: int, micros: int = 0) -> str:
    dt = datetime.fromtimestamp(int(value), tz=timezone.utc) + timedelta(microseconds=micros)
    return dt.isoformat(timespec="microseconds").replace("+00:00", "Z")


def event(
    *,
    event_id: str,
    ts: str,
    event_type: str,
    session_id: str,
    request_id: str,
    customer: str,
    destination: str,
    state: str,
    amount_copper: int,
    correlation_id: str,
    severity: str = "info",
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "event_id": event_id,
        "ts_utc": ts,
        "type": event_type,
        "session_id": session_id,
        "request_id": request_id,
        "customer": customer,
        "destination": destination,
        "state": state,
        "amount_copper": int(amount_copper),
        "correlation_id": correlation_id,
        "severity": severity,
        "metadata": metadata or {},
    }


def convert_summon(record: dict[str, Any], session_id: str) -> list[dict[str, Any]]:
    summon_id = str(record["summon_id"])
    customer = str(record["client_name"])
    destination = str(record.get("destination") or "")
    created = int(record["timestamp_created"])
    expected = int(record.get("expected_price_copper") or 0)
    common = {
        "source": "tele10_payment_ledger",
        "legacy_summon_id": summon_id,
        "client_guid": int(record.get("client_guid") or 0),
        "summoner_name": record.get("summoner_name"),
        "trigger_message": record.get("trigger_message"),
        "settlement_id": record.get("settlement_id"),
    }
    out = [
        event(
            event_id=f"tele10:{summon_id}:queued",
            ts=utc_from_unix(created, 0),
            event_type="RequestQueued",
            session_id=session_id,
            request_id=summon_id,
            customer=customer,
            destination=destination,
            state="queued",
            amount_copper=0,
            correlation_id=summon_id,
            metadata={**common, "timestamp_source": "legacy_timestamp_created"},
        ),
        event(
            event_id=f"tele10:{summon_id}:started",
            ts=utc_from_unix(created, 1),
            event_type="SummonStarted",
            session_id=session_id,
            request_id=summon_id,
            customer=customer,
            destination=destination,
            state="started",
            amount_copper=0,
            correlation_id=summon_id,
            metadata={**common, "timestamp_source": "legacy_timestamp_created"},
        ),
    ]
    if expected > 0:
        out.append(
            event(
                event_id=f"tele10:{summon_id}:payment_expected",
                ts=utc_from_unix(created, 2),
                event_type="PaymentExpected",
                session_id=session_id,
                request_id=summon_id,
                customer=customer,
                destination=destination,
                state="expected",
                amount_copper=expected,
                correlation_id=summon_id,
                metadata=common,
            )
        )

    summon_status = str(record.get("summon_status") or "").lower()
    if summon_status == "summoned":
        out.append(
            event(
                event_id=f"tele10:{summon_id}:completed",
                ts=utc_from_unix(created, 3),
                event_type="SummonCompleted",
                session_id=session_id,
                request_id=summon_id,
                customer=customer,
                destination=destination,
                state="completed",
                amount_copper=0,
                correlation_id=summon_id,
                metadata={**common, "timestamp_source": "ordered_from_legacy_created"},
            )
        )
    elif summon_status in {"failed", "cancelled"}:
        out.append(
            event(
                event_id=f"tele10:{summon_id}:failed",
                ts=utc_from_unix(int(record.get("last_update") or created), 0),
                event_type="SummonFailed",
                session_id=session_id,
                request_id=summon_id,
                customer=customer,
                destination=destination,
                state=summon_status,
                amount_copper=0,
                correlation_id=summon_id,
                severity="error",
                metadata={**common, "failure_reason": record.get("failure_reason")},
            )
        )

    payment_status = str(record.get("payment_status") or "unpaid").lower()
    paid_amount = int(record.get("amount_paid_copper") or 0)
    payment_ts = int(record.get("payment_timestamp") or record.get("last_update") or created)
    payment_event_id = str(record.get("payment_event_id") or f"{summon_id}:payment")
    payment_meta = {
        **common,
        "legacy_payment_event_id": record.get("payment_event_id"),
        "trade_partner": record.get("trade_partner"),
        "failure_reason": record.get("failure_reason"),
    }
    if payment_status in {"paid", "overpaid"} and paid_amount > 0:
        out.append(
            event(
                event_id=f"tele10:{payment_event_id}:received",
                ts=utc_from_unix(payment_ts, 0),
                event_type="PaymentReceived",
                session_id=session_id,
                request_id=summon_id,
                customer=customer,
                destination=destination,
                state=payment_status,
                amount_copper=paid_amount,
                correlation_id=summon_id,
                metadata=payment_meta,
            )
        )
    elif payment_status == "uncertain":
        out.append(
            event(
                event_id=f"tele10:{payment_event_id}:uncertain",
                ts=utc_from_unix(payment_ts, 0),
                event_type="TradeUncertain",
                session_id=session_id,
                request_id=summon_id,
                customer=customer,
                destination=destination,
                state="uncertain",
                amount_copper=paid_amount,
                correlation_id=summon_id,
                severity="error",
                metadata=payment_meta,
            )
        )
    else:
        out.append(
            event(
                event_id=f"tele10:{summon_id}:payment_missing",
                ts=utc_from_unix(int(record.get("last_update") or created), 0),
                event_type="PaymentMissing",
                session_id=session_id,
                request_id=summon_id,
                customer=customer,
                destination=destination,
                state=payment_status,
                amount_copper=0,
                correlation_id=summon_id,
                severity="warning",
                metadata=payment_meta,
            )
        )
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--legacy", required=True)
    parser.add_argument("--db", required=True)
    parser.add_argument("--events", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--summary", required=True)
    args = parser.parse_args()

    legacy_path = Path(args.legacy)
    raw = json.loads(legacy_path.read_text(encoding="utf-8-sig"))
    summons = raw.get("summons") or []
    if not isinstance(summons, list):
        raise SystemExit("legacy ledger summons must be a list")

    events: list[dict[str, Any]] = []
    for record in summons:
        if isinstance(record, dict):
            events.extend(convert_summon(record, args.session))

    events_path = Path(args.events)
    events_path.parent.mkdir(parents=True, exist_ok=True)
    with events_path.open("w", encoding="utf-8") as handle:
        for item in events:
            handle.write(json.dumps(item, ensure_ascii=False, sort_keys=True) + "\n")

    with Ledger(Path(args.db)) as ledger:
        results = ledger.ingest_many(events)
        stats = ledger.stats()

    summary = {
        "schema_version": 1,
        "source": str(legacy_path),
        "session_id": args.session,
        "events": len(events),
        "inserted": results.count("inserted"),
        "duplicates": results.count("duplicate"),
        "stats": stats,
    }
    Path(args.summary).write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
