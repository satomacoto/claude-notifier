#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/claude-notifier.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Cleaning build directory..."
rm -rf "$APP_DIR"

echo "==> Regenerating icon assets..."
swift "$SCRIPT_DIR/generate_app_icon.swift"

echo "==> Creating app bundle structure..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "==> Compiling Swift source..."
swiftc \
    -framework AppKit \
    -o "$MACOS_DIR/claude-notifier" \
    "$SCRIPT_DIR/Sources/main.swift"

echo "==> Copying Info.plist..."
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

echo "==> Copying icon..."
cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

echo "==> Setting permissions..."
chmod +x "$MACOS_DIR/claude-notifier"

echo "==> Signing (ad-hoc)..."
codesign --force --deep --sign - "$APP_DIR"

echo "==> Build complete: $APP_DIR"
