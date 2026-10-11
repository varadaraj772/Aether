#!/usr/bin/env python3
"""JSON-line RPC bridge for the Aether Swift UI."""

import json
import os
import sys
import threading
import uuid

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

AETHER_DIR = os.environ.get("AETHER_DIR", os.path.join(os.path.expanduser("~"), ".aether"))
DB_DIR = os.path.join(AETHER_DIR, "db")
os.makedirs(DB_DIR, exist_ok=True)
os.chdir(DB_DIR)

# Keep stdout clean for JSON-RPC - model/transformers logs must not land here.
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("TRANSFORMERS_VERBOSITY", "error")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

_index_lock = threading.Lock()
_index_thread = None
_index_result = None
_index_error = None
_index_done = False
_index_cancelled = False
_index_state = "idle"
_index_job_id = None
_stdout_gate_installed = False
_rpc_stdout = sys.stdout
_rpc_stdout_lock = threading.Lock()

# Convert a state left by a previously terminated backend into an explicit
# recoverable state before accepting a new request.
from index_progress import recover_interrupted_job
_recovered_job = recover_interrupted_job()
_index_state = _recovered_job.get("state", "idle") or "idle"


class _RPCStdout:
    """Keep every incidental print away from the JSON-lines protocol."""

    def write(self, data):
        return sys.__stderr__.write(data)

    def flush(self):
        try:
            sys.__stderr__.flush()
        except Exception:
            pass

    def fileno(self):
        return sys.__stderr__.fileno()

    def isatty(self):
        return sys.__stderr__.isatty()

    def __getattr__(self, name):
        return getattr(sys.__stderr__, name)


def _ensure_stdout_gate():
    global _stdout_gate_installed
    if _stdout_gate_installed:
        return
    if not isinstance(sys.stdout, _RPCStdout):
        sys.stdout = _RPCStdout()
    _stdout_gate_installed = True


def _emit_response(response):
    payload = json.dumps(response, default=_json_default) + "\n"
    with _rpc_stdout_lock:
        _rpc_stdout.write(payload)
        _rpc_stdout.flush()


def _json_default(value):
    if hasattr(value, "item"):
        try:
            return value.item()
        except Exception:
            pass
    if hasattr(value, "tolist"):
        return value.tolist()
    raise TypeError(f"Object of type {type(value)} is not JSON serializable")


def _index_is_active():
    global _index_thread
    with _index_lock:
        return _index_thread is not None and _index_thread.is_alive()


def _start_index_job(target, *args, **kwargs):
    """Run indexing in a daemon thread. Returns immediately with async ack."""
    global _index_thread, _index_result, _index_error, _index_done, _index_cancelled, _index_state, _index_job_id

    _ensure_stdout_gate()

    def worker():
        global _index_thread, _index_result, _index_error, _index_done, _index_cancelled, _index_state, _index_job_id
        from index_progress import finish_job
        try:
            result = target(*args, **kwargs)
            with _index_lock:
                _index_result = result
                _index_error = None
                _index_cancelled = False
                _index_done = True
                _index_state = "completed"
                finish_job("completed")
        except InterruptedError as exc:
            with _index_lock:
                _index_result = None
                _index_error = str(exc) or "Indexing cancelled"
                _index_cancelled = True
                _index_done = True
                _index_state = "cancelled"
                finish_job("cancelled", error=_index_error)
        except Exception as exc:
            with _index_lock:
                _index_result = None
                _index_error = str(exc)
                _index_cancelled = False
                _index_done = True
                _index_state = "failed"
                finish_job("failed", error=_index_error)
            print(f"INDEX ERROR: {exc}", file=sys.stderr)
        finally:
            with _index_lock:
                _index_thread = None

    thread = threading.Thread(target=worker, daemon=True, name="aether-index")
    with _index_lock:
        if _index_thread is not None:
            raise ValueError("Indexing already in progress")
        from index_progress import clear_progress, start_job

        clear_progress()
        _index_result = None
        _index_error = None
        _index_done = False
        _index_cancelled = False
        _index_state = "running"
        _index_job_id = uuid.uuid4().hex
        start_job(_index_job_id, operation=getattr(target, "__name__", "index"))
        _index_thread = thread
        thread.start()
    return {"started": True, "async": True}


def _index_status():
    """Poll async index job. Clears result/error after one successful done read."""
    global _index_result, _index_error, _index_done, _index_cancelled, _index_state

    with _index_lock:
        active = _index_thread is not None
        done = _index_done and not active
        result = _index_result
        error = _index_error
        cancelled = _index_cancelled
        state = _index_state
        if done:
            # Consume completion so subsequent polls are idle until next index.
            _index_result = None
            _index_error = None
            _index_done = False
            _index_cancelled = False
            _index_state = "idle"
        return {
            "active": active,
            "done": done,
            "result": result,
            "error": error,
            "cancelled": cancelled,
            "state": state,
        }


def _cancel_index():
    """Request cancellation only while a job can consume the request."""
    with _index_lock:
        if _index_thread is None:
            return {"ok": True, "accepted": False}
        from index_progress import request_cancel

        request_cancel()
        return {"ok": True, "accepted": True}


def handle(request):
    """Dispatch JSON-RPC commands.

    Commands:
      ping, warmup, search, preview, related, duplicates,
      index_folder, index_all, index_status, index_progress, cancel_index, index_file,
      load_config, load_folders, save_folder, remove_folder,
      save_excluded_dirs, delete_file, delete_folder, folder_stats,
      folder_is_indexed, recent_searches, saved_searches

    Async indexing note (Swift):
      index_folder / index_all return immediately:
        {"started": true, "async": true}
      Poll index_status for:
        {"active": bool, "done": bool, "result": IndexStats|null, "error": str|null}
      When done=true, result is IndexStats
      (chunks/updated/removed/skipped/failed/failed_sample) or error is set.
      cancel_index and index_progress still work via progress files.
    """
    cmd = request.get("cmd")
    args = request.get("args", {})

    if cmd == "ping":
        return {"ok": True}

    if cmd == "warmup":
        from models import warmup_model

        return warmup_model()

    if cmd == "search":
        query = args.get("query", "").strip()
        if len(query) < 2:
            return []
        from search import search

        folder = args.get("folder")
        file_type = args.get("file_type")
        recent_paths = args.get("recent_paths") or []
        if not isinstance(recent_paths, list):
            recent_paths = []
        recent_items = args.get("recent_items") or []
        if not isinstance(recent_items, list):
            recent_items = []
        search_args = {
            "folder": folder,
            "recent_paths": recent_paths,
            "recent_items": recent_items,
        }
        if isinstance(file_type, str) and file_type:
            search_args["file_type"] = file_type
        results = search(query, **search_args)
        for item in results:
            item.pop("vector", None)
        return results

    if cmd == "index_folder":
        from indexer import build_index

        folder = args["folder"]
        force = bool(args.get("force", False))
        return _start_index_job(build_index, folder, force=force)

    if cmd == "index_all":
        from indexer import build_index_all

        folders = args.get("folders", [])
        force = bool(args.get("force", False))
        return _start_index_job(build_index_all, folders, force=force)

    if cmd == "index_status":
        return _index_status()

    if cmd == "index_progress":
        from index_progress import get_progress

        return get_progress()

    if cmd == "cancel_index":
        return _cancel_index()

    if cmd == "load_config":
        from folders import (
            load_folders,
            load_recent_searches,
            load_saved_searches,
            load_excluded_dir_names_optional,
        )

        payload = {
            "folders": load_folders(),
            "recent_searches": load_recent_searches(),
            "saved_searches": load_saved_searches(),
        }
        excluded = load_excluded_dir_names_optional()
        if excluded is not None:
            payload["excluded_dir_names"] = sorted(excluded, key=str.lower)
        return payload

    if cmd == "save_excluded_dirs":
        from folders import save_excluded_dir_names

        names = args.get("names", [])
        return {"excluded_dir_names": save_excluded_dir_names(names)}

    if cmd == "index_file":
        from indexer import index_single_file

        return {"chunks": index_single_file(args["path"])}

    if cmd == "delete_file":
        from indexer import delete_file_from_index

        delete_file_from_index(args["path"])
        return {"ok": True}

    if cmd == "delete_folder":
        from indexer import delete_folder_from_index

        delete_folder_from_index(args["folder"])
        return {"ok": True}

    if cmd == "folder_stats":
        from indexer import get_folder_stats

        return get_folder_stats(args["folder"])

    if cmd == "folder_is_indexed":
        from indexer import folder_is_indexed

        return {"indexed": folder_is_indexed(args["folder"])}

    if cmd == "preview":
        from preview import preview_file

        return {"content": preview_file(args["path"])}

    if cmd == "load_folders":
        from folders import load_folders

        return {"folders": load_folders()}

    if cmd == "save_folder":
        from folders import save_folder

        save_folder(args["folder"])
        return {"ok": True}

    if cmd == "remove_folder":
        from folders import remove_folder

        remove_folder(args["folder"])
        return {"ok": True}

    if cmd == "recent_searches":
        from folders import load_recent_searches, add_recent_search, remove_recent_search

        if args.get("delete"):
            remove_recent_search(args["delete"])
            return {"searches": load_recent_searches()}
        if args.get("add"):
            add_recent_search(args["add"])
        return {"searches": load_recent_searches()}

    if cmd == "saved_searches":
        from folders import load_saved_searches, save_saved_search, delete_saved_search

        if args.get("delete"):
            delete_saved_search(args["delete"])
            return {"ok": True}
        if args.get("name") and args.get("query"):
            save_saved_search(args["name"], args["query"])
            return {"ok": True}
        return {"searches": load_saved_searches()}

    if cmd == "related":
        from related import related_files

        return related_files(args["path"], limit=int(args.get("limit", 8)))

    if cmd == "duplicates":
        from duplicates import find_duplicates

        threshold = float(args.get("threshold", 0.92))
        max_files = int(args.get("max_files", 2000))
        return {
            "groups": find_duplicates(
                similarity_threshold=threshold,
                max_files=max_files,
            )
        }

    raise ValueError(f"Unknown command: {cmd}")


def main():
    _ensure_stdout_gate()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        request = None
        try:
            request = json.loads(line)
            data = handle(request)
            response = {"id": request.get("id"), "ok": True, "data": data}
        except Exception as exc:
            response = {
                "id": request.get("id") if isinstance(request, dict) else None,
                "ok": False,
                "error": str(exc),
            }
        _emit_response(response)
        if (
            os.environ.get("AETHER_TEST_EXIT_AFTER_START") == "1"
            and request.get("cmd") in {"index_folder", "index_all"}
        ):
            os._exit(75)


if __name__ == "__main__":
    main()
