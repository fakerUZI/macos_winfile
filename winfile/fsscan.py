"""目录遍历与条目元数据构建（资源管理器“详细信息”列的数据来源）。"""

from __future__ import annotations

import os
import stat
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from . import extdb, utils

# 目录列表最大返回条目数
MAX_ENTRIES = 5000
# 达到该数量后并行 stat
PARALLEL_THRESHOLD = 150

KNOWN_BUNDLE_SUFFIXES = set(extdb.BUNDLE_SUFFIXES)


def is_bundle(path: Path, is_dir: bool) -> bool:
    if not is_dir:
        return False
    suffix = path.suffix.lower().lstrip(".")
    if suffix not in KNOWN_BUNDLE_SUFFIXES:
        return False
    if suffix in {"app", "framework", "kext", "bundle", "prefpane", "plugin", "xcodeproj", "xcworkspace"}:
        return True
    # 文档型包（pages/numbers/key…）需存在 Contents 目录
    return (path / "Contents").is_dir()


def is_hidden(name: str) -> bool:
    """点文件视为隐藏；macOS 的 UF_HIDDEN 需要额外系统调用，这里按需跳过。"""
    return name.startswith(".")


def read_app_meta(path: Path) -> dict:
    """读取 .app 包的显示名与 Bundle ID（用于“应用程序”视图）。"""
    info: dict = {"display_name": path.stem if path.suffix.lower() == ".app" else path.name}
    plist = path / "Contents" / "Info.plist"
    if not plist.is_file():
        return info
    code, out, _ = utils.run_cmd(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", "--", str(plist)], timeout=4.0
    )
    if code != 0 or not out.strip():
        return info
    import json

    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return info
    for key in ("CFBundleDisplayName", "CFBundleName"):
        value = data.get(key)
        if isinstance(value, str) and value.strip():
            info["display_name"] = value.strip()
            break
    bundle_id = data.get("CFBundleIdentifier")
    if isinstance(bundle_id, str) and bundle_id.strip():
        info["bundle_id"] = bundle_id.strip()
    short = data.get("CFBundleShortVersionString") or data.get("CFBundleVersion")
    if isinstance(short, str) and short.strip():
        info["version"] = short.strip()
    icon_file = data.get("CFBundleIconFile")
    if isinstance(icon_file, str) and icon_file.strip():
        info["icon_file"] = icon_file.strip()
    icon_name = data.get("CFBundleIconName")
    if isinstance(icon_name, str) and icon_name.strip():
        info["icon_name"] = icon_name.strip()
    return info


def build_entry(
    path: Path,
    st: os.stat_result | None,
    *,
    kind_override: str | None = None,
    deep_type: bool = False,
    name_override: str | None = None,
) -> dict:
    name = name_override or path.name
    if not name:
        name = path.anchor or str(path)

    is_symlink = False
    if st is None:
        try:
            lst = os.lstat(path)
            is_symlink = stat.S_ISLNK(lst.st_mode)
            st = os.stat(path) if not is_symlink else lst
        except OSError:
            st = None
    if st is not None:
        is_symlink = stat.S_ISLNK(st.st_mode)

    is_dir = bool(st and stat.S_ISDIR(st.st_mode))
    if kind_override == "directory":
        is_dir = True
    elif kind_override == "file":
        is_dir = False

    bundle = is_bundle(path, is_dir)
    if bundle:
        category, type_desc, icon = extdb.classify(name, is_dir=True)
    elif is_symlink and not is_dir:
        category, type_desc, icon = extdb.classify(name, is_dir=False, is_symlink=True)
    else:
        category, type_desc, icon = extdb.classify(name, is_dir=is_dir)

    if not is_dir and category == "other" and deep_type:
        detected = utils.file_type_description(str(path))
        if detected:
            type_desc = detected

    ext = extdb.extension_of(name)
    size: int | None = None
    if st is not None:
        if is_dir and not bundle:
            size = None
        elif is_symlink and not is_dir:
            size = None
        else:
            size = int(st.st_size)

    mode = st.st_mode if st else 0
    entry = {
        "path": str(path),
        "name": name,
        "kind": "bundle" if bundle else ("directory" if is_dir else ("symlink" if is_symlink else "file")),
        "category": category,
        "type": type_desc,
        "type_group": extdb.category_meta(category)[0],
        "icon": icon,
        "color": extdb.category_meta(category)[2],
        "ext": ext,
        "size": size,
        "size_h": utils.human_size(size) if size is not None else "",
        "modified": st.st_mtime if st else None,
        "modified_h": utils.short_time(st.st_mtime) if st else "",
        "modified_iso": utils.iso_time(st.st_mtime) if st else None,
        "created": st.st_birthtime if st and hasattr(st, "st_birthtime") else None,
        "created_iso": utils.iso_time(getattr(st, "st_birthtime", None)) if st else None,
        "accessed": st.st_atime if st else None,
        "hidden": is_hidden(name),
        "readonly": not bool(mode & stat.S_IWUSR) if mode else False,
        "link_target": (os.readlink(path) if is_symlink else None),
        "is_bundle": bundle,
    }
    if bundle or (is_dir and name.lower().endswith(".app")):
        meta = read_app_meta(path)
        if meta:
            entry["app"] = meta
            if meta.get("display_name"):
                entry["display_name"] = meta["display_name"]
    return entry


SORT_KEYS = {
    "name": lambda e: (e["name"] or "").lower(),
    "size": lambda e: (e["size"] if e["size"] is not None else -1),
    "type": lambda e: ((e["type"] or "").lower(), (e["name"] or "").lower()),
    "modified": lambda e: (e["modified"] or 0),
    "created": lambda e: (e["created"] or 0),
    "category": lambda e: ((e["category"] or ""), (e["name"] or "").lower()),
}


def sort_entries(entries: list[dict], sort: str, order: str = "asc") -> list[dict]:
    """目录置顶 + 指定字段排序（模拟资源管理器）。"""
    key = SORT_KEYS.get(sort, SORT_KEYS["name"])
    reverse = order == "desc"
    # 资源管理器习惯：文件夹始终排在文件前面
    containers = [e for e in entries if e["kind"] in ("directory", "bundle")]
    others = [e for e in entries if e["kind"] not in ("directory", "bundle")]
    containers.sort(key=key, reverse=reverse)
    others.sort(key=key, reverse=reverse)
    return containers + others


def scan_directory(
    path: Path,
    *,
    show_hidden: bool = False,
    sort: str = "name",
    order: str = "asc",
    limit: int = MAX_ENTRIES,
    deep_type: bool = False,
) -> dict:
    """扫描单个目录，返回资源管理器可用的条目列表。"""
    entries: list[dict] = []
    raw: list[tuple[Path, os.stat_result | None, str | None]] = []
    truncated = False
    errors: list[str] = []

    try:
        with os.scandir(path) as it:
            for item in it:
                if len(raw) >= limit:
                    truncated = True
                    break
                try:
                    st = item.stat(follow_symlinks=False)
                except OSError:
                    st = None
                raw.append((Path(item.path), st, item.name))
    except PermissionError:
        return {
            "entries": [],
            "error": "没有权限访问该目录（macOS 隐私保护）。可在“系统设置 → 隐私与安全性 → 完全磁盘访问权限”中授权终端/浏览器后重试。",
            "permission_denied": True,
        }
    except FileNotFoundError:
        return {"entries": [], "error": "路径不存在"}
    except NotADirectoryError:
        return {"entries": [], "error": "该路径不是文件夹"}
    except OSError as exc:
        return {"entries": [], "error": f"无法读取目录: {exc.strerror or exc}"}

    def work(item: tuple[Path, os.stat_result | None, str | None]) -> dict:
        p, st, nm = item
        entry = build_entry(p, st, deep_type=deep_type, name_override=nm)
        if not show_hidden and entry["hidden"]:
            return None  # type: ignore[return-value]
        return entry

    if len(raw) >= PARALLEL_THRESHOLD:
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(work, raw))
    else:
        results = [work(item) for item in raw]

    for entry in results:
        if entry:
            entries.append(entry)

    entries = sort_entries(entries, sort, order)
    dir_count = sum(1 for e in entries if e["kind"] in ("directory", "bundle"))
    file_count = len(entries) - dir_count
    total_size = sum(e["size"] or 0 for e in entries if e["size"] is not None)

    return {
        "entries": entries,
        "truncated": truncated,
        "counts": {"dirs": dir_count, "files": file_count, "total": len(entries)},
        "top_level_size": total_size,
        "top_level_size_h": utils.human_size(total_size),
        "scanned": len(raw),
        "errors": errors,
    }
