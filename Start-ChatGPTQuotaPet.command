#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_DIR="$ROOT_DIR/ChatGPTQuotaPet.app"

if [[ ! -x "$APP_DIR/Contents/MacOS/ChatGPTQuotaPet" ]]; then
  "$ROOT_DIR/macOS/build-mac.sh"
fi

open "$APP_DIR"
