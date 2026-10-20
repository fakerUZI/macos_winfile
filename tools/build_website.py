#!/usr/bin/env python3
"""Build the dependency-free GitHub Pages site, exposing only approved assets."""
from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import urlsplit, unquote
import argparse
import html
import plistlib
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "website"
OUTPUT = ROOT / ".site-build"


class PageValidator(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.references = []
        self.errors = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            if attrs["id"] in self.ids:
                self.errors.append(f"Duplicate id: {attrs['id']}")
            self.ids.add(attrs["id"])
        if tag == "img" and "alt" not in attrs:
            self.errors.append("Image is missing alt text")
        for key in ("href", "src", "data-image"):
            if key in attrs:
                self.references.append(attrs[key])
        for key in ("aria-controls", "aria-labelledby"):
            for target in attrs.get(key, "").split():
                self.references.append(f"#{target}")

    def validate(self, output):
        for ref in self.references:
            parsed = urlsplit(ref)
            if parsed.scheme or parsed.netloc:
                continue
            if parsed.path:
                target = (output / unquote(parsed.path)).resolve()
                if not target.is_relative_to(output) or not target.is_file():
                    self.errors.append(f"Missing or unsafe local asset: {ref}")
            elif parsed.fragment and parsed.fragment not in self.ids:
                self.errors.append(f"Missing fragment: {ref}")
        if self.errors:
            raise ValueError("\n".join(self.errors))


def build():
    info = plistlib.loads((ROOT / "native/Info.plist").read_bytes())
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    (OUTPUT / "assets").mkdir(parents=True)
    # Use an allowlist: never publish source, signing material, or the whole docs tree.
    for name in ("styles.css", "app.js"):
        shutil.copy2(SOURCE / name, OUTPUT / name)
    for name in ("main-window.png", "wechat-cleanup.png", "android-files.png", "archive-extraction.png"):
        shutil.copy2(ROOT / "docs/screenshots" / name, OUTPUT / "assets" / name)
    shutil.copy2(ROOT / "docs/icon/AppIcon-1024.png", OUTPUT / "assets/app-icon.png")
    page = (SOURCE / "index.html").read_text()
    for key, value in {"VERSION": info["CFBundleShortVersionString"], "MIN_MACOS": info["LSMinimumSystemVersion"]}.items():
        page = page.replace("{{" + key + "}}", html.escape(value, quote=True))
    if re.search(r"\{\{[^{}]+\}\}", page):
        raise ValueError("Unresolved template variable in website")
    (OUTPUT / "index.html").write_text(page)
    (OUTPUT / ".nojekyll").touch()
    validator = PageValidator()
    validator.feed(page)
    validator.validate(OUTPUT)
    print(f"Website v{info['CFBundleShortVersionString']} built and validated: {OUTPUT}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    build()
