#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND="$ROOT/Backend"
VENV="$BACKEND/venv"
REQUIREMENTS="$BACKEND/requirements.txt"

fail() {
  echo "error: $*" >&2
  exit 1
}

if ! command -v python3 >/dev/null 2>&1; then
  fail "Python 3 was not found. Install Python 3.10 or newer, then rerun $0."
fi

SYSTEM_PYTHON="$(command -v python3)"
if ! "$SYSTEM_PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
  PYTHON_VERSION="$("$SYSTEM_PYTHON" -c 'import platform; print(platform.python_version())' 2>/dev/null || echo unknown)"
  fail "Python 3.10 or newer is required; $SYSTEM_PYTHON is Python $PYTHON_VERSION."
fi

[ -d "$BACKEND" ] || fail "Backend directory not found at $BACKEND."
[ -f "$REQUIREMENTS" ] || fail "Requirements file not found at $REQUIREMENTS."

venv_is_healthy() {
  [ -x "$VENV/bin/python" ] || return 1

  "$VENV/bin/python" - "$VENV" <<'PY'
import glob
import os
import sys

venv = os.path.abspath(sys.argv[1])
if os.path.abspath(sys.prefix) != venv:
    print(
        f"Existing virtual environment points to {sys.prefix}, not {venv}.",
        file=sys.stderr,
    )
    raise SystemExit(1)

if sys.version_info < (3, 10):
    print(
        f"Existing virtual environment uses unsupported Python "
        f"{sys.version_info.major}.{sys.version_info.minor}.",
        file=sys.stderr,
    )
    raise SystemExit(1)

try:
    import pip  # noqa: F401
except Exception as exc:
    print(f"Existing virtual environment cannot import pip: {exc}", file=sys.stderr)
    raise SystemExit(1)

expected_bin = os.path.join(venv, "bin")
for launcher in glob.glob(os.path.join(expected_bin, "pip*")):
    if not os.path.isfile(launcher):
        continue
    try:
        with open(launcher, "rb") as handle:
            first_line = handle.readline().decode("utf-8", "replace").strip()
    except OSError as exc:
        print(f"Cannot inspect {launcher}: {exc}", file=sys.stderr)
        raise SystemExit(1)
    if first_line.startswith("#!"):
        interpreter = first_line[2:]
        if os.path.dirname(interpreter) != expected_bin:
            print(
                f"Stale pip launcher detected: {launcher} references {interpreter}.",
                file=sys.stderr,
            )
            raise SystemExit(1)
PY
}

recreate_venv() {
  if [ -e "$VENV" ] || [ -L "$VENV" ]; then
    echo "Repairing the backend virtual environment at ${VENV}…"
    rm -rf "$VENV" || fail "Could not remove the stale virtual environment at $VENV."
  else
    echo "Creating the backend virtual environment at ${VENV}…"
  fi

  if ! "$SYSTEM_PYTHON" -m venv "$VENV"; then
    rm -rf "$VENV"
    fail "Could not create the virtual environment. Verify that $SYSTEM_PYTHON supports the venv module."
  fi
}

echo "Setting up Aether Python backend…"

if [ -e "$VENV" ] || [ -L "$VENV" ]; then
  if ! venv_is_healthy; then
    recreate_venv
  fi
else
  recreate_venv
fi

VENV_PYTHON="$VENV/bin/python"
[ -x "$VENV_PYTHON" ] || fail "Virtual environment creation did not produce $VENV_PYTHON."

if ! "$VENV_PYTHON" -m pip install --upgrade pip; then
  fail "Failed to upgrade pip. Check your network connection and Python installation, then rerun $0."
fi

if ! "$VENV_PYTHON" -m pip install -r "$REQUIREMENTS"; then
  fail "Failed to install backend requirements from $REQUIREMENTS. Review the pip error above, then rerun $0."
fi

echo ""
echo "Preloading the search model into the local Hugging Face cache (first time can take a few minutes)…"
if ! (
  cd "$BACKEND" && "$VENV_PYTHON" - <<'PY'
from models import warmup_model
warmup_model()
print("Model cached.")
PY
); then
  echo "warning: model preload failed; Aether will download it on first launch instead." >&2
fi

echo ""
echo "Backend ready."
echo "Python: $VENV_PYTHON"
echo "Run the app from Xcode or set AETHER_PYTHON=$VENV_PYTHON"
