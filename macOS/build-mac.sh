#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}/.."
SOURCE_FILE="$ROOT_DIR/macOS/ChatGPTQuotaPet.swift"
INFO_FILE="$ROOT_DIR/macOS/Info.plist"
APP_DIR="$ROOT_DIR/ChatGPTQuotaPet.app"
BUILD_DIR="$ROOT_DIR/macOS/.build"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx13.0"

if ! command -v swiftc >/dev/null 2>&1; then
  print -u2 "找不到 swiftc，请先安装 Xcode Command Line Tools。"
  exit 1
fi

mkdir -p "$BUILD_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
swiftc -parse-as-library -target "$TARGET" "$SOURCE_FILE" -o "$BUILD_DIR/ChatGPTQuotaPet" -framework AppKit -framework Combine -framework SwiftUI
cp "$BUILD_DIR/ChatGPTQuotaPet" "$APP_DIR/Contents/MacOS/ChatGPTQuotaPet"
cp "$INFO_FILE" "$APP_DIR/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

print "已生成：$APP_DIR"
