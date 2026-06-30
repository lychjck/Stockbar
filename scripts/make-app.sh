#!/usr/bin/env bash
# Build StockBar and assemble a .app bundle, then stop any running copy and
# install the freshly built bundle into /Applications.
# Usage:
#   ./scripts/make-app.sh         # release build, app at ./build/StockBar.app
#   ./scripts/make-app.sh debug   # debug build (faster, larger)
#
# Env vars:
#   DEVELOPER_DIR  Path to an Xcode.app/Contents/Developer to use for swiftc.
#                  Defaults to /Volumes/disk/Applications/Xcode.app if present.
#   NO_INSTALL=1   Skip copying the bundle into /Applications.
#   NO_LAUNCH=1    Skip re-launching the installed bundle.
#
# Requires: Xcode toolchain.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
case "$CONFIG" in
    debug)   SWIFT_FLAGS=(-c debug);   BUILD_DIR=".build/debug" ;;
    release) SWIFT_FLAGS=(-c release); BUILD_DIR=".build/release" ;;
    *)       echo "unknown config: $CONFIG (use debug or release)"; exit 1 ;;
esac

# Pick toolchain. Prefer caller's DEVELOPER_DIR; fall back to external Xcode.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d /Volumes/disk/Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Volumes/disk/Applications/Xcode.app/Contents/Developer
    fi
fi

echo "==> Using DEVELOPER_DIR=${DEVELOPER_DIR:-(default)}"
echo "==> swift --version"
xcrun swift --version

echo "==> Building ($CONFIG)"
xcrun swift build "${SWIFT_FLAGS[@]}"

BIN="$ROOT/$BUILD_DIR/StockBar"
if [[ ! -x "$BIN" ]]; then
    echo "binary not found at $BIN"
    exit 1
fi

APP="$ROOT/build/StockBar.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/StockBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc codesign so Gatekeeper / Launch Services don't reject the bundle.
codesign --force --sign - --options runtime "$APP" 2>&1 | sed 's/^/    /'

echo
echo "==> Built: $APP"

# ---- Install + restart cycle.
# Always stop any running StockBar first — matches both the dev build and the
# previously installed /Applications copy by full executable path.
echo "==> Stopping running StockBar (if any)"
pkill -f 'StockBar\.app/Contents/MacOS/StockBar' 2>/dev/null || true
# Tiny delay so Launch Services has settled before we replace the bundle.
sleep 0.3

if [[ -z "${NO_INSTALL:-}" ]]; then
    DEST="/Applications/StockBar.app"
    echo "==> Installing to $DEST"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"

    if [[ -z "${NO_LAUNCH:-}" ]]; then
        echo "==> Launching $DEST"
        open "$DEST"
    fi

    echo
    echo "Installed: $DEST"
    echo "Stop:      pkill -f 'StockBar.app/Contents/MacOS/StockBar'"
else
    echo
    echo "Run:   open '$APP'"
    echo "Or:    '$APP/Contents/MacOS/StockBar'   # foreground, ctrl-c to stop"
fi
