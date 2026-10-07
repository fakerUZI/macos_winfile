#!/bin/bash
# 逻辑层测试：
#   1) 编译命令行版本（快速，适合开发迭代）
#   2) 同时构建 .app 并用真实 bundle 环境再跑一次（本地化与资源可用）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/native/WinFile"
BUILD="$ROOT/native/native-build"
mkdir -p "$BUILD"

CORE=(
  "$SRC/Localization.swift"
  "$SRC/Models.swift"
  "$SRC/FileSystemService.swift"
  "$SRC/PlacesService.swift"
  "$SRC/ClosureMenuItem.swift"
  "$SRC/ContextMenuCatcher.swift"
  "$SRC/FSEngine.swift"
  "$SRC/BrowserModel.swift"
  "$SRC/TabManager.swift"
  "$SRC/TabDiagnostics.swift"
  "$SRC/AppDataService.swift"
  "$SRC/TableDoubleClick.swift"
  "$SRC/FileTileMarker.swift"
  $(find "$SRC/Android" -name "*.swift" | sort)
)

echo "== 1) 命令行测试 =="
/usr/bin/swiftc -swift-version 5 -O \
  -target arm64-apple-macos13.0 \
  -framework AppKit -framework SwiftUI \
  -o "$BUILD/WinFileTests" \
  "${CORE[@]}" \
  "$ROOT/native/WinFileTests/NativeTestSuite.swift" \
  "$ROOT/native/WinFileTests/cli-main.swift"
"$BUILD/WinFileTests"

echo
echo "== 2) 构建应用并在真实 bundle 中测试 =="
"$ROOT/native/build_native.sh" --in-place >/dev/null
"$ROOT/WinFile.app/Contents/MacOS/WinFile" --run-tests

echo
echo "== 3) 页签切换冒烟测试（真实界面像素比对）=="
SMOKE_LOG="$(mktemp -t winfile-tabtest)"
"$ROOT/WinFile.app/Contents/MacOS/WinFile" --selftest-tabs "$SMOKE_LOG"
cat "$SMOKE_LOG"
rm -f "$SMOKE_LOG"
