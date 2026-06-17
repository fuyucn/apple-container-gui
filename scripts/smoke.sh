#!/usr/bin/env bash
# Canonical UI smoke gate, reused by every UI task: bundle the app, launch it,
# wait, assert the process is alive (i.e. it did not crash on launch), then kill
# it. Exits non-zero if the app failed to come up.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="AppleContainerGUI"
APP_DIR="$ROOT_DIR/$APP_NAME.app"
EXECUTABLE="AppMain"

bash "$SCRIPT_DIR/bundle.sh"

echo "==> Launching $APP_NAME.app"
open "$APP_DIR"

echo "==> Waiting 5s for the app to settle"
sleep 5

if pgrep -x "$EXECUTABLE" >/dev/null; then
	echo "==> OK: $EXECUTABLE is running"
	pkill -x "$EXECUTABLE" || true
	echo "==> Smoke gate passed"
	exit 0
else
	echo "error: $EXECUTABLE is not running 5s after launch (crashed or failed to start)" >&2
	exit 1
fi
