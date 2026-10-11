"""Integration coverage for batched indexing failure boundaries."""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BACKEND not in sys.path:
    sys.path.insert(0, BACKEND)

import lancedb
import indexer


class DeterministicModel:
    def __init__(self, fail=False, malformed=False):
        self.calls = []
        self.fail = fail
        self.malformed = malformed

    def encode(self, values, **_kwargs):
        if self.fail:
            raise RuntimeError("injected embedding failure")
        values = values if isinstance(values, list) else [values]
        self.calls.append(list(values))
        if self.malformed:
            return [[float(i)] for i in range(len(values))]
        return [[float(i)] * 768 for i in range(len(values))]


class BatchedIndexingFailureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="aether-batch-test-")
        self.root = Path(self.temp.name)
        self.old_db = indexer.db
        indexer.db = lancedb.connect(str(self.root / "db"))

    def tearDown(self):
        indexer.db = self.old_db
        self.temp.cleanup()

    def _file(self, name, text):
        path = self.root / name
        path.write_text(text, encoding="utf-8")
        return str(path)

    def _rows(self, path=None):
        table = indexer.db.open_table(indexer.TABLE_NAME)
        rows = table.to_arrow().to_pylist()
        return [row for row in rows if path is None or row["path"] == path]

    def test_large_documents_share_batches_and_align_partial_final_batch(self):
        paths = [
            self._file("a.txt", "a" * 1700),
            self._file("b.txt", "b" * 1700),
        ]
        model = DeterministicModel()
        with mock.patch("index_progress.is_cancelled", return_value=False):
            counts = indexer._index_text_batch(paths, model, 3)

        self.assertEqual(counts, {paths[0]: 3, paths[1]: 3})
        self.assertEqual([len(call) for call in model.calls], [3, 3])
        rows = self._rows()
        self.assertEqual(len(rows), 6)
        for path in paths:
            file_rows = sorted(self._rows(path), key=lambda row: row["chunk_id"])
            self.assertEqual([row["chunk_id"] for row in file_rows], [0, 1, 2])
            self.assertTrue(all(row["path"] == path for row in file_rows))

    def test_failed_document_retains_old_rows_and_unrelated_document_succeeds(self):
        target = self._file("target.txt", "old target")
        other = self._file("other.txt", "other content")
        model = DeterministicModel()
        with mock.patch("index_progress.is_cancelled", return_value=False):
            indexer._index_text_batch([target], model, 2)
        old_content = self._rows(target)[0]["content"]
        Path(target).write_text("new target content", encoding="utf-8")
        original_write = indexer._write_index_rows

        def fail_target(path, rows):
            if path == target:
                raise OSError("injected database failure")
            return original_write(path, rows)

        with mock.patch.object(indexer, "_write_index_rows", side_effect=fail_target):
            with self.assertRaises(OSError):
                indexer._index_text_batch([target, other], model, 2)

        self.assertEqual(self._rows(target)[0]["content"], old_content)
        self.assertEqual(len(self._rows(other)), 1)
        self.assertEqual(len(self._rows(target)), 1)

    def test_cancellation_after_embedding_writes_no_new_rows_and_retry_is_idempotent(self):
        path = self._file("cancel.txt", "cancel me")
        model = DeterministicModel()
        with mock.patch("index_progress.is_cancelled", side_effect=[False, False, True]):
            with self.assertRaises(InterruptedError):
                indexer._index_text_batch([path], model, 2)
        self.assertFalse(indexer.TABLE_NAME in indexer.db.table_names())

        with mock.patch("index_progress.is_cancelled", return_value=False):
            indexer._index_text_batch([path], model, 2)
            indexer._index_text_batch([path], model, 2)
        self.assertEqual(len(self._rows(path)), 1)

    def test_embedding_failure_and_malformed_vectors_leave_existing_rows(self):
        path = self._file("failure.txt", "valid content")
        good = DeterministicModel()
        with mock.patch("index_progress.is_cancelled", return_value=False):
            indexer._index_text_batch([path], good, 2)
        old = self._rows(path)[0]["content"]
        with self.assertRaises(RuntimeError):
            indexer._index_text_batch([path], DeterministicModel(fail=True), 2)
        self.assertEqual(self._rows(path)[0]["content"], old)
        with self.assertRaises(ValueError):
            indexer._index_text_batch([path], DeterministicModel(malformed=True), 2)
        self.assertEqual(self._rows(path)[0]["content"], old)

    def test_empty_document_is_rejected_without_creating_rows(self):
        path = self._file("empty.txt", "")
        with mock.patch("index_progress.is_cancelled", return_value=False):
            with self.assertRaises(indexer.ExtractionError):
                indexer._index_text_batch([path], DeterministicModel(), 2)
        self.assertNotIn(indexer.TABLE_NAME, indexer.db.table_names())


if __name__ == "__main__":
    unittest.main()
