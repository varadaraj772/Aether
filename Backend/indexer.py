import os
import sys
import tempfile
import subprocess

import pandas as pd
from pypdf import PdfReader
from docx import Document
from pptx import Presentation

from models import get_model
from lance_store import db, db_lock

AETHER_DIR = os.path.join(os.path.expanduser("~"), ".aether")
os.makedirs(os.path.join(AETHER_DIR, "db"), exist_ok=True)

TABLE_NAME = "documents"

TEXT_EXTENSIONS = {
    ".txt",
    ".md",
    ".json",
    ".csv",
    ".log",
    ".swift",
    ".py",
    ".js",
    ".ts",
    ".tsx",
    ".jsx",
    ".html",
    ".css",
    ".rs",
    ".go",
    ".java",
    ".kt",
    ".c",
    ".cpp",
    ".h",
    ".hpp",
    ".m",
    ".mm",
    ".rb",
    ".php",
    ".sh",
    ".yaml",
    ".yml",
    ".toml",
    ".xml",
    ".sql",
    ".r",
    ".scala",
    ".vue",
    ".svelte",
    ".eml",
}

SUPPORTED_EXTENSIONS = {
    ".pdf",
    ".docx",
    ".pages",
    ".xlsx",
    ".pptx",
    ".png",
    ".jpg",
    ".jpeg",
    *TEXT_EXTENSIONS,
}

PDF_OCR_MIN_CHARS = 40
PDF_OCR_MAX_PAGES = 10

EXCLUDED_DIR_NAMES = {
    ".git",
    ".svn",
    ".hg",
    "node_modules",
    "__pycache__",
    ".venv",
    "venv",
    "dist",
    "build",
    ".cache",
    ".Trash",
    ".idea",
    ".cursor",
    "site-packages",
}


def _active_excluded_names():
    try:
        from folders import load_excluded_dir_names

        names = load_excluded_dir_names()
        if names:
            return names
    except Exception:
        pass
    return set(EXCLUDED_DIR_NAMES)


def _should_skip_dir(dirname):
    excluded = _active_excluded_names()
    return any(dirname == name or dirname.lower() == name.lower() for name in excluded)


def should_skip_path(path):
    excluded = _active_excluded_names()
    normalized = os.path.normpath(path)
    parts = normalized.split(os.sep)
    for name in excluded:
        needle = name.strip().strip("/\\")
        if not needle:
            continue
        if any(part == needle or part.lower() == needle.lower() for part in parts):
            return True
        lower_path = normalized.lower()
        lower_needle = needle.lower()
        if lower_path.endswith("/" + lower_needle) or lower_path.endswith("\\" + lower_needle):
            return True
        if lower_path == lower_needle:
            return True
    return False



def extract_pages_text(path):
    try:
        temp_dir = tempfile.mkdtemp()
        pdf_path = os.path.join(temp_dir, os.path.basename(path) + ".pdf")

        script = f'''
        tell application "Pages"
            open POSIX file "{path}"
            export front document to POSIX file "{pdf_path}" as PDF
            close front document saving no
        end tell
        '''

        subprocess.run(
            ["osascript", "-e", script],
            check=True,
            capture_output=True,
            text=True
        )

        reader = PdfReader(pdf_path)
        return "\n".join(page.extract_text() or "" for page in reader.pages)
    except Exception as e:
        print(f"\nPAGES ERROR: {path}")
        print(e)
        return ""


def extract_pdf(path, max_pages=None, ocr_max_pages=PDF_OCR_MAX_PAGES):
    text = ""
    try:
        reader = PdfReader(path)
        pages = reader.pages if max_pages is None else reader.pages[:max_pages]
        text = "\n".join(page.extract_text() or "" for page in pages)
    except Exception as e:
        print(f"\nPDF ERROR: {path}")
        print(e)
        text = ""

    if len(text.strip()) < PDF_OCR_MIN_CHARS:
        ocr_text = ocr_pdf_pages(path, max_pages=ocr_max_pages)
        if len(ocr_text.strip()) > len(text.strip()):
            return ocr_text

    return text


def extract_docx(path):
    try:
        doc = Document(path)
        return "\n".join(p.text for p in doc.paragraphs)
    except Exception as e:
        print(f"\nDOCX ERROR: {path}")
        print(e)
        return ""


def extract_text_file(path):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read()
    except Exception as e:
        print(f"\nTEXT ERROR: {path}")
        print(e)
        return ""


def extract_xlsx(path):
    try:
        df = pd.read_excel(path)
        return df.to_string()
    except Exception as e:
        print(f"\nXLSX ERROR: {path}")
        print(e)
        return ""


def extract_pptx(path):
    try:
        prs = Presentation(path)
        text = ""
        for slide in prs.slides:
            for shape in slide.shapes:
                if hasattr(shape, "text"):
                    text += shape.text + "\n"
        return text
    except Exception as e:
        print(f"\nPPTX ERROR: {path}")
        print(e)
        return ""


_ocr_engine = None

def extract_image(path):
    global _ocr_engine
    try:
        # pyrefly: ignore [missing-import]
        from rapidocr_onnxruntime import RapidOCR
        if _ocr_engine is None:
            _ocr_engine = RapidOCR()
        result, _ = _ocr_engine(path)
        if result:
            return "\n".join(line[1] for line in result if line and len(line) > 1)
    except Exception as e:
        print(f"\nOCR ERROR: {path}")
        print(e)
    return ""


def ocr_pdf_pages(path, max_pages=PDF_OCR_MAX_PAGES):
    """Render PDF pages to images and OCR them. Prefers pypdfium2."""
    try:
        import pypdfium2 as pdfium
    except ImportError:
        print(f"\nPDF OCR SKIP (pypdfium2 missing): {path}", file=sys.stderr)
        return ""

    texts = []
    pdf = None
    try:
        pdf = pdfium.PdfDocument(path)
        page_count = min(len(pdf), max_pages)
        for i in range(page_count):
            page = pdf[i]
            try:
                bitmap = page.render(scale=2.0)
                image = bitmap.to_pil()
            finally:
                try:
                    page.close()
                except Exception:
                    pass

            fd, tmp_path = tempfile.mkstemp(suffix=".png")
            os.close(fd)
            try:
                image.save(tmp_path, format="PNG")
                page_text = extract_image(tmp_path)
                if page_text.strip():
                    texts.append(page_text)
            finally:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
    except Exception as e:
        print(f"\nPDF OCR ERROR: {path}")
        print(e)
        return ""
    finally:
        if pdf is not None:
            try:
                pdf.close()
            except Exception:
                pass

    return "\n".join(texts)


def extract_text(path):
    ext = os.path.splitext(path)[1].lower()

    if ext == ".pdf":
        return extract_pdf(path)
    elif ext == ".docx":
        return extract_docx(path)
    elif ext == ".pages":
        return extract_pages_text(path)
    elif ext == ".xlsx":
        return extract_xlsx(path)
    elif ext == ".pptx":
        return extract_pptx(path)
    elif ext in [".png", ".jpg", ".jpeg"]:
        return extract_image(path)
    elif ext in TEXT_EXTENSIONS:
        return extract_text_file(path)

    return ""


def chunk_text(text, chunk_size=800, overlap=150):
    chunks = []
    start = 0

    while start < len(text):
        end = start + chunk_size
        chunks.append(text[start:end])
        start += (chunk_size - overlap)

    return chunks


def _normalize_folder(folder):
    return os.path.normpath(folder.rstrip(os.sep)) or folder


def _escape_sql(value):
    return value.replace("'", "''")


def _path_in_folder(path, folder):
    folder = _normalize_folder(folder)
    path = os.path.normpath(path)
    return path == folder or path.startswith(folder + os.sep)


def delete_folder_from_index(folder):
    folder = _normalize_folder(folder)
    prefix = _escape_sql(folder + os.sep)
    escaped = _escape_sql(folder)

    with db_lock:
        if TABLE_NAME not in db.table_names():
            return
        table = db.open_table(TABLE_NAME)
        try:
            table.delete(f"path LIKE '{prefix}%' OR path = '{escaped}'")
            return
        except Exception:
            pass

        try:
            paths = table.to_arrow().column("path").to_pylist()
            for path in {p for p in paths if _path_in_folder(p, folder)}:
                table.delete(f"path = '{_escape_sql(path)}'")
        except Exception as e:
            print(f"DELETE FOLDER ERROR: {folder}")
            print(e)


def folder_is_indexed(folder):
    folder = _normalize_folder(folder)
    try:
        with db_lock:
            if TABLE_NAME not in db.table_names():
                return False
            table = db.open_table(TABLE_NAME)
            paths = table.to_arrow().column("path").to_pylist()
        return any(_path_in_folder(path, folder) for path in paths)
    except Exception:
        return False


def delete_file_from_index(path):
    path = os.path.normpath(path)
    try:
        with db_lock:
            if TABLE_NAME not in db.table_names():
                return
            table = db.open_table(TABLE_NAME)
            table.delete(f"path = '{_escape_sql(path)}'")
        print(f"Removed from index: {path}")
    except Exception as e:
        print(f"DELETE FILE ERROR: {path}")
        print(e)
        return

    folder = _parent_indexed_folder(path)
    if folder:
        from folders import get_folder_file_mtimes, set_folder_file_mtimes

        mtimes = get_folder_file_mtimes(folder)
        if mtimes.pop(path, None) is not None:
            set_folder_file_mtimes(folder, mtimes)


def get_folder_stats(folder):
    folder = _normalize_folder(folder)
    last_indexed = None
    try:
        from folders import get_folder_meta

        last_indexed = get_folder_meta(folder).get("last_indexed")
    except Exception:
        pass
    try:
        with db_lock:
            if TABLE_NAME not in db.table_names():
                return {
                    "indexed": False,
                    "file_count": 0,
                    "chunk_count": 0,
                    "last_indexed": last_indexed,
                }
            table = db.open_table(TABLE_NAME)
            paths = table.to_arrow().column("path").to_pylist()
        folder_paths = [p for p in paths if _path_in_folder(p, folder)]
        return {
            "indexed": bool(folder_paths),
            "file_count": len(set(folder_paths)),
            "chunk_count": len(folder_paths),
            "last_indexed": last_indexed,
        }
    except Exception:
        return {
            "indexed": False,
            "file_count": 0,
            "chunk_count": 0,
            "last_indexed": last_indexed,
        }


def _walk_supported_files(folder):
    folder = _normalize_folder(folder)
    paths = []
    for root, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if not _should_skip_dir(d)]
        for file in files:
            path = os.path.join(root, file)
            if should_skip_path(path):
                continue
            ext = os.path.splitext(path)[1].lower()
            if ext in SUPPORTED_EXTENSIONS:
                paths.append(os.path.normpath(path))
    return paths


def _indexed_paths_in_folder(folder):
    folder = _normalize_folder(folder)
    try:
        with db_lock:
            if TABLE_NAME not in db.table_names():
                return set()
            table = db.open_table(TABLE_NAME)
            paths = table.to_arrow().column("path").to_pylist()
        return {os.path.normpath(p) for p in paths if _path_in_folder(p, folder)}
    except Exception:
        return set()


def _parent_indexed_folder(path):
    from folders import load_folders

    path = os.path.normpath(path)
    for folder in load_folders():
        folder = _normalize_folder(folder)
        if _path_in_folder(path, folder):
            return folder
    return None


def _index_file(path, model=None):
    path = os.path.normpath(path)
    if should_skip_path(path):
        return 0

    ext = os.path.splitext(path)[1].lower()
    if ext not in SUPPORTED_EXTENSIONS:
        return 0

    print(f"Processing: {path}")
    text = extract_text(path)
    if not text.strip():
        delete_file_from_index(path)
        return 0

    if model is None:
        model = get_model()

    chunks = chunk_text(text)
    rows = []
    for chunk_id, chunk in enumerate(chunks):
        vector = model.encode(chunk).tolist()
        rows.append({
            "path": path,
            "file_name": os.path.basename(path),
            "chunk_id": chunk_id,
            "content": chunk,
            "vector": vector,
        })

    # Keep replacement atomic with respect to searches in this process. The
    # expensive extraction and embedding work above intentionally stays outside.
    with db_lock:
        if TABLE_NAME not in db.table_names():
            db.create_table(TABLE_NAME, data=rows)
        else:
            table = db.open_table(TABLE_NAME)
            try:
                table.delete(f"path = '{_escape_sql(path)}'")
            except Exception:
                pass
            table.add(rows)
    print(f"Indexed: {path}")
    return len(rows)


def _build_index(folder, force=False):
    folder = _normalize_folder(folder)
    from folders import get_folder_file_mtimes, set_folder_file_mtimes, update_folder_meta
    from index_progress import is_cancelled, set_progress

    disk_paths = sorted(_walk_supported_files(folder))
    disk_path_set = set(disk_paths)
    indexed_paths = _indexed_paths_in_folder(folder)
    meta_mtimes = get_folder_file_mtimes(folder)
    model = get_model()

    total_steps = len(indexed_paths - disk_path_set) + len(disk_paths)
    set_progress(active=True, current=0, total=max(total_steps, 1), folder=folder, file="")
    step = 0

    removed = 0
    for path in indexed_paths - disk_path_set:
        if is_cancelled():
            raise InterruptedError("Indexing cancelled")
        delete_file_from_index(path)
        meta_mtimes.pop(path, None)
        removed += 1
        step += 1
        set_progress(active=True, current=step, total=max(total_steps, 1), folder=folder, file=os.path.basename(path))

    updated = 0
    skipped = 0
    failed_paths = []
    for path in disk_paths:
        if is_cancelled():
            raise InterruptedError("Indexing cancelled")

        try:
            mtime = os.path.getmtime(path)
        except OSError:
            failed_paths.append(path)
            step += 1
            continue

        set_progress(
            active=True,
            current=step,
            total=max(total_steps, 1),
            folder=folder,
            file=os.path.basename(path),
        )

        if not force and path in indexed_paths and meta_mtimes.get(path) == mtime:
            skipped += 1
            step += 1
            continue

        chunk_count = _index_file(path, model=model)
        if chunk_count:
            updated += 1
            meta_mtimes[path] = mtime
        else:
            failed_paths.append(path)
            if path in indexed_paths:
                updated += 1
            meta_mtimes.pop(path, None)
        step += 1
        set_progress(active=True, current=step, total=max(total_steps, 1), folder=folder, file=os.path.basename(path))

    for path in list(meta_mtimes):
        if path not in disk_path_set:
            del meta_mtimes[path]

    set_folder_file_mtimes(folder, meta_mtimes)
    stats = get_folder_stats(folder)
    failed_sample = failed_paths[:8]
    update_folder_meta(
        folder,
        file_count=stats["file_count"],
        chunk_count=stats["chunk_count"],
        skipped=skipped,
        last_index_failures=failed_sample,
    )
    return {
        "chunks": stats["chunk_count"],
        "updated": updated,
        "removed": removed,
        "skipped": skipped,
        "failed": len(failed_paths),
        "failed_sample": failed_sample,
    }


def build_index(folder, force=False):
    from index_progress import clear_progress

    try:
        return _build_index(folder, force=force)
    finally:
        # Never leave stale active/cancelled progress after success or failure.
        clear_progress()


def build_index_all(folders, force=False):
    from index_progress import clear_progress, is_cancelled

    totals = {
        "chunks": 0,
        "updated": 0,
        "removed": 0,
        "skipped": 0,
        "failed": 0,
        "failed_sample": [],
    }
    try:
        for folder in folders:
            if is_cancelled():
                raise InterruptedError("Indexing cancelled")
            folder = _normalize_folder(folder)
            if os.path.isdir(folder):
                result = _build_index(folder, force=force)
                for key in ("chunks", "updated", "removed", "skipped", "failed"):
                    totals[key] += result.get(key, 0)
                for path in result.get("failed_sample") or []:
                    if len(totals["failed_sample"]) >= 8:
                        break
                    if path not in totals["failed_sample"]:
                        totals["failed_sample"].append(path)
        return totals
    finally:
        clear_progress()


def index_single_file(path):
    path = os.path.normpath(path)
    chunk_count = _index_file(path)

    from folders import get_folder_file_mtimes, set_folder_file_mtimes

    folder = _parent_indexed_folder(path)
    if folder:
        mtimes = get_folder_file_mtimes(folder)
        if chunk_count:
            try:
                mtimes[path] = os.path.getmtime(path)
            except OSError:
                pass
        else:
            mtimes.pop(path, None)
        set_folder_file_mtimes(folder, mtimes)