#!/bin/bash
# 打包可发布的 zip（用于 GitHub Releases）
#
#   ./native/make_release.sh              # 用 Info.plist 里的版本号
#   ./native/make_release.sh 2.1.0        # 指定版本号
#
# 说明
#   必须用 ditto 而非 zip：zip 会丢失扩展属性与签名信息，
#   解压后应用可能无法通过签名校验。ditto 是 Apple 推荐的打包方式。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="WinFile"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$ROOT/native/Info.plist" 2>/dev/null || echo "0.0.0")"
fi

DIST="$ROOT/dist"
ZIP="$DIST/$NAME-$VERSION.zip"

echo "== 1/4 构建（不安装）=="
"$ROOT/native/build_native.sh" --in-place

echo
echo "== 2/4 打包 $NAME-$VERSION.zip =="
mkdir -p "$DIST"
rm -f "$ZIP"
# --keepParent：解压后得到 WinFile.app 而不是散开的文件
# ditto 保留签名与扩展属性（zip 会丢失，导致签名失效）
/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$ROOT/$NAME.app" "$ZIP"

echo
echo "== 3/4 生成校验值 =="
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo
echo "== 4/4 检查产物 =="
du -sh "$ZIP" | sed 's/^/   体积: /'
SIZE_MB=$(( $(stat -f%z "$ZIP") / 1024 / 1024 ))
if [ "$SIZE_MB" -gt 100 ]; then
  echo "   提示：超过 100 MB，GitHub 单文件上限仍可接受（2 GB），但网页上传较慢"
fi
echo
echo "打包完成：$ZIP"
echo
echo "发布到 GitHub Releases："
echo "  1. 打开仓库 → Releases → Draft a new release"
echo "  2. Tag 填 v$VERSION，标题填 WinFile $VERSION"
echo "  3. 上传 $ZIP"
echo "  4. 说明里贴上安装步骤（见 README「安装」章节）"
