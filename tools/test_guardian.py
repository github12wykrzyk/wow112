#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

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

if __name__ == "__main__":
    unittest.main()
