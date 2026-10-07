#!/usr/bin/env python3
"""macOS 文件管理器启动入口。

用法:
    python3 winfile.py                 # 启动服务并自动打开浏览器
    python3 winfile.py --port 8888     # 指定端口
    python3 winfile.py --no-browser    # 不自动打开浏览器
    python3 winfile.py --check         # 自检：导入模块 + 目录扫描是否正常
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from winfile.config import Config  # noqa: E402


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Windows 资源管理器风格的 macOS 文件管理器")
    parser.add_argument("--port", type=int, default=None, help="HTTP 端口（默认 8790）")
    parser.add_argument("--host", default=None, help="绑定地址（默认 127.0.0.1）")
    parser.add_argument("--no-browser", action="store_true", help="启动后不自动打开浏览器")
    parser.add_argument("--token", default=None, help="自定义访问令牌")
    parser.add_argument("--check", action="store_true", help="只做自检，不启动服务")
    parser.add_argument("--desktop", action="store_true", help="桌面应用模式（由 WinFile.app 调用）")
    parser.add_argument("--status-file", default=None, help="桌面模式下向宿主报告端口与令牌的文件")
    parser.add_argument("--auto-port", action="store_true", help="端口被占用时自动改用空闲端口")
    parser.add_argument("--web", default=None, help="前端静态资源目录（桌面应用内置时使用）")
    return parser.parse_args(argv)


def make_config(args: argparse.Namespace) -> Config:
    if args.port:
        os.environ["WINFILE_PORT"] = str(args.port)
    if args.host:
        os.environ["WINFILE_HOST"] = args.host
    if args.token:
        os.environ["WINFILE_TOKEN"] = args.token
    if args.no_browser:
        os.environ["WINFILE_NO_BROWSER"] = "1"
    if args.desktop:
        os.environ["WINFILE_DESKTOP"] = "1"
        os.environ["WINFILE_NO_BROWSER"] = "1"
    config = Config()
    if args.web:
        config.web_dir = Path(args.web).expanduser()
    if args.status_file:
        config.desktop_status_file = Path(args.status_file).expanduser()
    elif config.desktop_mode:
        config.desktop_status_file = config.state_dir / "desktop-status.json"
    return config


def self_check(config: Config) -> int:
    from winfile import fsscan, macrofs, utils

    problems: list[str] = []
    print("== winfile-mac 自检 ==")
    print(f"Python      : {sys.version.split()[0]}")
    print(f"家目录      : {Path.home()}")
    print(f"状态目录    : {config.state_dir}")

    for tool, label in (("/usr/bin/mdfind", "Spotlight"), ("/usr/bin/sips", "sips 缩略图"), ("/usr/bin/open", "open")):
        status = "可用" if Path(tool).exists() else "缺失"
        print(f"{label:12s}: {status} ({tool})")
        if not Path(tool).exists():
            problems.append(f"缺少 {tool}")

    listing = fsscan.scan_directory(Path.home(), show_hidden=False, sort="name")
    print(f"扫描家目录  : {listing.get('counts', {}).get('total', 0)} 项")
    if listing.get("error"):
        problems.append(f"扫描失败: {listing['error']}")

    macro = macrofs.MacroFS(config)
    apps = macro.list_apps(refresh=True)
    print(f"应用程序    : {apps['counts']['total']} 个")
    completion = macro.complete("~/Doc", limit=5)
    print(f"路径补全    : ~/Doc -> {[s['name'] for s in completion['suggestions']]}")
    recent = macro.recent(days=30, limit=5, refresh=True)
    print(f"最近使用    : {recent['total']} 项（来源 {recent['source']}）")

    if problems:
        print("\n发现问题:")
        for item in problems:
            print(f"  - {item}")
        return 1
    print("\n自检通过 ✔")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    config = make_config(args)
    if args.auto_port:
        from winfile.config import find_free_port

        chosen = find_free_port(config.port, config.host)
        if chosen != config.port:
            print(f"[winfile-mac] 端口 {config.port} 被占用，改用 {chosen}")
            config.port = chosen
    if args.check:
        return self_check(config)
    from winfile.server import serve_forever

    serve_forever(config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
