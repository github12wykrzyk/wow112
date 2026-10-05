#!/usr/bin/env python3
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PREFLIGHT = ROOT / ".github/workflows/parallel_feature_preflight.yml"
HEAVY = (
    ROOT / ".github/workflows/verify.yml",
    ROOT / ".github/workflows/ai_experiments.yml",
    ROOT / ".github/workflows/audit_native_abi.yml",
)
STABLE = ROOT / ".github/workflows/build_stable_candidate.yml"


class CanonicalTrunkContract(unittest.TestCase):
    def test_main_is_integration_base_and_parallel_is_exact_alias(self):
        text = PREFLIGHT.read_text(encoding="utf-8")
        self.assertIn("refs/heads/main:refs/remotes/origin/main", text)
        self.assertIn("--base origin/main", text)
        self.assertIn("--base refs/remotes/origin/main", text)
        self.assertIn("git checkout -f --detach $env:FEATURE_SHA", text)
        self.assertIn("git checkout -f -B __canonical_integrate refs/remotes/origin/main", text)
        self.assertIn(
            "git push --atomic origin HEAD:refs/heads/main HEAD:refs/heads/parallel",
            text,
        )
        self.assertIn("parallel delivery alias diverged from canonical main", text)

    def test_integration_uses_optimistic_atomic_cas_not_github_pending_slot(self):
        text = PREFLIGHT.read_text(encoding="utf-8")
        integrate = text.split("\n  integrate:\n", 1)[1]
        self.assertNotIn("group: canonical-main-integration-queue", integrate)
        self.assertIn("$maxAttempts = 6", integrate)
        self.assertIn("git push --atomic origin HEAD:refs/heads/main HEAD:refs/heads/parallel", integrate)
        self.assertIn("Canonical refs moved before atomic push", integrate)
        self.assertIn("Get-Random", integrate)
        self.assertIn("Start-Sleep -Milliseconds", integrate)

    def test_heavy_repository_audits_have_no_push_trigger(self):
        for path in HEAVY:
            with self.subTest(path=path.name):
                text = path.read_text(encoding="utf-8")
                on_block = text.split("on:\n", 1)[1].split("\npermissions:", 1)[0]
                self.assertNotIn("\n  push:", "\n" + on_block)
                self.assertIn("workflow_dispatch:", on_block)
                self.assertIn("schedule:", on_block)

    def test_stable_candidate_is_explicit_release_action_only(self):
        text = STABLE.read_text(encoding="utf-8")
        on_block = text.split("on:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("workflow_dispatch:", on_block)
        self.assertNotIn("push:", on_block)

    def test_successful_queue_cleanup_is_exact_sha_lease_safe(self):
        text = PREFLIGHT.read_text(encoding="utf-8")
        self.assertIn('$featureRef = "refs/heads/$env:FEATURE_BRANCH"', text)
        self.assertIn('$leaseArg = "--force-with-lease=${featureRef}:$env:FEATURE_SHA"', text)
        self.assertIn('git push $leaseArg origin ":$featureRef"', text)
        self.assertNotIn('git push origin --delete "$env:FEATURE_BRANCH"', text)
        self.assertLess(
            text.index("exact integrated delivery gates failed"),
            text.index('$featureRef = "refs/heads/$env:FEATURE_BRANCH"'),
        )


if __name__ == "__main__":
    unittest.main()
