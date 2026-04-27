#!/usr/bin/env bash
# Build Tama in Debug and run it from a stable path so TCC permissions stick.
#
# Why: macOS keys every TCC permission (Accessibility, Screen Recording, Mic,
# Speech, Full Disk, etc.) to a binary's path + code-signing designated
# requirement. Running directly out of DerivedData mostly works but Screen
# Recording in particular re-verifies the cdhash on macOS 15+, and stray
# Release installs in /Applications create competing TCC entries that mask
# the Debug build. Net effect: permissions appear to "reset" on every rebuild.
#
# This script copies the freshly-built .app into ~/Applications/Tama.app and
# launches it from there. Same path every run → TCC entries persist → grant
# once, never again.
#
# Usage:
#   ./scripts/dev.sh              # build + install + launch
#   ./scripts/dev.sh --no-build   # skip xcodebuild, just relaunch installed copy
#   ./scripts/dev.sh --reset-tcc  # nuke Tama TCC entries (forces fresh prompts)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/Tama.app"
BUNDLE_ID="com.unstablemind.tama"

DO_BUILD=1
case "${1:-}" in
    --no-build) DO_BUILD=0 ;;
    --reset-tcc)
        echo "━━━ Resetting TCC entries for $BUNDLE_ID ━━━"
        for service in Accessibility ScreenCapture Microphone SpeechRecognition \
                       SystemPolicyAllFiles SystemPolicyDocumentsFolder \
                       AppleEvents PostEvent ListenEvent; do
            tccutil reset "$service" "$BUNDLE_ID" 2>/dev/null || true
        done
        echo "Done. Re-grant permissions on next launch."
        exit 0
        ;;
    "") ;;
    *)
        echo "Unknown flag: $1" >&2
        echo "Usage: $0 [--no-build | --reset-tcc]" >&2
        exit 64
        ;;
esac

# Kill any running Tama before we overwrite the bundle.
if pgrep -xf "$INSTALLED_APP/Contents/MacOS/Tama" >/dev/null 2>&1; then
    echo "━━━ Stopping running Tama ━━━"
    pkill -xf "$INSTALLED_APP/Contents/MacOS/Tama" || true
    sleep 0.5
fi
# Also stop any other Tama process (e.g. running from DerivedData).
pkill -x Tama 2>/dev/null || true

if [[ "$DO_BUILD" == 1 ]]; then
    if [[ ! -f Tama.xcodeproj/project.pbxproj || project.yml -nt Tama.xcodeproj/project.pbxproj ]]; then
        echo "━━━ Regenerating Xcode project ━━━"
        xcodegen generate
    fi

    echo "━━━ Building Tama (Debug) ━━━"
    xcodebuild \
        -project Tama.xcodeproj \
        -scheme Tama \
        -configuration Debug \
        -quiet \
        build
fi

# Locate the freshly-built .app via xcodebuild's settings rather than guessing
# the DerivedData hash.
BUILT_APP="$(
    xcodebuild -project Tama.xcodeproj -scheme Tama -configuration Debug \
        -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR[[:space:]]*=/ { print $2; exit }'
)/Tama.app"

if [[ ! -d "$BUILT_APP" ]]; then
    echo "Built app not found at: $BUILT_APP" >&2
    echo "Try running without --no-build." >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"

echo "━━━ Installing → $INSTALLED_APP ━━━"
rm -rf "$INSTALLED_APP"
cp -R "$BUILT_APP" "$INSTALLED_APP"

# Tell LaunchServices about the (re)installed bundle so it's preferred over
# any other Tama.app on the system.
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
    -f "$INSTALLED_APP" >/dev/null 2>&1 || true

echo "━━━ Launching ━━━"
open "$INSTALLED_APP"
echo "Running from: $INSTALLED_APP"
