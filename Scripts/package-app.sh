#!/bin/sh
# Build a Release .app for local distribution (Phase 1 - partial Python bundling).
#
# What this script does:
#   1. Builds Aether with xcodebuild (Release, unsigned by default)
#   2. Ensures Backend/*.py (+ requirements.txt) are in the app Resources
#      (Xcode Run Script already runs copy-backend.sh; this is a safety net)
#   3. Prints next steps for Python setup and optional notarization
#
# Limitations (Phase 1):
#   - The Python virtualenv is NOT embedded in the .app.
#   - Recipients still need Python 3.10+ and must run ./Scripts/setup-backend.sh
#     (or set AETHER_PYTHON to a suitable interpreter with deps installed).
#   - Full install-and-run bundling of the runtime is future work.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Aether.xcodeproj"
SCHEME="Aether"
CONFIGURATION="Release"
DERIVED="$ROOT/build/Package"
APP_NAME="Aether.app"

fail() {
  echo "error: $*" >&2
  exit 1
}

echo "==> Building $SCHEME ($CONFIGURATION)…"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$(find "$DERIVED/Build/Products/$CONFIGURATION" -maxdepth 1 -name "$APP_NAME" -print -quit)"
[ -n "$APP_PATH" ] && [ -d "$APP_PATH" ] || fail "Built app not found under $DERIVED/Build/Products/$CONFIGURATION"

RESOURCES_BACKEND="$APP_PATH/Contents/Resources/Backend"
echo "==> Ensuring Backend Python sources are in Resources…"
mkdir -p "$RESOURCES_BACKEND"
for file in "$ROOT/Backend/"*.py; do
  [ -f "$file" ] || continue
  cp "$file" "$RESOURCES_BACKEND/"
done
if [ -f "$ROOT/Backend/requirements.txt" ]; then
  cp "$ROOT/Backend/requirements.txt" "$RESOURCES_BACKEND/"
fi
[ -f "$RESOURCES_BACKEND/bridge.py" ] || fail "bridge.py missing from $RESOURCES_BACKEND"

echo ""
echo "Packaged app:"
echo "  $APP_PATH"
echo ""
echo "Python runtime (Phase 1 - external venv):"
echo "  1. On this machine (or the target Mac):"
echo "       $ROOT/Scripts/setup-backend.sh"
echo "  2. Launch with the venv Python discoverable, e.g.:"
echo "       export AETHER_PYTHON=$ROOT/Backend/venv/bin/python3"
echo "       open \"$APP_PATH\""
echo "     Or keep the project Backend/venv next to a checkout that"
echo "     BackendLocator can resolve during development."
echo ""
echo "Note: Resources include Backend/*.py only. The venv / site-packages"
echo "are not copied into the .app. Full Python bundling is not in Phase 1."
echo ""
echo "Optional signing / notarization (not performed by this script):"
echo "  See README.md -> Packaging & notarization prerequisites."
echo ""
echo "Done."
