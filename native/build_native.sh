#!/bin/bash
# 构建原生 SwiftUI 版 WinFile.app
#
#   ./native/build_native.sh                # 构建并安装到 /Applications（启动台可见）
#   ./native/build_native.sh --in-place     # 只构建到项目目录，不安装
#
# 本地使用形态：未沙盒，可直接访问整个磁盘。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Retain the on-disk app/executable names for existing curl and Sparkle installs.
# The product's user-visible name is LeafFiles (Info.plist + localized resources).
NAME="WinFile"
SRC="$ROOT/native/WinFile"
BUILD="$ROOT/native/native-build"
OUTPUT_APP="$ROOT/$NAME.app"
# Assemble/sign away from synced Documents folders, whose FinderInfo attributes
# can reappear during signing and invalidate a release archive.
APP_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/winfile-build.XXXXXX")"
APP="$APP_STAGE/$NAME.app"
INSTALL_DIR="/Applications"
OPT=-O

for arg in "$@"; do
  case "$arg" in
    --in-place) INSTALL_DIR="" ;;
    --quick) OPT=-Onone ;;
  esac
done
SPARKLE_SDK="$("$ROOT/native/prepare_sparkle.sh")"
MTP_SDK="$("$ROOT/native/build_mtp_helper.sh")"

echo "== 1/6 生成应用图标 =="
python3 "$ROOT/tools/make_icon.py" >/dev/null
ICNS="$ROOT/docs/icon/AppIcon.icns"
[ -f "$ICNS" ] || { echo "图标生成失败"; exit 1; }

echo "== 2/6 编译 SwiftUI 应用（arm64 + x86_64）=="
mkdir -p "$BUILD"

# 源文件：应用本体 + 安卓模块（子目录）+ 测试辅助
SRC_FILES=("$SRC"/*.swift)
while IFS= read -r file; do
  SRC_FILES+=("$file")
done < <(find "$SRC/Android" -name "*.swift" 2>/dev/null | sort)
SRC_FILES+=(
  "$ROOT/native/WinFileTests/AndroidProbe.swift"
  "$ROOT/native/WinFileTests/NativeTestSuite.swift"
  "$ROOT/native/WinFileTests/SnapshotRenderer.swift"
  "$ROOT/native/WinFileTests/ViewTreeDumper.swift"
  "$ROOT/native/WinFileTests/TabSmokeTest.swift"
  "$ROOT/native/WinFileTests/A11yProbe.swift"
)

build_arch() {
  local arch="$1"
  /usr/bin/swiftc -swift-version 5 "$OPT" \
    -target "${arch}-apple-macos13.0" \
    -framework AppKit -framework SwiftUI -framework Security -framework AVFoundation -framework AVKit \
    -F "$SPARKLE_SDK" -framework Sparkle \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    -o "$BUILD/$NAME-$arch" \
    "${SRC_FILES[@]}"
}

echo "   - 编译 arm64"
build_arch arm64
echo "   - 编译 x86_64"
build_arch x86_64

echo "== 3/6 合并通用二进制 =="
/usr/bin/lipo -create -output "$BUILD/$NAME-universal" \
  "$BUILD/$NAME-arm64" "$BUILD/$NAME-x86_64"
/usr/bin/lipo -info "$BUILD/$NAME-universal"

echo "== 4/6 组装应用包 =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/ThirdParty/Sparkle"
/usr/bin/ditto --noextattr --norsrc "$SPARKLE_SDK/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/native/vendor/sparkle/LICENSE" "$APP/Contents/Resources/ThirdParty/Sparkle/"
cp "$BUILD/$NAME-universal" "$APP/Contents/MacOS/$NAME"
chmod +x "$APP/Contents/MacOS/$NAME"
cp "$ROOT/native/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
HELPER="$ROOT/native/vendor/7zip/7zz"
EXPECTED_HELPER_SHA="36ea959367d8f9ac51d47a56dc1f20bfb851f1cd22d6f206e85cb5cbc6ab4577"
[[ "$(shasum -a 256 "$HELPER" | awk '{print $1}')" == "$EXPECTED_HELPER_SHA" ]] || { echo "7-Zip engine checksum mismatch"; exit 1; }
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/ThirdParty/7zip" "$APP/Contents/Resources/TestFixtures"
cp "$HELPER" "$APP/Contents/Helpers/7zz"
cp "$MTP_SDK/WinFileMTP" "$APP/Contents/Helpers/WinFileMTP"
cp "$MTP_SDK/"*.dylib "$APP/Contents/Frameworks/"
mkdir -p "$APP/Contents/Resources/ThirdParty/MTP"
cp "$ROOT/native/vendor/mtp/"* "$ROOT/native/prepare_mtp.sh" "$ROOT/native/build_mtp_helper.sh" "$APP/Contents/Resources/ThirdParty/MTP/"
cp "$ROOT/native/native-build/dependencies/mtp-source/libmtp-1.1.23/COPYING" "$APP/Contents/Resources/ThirdParty/MTP/libmtp-COPYING"
cp "$ROOT/native/native-build/dependencies/mtp-source/libusb-1.0.30/COPYING" "$APP/Contents/Resources/ThirdParty/MTP/libusb-COPYING"
chmod +x "$APP/Contents/Helpers/7zz"
cp "$ROOT/native/vendor/7zip/License.txt" "$ROOT/native/vendor/7zip/LGPL-2.1.txt" "$ROOT/native/vendor/7zip/PROVENANCE.md" "$APP/Contents/Resources/ThirdParty/7zip/"
cp "$ROOT/native/WinFileTests/Fixtures/"* "$APP/Contents/Resources/TestFixtures/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 本地化资源：编译成二进制 plist 加快加载
for lproj in "$ROOT/native/Resources"/*.lproj; do
  [ -d "$lproj" ] || continue
  name="$(basename "$lproj")"
  mkdir -p "$APP/Contents/Resources/$name"
  if [ -f "$lproj/Localizable.strings" ]; then
    /usr/bin/plutil -lint "$lproj/Localizable.strings" >/dev/null 2>&1 \
      && cp "$lproj/Localizable.strings" "$APP/Contents/Resources/$name/" \
      || { echo "   x $name/Localizable.strings 格式有误"; exit 1; }
    /usr/bin/plutil -convert binary1 "$APP/Contents/Resources/$name/Localizable.strings"
  fi
  # 应用名本地化（Dock / 菜单栏显示）
  printf '"CFBundleDisplayName" = "%s";\n"CFBundleName" = "%s";\n' \
    "LeafFiles" \
    "LeafFiles" > "$APP/Contents/Resources/$name/InfoPlist.strings"
  /usr/bin/plutil -convert binary1 "$APP/Contents/Resources/$name/InfoPlist.strings"
  echo "   - $name"
done

echo "== 5/6 代码签名 =="
# Finder metadata inherited by copied resources prevents bundle signing.
# Remove only those unsupported attributes from the generated app.
for attribute in com.apple.FinderInfo com.apple.ResourceFork; do
  /usr/bin/xattr -dr "$attribute" "$APP" 2>/dev/null || true
done
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | { grep -E 'Developer ID Application|Apple Development|Mac Developer' || true; } \
  | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
if [ -n "$IDENTITY" ]; then
  echo "   使用身份：$IDENTITY"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Helpers/7zz"
  for binary in "$APP/Contents/Frameworks/"*.dylib "$APP/Contents/Helpers/WinFileMTP"; do
    /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$binary"
  done
  SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  for nested in "$SPARKLE_FRAMEWORK"/XPCServices/*.xpc "$SPARKLE_FRAMEWORK/Updater.app" "$SPARKLE_FRAMEWORK/Autoupdate"; do
    /usr/bin/codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$IDENTITY" "$nested"
  done
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  echo "   未找到签名身份，使用 ad-hoc 签名（本机可正常运行）"
  /usr/bin/codesign --force --sign - "$APP/Contents/Helpers/7zz"
  for binary in "$APP/Contents/Frameworks/"*.dylib "$APP/Contents/Helpers/WinFileMTP"; do
    /usr/bin/codesign --force --sign - "$binary"
  done
  /usr/bin/codesign --force --sign - "$APP"
fi

echo "== 6/6 校验 =="
/usr/bin/codesign --verify --verbose=1 "$APP/Contents/Helpers/7zz"
/usr/bin/codesign --verify --deep --strict --verbose=1 "$APP"
# Keep a clean verified source for release packaging, plus the customary local copy.
printf '%s\n' "$APP" > "$BUILD/last-built-app-path"
rm -rf "$OUTPUT_APP"
/usr/bin/ditto --noextattr --norsrc "$APP" "$OUTPUT_APP"
echo
echo "构建完成: $APP"
du -sh "$APP"
echo
echo "本构建为本地使用形态：未沙盒，可直接访问整个磁盘。"

# 安装到 /Applications：启动台据此显示应用
if [ -n "$INSTALL_DIR" ]; then
  echo
  echo "== 安装到 $INSTALL_DIR =="
  # 先退出正在运行的实例，避免替换时文件被占用
  pkill -f "$INSTALL_DIR/$NAME.app/Contents/MacOS/$NAME" 2>/dev/null || true
  sleep 1
  rm -rf "$INSTALL_DIR/$NAME.app"
  /usr/bin/ditto --noextattr --norsrc "$APP" "$INSTALL_DIR/$NAME.app"
  # 让 LaunchServices 立即登记（启动台据此显示）
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$INSTALL_DIR/$NAME.app" 2>/dev/null || true
  echo "   已安装：$INSTALL_DIR/$NAME.app"
  echo "   可在启动台 / 聚焦搜索中找到「LeafFiles」"
else
  echo
  echo "仅构建未安装（--in-place）：$APP"
fi
