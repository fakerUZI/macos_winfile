#!/bin/bash
# Build, sign and package GitHub Release assets (including the Sparkle feed).
# Usage: ./native/make_release.sh [VERSION] [--package-only]
# Increment CFBundleShortVersionString AND CFBundleVersion in native/Info.plist first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$ROOT/native/Info.plist")"
BUILD_VERSION="$(/usr/bin/plutil -extract CFBundleVersion raw "$ROOT/native/Info.plist")"
PACKAGE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --package-only) PACKAGE_ONLY=1 ;;
    *) [ "$arg" = "$VERSION" ] || { echo 'Version argument must match native/Info.plist. Update its version and build before releasing.' >&2; exit 2; } ;;
  esac
done
SDK="$("$ROOT/native/prepare_sparkle.sh")"
if [ "$PACKAGE_ONLY" = 0 ]; then "$ROOT/native/build_native.sh" --in-place; fi
APP="$(cat "$ROOT/native/native-build/last-built-app-path")"
[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$VERSION" ] && \
[ "$(/usr/bin/plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" = "$BUILD_VERSION" ] || { echo 'The verified build is stale. Rebuild before packaging.' >&2; exit 1; }
NOTES=()
if [ -f "$ROOT/docs/releases/v$VERSION.md" ]; then NOTES=(--notes "$ROOT/docs/releases/v$VERSION.md"); fi
python3 "$ROOT/tools/prepare_appcast.py" --app "$APP" --sdk "$SDK" --dist "$ROOT/dist" "${NOTES[@]}"
echo "Upload all five release files:"
for name in appcast.xml "WinFile-$VERSION.zip" "WinFile-$VERSION.zip.sha256" WinFile.zip WinFile.zip.sha256; do
  echo "  $ROOT/dist/$name"
done
echo "Publish as stable GitHub Release v$VERSION. The updater uses build $BUILD_VERSION for comparison."
