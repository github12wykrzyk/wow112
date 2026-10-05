#!/usr/bin/env python3
"""Protect the single-owner delivery contract for queued integration.

Queued integration intentionally pushes the integration ref with the repository
GITHUB_TOKEN credentials persisted by actions/checkout. GitHub suppresses new
push-triggered workflow runs caused by GITHUB_TOKEN, so exact downstream
delivery is owned by parallel_ci_dispatch.py via workflow_dispatch.

Direct/manual pushes may still use the build workflows' push triggers as a
recovery path; they are not part of the queued integration path.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PREFLIGHT = ROOT / ".github/workflows/parallel_feature_preflight.yml"
DISPATCHER = ROOT / "tools/parallel_ci_dispatch.py"
DELIVERY_WORKFLOWS = (
    ROOT / ".github/workflows/build_work_candidate.yml",
    ROOT / ".github/workflows/build_parallel_economy.yml",
    ROOT / ".github/workflows/build_updater.yml",
    ROOT / ".github/workflows/build_autologinbridge.yml",
)


class DeliverySingleOwnerContract(unittest.TestCase):
    def test_queue_push_uses_checkout_github_token_credentials(self):
        text = PREFLIGHT.read_text(encoding="utf-8")
        checkout_marker = "- name: Checkout exact preflighted feature revision (full merge history)"
        integrate_marker = "- name: Revalidate, integrate and verify exact parallel delivery"
        self.assertIn(checkout_marker, text)
        self.assertIn(integrate_marker, text)
        checkout = text.split(checkout_marker, 1)[1].split(integrate_marker, 1)[0]
        self.assertIn("uses: actions/checkout@v5", checkout)
        # actions/checkout defaults to github.token and persist-credentials=true.
        # A custom token or disabled persisted credentials would invalidate the
        # GitHub recursion-suppression assumption used by this architecture.
        self.assertNotIn("token:", checkout)
        self.assertNotIn("persist-credentials: false", checkout)

    def test_post_merge_delivery_is_explicit_exact_sha_dispatch(self):
        text = PREFLIGHT.read_text(encoding="utf-8")
        integrate = text.split(
            "- name: Revalidate, integrate and verify exact parallel delivery", 1
        )[1]
        self.assertIn("GH_TOKEN: ${{ github.token }}", integrate)
        push = "git push origin HEAD:refs/heads/parallel"
        dispatch = "python tools/parallel_ci_dispatch.py"
        self.assertIn(push, integrate)
        self.assertIn(dispatch, integrate)
        self.assertLess(integrate.index(push), integrate.index(dispatch))
        self.assertIn('--sha "$integrated"', integrate)

    def test_dispatcher_materializes_only_workflow_dispatch_runs(self):
        text = DISPATCHER.read_text(encoding="utf-8")
        self.assertIn('"event": "workflow_dispatch"', text)
        self.assertIn('/dispatches', text)
        self.assertIn('candidate.get("head_sha") == sha', text)
        self.assertIn('candidate.get("head_branch") == ref', text)
        self.assertNotIn('"event": "push"', text)

    def test_all_delivery_profiles_remain_manually_dispatchable(self):
        for path in DELIVERY_WORKFLOWS:
            with self.subTest(path=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertIn("workflow_dispatch:", text)


if __name__ == "__main__":
    unittest.main()
