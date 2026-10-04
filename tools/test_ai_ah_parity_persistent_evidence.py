#!/usr/bin/env python3
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHADOW = ROOT / "src" / "AddOns" / "AuxEconomyShadow"
TASK = ROOT / "runtime" / "parallel_tasks" / "ah-parity-persistent-evidence-v1.json"


class AHParityPersistentEvidenceTests(unittest.TestCase):
    def test_exporter_persists_compatible_cumulative_evidence(self):
        text = (SHADOW / "AuxEconomyShadow_ParityExport.lua").read_text(encoding="utf-8")
        for token in (
            'REVISION = "5-persistent-evidence"',
            'EVIDENCE_SCHEMA = 1',
            'MIGRATE_REVISION = "4-cutover-decision-feed"',
            'shadowParityEvidence',
            'compatibilityKey',
            'migratedFromRevision',
            'counterDelta',
            'currentDecisionCompared',
            'currentScans',
            'evidenceMismatches',
            'evidenceReady',
            'function api.EvidenceSummary()',
        ):
            self.assertIn(token, text)

    def test_counter_reset_is_treated_as_new_runtime_epoch(self):
        text = (SHADOW / "AuxEconomyShadow_ParityExport.lua").read_text(encoding="utf-8")
        self.assertIn('if current >= previous then return current - previous end', text)
        self.assertIn('return current', text)
        self.assertIn('state.lastSeen = zeroSeen()', text)
        self.assertIn('state.lastSeen = snapshotCurrent(summary, status)', text)

    def test_legacy_marketmeta_is_migrated_once_without_double_count(self):
        text = (SHADOW / "AuxEconomyShadow_ParityExport.lua").read_text(encoding="utf-8")
        self.assertIn('local old = AVM_DB.marketMeta.shadowParity', text)
        self.assertIn('local migrated = migrateLegacy(evidence, old, status)', text)
        self.assertIn('if migrated then', text)
        self.assertIn('state.lastSeen = snapshotCurrent(summary, status)', text)

    def test_cutover_safety_remains_current_generation_only(self):
        cutover = (SHADOW / "AuxEconomyShadow_Cutover.lua").read_text(encoding="utf-8")
        self.assertIn('positive-match-required', cutover)
        self.assertIn('state.generationArmed = false', cutover)
        self.assertIn('tonumber(match.generation) ~= (tonumber(R.hotPayloadGeneration) or 0)', cutover)
        self.assertNotIn('EvidenceSummary', cutover)

    def test_exporter_does_not_take_transaction_or_scan_ownership(self):
        text = (SHADOW / "AuxEconomyShadow_ParityExport.lua").read_text(encoding="utf-8")
        for forbidden in (
            'PlaceAuctionBid',
            'QueryAuctionItems(',
            'CancelAuction(',
            'StartAuction(',
            'AVM_AuxArbScanDone =',
            'AVM_AuxArbPageDone =',
        ):
            self.assertNotIn(forbidden, text)

    def test_task_is_isolated_and_economy_gated(self):
        task = json.loads(TASK.read_text(encoding="utf-8"))
        self.assertEqual(task["branch"], "feature/ah-parity-persistent-evidence-v1")
        self.assertEqual(task["base_parallel_sha"], "a79572f56f6cd99d2606fce7bb12c081831719d4")
        self.assertIn(task["status"], ("coding", "preflight", "ready_for_integration", "integrating", "integrated", "parallel_ci", "test_ready"))
        self.assertEqual(task["delivery_profiles"], ["economy"])
        self.assertIn("AuxEconomyShadow", task["modules"])
        self.assertIn("parity-evidence", task["shared_resources"])
        if task["lease"] is not None:
            self.assertIn("resource:parity-evidence", task["lease"]["scopes"])


if __name__ == "__main__":
    unittest.main()
