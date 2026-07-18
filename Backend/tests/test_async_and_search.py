#!/usr/bin/env python3
"""Regression tests for async indexing and deterministic search ranking."""

import contextlib
import io
import os
import sys
import threading
import time
import types
import unittest
from pathlib import Path
from unittest import mock

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BACKEND not in sys.path:
    sys.path.insert(0, BACKEND)

import bridge

# Unit tests replace the DB object, so a lightweight module stub keeps these
# tests runnable in development environments without optional LanceDB wheels.
if "lancedb" not in sys.modules:
    try:
        import lancedb  # noqa: F401
    except ImportError:
        sys.modules["lancedb"] = types.SimpleNamespace(connect=lambda _path: object())
import search


class _FakeModel:
    def encode(self, _value, **_kwargs):
        return _FakeVector()


class _FakeVector:
    def tolist(self):
        return [0.1, 0.2]


class _FakeSearch:
    def __init__(self, rows, lock_state=None):
        self.rows = rows
        self.lock_state = lock_state

    def limit(self, _count):
        return self

    def to_list(self):
        if self.lock_state is not None:
            assert self.lock_state["held"], "LanceDB read occurred without db_lock"
        return [dict(row) for row in self.rows]


class _FakeTable:
    def __init__(self, rows, lock_state=None):
        self.rows = rows
        self.lock_state = lock_state

    def search(self, _vector):
        return _FakeSearch(self.rows, self.lock_state)


class _FakeDB:
    def __init__(self, rows, lock_state=None):
        self.table = _FakeTable(rows, lock_state)

    def table_names(self):
        return ["documents"]

    def open_table(self, _name):
        return self.table


class AsyncIndexTests(unittest.TestCase):
    def setUp(self):
        thread = bridge._index_thread
        if thread is not None:
            thread.join(timeout=2)
        with bridge._index_lock:
            bridge._index_thread = None
            bridge._index_result = None
            bridge._index_error = None
            bridge._index_done = False
            bridge._index_cancelled = False

    def _wait_done(self):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            status = bridge._index_status()
            if status["done"]:
                return status
            time.sleep(0.01)
        self.fail("index job did not complete")

    def test_only_one_index_job_can_start(self):
        release = threading.Event()
        started = threading.Event()

        def job():
            started.set()
            release.wait(2)
            return {"chunks": 1}

        bridge._start_index_job(job)
        self.assertTrue(started.wait(1))
        with self.assertRaisesRegex(ValueError, "already in progress"):
            bridge._start_index_job(job)
        release.set()
        self.assertEqual(self._wait_done()["result"], {"chunks": 1})

    def test_cancelled_completion_is_consumed_once(self):
        bridge._start_index_job(lambda: (_ for _ in ()).throw(InterruptedError("Indexing cancelled")))
        status = self._wait_done()
        self.assertTrue(status["cancelled"])
        self.assertEqual(status["error"], "Indexing cancelled")
        idle = bridge._index_status()
        self.assertFalse(idle["done"])
        self.assertFalse(idle["cancelled"])

    def test_idle_cancel_does_not_create_stale_request(self):
        with mock.patch("index_progress.request_cancel") as request_cancel:
            response = bridge._cancel_index()
        self.assertEqual(response, {"ok": True, "accepted": False})
        request_cancel.assert_not_called()

    def test_stdout_gate_routes_incidental_prints_to_stderr(self):
        stderr = io.StringIO()
        with mock.patch.object(bridge.sys, "__stderr__", stderr):
            stream = bridge._RPCStdout()
            with contextlib.redirect_stdout(stream):
                print("model noise")
        self.assertIn("model noise", stderr.getvalue())


class SearchRankingTests(unittest.TestCase):
    def _search(self, rows, query="report", folder=None, recent_paths=None, lock_state=None):
        fake_db = _FakeDB(rows, lock_state)
        with mock.patch.object(search, "db", fake_db), mock.patch.object(
            search, "get_model", return_value=_FakeModel()
        ):
            return search.search(query, folder=folder, recent_paths=recent_paths)

    def test_exact_stem_beats_better_semantic_result(self):
        rows = [
            {
                "path": "/docs/report.pdf",
                "file_name": "report.pdf",
                "chunk_id": 0,
                "content": "unrelated",
                "_distance": 10.0,
            },
            {
                "path": "/docs/notes.txt",
                "file_name": "notes.txt",
                "chunk_id": 0,
                "content": "report",
                "_distance": 0.0,
            },
        ]
        self.assertEqual(self._search(rows)[0]["path"], "/docs/report.pdf")

    def test_filename_token_prefix_and_content_ordering(self):
        rows = [
            {"path": "/d/content.txt", "file_name": "content.txt", "chunk_id": 0,
             "content": "budget details", "_distance": 1.0},
            {"path": "/d/budgeting.txt", "file_name": "budgeting.txt", "chunk_id": 0,
             "content": "", "_distance": 1.0},
            {"path": "/d/budget-plan.txt", "file_name": "budget-plan.txt", "chunk_id": 0,
             "content": "", "_distance": 1.0},
        ]
        paths = [item["path"] for item in self._search(rows, query="budget")]
        self.assertEqual(paths, ["/d/budget-plan.txt", "/d/budgeting.txt", "/d/content.txt"])

    def test_folder_filter_remains_optional_and_boundary_safe(self):
        rows = [
            {"path": "/docs/a.txt", "file_name": "a.txt", "chunk_id": 0,
             "content": "query", "_distance": 0.0},
            {"path": "/docs-other/b.txt", "file_name": "b.txt", "chunk_id": 0,
             "content": "query", "_distance": 0.0},
        ]
        paths = [item["path"] for item in self._search(rows, query="query", folder="/docs")]
        self.assertEqual(paths, ["/docs/a.txt"])

    def test_search_holds_lock_only_during_database_read(self):
        state = {"held": False}

        @contextlib.contextmanager
        def tracked_lock():
            state["held"] = True
            try:
                yield
            finally:
                state["held"] = False

        rows = [{"path": "/d/a", "file_name": "a", "chunk_id": 0,
                 "content": "query", "_distance": 0.0}]
        with mock.patch.object(search, "db_lock", tracked_lock()):
            result = self._search(rows, query="query", lock_state=state)
        self.assertFalse(state["held"])
        self.assertEqual(len(result), 1)

    def test_ranking_does_not_stat_result_files(self):
        rows = [{"path": "/missing/report", "file_name": "report", "chunk_id": 0,
                 "content": "", "_distance": 0.0, "mtime": 100.0}]
        with mock.patch.object(search.os.path, "getmtime", side_effect=AssertionError("unexpected stat")):
            self.assertEqual(self._search(rows)[0]["path"], "/missing/report")

    def test_path_segment_boost_prefers_matching_parent(self):
        rows = [
            {
                "path": "/archive/misc/budget.txt",
                "file_name": "budget.txt",
                "chunk_id": 0,
                "content": "",
                "_distance": 1.0,
            },
            {
                "path": "/archive/invoices/budget.txt",
                "file_name": "budget.txt",
                "chunk_id": 0,
                "content": "",
                "_distance": 1.0,
            },
        ]
        paths = [item["path"] for item in self._search(rows, query="invoice budget")]
        self.assertEqual(paths[0], "/archive/invoices/budget.txt")
        self.assertGreater(
            self._search(rows, query="invoice budget")[0]["path_score"], 0
        )

    def test_recent_paths_boost(self):
        rows = [
            {
                "path": "/docs/a.txt",
                "file_name": "a.txt",
                "chunk_id": 0,
                "content": "memo",
                "_distance": 1.0,
            },
            {
                "path": "/docs/b.txt",
                "file_name": "b.txt",
                "chunk_id": 0,
                "content": "memo",
                "_distance": 1.0,
            },
        ]
        ranked = self._search(rows, query="memo", recent_paths=["/docs/b.txt"])
        self.assertEqual(ranked[0]["path"], "/docs/b.txt")
        self.assertGreater(ranked[0]["recent_score"], 0)

    def test_synonym_expansion_helps_keyword_scoring_only(self):
        rows = [
            {
                "path": "/docs/scan.pdf",
                "file_name": "scan.pdf",
                "chunk_id": 0,
                "content": "store receipt total",
                "_distance": 1.0,
            },
            {
                "path": "/docs/other.pdf",
                "file_name": "other.pdf",
                "chunk_id": 0,
                "content": "unrelated",
                "_distance": 1.0,
            },
        ]
        # Equal semantic distance: synonym content match should decide ranking.
        ranked = self._search(rows, query="invoice")
        self.assertEqual(ranked[0]["path"], "/docs/scan.pdf")
        self.assertGreater(ranked[0]["keyword_score"], ranked[1]["keyword_score"])

    def test_expand_tokens_is_small_and_stable(self):
        self.assertEqual(
            search._expand_tokens(["invoice", "photo"]),
            ["invoice", "receipt", "bill", "photo", "image", "picture"],
        )


class BridgeArgPassthroughTests(unittest.TestCase):
    def test_search_forwards_recent_paths(self):
        captured = {}

        def fake_search(query, folder=None, recent_paths=None):
            captured["query"] = query
            captured["folder"] = folder
            captured["recent_paths"] = recent_paths
            return []

        with mock.patch("search.search", fake_search):
            result = bridge.handle({
                "cmd": "search",
                "args": {
                    "query": "hello",
                    "folder": "/docs",
                    "recent_paths": ["/docs/a.txt"],
                },
            })
        self.assertEqual(result, [])
        self.assertEqual(captured["query"], "hello")
        self.assertEqual(captured["folder"], "/docs")
        self.assertEqual(captured["recent_paths"], ["/docs/a.txt"])

    def test_duplicates_forwards_max_files(self):
        captured = {}

        def fake_find_duplicates(similarity_threshold=0.92, max_files=2000):
            captured["threshold"] = similarity_threshold
            captured["max_files"] = max_files
            return [{"kind": "exact", "similarity": 1.0, "files": []}]

        duplicates_mod = types.ModuleType("duplicates")
        duplicates_mod.find_duplicates = fake_find_duplicates
        with mock.patch.dict(sys.modules, {"duplicates": duplicates_mod}):
            result = bridge.handle({
                "cmd": "duplicates",
                "args": {"threshold": 0.95, "max_files": 1500},
            })
        self.assertEqual(captured["threshold"], 0.95)
        self.assertEqual(captured["max_files"], 1500)
        self.assertEqual(result["groups"][0]["kind"], "exact")


class IndexFailureStatsTests(unittest.TestCase):
    def test_build_index_all_aggregates_failed_fields(self):
        try:
            import indexer
        except ImportError:
            self.skipTest("indexer dependencies unavailable")

        calls = [
            {
                "chunks": 2,
                "updated": 1,
                "removed": 0,
                "skipped": 3,
                "failed": 2,
                "failed_sample": ["/a/fail1.pdf", "/a/fail2.pdf"],
            },
            {
                "chunks": 5,
                "updated": 2,
                "removed": 1,
                "skipped": 0,
                "failed": 1,
                "failed_sample": ["/b/fail3.pdf"],
            },
        ]

        def fake_build(folder, force=False):
            return calls.pop(0)

        with mock.patch.object(indexer, "_build_index", side_effect=fake_build), mock.patch(
            "index_progress.clear_progress"
        ), mock.patch("index_progress.is_cancelled", return_value=False), mock.patch.object(
            indexer.os.path, "isdir", return_value=True
        ):
            totals = indexer.build_index_all(["/a", "/b"], force=False)

        self.assertEqual(totals["chunks"], 7)
        self.assertEqual(totals["failed"], 3)
        self.assertEqual(
            totals["failed_sample"],
            ["/a/fail1.pdf", "/a/fail2.pdf", "/b/fail3.pdf"],
        )


class ModelProgressTests(unittest.TestCase):
    def test_emit_model_progress_stderr_marker(self):
        import models

        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            models._emit_model_progress("loading")
        self.assertIn("MODEL_PROGRESS: loading", buf.getvalue())

    def test_warmup_emits_ready_and_keeps_stdout_clean(self):
        import models

        fake = mock.Mock()
        fake.encode = mock.Mock(return_value=[0.0])
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.object(models, "get_model", return_value=fake), contextlib.redirect_stdout(
            stdout
        ), contextlib.redirect_stderr(stderr):
            result = models.warmup_model()
        self.assertTrue(result.get("ready"))
        self.assertIn("cached", result)
        self.assertEqual(stdout.getvalue().strip(), "")
        self.assertIn("MODEL_PROGRESS: ready", stderr.getvalue())

    def test_get_model_uses_local_snapshot_offline_when_cached(self):
        import models

        fake_snapshot = Path("/tmp/aether-fake-minilm-snapshot")
        captured = {}

        class FakeST:
            def __init__(self, model_id, local_files_only=False):
                captured["model_id"] = model_id
                captured["local_files_only"] = local_files_only

        fake_module = types.SimpleNamespace(SentenceTransformer=FakeST)
        with mock.patch.object(models, "_model", None), mock.patch.object(
            models, "_resolve_local_snapshot", return_value=fake_snapshot
        ), mock.patch.object(models, "_enable_offline_hub") as offline, mock.patch.dict(
            sys.modules, {"sentence_transformers": fake_module}
        ):
            model = models.get_model()

        self.assertIsInstance(model, FakeST)
        self.assertEqual(captured["model_id"], str(fake_snapshot))
        self.assertTrue(captured["local_files_only"])
        offline.assert_called_once()


if __name__ == "__main__":
    unittest.main()
