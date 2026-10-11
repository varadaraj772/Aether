"""Shared LanceDB connection and in-process operation lock.

LanceDB handles persistence, while this lock prevents this bridge process from
reading a table during a multi-step replacement (delete followed by add).
Callers should hold it only while interacting with LanceDB, never while
extracting text or producing embeddings.
"""

import os
import threading
import time

import lancedb

AETHER_DIR = os.environ.get("AETHER_DIR", os.path.join(os.path.expanduser("~"), ".aether"))
db = lancedb.connect(os.path.join(AETHER_DIR, "db"))

# RLock allows helpers that already hold the lock to call another DB helper.


class ProfiledRLock:
    """RLock-compatible wrapper recording wait and hold time when enabled."""

    def __init__(self):
        self._lock = threading.RLock()
        self._local = threading.local()
        self.reset_profile()

    def reset_profile(self):
        self.wait_seconds = 0.0
        self.hold_seconds = 0.0
        self.acquire_count = 0

    def snapshot_profile(self):
        return {
            "lock_acquires": self.acquire_count,
            "lock_wait_seconds": self.wait_seconds,
            "lock_hold_seconds": self.hold_seconds,
        }

    def acquire(self, blocking=True, timeout=-1):
        started = time.perf_counter()
        acquired = self._lock.acquire(blocking, timeout)
        if acquired:
            self.acquire_count += 1
            self.wait_seconds += time.perf_counter() - started
            stack = getattr(self._local, "starts", [])
            stack.append(time.perf_counter())
            self._local.starts = stack
        return acquired

    def release(self):
        stack = getattr(self._local, "starts", [])
        if stack:
            self.hold_seconds += time.perf_counter() - stack.pop()
        self._lock.release()

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.release()
        return False


db_lock = ProfiledRLock()
