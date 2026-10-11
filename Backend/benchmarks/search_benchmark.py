"""Deterministic search benchmark harness.

Run with a JSON fixture containing:
{
  "documents": [{"path": "...", "file_name": "...", "content": "..."}],
  "queries": [{"query": "...", "relevant": ["path", ...]}]
}

The harness uses the same lexical scoring primitives as the backend and is
deliberately model-free, so it can run in CI without downloading weights.
"""
import json
import math
import sys
import types
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))
try:
    import lancedb  # noqa: F401
except ImportError:
    sys.modules["lancedb"] = types.SimpleNamespace(connect=lambda _path: object())
from search import _lexical_scores  # noqa: E402


def metrics(results, relevant, cutoff=10):
    relevant = set(relevant)
    ranked = [item["path"] for item in results[:cutoff]]
    hits = [path for path in ranked if path in relevant]
    recall = len(set(hits)) / len(relevant) if relevant else 1.0
    mrr = 0.0
    for index, path in enumerate(ranked, 1):
        if path in relevant:
            mrr = 1.0 / index
            break
    dcg = sum((1.0 / math.log2(index + 2)) for index, path in enumerate(ranked) if path in relevant)
    ideal = sum((1.0 / math.log2(index + 2)) for index in range(min(cutoff, len(relevant))))
    return recall, mrr, (dcg / ideal if ideal else 1.0)


def run(fixture):
    documents = fixture["documents"]
    totals = [0.0, 0.0, 0.0]
    for case in fixture["queries"]:
        query = case["query"]
        ranked = sorted(
            documents,
            key=lambda item: (
                -sum(_lexical_scores(item, query)),
                item["path"],
            ),
        )
        values = metrics(ranked, case.get("relevant", []))
        totals = [left + right for left, right in zip(totals, values)]
    count = max(1, len(fixture["queries"]))
    return {"queries": len(fixture["queries"]), "recall@10": totals[0] / count, "mrr": totals[1] / count, "ndcg@10": totals[2] / count}


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as handle:
        print(json.dumps(run(json.load(handle)), indent=2, sort_keys=True))
