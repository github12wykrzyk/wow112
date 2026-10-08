from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any, Iterable

from .ledger import EventConflictError, EventValidationError, Ledger, parse_since


def emit(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))


def read_events(path: str) -> Iterable[dict[str, Any]]:
    handle = sys.stdin if path == "-" else open(path, "r", encoding="utf-8")
    try:
        for line_no, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as exc:
                raise EventValidationError("invalid JSONL at line %d: %s" % (line_no, exc)) from exc
            if not isinstance(value, dict):
                raise EventValidationError("JSONL line %d must be an object" % line_no)
            yield value
    finally:
        if handle is not sys.stdin:
            handle.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="summon-ledger", description="Persistent Summon Service V1 ledger")
    parser.add_argument(
        "--db",
        default=os.environ.get("SUMMON_LEDGER_DB", "summon_ledger.sqlite3"),
        help="SQLite path (default: SUMMON_LEDGER_DB or ./summon_ledger.sqlite3)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    ingest = sub.add_parser("ingest", help="ingest structured events from JSONL")
    ingest.add_argument("path", help="JSONL path or - for stdin")

    find = sub.add_parser("find-player")
    find.add_argument("name")
    find.add_argument("--since", help="UTC ISO-8601 or duration such as 1h, 30m, 2d")
    find.add_argument("--limit", type=int, default=100)

    request = sub.add_parser("request")
    request.add_argument("request_id")

    payments = sub.add_parser("payments")
    payments.add_argument("--since", help="UTC ISO-8601 or duration such as 1h")
    payments.add_argument("--player")
    payments.add_argument("--session")
    payments.add_argument("--limit", type=int, default=1000)

    revenue = sub.add_parser("revenue")
    mode = revenue.add_mutually_exclusive_group(required=True)
    mode.add_argument("--today", action="store_true")
    mode.add_argument("--since")
    mode.add_argument("--session")

    unpaid = sub.add_parser("unpaid")
    unpaid.add_argument("--limit", type=int, default=1000)

    uncertain = sub.add_parser("uncertain")
    uncertain.add_argument("--limit", type=int, default=1000)

    sub.add_parser("stats")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        with Ledger(Path(args.db)) as ledger:
            if args.command == "ingest":
                results = ledger.ingest_many(read_events(args.path))
                emit({"inserted": results.count("inserted"), "duplicates": results.count("duplicate")})
            elif args.command == "find-player":
                emit(ledger.find_player(args.name, parse_since(args.since), args.limit))
            elif args.command == "request":
                value = ledger.request(args.request_id)
                if value is None:
                    emit({"found": False, "request_id": args.request_id})
                    return 2
                emit(value)
            elif args.command == "payments":
                emit(ledger.payments(parse_since(args.since), args.player, args.session, args.limit))
            elif args.command == "revenue":
                if args.today:
                    emit(ledger.revenue_today())
                elif args.since:
                    emit(ledger.revenue(since_utc=parse_since(args.since)))
                else:
                    emit(ledger.revenue(session_id=args.session))
            elif args.command == "unpaid":
                emit(ledger.unpaid(args.limit))
            elif args.command == "uncertain":
                emit(ledger.uncertain(args.limit))
            elif args.command == "stats":
                emit(ledger.stats())
            else:
                raise AssertionError(args.command)
    except (EventValidationError, EventConflictError) as exc:
        print("summon-ledger: %s" % exc, file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
