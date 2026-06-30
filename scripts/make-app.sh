#!/usr/bin/env bash
# Build the Stock* apps and assemble .app bundles, then stop any running copy
# and install the freshly built bundles into /Applications.
#
# Usage:
#   ./scripts/make-app.sh                       # release, all targets
#   ./scripts/make-app.sh debug                 # debug config, all targets
#   TARGETS=StockBar ./scripts/make-app.sh      # only the menu-bar app
#   TARGETS=StockTouchBar ./scripts/make-app.sh # only the Touch Bar agent
#
# Env vars:
#   DEVELOPER_DIR  Path to an Xcode.app/Contents/Developer to use for swiftc.
#                  Defaults to /Volumes/disk/Applications/Xcode.app if present.
#   TARGETS        Space-separated list of executable targets to build.
#                  Defaults to "StockBar StockTouchBar".
#   NO_INSTALL=1   Skip copying the bundle(s) into /Applications.
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

TARGETS="${TARGETS:-StockBar StockTouchBar}"

# Pick toolchain. Prefer caller's DEVELOPER_DIR; fall back to external Xcode.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d /Volumes/disk/Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Volumes/disk/Applications/Xcode.app/Contents/Developer
    fi
fi

echo "==> Using DEVELOPER_DIR=${DEVELOPER_DIR:-(default)}"
echo "==> swift --version"
xcrun swift --version
echo "==> Targets: $TARGETS"

# ---- Per-target metadata.
# `plist_for <target>` echoes the path to the Info.plist that should be baked
# into the .app for that target.
plist_for() {
    case "$1" in
        StockBar)      echo "$ROOT/Resources/Info.plist" ;;
        StockTouchBar) echo "$ROOT/Resources/Info-TouchBar.plist" ;;
        *)             echo ""; return 1 ;;
    esac
}

build_target() {
    local target="$1"
    local plist
    plist="$(plist_for "$target")"
    if [[ -z "$plist" || ! -f "$plist" ]]; then
        echo "no Info.plist defined for target '$target'" >&2
        exit 1
    fi

    echo
    echo "==> Building $target ($CONFIG)"
    xcrun swift build "${SWIFT_FLAGS[@]}" --product "$target"

    local bin="$ROOT/$BUILD_DIR/$target"
    if [[ ! -x "$bin" ]]; then
        echo "binary not found at $bin" >&2
        exit 1
    fi

    local app="$ROOT/build/${target}.app"
    echo "==> Assembling $app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    mkdir -p "$app/Contents/Resources"

    cp "$bin" "$app/Contents/MacOS/$target"
    cp "$plist" "$app/Contents/Info.plist"
    [[ -f "$ROOT/Resources/AppIcon.icns" ]] \
        && cp "$ROOT/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

    # Ad-hoc codesign so Gatekeeper / Launch Services don't reject the bundle.
    codesign --force --sign - --options runtime "$app" 2>&1 | sed 's/^/    /'

    echo "==> Built: $app"

    # ---- Install + restart cycle.
    echo "==> Stopping running $target (if any)"
    pkill -f "${target}\\.app/Contents/MacOS/${target}" 2>/dev/null || true
    sleep 0.3

    if [[ -z "${NO_INSTALL:-}" ]]; then
        local dest="/Applications/${target}.app"
        echo "==> Installing to $dest"
        rm -rf "$dest"
        cp -R "$app" "$dest"

        if [[ -z "${NO_LAUNCH:-}" ]]; then
            echo "==> Launching $dest"
            open "$dest"
        fi
        echo "Installed: $dest"
    else
        echo "Run:   open '$app'"
        echo "Or:    '$app/Contents/MacOS/$target'   # foreground, ctrl-c to stop"
    fi
}

for target in $TARGETS; do
    build_target "$target"
done

echo
echo "Done."
echo "Stop StockBar:      pkill -f 'StockBar.app/Contents/MacOS/StockBar'"
echo "Stop StockTouchBar: pkill -f 'StockTouchBar.app/Contents/MacOS/StockTouchBar'"
