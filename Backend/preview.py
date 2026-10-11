import os

from indexer import extract_text


def preview_file(path):
    if not os.path.exists(path):
        return ""
    try:
        return extract_text(path)
    except Exception:
        return ""
