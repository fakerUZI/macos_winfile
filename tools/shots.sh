#!/bin/bash
# 生成界面截图（开发期视觉验证）
#
#   1) 把 web/ 复制到临时目录，并注入截图脚本
#   2) 起一个只用于截图的 winfile 实例
#   3) 用 Chrome DevTools Protocol 逐个视图截图（见 tools/capture.mjs）
#
# 用法: ./tools/shots.sh [输出目录] [每视图额外等待毫秒]
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/docs/screenshots}"
WAIT="${2:-5000}"
STAGE=/tmp/wf-shot-stage
PORT=8792

rm -rf "$STAGE"; mkdir -p "$STAGE" "$OUT"
cp -R "$ROOT/web/." "$STAGE/"
python3 - "$STAGE/index.html" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
html = p.read_text(encoding='utf-8')
html = html.replace('</body>', '<script src="/js/shot-view.js"></script>\n<script src="/js/shot-base.js"></script>\n</body>', 1)
p.write_text(html, encoding='utf-8')
PY

lsof -ti tcp:$PORT 2>/dev/null | xargs -r kill 2>/dev/null || true
python3 "$ROOT/tools/shot_server.py" --web "$STAGE" --port "$PORT" --token shottoken >/tmp/wf-shot-server.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 2

node "$ROOT/tools/capture.mjs" "http://127.0.0.1:$PORT/?token=shottoken" "$STAGE" "$OUT" --wait "$WAIT"
