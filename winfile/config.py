"""运行配置：端口、绑定地址、访问令牌与可浏览根目录白名单。"""

from __future__ import annotations

import os
import secrets
import socket
from dataclasses import dataclass, field
from pathlib import Path

HOME = Path.home()


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def port_available(port: int, host: str = "127.0.0.1") -> bool:
    """端口是否可绑定。"""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind((host, port))
        except OSError:
            return False
    return True


def find_free_port(preferred: int, host: str = "127.0.0.1", tries: int = 30) -> int:
    """从 preferred 开始找可用端口（0 表示交给系统分配）。"""
    if preferred == 0:
        return 0
    for candidate in range(preferred, preferred + tries):
        if port_available(candidate, host):
            return candidate
    return 0


def default_visible_roots() -> list[Path]:
    """可访问的根目录（越界访问一律拒绝，避免变成任意文件读取器）。"""
    import tempfile

    roots: list[Path] = [Path("/")]
    for candidate in (
        Path("/Applications"),
        Path("/System/Applications"),
        Path("/System/Library/CoreServices"),
        Path("/Library"),
        Path("/Volumes"),
        Path("/opt"),
        Path("/usr/local"),
        Path("/private/tmp"),
        Path("/tmp"),
        Path("/var/folders"),
        Path("/Users/Shared"),
        HOME,
    ):
        try:
            if candidate.exists():
                roots.append(candidate.resolve())
        except OSError:
            continue
    try:
        roots.append(Path(tempfile.gettempdir()).resolve())
    except OSError:
        pass
    # 去重且保持顺序；/=任意可读路径，故它总是优于其他项。
    seen: set[str] = set()
    unique: list[Path] = []
    for root in roots:
        key = str(root)
        if key not in seen:
            seen.add(key)
            unique.append(root)
    return unique


@dataclass
class Config:
    host: str = ""
    port: int = 0
    token: str = ""
    state_dir: Path = field(
        default_factory=lambda: Path(
            os.environ.get("WINFILE_STATE_DIR", str(HOME / ".winfile-mac"))
        )
    )
    web_dir: Path = field(
        default_factory=lambda: Path(__file__).resolve().parent.parent / "web"
    )
    visible_roots: list[Path] = field(default_factory=default_visible_roots)
    open_browser: bool = True
    cache_ttl: int = 0
    # 桌面应用模式：由 WinFile.app 启动，需向宿主程序报告端口与令牌
    desktop_mode: bool = False
    desktop_status_file: Path | None = None
    # 原生工具（WinFile.app 内置）：图标提取 / 打开方式查询
    icon_tool: Path | None = None
    apps_tool: Path | None = None

    def __post_init__(self) -> None:
        # 这些值必须在实例化时读取环境变量：dataclass 的默认值在导入期求值，
        # 那样会导致命令行 --port/--host 被忽略。
        if not self.host:
            self.host = os.environ.get("WINFILE_HOST", "127.0.0.1")
        if not self.port:
            self.port = _env_int("WINFILE_PORT", 8790)
        if not self.token:
            self.token = os.environ.get("WINFILE_TOKEN") or secrets.token_urlsafe(24)
        if not self.cache_ttl:
            self.cache_ttl = _env_int("WINFILE_CACHE_TTL", 45)
        self.open_browser = os.environ.get("WINFILE_NO_BROWSER") != "1"
        self.desktop_mode = os.environ.get("WINFILE_DESKTOP") == "1"
        if self.icon_tool is None and os.environ.get("WINFILE_ICON_TOOL"):
            self.icon_tool = Path(os.environ["WINFILE_ICON_TOOL"])
        if self.apps_tool is None and os.environ.get("WINFILE_APPS_TOOL"):
            self.apps_tool = Path(os.environ["WINFILE_APPS_TOOL"])
        if self.desktop_status_file is None and self.desktop_mode:
            self.desktop_status_file = self.state_dir / "desktop-status.json"

    def ensure_state_dir(self) -> Path:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        (self.state_dir / "icons").mkdir(parents=True, exist_ok=True)
        (self.state_dir / "thumbs").mkdir(parents=True, exist_ok=True)
        return self.state_dir

    def _session_payload(self) -> dict:
        return {
            "url": f"http://{self.host}:{self.port}/",
            "token": self.token,
            "port": self.port,
            "host": self.host,
            "home": str(HOME),
            "pid": os.getpid(),
        }

    def write_token_file(self) -> Path:
        """写入会话信息；桌面模式额外写宿主程序等待的状态文件。"""
        self.ensure_state_dir()
        import json

        path = self.state_dir / "session.json"
        path.write_text(json.dumps(self._session_payload(), ensure_ascii=False, indent=2), encoding="utf-8")
        if self.desktop_mode and self.desktop_status_file:
            self.desktop_status_file.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.desktop_status_file.with_suffix(".tmp")
            tmp.write_text(json.dumps(self._session_payload(), ensure_ascii=False), encoding="utf-8")
            tmp.replace(self.desktop_status_file)  # 原子替换，宿主可安全轮询
        return path
