#!/usr/bin/env python3
"""Build the dependency-free GitHub Pages site, exposing only approved assets."""
from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import urlsplit, unquote
import argparse
import html
import json
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT
OUTPUT = ROOT / ".site-build"
SITE_URL = "https://fakeruzi.github.io/macos_winfile/"
HAN = re.compile(r"[\u4e00-\u9fff]")


class LocalizedPage(HTMLParser):
    """Render static locale routes; translation values are escaped as text."""
    def __init__(self, language, translations):
        super().__init__(convert_charrefs=False)
        self.language = language
        self.translations = translations
        self.parts = []
        self.missing = set()

    def translate(self, value):
        if self.language != "en" or not HAN.search(value):
            return value
        key = value.strip()
        if key not in self.translations:
            self.missing.add(key)
            return value
        start = len(value) - len(value.lstrip())
        end = len(value.rstrip())
        return value[:start] + self.translations[key] + value[end:]

    def start(self, tag, attrs, closed=False):
        attributes = dict(attrs)
        rendered = []
        for key, value in attrs:
            if value is not None:
                if key in {"alt", "aria-label", "title", "data-caption", "content"}:
                    value = self.translate(value)
                if self.language == "en":
                    if tag == "html" and key == "lang":
                        value = "en"
                    if key in {"href", "src", "data-image"} and value.startswith("./"):
                        value = "../" + value[2:]
                    if key == "href" and attributes.get("rel") == "canonical":
                        value = SITE_URL + "en/"
                    if key == "content" and attributes.get("property") == "og:url":
                        value = SITE_URL + "en/"
                    if key == "content" and attributes.get("property") == "og:locale":
                        value = "en_US"
                    guides = {
                        "https://github.com/fakerUZI/macos_winfile#功能": "features",
                        "https://github.com/fakerUZI/macos_winfile#安装": "installation",
                        "https://github.com/fakerUZI/macos_winfile#安卓功能准备": "android-setup",
                    }
                    if key == "href" and value in guides:
                        value = "https://github.com/fakerUZI/macos_winfile/blob/main/README.en.md#" + guides[value]
                if attributes.get("data-language"):
                    if key == "aria-current":
                        continue
                    if key == "href":
                        value = ("./" if self.language == "en" else "./en/") if attributes["data-language"] == "en" else ("../" if self.language == "en" else "./")
            rendered.append(key if value is None else f'{key}="{html.escape(value, quote=True)}"')
        if attributes.get("data-language") == self.language:
            rendered.append('aria-current="page"')
        self.parts.append("<" + tag + (" " + " ".join(rendered) if rendered else "") + ("/>" if closed else ">"))
        if tag == "br" and self.language == "en":
            # Responsive styles hide some line breaks; English still needs a word boundary.
            self.parts.append(" ")

    def handle_starttag(self, tag, attrs):
        self.start(tag, attrs)

    def handle_startendtag(self, tag, attrs):
        self.start(tag, attrs, closed=True)

    def handle_endtag(self, tag):
        self.parts.append(f"</{tag}>")

    def handle_data(self, data):
        self.parts.append(html.escape(self.translate(data), quote=False))

    def handle_entityref(self, name):
        self.parts.append(f"&{name};")

    def handle_charref(self, name):
        self.parts.append(f"&#{name};")

    def handle_decl(self, decl):
        self.parts.append(f"<!{decl}>")

    def handle_comment(self, data):
        self.parts.append(f"<!--{data}-->")


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

    def validate(self, output, page_directory):
        for ref in self.references:
            parsed = urlsplit(ref)
            if parsed.scheme or parsed.netloc:
                continue
            if parsed.path:
                target = (page_directory / unquote(parsed.path)).resolve()
                if not target.is_relative_to(output) or not (target.is_file() or (target.is_dir() and (target / "index.html").is_file())):
                    self.errors.append(f"Missing or unsafe local asset: {ref}")
            elif parsed.fragment and parsed.fragment not in self.ids:
                self.errors.append(f"Missing fragment: {ref}")
        if self.errors:
            raise ValueError("\n".join(self.errors))


def build():
    info = json.loads((ROOT / "site.json").read_text())
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    (OUTPUT / "assets").mkdir(parents=True)
    # Use an allowlist: never publish source, signing material, or the whole docs tree.
    for name in ("styles.css", "app.js"):
        shutil.copy2(SOURCE / name, OUTPUT / name)
    for name in ("main-window.png", "interface-refresh.jpg", "storage-cleanup.jpg", "software-cleanup.jpg", "wechat-cleanup.jpg", "android-files.png", "android-video-memory.png", "archive-extraction.png", "archive-preview.jpg", "archive-preview-201.jpg", "archive-default-open-202.png", "folder-picker.png", "extraction-new-folder.jpg", "interface-220.jpg", "home-quick-access-220.jpg"):
        shutil.copy2(SOURCE / "assets" / name, OUTPUT / "assets" / name)
    shutil.copy2(SOURCE / "assets/app-icon.png", OUTPUT / "assets/app-icon.png")
    def substitute(text):
        for key, value in {"VERSION": info["version"], "DOWNLOAD_VERSION": info["download_version"],
                           "SCREENSHOT_VERSION": info["screenshot_version"], "MIN_MACOS": info["minimum_macos"]}.items():
            text = text.replace("{{" + key + "}}", value)
        return text
    source = substitute((SOURCE / "index.html").read_text())
    catalog = json.loads((SOURCE / "locales/en.json").read_text())
    translations = {substitute(key): substitute(value) for key, value in catalog.items()}
    pages = []
    for language, relative in (("zh", "index.html"), ("en", "en/index.html")):
        renderer = LocalizedPage(language, translations)
        renderer.feed(source)
        if renderer.missing:
            raise ValueError("Missing English translations:\n" + "\n".join(sorted(renderer.missing)))
        page = "".join(renderer.parts)
        if re.search(r"\{\{[^{}]+\}\}", page):
            raise ValueError("Unresolved template variable in website")
        if re.search(r"\bwindows\b", page, re.I):
            raise ValueError("Remove the old platform-style comparison from the website")
        target = OUTPUT / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(page)
        pages.append((target, page))
    (OUTPUT / ".nojekyll").touch()
    for target, page in pages:
        validator = PageValidator()
        validator.feed(page)
        validator.validate(OUTPUT, target.parent)
    print(f"Website v{info['version']} built and validated (Chinese + English): {OUTPUT}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    build()
