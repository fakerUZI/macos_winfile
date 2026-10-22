#!/bin/bash
# Pinned, universal MTP runtime. No Homebrew/runtime installation required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$ROOT/native/native-build/dependencies/mtp-source"
OUT="$ROOT/native/native-build/mtp"
mkdir -p "$BASE" "$OUT"
fetch() {
  local name="$1" url="$2" sha="$3"
  if [ ! -f "$BASE/$name" ]; then curl -fL --retry 3 "$url" -o "$BASE/$name" >&2; fi
  [ "$(shasum -a 256 "$BASE/$name" | awk '{print $1}')" = "$sha" ] || { echo "MTP source checksum mismatch: $name" >&2; exit 1; }
}
fetch libmtp-1.1.23.tar.gz https://github.com/libmtp/libmtp/releases/download/v1.1.23/libmtp-1.1.23.tar.gz 74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed
fetch libusb-1.0.30.tar.bz2 https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2 fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
if [ ! -f "$OUT/no-reset-v1.stamp" ] || [ ! -f "$OUT/libmtp.9.dylib" ]; then
  tar -xf "$BASE/libmtp-1.1.23.tar.gz" -C "$BASE"
  tar -xf "$BASE/libusb-1.0.30.tar.bz2" -C "$BASE"
  # Release archives contain Linux-generated headers; quoted includes otherwise pick them before build headers.
  rm -f "$BASE/libmtp-1.1.23/src/gphoto2-endian.h" "$BASE/libmtp-1.1.23/src/_stdint.h"
  (cd "$BASE/libmtp-1.1.23" && patch -p1 < "$ROOT/native/vendor/mtp/no-usb-reset.patch") >&2
  for arch in arm64 x86_64; do
    prefix="$OUT/$arch"
    mkdir -p "$BASE/build-usb-$arch" "$BASE/build-mtp-$arch" "$prefix"
    (
      cd "$BASE/build-usb-$arch"
      CC=clang CFLAGS="-arch $arch -mmacosx-version-min=13.0" LDFLAGS="-arch $arch -mmacosx-version-min=13.0" \
        ../libusb-1.0.30/configure --host="$arch-apple-darwin" --prefix="$prefix" --disable-static
      make -j4 && make install
    ) >&2
    (
      cd "$BASE/build-mtp-$arch"
      CC=clang CFLAGS="-arch $arch -mmacosx-version-min=13.0" LDFLAGS="-arch $arch -mmacosx-version-min=13.0" \
        PKG_CONFIG=/usr/bin/true LIBUSB_CFLAGS="-I$prefix/include/libusb-1.0" LIBUSB_LIBS="-L$prefix/lib -lusb-1.0" \
        ../libmtp-1.1.23/configure --host="$arch-apple-darwin" --prefix="$prefix" --disable-static --disable-mtpz --disable-doxygen --without-udev
      make -j4 && make install
    ) >&2
  done
  lipo -create "$OUT/arm64/lib/libusb-1.0.dylib" "$OUT/x86_64/lib/libusb-1.0.dylib" -output "$OUT/libusb-1.0.0.dylib"
  lipo -create "$OUT/arm64/lib/libmtp.dylib" "$OUT/x86_64/lib/libmtp.dylib" -output "$OUT/libmtp.9.dylib"
  install_name_tool -id @rpath/libusb-1.0.0.dylib "$OUT/libusb-1.0.0.dylib"
  install_name_tool -id @rpath/libmtp.9.dylib "$OUT/libmtp.9.dylib"
  for arch in arm64 x86_64; do
    install_name_tool -change "$OUT/$arch/lib/libusb-1.0.0.dylib" @rpath/libusb-1.0.0.dylib "$OUT/libmtp.9.dylib"
  done
  touch "$OUT/no-reset-v1.stamp"
fi
printf '%s\n' "$OUT"
