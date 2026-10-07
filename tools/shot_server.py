#!/usr/bin/env python3
"""启动一个仅用于截图/自测的 winfile 服务实例（静态目录可切换）。

用法:
    python3 tools/shot_server.py --web /tmp/stage --port 8792 --token shottoken
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from winfile.config import Config  # noqa: E402
from winfile.server import build_server  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--web", required=True)
    parser.add_argument("--port", type=int, default=8792)
    parser.add_argument("--token", default="shottoken")
    args = parser.parse_args()

    config = Config()
    config.web_dir = Path(args.web).resolve()
    config.port = args.port
    config.token = args.token
    server = build_server(config)
    config.write_token_file()
    print(f"[shot-server] http://{config.host}:{config.port}/ （静态目录 {config.web_dir}）", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
