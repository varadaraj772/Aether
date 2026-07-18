import os
import re
from datetime import datetime

from models import get_model
from lance_store import db, db_lock

# Tiny synonym map for keyword scoring only (embeddings keep the raw query).
_SYNONYMS = {
    "invoice": ("receipt", "bill"),
    "receipt": ("invoice", "bill"),
    "bill": ("invoice", "receipt"),
    "resume": ("cv",),
    "cv": ("resume",),
    "photo": ("image", "picture"),
    "image": ("photo", "picture"),
    "picture": ("photo", "image"),
    "todo": ("task",),
    "task": ("todo",),
    "meeting": ("notes",),
    "notes": ("meeting",),
}

_PATH_BOOST = 0.12
_RECENT_BOOST = 0.08


def _match_snippet(content, query, length=140):
    words = [w for w in query.lower().split() if w]
    if not words:
        return content[:length].replace("\n", " ")

    content_lower = content.lower()
    pos = -1
    for word in words:
        pos = content_lower.find(word)
        if pos >= 0:
            break

    if pos < 0:
        return content[:length].replace("\n", " ")

    start = max(0, pos - 50)
    excerpt = content[start : start + length].replace("\n", " ")
    prefix = "…" if start > 0 else ""
    suffix = "…" if start + length < len(content) else ""
    return prefix + excerpt + suffix


def _path_in_folder(path, folder):
    folder = os.path.normpath(folder.rstrip(os.sep)) or folder
    path = os.path.normpath(path)
    return path == folder or path.startswith(folder + os.sep)


def _tokens(value):
    return re.findall(r"[\w]+", value.lower(), flags=re.UNICODE)


def _expand_tokens(tokens):
    """Expand query tokens with synonyms for keyword scoring only."""
    expanded = []
    seen = set()
    for token in tokens:
        if token not in seen:
            expanded.append(token)
            seen.add(token)
        for syn in _SYNONYMS.get(token, ()):
            if syn not in seen:
                expanded.append(syn)
                seen.add(syn)
    return expanded


def _metadata_timestamp(item):
    """Use existing metadata only; never stat result paths during ranking."""
    for key in ("mtime", "modified_at", "modified", "updated_at"):
        value = item.get(key)
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str) and value:
            try:
                return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
            except ValueError:
                continue
    return None


def _synonym_set(token):
    return {token, *_SYNONYMS.get(token, ())}


def _path_segment_score(item, query_tokens):
    """Mild boost when query tokens appear in parent path segments."""
    if not query_tokens:
        return 0.0
    path = item.get("path", "")
    parent = os.path.dirname(path)
    if not parent:
        return 0.0
    parent_folded = parent.casefold()
    segment_tokens = set(_tokens(parent))
    if not segment_tokens and not parent_folded:
        return 0.0

    hits = 0
    for token in query_tokens:
        candidates = _synonym_set(token)
        if any(candidate in parent_folded for candidate in candidates):
            hits += 1
            continue
        if any(
            any(
                seg == candidate or seg.startswith(candidate) or candidate.startswith(seg)
                for seg in segment_tokens
            )
            for candidate in candidates
        ):
            hits += 1
    return _PATH_BOOST * (hits / len(query_tokens))


def _recent_path_score(item, recent_paths):
    if not recent_paths:
        return 0.0
    path = os.path.normpath(item.get("path", ""))
    return _RECENT_BOOST if path in recent_paths else 0.0


def _token_satisfied(query_token, haystack_tokens, *, prefix=False):
    """True if query token or any synonym matches haystack tokens."""
    for candidate in _synonym_set(query_token):
        if candidate in haystack_tokens:
            return True
        if prefix and any(file_token.startswith(candidate) for file_token in haystack_tokens):
            return True
    return False


def _lexical_scores(item, query):
    query_normalized = query.strip().casefold()
    query_tokens = _tokens(query)
    file_name = (item.get("file_name") or os.path.basename(item.get("path", ""))).casefold()
    stem = os.path.splitext(file_name)[0]
    file_tokens = _tokens(stem)
    content_tokens = set(_tokens(item.get("content", "")))

    exact = 1.0 if query_normalized and query_normalized in (file_name, stem) else 0.0
    if query_tokens:
        token_matches = sum(
            1 for query_token in query_tokens
            if _token_satisfied(query_token, file_tokens)
        ) / len(query_tokens)
        prefix_matches = sum(
            1 for query_token in query_tokens
            if _token_satisfied(query_token, file_tokens, prefix=True)
        ) / len(query_tokens)
        content_matches = sum(
            1 for query_token in query_tokens
            if _token_satisfied(query_token, content_tokens)
        ) / len(query_tokens)
    else:
        token_matches = prefix_matches = content_matches = 0.0

    # Exact filename/stem dominates. Token matches outrank prefixes, and
    # content matches remain a bounded, conservative signal.
    filename_score = (token_matches * 0.55) + (prefix_matches * 0.30)
    content_score = content_matches * 0.25
    return exact, filename_score, content_score


def search(query, folder=None, recent_paths=None):
    model = get_model()
    # Embed the raw query so synonym expansion does not dilute semantics.
    vector = model.encode(query, show_progress_bar=False).tolist()
    query_tokens = _tokens(query)
    recent_set = {
        os.path.normpath(p)
        for p in (recent_paths or [])
        if isinstance(p, str) and p
    }

    # Lock only the LanceDB read itself. Index extraction/embedding happens
    # concurrently, and search waits only for a short table mutation.
    with db_lock:
        if "documents" not in db.table_names():
            return []
        table = db.open_table("documents")
        results = table.search(vector).limit(100).to_list()

    for item in results:
        distance = max(float(item.get("_distance", 0) or 0), 0.0)
        semantic_score = 1 / (distance + 1)
        # Keyword path uses synonym satisfaction; embedding query stays raw.
        exact_score, filename_score, content_score = _lexical_scores(item, query)
        path_score = _path_segment_score(item, query_tokens)
        recent_score = _recent_path_score(item, recent_set)
        keyword_score = exact_score + filename_score + content_score + path_score

        item["semantic_score"] = semantic_score
        item["keyword_score"] = keyword_score
        item["path_score"] = path_score
        item["recent_score"] = recent_score
        item["final_score"] = (
            (exact_score * 2.0)
            + filename_score
            + content_score
            + path_score
            + recent_score
            + (semantic_score * 0.55)
        )
        item["match_snippet"] = _match_snippet(item.get("content", ""), query)

    timestamps = [_metadata_timestamp(item) for item in results]
    timestamps = [value for value in timestamps if value is not None]
    if timestamps:
        newest = max(timestamps)
        thirty_days = 30 * 24 * 60 * 60
        for item in results:
            timestamp = _metadata_timestamp(item)
            if timestamp is not None:
                age = max(0.0, newest - timestamp)
                item["recency_score"] = 0.05 * max(0.0, 1.0 - (age / thirty_days))
                item["final_score"] += item["recency_score"]

    if folder:
        results = [item for item in results if _path_in_folder(item.get("path", ""), folder)]

    seen_files = {}
    for item in results:
        path = item["path"]
        if path not in seen_files or item["final_score"] > seen_files[path]["final_score"]:
            seen_files[path] = item

    return sorted(
        seen_files.values(),
        key=lambda item: (-item["final_score"], item.get("path", ""), item.get("chunk_id", 0)),
    )
