"""Reproducible synthetic indexing benchmark.

This is intentionally separate from unit tests. It creates a temporary corpus,
uses the real indexer/model, and reports measured timings. It does not claim a
scale target passed unless the command is actually run on the target machine.
"""
import argparse
import json
import os
import platform
import resource
import shutil
import sys
import tempfile
import time
import tracemalloc
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--files", type=int, default=1000)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="aether-benchmark-") as raw:
        root = Path(raw)
        state_dir = root.parent / f"{root.name}-state"
        os.environ["AETHER_DIR"] = str(state_dir)
        os.environ["AETHER_PROFILE_INDEX"] = "1"
        for index in range(args.files):
            (root / f"document-{index:06d}.txt").write_text(
                f"Synthetic document {index}. Retrieval benchmark content.\n" * 4,
                encoding="utf-8",
            )
        from indexer import (
            build_index,
            folder_is_indexed,
            get_folder_stats,
            get_index_profile,
            reset_index_profile,
        )
        from related import related_files
        from duplicates import find_duplicates
        from models import get_model
        from lance_store import db_lock

        tracemalloc.start()
        db_lock.reset_profile()
        cold_started = time.perf_counter()
        get_model()
        cold_start = time.perf_counter() - cold_started
        _cold_current, cold_peak_python = tracemalloc.get_traced_memory()
        cold_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        tracemalloc.stop()
        tracemalloc.start()
        reset_index_profile()
        started = time.perf_counter()
        result = build_index(str(root), force=True)
        elapsed = time.perf_counter() - started
        index_profile = get_index_profile()
        _warm_current, warm_peak_python = tracemalloc.get_traced_memory()
        warm_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        sample_path = str(root / "document-000000.txt")
        related_started = time.perf_counter()
        related_result = related_files(sample_path, limit=8)
        related_latency = time.perf_counter() - related_started
        duplicate_started = time.perf_counter()
        duplicate_result = find_duplicates(max_files=args.files)
        duplicate_latency = time.perf_counter() - duplicate_started
        stats_started = time.perf_counter()
        stats = get_folder_stats(str(root))
        stats_latency = time.perf_counter() - stats_started
        indexed_started = time.perf_counter()
        indexed = folder_is_indexed(str(root))
        indexed_latency = time.perf_counter() - indexed_started
        _current, peak = tracemalloc.get_traced_memory()
        tracemalloc.stop()
        report = {
            "synthetic": True,
            "files_requested": args.files,
            "index_result": result,
            "elapsed_seconds": elapsed,
            "cold_model_start_seconds": cold_start,
            "cold_model_peak_python_bytes": cold_peak_python,
            "rss_after_cold_model_bytes": cold_rss,
            "rss_after_index_bytes": warm_rss,
            "rss_delta_after_index_bytes": max(0, warm_rss - cold_rss),
            "warm_index_peak_python_bytes": warm_peak_python,
            "index_profile": index_profile,
            "db_lock_profile": db_lock.snapshot_profile(),
            "embedding_call_count": index_profile.get("embedding_calls", 0),
            "embedding_average_batch_utilization": (
                index_profile.get("embedding_texts", 0) / index_profile.get("embedding_calls", 1)
                if index_profile.get("embedding_calls", 0) else 0
            ),
            "files_per_second": args.files / elapsed if elapsed else 0,
            "related_latency_seconds": related_latency,
            "related_result_count": len(related_result),
            "near_duplicate_latency_seconds": duplicate_latency,
            "duplicate_group_count": len(duplicate_result),
            "folder_stats_latency_seconds": stats_latency,
            "folder_stats": stats,
            "folder_is_indexed_latency_seconds": indexed_latency,
            "folder_is_indexed": indexed,
            "peak_python_bytes": peak,
            "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
            "python": platform.python_version(),
            "platform": platform.platform(),
            "embedding_batch_size": int(os.environ.get("AETHER_EMBED_BATCH_SIZE", "16")),
            "methodology": "temporary UTF-8 text corpus; isolated AETHER_DIR; real local model and LanceDB; force rebuild; RSS is process peak and Python allocation is tracemalloc peak",
        }
    rendered = json.dumps(report, indent=2, sort_keys=True)
    if args.output:
        args.output.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)
    shutil.rmtree(state_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
