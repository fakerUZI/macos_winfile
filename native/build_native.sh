#!/bin/bash
# 构建原生 SwiftUI 版 WinFile.app
#
#   ./native/build_native.sh                # 构建到项目目录
#   ./native/build_native.sh --in-place     # 同上（保留参数以兼容旧命令）
#
# 本地使用形态：未沙盒，可直接访问整个磁盘。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="WinFile"
SRC="$ROOT/native/WinFile"
BUILD="$ROOT/native/native-build"
APP="$ROOT/$NAME.app"

for arg in "$@"; do
  case "$arg" in
    --in-place) APP="$ROOT/$NAME.app" ;;
  esac
done

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
  "$ROOT/native/WinFileTests/NativeTestSuite.swift"
  "$ROOT/native/WinFileTests/SnapshotRenderer.swift"
  "$ROOT/native/WinFileTests/ViewTreeDumper.swift"
  "$ROOT/native/WinFileTests/TabSmokeTest.swift"
  "$ROOT/native/WinFileTests/A11yProbe.swift"
)

build_arch() {
  local arch="$1"
  /usr/bin/swiftc -swift-version 5 -O \
    -target "${arch}-apple-macos13.0" \
    -framework AppKit -framework SwiftUI -framework Security \
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
cp "$BUILD/$NAME-universal" "$APP/Contents/MacOS/$NAME"
chmod +x "$APP/Contents/MacOS/$NAME"
cp "$ROOT/native/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
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
    "$( [ "$name" = "zh-Hans.lproj" ] && echo "WinFile 文件管理器" || echo "WinFile" )" \
    "WinFile" > "$APP/Contents/Resources/$name/InfoPlist.strings"
  /usr/bin/plutil -convert binary1 "$APP/Contents/Resources/$name/InfoPlist.strings"
  echo "   - $name"
done

echo "== 5/6 代码签名 =="
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | { grep -E 'Developer ID Application|Apple Development|Mac Developer' || true; } \
  | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
if [ -n "$IDENTITY" ]; then
  echo "   使用身份：$IDENTITY"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  echo "   未找到签名身份，使用 ad-hoc 签名（本机可正常运行）"
  /usr/bin/codesign --force --sign - "$APP" 2>&1 | tail -2 || true
fi

echo "== 6/6 校验 =="
/usr/bin/codesign --verify --verbose=1 "$APP" 2>&1 | tail -2 || true
echo
echo "构建完成: $APP"
du -sh "$APP"
echo
echo "本构建为本地使用形态：未沙盒，可直接访问整个磁盘。"
