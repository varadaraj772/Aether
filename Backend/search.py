import math
import os
import re
import time
from datetime import datetime

from models import get_model
from lance_store import db, db_lock

# Conservative synonym groups for lexical/path/snippet scoring only.
# Embeddings keep the raw query so expansion does not dilute semantics.
_SYNONYM_GROUPS = (
    ("invoice", "receipt", "bill", "expense"),
    ("meeting", "notes", "minutes", "agenda"),
    ("resume", "cv", "résumé"),
    ("photo", "image", "picture", "screenshot"),
    ("todo", "task", "checklist"),
    ("contract", "agreement"),
    ("tax", "return"),
    ("bug", "issue", "error"),
    ("docs", "documentation"),
)


def _build_synonym_map(groups):
    mapping = {}
    for group in groups:
        normalized = []
        seen = set()
        for raw in group:
            token = raw.casefold()
            if token and token not in seen:
                normalized.append(token)
                seen.add(token)
        for token in normalized:
            mapping[token] = tuple(other for other in normalized if other != token)
    return mapping


_SYNONYMS = _build_synonym_map(_SYNONYM_GROUPS)

_PATH_BOOST = 0.12
_RECENT_MAX_BOOST = 0.10
_FILENAME_COMPLETE_BONUS = 0.12
_CONTENT_WEIGHT = 0.25
_FILENAME_TOKEN_WEIGHT = 0.55
_FILENAME_PREFIX_WEIGHT = 0.30
_EXACT_WEIGHT = 2.0
_SEMANTIC_WEIGHT = 0.55
_MTIME_MAX_BOOST = 0.05
_RECENT_HALF_LIFE_DAYS = 14.0


def _match_snippet(content, query, length=140):
    """Prefer original query terms, then conservative synonyms, for snippet anchors."""
    content_lower = content.lower()
    query_tokens = _tokens(query)
    search_terms = []
    seen = set()
    for token in query_tokens:
        for candidate in (token, *_SYNONYMS.get(token, ())):
            if candidate not in seen:
                search_terms.append(candidate)
                seen.add(candidate)

    pos = -1
    for term in search_terms:
        pos = content_lower.find(term)
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
    """Mild boost when query tokens match parent path tokens (not substrings)."""
    if not query_tokens:
        return 0.0
    path = item.get("path", "")
    parent = os.path.dirname(path)
    if not parent:
        return 0.0
    segment_tokens = set(_tokens(parent))
    if not segment_tokens:
        return 0.0

    hits = 0
    for token in query_tokens:
        candidates = _synonym_set(token)
        if any(
            any(
                seg == candidate
                or (len(candidate) >= 3 and seg.startswith(candidate))
                for seg in segment_tokens
            )
            for candidate in candidates
        ):
            hits += 1
    return _PATH_BOOST * (hits / len(query_tokens))


def _parse_recent_items(recent_items=None, recent_paths=None):
    """Normalize recent_items / legacy recent_paths into ranking records."""
    records = []
    seen = set()

    if isinstance(recent_items, list):
        for raw in recent_items:
            if not isinstance(raw, dict):
                continue
            path = raw.get("path")
            if not isinstance(path, str) or not path.strip():
                continue
            norm = os.path.normpath(path)
            if norm in seen:
                continue
            try:
                open_count = max(1, int(raw.get("open_count", 1) or 1))
            except (TypeError, ValueError):
                open_count = 1
            try:
                last_opened_at = float(raw.get("last_opened_at", 0) or 0)
            except (TypeError, ValueError):
                last_opened_at = 0.0
            if last_opened_at <= 0:
                last_opened_at = time.time()
            records.append(
                {
                    "path": norm,
                    "open_count": open_count,
                    "last_opened_at": last_opened_at,
                }
            )
            seen.add(norm)

    if not records and isinstance(recent_paths, list):
        now = time.time()
        for index, path in enumerate(recent_paths):
            if not isinstance(path, str) or not path.strip():
                continue
            norm = os.path.normpath(path)
            if norm in seen:
                continue
            records.append(
                {
                    "path": norm,
                    "open_count": 1,
                    "last_opened_at": now - float(index),
                }
            )
            seen.add(norm)

    return records


def _recent_path_score(item, recent_records, *, now=None):
    """Bounded decayed usage boost from open history."""
    if not recent_records:
        return 0.0
    path = os.path.normpath(item.get("path", ""))
    record = next((entry for entry in recent_records if entry["path"] == path), None)
    if record is None:
        return 0.0

    now = time.time() if now is None else now
    age_days = max(0.0, (now - float(record["last_opened_at"])) / 86400.0)
    half_life = _RECENT_HALF_LIFE_DAYS
    time_factor = 0.5 ** (age_days / half_life)
    count_factor = min(1.0, math.log1p(max(1, int(record["open_count"]))) / math.log1p(10))
    return _RECENT_MAX_BOOST * time_factor * (0.55 + 0.45 * count_factor)


def _token_satisfied(query_token, haystack_tokens, *, prefix=False):
    """True if query token or any synonym matches haystack tokens."""
    for candidate in _synonym_set(query_token):
        if candidate in haystack_tokens:
            return True
        if (
            prefix
            and len(candidate) >= 3
            and any(file_token.startswith(candidate) for file_token in haystack_tokens)
        ):
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
        complete_bonus = _FILENAME_COMPLETE_BONUS if token_matches >= 1.0 else 0.0
    else:
        token_matches = prefix_matches = content_matches = 0.0
        complete_bonus = 0.0

    # Exact filename/stem dominates. Complete token coverage outranks prefixes.
    filename_score = (
        (token_matches * _FILENAME_TOKEN_WEIGHT)
        + (prefix_matches * _FILENAME_PREFIX_WEIGHT)
        + complete_bonus
    )
    content_score = content_matches * _CONTENT_WEIGHT
    return exact, filename_score, content_score


def search(query, folder=None, recent_paths=None, recent_items=None):
    model = get_model()
    # Embed the raw query so synonym expansion does not dilute semantics.
    vector = model.encode(query, show_progress_bar=False).tolist()
    query_tokens = _tokens(query)
    recent_records = _parse_recent_items(recent_items=recent_items, recent_paths=recent_paths)
    now = time.time()

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
        recent_score = _recent_path_score(item, recent_records, now=now)
        keyword_score = exact_score + filename_score + content_score + path_score

        item["semantic_score"] = semantic_score
        item["keyword_score"] = keyword_score
        item["path_score"] = path_score
        item["recent_score"] = recent_score
        item["final_score"] = (
            (exact_score * _EXACT_WEIGHT)
            + filename_score
            + content_score
            + path_score
            + recent_score
            + (semantic_score * _SEMANTIC_WEIGHT)
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
                item["recency_score"] = _MTIME_MAX_BOOST * max(0.0, 1.0 - (age / thirty_days))
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
