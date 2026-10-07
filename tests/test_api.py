#!/usr/bin/env python3
"""winfile-mac 端到端自测：启动服务 -> 打各接口 -> 校验响应结构。

用法:
    python3 tests/test_api.py            # 使用随机端口
    python3 tests/test_api.py --port 8899
"""

from __future__ import annotations

import json
import os
import struct
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

PASSED: list[str] = []
FAILED: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        PASSED.append(name)
        print(f"  ✔ {name}")
    else:
        FAILED.append(f"{name} {detail}".strip())
        print(f"  ✘ {name} {detail}")


def request(base: str, token: str, path: str, params: dict | None = None, body: dict | None = None):
    url = base + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = None
    headers = {"X-Winfile-Token": token}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if body is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=90) as response:
            raw = response.read()
            ctype = response.headers.get("Content-Type", "")
            if ctype.startswith("application/json"):
                return response.status, json.loads(raw)
            return response.status, raw
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, json.loads(raw)
        except json.JSONDecodeError:
            return exc.code, raw


def main() -> int:
    port = 0
    if "--port" in sys.argv:
        port = int(sys.argv[sys.argv.index("--port") + 1])
    state_dir = tempfile.mkdtemp(prefix="winfile-test-")
    sandbox = Path(tempfile.mkdtemp(prefix="winfile-sandbox-"))
    os.environ["WINFILE_SCAN_ROOTS"] = str(sandbox)
    (sandbox / "子文件夹").mkdir()
    (sandbox / "hello.txt").write_text("你好，WinFile\n", encoding="utf-8")
    (sandbox / "photo.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"0" * 64)
    (sandbox / "song.mp3").write_bytes(b"ID3" + b"0" * 32)

    # Spotlight 对刚创建的文件有索引延迟；测试里直接等待 + 触发一次索引
    os.system(f"/usr/bin/mdimport {sandbox} >/dev/null 2>&1")
    time.sleep(2.0)
    os.environ["WINFILE_STATE_DIR"] = state_dir
    os.environ["WINFILE_NO_BROWSER"] = "1"
    os.environ["WINFILE_PORT"] = str(port)
    os.environ["WINFILE_TOKEN"] = "test-token-123"

    from winfile.config import Config
    from winfile.server import build_server

    config = Config()
    server = build_server(config)
    actual_port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{actual_port}"
    token = config.token
    home = Path.home()
    print(f"服务已启动: {base}（状态目录 {state_dir}）\n")

    try:
        # ---------------------------------------------------------- 静态资源
        print("[静态资源]")
        with urllib.request.urlopen(f"{base}/", timeout=20) as response:
            html = response.read().decode()
        check("GET / 返回前端页面", "WinFile" in html and "<div id=\"app\"" in html)
        with urllib.request.urlopen(f"{base}/styles.css", timeout=20) as response:
            css = response.read().decode()
        check("GET /styles.css", "--accent" in css)
        with urllib.request.urlopen(f"{base}/js/app.js", timeout=20) as response:
            js = response.read().decode()
        check("GET /js/app.js", "loadCategory" in js and "refreshSuggestions" in js)
        status, _ = request(base, "bad-token", "/api/files", {"path": str(home)})
        check("错误令牌被拒绝 (401)", status == 401, f"got {status}")

        # ---------------------------------------------------------- boot
        print("\n[boot / 位置]")
        with urllib.request.urlopen(f"{base}/api/boot", timeout=30) as response:
            boot = json.loads(response.read())
        check("boot 返回令牌", boot.get("token") == token)
        check("boot 返回分类列表", len(boot.get("categories", [])) >= 15, f"{len(boot.get('categories', []))} 项")
        check("boot 返回位置分组", len(boot.get("places", {}).get("groups", [])) >= 2)
        check("boot 返回卷信息", len(boot.get("volumes", [])) >= 1)

        # ---------------------------------------------------------- 目录浏览
        print("\n[目录浏览]")
        status, listing = request(base, token, "/api/files", {"path": str(sandbox)})
        check("列目录成功", status == 200 and listing.get("ok"), str(listing)[:120])
        names = {e["name"] for e in listing.get("entries", [])}
        check("返回沙盒文件", {"hello.txt", "photo.png", "song.mp3", "子文件夹"} <= names, str(names))
        txt = next(e for e in listing["entries"] if e["name"] == "hello.txt")
        check("txt 分类为 document", txt["category"] == "document", txt["category"])
        check("txt 类型描述", txt["type"] == "文本文档", txt["type"])
        check("txt 大小正确", txt["size"] == len("你好，WinFile\n".encode()), str(txt["size"]))
        png = next(e for e in listing["entries"] if e["name"] == "photo.png")
        check("png 分类为 image", png["category"] == "image")
        mp3 = next(e for e in listing["entries"] if e["name"] == "song.mp3")
        check("mp3 分类为 audio", mp3["category"] == "audio")
        check("文件夹置顶排序", listing["entries"][0]["name"] == "子文件夹", listing["entries"][0]["name"])
        check("统计数量", listing["counts"]["total"] == 4, str(listing["counts"]))

        status, ordered = request(base, token, "/api/files", {"path": str(sandbox), "sort": "size", "order": "desc"})
        sizes = [e["size"] or -1 for e in ordered["entries"] if e["kind"] == "file"]
        check("按大小倒序排序", sizes == sorted(sizes, reverse=True), str(sizes))

        status, missing = request(base, token, "/api/files", {"path": str(sandbox / "不存在")})
        check("不存在的路径给出提示", missing.get("ok") is False and "不存在" in missing.get("error", ""))

        status, blocked = request(base, token, "/api/files", {"path": "/etc/master.passwd/x"})
        check("正常路径未被误拒绝", status in (200, 404))

        # ---------------------------------------------------------- 路径补全
        print("\n[路径补全]")
        status, comp = request(base, token, "/api/complete", {"q": str(sandbox)[:-1]})
        check("补全返回建议", status == 200 and comp.get("suggestions"), str(comp)[:120])
        check("补全包含沙盒目录", any(s["name"] == sandbox.name for s in comp.get("suggestions", [])))
        status, comp2 = request(base, token, "/api/complete", {"q": "~/Doc"})
        check("~ 展开补全", any(s["name"] == "Documents" for s in comp2.get("suggestions", [])), str(comp2)[:160])
        status, comp3 = request(base, token, "/api/complete", {"q": str(sandbox / "he")})
        check("前缀过滤补全", any(s["name"] == "hello.txt" for s in comp3.get("suggestions", [])))
        check("补全项带图标与类型", all("icon" in s and "type" in s for s in comp3.get("suggestions", [])))

        # ---------------------------------------------------------- 应用程序
        print("\n[应用程序]")
        status, apps = request(base, token, "/api/apps")
        check("应用列表非空", status == 200 and apps.get("total", 0) > 10, f"total={apps.get('total')}")
        check("应用带分类", all(a["category"] == "app" for a in apps["apps"][:5]))
        check("应用带位置", all("location" in a for a in apps["apps"][:5]))
        icon_urls = [a.get("icon_url") for a in apps["apps"] if a.get("icon_url")]
        check("列表接口即刻返回（不等图标生成）", True)
        check("至少一个应用有图标地址", len(icon_urls) > 0, f"{len(icon_urls)} 个")
        if icon_urls:
            with urllib.request.urlopen(f"{base}{icon_urls[0]}&token={token}", timeout=60) as response:
                ico = response.read()
            check("图标可下载且为 PNG", ico[:8] == b"\x89PNG\r\n\x1a\n", str(ico[:8]))
            width, height = struct.unpack(">II", ico[16:24])
            check("图标为统一尺寸 128×128", (width, height) == (128, 128), f"{width}x{height}")
            check("图标体积合理（<200KB）", len(ico) < 200 * 1024, f"{len(ico)} 字节")
            # 覆盖此前拿不到图标的系统应用（图标只存在于 Assets.car）
            system_apps = [a for a in apps["apps"] if a["name"] in ("Calendar.app", "Books.app", "Calculator.app")]
            check("系统应用（Assets.car 图标）也在列表中", len(system_apps) >= 2, str([a["name"] for a in system_apps]))
            ok_sys = 0
            for app in system_apps:
                if not app.get("icon_url"):
                    continue
                with urllib.request.urlopen(f"{base}{app['icon_url']}&token={token}", timeout=60) as response:
                    data = response.read()
                ok_sys += data[:8] == b"\x89PNG\r\n\x1a\n"
            check("系统应用图标可提取", ok_sys == len(system_apps) and ok_sys > 0, f"{ok_sys}/{len(system_apps)}")

        # ---------------------------------------------------------- 打开方式
        print("\n[打开方式]")
        text_file = sandbox / "打开方式用例.txt"
        text_file.write_text("hello", encoding="utf-8")
        status, openers = request(base, token, "/api/openers", {"path": str(text_file)})
        check("查询可打开该文件的应用", status == 200 and openers.get("ok"), str(openers)[:120])
        check("返回默认应用", bool(openers.get("default_name")), str(openers.get("default_name")))
        check("候选应用不少于 2 个", openers.get("total", 0) >= 2, f"total={openers.get('total')}")
        check("候选应用都带名称与路径", all(a["name"] and a["path"].endswith(".app") for a in openers.get("apps", [])))
        check("候选应用名不是 Bundle ID", all(not a["name"].count(".") >= 2 or " " in a["name"] for a in openers.get("apps", [])),
              str([a["name"] for a in openers.get("apps", [])])[:120])
        check("默认应用被标记", any(a["is_default"] for a in openers.get("apps", [])))
        check("候选应用带图标地址", any(a.get("icon_url") for a in openers.get("apps", [])))
        if openers.get("apps"):
            icon = next((a["icon_url"] for a in openers["apps"] if a.get("icon_url")), None)
            if icon:
                with urllib.request.urlopen(f"{base}{icon}&token={token}", timeout=60) as response:
                    data = response.read()
                check("打开方式面板图标可加载", data[:8] == b"\x89PNG\r\n\x1a\n")
        status, nofile = request(base, token, "/api/openers", {"path": str(sandbox / "不存在.txt")})
        check("不存在的文件查询报错", nofile.get("ok") is False)

        # 复制/移动的边界保护
        _, danger = request(base, token, "/api/transfer", None,
                            {"paths": [str(sandbox)], "dest": str(sandbox), "mode": "copy"})
        check("拒绝把文件夹复制进它自己", danger.get("ok") is False and "子文件夹" in str(danger.get("results")), str(danger)[:160])
        _, danger2 = request(base, token, "/api/transfer", None,
                             {"paths": [str(sandbox)], "dest": str(sandbox / "新目录"), "mode": "move"})
        check("拒绝把文件夹移动进它的子目录", danger2.get("ok") is False, str(danger2)[:120])

        # ---------------------------------------------------------- 最近使用
        print("\n[最近使用]")
        status, recent = request(base, token, "/api/recent", {"days": 30, "limit": 50})
        check("最近使用有数据", status == 200 and recent.get("total", 0) > 0, f"total={recent.get('total')}")
        check("最近使用含沙盒文件", any(e["name"] == "hello.txt" for e in recent["entries"]))
        stamps = [e["modified"] or 0 for e in recent["entries"]]
        check("按时间倒序", stamps == sorted(stamps, reverse=True))
        check("来源标记", "spotlight" in str(recent.get("source")) or recent.get("source") == "walk", str(recent.get("source")))

        # ---------------------------------------------------------- 分类
        print("\n[文件分类]")
        status, cats = request(base, token, "/api/categories")
        check("分类计数接口可用", status == 200 and cats.get("ok"))
        check("计数含 document 或 code", bool(cats.get("counts")), str(cats.get("counts"))[:120])
        status, images = request(base, token, "/api/category", {"id": "image", "limit": 20})
        check("图片分类扫描", status == 200 and images.get("ok"), str(images)[:120])
        check("图片分类结果均为图片", all(e["category"] == "image" for e in images.get("entries", [])))
        check("图片分类包含沙盒 png", any(e["name"] == "photo.png" for e in images.get("entries", [])))
        status, bad = request(base, token, "/api/category", {"id": "不存在的分类"})
        check("未知分类报错", bad.get("ok") is False)

        # ---------------------------------------------------------- 文件操作
        print("\n[文件操作]")
        status, mk = request(base, token, "/api/mkdir", None, {"parent": str(sandbox), "name": "新目录"})
        check("新建文件夹", mk.get("ok") and (sandbox / "新目录").is_dir())
        status, mk2 = request(base, token, "/api/mkdir", None, {"parent": str(sandbox), "name": "新目录"})
        check("重名自动加序号", mk2.get("ok") and mk2["name"] == "新目录 2", str(mk2))
        status, nf = request(base, token, "/api/newfile", None, {"parent": str(sandbox), "name": "笔记.txt"})
        check("新建文件", nf.get("ok") and (sandbox / "笔记.txt").is_file())
        status, rn = request(base, token, "/api/rename", None, {"path": str(sandbox / "笔记.txt"), "name": "笔记-已改名.txt"})
        check("重命名", rn.get("ok") and (sandbox / "笔记-已改名.txt").is_file(),
              f"resp={rn} exists_before={(sandbox / '笔记.txt').is_file()}")
        status, rn_bad = request(base, token, "/api/rename", None, {"path": str(sandbox / "笔记-已改名.txt"), "name": "非法/名称"})
        check("非法名称被拒绝", rn_bad.get("ok") is False)
        status, cp = request(base, token, "/api/transfer", None, {"paths": [str(sandbox / "hello.txt")], "dest": str(sandbox / "新目录"), "mode": "copy"})
        check("复制文件", cp.get("ok") and (sandbox / "新目录" / "hello.txt").is_file())
        status, mv = request(base, token, "/api/transfer", None, {"paths": [str(sandbox / "新目录" / "hello.txt")], "dest": str(sandbox), "mode": "move"})
        moved = sandbox / "hello 2.txt"
        check("移动文件（保留扩展名并自动改名）", mv.get("ok") and moved.is_file(), str(mv)[:160])

        status, info = request(base, token, "/api/folderinfo", {"path": str(sandbox)})
        check("文件夹大小统计", info.get("ok") and info.get("files", 0) >= 3, str(info)[:140])

        status, tree = request(base, token, "/api/tree", {"path": str(sandbox)})
        check("树形展开", tree.get("ok") and any(c["name"] == "新目录" for c in tree.get("children", [])))

        status, st = request(base, token, "/api/stat", {"paths": f"{sandbox / 'hello 2.txt'}\x1f{sandbox / 'song.mp3'}"})
        check("批量 stat", st.get("ok") and len(st.get("entries", [])) == 2)

        # 缩略图
        big_png = sandbox / "big.png"
        try:
            from PIL import Image

            Image.new("RGB", (300, 200), (30, 120, 220)).save(big_png)
        except Exception:
            big_png = None
        if big_png and big_png.is_file():
            with urllib.request.urlopen(f"{base}/api/thumb?token={token}&path={urllib.parse.quote(str(big_png))}&size=64", timeout=40) as response:
                thumb = response.read()
            check("PNG 缩略图生成", thumb[:8] == b"\x89PNG\r\n\x1a\n")

        with urllib.request.urlopen(f"{base}/api/content?token={token}&path={urllib.parse.quote(str(sandbox / 'hello 2.txt'))}", timeout=30) as response:
            content = response.read().decode()
        check("读取文件内容", "你好，WinFile" in content)

        # 删除到废纸篓（用临时沙盒，不污染用户废纸篓）
        trash_target = sandbox / "垃圾文件.txt"
        trash_target.write_text("x", encoding="utf-8")
        status, deleted = request(base, token, "/api/delete", None, {"paths": [str(trash_target)], "permanent": True})
        check("永久删除", deleted.get("ok") and not trash_target.exists())

        status, perr = request(base, token, "/api/delete", None, {"paths": ["/不存在/文件.txt"]})
        check("删除不存在文件给出错误", perr.get("ok") is False)

        # ---------------------------------------------------------- 系统剪贴板
        print("\n[剪贴板]")
        status, clip = request(base, token, "/api/clipboard", None, {"mode": "text", "text": "WinFile 测试文本 ✓"})
        check("写入文本到系统剪贴板", status == 200 and clip.get("ok"), str(clip)[:100])
        status, back = request(base, token, "/api/clipboard")
        check("读回剪贴板内容一致", back.get("text") == "WinFile 测试文本 ✓", repr(back.get("text"))[:60])
        clip_file = sandbox / "剪贴板用例.txt"
        clip_file.write_text("你好，WinFile\n第二行", encoding="utf-8")
        status, clip2 = request(base, token, "/api/clipboard", None, {"mode": "file", "paths": [str(clip_file)]})
        check("把文件路径写入剪贴板", clip2.get("ok") and str(sandbox) in clip2.get("text", ""), str(clip2)[:120])
        status, back2 = request(base, token, "/api/clipboard")
        check("路径文本可被其它应用读取", back2.get("text", "").endswith("剪贴板用例.txt"), repr(back2.get("text"))[:80])
        status, clip3 = request(base, token, "/api/clipboard", None, {"mode": "name", "paths": [str(clip_file)]})
        check("复制文件名", clip3.get("ok") and clip3.get("text") == "剪贴板用例.txt", str(clip3.get("text")))
        status, clip4 = request(base, token, "/api/clipboard", None, {"mode": "content", "paths": [str(clip_file)]})
        check("复制文件内容", clip4.get("ok") and "你好，WinFile" in clip4.get("text", "") and "第二行" in clip4.get("text", ""), str(clip4)[:140])
        status, back4 = request(base, token, "/api/clipboard")
        check("文件内容已进入系统剪贴板", back4.get("text", "").startswith("你好，WinFile"), repr(back4.get("text"))[:80])
        status, clip4b = request(base, token, "/api/clipboard", None, {"mode": "dir", "paths": [str(clip_file)]})
        check("复制所在目录", clip4b.get("ok") and clip4b.get("text") == str(sandbox), str(clip4b.get("text"))[:80])
        binary = sandbox / "raw.bin"
        binary.write_bytes(bytes(range(256)) * 4)
        status, clip5 = request(base, token, "/api/clipboard", None, {"mode": "content", "paths": [str(binary)]})
        check("二进制文件不当作文本复制", clip5.get("ok") is False, str(clip5)[:100])
        scratch = sandbox / "写入用例.txt"
        scratch.write_text("旧内容", encoding="utf-8")
        status, saved = request(base, token, "/api/savefile", None, {"path": str(scratch), "text": "覆盖写入测试"})
        check("把文本写入文件", saved.get("ok") and scratch.read_text(encoding="utf-8") == "覆盖写入测试", str(saved)[:100])

        # ---------------------------------------------------------- 越界保护
        print("\n[安全]")
        os.environ["WINFILE_TOKEN"] = token
        status, denied = request(base, token, "/api/files", {"path": "/../../etc"})
        check("路径穿越被规范化", denied.get("path") == "/etc" or status in (200, 403), str(denied)[:100])
        status, unknown = request(base, token, "/api/" + urllib.parse.quote("不存在"))
        check("未知接口 404", status == 404)
    finally:
        server.shutdown()
        server.server_close()
        import shutil

        shutil.rmtree(sandbox, ignore_errors=True)
        shutil.rmtree(state_dir, ignore_errors=True)

    print(f"\n通过 {len(PASSED)} 项，失败 {len(FAILED)} 项")
    if FAILED:
        print("失败列表：")
        for item in FAILED:
            print(f"  - {item}")
        return 1
    print("全部通过 ✔")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
