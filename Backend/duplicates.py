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


def find_duplicates(similarity_threshold=0.92, max_files=DEFAULT_MAX_FILES):
    max_files = max(1, int(max_files))

    with db_lock:
        if TABLE_NAME not in db.table_names():
            return []
        table = db.open_table(TABLE_NAME)
        arrow = table.to_arrow()
        paths = arrow.column("path").to_pylist()
        contents = arrow.column("content").to_pylist()
        vectors = arrow.column("vector").to_pylist()
        file_names = arrow.column("file_name").to_pylist()

    by_file = {}
    for idx, path in enumerate(paths):
        if path in by_file:
            continue
        by_file[path] = {
            "path": path,
            "file_name": file_names[idx],
            "content": contents[idx] or "",
            "vector": vectors[idx],
        }

    all_files = list(by_file.values())
    files = all_files[:max_files]
    if len(all_files) > max_files:
        _progress(
            f"DUPLICATES: capping at {max_files} of {len(all_files)} indexed files"
        )
    else:
        _progress(f"DUPLICATES: scanning {len(files)} files")

    # Exact duplicates via content fingerprint (batched for progress).
    fingerprint_groups = defaultdict(list)
    for start in range(0, len(files), BATCH_SIZE):
        batch = files[start : start + BATCH_SIZE]
        for item in batch:
            snippet = item["content"][:800].strip().lower()
            if len(snippet) < 40:
                continue
            fp = hashlib.sha256(snippet.encode("utf-8", errors="ignore")).hexdigest()
            fingerprint_groups[fp].append(item)
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

    # Near-duplicates via embedding similarity (first chunk per file).
    remaining = [f for f in files if f["path"] not in used]
    _progress(f"DUPLICATES: near-duplicate pass over {len(remaining)} files")
    for i, left in enumerate(remaining):
        if left["path"] in used:
            continue
        if i > 0 and i % BATCH_SIZE == 0:
            _progress(f"DUPLICATES: near-dup {i}/{len(remaining)}")
        cluster = [left]
        for right in remaining[i + 1 :]:
            if right["path"] in used:
                continue
            sim = _cosine(left["vector"], right["vector"])
            if sim >= similarity_threshold:
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
