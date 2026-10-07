// 文件条目模型与分类规则（对应原 Python extdb.py）
import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - 分类

enum FileCategory: String, CaseIterable, Identifiable, Codable {
    case folder, image, video, audio, document, spreadsheet, presentation
    case pdf, archive, code, app, font, disk, executable, database, ebook, design, other

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .folder: return L("category.folder", "文件夹")
        case .image: return L("category.image", "图片")
        case .video: return L("category.video", "视频")
        case .audio: return L("category.audio", "音乐")
        case .document: return L("category.document", "文档")
        case .spreadsheet: return L("category.spreadsheet", "表格")
        case .presentation: return L("category.presentation", "演示文稿")
        case .pdf: return L("category.pdf", "PDF")
        case .archive: return L("category.archive", "压缩包")
        case .code: return L("category.code", "代码")
        case .app: return L("category.app", "应用程序")
        case .font: return L("category.font", "字体")
        case .disk: return L("category.disk", "磁盘映像")
        case .executable: return L("category.executable", "可执行文件")
        case .database: return L("category.database", "数据库")
        case .ebook: return L("category.ebook", "电子书")
        case .design: return L("category.design", "设计素材")
        case .other: return L("category.other", "其他")
        }
    }

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .image: return "photo.fill"
        case .video: return "film.fill"
        case .audio: return "music.note"
        case .document: return "doc.text.fill"
        case .spreadsheet: return "tablecells.fill"
        case .presentation: return "rectangle.on.rectangle.fill"
        case .pdf: return "doc.richtext.fill"
        case .archive: return "archivebox.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .app: return "app.fill"
        case .font: return "textformat"
        case .disk: return "externaldrive.fill"
        case .executable: return "gearshape.2.fill"
        case .database: return "cylinder.split.1x2.fill"
        case .ebook: return "book.fill"
        case .design: return "paintpalette.fill"
        case .other: return "doc.fill"
        }
    }

    /// 侧边栏配色（沿用原网页版主题色）
    var tint: NSColor {
        switch self {
        case .folder: return NSColor(srgbRed: 0.94, green: 0.71, blue: 0.16, alpha: 1)
        case .image: return NSColor(srgbRed: 0.18, green: 0.70, blue: 0.27, alpha: 1)
        case .video: return NSColor(srgbRed: 0.91, green: 0.35, blue: 0.05, alpha: 1)
        case .audio: return NSColor(srgbRed: 0.61, green: 0.21, blue: 0.71, alpha: 1)
        case .document: return NSColor(srgbRed: 0.11, green: 0.49, blue: 0.84, alpha: 1)
        case .spreadsheet: return NSColor(srgbRed: 0.18, green: 0.62, blue: 0.27, alpha: 1)
        case .presentation: return NSColor(srgbRed: 0.91, green: 0.35, blue: 0.05, alpha: 1)
        case .pdf: return NSColor(srgbRed: 0.79, green: 0.16, blue: 0.16, alpha: 1)
        case .archive: return NSColor(srgbRed: 0.72, green: 0.53, blue: 0.04, alpha: 1)
        case .code: return NSColor(srgbRed: 0.04, green: 0.45, blue: 0.52, alpha: 1)
        case .app: return NSColor(srgbRed: 0.26, green: 0.39, blue: 0.92, alpha: 1)
        case .font: return NSColor(srgbRed: 0.44, green: 0.28, blue: 0.91, alpha: 1)
        case .disk: return NSColor(srgbRed: 0.29, green: 0.31, blue: 0.34, alpha: 1)
        case .executable: return NSColor(srgbRed: 0.37, green: 0.24, blue: 0.77, alpha: 1)
        case .database: return NSColor(srgbRed: 0.55, green: 0.43, blue: 0.39, alpha: 1)
        case .ebook: return NSColor(srgbRed: 0.76, green: 0.15, blue: 0.36, alpha: 1)
        case .design: return NSColor(srgbRed: 0.84, green: 0.20, blue: 0.42, alpha: 1)
        case .other: return NSColor(srgbRed: 0.53, green: 0.56, blue: 0.59, alpha: 1)
        }
    }

    /// 侧边栏展示顺序
    static var sidebarOrder: [FileCategory] {
        [.image, .video, .audio, .document, .spreadsheet, .presentation, .pdf,
         .archive, .code, .ebook, .design, .database, .font, .disk, .executable]
    }
}

// MARK: - 文件类型库

enum FileTypeDB {
    struct Info {
        let category: FileCategory
        let description: String
    }

    private static let table: [String: Info] = [
        // 图片
        "jpg": .init(category: .image, description: "JPEG 图片"),
        "jpeg": .init(category: .image, description: "JPEG 图片"),
        "png": .init(category: .image, description: "PNG 图片"),
        "gif": .init(category: .image, description: "GIF 图片"),
        "webp": .init(category: .image, description: "WebP 图片"),
        "bmp": .init(category: .image, description: "BMP 图片"),
        "tif": .init(category: .image, description: "TIFF 图片"),
        "tiff": .init(category: .image, description: "TIFF 图片"),
        "heic": .init(category: .image, description: "HEIC 图片"),
        "heif": .init(category: .image, description: "HEIF 图片"),
        "avif": .init(category: .image, description: "AVIF 图片"),
        "svg": .init(category: .image, description: "SVG 矢量图"),
        "ico": .init(category: .image, description: "图标文件"),
        "icns": .init(category: .image, description: "macOS 图标"),
        "raw": .init(category: .image, description: "RAW 照片"),
        "cr2": .init(category: .image, description: "佳能 RAW"),
        "nef": .init(category: .image, description: "尼康 RAW"),
        "arw": .init(category: .image, description: "索尼 RAW"),
        "dng": .init(category: .image, description: "DNG 照片"),
        // 设计素材
        "psd": .init(category: .design, description: "Photoshop 文档"),
        "ai": .init(category: .design, description: "Illustrator 文档"),
        "sketch": .init(category: .design, description: "Sketch 文档"),
        "fig": .init(category: .design, description: "Figma 文档"),
        "xd": .init(category: .design, description: "XD 文档"),
        "afdesign": .init(category: .design, description: "Affinity 设计"),
        "afphoto": .init(category: .design, description: "Affinity 照片"),
        // 视频
        "mp4": .init(category: .video, description: "MP4 视频"),
        "m4v": .init(category: .video, description: "M4V 视频"),
        "mov": .init(category: .video, description: "QuickTime 影片"),
        "avi": .init(category: .video, description: "AVI 视频"),
        "mkv": .init(category: .video, description: "Matroska 视频"),
        "wmv": .init(category: .video, description: "WMV 视频"),
        "flv": .init(category: .video, description: "FLV 视频"),
        "webm": .init(category: .video, description: "WebM 视频"),
        "mpg": .init(category: .video, description: "MPEG 视频"),
        "mpeg": .init(category: .video, description: "MPEG 视频"),
        "mts": .init(category: .video, description: "传输流视频"),
        "m2ts": .init(category: .video, description: "传输流视频"),
        "rmvb": .init(category: .video, description: "RealMedia 视频"),
        // 音频
        "mp3": .init(category: .audio, description: "MP3 音频"),
        "m4a": .init(category: .audio, description: "AAC 音频"),
        "aac": .init(category: .audio, description: "AAC 音频"),
        "wav": .init(category: .audio, description: "WAV 音频"),
        "aiff": .init(category: .audio, description: "AIFF 音频"),
        "aif": .init(category: .audio, description: "AIFF 音频"),
        "flac": .init(category: .audio, description: "FLAC 无损音频"),
        "ape": .init(category: .audio, description: "APE 无损音频"),
        "ogg": .init(category: .audio, description: "OGG 音频"),
        "opus": .init(category: .audio, description: "OPUS 音频"),
        "wma": .init(category: .audio, description: "WMA 音频"),
        "mid": .init(category: .audio, description: "MIDI 音频"),
        "midi": .init(category: .audio, description: "MIDI 音频"),
        // 文档
        "txt": .init(category: .document, description: "文本文档"),
        "md": .init(category: .document, description: "Markdown 文档"),
        "markdown": .init(category: .document, description: "Markdown 文档"),
        "rtf": .init(category: .document, description: "RTF 文档"),
        "rtfd": .init(category: .document, description: "RTFD 文档"),
        "doc": .init(category: .document, description: "Word 文档"),
        "docx": .init(category: .document, description: "Word 文档"),
        "dot": .init(category: .document, description: "Word 模板"),
        "dotx": .init(category: .document, description: "Word 模板"),
        "pages": .init(category: .document, description: "Pages 文档"),
        "odt": .init(category: .document, description: "OpenDocument 文本"),
        "tex": .init(category: .document, description: "LaTeX 文档"),
        "log": .init(category: .document, description: "日志文件"),
        // 表格
        "csv": .init(category: .spreadsheet, description: "CSV 表格"),
        "tsv": .init(category: .spreadsheet, description: "TSV 表格"),
        "xls": .init(category: .spreadsheet, description: "Excel 工作簿"),
        "xlsx": .init(category: .spreadsheet, description: "Excel 工作簿"),
        "xlsm": .init(category: .spreadsheet, description: "Excel 宏工作簿"),
        "numbers": .init(category: .spreadsheet, description: "Numbers 表格"),
        "ods": .init(category: .spreadsheet, description: "OpenDocument 表格"),
        // 演示文稿
        "ppt": .init(category: .presentation, description: "PowerPoint 演示文稿"),
        "pptx": .init(category: .presentation, description: "PowerPoint 演示文稿"),
        "key": .init(category: .presentation, description: "Keynote 演示文稿"),
        "odp": .init(category: .presentation, description: "OpenDocument 演示文稿"),
        // PDF / 电子书
        "pdf": .init(category: .pdf, description: "PDF 文档"),
        "epub": .init(category: .ebook, description: "EPUB 电子书"),
        "mobi": .init(category: .ebook, description: "Mobi 电子书"),
        "azw": .init(category: .ebook, description: "Kindle 电子书"),
        "azw3": .init(category: .ebook, description: "Kindle 电子书"),
        "djvu": .init(category: .ebook, description: "DjVu 文档"),
        // 压缩包
        "zip": .init(category: .archive, description: "ZIP 压缩包"),
        "rar": .init(category: .archive, description: "RAR 压缩包"),
        "7z": .init(category: .archive, description: "7-Zip 压缩包"),
        "tar": .init(category: .archive, description: "TAR 归档"),
        "gz": .init(category: .archive, description: "GZip 压缩"),
        "tgz": .init(category: .archive, description: "TAR.GZ 归档"),
        "bz2": .init(category: .archive, description: "BZip2 压缩"),
        "xz": .init(category: .archive, description: "XZ 压缩"),
        "zst": .init(category: .archive, description: "Zstandard 压缩"),
        "xip": .init(category: .archive, description: "XIP 归档"),
        "jar": .init(category: .archive, description: "Java 归档"),
        "war": .init(category: .archive, description: "Java Web 归档"),
        // 磁盘映像 / 安装包
        "dmg": .init(category: .disk, description: "磁盘映像"),
        "iso": .init(category: .disk, description: "光盘映像"),
        "pkg": .init(category: .disk, description: "安装包"),
        "mpkg": .init(category: .disk, description: "安装包"),
        // 代码
        "py": .init(category: .code, description: "Python 源码"),
        "pyw": .init(category: .code, description: "Python 源码"),
        "ipynb": .init(category: .code, description: "Jupyter 笔记本"),
        "js": .init(category: .code, description: "JavaScript 源码"),
        "mjs": .init(category: .code, description: "JavaScript 模块"),
        "cjs": .init(category: .code, description: "JavaScript 模块"),
        "jsx": .init(category: .code, description: "React 组件"),
        "ts": .init(category: .code, description: "TypeScript 源码"),
        "tsx": .init(category: .code, description: "React TS 组件"),
        "java": .init(category: .code, description: "Java 源码"),
        "kt": .init(category: .code, description: "Kotlin 源码"),
        "swift": .init(category: .code, description: "Swift 源码"),
        "m": .init(category: .code, description: "Objective-C 源码"),
        "mm": .init(category: .code, description: "Objective-C++ 源码"),
        "c": .init(category: .code, description: "C 源码"),
        "h": .init(category: .code, description: "C 头文件"),
        "cpp": .init(category: .code, description: "C++ 源码"),
        "cc": .init(category: .code, description: "C++ 源码"),
        "hpp": .init(category: .code, description: "C++ 头文件"),
        "cs": .init(category: .code, description: "C# 源码"),
        "go": .init(category: .code, description: "Go 源码"),
        "rs": .init(category: .code, description: "Rust 源码"),
        "rb": .init(category: .code, description: "Ruby 源码"),
        "php": .init(category: .code, description: "PHP 源码"),
        "pl": .init(category: .code, description: "Perl 源码"),
        "lua": .init(category: .code, description: "Lua 源码"),
        "r": .init(category: .code, description: "R 源码"),
        "scala": .init(category: .code, description: "Scala 源码"),
        "sh": .init(category: .code, description: "Shell 脚本"),
        "bash": .init(category: .code, description: "Bash 脚本"),
        "zsh": .init(category: .code, description: "Zsh 脚本"),
        "fish": .init(category: .code, description: "Fish 脚本"),
        "ps1": .init(category: .code, description: "PowerShell 脚本"),
        "bat": .init(category: .code, description: "批处理文件"),
        "cmd": .init(category: .code, description: "命令脚本"),
        "html": .init(category: .code, description: "HTML 网页"),
        "htm": .init(category: .code, description: "HTML 网页"),
        "css": .init(category: .code, description: "样式表"),
        "scss": .init(category: .code, description: "SCSS 样式"),
        "less": .init(category: .code, description: "LESS 样式"),
        "vue": .init(category: .code, description: "Vue 组件"),
        "svelte": .init(category: .code, description: "Svelte 组件"),
        "json": .init(category: .code, description: "JSON 数据"),
        "yaml": .init(category: .code, description: "YAML 配置"),
        "yml": .init(category: .code, description: "YAML 配置"),
        "toml": .init(category: .code, description: "TOML 配置"),
        "ini": .init(category: .code, description: "INI 配置"),
        "cfg": .init(category: .code, description: "配置文件"),
        "conf": .init(category: .code, description: "配置文件"),
        "xml": .init(category: .code, description: "XML 文档"),
        "plist": .init(category: .code, description: "属性列表"),
        "sql": .init(category: .code, description: "SQL 脚本"),
        "graphql": .init(category: .code, description: "GraphQL 查询"),
        "patch": .init(category: .code, description: "补丁文件"),
        "diff": .init(category: .code, description: "差异文件"),
        // 数据库
        "db": .init(category: .database, description: "SQLite 数据库"),
        "sqlite": .init(category: .database, description: "SQLite 数据库"),
        "sqlite3": .init(category: .database, description: "SQLite 数据库"),
        "mdb": .init(category: .database, description: "Access 数据库"),
        "accdb": .init(category: .database, description: "Access 数据库"),
        "realm": .init(category: .database, description: "Realm 数据库"),
        // 字体
        "ttf": .init(category: .font, description: "TrueType 字体"),
        "otf": .init(category: .font, description: "OpenType 字体"),
        "woff": .init(category: .font, description: "Web 字体"),
        "woff2": .init(category: .font, description: "Web 字体"),
        "ttc": .init(category: .font, description: "字体集合"),
        // 可执行
        "app": .init(category: .app, description: "应用程序"),
        "exe": .init(category: .executable, description: "Windows 程序"),
        "msi": .init(category: .executable, description: "Windows 安装包"),
        "bin": .init(category: .executable, description: "二进制文件"),
        "so": .init(category: .executable, description: "共享库"),
        "dylib": .init(category: .executable, description: "动态库"),
        "a": .init(category: .executable, description: "静态库"),
        "o": .init(category: .executable, description: "目标文件"),
        "command": .init(category: .executable, description: "终端命令"),
        "apk": .init(category: .executable, description: "Android 安装包"),
        "deb": .init(category: .executable, description: "Debian 软件包"),
        "rpm": .init(category: .executable, description: "RPM 软件包"),
    ]

    /// 作为“可进入的包”还是“双击启动的应用”
    private static let bundleSuffixes: Set<String> = [
        "app", "bundle", "framework", "plugin", "prefpane", "kext",
        "xcodeproj", "xcworkspace", "playground", "sparsebundle",
        "photoslibrary", "photolibrary", "rtfd", "pages", "numbers", "key",
    ]

    private static let nameTable: [String: Info] = [
        "makefile": .init(category: .code, description: "Makefile"),
        "dockerfile": .init(category: .code, description: "Dockerfile"),
        "readme": .init(category: .document, description: "说明文档"),
        "license": .init(category: .document, description: "许可证"),
        "licence": .init(category: .document, description: "许可证"),
        "changelog": .init(category: .document, description: "更新日志"),
        ".gitignore": .init(category: .code, description: "Git 忽略规则"),
        ".zshrc": .init(category: .code, description: "Zsh 配置"),
        ".bashrc": .init(category: .code, description: "Bash 配置"),
        ".bash_profile": .init(category: .code, description: "Bash 配置"),
        ".profile": .init(category: .code, description: "Shell 配置"),
        ".env": .init(category: .code, description: "环境变量"),
    ]

    static func fileExtension(of name: String) -> String {
        // ".zshrc" 这类以点开头的文件按 macOS 约定没有扩展名
        let trimmed = name.hasPrefix(".") ? String(name.dropFirst()) : name
        guard let dot = trimmed.lastIndex(of: ".") else { return "" }
        return String(trimmed[trimmed.index(after: dot)...]).lowercased()
    }

    static func isBundle(_ url: URL, isDirectory: Bool) -> Bool {
        guard isDirectory else { return false }
        let ext = url.pathExtension.lowercased()
        guard bundleSuffixes.contains(ext) else { return false }
        // 文档型包需要 Contents 目录才算包
        switch ext {
        case "app", "framework", "kext", "bundle", "prefpane", "plugin", "xcodeproj", "xcworkspace":
            return true
        default:
            return FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents").path)
        }
    }

    static func info(name: String, isDirectory: Bool, isSymlink: Bool, isBundle: Bool) -> Info {
        if isBundle {
            return .init(category: .app, description: L("type.applicationBundle", "应用程序"))
        }
        if isDirectory {
            return .init(category: .folder, description: isSymlink
                         ? L("type.symlinkFolder", "替身文件夹")
                         : L("type.folder", "文件夹"))
        }
        if isSymlink {
            return .init(category: .other, description: L("type.symlink", "替身"))
        }
        let lower = name.lowercased()
        if let hit = nameTable[lower] { return hit }
        let ext = fileExtension(of: name)
        if let hit = table[ext] { return hit }
        return .init(category: .other, description: L("type.file", "文件"))
    }
}

// MARK: - 文件条目

struct FileItem: Identifiable, Hashable {

    /// 由安卓条目构造。
    ///
    /// 安卓路径用 `android://` 虚拟地址表示，本地 FileManager 不参与，
    /// 因此这里不做资源属性读取，直接用 adb 已取得的信息填充。
    init(androidEntry entry: AndroidEntry) {
        self.id = entry.url.absoluteString
        self.url = entry.url
        self.name = entry.name
        self.isDirectory = entry.isDirectory
        self.isSymlink = entry.isSymlink
        self.isBundle = false
        self.isHidden = entry.name.hasPrefix(".")
        self.isReadable = entry.isReadable
        self.size = entry.isDirectory ? nil : entry.size
        self.modified = entry.modified
        self.created = nil
        // 复用类型库，保证安卓条目与本地条目的类型/分类判定一致
        let info = FileTypeDB.info(name: entry.name, isDirectory: entry.isDirectory,
                                   isSymlink: entry.isSymlink, isBundle: false)
        self.typeDescription = info.description
        self.category = info.category
    }
    let id: String              // 使用完整路径作为稳定标识
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let isBundle: Bool
    let isHidden: Bool
    let isReadable: Bool
    let size: Int64?
    let modified: Date?
    let created: Date?
    let typeDescription: String
    let category: FileCategory

    var isContainer: Bool { isDirectory || isBundle }

    /// 可在应用内进入浏览的容器（.app 等包双击是启动，不进入）
    var isBrowsableFolder: Bool { isDirectory && !(isBundle && url.pathExtension.lowercased() == "app") }

    var displayName: String { name }

    var sizeText: String {
        guard let size else { return "" }
        return FileItem.formatSize(size)
    }

    /// 日期展示：今天 / 昨天 / 月-日 时:分 / 年-月-日 时:分（与资源管理器一致）
    static func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.dateFormat = L("date.todayFormat", "今天 HH:mm")
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = L("date.yesterdayFormat", "昨天 HH:mm")
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            formatter.dateFormat = "MM/dd HH:mm"
        } else {
            formatter.dateFormat = "yyyy/MM/dd HH:mm"
        }
        return formatter.string(from: date)
    }

    /// Windows 资源管理器风格的大小显示：B / KB / MB / GB / TB（1024 进制、固定单位）
    static func formatSize(_ bytes: Int64) -> String {
        if bytes < 0 { return "" }
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes) / 1024
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        let formatted = value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(formatted) \(units[unitIndex])"
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension FileItem {
    /// 用 FileManager 一次性取出属性，避免逐项 stat
    init?(url: URL, resourceKeys: [URLResourceKey], showHidden: Bool) {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return nil }

        let isDirectory = values.isDirectory ?? false
        let isSymlink = values.isSymbolicLink ?? false
        let isHidden = (values.isHidden ?? false) || url.lastPathComponent.hasPrefix(".")
        if isHidden && !showHidden { return nil }

        let name = url.lastPathComponent
        guard !name.isEmpty else { return nil }

        let bundle = FileTypeDB.isBundle(url, isDirectory: isDirectory)
        let info = FileTypeDB.info(name: name, isDirectory: isDirectory, isSymlink: isSymlink, isBundle: bundle)

        self.id = url.path
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isBundle = bundle
        self.isHidden = isHidden
        self.isReadable = values.isReadable ?? true
        if isDirectory && !bundle {
            self.size = nil
        } else {
            self.size = values.fileSize.map { Int64($0) }
        }
        self.modified = values.contentModificationDate
        self.created = values.creationDate
        self.typeDescription = info.description
        self.category = info.category
    }
}
