import json
import os
import sys
import threading

AETHER_DIR = os.path.join(os.path.expanduser("~"), ".aether")
PROGRESS_FILE = os.path.join(AETHER_DIR, "index_progress.json")
CANCEL_FILE = os.path.join(AETHER_DIR, "index_cancel.flag")

_lock = threading.Lock()
_cancel_requested = False


def _ensure_dir():
    os.makedirs(AETHER_DIR, exist_ok=True)


def clear_progress():
    global _cancel_requested
    with _lock:
        _cancel_requested = False
    for path in (PROGRESS_FILE, CANCEL_FILE):
        try:
            if os.path.exists(path):
                os.remove(path)
        except OSError:
            pass


def request_cancel():
    global _cancel_requested
    with _lock:
        _cancel_requested = True
    _ensure_dir()
    try:
        open(CANCEL_FILE, "a").close()
    except OSError:
        pass
    _write(active=True, cancelled=True)


def is_cancelled():
    with _lock:
        if _cancel_requested:
            return True
    return os.path.exists(CANCEL_FILE)


def set_progress(*, active, current=0, total=0, folder="", file=""):
    _write(active=active, current=current, total=total, folder=folder, file=file)


def get_progress():
    if not os.path.exists(PROGRESS_FILE):
        return {"active": False, "current": 0, "total": 0, "folder": "", "file": "", "cancelled": False}
    try:
        with open(PROGRESS_FILE) as f:
            return json.load(f)
    except Exception:
        return {"active": False, "current": 0, "total": 0, "folder": "", "file": "", "cancelled": False}


def _write(**payload):
    _ensure_dir()
    with _lock:
        if _cancel_requested or os.path.exists(CANCEL_FILE):
            payload["cancelled"] = True
        payload.setdefault("cancelled", False)
    try:
        with open(PROGRESS_FILE, "w") as f:
            json.dump(payload, f)
    except OSError:
        pass
    print(f"AETHER_PROGRESS:{json.dumps(payload)}", file=sys.stderr, flush=True)
