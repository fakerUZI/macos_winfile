"""通用工具：路径处理、时间/大小格式化、外部命令调用、磁盘统计。"""

from __future__ import annotations

import functools
import os
import shutil
import subprocess
import time
from pathlib import Path


# --------------------------------------------------------------------------- 路径

def expand(path: str | None) -> Path:
    """把用户输入（支持 ~、相对路径）规范成绝对 Path，不要求存在。"""
    if not path:
        return Path.home()
    raw = str(path).strip()
    if not raw:
        return Path.home()
    # 兼容 Windows 风格反斜杠输入
    if "\\" in raw and "/" not in raw[:3]:
        raw = raw.replace("\\", "/")
    raw = os.path.expanduser(raw)
    p = Path(raw)
    if not p.is_absolute():
        p = Path.home() / p
    # 规范化 . / .. 但不做 realpath（符号链接需保留）
    return Path(os.path.normpath(str(p)))


def norm_key(path: Path | str) -> str:
    return os.path.normpath(str(path))


def is_within(child: Path, roots: list[Path]) -> bool:
    """child 是否位于白名单任一目录内（含自身）。"""
    try:
        target = os.path.realpath(str(child))
    except OSError:
        return False
    for root in roots:
        root_str = os.path.realpath(str(root))
        if target == root_str or target.startswith(root_str.rstrip("/") + "/"):
            return True
    return False


def parent_of(path: Path) -> Path | None:
    parent = path.parent
    if str(parent) == str(path):
        return None
    return parent


def display_name(path: Path) -> str:
    name = path.name
    if not name:
        return path.anchor or str(path)
    return name


# --------------------------------------------------------------------------- 格式化

_SIZE_UNITS = ("B", "KB", "MB", "GB", "TB", "PB")


def human_size(size: int | None) -> str:
    if size is None:
        return ""
    if size < 0:
        return ""
    value = float(size)
    for unit in _SIZE_UNITS:
        if value < 1024 or unit == _SIZE_UNITS[-1]:
            if unit == "B":
                return f"{int(value)} B"
            return f"{value:.1f} {unit}" if value < 100 else f"{value:.0f} {unit}"
        value /= 1024
    return f"{value:.0f} PB"


def iso_time(ts: float | None) -> str | None:
    if not ts or ts <= 0:
        return None
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(ts))
    except (OverflowError, OSError, ValueError):
        return None


def short_time(ts: float | None) -> str:
    """资源管理器风格的时间显示。"""
    if not ts or ts <= 0:
        return ""
    now = time.time()
    delta = now - ts
    if delta < 60:
        return "刚刚"
    if delta < 3600:
        return f"{int(delta // 60)} 分钟前"
    if delta < 86400 and time.localtime(ts).tm_mday == time.localtime(now).tm_mday:
        return "今天 " + time.strftime("%H:%M", time.localtime(ts))
    if delta < 172800:
        return "昨天 " + time.strftime("%H:%M", time.localtime(ts))
    if time.localtime(ts).tm_year == time.localtime(now).tm_year:
        return time.strftime("%m/%d %H:%M", time.localtime(ts))
    return time.strftime("%Y/%m/%d %H:%M", time.localtime(ts))


# --------------------------------------------------------------------------- 外部命令

def which(name: str) -> str | None:
    return shutil.which(name)


def run_cmd(
    args: list[str],
    timeout: float = 8.0,
    stdin: bytes | None = None,
    env: dict[str, str] | None = None,
) -> tuple[int, str, str]:
    """执行外部命令，返回 (returncode, stdout, stderr)。失败不抛异常。"""
    try:
        proc = subprocess.run(
            args,
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            env=env,
        )
    except FileNotFoundError:
        return 127, "", f"未找到命令: {args[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", "命令超时"
    except OSError as exc:  # pragma: no cover
        return 126, "", str(exc)
    out = proc.stdout.decode("utf-8", "replace")
    err = proc.stderr.decode("utf-8", "replace")
    return proc.returncode, out, err


@functools.lru_cache(maxsize=4096)
def file_type_description(path: str) -> str:
    """用 file(1) 探测真实类型，带缓存。"""
    code, out, _ = run_cmd(["/usr/bin/file", "-b", "--", path], timeout=3.0)
    if code != 0 or not out.strip():
        return ""
    desc = out.strip().splitlines()[0]
    # 精简描述：去掉编解码细节
    for sep in (";", ","):
        if sep in desc:
            head = desc.split(sep)[0].strip()
            if head:
                desc = head
                break
    return desc if len(desc) <= 60 else desc[:57] + "…"


# --------------------------------------------------------------------------- 磁盘

def volume_info(path: Path) -> dict:
    try:
        usage = shutil.disk_usage(str(path))
    except OSError:
        return {}
    return {
        "total": usage.total,
        "used": usage.used,
        "free": usage.free,
        "total_h": human_size(usage.total),
        "used_h": human_size(usage.used),
        "free_h": human_size(usage.free),
        "percent": round(usage.used / usage.total * 100, 1) if usage.total else 0,
    }


def list_volumes() -> list[dict]:
    """列出挂载的卷（/ 与 /Volumes/*）。"""
    volumes: list[dict] = []
    seen: set[str] = set()

    def add(mount: Path, name: str) -> None:
        key = str(mount)
        if key in seen or not mount.exists():
            return
        seen.add(key)
        info = volume_info(mount)
        entry = {
            "name": name,
            "path": key,
            "icon": "💽" if key == "/" else "🗄️",
            "removable": not key.startswith("/System"),
        }
        entry.update(info)
        volumes.append(entry)

    add(Path("/"), "Macintosh HD")
    volumes_root = Path("/Volumes")
    if volumes_root.is_dir():
        try:
            for child in sorted(volumes_root.iterdir(), key=lambda p: p.name.lower()):
                if child.name.startswith("."):
                    continue
                add(child, child.name)
        except OSError:
            pass
    return volumes


def dir_size(path: Path, budget_seconds: float = 4.0, max_entries: int = 400_000) -> dict:
    """递归统计目录大小，超时/超量则提前返回 partial=True。"""
    total = 0
    files = 0
    dirs = 0
    deadline = time.monotonic() + budget_seconds
    partial = False
    stack = [path]
    while stack:
        current = stack.pop()
        try:
            with os.scandir(current) as it:
                for entry in it:
                    if time.monotonic() > deadline or files + dirs > max_entries:
                        partial = True
                        stack.clear()
                        break
                    try:
                        if entry.is_symlink():
                            continue
                        if entry.is_dir(follow_symlinks=False):
                            dirs += 1
                            stack.append(Path(entry.path))
                        else:
                            files += 1
                            total += entry.stat(follow_symlinks=False).st_size
                    except OSError:
                        continue
        except OSError:
            continue
    return {
        "size": total,
        "size_h": human_size(total),
        "files": files,
        "dirs": dirs,
        "partial": partial,
    }
