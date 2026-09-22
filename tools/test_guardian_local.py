#!/usr/bin/env python3
"""Offline tests for Windows/Ollama bridge; no GitHub or local server needed."""
import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("guardian_local", Path(__file__).with_name("guardian_local.py"))
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)


class LocalBridgeTests(unittest.TestCase):
    def test_localhost_only(self):
        self.assertEqual(local.URL, "http://127.0.0.1:11434")

    def test_oversized_source_not_sent_to_model(self):
        req = {"messages": [{"role": "system", "content": "test"},
                            {"role": "user", "content": json.dumps({"source": "x" * 12001})}]}
        with patch.object(local.urllib.request, "urlopen") as opened:
            answer = local.local_completion(req)
        self.assertEqual(answer["old"], "")
        opened.assert_not_called()

    def test_model_json_conversion(self):
        req = {"messages": [{"role": "system", "content": "test"},
                            {"role": "user", "content": json.dumps({"source": "int x=1;"})}]}
        class Response:
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return False
            def read(self):
                return b'{"message":{"content":"{\\"old\\":\\"x=1\\",\\"new\\":\\"x=2\\"}"},"done_reason":"stop"}'
        with patch.object(local.urllib.request, "urlopen", return_value=Response()) as opened:
            proposal = local.local_completion(req)
        self.assertEqual(proposal["old"], "x=1")
        self.assertTrue(opened.call_args.args[0].full_url.startswith(local.URL + "/api/chat"))

    def test_incomplete_model_response_rejected(self):
        req = {"messages": [{"role": "system", "content": "test"},
                            {"role": "user", "content": json.dumps({"source": "int x=1;"})}]}
        class Response:
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return False
            def read(self):
                return b'{"message":{"content":"{}"},"done_reason":"length"}'
        with patch.object(local.urllib.request, "urlopen", return_value=Response()):
            with self.assertRaises(RuntimeError):
                local.local_completion(req)


if __name__ == "__main__":
    unittest.main()
