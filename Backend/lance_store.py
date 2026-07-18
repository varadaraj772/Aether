"""Shared LanceDB connection and in-process operation lock.

LanceDB handles persistence, while this lock prevents this bridge process from
reading a table during a multi-step replacement (delete followed by add).
Callers should hold it only while interacting with LanceDB, never while
extracting text or producing embeddings.
"""

import os
import threading

import lancedb

AETHER_DIR = os.path.join(os.path.expanduser("~"), ".aether")
db = lancedb.connect(os.path.join(AETHER_DIR, "db"))

# RLock allows helpers that already hold the lock to call another DB helper.
db_lock = threading.RLock()
