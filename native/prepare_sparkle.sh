#!/bin/bash
# Pinned official SDK; compiled dependencies stay outside Git.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=2.10.0
SHA=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
CACHE="$ROOT/native/native-build/dependencies"
ARCHIVE="$CACHE/Sparkle-$VERSION.tar.xz"
SDK="$CACHE/Sparkle-$VERSION"
mkdir -p "$CACHE"
if [ ! -f "$ARCHIVE" ]; then
  DOWNLOAD="$(mktemp "$CACHE/.sparkle-download.XXXXXX")"
  trap 'rm -f "$DOWNLOAD"' EXIT
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 2 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "$DOWNLOAD"
  [ "$(shasum -a 256 "$DOWNLOAD" | awk '{print $1}')" = "$SHA" ] || { echo 'Sparkle SDK checksum mismatch' >&2; exit 1; }
  mv "$DOWNLOAD" "$ARCHIVE"
fi
[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" = "$SHA" ] || { echo 'Sparkle SDK checksum mismatch' >&2; exit 1; }
if [ ! -f "$SDK/Sparkle.framework/Versions/B/Sparkle" ]; then
  STAGE="$(mktemp -d "$CACHE/.sparkle-extract.XXXXXX")"
  tar -xJf "$ARCHIVE" -C "$STAGE"
  [ ! -e "$SDK" ] || { echo 'Incomplete Sparkle SDK: remove the dependency cache and retry' >&2; exit 1; }
  mv "$STAGE" "$SDK"
fi
printf '%s\n' "$SDK"
