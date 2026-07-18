#!/bin/sh
# Regenerate macOS icon sizes from icon.png (1024×1024, edge-to-edge artwork).
set -euo pipefail

ICONSET="$(cd "$(dirname "$0")/.." && pwd)/Aether/Assets.xcassets/AppIcon.appiconset"
SRC="$ICONSET/icon.png"

if [ ! -f "$SRC" ]; then
  echo "Missing $SRC"
  exit 1
fi

for size in 16 32 64 128 256 512; do
  sips -z "$size" "$size" "$SRC" --out "$ICONSET/icon_${size}.png" >/dev/null
done

echo "Regenerated icon sizes in AppIcon.appiconset"
