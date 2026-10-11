import hashlib
import os
import sys
from collections import defaultdict

import numpy as np
from lance_store import db, db_lock

TABLE_NAME = "documents"
DEFAULT_MAX_FILES = 2000
BATCH_SIZE = 200


def _cosine(a, b):
    a = np.asarray(a, dtype=np.float32)
    b = np.asarray(b, dtype=np.float32)
    denom = np.linalg.norm(a) * np.linalg.norm(b)
    if denom == 0:
        return 0.0
    return float(np.dot(a, b) / denom)


def _progress(message):
    print(message, file=sys.stderr, flush=True)


def _sha256_file(path, block_size=1024 * 1024):
    """Hash the complete file; a shared prefix is never an exact duplicate."""
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            while True:
                block = handle.read(block_size)
                if not block:
                    break
                digest.update(block)
    except (OSError, IOError):
        return None
    return digest.hexdigest()


def find_duplicates(similarity_threshold=0.92, max_files=DEFAULT_MAX_FILES):
    max_files = max(1, int(max_files))

    with db_lock:
        if TABLE_NAME not in db.table_names():
            return []
        table = db.open_table(TABLE_NAME)
        try:
            rows = table.search().select(["path", "file_name"]).limit(max_files).to_list()
        except Exception:
            rows = []
            try:
                rows = [
                    {key: row.get(key) for key in ("path", "file_name")}
                    for row in table.to_arrow().to_pylist()
                ]
            except Exception:
                return []

    by_file = {}
    for row in rows:
        path = row.get("path")
        if not path or path in by_file:
            continue
        by_file[path] = {
            "path": path,
            "file_name": row.get("file_name") or os.path.basename(path),
        }

    all_files = list(by_file.values())
    files = all_files[:max_files]
    if len(all_files) > max_files:
        _progress(
            f"DUPLICATES: capping at {max_files} of {len(all_files)} indexed files"
        )
    else:
        _progress(f"DUPLICATES: scanning {len(files)} files")

    # Exact duplicates via complete byte-level SHA-256. Empty files are valid
    # exact duplicates too; unreadable files are simply excluded from this
    # pass and remain eligible for near-duplicate retrieval if embedded.
    fingerprint_groups = defaultdict(list)
    for start in range(0, len(files), BATCH_SIZE):
        batch = files[start : start + BATCH_SIZE]
        for item in batch:
            fingerprint = _sha256_file(item["path"])
            if fingerprint is None:
                continue
            fingerprint_groups[fingerprint].append(item)
        _progress(
            f"DUPLICATES: fingerprint {min(start + BATCH_SIZE, len(files))}/{len(files)}"
        )

    groups = []
    used = set()

    for members in fingerprint_groups.values():
        if len(members) < 2:
            continue
        group_paths = [m["path"] for m in members]
        for p in group_paths:
            used.add(p)
        groups.append({
            "kind": "exact",
            "similarity": 1.0,
            "files": [
                {"path": m["path"], "file_name": m["file_name"]}
                for m in members
            ],
        })

    # Near-duplicates via vector candidate retrieval. We retrieve only a
    # bounded neighborhood for each document instead of comparing every pair.
    remaining = [f for f in files if f["path"] not in used]
    remaining_by_path = {item["path"]: item for item in remaining}
    _progress(f"DUPLICATES: near-duplicate pass over {len(remaining)} files")
    for i, left in enumerate(remaining):
        if left["path"] in used:
            continue
        # Hold the application lock for one source/candidate read only. The
        # previous implementation held it across the entire near-duplicate
        # pass, starving document replacement writes and other reads.
        with db_lock:
            table = db.open_table(TABLE_NAME) if TABLE_NAME in db.table_names() else None
            if table is None:
                break
            try:
                source = table.search().where(
                    f"path = '{left['path'].replace(chr(39), chr(39) * 2)}'"
                ).select(["vector"]).limit(1).to_list()
                if not source:
                    continue
                candidates = table.search(source[0]["vector"]).select(
                    ["path", "file_name", "_distance"]
                ).limit(24).to_list()
            except Exception:
                continue
        cluster = [left]
        candidate_paths = {
            item.get("path") for item in candidates
            if item.get("path") and item.get("path") != left["path"]
        }
        for candidate_path in candidate_paths:
            right = remaining_by_path.get(candidate_path)
            if right is None or right["path"] in used:
                continue
            # The vector index generated the candidate set. The distance
            # threshold is applied by the database result ordering; the
            # explicit pair check is retained only for compatibility with
            # older search implementations that omit distances.
            candidate = next((item for item in candidates if item.get("path") == right["path"]), None)
            distance = float(candidate.get("_distance", 1.0)) if candidate else 1.0
            if distance <= (1.0 - similarity_threshold):
                cluster.append(right)
                used.add(right["path"])
        if len(cluster) > 1:
            used.add(left["path"])
            groups.append({
                "kind": "near",
                "similarity": similarity_threshold,
                "files": [
                    {"path": m["path"], "file_name": m["file_name"]}
                    for m in cluster
                ],
            })
    groups.sort(key=lambda g: len(g["files"]), reverse=True)
    _progress(f"DUPLICATES: found {len(groups)} groups")
    return groups[:20]
