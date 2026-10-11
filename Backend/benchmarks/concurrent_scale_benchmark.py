"""Measure backend responsiveness while real indexing is active."""

import argparse
import json
import os
import platform
import resource
import shutil
import statistics
import sys
import tempfile
import threading
import time
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))


def _summary(samples):
    if not samples:
        return {"samples": 0, "median_seconds": None, "p95_seconds": None, "max_seconds": None, "errors": 0}
    ordered = sorted(samples)
    p95_index = min(len(ordered) - 1, max(0, int(len(ordered) * 0.95) - 1))
    return {
        "samples": len(samples),
        "median_seconds": statistics.median(ordered),
        "p95_seconds": ordered[p95_index],
        "max_seconds": max(ordered),
        "errors": 0,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--files", type=int, default=500)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    state_dir = None
    with tempfile.TemporaryDirectory(prefix="aether-concurrent-") as raw:
        root = Path(raw)
        state_dir = root.parent / f"{root.name}-state"
        os.environ["AETHER_DIR"] = str(state_dir)
        os.environ["AETHER_PROFILE_INDEX"] = "1"
        for index in range(args.files):
            (root / f"document-{index:06d}.txt").write_text(
                f"Synthetic concurrent document {index}. Search and retrieval content.\n" * 4,
                encoding="utf-8",
            )

        from duplicates import find_duplicates
        from indexer import build_index, folder_is_indexed, get_folder_stats, get_index_profile, reset_index_profile
        from models import get_model
        from related import related_files
        from search import search
        from lance_store import db_lock

        cold_started = time.perf_counter()
        get_model()
        cold_model_seconds = time.perf_counter() - cold_started
        reset_index_profile()
        db_lock.reset_profile()
        sample_path = str(root / "document-000000.txt")
        stop = threading.Event()
        lock = threading.Lock()
        measurements = {name: [] for name in ("search", "folder_stats", "indexed_path", "related", "near_duplicates")}
        errors = {name: 0 for name in measurements}
        correctness = {"invalid_search_paths": 0, "invalid_related_paths": 0}

        def measure(name, operation):
            while not stop.is_set():
                started = time.perf_counter()
                try:
                    result = operation()
                    if name == "search":
                        for item in result:
                            if not isinstance(item.get("path"), str):
                                correctness["invalid_search_paths"] += 1
                    elif name == "related":
                        for item in result:
                            if not isinstance(item.get("path"), str):
                                correctness["invalid_related_paths"] += 1
                except Exception:
                    with lock:
                        errors[name] += 1
                elapsed = time.perf_counter() - started
                with lock:
                    measurements[name].append(elapsed)

        operations = {
            "search": lambda: search("concurrent retrieval content", folder=str(root)),
            "folder_stats": lambda: get_folder_stats(str(root)),
            "indexed_path": lambda: folder_is_indexed(str(root)),
            "related": lambda: related_files(sample_path, limit=8),
            "near_duplicates": lambda: find_duplicates(max_files=args.files),
        }
        workers = [threading.Thread(target=measure, args=(name, operation), daemon=True) for name, operation in operations.items()]
        for worker in workers:
            worker.start()
        started = time.perf_counter()
        result = build_index(str(root), force=True)
        indexing_seconds = time.perf_counter() - started
        stop.set()
        for worker in workers:
            worker.join(timeout=30)

        report = {
            "synthetic": True,
            "files_requested": args.files,
            "index_result": result,
            "indexing_seconds": indexing_seconds,
            "files_per_second": args.files / indexing_seconds if indexing_seconds else 0,
            "cold_model_start_seconds": cold_model_seconds,
            "operation_latency_seconds": {name: _summary(values) for name, values in measurements.items()},
            "operation_errors": errors,
            "correctness": correctness,
            "index_profile": get_index_profile(),
            "db_lock_profile": db_lock.snapshot_profile(),
            "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
            "python": platform.python_version(),
            "platform": platform.platform(),
            "embedding_batch_size": int(os.environ.get("AETHER_EMBED_BATCH_SIZE", "16")),
            "methodology": "isolated temporary corpus and AETHER_DIR; real local model and LanceDB; five concurrent operation workers run until force indexing completes; operation latency includes database lock wait",
        }
    rendered = json.dumps(report, indent=2, sort_keys=True)
    if args.output:
        args.output.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)
    if state_dir:
        shutil.rmtree(state_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
