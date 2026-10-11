#!/usr/bin/env python3
"""Smoke tests for the Aether JSON-RPC bridge."""

import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE = os.path.join(ROOT, "bridge.py")
PYTHON = os.path.join(ROOT, "venv", "bin", "python3")


def rpc(cmd, args=None, request_id=1):
    payload = {"id": request_id, "cmd": cmd, "args": args or {}}
    proc = subprocess.run(
        [PYTHON, BRIDGE],
        input=json.dumps(payload) + "\n",
        capture_output=True,
        text=True,
        cwd=os.path.join(os.path.expanduser("~"), ".aether", "db"),
        timeout=120,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr or proc.stdout)
    line = proc.stdout.strip().splitlines()[-1]
    return json.loads(line)


@unittest.skipUnless(os.path.exists(PYTHON), "Backend venv not installed")
class BridgeSmokeTests(unittest.TestCase):
    def test_malformed_line_does_not_reuse_previous_request_id(self):
        with tempfile.TemporaryDirectory(prefix="aether-bridge-protocol-") as state:
            env = os.environ.copy()
            env["AETHER_DIR"] = state
            proc = subprocess.Popen(
                [PYTHON, BRIDGE],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
            )
            try:
                proc.stdin.write('{"id": 41, "cmd": "ping"}\nnot-json\n{"id": 42, "cmd": "ping"}\n')
                proc.stdin.close()
                responses = [json.loads(line) for line in proc.stdout if line.strip()]
                self.assertEqual(responses[0]["id"], 41)
                self.assertIsNone(responses[1]["id"])
                self.assertFalse(responses[1]["ok"])
                self.assertEqual(responses[2]["id"], 42)
                self.assertTrue(responses[2]["data"]["ok"])
            finally:
                proc.stdout.close()
                proc.stderr.close()
                proc.wait(timeout=10)

    def test_ping(self):
        response = rpc("ping")
        self.assertTrue(response["ok"])
        self.assertEqual(response["data"]["ok"], True)

    def test_load_config(self):
        response = rpc("load_config", request_id=2)
        self.assertTrue(response["ok"])
        self.assertIn("folders", response["data"])
        self.assertIn("recent_searches", response["data"])
        self.assertIn("saved_searches", response["data"])

    def test_search_short_query(self):
        response = rpc("search", {"query": "a"}, request_id=3)
        self.assertTrue(response["ok"])
        self.assertEqual(response["data"], [])

    def test_index_progress_idle(self):
        response = rpc("index_progress", request_id=4)
        self.assertTrue(response["ok"])
        self.assertFalse(response["data"]["active"])


if __name__ == "__main__":
    unittest.main()
