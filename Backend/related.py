import os

from lance_store import db, db_lock

TABLE_NAME = "documents"


def _escape_sql(value):
    return value.replace("'", "''")


def related_files(path, limit=8):
    path = os.path.normpath(path)
    with db_lock:
        if TABLE_NAME not in db.table_names():
            return []
        table = db.open_table(TABLE_NAME)
        arrow = table.to_arrow()
        paths = arrow.column("path").to_pylist()
        vectors = arrow.column("vector").to_pylist()

        source_vector = None
        for idx, candidate in enumerate(paths):
            if candidate == path:
                source_vector = vectors[idx]
                break

        if source_vector is None:
            return []

        hits = table.search(source_vector).limit(limit + 12).to_list()
    seen = set()
    related = []
    for item in hits:
        hit_path = item.get("path")
        if not hit_path or hit_path == path or hit_path in seen:
            continue
        seen.add(hit_path)
        distance = item.get("_distance", 0)
        score = 1 / (distance + 1)
        related.append({
            "path": hit_path,
            "file_name": item.get("file_name") or os.path.basename(hit_path),
            "final_score": score,
            "match_snippet": item.get("content", "")[:140],
        })
        if len(related) >= limit:
            break

    return related
