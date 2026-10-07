"""macOS 集成层：应用程序、最近使用、文件分类（Spotlight/mdfind）、图标提取、废纸篓。"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import quote

from . import extdb, fsscan, sysclip, utils

HOME = Path.home()
MDFIND = "/usr/bin/mdfind"
SIPS = "/usr/bin/sips"
PLUTIL = "/usr/bin/plutil"
OSASCRIPT = "/usr/bin/osascript"
OPEN = "/usr/bin/open"

APP_DIRS = [
    Path("/Applications"),
    Path("/Applications/Utilities"),
    Path("/System/Applications"),
    Path("/System/Applications/Utilities"),
    HOME / "Applications",
]

# 最近使用/分类扫描时跳过的目录名（避免命中缓存与系统目录）
SKIP_DIR_NAMES = {
    "Library", ".Trash", ".git", "node_modules", ".venv", "venv", "__pycache__",
    ".cache", ".npm", ".pnpm-store", ".cargo", ".rustup", ".gradle", ".m2",
    "site-packages", ".local", ".conda", "Caches", "Containers", "Group Containers",
}

# 分类扫描的默认搜索根
CATEGORY_SCAN_ROOTS = [
    HOME / "Desktop", HOME / "Documents", HOME / "Downloads",
    HOME / "Pictures", HOME / "Movies", HOME / "Music", HOME / "Public",
]


def scan_roots() -> list[Path]:
    """最近使用/分类扫描的搜索根，可用 WINFILE_SCAN_ROOTS 覆盖（冒号分隔）。"""
    override = os.environ.get("WINFILE_SCAN_ROOTS")
    if override:
        roots = [Path(part).expanduser() for part in override.split(":") if part.strip()]
        existing = [r for r in roots if r.is_dir()]
        if existing:
            return existing
    return [root for root in CATEGORY_SCAN_ROOTS if root.is_dir()]

MAX_WALK_DEPTH = 4


class MacroFS:
    """聚合 Spotlight 查询、应用扫描、图标提取与文件操作。"""

    def __init__(self, config):
        self.config = config
        self.cache_dir = config.ensure_state_dir()
        self.icons_dir = self.cache_dir / "icons"
        self._cache: dict[str, tuple[float, object]] = {}
        self._icon_paths: dict[str, Path] = {}
        self._load_icon_index()

    # ------------------------------------------------------------------ 缓存

    def cached(self, key: str, ttl: float | None = None):
        item = self._cache.get(key)
        if not item:
            return None
        stamp, value = item
        if time.time() - stamp > (ttl if ttl is not None else self.config.cache_ttl):
            return None
        return value

    def store(self, key: str, value):
        self._cache[key] = (time.time(), value)
        if len(self._cache) > 128:
            oldest = sorted(self._cache.items(), key=lambda kv: kv[1][0])[:32]
            for k, _ in oldest:
                self._cache.pop(k, None)
        return value

    def invalidate(self, prefix: str = "") -> None:
        for key in [k for k in self._cache if k.startswith(prefix)]:
            self._cache.pop(key, None)

    # ------------------------------------------------------------------ 路径补全

    def complete(self, fragment: str, limit: int = 24) -> dict:
        raw = (fragment or "").strip()
        tilde = raw.startswith("~") or not raw.startswith("/")
        expanded = os.path.expanduser(raw) if raw else str(HOME)
        if expanded.endswith("/"):
            directory, prefix = expanded, ""
        else:
            directory, prefix = os.path.split(expanded)
            directory = directory or "/"

        if not os.path.isdir(directory):
            # 逐级向上寻找最近存在的父目录，仍给出可用建议
            probe = directory
            while probe and not os.path.isdir(probe):
                parent = os.path.dirname(probe)
                if parent == probe:
                    break
                probe = parent
            if not probe or not os.path.isdir(probe):
                return {"suggestions": [], "directory": directory, "prefix": prefix}
            directory = probe
            prefix = ""

        suggestions: list[dict] = []
        base_dir = Path(directory)
        try:
            with os.scandir(directory) as it:
                for item in it:
                    name = item.name
                    if name.startswith(".") and not prefix.startswith("."):
                        continue
                    if prefix and not name.lower().startswith(prefix.lower()):
                        continue
                    try:
                        is_dir = item.is_dir(follow_symlinks=False)
                    except OSError:
                        is_dir = False
                    full = os.path.join(directory, name)
                    show = self._with_tilde(full)
                    category, type_desc, icon = extdb.classify(name, is_dir=is_dir)
                    suggestions.append(
                        {
                            "name": name,
                            "path": full,
                            "display": show,
                            "is_dir": is_dir,
                            "is_bundle": fsscan.is_bundle(Path(full), is_dir) if is_dir else False,
                            "icon": icon,
                            "type": type_desc,
                            "category": category,
                        }
                    )
        except PermissionError:
            return {"suggestions": [], "directory": directory, "prefix": prefix, "error": "无权限"}
        except OSError as exc:
            return {"suggestions": [], "directory": directory, "prefix": prefix, "error": str(exc)}

        def rank(item: dict) -> tuple:
            name = item["name"].lower()
            exact = 0 if name == prefix.lower() else 1
            starts = 0 if prefix and name.startswith(prefix.lower()) else 1
            natural = 0 if name.replace(".", "").replace("-", "").replace("_", "").replace(" ", "").isalnum() else 1
            return (exact, starts, natural, 0 if item["is_dir"] else 1, len(item["name"]), name)

        suggestions.sort(key=rank)
        total = len(suggestions)
        suggestions = suggestions[:limit]
        if tilde:
            for item in suggestions:
                item["display"] = self._with_tilde(item["path"])
        return {
            "suggestions": suggestions,
            "directory": directory,
            "prefix": prefix,
            "total": total,
            "truncated": total > len(suggestions),
        }

    def _with_tilde(self, path: str) -> str:
        home = str(HOME)
        if path == home:
            return "~"
        if path.startswith(home + "/"):
            return "~" + path[len(home):]
        return path

    # ------------------------------------------------------------------ 应用程序

    def list_apps(self, refresh: bool = False) -> dict:
        if not refresh:
            hit = self.cached("apps", ttl=300)
            if hit:
                return hit  # type: ignore[return-value]

        found: dict[str, dict] = {}
        for base in APP_DIRS:
            if not base.is_dir():
                continue
            self._collect_apps(base, found, depth=0, max_depth=1)

        # /System/Library/CoreServices 里的“访达/终端”等
        core = Path("/System/Library/CoreServices")
        if core.is_dir():
            self._collect_apps(core, found, depth=0, max_depth=0)

        apps = sorted(found.values(), key=lambda a: (a["name"] or "").lower())
        folders: dict[str, int] = {}
        for app in apps:
            parent = str(Path(app["path"]).parent)
            folders[parent] = folders.get(parent, 0) + 1

        payload = {
            "apps": apps,
            "counts": {"total": len(apps), "folders": folders},
            "scanned": [str(p) for p in APP_DIRS if p.is_dir()],
        }
        return self.store("apps", payload)  # type: ignore[return-value]

    def _collect_apps(self, base: Path, out: dict[str, dict], depth: int, max_depth: int) -> None:
        try:
            with os.scandir(base) as it:
                for item in it:
                    name = item.name
                    if name.startswith("."):
                        continue
                    try:
                        is_dir = item.is_dir(follow_symlinks=False)
                    except OSError:
                        continue
                    if not is_dir:
                        continue
                    if name.lower().endswith(".app"):
                        path = Path(item.path)
                        try:
                            st = item.stat(follow_symlinks=False)
                        except OSError:
                            st = None
                        entry = fsscan.build_entry(path, st)
                        entry["kind"] = "bundle"
                        entry["launchable"] = True
                        entry["location"] = str(base)
                        entry["category"] = "app"
                        entry["icon_url"] = self.app_icon_url(path)
                        out[entry["path"]] = entry
                    elif depth < max_depth:
                        self._collect_apps(Path(item.path), out, depth + 1, max_depth)
        except OSError:
            return

    # ------------------------------------------------------------------ 图标提取

    def _load_icon_index(self) -> None:
        index_file = self.icons_dir / "index.json"
        if index_file.is_file():
            try:
                raw = json.loads(index_file.read_text(encoding="utf-8"))
                for key, value in raw.items():
                    path = self.icons_dir / value
                    if path.is_file():
                        self._icon_paths[key] = path
            except (OSError, json.JSONDecodeError):
                pass

    def _save_icon_index(self) -> None:
        try:
            (self.icons_dir / "index.json").write_text(
                json.dumps({k: v.name for k, v in self._icon_paths.items()}, ensure_ascii=False),
                encoding="utf-8",
            )
        except OSError:
            pass

    def app_icon_url(self, app_path: Path) -> str | None:
        """提取 .app 的真实图标为 PNG 并返回 /api/icon?key=... 地址。

        优先使用内置的 winfile-icon（NSWorkspace，可覆盖 Assets.car 里的系统应用图标），
        否则退回 sips 解析 .icns。
        """
        key = self._icon_key(app_path)
        if key is None:
            return None
        cached = self._icon_paths.get(key)
        if cached and cached.is_file():
            return f"/api/icon?key={cached.name}"

        out_name = self._icon_name(key)
        out_path = self.icons_dir / out_name
        self._icon_paths[key] = out_path   # 值可能尚不存在，首次请求时生成
        self._save_icon_index()
        # 关键：这里不生成图标（AppKit 取图标较慢），交给 /api/icon 按需生成，
        # 否则“应用程序”视图要等全部图标提取完才能显示（200 个应用约 1 分钟）。
        return f"/api/icon?key={out_name}&app={quote(str(app_path))}"

    @staticmethod
    def _icon_key(app_path: Path) -> str | None:
        """图标缓存键：应用路径 + 修改时间（与哪个实例生成无关）。"""
        try:
            st = app_path.stat()
        except OSError:
            return None
        return f"{app_path}:{int(st.st_mtime)}"

    @staticmethod
    def _icon_name(key: str) -> str:
        import hashlib

        return f"app-{hashlib.sha1(key.encode('utf-8')).hexdigest()[:20]}.png"

    def extract_icon_for(self, app_path: Path) -> Path | None:
        """取（必要时生成）某个应用的图标文件，返回 PNG 路径。"""
        key = self._icon_key(app_path)
        if key is None:
            return None
        out_path = self._icon_paths.get(key) or (self.icons_dir / self._icon_name(key))
        if out_path.is_file():
            return out_path
        if self._extract_icon_native(app_path, out_path) or self._extract_icon_icns(app_path, out_path):
            self._icon_paths[key] = out_path
            return out_path
        return None

    def _extract_icon_native(self, app_path: Path, out_path: Path) -> bool:
        """调用内置 Swift 工具（NSWorkspace）取图标，可覆盖 Assets.car 里的系统应用图标。"""
        tool = self.config.icon_tool
        if not tool or not Path(tool).exists():
            return False
        try:
            proc = subprocess.run(
                [str(tool), str(app_path), "128"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=20.0,
            )
        except (OSError, subprocess.TimeoutExpired):
            return False
        data = proc.stdout
        if proc.returncode != 0 or not data.startswith(b"\x89PNG\r\n\x1a\n"):
            return False
        try:
            out_path.write_bytes(data)
        except OSError:
            return False
        return True

    def _extract_icon_icns(self, app_path: Path, out_path: Path) -> bool:
        """退回方案：读取 Info.plist 中的 .icns 并用 sips 转 PNG。"""
        if not SIPS:
            return False
        meta = fsscan.read_app_meta(app_path)
        icns: Path | None = None
        icon_file = meta.get("icon_file") or meta.get("icon_name")
        resources = app_path / "Contents" / "Resources"
        if icon_file:
            candidate = resources / icon_file
            if candidate.is_file():
                icns = candidate
            elif (resources / f"{icon_file}.icns").is_file():
                icns = resources / f"{icon_file}.icns"
        if icns is None and resources.is_dir():
            for candidate in sorted(resources.glob("*.icns")):
                icns = candidate
                break
        if icns is None:
            return False
        code, _, _ = utils.run_cmd(
            [SIPS, "-s", "format", "png", "-Z", "128", str(icns), "--out", str(out_path)],
            timeout=12.0,
        )
        return code == 0 and out_path.is_file()

    # ------------------------------------------------------------------ 最近使用

    def recent(self, days: int = 30, limit: int = 200, refresh: bool = False) -> dict:
        cache_key = f"recent:{days}"
        if not refresh:
            hit = self.cached(cache_key, ttl=30)
            if hit:
                return hit  # type: ignore[return-value]

        now = time.time()
        cutoff = now - days * 86400
        entries: list[dict] = []
        used: list[str] = []

        # Spotlight 覆盖面更广；目录遍历能补上「未进索引 / 刚创建」的文件，
        # 两者合并（按路径去重）才能既全又准。
        if MDFIND and Path(MDFIND).exists():
            spot = self._spotlight_recent(days)
            if spot:
                entries.extend(spot)
                used.append("spotlight")
        walked = self._walk_recent(cutoff, max_entries=1200)
        if walked:
            entries.extend(walked)
            used.append("walk")

        unique: dict[str, dict] = {}
        for entry in entries:
            if (entry.get("modified") or 0) < cutoff:
                continue
            unique.setdefault(entry["path"], entry)
        entries = sorted(unique.values(), key=lambda e: e.get("modified") or 0, reverse=True)

        buckets = {"today": 0, "week": 0, "month": 0}
        for entry in entries:
            age = now - (entry.get("modified") or 0)
            if age <= 86400:
                buckets["today"] += 1
            if age <= 7 * 86400:
                buckets["week"] += 1
            if age <= 30 * 86400:
                buckets["month"] += 1

        payload = {
            "entries": entries[:limit],
            "counts": buckets,
            "total": len(entries),
            "days": days,
            "source": "+".join(used) or "none",
            "generated": now,
        }
        return self.store(cache_key, payload)  # type: ignore[return-value]

    def _spotlight_recent(self, days: int) -> list[dict]:
        """Spotlight 查询最近修改的内容文件。

        注意：Spotlight 不支持 `kMDItemFSName == '*'` 这种通配查询，
        必须用具体谓词，所以这里用「有修改日期 + 属于可索引内容类型」来圈定。
        """
        predicate = (
            f"kMDItemContentModificationDate >= $time.today(-{int(days)})"
            " && kMDItemContentType != 'public.folder'"
            " && kMDItemContentType != 'public.volume'"
            " && kMDItemContentType != 'com.apple.application-bundle'"
        )
        paths: list[str] = []
        for root in scan_roots():
            if not root.is_dir():
                continue
            code, out, _ = utils.run_cmd([MDFIND, "-onlyin", str(root), predicate], timeout=20.0)
            if code == 0:
                paths.extend(line for line in out.splitlines() if line.strip())
        if not paths:
            code, out, _ = utils.run_cmd(
                [MDFIND, "-onlyin", str(HOME), predicate], timeout=30.0
            )
            if code == 0:
                paths.extend(line for line in out.splitlines() if line.strip())
        unique = list(dict.fromkeys(paths))
        return self._paths_to_entries(unique, limit=6000)

    def _walk_recent(self, cutoff: float, max_entries: int = 800) -> list[dict]:
        found: list[dict] = []
        for root in scan_roots():
            if not root.is_dir():
                continue
            self._walk_collect(root, cutoff, found, depth=0, budget=max_entries)
            if len(found) >= max_entries:
                break
        return found

    def _walk_collect(
        self,
        root: Path,
        cutoff: float,
        out: list[dict],
        depth: int,
        budget: int,
        max_depth: int = MAX_WALK_DEPTH,
    ) -> None:
        if depth > max_depth or len(out) >= budget:
            return
        try:
            with os.scandir(root) as it:
                for item in it:
                    if len(out) >= budget:
                        return
                    name = item.name
                    if name.startswith(".") or name in SKIP_DIR_NAMES:
                        continue
                    try:
                        if item.is_dir(follow_symlinks=False):
                            self._walk_collect(Path(item.path), cutoff, out, depth + 1, budget, max_depth=max_depth)
                            continue
                        st = item.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    if st.st_mtime < cutoff:
                        continue
                    out.append(fsscan.build_entry(Path(item.path), st))
        except OSError:
            return

    def _paths_to_entries(self, paths: list[str], skip_system: bool = True, limit: int = 4000) -> list[dict]:
        """把 mdfind 结果转成条目（并行 stat，跳过大目录/隐藏路径）。"""
        candidates: list[Path] = []
        for raw in paths[:limit]:
            path = Path(raw)
            if skip_system and self._is_noise(path):
                continue
            candidates.append(path)

        def work(path: Path) -> dict | None:
            try:
                st = os.lstat(path)
            except OSError:
                return None
            if os.path.isdir(path):
                return None
            return fsscan.build_entry(path, st)

        results: list[dict] = []
        with ThreadPoolExecutor(max_workers=12) as pool:
            for entry in pool.map(work, candidates):
                if entry:
                    results.append(entry)
        return results

    @staticmethod
    def _is_noise(path: Path) -> bool:
        parts = path.parts
        for part in parts:
            if part in SKIP_DIR_NAMES:
                return True
            if part.startswith(".") and part not in (".", ".."):
                # 允许 ~/.config 之类，但排除缓存
                if part in {".Trash", ".cache", ".npm", ".pnpm-store", ".cargo", ".rustup", ".gradle", ".m2"}:
                    return True
        name = path.name
        if name.endswith((".log", ".tmp", ".pyc", ".lock", ".cache")):
            return True
        if name == ".DS_Store":
            return True
        return False

    # ------------------------------------------------------------------ 文件分类

    def category_scan(self, category: str, limit: int = 300, refresh: bool = False) -> dict:
        cache_key = f"cat:{category}"
        if not refresh:
            hit = self.cached(cache_key, ttl=60)
            if hit:
                return hit  # type: ignore[return-value]

        if category not in extdb.CATEGORIES:
            return {"entries": [], "error": f"未知分类: {category}", "total": 0}

        entries: list[dict] = []
        source = "spotlight"
        if MDFIND and Path(MDFIND).exists():
            entries = self._spotlight_category(category)
        if not entries:
            source = "walk"
            entries = self._walk_category(category)

        entries.sort(key=lambda e: e.get("modified") or 0, reverse=True)
        payload = {
            "entries": entries[:limit],
            "total": len(entries),
            "category": category,
            "category_name": extdb.category_meta(category)[0],
            "source": source,
            "generated": time.time(),
        }
        return self.store(cache_key, payload)  # type: ignore[return-value]

    def _spotlight_category(self, category: str) -> list[dict]:
        types = extdb.SPOTLIGHT_TYPES.get(category)
        clauses = []
        if types:
            ors = " || ".join(f"kMDItemContentTypeTree == '{t}'" for t in types)
            clauses.append(f"({ors})")
        exts = sorted({ext for ext, (cat, _, _) in extdb._EXT_TABLE.items() if cat == category})
        if exts:
            ext_or = " || ".join(f"kMDItemFSName == '*.{ext}'cd" for ext in exts[:80])
            clauses.append(f"({ext_or})")
        if not clauses:
            return []
        query = " || ".join(clauses)
        collected: list[str] = []
        for root in scan_roots():
            if not root.is_dir():
                continue
            code, out, _ = utils.run_cmd([MDFIND, "-onlyin", str(root), query], timeout=20.0)
            if code == 0:
                collected.extend(line for line in out.splitlines() if line.strip())
        entries = self._paths_to_entries(list(dict.fromkeys(collected)))
        return [e for e in entries if e["category"] == category]

    def _walk_category(self, category: str) -> list[dict]:
        """Spotlight 不可用时的兜底：遍历常用目录并按扩展名分类。"""
        found: list[dict] = []
        budget = 400
        for root in scan_roots():
            if not root.is_dir():
                continue
            self._walk_by_category(root, category, found, depth=0, budget=budget)
            if len(found) >= budget:
                break
        return found

    def _walk_by_category(self, root: Path, category: str, out: list[dict], depth: int, budget: int) -> None:
        if depth > MAX_WALK_DEPTH or len(out) >= budget:
            return
        try:
            with os.scandir(root) as it:
                for item in it:
                    if len(out) >= budget:
                        return
                    name = item.name
                    if name.startswith(".") or name in SKIP_DIR_NAMES:
                        continue
                    try:
                        if item.is_dir(follow_symlinks=False):
                            self._walk_by_category(Path(item.path), category, out, depth + 1, budget)
                            continue
                        st = item.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    entry = fsscan.build_entry(Path(item.path), st)
                    if entry["category"] == category:
                        out.append(entry)
        except OSError:
            return

    def category_counts(self, days: int = 120, refresh: bool = False) -> dict:
        """各分类条目数量（侧边栏徽标）。用单次 Spotlight 查询 + Python 归类计数。"""
        if not refresh:
            hit = self.cached("catcounts", ttl=180)
            if hit:
                return hit  # type: ignore[return-value]

        counts: dict[str, int] = {}
        source = "unavailable"
        predicate = (
            f"kMDItemContentModificationDate >= $time.today(-{int(days)})"
            " && kMDItemContentType != 'public.folder'"
            " && kMDItemContentType != 'public.volume'"
            " && kMDItemContentType != 'com.apple.application-bundle'"
        )
        if MDFIND and Path(MDFIND).exists():
            seen: set[str] = set()
            for root in scan_roots():
                if not root.is_dir():
                    continue
                code, out, _ = utils.run_cmd([MDFIND, "-onlyin", str(root), predicate], timeout=25.0)
                if code != 0:
                    continue
                source = "spotlight"
                for line in out.splitlines():
                    line = line.strip()
                    if not line or line in seen:
                        continue
                    seen.add(line)
                    name = Path(line).name
                    if name.startswith(".") or MacroFS._is_noise(Path(line)):
                        continue
                    category, _, _ = extdb.classify(name, is_dir=False)
                    counts[category] = counts.get(category, 0) + 1
        payload = {"counts": counts, "source": source, "days": days}
        if not counts:
            # Spotlight 无结果（未索引的目录/新文件）时退回本地遍历
            payload["counts"] = self._walk_counts()
            payload["source"] = "walk"
        return self.store("catcounts", payload)  # type: ignore[return-value]

    def _walk_counts(self, budget: int = 4000) -> dict[str, int]:
        counts: dict[str, int] = {}
        total = 0
        for root in scan_roots():
            if not root.is_dir():
                continue
            for entry in self._walk_all(root, depth=0, budget=budget):
                counts[entry["category"]] = counts.get(entry["category"], 0) + 1
                total += 1
                if total >= budget:
                    return counts
        return counts

    def _walk_all(self, root: Path, depth: int, budget: int) -> list[dict]:
        out: list[dict] = []
        if depth > MAX_WALK_DEPTH:
            return out
        try:
            with os.scandir(root) as it:
                for item in it:
                    if len(out) >= budget:
                        break
                    name = item.name
                    if name.startswith(".") or name in SKIP_DIR_NAMES:
                        continue
                    try:
                        if item.is_dir(follow_symlinks=False):
                            out.extend(self._walk_all(Path(item.path), depth + 1, budget - len(out)))
                            continue
                        st = item.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    out.append(fsscan.build_entry(Path(item.path), st))
        except OSError:
            return out
        return out

    # ------------------------------------------------------------------ 剪贴板与打开方式

    def clipboard_copy(self, payload: dict) -> dict:
        """把文本/文件路径写入系统剪贴板（跨应用可用）。"""
        mode = (payload.get("mode") or "file").lower()
        if mode == "text":
            text = payload.get("text")
            if text is None:
                return {"ok": False, "error": "缺少 text 参数"}
            result = sysclip.copy_text(str(text))
            if result.get("ok"):
                result["mode"] = "text"
            return result

        raws = payload.get("paths") or []
        if not raws:
            return {"ok": False, "error": "缺少 paths 参数"}
        paths = [Path(raw) for raw in raws]
        existing = [p for p in paths if p.exists() or p.is_symlink()]
        if not existing:
            return {"ok": False, "error": "文件已不存在"}

        if mode == "content":
            # 复制单个文本文件的全部内容
            target = existing[0]
            if target.is_dir():
                return {"ok": False, "error": "文件夹没有文本内容"}
            ok, text, error = sysclip.read_text(target)
            if not ok:
                return {"ok": False, "error": error}
            result = sysclip.copy_text(text)
            if result.get("ok"):
                result.update({
                    "mode": "content",
                    "name": target.name,
                    "bytes": len(text.encode("utf-8")),
                    "text": text if len(text) <= 500 else text[:500] + "…",
                })
            return result

        if mode == "name":
            text = "\n".join(p.name for p in existing)
        elif mode == "dir":
            text = "\n".join(str(p if p.is_dir() else p.parent) for p in existing)
        else:  # file：完整路径，可在终端/编辑器直接粘贴
            text = "\n".join(str(p) for p in existing)
        result = sysclip.copy_text(text)
        if result.get("ok"):
            result.update({
                "mode": mode,
                "count": len(existing),
                "text": text if len(text) <= 500 else text[:500] + "…",
            })
        return result

    def suggest_apps_for(self, path: Path, limit: int = 60) -> dict:
        """查询可打开该文件的应用（Launch Services），并补全名称与图标。"""
        cache_key = f"opener:{path.suffix.lower()}:{path.is_dir()}"
        data = self.cached(cache_key, ttl=600)
        if data is None:
            data = self._query_launch_services(path, limit=90)
            # 只缓存成功结果：查询工具缺失/失败时不能把空结果缓存住
            if data.get("apps"):
                self.store(cache_key, data)

        known = {a["path"]: a for a in self.list_apps().get("apps", [])}
        apps: list[dict] = []
        for app_path in data.get("apps", []):  # type: ignore[union-attr]
            app = Path(app_path)
            if not self._is_launchable_app(app):
                continue  # 跳过没有 Info.plist 的残缺 bundle（无法启动）
            meta = known.get(app_path)
            if meta:
                name = meta.get("display_name") or meta["name"]
                bundle_id = (meta.get("app") or {}).get("bundle_id", "")
                version = (meta.get("app") or {}).get("version", "")
            else:
                plist = fsscan.read_app_meta(app)
                name = plist.get("display_name") or app.stem
                bundle_id = plist.get("bundle_id", "")
                version = plist.get("version", "")
            apps.append({
                "path": app_path,
                "name": name,
                "icon_url": self.app_icon_url(app),
                "bundle_id": bundle_id,
                "version": version,
                "is_default": app_path == data.get("default"),  # type: ignore[union-attr]
            })
            if len(apps) >= limit:
                break
        apps.sort(key=lambda a: (not a["is_default"], a["name"].lower()))
        return {
            "path": str(path),
            "name": path.name,
            "default": data.get("default", ""),  # type: ignore[union-attr]
            "default_name": data.get("default_name", ""),  # type: ignore[union-attr]
            "apps": apps,
            "total": len(apps),
        }

    @staticmethod
    def _is_launchable_app(app: Path) -> bool:
        """只保留可真正启动的应用包（有 Info.plist 或可执行文件）。"""
        if not app.exists():
            return False
        info = app / "Contents" / "Info.plist"
        if info.is_file():
            return True
        macos_dir = app / "Contents" / "MacOS"
        if macos_dir.is_dir():
            try:
                return any(child.is_file() for child in macos_dir.iterdir())
            except OSError:
                return False
        return False

    def _query_launch_services(self, path: Path, limit: int = 80) -> dict:
        """调用内置 Swift 工具查询打开方式；失败时退回按扩展名推测。"""
        tool = self.config.apps_tool
        if tool and Path(tool).exists():
            try:
                proc = subprocess.run(
                    [str(tool), str(path), "--limit", str(limit)],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    timeout=25.0,
                )
            except (OSError, subprocess.TimeoutExpired):
                proc = None
            if proc is not None and proc.returncode == 0 and proc.stdout:
                try:
                    data = json.loads(proc.stdout.decode("utf-8", "replace"))
                    if isinstance(data, dict):
                        return data
                except json.JSONDecodeError:
                    pass
        # 兜底：本机应用表里所有能“打开任意文件”的候选（至少让对话框有内容）
        return {"default": "", "default_name": "", "bundle_id": "", "apps": []}

    # ------------------------------------------------------------------ 快速位置

    def places(self) -> dict:
        groups = [
            (
                "快速访问",
                [
                    ("桌面", HOME / "Desktop", "🖥️"),
                    ("下载", HOME / "Downloads", "⬇️"),
                    ("文稿", HOME / "Documents", "📄"),
                    ("图片", HOME / "Pictures", "🖼️"),
                    ("影片", HOME / "Movies", "🎬"),
                    ("音乐", HOME / "Music", "🎵"),
                    ("个人文件夹", HOME, "🏠"),
                ],
            ),
            (
                "此电脑",
                [
                    ("Macintosh HD", Path("/"), "💽"),
                    ("应用程序", Path("/Applications"), "🚀"),
                    ("用户", Path("/Users"), "👥"),
                    ("资源库", Path("/Library"), "📚"),
                    ("卷", Path("/Volumes"), "🗄️"),
                    ("共享", Path("/Users/Shared"), "🤝"),
                ],
            ),
        ]
        out_groups = []
        for title, items in groups:
            rows = []
            for name, path, icon in items:
                if path.exists():
                    rows.append({"name": name, "path": str(path), "icon": icon})
            if rows:
                out_groups.append({"title": title, "items": rows})
        return {"groups": out_groups, "home": str(HOME)}

    # ------------------------------------------------------------------ 文件操作

    @staticmethod
    def open_path(path: Path, reveal: bool = False) -> dict:
        if reveal:
            code, out, err = utils.run_cmd([OPEN, "-R", str(path)], timeout=10.0)
        else:
            code, out, err = utils.run_cmd([OPEN, str(path)], timeout=15.0)
        if code != 0:
            return {"ok": False, "error": err.strip() or "打开失败"}
        return {"ok": True}

    @staticmethod
    def open_with(path: Path, app: str) -> dict:
        if not app:
            return {"ok": False, "error": "缺少应用名"}
        code, out, err = utils.run_cmd([OPEN, "-a", app, str(path)], timeout=20.0)
        if code != 0:
            return {"ok": False, "error": err.strip() or "打开失败"}
        return {"ok": True}

    @staticmethod
    def reveal_in_terminal(path: Path) -> dict:
        directory = path if path.is_dir() else path.parent
        script = 'tell application "Terminal" to do script "cd " & quoted form of %s' % json.dumps(str(directory))
        code, out, err = utils.run_cmd([OSASCRIPT, "-e", script], timeout=15.0)
        if code != 0:
            return {"ok": False, "error": err.strip() or "无法打开终端"}
        return {"ok": True}

    def trash(self, paths: list[Path]) -> dict:
        """移动到废纸篓（优先 Finder，失败则退回 ~/.Trash 移动）。"""
        moved: list[str] = []
        failed: list[dict] = []
        pending: list[Path] = []

        for path in paths:
            if not path.exists() and not path.is_symlink():
                failed.append({"path": str(path), "error": "文件不存在"})
            else:
                pending.append(path)

        if pending and OSASCRIPT:
            args = [OSASCRIPT, "-l", "JavaScript", "-e", _JXA_TRASH]
            args.extend(str(p) for p in pending)
            code, out, err = utils.run_cmd(args, timeout=60.0)
            if code == 0:
                for path in pending:
                    if not path.exists() and not path.is_symlink():
                        moved.append(str(path))
            else:
                failed.append({"path": "", "error": err.strip() or "Finder 删除失败"})

        remaining = [p for p in pending if str(p) not in moved]
        if remaining:
            trash_dir = HOME / ".Trash"
            for path in remaining:
                try:
                    target = self._unique_target(trash_dir, path.name)
                    shutil.move(str(path), str(target))
                    moved.append(str(path))
                except (OSError, shutil.Error) as exc:
                    failed.append({"path": str(path), "error": str(exc)})

        self.invalidate("recent")
        self.invalidate("cat")
        return {"ok": not failed, "moved": moved, "failed": failed}

    @staticmethod
    def _unique_target(directory: Path, name: str) -> Path:
        directory.mkdir(parents=True, exist_ok=True)
        target = directory / name
        if not target.exists():
            return target
        stem = Path(name).stem
        suffix = Path(name).suffix
        index = 2
        while True:
            candidate = directory / f"{stem} {index}{suffix}"
            if not candidate.exists():
                return candidate
            index += 1

    @staticmethod
    def delete_permanent(paths: list[Path]) -> dict:
        deleted: list[str] = []
        failed: list[dict] = []
        for path in paths:
            try:
                if path.is_dir() and not path.is_symlink():
                    shutil.rmtree(path)
                else:
                    path.unlink()
                deleted.append(str(path))
            except OSError as exc:
                failed.append({"path": str(path), "error": str(exc)})
        return {"ok": not failed, "deleted": deleted, "failed": failed}

    @staticmethod
    def rename(path: Path, new_name: str) -> dict:
        new_name = (new_name or "").strip()
        if not new_name or "/" in new_name:
            return {"ok": False, "error": "名称不合法"}
        target = path.parent / new_name
        if str(target) == str(path):
            return {"ok": True, "path": str(path), "unchanged": True}
        if target.exists():
            return {"ok": False, "error": "同名文件已存在"}
        try:
            os.rename(path, target)
        except OSError as exc:
            return {"ok": False, "error": str(exc)}
        return {"ok": True, "path": str(target), "name": new_name}

    @staticmethod
    def mkdir(parent: Path, name: str) -> dict:
        name = (name or "").strip() or "新建文件夹"
        if "/" in name:
            return {"ok": False, "error": "名称不合法"}
        target = parent / name
        index = 2
        while target.exists():
            target = parent / f"{name} {index}"
            index += 1
        try:
            target.mkdir(parents=True)
        except OSError as exc:
            return {"ok": False, "error": str(exc)}
        return {"ok": True, "path": str(target), "name": target.name}

    @staticmethod
    def create_file(parent: Path, name: str) -> dict:
        name = (name or "").strip() or "新建文本文档.txt"
        if "/" in name:
            return {"ok": False, "error": "名称不合法"}
        target = parent / name
        index = 2
        while target.exists():
            stem = Path(name).stem
            suffix = Path(name).suffix
            target = parent / f"{stem} {index}{suffix}"
            index += 1
        try:
            target.touch()
        except OSError as exc:
            return {"ok": False, "error": str(exc)}
        return {"ok": True, "path": str(target), "name": target.name}

    @staticmethod
    def transfer(sources: list[Path], dest_dir: Path, mode: str = "copy") -> dict:
        results: list[dict] = []
        dest_dir = dest_dir if dest_dir.is_dir() else dest_dir.parent
        dest_real = os.path.realpath(str(dest_dir))
        for src in sources:
            try:
                # 禁止把文件夹放入它自己或它的子目录（复制会无限递归，移动会丢数据）
                if src.is_dir() and not src.is_symlink():
                    src_real = os.path.realpath(str(src))
                    if dest_real == src_real or dest_real.startswith(src_real + os.sep):
                        results.append({
                            "path": str(src),
                            "ok": False,
                            "error": f"不能把「{src.name}」放入它自己或它的子文件夹中",
                        })
                        continue
                if mode == "move":
                    if str(src.parent) == str(dest_dir):
                        results.append({"path": str(src), "ok": True, "skipped": "同一目录"})
                        continue
                    target = MacroFS._unique_target(dest_dir, src.name)
                    shutil.move(str(src), str(target))
                    results.append({"path": str(src), "ok": True, "target": str(target)})
                else:
                    target = dest_dir / src.name
                    if target.exists():
                        target = MacroFS._unique_target(dest_dir, src.name)
                    if src.is_dir() and not src.is_symlink():
                        shutil.copytree(str(src), str(target), symlinks=True)
                    else:
                        shutil.copy2(str(src), str(target))
                    results.append({"path": str(src), "ok": True, "target": str(target)})
            except (OSError, shutil.Error) as exc:
                results.append({"path": str(src), "ok": False, "error": str(exc)})
        ok = all(r.get("ok") for r in results)
        return {"ok": ok, "results": results, "dest": str(dest_dir), "mode": mode}

    # ------------------------------------------------------------------ 目录信息

    def folder_info(self, path: Path) -> dict:
        info = utils.dir_size(path)
        return {"path": str(path), "name": path.name or str(path), **info}


_JXA_TRASH = """
function run(argv) {
  const finder = Application('Finder');
  const out = [];
  for (let i = 0; i < argv.length; i++) {
    try {
      finder.delete(ObjectSpecifier.whose({ _match: [{ _property: 'POSIX path', _equals: argv[i] }] })());
      out.push(argv[i]);
    } catch (e) {
      // 单个失败不影响其它文件
    }
  }
  return out.join('\\n');
}
"""
