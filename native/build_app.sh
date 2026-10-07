#!/bin/bash
# 构建 WinFile.app —— 原生 macOS 应用（WKWebView 外壳 + 内置 Python 服务）
#
#   ./native/build_app.sh             # 构建到 ~/Applications/WinFile.app
#   ./native/build_app.sh --in-place  # 构建到项目目录下的 WinFile.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="WinFile"
IN_PLACE=0
[ "${1:-}" = "--in-place" ] && IN_PLACE=1

if [ "$IN_PLACE" = "1" ]; then
  APP="$ROOT/$NAME.app"
else
  APP="$HOME/Applications/$NAME.app"
fi

echo "== 1/5 生成应用图标 =="
python3 "$ROOT/tools/make_icon.py" >/dev/null
ICNS="$ROOT/docs/icon/AppIcon.icns"
[ -f "$ICNS" ] || { echo "图标生成失败"; exit 1; }
echo "   $ICNS"

echo "== 2/5 编译原生外壳（Swift，arm64 + x86_64） =="
BIN_DIR="$ROOT/native/build"
mkdir -p "$BIN_DIR"
for ARCH in arm64 x86_64; do
  # shellcheck disable=SC2086
  /usr/bin/swiftc -O -target "$ARCH-apple-macos11.0" \
    -framework AppKit -framework WebKit \
    -o "$BIN_DIR/$NAME-$ARCH" "$ROOT/native/WinFileApp.swift" 2>&1 | grep -v "^$" || true
done
/usr/bin/lipo -create "$BIN_DIR/$NAME-arm64" "$BIN_DIR/$NAME-x86_64" -output "$BIN_DIR/$NAME"
/usr/bin/lipo -info "$BIN_DIR/$NAME"

echo "== 3/5 编译原生工具（图标提取 + 打开方式查询）=="
for ARCH in arm64 x86_64; do
  /usr/bin/swiftc -O -target "$ARCH-apple-macos11.0" -framework AppKit \
    -o "$BIN_DIR/winfile-icon-$ARCH" "$ROOT/native/winfile-icon.swift"
  /usr/bin/swiftc -O -target "$ARCH-apple-macos11.0" -framework AppKit -framework CoreServices \
    -framework UniformTypeIdentifiers \
    -o "$BIN_DIR/winfile-apps-$ARCH" "$ROOT/native/winfile-apps.swift"
done
/usr/bin/lipo -create "$BIN_DIR/winfile-icon-arm64" "$BIN_DIR/winfile-icon-x86_64" -output "$BIN_DIR/winfile-icon"
/usr/bin/lipo -create "$BIN_DIR/winfile-apps-arm64" "$BIN_DIR/winfile-apps-x86_64" -output "$BIN_DIR/winfile-apps"

echo "== 4/5 组装应用包 =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$NAME" "$APP/Contents/MacOS/$NAME"
cp "$BIN_DIR/winfile-icon" "$APP/Contents/Resources/winfile-icon"
cp "$BIN_DIR/winfile-apps" "$APP/Contents/Resources/winfile-apps"
chmod +x "$APP/Contents/MacOS/$NAME" "$APP/Contents/Resources/winfile-icon" "$APP/Contents/Resources/winfile-apps"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/native/Info.plist" "$APP/Contents/Info.plist"

# 内置后端与前端，使 .app 可以单独拷贝到任何位置运行
mkdir -p "$APP/Contents/Resources/backend/winfile"
cp "$ROOT/winfile.py" "$APP/Contents/Resources/backend/"
cp "$ROOT"/winfile/*.py "$APP/Contents/Resources/backend/winfile/"
cp -R "$ROOT/web" "$APP/Contents/Resources/web"
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 让系统刷新图标缓存
touch "$APP"

echo "== 5/5 代码签名（ad-hoc） =="
/usr/bin/codesign --force --deep --sign - "$APP" 2>&1 | tail -2 || echo "   （签名失败可忽略，仅影响首次启动提示）"

echo
echo "构建完成: $APP"
du -sh "$APP"
