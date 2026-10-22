#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$("$ROOT/native/prepare_mtp.sh")"
for arch in arm64 x86_64; do
  clang -arch "$arch" -mmacosx-version-min=13.0 -O2 -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
    -framework Foundation -I"$SDK/$arch/include" -I"$SDK/$arch/include/libusb-1.0" \
    -L"$SDK" -lmtp.9 -lusb-1.0.0 -Wl,-rpath,@executable_path/../Frameworks -Wl,-rpath,@executable_path \
    "$ROOT/native/MTPHelper/main.m" -o "$SDK/WinFileMTP-$arch"
done
lipo -create "$SDK/WinFileMTP-arm64" "$SDK/WinFileMTP-x86_64" -output "$SDK/WinFileMTP"
for binary in "$SDK/"*.dylib "$SDK/WinFileMTP"; do codesign --force --sign - "$binary" >&2; done
printf '%s\n' "$SDK"
