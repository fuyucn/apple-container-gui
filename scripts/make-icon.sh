#!/usr/bin/env bash
# Generate the app icon -> Resources/AppIcon.icns (and a 1024 master PNG).
#
# Design: "Window + Container Core" — an original composite logo rendered by
# scripts/AppIcon.swift. It uses a native macOS window and an original
# container/status core instead of embedding Apple's official bitmap.
#
# Deps ship with the Command Line Tools: swift, iconutil. No third-party tools.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RES_DIR="$ROOT_DIR/Resources"
RENDERER="$SCRIPT_DIR/AppIcon.swift"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

ICONSET="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
OUT_ICNS="$RES_DIR/AppIcon.icns"
MASTER="$ROOT_DIR/docs/icon-master-1024.png"

if [[ ! -f "$RENDERER" ]]; then
	echo "error: missing $RENDERER" >&2
	exit 1
fi

# iconset entry filename -> pixel size.
render() { swift "$RENDERER" "$2" "$ICONSET/$1"; }

echo "==> Rendering original app icon"
render "icon_16x16.png"        16
render "icon_16x16@2x.png"     32
render "icon_32x32.png"        32
render "icon_32x32@2x.png"     64
render "icon_128x128.png"      128
render "icon_128x128@2x.png"   256
render "icon_256x256.png"      256
render "icon_256x256@2x.png"   512
render "icon_512x512.png"      512
render "icon_512x512@2x.png"   1024

echo "==> Packing $OUT_ICNS"
iconutil -c icns "$ICONSET" -o "$OUT_ICNS"

echo "==> Exporting 1024 master -> $MASTER (import into Icon Composer for Liquid Glass)"
mkdir -p "$(dirname "$MASTER")"
swift "$RENDERER" 1024 "$MASTER"

echo "==> Done: $OUT_ICNS"
