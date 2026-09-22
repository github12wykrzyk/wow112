#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("guardian", Path(__file__).with_name("guardian.py"))
guardian = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guardian)

class GuardTests(unittest.TestCase):
    def test_single_unique_replacement(self):
        self.assertEqual(guardian.bounded_patch("int x=1;\n", "x=1", "x=2"), "int x=2;\n")

    def test_duplicate_anchor_rejected(self):
        with self.assertRaises(ValueError):
            guardian.bounded_patch("abc abc", "abc", "def")

    def test_absolute_address_rejected(self):
        with self.assertRaises(ValueError):
            guardian.bounded_patch("int x=0x123456;\n", "0x123456", "0x123457")

    def test_many_lines_rejected(self):
        old = "".join("int a%d=0;\n" % i for i in range(45))
        new = "".join("int a%d=1;\n" % i for i in range(45))
        with self.assertRaises(ValueError):
            guardian.bounded_patch(old, old, new)

    def test_blank_rejected(self):
        with self.assertRaises(ValueError):
            guardian.bounded_patch("foo", "", "bar")


class OptimizationReviewTests(unittest.TestCase):
    def test_review_runs_on_successful_ci_without_committing(self):
        row = {"branch": "parallel", "head": "a" * 40,
               "sources": ["src/Example/example.c"], "failures": [],
               "findings": []}
        prompts = []
        def answer(request):
            prompts.append(request["messages"][0]["content"])
            return {"old": "", "new": "", "reason": "No proven speedup",
                    "measurement": ""}
        def fake_api(method, endpoint, body=None):
            self.assertEqual(method, "GET")
            if endpoint.startswith("pulls?"):
                return []
            if endpoint.startswith("commits/"):
                return {"commit": {"tree": {"sha": "b" * 40}}}
            raise AssertionError(endpoint)
        with patch.object(guardian, "api", side_effect=fake_api), \
             patch.object(guardian, "read_file", return_value="int x = 1;"):
            result = guardian.repair([row], model_call=answer, optimize=True)
        self.assertEqual(result["state"], "reviewed")
        self.assertEqual(result["source"], "src/Example/example.c")
        self.assertIn("PERFORMANCE OPTIMIZATION", prompts[0])

    def test_oversized_module_never_sent_to_model(self):
        row = {"branch": "work", "head": "a" * 40,
               "sources": ["src/Large/large.c"], "failures": [], "findings": []}
        def fake_api(method, endpoint, body=None):
            if endpoint.startswith("pulls?"):
                return []
            if endpoint.startswith("commits/"):
                return {"commit": {"tree": {"sha": "b" * 40}}}
            raise AssertionError(endpoint)
        with patch.object(guardian, "api", side_effect=fake_api), \
             patch.object(guardian, "read_file", return_value="x" * 12001), \
             patch.object(guardian, "bounded_patch") as patched:
            result = guardian.repair([row], model_call=lambda _: self.fail(
                "oversized code must not be sent to model"), optimize=True)
        self.assertEqual(result["state"], "skipped")
        patched.assert_not_called()


if __name__ == "__main__":
    unittest.main()
