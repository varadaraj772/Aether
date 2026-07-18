import json
import os
import shutil
from datetime import datetime, timezone

CONFIG_DIR = os.path.join(os.path.expanduser("~"), ".aether")
CONFIG_FILE = os.path.join(CONFIG_DIR, "folders.json")
LEGACY_CONFIG_FILE = "folders.json"


def _ensure_config_dir():
    os.makedirs(CONFIG_DIR, exist_ok=True)
    if os.path.exists(LEGACY_CONFIG_FILE) and not os.path.exists(CONFIG_FILE):
        shutil.copy2(LEGACY_CONFIG_FILE, CONFIG_FILE)


def _normalize_folder(folder):
    return os.path.normpath(folder.rstrip(os.sep)) or folder


DEFAULT_EXCLUDED_DIR_NAMES = [
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
]


def _load_data():
    _ensure_config_dir()
    if not os.path.exists(CONFIG_FILE):
        return {
            "folders": [],
            "meta": {},
            "recent_searches": [],
            "saved_searches": [],
            "excluded_dir_names": list(DEFAULT_EXCLUDED_DIR_NAMES),
        }
    try:
        with open(CONFIG_FILE) as f:
            data = json.load(f)
        excluded = data.get("excluded_dir_names")
        if excluded is None:
            excluded = list(DEFAULT_EXCLUDED_DIR_NAMES)
        return {
            "folders": [_normalize_folder(f) for f in data.get("folders", []) if f],
            "meta": data.get("meta", {}),
            "recent_searches": data.get("recent_searches", []),
            "saved_searches": data.get("saved_searches", []),
            "excluded_dir_names": [n for n in excluded if isinstance(n, str) and n.strip()],
        }
    except Exception:
        return {
            "folders": [],
            "meta": {},
            "recent_searches": [],
            "saved_searches": [],
            "excluded_dir_names": list(DEFAULT_EXCLUDED_DIR_NAMES),
        }


def _save_data(
    folders,
    meta,
    recent_searches=None,
    saved_searches=None,
    excluded_dir_names=None,
):
    _ensure_config_dir()
    data = _load_data()
    payload = {"folders": folders, "meta": meta}
    payload["recent_searches"] = (
        recent_searches if recent_searches is not None else data.get("recent_searches", [])
    )
    payload["saved_searches"] = (
        saved_searches if saved_searches is not None else data.get("saved_searches", [])
    )
    payload["excluded_dir_names"] = (
        excluded_dir_names
        if excluded_dir_names is not None
        else data.get("excluded_dir_names", list(DEFAULT_EXCLUDED_DIR_NAMES))
    )
    with open(CONFIG_FILE, "w") as f:
        json.dump(payload, f, indent=2)


def save_folder(folder):
    folder = _normalize_folder(folder)
    data = _load_data()
    if folder not in data["folders"]:
        data["folders"].append(folder)
    _save_data(data["folders"], data["meta"])


def remove_folder(folder):
    folder = _normalize_folder(folder)
    data = _load_data()
    data["folders"] = [f for f in data["folders"] if f != folder]
    data["meta"].pop(folder, None)
    _save_data(data["folders"], data["meta"])


def load_folders():
    return _load_data()["folders"]


def get_folder_meta(folder):
    folder = _normalize_folder(folder)
    return _load_data()["meta"].get(folder, {})


def update_folder_meta(
    folder,
    *,
    file_count=0,
    chunk_count=0,
    skipped=0,
    last_index_failures=None,
):
    folder = _normalize_folder(folder)
    data = _load_data()
    prev = data["meta"].get(folder, {})
    entry = {
        "last_indexed": datetime.now(timezone.utc).isoformat(),
        "file_count": file_count,
        "chunk_count": chunk_count,
        "skipped": skipped,
        "file_mtimes": prev.get("file_mtimes", {}),
    }
    if last_index_failures is not None:
        entry["last_index_failures"] = list(last_index_failures)[:20]
    elif "last_index_failures" in prev:
        entry["last_index_failures"] = prev["last_index_failures"]
    data["meta"][folder] = entry
    _save_data(data["folders"], data["meta"])


def get_folder_file_mtimes(folder):
    folder = _normalize_folder(folder)
    return _load_data()["meta"].get(folder, {}).get("file_mtimes", {})


def set_folder_file_mtimes(folder, mtimes):
    folder = _normalize_folder(folder)
    data = _load_data()
    entry = data["meta"].get(folder, {})
    entry["file_mtimes"] = mtimes
    data["meta"][folder] = entry
    _save_data(data["folders"], data["meta"])


def load_recent_searches():
    return _load_data().get("recent_searches", [])


def add_recent_search(query):
    query = query.strip()
    if len(query) < 2:
        return
    data = _load_data()
    recent = [q for q in data.get("recent_searches", []) if q != query]
    recent.insert(0, query)
    data["recent_searches"] = recent[:10]
    _save_data(data["folders"], data["meta"], data["recent_searches"], data.get("saved_searches", []))


def remove_recent_search(query):
    query = query.strip()
    if not query:
        return
    data = _load_data()
    data["recent_searches"] = [q for q in data.get("recent_searches", []) if q != query]
    _save_data(data["folders"], data["meta"], data["recent_searches"], data.get("saved_searches", []))


def load_saved_searches():
    return _load_data().get("saved_searches", [])


def save_saved_search(name, query):
    name = name.strip()
    query = query.strip()
    if not name or not query:
        return
    data = _load_data()
    saved = [s for s in data.get("saved_searches", []) if s.get("name") != name]
    saved.insert(0, {"name": name, "query": query})
    data["saved_searches"] = saved[:20]
    _save_data(data["folders"], data["meta"], data.get("recent_searches", []), data["saved_searches"])


def delete_saved_search(name):
    data = _load_data()
    data["saved_searches"] = [
        s for s in data.get("saved_searches", []) if s.get("name") != name
    ]
    _save_data(data["folders"], data["meta"], data.get("recent_searches", []), data["saved_searches"])


def load_excluded_dir_names():
    names = _load_data().get("excluded_dir_names")
    if not names:
        return set(DEFAULT_EXCLUDED_DIR_NAMES)
    return {n.strip() for n in names if isinstance(n, str) and n.strip()}


def load_excluded_dir_names_optional():
    """Return persisted excludes, or None if the config never stored them."""
    _ensure_config_dir()
    if not os.path.exists(CONFIG_FILE):
        return None
    try:
        with open(CONFIG_FILE) as f:
            data = json.load(f)
    except Exception:
        return None
    if "excluded_dir_names" not in data:
        return None
    names = data.get("excluded_dir_names") or []
    cleaned = [n.strip() for n in names if isinstance(n, str) and n.strip()]
    return cleaned


def save_excluded_dir_names(names):
    cleaned = []
    seen = set()
    for raw in names or []:
        if not isinstance(raw, str):
            continue
        name = raw.strip()
        if not name:
            continue
        key = name.lower()
        if key in seen:
            continue
        seen.add(key)
        cleaned.append(name)
    cleaned.sort(key=str.lower)
    data = _load_data()
    _save_data(
        data["folders"],
        data["meta"],
        data.get("recent_searches", []),
        data.get("saved_searches", []),
        cleaned,
    )
    return cleaned
