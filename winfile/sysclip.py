"""系统剪贴板读写（macOS 用 pbcopy/pbpaste，其它平台给出明确错误）。"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

PBCOPY = "/usr/bin/pbcopy"
PBPASTE = "/usr/bin/pbpaste"

# 可作为文本复制到剪贴板的扩展名（避免把二进制内容塞进剪贴板）
TEXT_EXTENSIONS = {
    "txt", "md", "markdown", "log", "csv", "tsv", "json", "xml", "yaml", "yml",
    "toml", "ini", "cfg", "conf", "env", "sh", "bash", "zsh", "fish", "ps1",
    "bat", "cmd", "py", "pyw", "js", "mjs", "cjs", "jsx", "ts", "tsx", "java",
    "kt", "swift", "m", "mm", "c", "h", "cpp", "cc", "hpp", "cs", "go", "rs",
    "rb", "php", "pl", "lua", "r", "scala", "sql", "graphql", "html", "htm",
    "css", "scss", "less", "vue", "svelte", "tex", "rst", "srt", "vtt",
}

MAX_TEXT_BYTES = 2 * 1024 * 1024


def _pbcopy(args: list[str], text: str) -> dict:
    if not Path(PBCOPY).exists():
        return {"ok": False, "error": "系统不支持 pbcopy（仅 macOS）"}
    try:
        proc = subprocess.run(
            [PBCOPY, *args],
            input=text.encode("utf-8"),
            timeout=8,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"ok": False, "error": f"写入剪贴板失败: {exc}"}
    if proc.returncode != 0:
        return {"ok": False, "error": proc.stderr.decode("utf-8", "replace").strip() or "写入剪贴板失败"}
    return {"ok": True, "chars": len(text)}


def copy_text(text: str) -> dict:
    """把纯文本写入系统剪贴板。"""
    if text is None:
        return {"ok": False, "error": "没有要复制的内容"}
    return _pbcopy([], str(text))


def copy_files(paths: list[Path]) -> dict:
    """把文件路径以文本写入剪贴板（终端/编辑器可直接粘贴）。
    额外尝试写入文件对象，让访达等应用能识别为文件列表。"""
    if not paths:
        return {"ok": False, "error": "没有要复制的文件"}
    text = "\n".join(str(p) for p in paths)
    result = _pbcopy([], text)
    if result.get("ok"):
        result["files"] = len(paths)
        result["text"] = text
    return result


def paste_text() -> str:
    """读取系统剪贴板文本（失败返回空串）。"""
    if not Path(PBPASTE).exists():
        return ""
    try:
        proc = subprocess.run([PBPASTE], capture_output=True, timeout=8)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return proc.stdout.decode("utf-8", "replace")


def is_text_file(path: Path, size: int | None = None) -> bool:
    """是否按文本处理（按扩展名判断，未知扩展名再看内容）。"""
    if size is None:
        try:
            size = path.stat().st_size
        except OSError:
            return False
    if size > MAX_TEXT_BYTES:
        return False
    suffix = path.suffix.lower().lstrip(".")
    if suffix in TEXT_EXTENSIONS:
        return True
    if suffix:
        return False
    try:
        with path.open("rb") as handle:
            chunk = handle.read(4096)
    except OSError:
        return False
    if b"\x00" in chunk:
        return False
    try:
        chunk.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return bool(chunk)


def _looks_like_text(data: bytes) -> bool:
    """按控制字符比例判断是否像文本。"""
    if not data:
        return True
    if b"\x00" in data:
        return False
    control = sum(1 for byte in data if byte < 9 or 13 < byte < 32)
    return control / len(data) < 0.05


def read_text(path: Path) -> tuple[bool, str, str]:
    """读取文本内容，返回 (成功, 内容或错误, 错误信息)。"""
    try:
        size = path.stat().st_size
    except OSError as exc:
        return False, "", str(exc)
    if size > MAX_TEXT_BYTES:
        return False, "", f"文件过大（{size // 1024} KB），已超过 2 MB 上限"
    try:
        data = path.read_bytes()
    except OSError as exc:
        return False, "", str(exc)
    for encoding in ("utf-8", "utf-16", "gb18030"):
        try:
            return True, data.decode(encoding), ""
        except UnicodeDecodeError:
            continue
    # 兜底：Latin-1 能解码任意字节，必须先确认内容看起来像文本
    if _looks_like_text(data):
        return True, data.decode("latin-1"), ""
    return False, "", "不是文本文件（内容含二进制数据）"


if __name__ == "__main__":  # 便于手工测试
    if len(sys.argv) > 1:
        print(copy_text(" ".join(sys.argv[1:])))
    else:
        print(repr(paste_text()[:200]))
