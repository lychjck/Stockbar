#!/usr/bin/env bash
# Build StockBar and assemble .app bundle, then stop any running copy
# and install the freshly built bundle into /Applications.
#
# Usage:
#   ./scripts/make-app.sh           # release build
#   ./scripts/make-app.sh debug     # debug config
#
# Env vars:
#   DEVELOPER_DIR  Path to an Xcode.app/Contents/Developer to use for swiftc.
#                  Defaults to /Volumes/disk/Applications/Xcode.app if present.
#   NO_INSTALL=1   Skip copying the bundle into /Applications.
#   NO_LAUNCH=1    Skip re-launching after install.
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

TARGET="StockBar"

# Pick toolchain. Prefer caller's DEVELOPER_DIR; fall back to external Xcode.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d /Volumes/disk/Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Volumes/disk/Applications/Xcode.app/Contents/Developer
    fi
fi

echo "==> Using DEVELOPER_DIR=${DEVELOPER_DIR:-(default)}"
echo "==> swift --version"
xcrun swift --version
echo "==> Target: $TARGET"

echo
echo "==> Building $TARGET ($CONFIG)"
xcrun swift build "${SWIFT_FLAGS[@]}" --product "$TARGET"

BIN="$ROOT/$BUILD_DIR/$TARGET"
if [[ ! -x "$BIN" ]]; then
    echo "binary not found at $BIN" >&2
    exit 1
fi

APP="$ROOT/build/${TARGET}.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$TARGET"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] \
    && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc codesign so Gatekeeper / Launch Services don't reject the bundle.
codesign --force --sign - --options runtime "$APP" 2>&1 | sed 's/^/    /'

echo "==> Built: $APP"

# ---- Install + restart cycle.
echo "==> Stopping running $TARGET (if any)"
pkill -f "${TARGET}\\.app/Contents/MacOS/${TARGET}" 2>/dev/null || true
sleep 0.3

if [[ -z "${NO_INSTALL:-}" ]]; then
    DEST="/Applications/${TARGET}.app"
    echo "==> Installing to $DEST"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"

    if [[ -z "${NO_LAUNCH:-}" ]]; then
        echo "==> Launching $DEST"
        open "$DEST"
    fi
    echo "Installed: $DEST"
else
    echo "Run:   open '$APP'"
    echo "Or:    '$APP/Contents/MacOS/$TARGET'   # foreground, ctrl-c to stop"
fi

echo
echo "Done."
echo "Stop StockBar: pkill -f 'StockBar.app/Contents/MacOS/StockBar'"
