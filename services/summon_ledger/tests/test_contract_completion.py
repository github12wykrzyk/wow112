from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from services.summon_ledger.cli import main as cli_main
from services.summon_ledger.cloud_export import export_bundle
from services.summon_ledger.ledger import Ledger, utc_now, utc_text
from services.summon_ledger.operator_commands import (
    CommandConflictError,
    CommandValidationError,
    OperatorCommandQueue,
)


def event(event_id: str, event_type: str, *, request_id: str = "r1", amount: int = 0):
    return {
        "schema_version": 1,
        "event_id": event_id,
        "ts_utc": utc_text(utc_now()),
        "type": event_type,
        "session_id": "s1",
        "request_id": request_id,
        "customer": "Feltaxi",
        "destination": "Winterspring",
        "state": event_type,
        "amount_copper": amount,
        "correlation_id": "corr-" + request_id,
        "severity": "info",
        "metadata": {},
    }


class OperatorCommandContractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "ledger.sqlite3"
        with Ledger(self.db):
            pass

    def tearDown(self):
        self.tmp.cleanup()

    def test_pause_resume_and_manual_whisper_are_durable_intents(self):
        with OperatorCommandQueue(self.db) as queue:
            for command in (
                {"command_id": "pause-1", "type": "Pause"},
                {"command_id": "resume-1", "type": "Resume"},
                {
                    "command_id": "whisper-1",
                    "type": "ManualWhisper",
                    "customer": "Feltaxi",
                    "message": "summon ready",
                    "correlation_id": "corr-r1",
                },
            ):
                status, _ = queue.enqueue(command)
                self.assertEqual(status, "inserted")
            pending = queue.pending()
            self.assertEqual([x["type"] for x in pending], ["Pause", "Resume", "ManualWhisper"])

        with OperatorCommandQueue(self.db) as reopened:
            pending = reopened.pending()
            self.assertEqual(len(pending), 3)
            self.assertTrue(reopened.mark_consumed("pause-1"))
            self.assertFalse(reopened.mark_consumed("pause-1"))

    def test_command_id_replay_is_idempotent_and_conflicts_on_changed_payload(self):
        command = {"command_id": "c1", "type": "Pause"}
        with OperatorCommandQueue(self.db) as queue:
            self.assertEqual(queue.enqueue(command)[0], "inserted")
            self.assertEqual(queue.enqueue(command)[0], "duplicate")
            with self.assertRaises(CommandConflictError):
                queue.enqueue({"command_id": "c1", "type": "Resume"})

    def test_manual_whisper_validation_and_no_arbitrary_payload_surface(self):
        with OperatorCommandQueue(self.db) as queue:
            with self.assertRaises(CommandValidationError):
                queue.enqueue({"type": "ManualWhisper", "customer": "Feltaxi"})
            with self.assertRaises(CommandValidationError):
                queue.enqueue({"type": "ArbitraryPacket", "message": "x"})
            with self.assertRaises(CommandValidationError):
                queue.enqueue({"type": "Pause", "customer": "Feltaxi"})

    def test_cli_exposes_exact_three_operator_commands(self):
        self.assertEqual(cli_main(["--db", str(self.db), "operator-command", "Pause", "--command-id", "p1"]), 0)
        self.assertEqual(cli_main(["--db", str(self.db), "operator-command", "Resume", "--command-id", "r1"]), 0)
        self.assertEqual(
            cli_main([
                "--db", str(self.db), "operator-command", "ManualWhisper",
                "--command-id", "w1", "--customer", "Feltaxi", "--message", "ready"
            ]),
            0,
        )


class CloudExportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.db = self.root / "ledger.sqlite3"
        with Ledger(self.db) as ledger:
            ledger.ingest_many([
                event("queued", "RequestQueued"),
                event("started", "SummonStarted"),
                event("expected", "PaymentExpected", amount=40000),
                event("done", "SummonCompleted"),
                event("paid", "PaymentReceived", amount=40000),
            ])
        with OperatorCommandQueue(self.db) as queue:
            queue.enqueue({"command_id": "p1", "type": "Pause"})

    def tearDown(self):
        self.tmp.cleanup()

    def test_export_bundle_has_manifest_counts_cursor_and_valid_sha256(self):
        out = self.root / "export"
        manifest = export_bundle(self.db, out)
        self.assertEqual(manifest["export_schema_version"], 1)
        self.assertEqual(manifest["ledger_db_schema_version"], 2)
        self.assertEqual(manifest["counts"]["events"], 5)
        self.assertEqual(manifest["counts"]["requests"], 1)
        self.assertEqual(manifest["counts"]["operator_commands"], 1)

        exported_events = [
            json.loads(line)
            for line in (out / "events.jsonl").read_text(encoding="utf-8").splitlines()
            if line
        ]
        last_event = exported_events[-1]
        self.assertEqual(
            manifest["cursor"],
            {"ts_utc": last_event["ts_utc"], "event_id": last_event["event_id"]},
        )

        disk_manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
        for name, meta in disk_manifest["files"].items():
            digest = hashlib.sha256((out / name).read_bytes()).hexdigest()
            self.assertEqual(meta["sha256"], digest)

    def test_export_is_jsonl_cloud_neutral_and_contains_no_secret_config(self):
        out = self.root / "export"
        export_bundle(self.db, out)
        for name in ("events.jsonl", "requests.jsonl", "operator_commands.jsonl"):
            for line in (out / name).read_text(encoding="utf-8").splitlines():
                self.assertIsInstance(json.loads(line), dict)
        text = "\n".join(path.read_text(encoding="utf-8") for path in out.iterdir())
        self.assertNotIn("password", text.casefold())
        self.assertNotIn("token", text.casefold())

    def test_cli_cloud_export(self):
        out = self.root / "cli-export"
        self.assertEqual(cli_main(["--db", str(self.db), "cloud-export", str(out)]), 0)
        self.assertTrue((out / "manifest.json").exists())


if __name__ == "__main__":
    unittest.main()
