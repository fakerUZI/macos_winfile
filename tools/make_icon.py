#!/usr/bin/env python3
"""生成 WinFile.app 的应用图标（Windows 资源管理器风格的黄色文件夹）。

用法:
    python3 tools/make_icon.py                        # 生成 docs/icon/AppIcon.icns
    python3 tools/make_icon.py --out /tmp/AppIcon.icns

提示：本脚本依赖 Pillow；若系统 python3 没有，可用 DSH 内置运行时：
    PYTHONPATH=<...>/site-packages <...>/bin/python3 tools/make_icon.py
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def _ensure_pillow() -> None:
    """当前解释器没有 Pillow 时，尝试挂载常见位置后重新执行本脚本。"""
    try:
        import io

        from PIL import Image

        buffer = io.BytesIO()
        Image.new("RGB", (2, 2)).save(buffer, "PNG")  # 验证 C 扩展真的可用
        return
    except Exception:
        pass
    if os.environ.get("WINFILE_ICON_REEXEC") == "1":
        print("未找到 Pillow，无法生成图标。请安装：python3 -m pip install pillow", file=sys.stderr)
        raise SystemExit(2)

    # 优先使用自带 Pillow 的独立解释器（Pillow 含 C 扩展，必须解释器版本匹配）
    candidates: list[tuple[str, str]] = []
    bundled = Path.home() / ".dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3"
    if bundled.exists():
        site = bundled.parent.parent / "lib" / "python3.12" / "site-packages"
        if site.is_dir():
            candidates.append((str(bundled), str(site)))
        candidates.append((str(bundled), ""))
    for site in (
        Path.home() / "Library/Python/3.13/lib/python/site-packages",
        Path.home() / "Library/Python/3.12/lib/python/site-packages",
        Path("/opt/homebrew/lib/python3.13/site-packages"),
        Path("/opt/homebrew/lib/python3.12/site-packages"),
        Path("/usr/local/lib/python3.13/site-packages"),
        Path("/usr/local/lib/python3.12/site-packages"),
    ):
        if site.is_dir() and (site / "PIL").is_dir():
            candidates.append((sys.executable, str(site)))

    for interpreter, site in candidates:
        env = dict(os.environ)
        env["WINFILE_ICON_REEXEC"] = "1"
        if site:
            env["PYTHONPATH"] = site + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
        code = subprocess.run(
            [interpreter, "-c",
             "import io; from PIL import Image; Image.new('RGB', (2, 2)).save(io.BytesIO(), 'PNG')"],
            env=env,
            capture_output=True,
        )
        if code.returncode == 0:
            print(f"   （使用 {interpreter} 生成图标）")
            raise SystemExit(subprocess.run([interpreter, str(Path(__file__).resolve()), *sys.argv[1:]], env=env).returncode)
    print("未找到 Pillow，无法生成图标。请安装：python3 -m pip install pillow", file=sys.stderr)
    raise SystemExit(2)


_ensure_pillow()

ROOT = Path(__file__).resolve().parent.parent
SIZES = [16, 32, 64, 128, 256, 512, 1024]

# 调色板（Windows 11 文件夹配色）
TAB_LIGHT = (247, 201, 92)
BODY_LIGHT = (255, 214, 110)
BODY_DARK = (243, 178, 51)
EDGE = (222, 152, 27)


def _vgradient(size: int, top: tuple, bottom: tuple, box: tuple):
    """垂直渐变图像，用于文件夹主体的上方受光效果。"""
    from PIL import Image

    x0, y0, x1, y1 = [int(v) for v in box]
    width = max(1, x1 - x0)
    height = max(1, y1 - y0)
    grad = Image.new("RGB", (1, height))
    for y in range(height):
        t = y / max(1, height - 1)
        grad.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return grad.resize((width, height), Image.BILINEAR)


# 无底板形态下内容的缩放策略（1.0 = 保持原始布局大小）。
# 原布局内容占画布约 60%，放大到约 74% 更接近 macOS 图标的内容占比。
SCALE_WITHOUT_PLATE = 0.74 / 0.60   # ≈1.23：放大到画布 74%


def draw(size: int = 1024):
    from PIL import Image, ImageDraw

    s = size / 1024
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # ---- 背景：不加底板 ----
    #
    # 这里刻意不绘制浅蓝圆角底板：图标只保留文件夹本身，
    # 其余区域透明，形成"镂空"效果（按要求去掉最外侧底色）。
    # 若将来需要恢复 macOS 惯例的圆角底板，在此处补回绘制即可。

    # ---- 文件夹几何
    left = int(206 * s)
    right = int(818 * s)
    tab_top = int(262 * s)      # 标签页顶端
    body_top = int(374 * s)     # 主体顶端
    bottom = int(752 * s)
    tab_right = int(470 * s)
    r_out = int(30 * s)
    r_tab = int(26 * s)

    # 标签页（比主体略深，先画，主体覆盖其下半部分）
    tab = (left, tab_top, tab_right, body_top + int(40 * s))
    tab_mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(tab_mask).rounded_rectangle(tab, radius=r_tab, fill=255)
    tab_fill = Image.new("RGBA", (size, size), (232, 167, 40, 255))
    canvas.paste(tab_fill, (0, 0), tab_mask)
    tab_draw = ImageDraw.Draw(canvas)
    tab_draw.rounded_rectangle(tab, radius=r_tab, outline=(203, 137, 20, 255), width=max(1, int(4 * s)))

    # 主体：上亮下深的轻微渐变
    body = (left, body_top, right, bottom)
    body_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    body_layer.paste(
        _vgradient(size, (255, 219, 124), (245, 185, 62), body).convert("RGBA"),
        (body[0], body[1]),
    )
    body_mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(body_mask).rounded_rectangle(body, radius=r_out, fill=255)
    canvas.alpha_composite(Image.composite(body_layer, Image.new("RGBA", (size, size), (0, 0, 0, 0)), body_mask))

    draw = ImageDraw.Draw(canvas)
    # 顶部高光细线
    draw.rounded_rectangle(
        (body[0] + int(14 * s), body[1] + int(12 * s), body[2] - int(14 * s), body[1] + int(26 * s)),
        radius=int(9 * s),
        fill=(255, 247, 214, 170),
    )
    draw.rounded_rectangle(body, radius=r_out, outline=(203, 137, 20, 255), width=max(1, int(5 * s)))

    # ---- 放大到合适比例 ----
    # 去掉底板后，文件夹在原布局里只占约 60% 宽度，视觉上偏小。
    # 这里按内容包围盒居中放大，使其占据画布约 74%（贴近 macOS 图标的内容占比）。
    if SCALE_WITHOUT_PLATE != 1.0:
        bbox = canvas.getchannel("A").getbbox()
        if bbox:
            content = canvas.crop(bbox)
            # 目标宽度占比：0.74（原为 0.60）
            target = int(size * 0.74)
            ratio = min(target / content.width, target / content.height)
            new_size = (max(1, int(content.width * ratio)), max(1, int(content.height * ratio)))
            content = content.resize(new_size, Image.LANCZOS)
            canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
            canvas.alpha_composite(content, ((size - new_size[0]) // 2, (size - new_size[1]) // 2))

    return canvas


def build(out_path: Path) -> Path:
    from PIL import Image

    work = Path(tempfile.mkdtemp(prefix="winfile-iconset-"))
    iconset = work / "AppIcon.iconset"
    iconset.mkdir(parents=True)
    master = draw(1024)
    for size in SIZES:
        image = master.resize((size, size), Image.LANCZOS)
        image.save(iconset / f"icon_{size}x{size}.png")
        if size <= 512:
            image.save(iconset / f"icon_{size}x{size}@2x.png")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        ["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(out_path)],
        capture_output=True,
        text=True,
    )
    master.save(out_path.with_name("AppIcon-1024.png"))
    shutil.rmtree(work, ignore_errors=True)
    if proc.returncode != 0:
        fallback = out_path.with_suffix(".png")
        master.save(fallback)
        print(f"iconutil 失败（{proc.stderr.strip()}），已输出 PNG: {fallback}")
        return fallback
    return out_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=str(ROOT / "docs" / "icon" / "AppIcon.icns"))
    parser.add_argument("--png-only", action="store_true", help="只输出 1024 PNG（便于预览）")
    args = parser.parse_args()
    if args.png_only:
        out = Path(args.out).with_suffix(".png")
        out.parent.mkdir(parents=True, exist_ok=True)
        draw(1024).save(out)
        print(f"PNG 已生成: {out}")
        return 0
    result = build(Path(args.out))
    print(f"图标已生成: {result} ({result.stat().st_size} 字节)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
