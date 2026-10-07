"""HTTP 服务：静态前端 + JSON API。仅监听本机，全部 API 需要会话令牌。"""

from __future__ import annotations

import json
import mimetypes
import os
import socket
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

from . import extdb, fsscan, sysclip, utils
from .config import Config
from .macrofs import MacroFS

mimetypes.add_type("application/javascript", ".js")
mimetypes.add_type("text/css", ".css")
mimetypes.add_type("image/svg+xml", ".svg")
mimetypes.add_type("application/manifest+json", ".webmanifest")

CONTENT_CHUNK = 256 * 1024
MAX_CONTENT_BYTES = 64 * 1024 * 1024


class App:
    """把 HTTP 请求映射到文件系统操作。"""

    def __init__(self, config: Config):
        self.config = config
        self.fs = MacroFS(config)
        self.started = time.time()

    # ------------------------------------------------------------------ 基础

    def boot(self) -> dict:
        home = Path.home()
        return {
            "app": "winfile-mac",
            "version": "1.0.0",
            "home": str(home),
            "cwd": str(Path.cwd()),
            "hostname": socket.gethostname(),
            "user": os.environ.get("USER", ""),
            "platform": f"macOS {os.uname().release}",
            "started": self.started,
            "places": self.fs.places(),
            "categories": [
                {"id": key, "name": meta[0], "icon": meta[1], "color": meta[2]}
                for key, meta in extdb.CATEGORIES.items()
            ],
            "volumes": utils.list_volumes(),
        }

    # ------------------------------------------------------------------ 路径校验

    def resolve(self, raw: str | None, must_exist: bool = False) -> Path:
        path = utils.expand(raw)
        if not utils.is_within(path, self.config.visible_roots):
            raise PermissionError(f"路径不在允许范围内: {path}")
        if must_exist and not path.exists() and not path.is_symlink():
            raise FileNotFoundError(f"路径不存在: {path}")
        return path

    def resolve_many(self, values: list[str]) -> list[Path]:
        if not values:
            raise ValueError("缺少 paths 参数")
        return [self.resolve(value, must_exist=True) for value in values]

    # ------------------------------------------------------------------ 端点

    def list_dir(self, query: dict) -> dict:
        raw = (query.get("path") or [None])[0]
        path = self.resolve(raw)
        sort = (query.get("sort") or ["name"])[0]
        order = (query.get("order") or ["asc"])[0]
        show_hidden = (query.get("hidden") or ["0"])[0] in ("1", "true", "yes")
        deep_type = (query.get("meta") or ["fast"])[0] == "full"

        if not path.exists():
            return {
                "ok": False,
                "error": f"路径不存在：{path}",
                "path": str(path),
                "name": path.name or str(path),
                "entries": [],
            }
        if not path.is_dir():
            entry = fsscan.build_entry(path, None, deep_type=deep_type)
            return {
                "ok": True,
                "path": str(path),
                "name": path.name,
                "parent": str(path.parent),
                "is_dir": False,
                "entry": entry,
                "entries": [],
            }

        result = fsscan.scan_directory(
            path, show_hidden=show_hidden, sort=sort, order=order, deep_type=deep_type
        )
        parent = utils.parent_of(path)
        volume = utils.volume_info(path)
        payload = {
            "ok": "error" not in result,
            "path": str(path),
            "name": path.name or path.anchor or str(path),
            "display_path": str(path),
            "parent": str(parent) if parent else None,
            "is_dir": True,
            "entries": result.get("entries", []),
            "counts": result.get("counts", {}),
            "truncated": result.get("truncated", False),
            "scanned": result.get("scanned", 0),
            "top_level_size": result.get("top_level_size", 0),
            "top_level_size_h": result.get("top_level_size_h", ""),
            "permission_denied": result.get("permission_denied", False),
            "volume": volume,
            "sort": sort,
            "order": order,
            "show_hidden": show_hidden,
            "generated": time.time(),
        }
        if "error" in result:
            payload["error"] = result["error"]
        return payload

    def complete(self, query: dict) -> dict:
        fragment = (query.get("q") or [""])[0]
        limit = int((query.get("limit") or ["24"])[0])
        limit = max(1, min(limit, 80))
        return self.fs.complete(fragment, limit=limit)

    def app_list(self, query: dict) -> dict:
        refresh = (query.get("refresh") or ["0"])[0] in ("1", "true")
        data = self.fs.list_apps(refresh=refresh)
        search = (query.get("q") or [""])[0].strip().lower()
        apps = data["apps"]
        if search:
            apps = [a for a in apps if search in (a.get("display_name") or a["name"]).lower()]
        groups: dict[str, list] = {}
        for app in apps:
            groups.setdefault(app.get("location", ""), []).append(app)
        return {
            "ok": True,
            "apps": apps,
            "groups": [{"location": loc, "apps": items} for loc, items in sorted(groups.items())],
            "counts": data["counts"],
            "total": len(apps),
            "scanned": data["scanned"],
        }

    def recent(self, query: dict) -> dict:
        days = int((query.get("days") or ["30"])[0])
        limit = int((query.get("limit") or ["200"])[0])
        refresh = (query.get("refresh") or ["0"])[0] in ("1", "true")
        data = self.fs.recent(days=max(1, min(days, 365)), limit=max(1, min(limit, 2000)), refresh=refresh)
        search = (query.get("q") or [""])[0].strip().lower()
        entries = data["entries"]
        if search:
            entries = [e for e in entries if search in e["name"].lower()]
        return {"ok": True, **{**data, "entries": entries}}

    def category(self, query: dict) -> dict:
        name = (query.get("id") or [""])[0]
        limit = int((query.get("limit") or ["400"])[0])
        refresh = (query.get("refresh") or ["0"])[0] in ("1", "true")
        data = self.fs.category_scan(name, limit=max(1, min(limit, 2000)), refresh=refresh)
        search = (query.get("q") or [""])[0].strip().lower()
        entries = data["entries"]
        if search:
            entries = [e for e in entries if search in e["name"].lower()]
        return {"ok": "error" not in data, **{**data, "entries": entries}}

    def category_counts(self, query: dict) -> dict:
        refresh = (query.get("refresh") or ["0"])[0] in ("1", "true")
        days = int((query.get("days") or ["120"])[0])
        data = self.fs.category_counts(days=max(1, min(days, 3650)), refresh=refresh)
        categories = [
            {"id": key, "name": meta[0], "icon": meta[1], "color": meta[2]}
            for key, meta in extdb.CATEGORIES.items()
        ]
        return {"ok": True, "categories": categories, **data}

    def tree(self, query: dict) -> dict:
        raw = (query.get("path") or [None])[0]
        path = self.resolve(raw)
        if not path.is_dir():
            return {"ok": False, "error": "不是文件夹", "path": str(path), "children": []}
        children = []
        try:
            with os.scandir(path) as it:
                for item in it:
                    name = item.name
                    if name.startswith("."):
                        continue
                    try:
                        if not item.is_dir(follow_symlinks=False):
                            continue
                    except OSError:
                        continue
                    children.append(
                        {
                            "name": name,
                            "path": item.path,
                            "is_bundle": name.lower().endswith(".app"),
                        }
                    )
        except PermissionError:
            return {"ok": False, "error": "无权限", "path": str(path), "children": []}
        except OSError as exc:
            return {"ok": False, "error": str(exc), "path": str(path), "children": []}
        children.sort(key=lambda c: c["name"].lower())
        return {"ok": True, "path": str(path), "children": children[:400]}

    def stat_paths(self, query: dict) -> dict:
        raw = (query.get("paths") or [""])[0]
        parts = [p for p in raw.split("\x1f") if p.strip()]
        entries = []
        for part in parts[:200]:
            try:
                path = self.resolve(part, must_exist=True)
            except (PermissionError, FileNotFoundError) as exc:
                entries.append({"path": part, "error": str(exc)})
                continue
            try:
                entries.append(fsscan.build_entry(path, None))
            except OSError as exc:
                entries.append({"path": part, "error": str(exc)})
        return {"ok": True, "entries": entries}

    def openers(self, query: dict) -> dict:
        """可打开该文件的应用列表（用于“打开方式”选择器）。"""
        raw = (query.get("path") or [""])[0]
        if not raw:
            return {"ok": False, "error": "缺少 path 参数"}
        path = self.resolve(raw, must_exist=True)
        limit = int((query.get("limit") or ["60"])[0])
        data = self.fs.suggest_apps_for(path, limit=max(1, min(limit, 120)))
        return {"ok": True, **data}

    def paste_board(self) -> dict:
        """读取系统剪贴板文本（供前端“从剪贴板粘贴路径”使用）。"""
        text = sysclip.paste_text()
        return {"ok": True, "text": text, "chars": len(text)}

    def folder_info(self, query: dict) -> dict:
        raw = (query.get("path") or [None])[0]
        path = self.resolve(raw, must_exist=True)
        if not path.is_dir():
            return {"ok": False, "error": "不是文件夹", "path": str(path)}
        return {"ok": True, **self.fs.folder_info(path)}

    # ------------------------------------------------------------------ 写操作

    def open_paths(self, body: dict) -> dict:
        paths = self.resolve_many(body.get("paths") or [])
        app = (body.get("app") or "").strip()
        reveal = bool(body.get("reveal"))
        results = []
        for path in paths:
            if app:
                results.append({"path": str(path), **self.fs.open_with(path, app)})
            else:
                results.append({"path": str(path), **self.fs.open_path(path, reveal=reveal)})
        return {"ok": all(r.get("ok") for r in results), "results": results}

    def reveal(self, body: dict) -> dict:
        paths = self.resolve_many(body.get("paths") or [])
        results = []
        for path in paths:
            if body.get("terminal"):
                results.append({"path": str(path), **self.fs.reveal_in_terminal(path)})
            else:
                results.append({"path": str(path), **self.fs.open_path(path, reveal=True)})
        return {"ok": all(r.get("ok") for r in results), "results": results}

    def delete(self, body: dict) -> dict:
        paths = self.resolve_many(body.get("paths") or [])
        permanent = bool(body.get("permanent"))
        if permanent:
            result = self.fs.delete_permanent(paths)
        else:
            result = self.fs.trash(paths)
        return result

    def rename(self, body: dict) -> dict:
        path = self.resolve(body.get("path") or "", must_exist=True)
        result = self.fs.rename(path, body.get("name") or "")
        if result.get("ok"):
            self.fs.invalidate("recent")
            self.fs.invalidate("cat")
        return result

    def mkdir(self, body: dict) -> dict:
        parent = self.resolve(body.get("parent") or "", must_exist=True)
        result = self.fs.mkdir(parent, body.get("name") or "新建文件夹")
        if result.get("ok"):
            self.fs.invalidate("recent")
        return result

    def new_file(self, body: dict) -> dict:
        parent = self.resolve(body.get("parent") or "", must_exist=True)
        result = self.fs.create_file(parent, body.get("name") or "新建文本文档.txt")
        if result.get("ok"):
            self.fs.invalidate("recent")
        return result

    def transfer(self, body: dict) -> dict:
        sources = self.resolve_many(body.get("paths") or [])
        mode = body.get("mode") or "copy"
        if mode not in ("copy", "move"):
            return {"ok": False, "error": "mode 只能是 copy 或 move"}
        dest = self.resolve(body.get("dest") or "", must_exist=True)
        if not dest.is_dir():
            return {"ok": False, "error": "目标必须是文件夹"}
        result = self.fs.transfer(sources, dest, mode=mode)
        if result.get("ok"):
            self.fs.invalidate("recent")
            self.fs.invalidate("cat")
        return result

    def save_file(self, body: dict) -> dict:
        """把文本写入某个文件（用于「剪贴板文本存成文件」）。"""
        raw = body.get("path") or ""
        path = self.resolve(raw, must_exist=True)
        if path.is_dir():
            return {"ok": False, "error": "目标是文件夹"}
        text = body.get("text")
        if text is None:
            return {"ok": False, "error": "缺少 text 参数"}
        try:
            path.write_text(str(text), encoding="utf-8")
        except OSError as exc:
            return {"ok": False, "error": str(exc)}
        return {"ok": True, "path": str(path), "bytes": len(str(text).encode("utf-8"))}

    def clipboard_copy(self, body: dict) -> dict:
        """写入系统剪贴板：文本 / 文件路径 / 文件名 / 所在目录 / 文件内容。"""
        mode = (body.get("mode") or "file").lower()
        if mode == "text":
            return self.fs.clipboard_copy({"mode": "text", "text": body.get("text", "")})
        paths = self.resolve_many(body.get("paths") or [])
        return self.fs.clipboard_copy({"mode": mode, "paths": [str(p) for p in paths]})

    def trash_info(self) -> dict:
        trash = Path.home() / ".Trash"
        size = 0
        count = 0
        if trash.is_dir():
            try:
                with os.scandir(trash) as it:
                    for item in it:
                        count += 1
            except OSError:
                pass
        return {"ok": True, "path": str(trash), "count": count, "size": size, "size_h": utils.human_size(size)}


class ApiHandler(BaseHTTPRequestHandler):
    server_version = "winfile-mac/1.0"
    protocol_version = "HTTP/1.1"

    app: App
    config: Config

    # 关闭默认日志噪声
    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        if os.environ.get("WINFILE_DEBUG"):
            super().log_message(fmt, *args)

    # ------------------------------------------------------------------ 工具

    def _authorized(self, query: dict) -> bool:
        header = self.headers.get("X-Winfile-Token")
        if header and header == self.config.token:
            return True
        supplied = (query.get("token") or [""])[0]
        return bool(supplied) and supplied == self.config.token

    def _send_json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send_bytes(self, data: bytes, content_type: str, status: int = 200, extra: dict | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _read_body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        if length > 8 * 1024 * 1024:
            raise ValueError("请求体过大")
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError(f"请求体不是合法 JSON: {exc}") from exc

    # ------------------------------------------------------------------ 路由

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        route = unquote(parsed.path)
        query = parse_qs(parsed.query)

        # 首页始终返回前端外壳（内含获取令牌的引导请求）；
        # 真正的数据接口仍然要求令牌，避免其它网页跨源读取本机文件。
        if route in ("/", "/index.html"):
            return self._serve_static(self.config.web_dir / "index.html")
        if route == "/api/boot":
            return self._send_json({"ok": True, "token": self.config.token, **self.app.boot()})
        if route.startswith("/api/"):
            if not self._authorized(query):
                return self._send_json({"ok": False, "error": "未授权：缺少或错误的访问令牌"}, 401)
            try:
                payload = self._dispatch_get(route, query)
            except PermissionError as exc:
                return self._send_json({"ok": False, "error": str(exc)}, 403)
            except FileNotFoundError as exc:
                return self._send_json({"ok": False, "error": str(exc)}, 404)
            except ValueError as exc:
                return self._send_json({"ok": False, "error": str(exc)}, 400)
            except Exception as exc:  # pragma: no cover
                if os.environ.get("WINFILE_DEBUG"):
                    traceback.print_exc()
                return self._send_json({"ok": False, "error": f"服务器错误: {exc}"}, 500)
            if payload is None:
                return
            return self._send_json(payload)

        return self._serve_static(self.config.web_dir / route.lstrip("/"))

    def _dispatch_get(self, route: str, query: dict):
        if route == "/api/files":
            return self.app.list_dir(query)
        if route == "/api/complete":
            return self.app.complete(query)
        if route == "/api/apps":
            return self.app.app_list(query)
        if route == "/api/recent":
            return self.app.recent(query)
        if route == "/api/category":
            return self.app.category(query)
        if route == "/api/categories":
            return self.app.category_counts(query)
        if route == "/api/tree":
            return self.app.tree(query)
        if route == "/api/stat":
            return self.app.stat_paths(query)
        if route == "/api/folderinfo":
            return self.app.folder_info(query)
        if route == "/api/trash":
            return self.app.trash_info()
        if route == "/api/openers":
            return self.app.openers(query)
        if route == "/api/clipboard":
            return self.app.paste_board()
        if route == "/api/icon":
            return self._serve_icon(query)
        if route == "/api/thumb":
            return self._serve_thumb(query)
        if route == "/api/content":
            return self._serve_content(query)
        if route == "/api/download":
            return self._serve_content(query, download=True)
        return self._send_json({"ok": False, "error": f"未知接口: {route}"}, 404)

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        route = unquote(parsed.path)
        query = parse_qs(parsed.query)
        if not route.startswith("/api/"):
            return self._send_json({"ok": False, "error": "仅支持 /api 路径"}, 404)
        if not self._authorized(query):
            return self._send_json({"ok": False, "error": "未授权：缺少或错误的访问令牌"}, 401)
        try:
            body = self._read_body()
        except ValueError as exc:
            return self._send_json({"ok": False, "error": str(exc)}, 400)

        handlers = {
            "/api/open": self.app.open_paths,
            "/api/reveal": self.app.reveal,
            "/api/delete": self.app.delete,
            "/api/rename": self.app.rename,
            "/api/mkdir": self.app.mkdir,
            "/api/newfile": self.app.new_file,
            "/api/transfer": self.app.transfer,
            "/api/clipboard": self.app.clipboard_copy,
            "/api/savefile": self.app.save_file,
        }
        handler = handlers.get(route)
        if handler is None:
            return self._send_json({"ok": False, "error": f"未知接口: {route}"}, 404)
        try:
            result = handler(body)
        except PermissionError as exc:
            return self._send_json({"ok": False, "error": str(exc)}, 403)
        except FileNotFoundError as exc:
            return self._send_json({"ok": False, "error": str(exc)}, 404)
        except ValueError as exc:
            return self._send_json({"ok": False, "error": str(exc)}, 400)
        except Exception as exc:  # pragma: no cover
            if os.environ.get("WINFILE_DEBUG"):
                traceback.print_exc()
            return self._send_json({"ok": False, "error": f"服务器错误: {exc}"}, 500)
        return self._send_json(result)

    # ------------------------------------------------------------------ 静态与二进制

    def _serve_static(self, path: Path) -> None:
        web_root = self.config.web_dir.resolve()
        try:
            target = path.resolve()
        except OSError:
            return self._not_found()
        if not str(target).startswith(str(web_root)) or not target.is_file():
            return self._not_found()
        ctype, _ = mimetypes.guess_type(str(target))
        data = target.read_bytes()
        self._send_bytes(data, ctype or "application/octet-stream", extra={"Cache-Control": "no-cache"})

    def _not_found(self) -> None:
        self._send_json({"ok": False, "error": "资源不存在"}, 404)

    def _serve_icon(self, query: dict):
        key = (query.get("key") or [""])[0]
        if not key or "/" in key or ".." in key or key.startswith("."):
            return self._send_json({"ok": False, "error": "参数不合法"}, 400)

        # 应用图标：允许带 app= 参数，首次请求时即时提取
        raw_app = (query.get("app") or [""])[0]
        if raw_app:
            try:
                app_path = self.app.resolve(raw_app, must_exist=True)
            except PermissionError as exc:
                return self._send_json({"ok": False, "error": str(exc)}, 403)
            except FileNotFoundError as exc:
                return self._send_json({"ok": False, "error": str(exc)}, 404)
            icon = self.app.fs.extract_icon_for(app_path)
            if icon is None:
                return self._send_json({"ok": False, "error": "无法提取应用图标"}, 415)
            return self._send_bytes(
                icon.read_bytes(), "image/png", extra={"Cache-Control": "public, max-age=86400"}
            )

        path = self.config.state_dir / "icons" / key
        if not path.is_file():
            return self._send_json({"ok": False, "error": "图标不存在"}, 404)
        self._send_bytes(path.read_bytes(), "image/png", extra={"Cache-Control": "public, max-age=86400"})

    def _serve_thumb(self, query: dict):
        raw = (query.get("path") or [""])[0]
        size = int((query.get("size") or ["128"])[0])
        size = max(48, min(size, 512))
        try:
            path = self.app.resolve(raw, must_exist=True)
        except PermissionError as exc:
            return self._send_json({"ok": False, "error": str(exc)}, 403)
        except FileNotFoundError as exc:
            return self._send_json({"ok": False, "error": str(exc)}, 404)
        if not path.is_file():
            return self._send_json({"ok": False, "error": "不是文件"}, 400)
        thumb_dir = self.config.state_dir / "thumbs"
        thumb_dir.mkdir(parents=True, exist_ok=True)
        try:
            st = path.stat()
        except OSError as exc:
            return self._send_json({"ok": False, "error": str(exc)}, 404)
        token = f"{abs(hash((str(path), st.st_mtime, st.st_size, size))) & 0xFFFFFFFFFFFFFFFF:x}"
        out = thumb_dir / f"{token}.png"
        if not out.is_file():
            code, _, _ = utils.run_cmd(
                ["/usr/bin/sips", "-s", "format", "png", "-Z", str(size), str(path), "--out", str(out)],
                timeout=20.0,
            )
            if code != 0 or not out.is_file():
                return self._send_json({"ok": False, "error": "无法生成缩略图"}, 415)
        self._send_bytes(out.read_bytes(), "image/png", extra={"Cache-Control": "public, max-age=3600"})

    def _serve_content(self, query: dict, download: bool = False):
        raw = (query.get("path") or [""])[0]
        try:
            path = self.app.resolve(raw, must_exist=True)
        except PermissionError as exc:
            return self._send_json({"ok": False, "error": str(exc)}, 403)
        except FileNotFoundError as exc:
            return self._send_json({"ok": False, "error": str(exc)}, 404)
        if not path.is_file():
            return self._send_json({"ok": False, "error": "不是文件"}, 400)
        try:
            size = path.stat().st_size
        except OSError as exc:
            return self._send_json({"ok": False, "error": str(exc)}, 404)
        if size > MAX_CONTENT_BYTES:
            return self._send_json({"ok": False, "error": "文件过大，请使用“打开”方式查看"}, 413)
        ctype, _ = mimetypes.guess_type(str(path))
        if ctype is None:
            ctype = "text/plain" if _looks_texty(path) else "application/octet-stream"
        if ctype.startswith("text/") or ctype in ("application/json", "application/javascript"):
            ctype = f"{ctype}; charset=utf-8"
        extra = {}
        if download:
            extra["Content-Disposition"] = f'attachment; filename="{path.name}"'
        else:
            extra["Content-Disposition"] = "inline"
        data = path.read_bytes()
        self._send_bytes(data, ctype, extra=extra)


def _looks_texty(path: Path, probe: int = 4096) -> bool:
    try:
        with path.open("rb") as handle:
            chunk = handle.read(probe)
    except OSError:
        return False
    if b"\x00" in chunk:
        return False
    return True


def build_server(config: Config) -> ThreadingHTTPServer:
    app = App(config)
    handler = type("BoundApiHandler", (ApiHandler,), {"app": app, "config": config})
    try:
        server = ThreadingHTTPServer((config.host, config.port), handler)
    except OSError as exc:
        if exc.errno in (48, 98):  # EADDRINUSE
            raise SystemExit(
                f"[winfile-mac] 端口 {config.port} 已被占用。\n"
                f"  换个端口：python3 winfile.py --port {config.port + 1}\n"
                f"  或结束占用进程：lsof -ti tcp:{config.port} | xargs kill"
            ) from exc
        raise
    server.daemon_threads = True
    return server


def serve_forever(config: Config) -> None:
    server = build_server(config)
    config.write_token_file()
    url = f"http://{config.host}:{config.port}/?token={config.token}"
    print("[winfile-mac] 文件管理器已启动")
    print(f"[winfile-mac] 地址: {url}")
    print(f"[winfile-mac] 仅监听本机 ({config.host}:{config.port})，访问需要令牌")
    if config.desktop_mode and config.desktop_status_file:
        print(f"[winfile-mac] 桌面模式，状态文件: {config.desktop_status_file}")
    if config.open_browser:
        threading.Thread(target=lambda: utils.run_cmd(["/usr/bin/open", url], timeout=10.0), daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[winfile-mac] 已停止")
    finally:
        server.server_close()
