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
    def _search(
        self,
        rows,
        query="report",
        folder=None,
        recent_paths=None,
        recent_items=None,
        lock_state=None,
    ):
        fake_db = _FakeDB(rows, lock_state)
        with mock.patch.object(search, "db", fake_db), mock.patch.object(
            search, "get_model", return_value=_FakeModel()
        ):
            return search.search(
                query,
                folder=folder,
                recent_paths=recent_paths,
                recent_items=recent_items,
            )

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

    def test_mtime_recency_score_boosts_newer_file(self):
        now = time.time()
        rows = [
            {
                "path": "/docs/old.txt",
                "file_name": "old.txt",
                "chunk_id": 0,
                "content": "memo",
                "_distance": 1.0,
                "mtime": now - (20 * 24 * 60 * 60),
            },
            {
                "path": "/docs/new.txt",
                "file_name": "new.txt",
                "chunk_id": 0,
                "content": "memo",
                "_distance": 1.0,
                "mtime": now,
            },
        ]
        ranked = self._search(rows, query="memo")
        self.assertEqual(ranked[0]["path"], "/docs/new.txt")
        self.assertGreater(ranked[0].get("recency_score", 0), ranked[1].get("recency_score", 0))

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
        expanded = search._expand_tokens(["invoice", "photo"])
        self.assertEqual(expanded[0], "invoice")
        self.assertIn("receipt", expanded)
        self.assertIn("bill", expanded)
        self.assertIn("expense", expanded)
        self.assertIn("photo", expanded)
        self.assertIn("image", expanded)
        self.assertIn("picture", expanded)
        self.assertIn("screenshot", expanded)

    def test_synonym_groups_are_symmetric(self):
        for token, syns in search._SYNONYMS.items():
            for syn in syns:
                self.assertIn(token, search._SYNONYMS.get(syn, ()), msg=f"{token} <-> {syn}")

    def test_path_segment_ignores_short_substring_false_positives(self):
        rows = [
            {
                "path": "/archive/misc/note.txt",
                "file_name": "note.txt",
                "chunk_id": 0,
                "content": "note",
                "_distance": 1.0,
            },
            {
                "path": "/docs/note.txt",
                "file_name": "note.txt",
                "chunk_id": 0,
                "content": "note",
                "_distance": 1.0,
            },
        ]
        # "ar" must not boost /archive via substring/prefix containment.
        ranked = self._search(rows, query="ar note")
        self.assertEqual(ranked[0]["path_score"], ranked[1]["path_score"])

    def test_complete_multi_token_filename_outranks_partial(self):
        rows = [
            {
                "path": "/d/budget.txt",
                "file_name": "budget.txt",
                "chunk_id": 0,
                "content": "",
                "_distance": 1.0,
            },
            {
                "path": "/d/budget-report-final.txt",
                "file_name": "budget-report-final.txt",
                "chunk_id": 0,
                "content": "",
                "_distance": 1.0,
            },
        ]
        ranked = self._search(rows, query="budget report")
        self.assertEqual(ranked[0]["path"], "/d/budget-report-final.txt")

    def test_recent_items_time_decay_and_open_count(self):
        now = time.time()
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
            {
                "path": "/docs/c.txt",
                "file_name": "c.txt",
                "chunk_id": 0,
                "content": "memo",
                "_distance": 1.0,
            },
        ]
        recent_items = [
            {
                "path": "/docs/a.txt",
                "open_count": 1,
                "last_opened_at": now - (30 * 86400),
            },
            {
                "path": "/docs/b.txt",
                "open_count": 1,
                "last_opened_at": now,
            },
            {
                "path": "/docs/c.txt",
                "open_count": 8,
                "last_opened_at": now,
            },
        ]
        ranked = self._search(rows, query="memo", recent_items=recent_items)
        by_path = {item["path"]: item for item in ranked}
        self.assertGreater(by_path["/docs/b.txt"]["recent_score"], by_path["/docs/a.txt"]["recent_score"])
        self.assertGreater(by_path["/docs/c.txt"]["recent_score"], by_path["/docs/b.txt"]["recent_score"])
        self.assertEqual(ranked[0]["path"], "/docs/c.txt")

    def test_recent_boost_does_not_outrank_exact_filename(self):
        now = time.time()
        rows = [
            {
                "path": "/docs/report.pdf",
                "file_name": "report.pdf",
                "chunk_id": 0,
                "content": "unrelated",
                "_distance": 10.0,
            },
            {
                "path": "/docs/other.txt",
                "file_name": "other.txt",
                "chunk_id": 0,
                "content": "report",
                "_distance": 0.0,
            },
        ]
        recent_items = [
            {
                "path": "/docs/other.txt",
                "open_count": 50,
                "last_opened_at": now,
            }
        ]
        ranked = self._search(rows, query="report", recent_items=recent_items)
        self.assertEqual(ranked[0]["path"], "/docs/report.pdf")
        self.assertLessEqual(ranked[1]["recent_score"], search._RECENT_MAX_BOOST)

    def test_legacy_recent_paths_still_boost(self):
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

    def test_synonym_aware_snippet_anchors(self):
        content = "prefix " + ("x " * 40) + "store receipt total " + ("y " * 40)
        snippet = search._match_snippet(content, "invoice")
        self.assertIn("receipt", snippet.lower())

    def test_deterministic_tie_break_by_path(self):
        rows = [
            {
                "path": "/docs/b.txt",
                "file_name": "b.txt",
                "chunk_id": 0,
                "content": "memo",
                "_distance": 1.0,
            },
            {
                "path": "/docs/a.txt",
                "file_name": "a.txt",
                "chunk_id": 0,
                "content": "memo",
                "_distance": 1.0,
            },
        ]
        ranked = self._search(rows, query="memo")
        self.assertEqual([item["path"] for item in ranked], ["/docs/a.txt", "/docs/b.txt"])


class BridgeArgPassthroughTests(unittest.TestCase):
    def test_search_forwards_recent_paths(self):
        captured = {}

        def fake_search(query, folder=None, recent_paths=None, recent_items=None):
            captured["query"] = query
            captured["folder"] = folder
            captured["recent_paths"] = recent_paths
            captured["recent_items"] = recent_items
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
        self.assertEqual(captured["recent_items"], [])

    def test_search_forwards_recent_items(self):
        captured = {}

        def fake_search(query, folder=None, recent_paths=None, recent_items=None):
            captured["recent_paths"] = recent_paths
            captured["recent_items"] = recent_items
            return []

        items = [{"path": "/docs/a.txt", "open_count": 3, "last_opened_at": 100.0}]
        with mock.patch("search.search", fake_search):
            result = bridge.handle({
                "cmd": "search",
                "args": {
                    "query": "hello",
                    "recent_items": items,
                    "recent_paths": "not-a-list",
                },
            })
        self.assertEqual(result, [])
        self.assertEqual(captured["recent_items"], items)
        self.assertEqual(captured["recent_paths"], [])

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

    def test_warmup_error_message_missing_dependency(self):
        import models

        msg = models._warmup_error_message(ModuleNotFoundError("No module named 'sentence_transformers'"))
        self.assertIn("setup-backend.sh", msg)
        self.assertIn("dependencies are missing", msg.lower())

    def test_warmup_error_message_network(self):
        import models

        msg = models._warmup_error_message(RuntimeError("Connection timed out talking to huggingface"))
        self.assertIn("Connect to the internet", msg)
        self.assertIn("Hugging Face", msg)

    def test_warmup_error_message_generic(self):
        import models

        msg = models._warmup_error_message(RuntimeError("unexpected tensor layout"))
        self.assertIn("Search model warmup failed", msg)
        self.assertIn("setup-backend.sh", msg)

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
