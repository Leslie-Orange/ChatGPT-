#!/bin/zsh
set -euo pipefail

# Generate all standard macOS 1x/2x representations from the RGBA master.
ROOT_DIR="${0:A:h}"
SOURCE_FILE="$ROOT_DIR/AppIcon.png"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quota-icon.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
ICONSET_DIR="$TEMP_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SOURCE_FILE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$SOURCE_FILE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$TEMP_DIR/AppIcon.icns"
cp "$TEMP_DIR/AppIcon.icns" "$ROOT_DIR/AppIcon.icns"
print "已生成：$ROOT_DIR/AppIcon.icns"
