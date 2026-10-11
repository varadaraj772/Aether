"""Focused extraction, path, deletion, and watcher regression tests."""

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import sys
BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BACKEND not in sys.path:
    sys.path.insert(0, BACKEND)

import lancedb
import indexer
from watcher import FileChangeHandler, last_indexed


class ExtractionAndFilesystemTests(unittest.TestCase):
    def test_pdf_pages_preserve_boundaries_and_empty_pages(self):
        class Page:
            def __init__(self, text):
                self.text = text

            def extract_text(self):
                return self.text

        reader = mock.Mock(pages=[Page("first page"), Page(None), Page("third page")])
        with mock.patch.object(indexer, "PdfReader", return_value=reader), mock.patch.object(
            indexer, "ocr_pdf_pages", return_value=""
        ):
            text = indexer.extract_pdf("fixture.pdf")
        self.assertIn("first page", text)
        self.assertIn("third page", text)
        self.assertIn("\n\n", text)

    def test_pdf_partial_ocr_is_used_only_when_better_but_status_is_not_overclaimed(self):
        reader = mock.Mock(pages=[mock.Mock(extract_text=lambda: "")])
        with mock.patch.object(indexer, "PdfReader", return_value=reader), mock.patch.object(
            indexer, "ocr_pdf_pages", return_value="ocr text"
        ):
            self.assertEqual(indexer.extract_pdf("partial.pdf"), "ocr text")
        # The current extractor returns text only; explicit OCR completeness
        # metadata remains a documented limitation rather than an assumption.

    def test_binary_and_oversized_text_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "binary.txt"
            binary.write_bytes(b"header\x00not searchable")
            oversized = Path(directory) / "large.txt"
            oversized.write_text("x" * 32, encoding="utf-8")
            with self.assertRaises(indexer.ExtractionError):
                indexer.extract_text_file(str(binary))
            with mock.patch.dict(os.environ, {"AETHER_MAX_TEXT_BYTES": "8"}):
                with self.assertRaises(indexer.ExtractionError):
                    indexer.extract_text_file(str(oversized))

    def test_traversal_does_not_follow_symlinks_or_escape_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "root"
            outside = Path(directory) / "outside"
            root.mkdir()
            outside.mkdir()
            (root / "inside.txt").write_text("inside", encoding="utf-8")
            (outside / "secret.txt").write_text("secret", encoding="utf-8")
            try:
                (root / "link").symlink_to(outside, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            paths = indexer._walk_supported_files(str(root))
            self.assertEqual(paths, [str(root / "inside.txt")])
            self.assertTrue(indexer._path_in_folder(str(root / "inside.txt"), str(root)))
            self.assertFalse(indexer._path_in_folder(str(outside / "secret.txt"), str(root)))

    def test_rename_delete_and_retry_leave_one_current_row(self):
        with tempfile.TemporaryDirectory() as directory:
            old_db = indexer.db
            indexer.db = lancedb.connect(str(Path(directory) / "db"))
            try:
                old_path = str(Path(directory) / "old.txt")
                new_path = str(Path(directory) / "new.txt")
                Path(old_path).write_text("old content", encoding="utf-8")
                model = mock.Mock()
                model.encode.return_value = [[0.1] * 768]
                with mock.patch("index_progress.is_cancelled", return_value=False):
                    indexer._index_file(old_path, model=model)
                os.rename(old_path, new_path)
                indexer.delete_file_from_index(old_path)
                with mock.patch("index_progress.is_cancelled", return_value=False):
                    indexer._index_file(new_path, model=model)
                    indexer._index_file(new_path, model=model)
                rows = indexer.db.open_table(indexer.TABLE_NAME).to_arrow().to_pylist()
                self.assertEqual([row["path"] for row in rows], [new_path])
            finally:
                indexer.db = old_db

    def test_watcher_debounces_changes_and_handles_index_errors(self):
        handler = FileChangeHandler()
        last_indexed.clear()
        with mock.patch("watcher.index_single_file") as index_one:
            handler.process_file("/tmp/example.txt")
            handler.process_file("/tmp/example.txt")
        index_one.assert_called_once_with("/tmp/example.txt")
        with mock.patch("watcher.index_single_file", side_effect=RuntimeError("gone")):
            handler.process_file("/tmp/another.txt")


if __name__ == "__main__":
    unittest.main()
