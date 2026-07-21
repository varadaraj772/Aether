import os
import sys
import threading
from pathlib import Path

_model = None
_model_lock = threading.Lock()
MODEL_NAME = "all-MiniLM-L6-v2"
MODEL_REPO = f"sentence-transformers/{MODEL_NAME}"


def _emit_model_progress(stage: str) -> None:
    """Emit a one-line stderr progress marker for the Swift UI (stdout stays JSON-RPC)."""
    print(f"MODEL_PROGRESS: {stage}", file=sys.stderr, flush=True)


def _hub_cache_dir() -> Path:
    return Path(
        os.environ.get(
            "HF_HUB_CACHE",
            Path.home() / ".cache" / "huggingface" / "hub",
        )
    )


def _model_cache_root() -> Path | None:
    folder = "models--" + MODEL_REPO.replace("/", "--")
    root = _hub_cache_dir() / folder
    return root if root.is_dir() else None


def _resolve_local_snapshot() -> Path | None:
    """Return a fully downloaded snapshot path if the model is already cached."""
    root = _model_cache_root()
    if root is None:
        return None

    snapshots = root / "snapshots"
    if not snapshots.is_dir():
        return None

    # Prefer refs/main -> snapshot hash when present.
    ref_main = root / "refs" / "main"
    if ref_main.is_file():
        try:
            digest = ref_main.read_text(encoding="utf-8").strip()
            candidate = snapshots / digest
            if _snapshot_looks_complete(candidate):
                return candidate
        except OSError:
            pass

    try:
        candidates = sorted(
            (p for p in snapshots.iterdir() if p.is_dir()),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
    except OSError:
        return None

    for candidate in candidates:
        if _snapshot_looks_complete(candidate):
            return candidate
    return None


def _snapshot_looks_complete(path: Path) -> bool:
    if not path.is_dir():
        return False
    # MiniLM snapshots typically include config + weights/modules.
    has_config = (path / "config.json").is_file() or (path / "config_sentence_transformers.json").is_file()
    has_weights = any(path.glob("*.bin")) or any(path.glob("*.safetensors")) or (path / "pytorch_model.bin").is_file()
    return has_config and has_weights


def _model_cached() -> bool:
    return _resolve_local_snapshot() is not None


def _enable_offline_hub() -> None:
    """Skip Hugging Face network checks when we already have a local snapshot."""
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")


def get_model():
    global _model

    if _model is not None:
        return _model

    with _model_lock:
        if _model is None:
            local = _resolve_local_snapshot()
            if local is not None:
                _emit_model_progress("loading")
                print(f"Loading model from cache: {local}", file=sys.stderr, flush=True)
                _enable_offline_hub()
                model_id = str(local)
                local_files_only = True
            else:
                _emit_model_progress("downloading")
                print("Downloading model (first launch)…", file=sys.stderr, flush=True)
                model_id = MODEL_NAME
                local_files_only = False

            # Lazy import keeps bridge startup fast so ping responds immediately.
            from sentence_transformers import SentenceTransformer

            _model = SentenceTransformer(model_id, local_files_only=local_files_only)

    return _model


def warmup_model():
    """Load the embedding model and run a dummy encode to warm inference."""
    try:
        model = get_model()
        model.encode("warmup", show_progress_bar=False)
        _emit_model_progress("ready")
        print("Model ready.", file=sys.stderr, flush=True)
        return {"ready": True, "cached": _model_cached()}
    except Exception as exc:
        _emit_model_progress("error")
        raise RuntimeError(_warmup_error_message(exc)) from exc


def _warmup_error_message(exc: BaseException) -> str:
    text = str(exc) or exc.__class__.__name__
    lower = text.lower()
    if isinstance(exc, ModuleNotFoundError) or any(
        token in lower
        for token in (
            "no module named",
            "sentence_transformers",
            "sentence-transformers",
            "modulenotfounderror",
        )
    ):
        return (
            f"{text}\n\n"
            "Python dependencies are missing from the backend virtualenv. "
            "Run ./Scripts/setup-backend.sh, then Retry to restart the backend."
        )
    if any(
        token in lower
        for token in (
            "offline",
            "connection",
            "network",
            "timed out",
            "timeout",
            "huggingface",
            "hf_hub",
            "403",
            "401",
            "unreachable",
            "name or service not known",
        )
    ):
        return (
            f"{text}\n\n"
            "Could not download or load the search model. "
            "Connect to the internet on first launch (Hugging Face), "
            "then Retry to restart the backend."
        )
    return (
        f"{text}\n\n"
        "Search model warmup failed. "
        "Confirm ./Scripts/setup-backend.sh completed, then Retry."
    )
