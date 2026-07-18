#!/bin/sh
set -euo pipefail

DEST="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Backend"
mkdir -p "$DEST"

for file in "${SRCROOT}/Backend/"*.py; do
  [ -f "$file" ] || continue
  cp "$file" "$DEST/"
done

if [ -f "${SRCROOT}/Backend/requirements.txt" ]; then
  cp "${SRCROOT}/Backend/requirements.txt" "$DEST/"
fi
