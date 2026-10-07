"""文件类型数据库：扩展名 -> 分类 / 类型描述 / 图标 / 颜色。"""

from __future__ import annotations

# 分类元信息：id -> (中文名, 图标, 主题色)
CATEGORIES: dict[str, tuple[str, str, str]] = {
    "folder": ("文件夹", "📁", "#f0b429"),
    "image": ("图片", "🖼️", "#2fb344"),
    "video": ("视频", "🎬", "#e8590c"),
    "audio": ("音乐", "🎵", "#9c36b5"),
    "document": ("文档", "📄", "#1c7ed6"),
    "spreadsheet": ("表格", "📊", "#2f9e44"),
    "presentation": ("演示文稿", "📽️", "#e8590c"),
    "pdf": ("PDF", "📕", "#c92a2a"),
    "archive": ("压缩包", "🗜️", "#b8860b"),
    "code": ("代码", "🧩", "#0b7285"),
    "app": ("应用程序", "🚀", "#4263eb"),
    "font": ("字体", "🔤", "#7048e8"),
    "disk": ("磁盘映像", "💿", "#495057"),
    "executable": ("可执行文件", "⚙️", "#5f3dc4"),
    "database": ("数据库", "🗄️", "#8d6e63"),
    "ebook": ("电子书", "📚", "#c2255c"),
    "design": ("设计素材", "🎨", "#d6336c"),
    "other": ("其他", "📦", "#868e96"),
}

# 扩展名 -> (分类, 类型描述, 图标)
_EXT_TABLE: dict[str, tuple[str, str, str]] = {
    # 图片
    "jpg": ("image", "JPG 图片", "🖼️"),
    "jpeg": ("image", "JPEG 图片", "🖼️"),
    "png": ("image", "PNG 图片", "🖼️"),
    "gif": ("image", "GIF 图片", "🖼️"),
    "webp": ("image", "WebP 图片", "🖼️"),
    "bmp": ("image", "BMP 图片", "🖼️"),
    "tif": ("image", "TIFF 图片", "🖼️"),
    "tiff": ("image", "TIFF 图片", "🖼️"),
    "heic": ("image", "HEIC 图片", "🖼️"),
    "heif": ("image", "HEIF 图片", "🖼️"),
    "avif": ("image", "AVIF 图片", "🖼️"),
    "svg": ("image", "SVG 矢量图", "🖼️"),
    "ico": ("image", "图标文件", "🖼️"),
    "icns": ("image", "macOS 图标", "🖼️"),
    "raw": ("image", "RAW 照片", "📷"),
    "cr2": ("image", "佳能 RAW", "📷"),
    "nef": ("image", "尼康 RAW", "📷"),
    "arw": ("image", "索尼 RAW", "📷"),
    "dng": ("image", "DNG 照片", "📷"),
    "psd": ("design", "Photoshop 文档", "🎨"),
    "ai": ("design", "Illustrator 文档", "🎨"),
    "sketch": ("design", "Sketch 文档", "🎨"),
    "fig": ("design", "Figma 文档", "🎨"),
    "xd": ("design", "XD 文档", "🎨"),
    "afdesign": ("design", "Affinity 设计", "🎨"),
    "afphoto": ("design", "Affinity 照片", "🎨"),
    # 视频
    "mp4": ("video", "MP4 视频", "🎬"),
    "m4v": ("video", "M4V 视频", "🎬"),
    "mov": ("video", "QuickTime 影片", "🎬"),
    "avi": ("video", "AVI 视频", "🎬"),
    "mkv": ("video", "Matroska 视频", "🎬"),
    "wmv": ("video", "WMV 视频", "🎬"),
    "flv": ("video", "FLV 视频", "🎬"),
    "webm": ("video", "WebM 视频", "🎬"),
    "mpg": ("video", "MPEG 视频", "🎬"),
    "mpeg": ("video", "MPEG 视频", "🎬"),
    "ts": ("video", "传输流视频", "🎬"),
    "rmvb": ("video", "RealMedia 视频", "🎬"),
    # 音频
    "mp3": ("audio", "MP3 音频", "🎵"),
    "m4a": ("audio", "AAC 音频", "🎵"),
    "aac": ("audio", "AAC 音频", "🎵"),
    "wav": ("audio", "WAV 音频", "🎵"),
    "aiff": ("audio", "AIFF 音频", "🎵"),
    "flac": ("audio", "FLAC 无损音频", "🎵"),
    "ape": ("audio", "APE 无损音频", "🎵"),
    "ogg": ("audio", "OGG 音频", "🎵"),
    "opus": ("audio", "OPUS 音频", "🎵"),
    "wma": ("audio", "WMA 音频", "🎵"),
    "mid": ("audio", "MIDI 音频", "🎵"),
    "midi": ("audio", "MIDI 音频", "🎵"),
    "aif": ("audio", "AIFF 音频", "🎵"),
    # 文档
    "txt": ("document", "文本文档", "📄"),
    "md": ("document", "Markdown 文档", "📝"),
    "markdown": ("document", "Markdown 文档", "📝"),
    "rtf": ("document", "RTF 文档", "📄"),
    "doc": ("document", "Word 文档", "📘"),
    "docx": ("document", "Word 文档", "📘"),
    "dot": ("document", "Word 模板", "📘"),
    "dotx": ("document", "Word 模板", "📘"),
    "pages": ("document", "Pages 文档", "📘"),
    "odt": ("document", "OpenDocument 文本", "📄"),
    "tex": ("document", "LaTeX 文档", "📐"),
    "log": ("document", "日志文件", "🧾"),
    "csv": ("spreadsheet", "CSV 表格", "📊"),
    "tsv": ("spreadsheet", "TSV 表格", "📊"),
    "xls": ("spreadsheet", "Excel 工作簿", "📗"),
    "xlsx": ("spreadsheet", "Excel 工作簿", "📗"),
    "xlsm": ("spreadsheet", "Excel 宏工作簿", "📗"),
    "numbers": ("spreadsheet", "Numbers 表格", "📗"),
    "ods": ("spreadsheet", "OpenDocument 表格", "📊"),
    "ppt": ("presentation", "PowerPoint 演示", "📙"),
    "pptx": ("presentation", "PowerPoint 演示", "📙"),
    "key": ("presentation", "Keynote 演示", "📙"),
    "odp": ("presentation", "OpenDocument 演示", "📽️"),
    "pdf": ("pdf", "PDF 文档", "📕"),
    "epub": ("ebook", "EPUB 电子书", "📚"),
    "mobi": ("ebook", "Mobi 电子书", "📚"),
    "azw": ("ebook", "Kindle 电子书", "📚"),
    "azw3": ("ebook", "Kindle 电子书", "📚"),
    "djvu": ("ebook", "DjVu 文档", "📚"),
    # 压缩包
    "zip": ("archive", "ZIP 压缩包", "🗜️"),
    "rar": ("archive", "RAR 压缩包", "🗜️"),
    "7z": ("archive", "7-Zip 压缩包", "🗜️"),
    "tar": ("archive", "TAR 归档", "🗜️"),
    "gz": ("archive", "GZip 压缩", "🗜️"),
    "tgz": ("archive", "TAR.GZ 归档", "🗜️"),
    "bz2": ("archive", "BZip2 压缩", "🗜️"),
    "xz": ("archive", "XZ 压缩", "🗜️"),
    "zst": ("archive", "Zstandard 压缩", "🗜️"),
    "dmg": ("disk", "磁盘映像", "💿"),
    "iso": ("disk", "光盘映像", "💿"),
    "pkg": ("disk", "安装包", "📦"),
    "mpkg": ("disk", "安装包", "📦"),
    "xip": ("archive", "XIP 归档", "🗜️"),
    "jar": ("archive", "Java 归档", "☕"),
    "war": ("archive", "Java Web 归档", "☕"),
    # 代码
    "py": ("code", "Python 源码", "🐍"),
    "pyw": ("code", "Python 源码", "🐍"),
    "ipynb": ("code", "Jupyter 笔记本", "📓"),
    "js": ("code", "JavaScript 源码", "🟨"),
    "mjs": ("code", "JavaScript 模块", "🟨"),
    "cjs": ("code", "JavaScript 模块", "🟨"),
    "jsx": ("code", "React 组件", "⚛️"),
    "ts": ("code", "TypeScript 源码", "🔷"),
    "tsx": ("code", "React TS 组件", "⚛️"),
    "java": ("code", "Java 源码", "☕"),
    "kt": ("code", "Kotlin 源码", "🟪"),
    "swift": ("code", "Swift 源码", "🐦"),
    "m": ("code", "Objective-C 源码", "🍎"),
    "mm": ("code", "Objective-C++ 源码", "🍎"),
    "c": ("code", "C 源码", "🔧"),
    "h": ("code", "C 头文件", "🔧"),
    "cpp": ("code", "C++ 源码", "🔧"),
    "cc": ("code", "C++ 源码", "🔧"),
    "hpp": ("code", "C++ 头文件", "🔧"),
    "cs": ("code", "C# 源码", "🔷"),
    "go": ("code", "Go 源码", "🐹"),
    "rs": ("code", "Rust 源码", "🦀"),
    "rb": ("code", "Ruby 源码", "💎"),
    "php": ("code", "PHP 源码", "🐘"),
    "pl": ("code", "Perl 源码", "🐪"),
    "lua": ("code", "Lua 源码", "🌙"),
    "r": ("code", "R 源码", "📈"),
    "scala": ("code", "Scala 源码", "🔺"),
    "sh": ("code", "Shell 脚本", "🖥️"),
    "bash": ("code", "Bash 脚本", "🖥️"),
    "zsh": ("code", "Zsh 脚本", "🖥️"),
    "fish": ("code", "Fish 脚本", "🖥️"),
    "ps1": ("code", "PowerShell 脚本", "🖥️"),
    "bat": ("code", "批处理文件", "🖥️"),
    "cmd": ("code", "命令脚本", "🖥️"),
    "html": ("code", "HTML 网页", "🌐"),
    "htm": ("code", "HTML 网页", "🌐"),
    "css": ("code", "样式表", "🎨"),
    "scss": ("code", "SCSS 样式", "🎨"),
    "less": ("code", "LESS 样式", "🎨"),
    "vue": ("code", "Vue 组件", "💚"),
    "svelte": ("code", "Svelte 组件", "🧡"),
    "json": ("code", "JSON 数据", "🧾"),
    "yaml": ("code", "YAML 配置", "🧾"),
    "yml": ("code", "YAML 配置", "🧾"),
    "toml": ("code", "TOML 配置", "🧾"),
    "ini": ("code", "INI 配置", "🧾"),
    "cfg": ("code", "配置文件", "🧾"),
    "conf": ("code", "配置文件", "🧾"),
    "xml": ("code", "XML 文档", "🧾"),
    "plist": ("code", "属性列表", "🧾"),
    "sql": ("code", "SQL 脚本", "🗄️"),
    "graphql": ("code", "GraphQL 查询", "🕸️"),
    "patch": ("code", "补丁文件", "🩹"),
    "diff": ("code", "差异文件", "🩹"),
    # 数据库
    "db": ("database", "SQLite 数据库", "🗄️"),
    "sqlite": ("database", "SQLite 数据库", "🗄️"),
    "sqlite3": ("database", "SQLite 数据库", "🗄️"),
    "mdb": ("database", "Access 数据库", "🗄️"),
    "accdb": ("database", "Access 数据库", "🗄️"),
    "realm": ("database", "Realm 数据库", "🗄️"),
    # 字体
    "ttf": ("font", "TrueType 字体", "🔤"),
    "otf": ("font", "OpenType 字体", "🔤"),
    "woff": ("font", "Web 字体", "🔤"),
    "woff2": ("font", "Web 字体", "🔤"),
    "ttc": ("font", "字体集合", "🔤"),
    # 可执行
    "app": ("app", "应用程序", "🚀"),
    "exe": ("executable", "Windows 程序", "⚙️"),
    "msi": ("executable", "Windows 安装包", "⚙️"),
    "bin": ("executable", "二进制文件", "⚙️"),
    "so": ("executable", "共享库", "⚙️"),
    "dylib": ("executable", "动态库", "⚙️"),
    "a": ("executable", "静态库", "⚙️"),
    "o": ("executable", "目标文件", "⚙️"),
    "command": ("executable", "终端命令", "🖥️"),
    "tool": ("executable", "可执行工具", "⚙️"),
    "apk": ("executable", "Android 安装包", "🤖"),
    "deb": ("executable", "Debian 软件包", "📦"),
    "rpm": ("executable", "RPM 软件包", "📦"),
}

# macOS 包（bundle）：按目录后缀识别，双击进入内部由前端决定
BUNDLE_SUFFIXES: dict[str, tuple[str, str, str]] = {
    "app": ("app", "应用程序", "🚀"),
    "bundle": ("app", "插件包", "🧩"),
    "framework": ("app", "框架", "🏗️"),
    "plugin": ("app", "插件", "🔌"),
    "prefpane": ("app", "系统偏好面板", "⚙️"),
    "kext": ("app", "内核扩展", "🧬"),
    "xcodeproj": ("code", "Xcode 项目", "🛠️"),
    "xcworkspace": ("code", "Xcode 工作区", "🛠️"),
    "playground": ("code", "Swift Playground", "🎮"),
    "photoslibrary": ("image", "照片图库", "🖼️"),
    "photolibrary": ("image", "照片图库", "🖼️"),
    "sparsebundle": ("disk", "稀疏磁盘映像", "💿"),
    "rtfd": ("document", "RTFD 文档", "📄"),
    "pkg": ("disk", "安装包", "📦"),
    "pages": ("document", "Pages 文档", "📘"),
    "numbers": ("spreadsheet", "Numbers 表格", "📗"),
    "key": ("presentation", "Keynote 演示", "📙"),
}

# 无扩展名的常见文件名
_NAME_TABLE: dict[str, tuple[str, str, str]] = {
    "makefile": ("code", "Makefile", "🛠️"),
    "dockerfile": ("code", "Dockerfile", "🐳"),
    "readme": ("document", "说明文档", "📖"),
    "license": ("document", "许可证", "📜"),
    "licence": ("document", "许可证", "📜"),
    "changelog": ("document", "更新日志", "🧾"),
    ".gitignore": ("code", "Git 忽略规则", "🧾"),
    ".gitattributes": ("code", "Git 属性", "🧾"),
    ".zshrc": ("code", "Zsh 配置", "🖥️"),
    ".bashrc": ("code", "Bash 配置", "🖥️"),
    ".bash_profile": ("code", "Bash 配置", "🖥️"),
    ".profile": ("code", "Shell 配置", "🖥️"),
    ".env": ("code", "环境变量", "🔐"),
    ".ds_store": ("other", "Finder 缓存", "🗂️"),
}

# 分类 -> 用于 Spotlight 查询的 kMDItemContentTypeTree 值（补充扩展名判断）
SPOTLIGHT_TYPES: dict[str, list[str]] = {
    "image": ["public.image"],
    "video": ["public.movie"],
    "audio": ["public.audio"],
    "document": ["public.text", "public.rtf", "com.microsoft.word.doc"],
    "spreadsheet": ["public.spreadsheet", "com.microsoft.excel.xls"],
    "presentation": ["public.presentation"],
    "pdf": ["com.adobe.pdf"],
    "archive": ["public.archive", "public.zip-archive"],
    "code": ["public.source-code", "public.script", "public.json", "public.xml"],
    "app": ["com.apple.application-bundle"],
    "font": ["public.font"],
    "disk": ["public.disk-image"],
    "ebook": ["public.ebook"],
    "database": ["public.database"],
}


def classify(name: str, is_dir: bool = False, is_symlink: bool = False) -> tuple[str, str, str]:
    """返回 (分类 id, 类型描述, 图标)。"""
    if is_symlink and not is_dir:
        return "other", "替身/链接", "🔗"
    if is_dir:
        suffix = name.rsplit(".", 1)[-1].lower() if "." in name else ""
        if suffix in BUNDLE_SUFFIXES:
            return BUNDLE_SUFFIXES[suffix]
        return ("folder", "文件夹", "📁")
    lower = name.lower()
    if lower in _NAME_TABLE:
        return _NAME_TABLE[lower]
    if "." in name and not name.startswith("."):
        ext = name.rsplit(".", 1)[-1].lower()
        if ext in _EXT_TABLE:
            return _EXT_TABLE[ext]
    return ("other", "文件", "📦")


def extension_of(name: str) -> str:
    if "." not in name or name.startswith("."):
        return ""
    return name.rsplit(".", 1)[-1].lower()


def category_meta(cat: str) -> tuple[str, str, str]:
    return CATEGORIES.get(cat, CATEGORIES["other"])
