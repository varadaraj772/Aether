import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


BACKEND = Path(__file__).resolve().parents[1]
BRIDGE = BACKEND / "bridge.py"


class BridgeProcessRecoveryTests(unittest.TestCase):
    def _start(self, state_dir, root, *, crash=False):
        env = os.environ.copy()
        env.update({
            "AETHER_DIR": str(state_dir),
            "AETHER_TEST_FAKE_MODEL": "1",
            "PYTHONUNBUFFERED": "1",
        })
        if crash:
            env["AETHER_TEST_EXIT_AFTER_START"] = "1"
        return subprocess.Popen(
            [sys.executable, str(BRIDGE)],
            cwd=str(BACKEND),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )

    @staticmethod
    def _request(process, request_id, command, args=None):
        process.stdin.write(json.dumps({"id": request_id, "cmd": command, "args": args or {}}) + "\n")
        process.stdin.flush()
        line = process.stdout.readline()
        if not line:
            raise AssertionError("bridge exited before returning a response")
        return json.loads(line)

    def test_unexpected_process_exit_is_recoverable_and_retryable(self):
        with tempfile.TemporaryDirectory(prefix="aether-process-recovery-") as raw:
            root = Path(raw) / "documents"
            state = Path(raw) / "state"
            root.mkdir()
            state.mkdir()
            for index in range(40):
                (root / f"doc-{index}.txt").write_text(
                    f"recovery document {index}\n", encoding="utf-8"
                )

            crashed = self._start(state, root, crash=True)
            response = self._request(crashed, 1, "index_folder", {"folder": str(root), "force": True})
            self.assertTrue(response["data"]["started"])
            crashed.wait(timeout=5)
            self.assertEqual(crashed.returncode, 75)
            crashed.stdin.close()
            crashed.stdout.close()
            crashed.stderr.close()

            recovered = self._start(state, root)
            status = self._request(recovered, 2, "index_status")
            self.assertEqual(status["data"]["state"], "recoverable")

            retry = self._request(recovered, 3, "index_folder", {"folder": str(root), "force": True})
            self.assertTrue(retry["data"]["started"])
            deadline = time.time() + 30
            final = None
            while time.time() < deadline:
                final = self._request(recovered, 4, "index_status")
                if final["data"]["done"]:
                    break
                time.sleep(0.05)
            self.assertIsNotNone(final)
            self.assertTrue(final["data"]["done"], final)
            self.assertEqual(final["data"]["state"], "completed")
            self.assertEqual(final["data"]["result"]["failed"], 0)

            stats = self._request(recovered, 5, "folder_stats", {"folder": str(root)})
            self.assertEqual(stats["data"]["file_count"], 40)
            recovered.stdin.close()
            recovered.terminate()
            recovered.wait(timeout=5)
            recovered.stdout.close()
            recovered.stderr.close()


if __name__ == "__main__":
    unittest.main()
