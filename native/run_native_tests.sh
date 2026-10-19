#!/bin/bash
# 逻辑层测试：
#   1) 编译命令行版本（快速，适合开发迭代）
#   2) 同时构建 .app 并用真实 bundle 环境再跑一次（本地化与资源可用）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/native/WinFile"
BUILD="$ROOT/native/native-build"
mkdir -p "$BUILD"
OPT=-O
if [[ " ${*:-} " == *" --quick "* ]]; then OPT=-Onone; fi
TEST_ARGS=(--run-tests)
if [[ " ${*:-} " == *" --skip-device-tests "* ]]; then TEST_ARGS+=(--skip-device-tests); fi

CORE=(
  "$SRC/Localization.swift"
  "$SRC/AppUpdatePolicy.swift"
  "$SRC/FolderPickerModel.swift"
  "$SRC/SidebarFolderDrop.swift"
  "$SRC/Models.swift"
  "$SRC/FileSystemService.swift"
  "$SRC/PlacesService.swift"
  "$SRC/ClosureMenuItem.swift"
  "$SRC/ContextMenuCatcher.swift"
  "$SRC/FSEngine.swift"
  "$SRC/FileClipboard.swift"
  "$SRC/QuickLookService.swift"
  "$SRC/DirectoryWatcher.swift"
  "$SRC/BrowserSession.swift"
  "$SRC/FileSearchCriteria.swift"
  "$SRC/BatchRenameService.swift"
  "$SRC/DuplicateFileService.swift"
  "$SRC/FileOperationHistory.swift"
  "$SRC/FileTransferService.swift"
  "$SRC/BrowserModel.swift"
  "$SRC/TabManager.swift"
  "$SRC/TabDiagnostics.swift"
  "$SRC/AppDataService.swift"
  "$SRC/WeChatCleanupService.swift"
  "$SRC/WeChatCleanupModel.swift"
  "$SRC/ArchiveService.swift"
  "$SRC/ArchiveExtraction.swift"
  "$SRC/ThumbnailService.swift"
  "$SRC/FileAssociations.swift"
  "$SRC/DefaultAppService.swift"
  "$SRC/SidebarPreferences.swift"
  "$SRC/SortOrderBridge.swift"
  "$SRC/LayoutPreferences.swift"
  "$SRC/TableDoubleClick.swift"
  "$SRC/FileTileMarker.swift"
  $(find "$SRC/Android" -name "*.swift" | sort)
)

echo "== 1) 命令行测试 =="
/usr/bin/swiftc -swift-version 5 "$OPT" \
  -target arm64-apple-macos13.0 \
  -framework AppKit -framework SwiftUI \
  -o "$BUILD/WinFileTests" \
  "${CORE[@]}" \
  "$ROOT/native/WinFileTests/NativeTestSuite.swift" \
  "$ROOT/native/WinFileTests/cli-main.swift"
"$BUILD/WinFileTests" "${TEST_ARGS[@]}"
if [[ " ${*:-} " == *" --cli-only "* ]]; then exit 0; fi

echo
echo "== 2) 构建应用并在真实 bundle 中测试 =="
"$ROOT/native/build_native.sh" --in-place >/dev/null
APP="$(cat "$BUILD/last-built-app-path")"
"$APP/Contents/MacOS/WinFile" "${TEST_ARGS[@]}"

echo
echo "== 3) 页签切换冒烟测试（真实界面像素比对）=="
SMOKE_LOG="$(mktemp -t winfile-tabtest)"
if [[ " ${*:-} " == *" --skip-device-tests "* ]]; then
  "$APP/Contents/MacOS/WinFile" --selftest-tabs "$SMOKE_LOG" --skip-device-tests
else
  "$APP/Contents/MacOS/WinFile" --selftest-tabs "$SMOKE_LOG"
fi
cat "$SMOKE_LOG"
rm -f "$SMOKE_LOG"
