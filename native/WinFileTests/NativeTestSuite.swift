// WinFile 逻辑层测试套件
// 运行方式一（推荐，带完整 bundle 环境）：
//     WinFile.app/Contents/MacOS/WinFile --run-tests
// 运行方式二（命令行，快速迭代）：
//     ./native/run_native_tests.sh
import AppKit
import Foundation

@MainActor
final class TestReporter {
    static let shared = TestReporter()
    var passed = 0
    var failures: [String] = []

    func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
            print("  ✔ \(name)")
        } else {
            let extra = detail()
            failures.append(extra.isEmpty ? name : "\(name) — \(extra)")
            print("  ✘ \(name)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }
}

@MainActor
private func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    TestReporter.shared.check(name, condition, detail())
}

enum NativeTestSuite {

    static func run() {
        MainActor.assumeIsolated { runOnMain() }
    }

    @MainActor
    private static func runOnMain() {
        guard let sandbox = try? makeSandbox() else {
            print("无法创建测试沙盒")
            exit(1)
        }
        defer { try? FileManager.default.removeItem(at: sandbox) }

        print("== WinFile 逻辑层测试 ==")
        print("沙盒目录：\(sandbox.path)")

        testCategorization()
        do {
            try testListing(sandbox)
            try testOperations(sandbox)
            try testCategoryView(sandbox)
            try testHomeAndThisPC(sandbox)
            testEmptyAreaClassification()
            try testTabManager(sandbox)
            try testSorting(sandbox)
            testAppData()
            testDoubleClickMechanism()
            testTileMarkerLookup()
            try testNewTabUsable()
            testRowAreaRightClick()
            testAndroidParsing()
            testAndroidDevice()
            testAndroidBrowsing()
            testCustomPagesNotReportedEmpty()
            try testArchive()
            testSidebarCategories()
        } catch {
            print("  ✘ 测试抛出异常：\(error.localizedDescription)")
            TestReporter.shared.failures.append("异常：\(error.localizedDescription)")
        }

        let reporter = TestReporter.shared
        print("\n通过 \(reporter.passed) 项，失败 \(reporter.failures.count) 项")
        if !reporter.failures.isEmpty {
            print("失败列表：")
            for item in reporter.failures { print("  - \(item)") }
        } else {
            print("全部通过 ✔")
        }
    }

    // MARK: - 准备

    @MainActor
    private static func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("winfile-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - 分类与类型

    @MainActor
    static func testCategorization() {
        print("\n[文件分类]")
        let cases: [(String, FileCategory)] = [
            ("照片.jpg", .image), ("截图.PNG", .image), ("影片.mp4", .video),
            ("音乐.flac", .audio), ("报告.docx", .document), ("数据.xlsx", .spreadsheet),
            ("讲稿.pptx", .presentation), ("手册.pdf", .pdf), ("包.zip", .archive),
            ("脚本.py", .code), ("组件.tsx", .code), ("字体.ttf", .font),
            ("映像.dmg", .disk), ("库.dylib", .executable), ("数据.sqlite", .database),
            ("书.epub", .ebook), ("设计.psd", .design), ("未知.xyzzy", .other),
        ]
        for (name, expected) in cases {
            let info = FileTypeDB.info(name: name, isDirectory: false, isSymlink: false, isBundle: false)
            check("\(name) 归类为 \(expected.rawValue)", info.category == expected, "实际 \(info.category.rawValue)")
        }
        check("目录归类为文件夹",
              FileTypeDB.info(name: "文件夹", isDirectory: true, isSymlink: false, isBundle: false).category == .folder)
        let symlink = FileTypeDB.info(name: "替身", isDirectory: false, isSymlink: true, isBundle: false)
        check("替身归类为其他并带描述", symlink.category == .other && !symlink.description.isEmpty,
              "\(symlink.category.rawValue)/\(symlink.description)")
        check("TypeScript 归为代码",
              FileTypeDB.info(name: "a.ts", isDirectory: false, isSymlink: false, isBundle: false).category == .code)
        check("m2ts 归为视频",
              FileTypeDB.info(name: "a.m2ts", isDirectory: false, isSymlink: false, isBundle: false).category == .video)
        check("多点扩展名取最后一段", FileTypeDB.fileExtension(of: "a.tar.gz") == "gz")
        check("隐藏文件按约定无扩展名", FileTypeDB.fileExtension(of: ".zshrc") == "")
        check("大小显示为 Windows 风格", FileItem.formatSize(16) == "16 B", FileItem.formatSize(16))
        check("KB 显示一位小数", FileItem.formatSize(2048) == "2.0 KB", FileItem.formatSize(2048))
        check("MB 显示", FileItem.formatSize(5 * 1024 * 1024).contains("MB"), FileItem.formatSize(5 * 1024 * 1024))
    }

    // MARK: - 目录浏览

    @MainActor
    static func testListing(_ sandbox: URL) throws {
        print("\n[目录浏览]")
        let fm = FileManager.default
        try fm.createDirectory(at: sandbox.appendingPathComponent("子目录"), withIntermediateDirectories: true)
        try "你好，WinFile".write(to: sandbox.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
        try Data(repeating: 0, count: 2048).write(to: sandbox.appendingPathComponent("图片.png"))
        try "hidden".write(to: sandbox.appendingPathComponent(".隐藏文件"), atomically: true, encoding: .utf8)

        let visible = try FileSystemService.list(sandbox, showHidden: false)
        check("列出 3 个可见项", visible.count == 3, "实际 \(visible.count)：\(visible.map(\.name))")
        check("隐藏文件默认不显示", !visible.contains { $0.name == ".隐藏文件" })
        check("文件夹排在文件之前", visible.first?.isContainer == true, visible.first?.name ?? "nil")

        let all = try FileSystemService.list(sandbox, showHidden: true)
        check("显示隐藏文件时共 4 项", all.count == 4, "实际 \(all.count)")

        if let folder = visible.first(where: { $0.name == "子目录" }) {
            check("目录不显示大小", folder.size == nil)
            check("目录可进入浏览", folder.isBrowsableFolder)
        } else {
            check("找到子目录", false)
        }
        if let text = visible.first(where: { $0.name == "说明.txt" }) {
            check("文本大小正确", text.size == Int64("你好，WinFile".utf8.count), "\(text.size ?? -1)")
            check("文本类型描述非空", !text.typeDescription.isEmpty, text.typeDescription)
            check("大小文本带单位", text.sizeText.contains("B"), text.sizeText)
        } else {
            check("找到说明.txt", false)
        }

        let bySize = FileSystemService.sort(visible, field: .size, ascending: false)
        let sizes = bySize.filter { !$0.isContainer }.compactMap(\.size)
        check("按大小倒序", sizes == sizes.sorted(by: >), "\(sizes)")
        check("排序后文件夹仍置顶",
              FileSystemService.sort(visible, field: .name, ascending: true).first?.isContainer == true)

        do {
            _ = try FileSystemService.list(sandbox.appendingPathComponent("不存在"), showHidden: false)
            check("不存在的目录应抛错", false)
        } catch {
            check("不存在的目录抛错", true)
        }
    }

    // MARK: - 文件操作

    @MainActor
    static func testOperations(_ sandbox: URL) throws {
        print("\n[文件操作]")
        let engine = FSEngine()
        let fm = FileManager.default

        let folder = try engine.createFolder(in: sandbox, named: "新建文件夹")
        check("创建文件夹", fm.fileExists(atPath: folder.path))
        let second = try engine.createFolder(in: sandbox, named: "新建文件夹")
        check("重名自动加序号", second.lastPathComponent == "新建文件夹 2", second.lastPathComponent)

        let file = try engine.createTextFile(in: sandbox, named: "笔记.txt", contents: "内容A")
        check("创建文件并写入内容", (try? String(contentsOf: file, encoding: .utf8)) == "内容A")

        let renamed = try engine.rename(item(file), to: "笔记-改.txt")
        check("重命名成功", fm.fileExists(atPath: renamed.path))
        do {
            _ = try engine.rename(item(renamed), to: "非法/名称")
            check("非法名称应被拒绝", false)
        } catch {
            check("非法名称被拒绝", true)
        }

        let target = try engine.createFolder(in: sandbox, named: "目标")
        let copied = try engine.transfer([item(renamed)], to: target, mode: .copy)
        check("复制到目标目录", copied.count == 1 && fm.fileExists(atPath: copied[0].path))
        check("复制后原文件仍在", fm.fileExists(atPath: renamed.path))

        let moved = try engine.transfer([item(copied[0])], to: sandbox, mode: .move)
        check("移动回上级目录", moved.count == 1 && fm.fileExists(atPath: moved[0].path))
        check("移动后原位置消失", !fm.fileExists(atPath: copied[0].path))

        do {
            _ = try engine.transfer([item(target)], to: target, mode: .copy)
            check("拒绝复制到自身", false)
        } catch {
            check("拒绝把文件夹复制进它自己", true)
        }
        let nested = target.appendingPathComponent("内层")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        do {
            _ = try engine.transfer([item(target)], to: nested, mode: .move)
            check("拒绝移动到子目录", false)
        } catch {
            check("拒绝把文件夹移动进它的子目录", true)
        }

        let duplicated = try engine.duplicate([item(renamed)])
        check("制作副本", duplicated.count == 1 && fm.fileExists(atPath: duplicated[0].path))
        check("副本名称含“副本”", duplicated[0].lastPathComponent.contains("副本"), duplicated[0].lastPathComponent)

        let trashCandidate = try engine.createTextFile(in: sandbox, named: "待删除.txt")
        try engine.moveToTrash([item(trashCandidate)])
        check("移到废纸篓后原位置消失", !fm.fileExists(atPath: trashCandidate.path))

        let size = FileSystemService.directorySize(sandbox)
        check("目录统计包含文件", size.files >= 3, "files=\(size.files)")
        check("目录大小为正", size.bytes > 0, "bytes=\(size.bytes)")

        check("搜索能找到文件", !FileSystemService.search(under: sandbox, matching: "笔记").isEmpty)
        check("搜索无结果返回空", FileSystemService.search(under: sandbox, matching: "绝对不存在的名字").isEmpty)

        // 唯一命名规则
        let plain = engine.uniqueURL(in: sandbox, name: "重复.txt", isDirectory: false)
        try "x".write(to: plain, atomically: true, encoding: .utf8)
        let next = engine.uniqueURL(in: sandbox, name: "重复.txt", isDirectory: false)
        check("重名时生成“名称 2.ext”", next.lastPathComponent == "重复 2.txt", next.lastPathComponent)
    }

    // MARK: - 分类视图（回归：徽标数字与分类内容必须一致）

    @MainActor
    static func testCategoryView(_ sandbox: URL) throws {
        print("\n[分类视图]")
        let fm = FileManager.default
        let root = sandbox.appendingPathComponent("分类用例")
        let nested = root.appendingPathComponent("更深一层")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)

        // 铺开各类文件
        let files: [(String, FileCategory)] = [
            ("图片一.png", .image), ("图片二.jpg", .image), ("图层.psd", .design),
            ("短片.mp4", .video), ("音乐.mp3", .audio), ("报告.docx", .document),
            ("表格.xlsx", .spreadsheet), ("幻灯.pptx", .presentation), ("手册.pdf", .pdf),
            ("压缩.zip", .archive), ("脚本.py", .code), ("字体.ttf", .font),
        ]
        for (name, _) in files {
            try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // 子目录里的图片也应被收集（验证递归）
        try "y".write(to: nested.appendingPathComponent("深层图片.png"), atomically: true, encoding: .utf8)
        // 隐藏文件不应出现
        try "z".write(to: root.appendingPathComponent(".隐藏图片.png"), atomically: true, encoding: .utf8)

        let images = FileSystemService.categoryFiles(.image, under: [root])
        check("分类只收集图片类（含子目录，.psd 属设计素材不算图片）",
              images.count == 3 && images.allSatisfy({ $0.category == .image }),
              "实际 \(images.count)：\(images.map(\.name))")
        let designs = FileSystemService.categoryFiles(.design, under: [root])
        check("设计素材单独归类", designs.count == 1 && designs[0].name == "图层.psd", "\(designs.map(\.name))")
        let hasNested = images.contains(where: { $0.name == "深层图片.png" })
        check("分类会递归子目录", hasNested)
        let hasHidden = images.contains(where: { $0.name.hasPrefix(".") })
        check("分类排除隐藏文件", !hasHidden)
        let allImages = images.allSatisfy({ $0.category == .image })
        check("分类结果都是该类型", allImages)

        let videos = FileSystemService.categoryFiles(.video, under: [root])
        check("视频分类只含视频", videos.count == 1 && videos[0].name == "短片.mp4", "\(videos.map(\.name))")

        // 关键一致性：徽标数字 == 分类视图条目数
        let counts = FileSystemService.categoryCounts(under: [root])
        for (name, category) in files {
            let inView = FileSystemService.categoryFiles(category, under: [root]).count
            let badge = counts[category] ?? 0
            check("徽标与内容一致：\(name) (\(category.rawValue))", badge == inView, "徽标=\(badge) 内容=\(inView)")
        }

        // 排序：按修改时间倒序
        let sorted = FileSystemService.categoryFiles(.image, under: [root])
        let dates = sorted.compactMap(\.modified)
        let descending = dates == dates.sorted(by: >)
        check("分类结果按修改时间倒序", descending)

        // 空分类不应返回内容
        let emptyCategory = FileSystemService.categoryFiles(.ebook, under: [root])
        check("没有该类型时返回空", emptyCategory.isEmpty)

        // BrowserModel 集成：点击分类后 displayedItems 应来自分类结果
        let engine = FSEngine()
        engine.restrictScopeForTesting([root])   // 让分类检索范围可控
        let model = BrowserModel(engine: engine, startDirectory: root)
        model.reload()
        waitFor { !model.items.isEmpty }
        let loadedDirectoryCount = model.displayedItems.count
        check("进入分类前显示目录内容", loadedDirectoryCount >= files.count + 1,
              "\(loadedDirectoryCount)（可见文件 \(files.count) + 子目录，隐藏文件开关会影响）")
        model.loadCategory(.image)
        waitFor { !model.isLoadingCategory && !model.categoryResults.isEmpty }
        let categoryNames = Set(model.displayedItems.map(\.name))
        check("点击分类后展示该分类的全部文件（不受当前目录限制）",
              categoryNames == ["图片一.png", "图片二.jpg", "深层图片.png"],
              "实际 \(model.displayedItems.count) 项：\(categoryNames.sorted())")
        check("分类视图标记正确", model.isCategoryView)
        check("分类视图状态栏非空且含数量",
              !model.statusMessage.isEmpty && model.statusMessage.contains("\(model.displayedItems.count)"),
              model.statusMessage)
        // 回到目录应清空分类
        model.selectFolder(root)
        waitFor { !model.isCategoryView && !model.items.isEmpty }
        check("切回文件夹后退出分类视图", !model.isCategoryView && model.categoryResults.isEmpty)
        check("切回文件夹后能看到全部目录内容", model.displayedItems.count == loadedDirectoryCount,
              "\(model.displayedItems.count) vs \(loadedDirectoryCount)")
    }

    // MARK: - 主页与此电脑（Windows 的两个页面）

    @MainActor
    static func testHomeAndThisPC(_ sandbox: URL) throws {
        print("\n[主页与此电脑]")
        let fm = FileManager.default

        // ---- 此电脑：驱动器
        let drives = PlacesService.drives()
        check("列出至少一个驱动器", !drives.isEmpty, "\(drives.count) 个")
        check("包含启动磁盘", drives.contains { $0.isRoot }, drives.map(\.name).joined(separator: ", "))
        if let root = drives.first(where: { $0.isRoot }) {
            check("启动磁盘有容量信息", root.totalBytes > 0, "total=\(root.totalBytes)")
            check("启动磁盘可用空间不大于总量", root.freeBytes <= root.totalBytes)
            check("已用比例在 0…1 之间", root.usedFraction >= 0 && root.usedFraction <= 1,
                  String(format: "%.2f", root.usedFraction))
            check("容量文本带单位", root.totalText.contains("B"), root.totalText)
            check("启动磁盘不可弹出", !root.isEjectable)
            check("启动磁盘有类型说明", !root.kindDescription.isEmpty, root.kindDescription)
        }
        check("驱动器 id 唯一", Set(drives.map(\.id)).count == drives.count)

        // ---- 主页：快速访问
        let quick = PlacesService.quickAccessFolders()
        check("快速访问非空", !quick.isEmpty, "\(quick.count) 项")
        check("快速访问含个人文件夹或应用程序",
              quick.contains { $0.kind == .home || $0.kind == .applications },
              quick.map(\.name).joined(separator: ", "))
        check("快速访问项都有名称与路径", quick.allSatisfy { !$0.name.isEmpty && !$0.url.path.isEmpty })
        check("快速访问路径都真实存在", quick.allSatisfy { fm.fileExists(atPath: $0.url.path) })

        // ---- 主页：收藏夹
        let store = FavoritesStore.shared
        let pinTarget = sandbox
        let wasPinned = store.isPinned(pinTarget)
        if !wasPinned { store.pin(pinTarget) }
        check("可固定文件夹到收藏夹", store.isPinned(pinTarget))
        check("收藏夹列表包含刚固定的目录",
              store.pinnedFolders.contains { $0.path == pinTarget.standardizedFileURL.path },
              store.pinnedFolders.map(\.lastPathComponent).joined(separator: ", "))
        store.unpin(pinTarget)
        check("可取消固定", !store.isPinned(pinTarget))

        // ---- 主页：最近使用（最近修改 + 最近打开）
        let recentRoot = sandbox.appendingPathComponent("最近用例")
        try fm.createDirectory(at: recentRoot, withIntermediateDirectories: true)
        let newest = recentRoot.appendingPathComponent("刚修改的文件.txt")
        try "new".write(to: newest, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: newest.path)
        let older = recentRoot.appendingPathComponent("较早的文件.txt")
        try "old".write(to: older, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400 * 10)], ofItemAtPath: older.path)

        let entries = PlacesService.recentEntries(under: [recentRoot], limit: 50)
        check("最近使用包含刚修改的文件", entries.contains { $0.item.name == "刚修改的文件.txt" },
              entries.map(\.item.name).joined(separator: ", "))
        check("最近使用按时间倒序", entries.map(\.sortDate) == entries.map(\.sortDate).sorted(by: >))
        let newestFirst = entries.first?.item.name == "刚修改的文件.txt"
        check("最新修改的排在最前", newestFirst, entries.first?.item.name ?? "无")
        check("时间说明非空", entries.allSatisfy { !$0.timeDescription.isEmpty })

        // 记录「最近打开」后应带标记并置顶
        store.recordOpened(older)
        check("可记录最近打开", store.lastOpened(older) != nil)
        let afterOpen = PlacesService.recentEntries(under: [recentRoot], limit: 50)
        if let first = afterOpen.first {
            check("刚打开的文件带「已打开」标记", first.openedRecently, first.item.name)
            check("刚打开的排在首位", first.item.name == "较早的文件.txt", first.item.name)
        } else {
            check("最近使用非空", false)
        }
        store.clearOpened()
        check("可清除打开记录", store.lastOpened(older) == nil)

        // ---- BrowserModel 集成
        let engine = FSEngine()
        engine.restrictScopeForTesting([recentRoot])
        let model = BrowserModel(engine: engine, startDirectory: recentRoot)
        model.loadThisPC()
        waitFor { !model.isLoadingDrives }
        check("此电脑页可加载驱动器", !model.drives.isEmpty, "\(model.drives.count) 个")
        check("此电脑页标记正确", model.isThisPCView)
        check("此电脑页状态栏有数量", model.statusMessage.contains("\(model.drives.count)"), model.statusMessage)

        model.loadHome()
        waitFor { !model.isLoadingHome }
        check("主页可加载快速访问", !model.quickAccess.isEmpty, "\(model.quickAccess.count) 项")
        check("主页标记正确", model.isHomeView)
        check("主页最近使用非空", !model.recentEntries.isEmpty, "\(model.recentEntries.count) 项")
        check("切到主页会清空列表数据", model.items.isEmpty)

        // 切回文件夹应退出主页态
        model.selectFolder(recentRoot)
        waitFor { !model.items.isEmpty }
        check("切回文件夹后退出主页态", !model.isHomeView && !model.isThisPCView)
        check("切回文件夹后能看到内容", model.displayedItems.count >= 2, "\(model.displayedItems.count)")
    }

    // MARK: - 空白处右键的命中判定
    // 这段逻辑决定事件监听是否会吞掉正常右键，必须有测试覆盖

    @MainActor
    static func testEmptyAreaClassification() {
        print("\n[空白处右键判定]")

        // 构造一套与真实层级相近的视图树：
        // NSScrollView → clipView → NSTableView → NSTableRowView → NSTableCellView → 内容
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let clipView = NSClipView(frame: scrollView.bounds)
        let tableView = NSTableView(frame: clipView.bounds)
        scrollView.documentView = tableView
        clipView.addSubview(tableView)
        scrollView.addSubview(clipView)

        let row = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 600, height: 24))
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        let content = NSView(frame: cell.bounds)
        cell.addSubview(content)
        row.addSubview(cell)
        tableView.addSubview(row)

        let header = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: 24))
        tableView.headerView = header

        let scroller = NSScroller(frame: NSRect(x: 590, y: 0, width: 10, height: 400))
        scrollView.addSubview(scroller)

        check("行内内容 → 视为可交互（不弹背景菜单）", EmptyAreaContextMenu.InstallerView.classify(content, in: scrollView))
        check("单元格 → 视为可交互", EmptyAreaContextMenu.InstallerView.classify(cell, in: scrollView))
        check("行 → 视为可交互", EmptyAreaContextMenu.InstallerView.classify(row, in: scrollView))
        check("表头 → 视为可交互", EmptyAreaContextMenu.InstallerView.classify(header, in: scrollView))
        check("滚动条 → 视为可交互", EmptyAreaContextMenu.InstallerView.classify(scroller, in: scrollView))

        check("表格本体（行下方空白）→ 视为空白", !EmptyAreaContextMenu.InstallerView.classify(tableView, in: scrollView))
        check("文档视图 → 视为空白", !EmptyAreaContextMenu.InstallerView.classify(clipView, in: scrollView))

        // 表格内的普通容器若不是行/单元格，也应视为空白（比如 SwiftUI 的背景层）
        let plainContainer = NSView(frame: tableView.bounds)
        tableView.addSubview(plainContainer)
        check("表格内的普通容器 → 视为空白", !EmptyAreaContextMenu.InstallerView.classify(plainContainer, in: scrollView))

        // 查找所属滚动视图
        check("能从行找到所属滚动视图",
              EmptyAreaContextMenu.InstallerView.scrollViewOwning(row) === scrollView)
        check("无从属滚动视图时返回空",
              EmptyAreaContextMenu.InstallerView.scrollViewOwning(NSView()) == nil)

        // 不在滚动容器内的控件不应被判定为空白
        let standalone = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        check("滚动容器之外不参与背景菜单",
              EmptyAreaContextMenu.InstallerView.scrollViewOwning(standalone) == nil)

        // ---- 归属限定：真实窗口内的两个滚动视图（内容区 vs 侧边栏）不能互相误判
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = root

        func makeList(x: CGFloat, width: CGFloat, rows: Int) -> (NSScrollView, NSTableView, NSTableRowView) {
            let scroll = NSScrollView(frame: NSRect(x: x, y: 0, width: width, height: 600))
            let clip = NSClipView(frame: scroll.bounds)
            let table = NSTableView(frame: clip.bounds)
            scroll.documentView = table
            scroll.addSubview(clip)
            clip.addSubview(table)
            root.addSubview(scroll)
            var row: NSTableRowView?
            for index in 0..<rows {
                let rowView = NSTableRowView(frame: NSRect(x: 0, y: CGFloat(index) * 24, width: width, height: 24))
                table.addSubview(rowView)
                row = rowView
            }
            return (scroll, table, row ?? NSTableRowView())
        }

        let (contentScroll, contentTable, contentRow) = makeList(x: 220, width: 680, rows: 5)
        let (sidebarScroll, _, sidebarRow) = makeList(x: 0, width: 216, rows: 40)

        // 标记 = 内容区列表容器
        let marker = contentScroll
        check("内容区表格属于内容区标记", EmptyAreaContextMenu.InstallerView.isDescendant(contentTable, of: marker))
        check("内容区行属于内容区标记", EmptyAreaContextMenu.InstallerView.isDescendant(contentRow, of: marker))
        check("侧边栏行不属于内容区标记", !EmptyAreaContextMenu.InstallerView.isDescendant(sidebarRow, of: marker))
        check("侧边栏滚动视图不属于内容区标记", !EmptyAreaContextMenu.InstallerView.isDescendant(sidebarScroll, of: marker))
        check("标记自身视为命中", EmptyAreaContextMenu.InstallerView.isDescendant(marker, of: marker))

        check("能从内容区表格找到内容区滚动视图",
              EmptyAreaContextMenu.InstallerView.scrollViewOwning(contentTable) === contentScroll)
        check("能从侧边栏行找到侧边栏滚动视图",
              EmptyAreaContextMenu.InstallerView.scrollViewOwning(sidebarRow) === sidebarScroll)
        check("firstScrollView 能在容器中找到滚动视图",
              EmptyAreaContextMenu.InstallerView.firstScrollView(in: marker) === contentScroll)
        check("内容区行内点击 → 不出背景菜单",
              EmptyAreaContextMenu.InstallerView.classify(contentRow, in: contentScroll))
        check("内容区行下方背景 → 出背景菜单",
              !EmptyAreaContextMenu.InstallerView.classify(contentTable, in: contentScroll))

        // 锚点包含判定：内容区的锚点不应命中侧边栏滚动视图，反之亦然
        let contentAnchor = NSView(frame: NSRect(x: 220, y: 0, width: 0, height: 0))
        let sidebarAnchor = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 0))
        root.addSubview(contentAnchor)
        root.addSubview(sidebarAnchor)

        check("内容区锚点命中内容区滚动视图",
              EmptyAreaContextMenu.InstallerView.isAnchor(contentAnchor, inside: contentScroll))
        check("内容区锚点不命中侧边栏滚动视图",
              !EmptyAreaContextMenu.InstallerView.isAnchor(contentAnchor, inside: sidebarScroll))
        check("侧边栏锚点命中侧边栏滚动视图",
              EmptyAreaContextMenu.InstallerView.isAnchor(sidebarAnchor, inside: sidebarScroll))
        check("侧边栏锚点不命中内容区滚动视图",
              !EmptyAreaContextMenu.InstallerView.isAnchor(sidebarAnchor, inside: contentScroll))

        // ---- 空文件夹：表格没有任何行，整片区域都应视为空白（否则右键新建就点不出来）
        let emptyScroll = NSScrollView(frame: NSRect(x: 220, y: 0, width: 680, height: 600))
        let emptyClip = NSClipView(frame: emptyScroll.bounds)
        let emptyTable = NSTableView(frame: emptyClip.bounds)
        emptyScroll.documentView = emptyTable
        emptyScroll.addSubview(emptyClip)
        emptyClip.addSubview(emptyTable)
        root.addSubview(emptyScroll)

        check("空表格本体 → 视为空白（可右键新建）",
              !EmptyAreaContextMenu.InstallerView.classify(emptyTable, in: emptyScroll))
        check("空表格没有行区域", EmptyAreaContextMenu.InstallerView.rowAreaBottom(emptyTable) == nil)

        // ---- 有行时：行区域内的点算交互，行区域外算空白
        check("有行时存在行区域底边",
              (EmptyAreaContextMenu.InstallerView.rowAreaBottom(contentTable) ?? 0) > 0)
        let lastRowBottom = EmptyAreaContextMenu.InstallerView.rowAreaBottom(contentTable) ?? 0
        check("行区域内不算空白",
              !EmptyAreaContextMenu.InstallerView.isBelowRows(contentTable,
                                                             point: NSPoint(x: 0, y: max(0, lastRowBottom - 4))))
        check("行区域下方算空白",
              EmptyAreaContextMenu.InstallerView.isBelowRows(contentTable,
                                                            point: NSPoint(x: 0, y: lastRowBottom + 40)))
    }

    // MARK: - 页签管理

    /// 测试用表格数据源
    final class StubTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let rows: Int
        init(rows: Int) { self.rows = rows }
        func numberOfRows(in tableView: NSTableView) -> Int { rows }
    }

    // MARK: - 安卓目录解析

    @MainActor
    static func testAndroidParsing() {
        print("\n[安卓目录解析]")

        // 真实 toybox ls -la 输出（含目录、文件、符号链接、含空格文件名、中文名）
        let sample = """
        total 42
        drwxrwx--x   4 root   sdcard_rw    4096 2024-05-01 12:00 Download
        -rw-rw----   1 u0_a123 sdcard_rw  12345 2024-05-01 12:00 note.txt
        lrwxrwxrwx   1 root   root           21 2024-05-01 12:00 sdcard -> /storage/self/primary
        drwxrwx--x   2 root   sdcard_rw    4096 2024-05-01 12:00 My Documents
        -rw-rw----   1 u0_a123 sdcard_rw    1024 2024-05-01 12:00 微信文件.txt
        drwxrwx--x   3 root   sdcard_rw    4096 2024-05-01 12:00 Android
        """

        let entries = AndroidEntry.parseListOutput(sample, parent: "/sdcard")
        check("解析出全部条目（跳过 total 行）", entries.count == 6, "\(entries.count) 项")

        let download = entries.first { $0.name == "Download" }
        check("目录被识别为目录", download?.isDirectory == true)
        check("目录路径拼接正确", download?.path == "/sdcard/Download", download?.path ?? "无")

        let note = entries.first { $0.name == "note.txt" }
        check("文件被识别为文件", note?.isDirectory == false)
        check("文件大小解析正确", note?.size == 12345, "\(note?.size ?? -1)")
        check("文件路径正确", note?.path == "/sdcard/note.txt", note?.path ?? "无")

        let link = entries.first { $0.name == "sdcard" }
        check("符号链接被识别", link?.isSymlink == true)
        check("符号链接名去掉了箭头目标", link?.name == "sdcard", link?.name ?? "无")

        let spaced = entries.first { $0.name == "My Documents" }
        let allNames = entries.map { $0.name }.joined(separator: "/")
        check("含空格的文件名解析正确", spaced != nil, allNames)

        let chinese = entries.first { $0.name == "微信文件.txt" }
        check("中文文件名解析正确", chinese != nil, allNames)

        // 日期解析
        check("日期解析成功", note?.modified != nil)

        // 大小格式化
        check("大小格式化 B", AndroidEntry.formatSize(512) == "512 B", AndroidEntry.formatSize(512))
        check("大小格式化 KB", AndroidEntry.formatSize(2048) == "2.0 KB", AndroidEntry.formatSize(2048))
        check("大小格式化 MB", AndroidEntry.formatSize(5 * 1024 * 1024) == "5.0 MB",
              AndroidEntry.formatSize(5 * 1024 * 1024))

        // 虚拟地址
        let url = AndroidURL.make(serial: "ABC123", path: "/sdcard/Download")
        check("虚拟地址是 android 方案", AndroidURL.isAndroid(url))
        let split = AndroidURL.split(url)
        check("虚拟地址可拆回序列号", split?.serial == "ABC123", split?.serial ?? "无")
        check("虚拟地址可拆回路径", split?.path == "/sdcard/Download", split?.path ?? "无")
        check("本地地址不被识别为安卓", !AndroidURL.isAndroid(URL(fileURLWithPath: "/tmp")))

        // 序列号必须保留大小写（adb 区分大小写，URLComponents 会转小写）
        let mixedCase = AndroidURL.make(serial: "HA2B7QSF", path: "/storage/emulated/0")
        let roundTrip = AndroidURL.split(mixedCase)
        check("序列号大小写被保留", roundTrip?.serial == "HA2B7QSF", roundTrip?.serial ?? "无")
        check("嵌套路径可往返",
              AndroidURL.split(AndroidURL.make(serial: "S1", path: "/a/b/c"))?.path == "/a/b/c")
        check("含空格路径可往返",
              AndroidURL.split(AndroidURL.make(serial: "S1", path: "/a/My Documents"))?.path == "/a/My Documents",
              AndroidURL.split(AndroidURL.make(serial: "S1", path: "/a/My Documents"))?.path ?? "无")
        check("含中文路径可往返",
              AndroidURL.split(AndroidURL.make(serial: "S1", path: "/a/文档"))?.path == "/a/文档")

        // adb 可用性（本机已安装）
        check("检测到 adb", AdbRunner.isAvailable, AdbRunner.adbPath() ?? "未找到")
    }

    // MARK: - 安卓设备实连（有设备时才跑）

    @MainActor
    static func testAndroidDevice() {
        print("\n[安卓设备实连]")

        let probe = AndroidProbe.run()
        print("  探测结果: \(probe.summary)")
        check("检测到 adb", probe.adbAvailable, probe.adbPath ?? "未找到")

        guard probe.isUsable, let serial = probe.readySerials.first,
              let root = probe.storageRoot else {
            print("  跳过实连测试（\(probe.summary)）")
            return
        }
        print("  设备序号: \(serial)  存储根: \(root)")

        let service = AndroidFileService(serial: serial)
        let sandbox = root + "/WinFileAutoTest"

        // 清理可能的残留
        try? service.remove(sandbox)

        do {
            // 创建目录
            try service.createFolder(at: sandbox)
            let entriesAfterCreate = try service.list(root)
            check("能在设备上创建文件夹",
                  entriesAfterCreate.contains { $0.name == "WinFileAutoTest" },
                  "\(entriesAfterCreate.count) 项")

            // 上传
            let localFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("winfile-\(UUID().uuidString).txt")
            let content = "WinFile 安卓写入测试 \(Date())"
            try content.write(to: localFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: localFile) }

            try service.push(local: localFile, to: sandbox)
            let listed = try service.list(sandbox)
            check("上传后设备上能看到文件", listed.count == 1, "\(listed.count) 项")
            check("上传的文件大小正确",
                  listed.first?.size == Int64(content.utf8.count),
                  "\(listed.first?.size ?? -1) vs \(content.utf8.count)")

            // 重命名
            if let uploaded = listed.first {
                try service.rename(uploaded.path, to: "renamed-by-test.txt")
                let afterRename = try service.list(sandbox)
                check("重命名生效",
                      afterRename.first?.name == "renamed-by-test.txt",
                      afterRename.first?.name ?? "无")

                // 下载回本地并比对内容
                let backURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("winfile-back-\(UUID().uuidString).txt")
                defer { try? FileManager.default.removeItem(at: backURL) }
                try service.pull(remote: afterRename.first?.path ?? "", to: backURL)
                let readBack = (try? String(contentsOf: backURL, encoding: .utf8)) ?? ""
                check("下载内容与上传一致", readBack == content,
                      "长度 \(readBack.count) vs \(content.count)")

                // 复制
                try service.copy(afterRename.first?.path ?? "", to: sandbox)
                let afterCopy = try service.list(sandbox)
                check("复制后条目增加", afterCopy.count == 2, "\(afterCopy.count) 项")

                // 单个删除
                if let first = afterCopy.first {
                    try service.remove(first.path)
                    let afterRemove = try service.list(sandbox)
                    check("单个删除生效", afterRemove.count == 1, "\(afterRemove.count) 项")
                }
            }

            // 递归删除整个测试目录
            try service.remove(sandbox)
            let finalEntries = try service.list(root)
            check("递归删除测试目录",
                  !finalEntries.contains { $0.name == "WinFileAutoTest" })
        } catch {
            check("安卓文件操作无异常", false, error.localizedDescription)
            try? service.remove(sandbox)
        }
    }

    // MARK: - 压缩与解压

    @MainActor
    static func testArchive() throws {
        print("\n[压缩与解压]")

        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("winfile-archive-\(UUID().uuidString)")
        let source = base.appendingPathComponent("源目录")
        let output = base.appendingPathComponent("输出")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        // 造出：普通文件、子目录、含空格与中文的名字
        try "内容 A".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "内容 B".write(to: source.appendingPathComponent("带 空格.txt"), atomically: true, encoding: .utf8)
        let sub = source.appendingPathComponent("子目录")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try "内容 C".write(to: sub.appendingPathComponent("中文名.txt"), atomically: true, encoding: .utf8)

        // 压缩
        let archive = try ArchiveService.compress([source], to: output, name: "test")
        check("生成了压缩包", fm.fileExists(atPath: archive.path))
        check("扩展名是 zip", archive.pathExtension == "zip", archive.pathExtension)
        let size = (try? fm.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
        check("压缩包非空", (size ?? 0) > 0, "\(size ?? 0) 字节")

        // 压缩包识别
        check("能识别 zip 为压缩包", ArchiveService.isArchive(archive))
        check("普通文件不被识别为压缩包",
              !ArchiveService.isArchive(source.appendingPathComponent("a.txt")))

        // 压缩包结构：顶层应保留「源目录」，而不是把内容铺平
        let topLevel = ArchiveService.topLevelNames(of: archive)
        check("能读出压缩包顶层结构", !topLevel.isEmpty, "\(topLevel.count) 项")
        check("顶层保留被压缩的目录名（解压不铺平）",
              topLevel.contains("源目录"), topLevel.joined(separator: "/"))

        // 解压到新目录并逐项比对（关键：内容必须完整）
        let restore = base.appendingPathComponent("还原")
        try fm.createDirectory(at: restore, withIntermediateDirectories: true)
        let created = try ArchiveService.extract(archive, to: restore)
        check("解压返回了顶层项目", !created.isEmpty, "\(created.count) 项")

        let restoredRoot = restore.appendingPathComponent("源目录")
        check("解压后目录结构正确", fm.fileExists(atPath: restoredRoot.path))
        let restoredA = restoredRoot.appendingPathComponent("a.txt")
        let restoredSpace = restoredRoot.appendingPathComponent("带 空格.txt")
        let restoredChinese = restoredRoot.appendingPathComponent("子目录/中文名.txt")
        check("普通文件已还原", fm.fileExists(atPath: restoredA.path))
        check("含空格文件名已还原", fm.fileExists(atPath: restoredSpace.path))
        check("子目录中的中文名已还原", fm.fileExists(atPath: restoredChinese.path))

        let original = (try? String(contentsOf: source.appendingPathComponent("a.txt"), encoding: .utf8)) ?? ""
        let restored = (try? String(contentsOf: restoredA, encoding: .utf8)) ?? ""
        check("文件内容一致", original == restored, "原文=\(original) 还原=\(restored)")

        // 重名处理：再次压缩应生成不冲突的名字
        let second = try ArchiveService.compress([source], to: output, name: "test")
        check("同名压缩包不会覆盖", second.lastPathComponent != archive.lastPathComponent,
              second.lastPathComponent)

        // 默认命名
        check("单个项目用其名称作压缩包名",
              ArchiveService.defaultArchiveName(for: [source]) == "源目录",
              ArchiveService.defaultArchiveName(for: [source]))
        check("多个项目用统一名称",
              ArchiveService.defaultArchiveName(for: [source, source]).isEmpty == false)

        // 空选择应报错而非静默失败
        do {
            _ = try ArchiveService.compress([], to: output, name: "empty")
            check("空选择应报错", false, "未报错")
        } catch {
            check("空选择报错", true)
        }
    }

    // MARK: - 侧边栏分类管理

    @MainActor
    static func testSidebarCategories() {
        print("\n[侧边栏分类管理]")

        let prefs = SidebarPreferences.shared
        prefs.resetToDefault()

        let all = FileCategory.sidebarOrder
        check("默认显示全部分类", prefs.visibleCategories.count == all.count,
              "\(prefs.visibleCategories.count)/\(all.count)")
        check("默认没有被隐藏的分类", prefs.hiddenCategoryList.isEmpty)

        // 移除一个
        let target = all[0]
        prefs.hide(target)
        check("移除后不再显示", !prefs.visibleCategories.contains(target))
        check("移除后进入可添加列表", prefs.hiddenCategoryList.contains(target))
        check("移除不影响其它分类",
              prefs.visibleCategories.count == all.count - 1,
              "\(prefs.visibleCategories.count)")

        // 加回
        prefs.show(target)
        check("加回后重新显示", prefs.visibleCategories.contains(target))
        check("加回后从可添加列表移除", !prefs.hiddenCategoryList.contains(target))

        // 至少保留一个：全部隐藏后仍应有分类
        for category in all { prefs.hide(category) }
        check("全部隐藏后仍保留至少一个分类",
              !prefs.visibleCategories.isEmpty,
              "\(prefs.visibleCategories.count) 个")

        // 恢复默认
        prefs.resetToDefault()
        check("恢复默认后全部显示", prefs.visibleCategories.count == all.count,
              "\(prefs.visibleCategories.count)")
        check("恢复默认后隐藏列表为空", prefs.hiddenCategoryList.isEmpty)
    }

    // MARK: - 自定义页面不应误报"空"

    @MainActor
    static func testCustomPagesNotReportedEmpty() {
        print("\n[自定义页面空状态判定]")

        let model = BrowserModel(engine: FSEngine(), startDirectory: nil)

        // 主页
        model.navigate(to: .home)
        check("主页不显示文件列表空状态", !model.showsFileList)

        // 此电脑
        model.navigate(to: .thisPC)
        check("此电脑不显示文件列表空状态", !model.showsFileList)

        // 应用数据（用户报告的误报场景）
        model.navigate(to: .appData)
        check("应用数据页不显示文件列表空状态", !model.showsFileList,
              "displayedItems=\(model.displayedItems.count)")

        // 应用程序
        model.navigate(to: .applications)
        check("应用程序页不显示文件列表空状态", !model.showsFileList)

        // 安卓设备
        model.navigate(to: .androidDevice(serial: "TEST"))
        check("安卓设备页不显示文件列表空状态", !model.showsFileList)

        // 普通文件夹应当显示（空目录时给提示是正确的）
        // 注意：必须用自建的空目录，系统临时目录里通常已有大量文件
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("winfile-empty-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        // 用全新模型加载，避免前面导航遗留的异步任务干扰
        let fresh = BrowserModel(engine: FSEngine(), startDirectory: temp)
        let deadline = Date().addingTimeInterval(12)
        while fresh.isBusy && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        check("普通文件夹仍由文件列表承载", fresh.showsFileList)
        check("空文件夹确实没有内容", fresh.displayedItems.isEmpty,
              "\(fresh.displayedItems.count) 项，目录=\(fresh.currentDirectory?.lastPathComponent ?? "无")")
    }

    // MARK: - 安卓目录浏览（模型层）

    @MainActor
    static func testAndroidBrowsing() {
        print("\n[安卓目录浏览]")

        let probe = AndroidProbe.run()
        guard probe.isUsable, let serial = probe.readySerials.first,
              let root = probe.storageRoot else {
            print("  跳过（\(probe.summary)）")
            return
        }

        let model = BrowserModel(engine: FSEngine(), startDirectory: nil)
        let dirURL = AndroidURL.make(serial: serial, path: root)
        model.selectFolder(dirURL)

        // 等待异步加载
        let deadline = Date().addingTimeInterval(25)
        while model.isLoadingAndroid && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        check("安卓目录能被模型载入", !model.items.isEmpty, "\(model.items.count) 项")
        check("当前路径被识别为安卓", model.isAndroidPath)
        check("条目保留了安卓原始信息", !model.androidEntries.isEmpty,
              "\(model.androidEntries.count) 项")

        // 条目属性
        if let first = model.items.first {
            check("条目使用 android:// 虚拟地址", AndroidURL.isAndroid(first.url), first.url.absoluteString)
            check("条目有名称", !first.name.isEmpty, first.name)
        }

        // 目录优先排序（与本地一致）
        let dirsFirst = model.items.first?.isDirectory ?? false
        let hasDir = model.items.contains { $0.isDirectory }
        check("存在目录时目录排在前", !hasDir || dirsFirst,
              "首项=\(model.items.first?.name ?? "无") 是否目录=\(dirsFirst)")

        // 进入子目录
        if let sub = model.androidEntries.first(where: { $0.isDirectory }) {
            model.selectFolder(sub.url)
            let deadline2 = Date().addingTimeInterval(25)
            while model.isLoadingAndroid && Date() < deadline2 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
                check("能进入安卓子目录",
                  model.currentDirectory?.path == sub.path,
                  model.currentDirectory?.path ?? "无")
            check("子目录有内容或为空但无报错",
                  model.errorMessage == nil, model.errorMessage ?? "无错误")
        }

        // 上级目录：路径回退（用户报告此处弹系统对话框）
        let parentURL = AndroidURL.make(serial: serial, path: "/storage/emulated")
        let parentEntries = (try? AndroidFileService(serial: serial).list("/storage/emulated")) ?? []
        print("  诊断: /storage/emulated 列出 \(parentEntries.count) 项: \(parentEntries.map { $0.name })")
        check("能列出 /storage/emulated（含 0 与 obb）",
              parentEntries.contains { $0.name == "0" },
              parentEntries.map { $0.name }.joined(separator: "/"))

        model.selectFolder(parentURL)
        let deadline3 = Date().addingTimeInterval(25)
        while model.isLoadingAndroid && Date() < deadline3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        print("  诊断: 回退后 items=\(model.items.count) 错误=\(model.errorMessage ?? "无")")
        check("回退到上级目录后能列出内容", !model.items.isEmpty, "\(model.items.count) 项")
        check("回退后没有报错", model.errorMessage == nil, model.errorMessage ?? "无")

        // 从上级再回退（/storage）：不应崩溃或误报
        model.selectFolder(AndroidURL.make(serial: serial, path: "/storage"))
        let deadline4 = Date().addingTimeInterval(25)
        while model.isLoadingAndroid && Date() < deadline4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        print("  诊断: /storage items=\(model.items.count) 错误=\(model.errorMessage ?? "无")")
        check("回退到 /storage 不报错", model.errorMessage == nil, model.errorMessage ?? "无")

        // 回到存储根，继续后续断言
        model.selectFolder(dirURL)
        let deadline5 = Date().addingTimeInterval(25)
        while model.isLoadingAndroid && Date() < deadline5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        // 选中项与安卓条目对应
        if let first = model.items.first {
            model.selectedIDs = [first.id]
            check("选中项能映射回安卓条目",
                  model.selectedAndroidEntries.count == 1,
                  "\(model.selectedAndroidEntries.count) 项")
        }

        // 复制到剪贴板：安卓条目应记录到安卓剪贴板而非系统剪贴板
        if let first = model.items.first {
            model.selectedIDs = [first.id]
            model.copySelectionToClipboard()
            check("安卓复制记录到安卓剪贴板", model.androidClipboard != nil)
            check("安卓复制不写入本机剪贴板", model.clipboard == nil)
        }

        // 安卓上的文件不能直接打开，应给出提示
        if let file = model.androidEntries.first(where: { !$0.isDirectory }) {
            model.errorMessage = nil
            model.activateAndroid(file)
            check("安卓文件提示需先下载", model.errorMessage != nil,
                  model.errorMessage ?? "无提示")

            // 通过 activate 走同一保护（不得交给 NSWorkspace，否则会弹出系统"未设定打开方式"对话框）
            model.errorMessage = nil
            let item = file.asFileItem()
            model.activate(item)
            check("activate 对安卓文件同样只给提示（不调用 NSWorkspace）",
                  model.errorMessage != nil, model.errorMessage ?? "无提示")
        }

        // 在访达中显示：安卓条目应提示而非报错
        if let first = model.items.first {
            model.selectedIDs = [first.id]
            model.errorMessage = nil
            model.revealSelection()
            check("安卓条目「在访达中显示」给出提示", model.errorMessage != nil,
                  model.errorMessage ?? "无提示")
        }

        // 图标：安卓条目的分类应能提供符号图标（不再依赖 NSWorkspace）
        if let video = model.androidEntries.first(where: {
            $0.name.lowercased().hasSuffix(".mp4") || $0.name.lowercased().hasSuffix(".mov")
        }) {
            let item = video.asFileItem()
            check("安卓视频被归入视频分类", item.category == .video, item.category.rawValue)
            check("安卓视频有可用的符号图标", !item.category.symbol.isEmpty, item.category.symbol)
        }
        if let folder = model.androidEntries.first(where: { $0.isDirectory }) {
            let item = folder.asFileItem()
            check("安卓文件夹是容器（用于取文件夹图标）", item.isContainer)
        }
    }

    // MARK: - 右键行区域判定

    @MainActor
    static func testRowAreaRightClick() {
        print("\n[右键行区域判定]")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = root

        let scroll = NSScrollView(frame: NSRect(x: 220, y: 0, width: 680, height: 600))
        let table = NSTableView(frame: scroll.bounds)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        table.headerView = nil
        table.rowHeight = 24
        scroll.documentView = table
        root.addSubview(scroll)

        let source = StubTableSource(rows: 5)
        table.dataSource = source
        table.delegate = source
        table.reloadData()

        /// 构造一个位于窗口某点的右键事件
        func event(at pointInWindow: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: .rightMouseDown, location: pointInWindow,
                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 1, clickCount: 1, pressure: 1)
        }

        // 第 0 行的中心（表格坐标）→ 转换到窗口坐标
        let row0Center = table.convert(NSPoint(x: 100, y: table.rect(ofRow: 0).midY), to: nil)
        let belowRows = table.convert(NSPoint(x: 100, y: table.rect(ofRow: 4).maxY + 60), to: nil)

        if let e = event(at: row0Center) {
            EmptyAreaContextMenu.InstallerView.currentEvent = e
            let onRow = EmptyAreaContextMenu.InstallerView.classify(table, in: scroll)
            check("右键落在行上 → 判定为行内（交给系统的文件菜单）", onRow, "应含重命名/打开方式")
            EmptyAreaContextMenu.InstallerView.currentEvent = nil
        } else {
            check("构造右键事件", false)
        }

        if let e = event(at: belowRows) {
            EmptyAreaContextMenu.InstallerView.currentEvent = e
            let onBlank = EmptyAreaContextMenu.InstallerView.classify(table, in: scroll)
            check("右键落在行下方空白 → 判定为空白（背景菜单）", !onBlank)
            EmptyAreaContextMenu.InstallerView.currentEvent = nil
        }

        // 图标视图：有磁贴标记时，按磁贴矩形判断
        let tileHost = NSScrollView(frame: NSRect(x: 220, y: 0, width: 680, height: 600))
        let tileDoc = NSView(frame: tileHost.bounds)
        tileHost.documentView = tileDoc
        root.addSubview(tileHost)

        let tile = FileTileMarkerView(frame: NSRect(x: 100, y: 400, width: 120, height: 100))
        tile.item = FileItem(url: URL(fileURLWithPath: "/tmp/某文件夹"), resourceKeys: [], showHidden: false)
        tileDoc.addSubview(tile)

        // 用磁贴在窗口中的真实中心作为点击点（事件坐标是窗口坐标）
        let tileRectInWindow = tile.convert(tile.bounds, to: nil)
        if let e = event(at: NSPoint(x: tileRectInWindow.midX, y: tileRectInWindow.midY)) {
            EmptyAreaContextMenu.InstallerView.currentEvent = e
            check("图标视图：右键落在磁贴上 → 交给磁贴菜单",
                  EmptyAreaContextMenu.InstallerView.classify(tileDoc, in: tileHost))
            EmptyAreaContextMenu.InstallerView.currentEvent = nil
        }

        // 磁贴之外的空白（内容区右侧）
        if let e = event(at: NSPoint(x: 700, y: 300)) {
            EmptyAreaContextMenu.InstallerView.currentEvent = e
            check("图标视图：右键落在空白 → 弹背景菜单",
                  !EmptyAreaContextMenu.InstallerView.classify(tileDoc, in: tileHost))
            EmptyAreaContextMenu.InstallerView.currentEvent = nil
        }

        // 行区域边界：最后一行之内算行内
        if let e = event(at: table.convert(NSPoint(x: 100, y: table.rect(ofRow: 4).midY), to: nil)) {
            EmptyAreaContextMenu.InstallerView.currentEvent = e
            check("最后一行之上仍算行内",
                  EmptyAreaContextMenu.InstallerView.classify(table, in: scroll))
            EmptyAreaContextMenu.InstallerView.currentEvent = nil
        }
    }

    // MARK: - 新建页签后的可用性

    @MainActor
    static func testNewTabUsable() throws {
        print("\n[新建页签后可用性]")

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("winfile-newtab-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("甲.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: dir) }

        let manager = TabManager(engine: FSEngine(), startDirectory: nil)
        let first = manager.activeTab

        // 新建页签（与菜单 ⌘T 同一路径）
        let second = manager.newTab()
        check("新建页签后活动页签已切换", manager.activeTab.id == second.id)
        check("活动模型随之指向新页签", manager.activeModel === second.model)

        // 新建后立刻"点击"（导航）——用户报告此处无反应
        manager.activeModel.selectFolder(dir)
        check("新建页签后立即可导航",
              manager.activeModel.currentDirectory?.path == dir.path,
              manager.activeModel.currentDirectory?.path ?? "无")

        // 新页签的导航不应影响旧页签
        check("旧页签仍保持自己的位置", first.model.currentDirectory == nil,
              first.model.currentDirectory?.path ?? "（仍为主页）")

        // 再连续新建，仍应立即可用
        let third = manager.newTab()
        manager.activeModel.selectFolder(dir)
        check("连续新建后仍立即可导航",
              manager.activeModel.currentDirectory?.path == dir.path,
              manager.activeModel.currentDirectory?.path ?? "无")
        check("第三个页签即为活动页签", manager.activeTab.id == third.id)

        // 切换回来后依然可用
        manager.select(first)
        manager.activeModel.navigate(to: .thisPC)
        manager.select(third)
        check("来回切换后模型仍正确",
              manager.activeModel === third.model && third.model.currentDirectory?.path == dir.path,
              manager.activeModel.currentDirectory?.path ?? "无")
    }

    // MARK: - 图标视图双击的查找逻辑

    @MainActor
    static func testTileMarkerLookup() {
        print("\n[图标视图双击查找]")

        let item = FileItem(url: URL(fileURLWithPath: "/tmp/示例文件夹"),
                            resourceKeys: [], showHidden: false)
        check("测试项目构造成功", item != nil)

        let marker = FileTileMarkerView(frame: NSRect(x: 0, y: 0, width: 0, height: 0))
        marker.item = item
        var activated = false
        marker.onActivate = { activated = true }

        // 模拟真实层级：容器 → 磁贴内容 → 具体子视图（命中的通常是子视图）
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let tileContent = NSView(frame: NSRect(x: 10, y: 10, width: 100, height: 100))
        let deepChild = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        container.addSubview(marker)
        marker.addSubview(tileContent)
        tileContent.addSubview(deepChild)

        let find = EmptyAreaContextMenu.InstallerView.findTileMarker(from:)

        check("从深层子视图能找到磁贴标记", find(deepChild) === marker)
        check("从磁贴内容能找到磁贴标记", find(tileContent) === marker)
        check("从标记自身能找到自己", find(marker) === marker)
        check("无关视图找不到标记", find(NSView()) == nil)

        // 取出项目并触发打开
        if let found = find(deepChild), let foundItem = found.item {
            check("能取回正确的项目", foundItem.url.lastPathComponent == "示例文件夹",
                  foundItem.url.lastPathComponent)
            found.onActivate?()
            check("能触发打开动作", activated)
        } else {
            check("能取回正确的项目", false, "未取到")
        }
    }

    // MARK: - 双击打开机制

    @MainActor
    static func testDoubleClickMechanism() {
        print("\n[双击打开机制]")

        // 构造一个真实窗口 + 表格，验证 doubleAction 链路本身
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        window.contentView = root

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let table = NSTableView(frame: scroll.bounds)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        table.headerView = nil
        scroll.documentView = table
        root.addSubview(scroll)

        // 真实数据源：没有行就无法选中，也就无法验证行号
        let source = StubTableSource(rows: 5)
        table.dataSource = source
        table.delegate = source
        table.reloadData()

        var received: [Int] = []
        TableDiagnostics.installDoubleClick(on: table) { row in received.append(row) }
        check("安装双击后表格有 doubleAction", table.doubleAction != nil)
        check("安装双击后表格有 target", table.target != nil)

        // 模拟 AppKit 触发双击（这一步等价于用户双击某行）
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        if let action = table.doubleAction {
            _ = table.target?.perform(action, with: table)
        }
        check("双击回调被触发", !received.isEmpty, "收到 \(received.count) 次")
        check("双击回调拿到正确行号", received.first == 2, "\(received)")

        // 未选中任何行时不应崩溃，且回退为 -1 之外的有效处理
        table.deselectAll(nil)
        if let action = table.doubleAction {
            _ = table.target?.perform(action, with: table)
        }
        check("无选中行时双击不崩溃", received.count == 2, "\(received)")
    }

    // MARK: - 应用数据

    @MainActor
    static func testAppData() {
        print("\n[应用数据]")

        let items = AppDataService.scan()
        if items.isEmpty {
            print("  未能扫出应用数据目录（环境限制），跳过相关断言")
            return
        }
        let granted = AppDataService.hasSufficientAccess(items)
        print("  权限是否足够: \(granted ? "是" : "否")")
        check("能扫出应用数据目录", !items.isEmpty, "\(items.count) 个")
        check("列表无重复", Set(items.map(\.id)).count == items.count, "\(items.count)")

        // 条目字段完整性
        let wellFormed = items.allSatisfy { !$0.name.isEmpty && !$0.bundleID.isEmpty }
        check("每个条目都有名称与标识", wellFormed)

        // 目录必须真实存在
        let existing = items.filter { FileManager.default.fileExists(atPath: $0.dataURL.path) }
        check("所有条目的目录真实存在", existing.count == items.count,
              "\(existing.count)/\(items.count)")

        // 可读性统计（未授权时多数不可读，属正常）
        let readable = items.filter { $0.isReadable }
        print("  可读 \(readable.count) / 共 \(items.count)")
        if granted {
            check("权限足够时应能读出可浏览的目录", !readable.isEmpty, "\(readable.count)")
        } else {
            // 沙盒形态下这是预期结果：系统禁止读取其它应用数据
            print("  沙盒/未授权形态：可浏览 \(readable.count) 个（该功能在此形态下不可用，符合预期）")
        }

        // 应用名解析：能定位到 .app 的条目应拿到真实名称（而非 Bundle 标识）
        let withApp = items.filter { $0.appURL != nil }
        let resolvedNames = withApp.filter { $0.name != $0.bundleID }
        check("能解析出应用显示名", withApp.isEmpty || !resolvedNames.isEmpty,
              "\(resolvedNames.count)/\(withApp.count)")

        // 容器条目应带有 Data 目录
        let containers = items.filter { $0.isContainer }
        let validContainers = containers.filter { $0.dataURL.lastPathComponent == "Data" }
        check("容器条目的路径以 Data 结尾", containers.isEmpty || validContainers.count == containers.count,
              "\(validContainers.count)/\(containers.count)")

        // UUID 容器：空壳应被过滤，有内容的应被推断出应用名
        let uuidItems = items.filter { AppDataService.isUUID($0.bundleID) }
        check("UUID 空壳容器已被过滤（有内容的仍保留且已改名）",
              uuidItems.allSatisfy { $0.originalBundleID == nil || !AppDataService.isUUID($0.bundleID) },
              uuidItems.prefix(3).map(\.bundleID).joined(separator: "/"))

        // 推断出的名称必须来自真实线索
        let inferred = items.filter { $0.originalBundleID != nil }
        print("  由内容推断出应用名的容器: \(inferred.count) 个")
        for entry in inferred.prefix(4) {
            print("    \(entry.originalBundleID?.prefix(8) ?? "")… → \(entry.name)（\(entry.bundleID)）")
        }
        check("推断出的名称不是 UUID 形式",
              inferred.allSatisfy { !AppDataService.isUUID($0.name) },
              inferred.prefix(2).map(\.name).joined(separator: "/"))
        check("推断后仍保留原容器编号",
              inferred.allSatisfy { $0.originalBundleID != nil })

        // 线索识别逻辑
        check("能识别 Bundle 标识", AppDataService.looksLikeBundleID("com.tencent.weread"))
        check("拒绝纯版本号", !AppDataService.looksLikeBundleID("10.2.0.85"))
        check("拒绝过短的标识", !AppDataService.looksLikeBundleID("a.b"))

        // 反向验证：显式包含时应当能看到它们（说明过滤而非消失）
        let withShells = AppDataService.scan(includeEmptyShells: true)
        let shellsWhenIncluded = withShells.filter { AppDataService.isUUID($0.bundleID) }
        print("  包含空壳时条目数 \(withShells.count)，其中 UUID 容器 \(shellsWhenIncluded.count) 个")
        check("显式包含时能看到空壳容器（证明是过滤而非丢失）",
              shellsWhenIncluded.isEmpty || withShells.count > items.count,
              "\(items.count) vs \(withShells.count)")

        // UUID 判定本身的正确性
        check("UUID 判定：标准形式为真",
              AppDataService.isUUID("10BBAC01-58F1-42ED-B12D-389DD631825C"))
        check("UUID 判定：应用标识为假",
              !AppDataService.isUUID("com.tencent.xinWeChat"))
        check("UUID 判定：长度不符为假",
              !AppDataService.isUUID("10BBAC01-58F1-42ED-B12D-389DD631825"))
        check("UUID 判定：非十六进制为假",
              !AppDataService.isUUID("10BBAC0Z-58F1-42ED-B12D-389DD631825C"))

        // 有内容的容器不得被误判为空壳（误删数据的风险点）
        if let wechat = items.first(where: { $0.bundleID == "com.tencent.xinWeChat" }) {
            check("有内容的应用容器不被判为空壳",
                  !AppDataService.isEmptyShell(bundleID: wechat.bundleID, dataURL: wechat.dataURL))
        }
        // 有应用标识的容器一律不算空壳
        if let named = items.first(where: { !AppDataService.isUUID($0.bundleID) }) {
            check("有标识的容器不被判为空壳",
                  !AppDataService.isEmptyShell(bundleID: named.bundleID, dataURL: named.dataURL),
                  named.bundleID)
        }

        // 常见应用（若已安装）应被识别出中文名
        if let wechat = items.first(where: { $0.bundleID == "com.tencent.xinWeChat" }) {
            check("微信被识别", wechat.name == "微信", wechat.name)
        } else {
            print("  （未安装微信，跳过）")
        }
    }

    // MARK: - 排序

    @MainActor
    static func testSorting(_ sandbox: URL) throws {
        print("\n[排序]")
        let fm = FileManager.default
        let dir = sandbox.appendingPathComponent("排序测试")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 刻意造出：名称顺序与大小、日期顺序都不一致
        let files: [(String, Int)] = [("bbb.txt", 300), ("aaa.txt", 100), ("ccc.txt", 200)]
        for (name, size) in files {
            try String(repeating: "x", count: size).write(to: dir.appendingPathComponent(name),
                                                          atomically: true, encoding: .utf8)
        }
        try fm.createDirectory(at: dir.appendingPathComponent("zzz-文件夹"), withIntermediateDirectories: true)

        let model = BrowserModel(engine: FSEngine(), startDirectory: dir)
        model.selectFolder(dir)
        waitFor { !model.items.isEmpty }
        let names = model.items.map(\.name)
        check("目录已载入", !names.isEmpty, "\(names)")

        model.sortField = .name
        model.sortAscendingFlag = true
        let byNameAsc = model.items.map(\.name)
        // 文件夹恒在前（与 Windows 一致），文件之间按名称升序
        check("名称升序：文件夹在前", byNameAsc.first?.hasPrefix("zzz") == true, "\(byNameAsc)")
        let filesAsc = model.items.filter { !$0.isDirectory }.map(\.name)
        check("名称升序：文件按名称排列", filesAsc == ["aaa.txt", "bbb.txt", "ccc.txt"], "\(filesAsc)")

        model.sortAscendingFlag = false
        let filesDesc = model.items.filter { !$0.isDirectory }.map(\.name)
        check("名称降序与升序相反", filesDesc == ["ccc.txt", "bbb.txt", "aaa.txt"], "\(filesDesc)")

        model.sortField = .size
        model.sortAscendingFlag = true
        let bySize = model.items.filter { !$0.isDirectory }.map(\.name)
        check("按大小升序", bySize == ["aaa.txt", "ccc.txt", "bbb.txt"], "\(bySize)")

        model.sortAscendingFlag = false
        let bySizeDesc = model.items.filter { !$0.isDirectory }.map(\.name)
        check("按大小降序", bySizeDesc == ["bbb.txt", "ccc.txt", "aaa.txt"], "\(bySizeDesc)")

        model.sortField = .modified
        let byDate = model.items.map(\.name)
        check("按修改日期排序项目数不变", byDate.count == names.count, "\(byDate.count)")

        model.sortField = .type
        let byType = model.items.map(\.name)
        check("按类型排序项目数不变", byType.count == names.count, "\(byType.count)")

        // 关键：排序后 UI 依赖的 displayedItems 必须同步变化
        check("displayedItems 跟随排序", model.displayedItems.map(\.name) == model.items.map(\.name),
              "\(model.displayedItems.count) 项")

    }

    @MainActor
    static func testTabManager(_ sandbox: URL) throws {
        print("\n[页签管理]")
        let fm = FileManager.default
        let engine = FSEngine()

        // 准备两个目录，用于验证页签各自独立
        let dirA = sandbox.appendingPathComponent("页签A")
        let dirB = sandbox.appendingPathComponent("页签B")
        try fm.createDirectory(at: dirA, withIntermediateDirectories: true)
        try fm.createDirectory(at: dirB, withIntermediateDirectories: true)
        try "a".write(to: dirA.appendingPathComponent("甲.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: dirB.appendingPathComponent("乙.txt"), atomically: true, encoding: .utf8)
        try "b2".write(to: dirB.appendingPathComponent("丙.txt"), atomically: true, encoding: .utf8)

        let manager = TabManager(engine: engine, startDirectory: dirA)
        check("初始只有一个页签", manager.count == 1, "\(manager.count)")
        check("初始页签指向起始目录",
              manager.activeModel.currentDirectory?.path == dirA.path,
              manager.activeModel.currentDirectory?.path ?? "无")

        // 新页签：默认进入主页
        let second = manager.newTab()
        check("可新建页签", manager.count == 2, "\(manager.count)")
        check("新页签成为活动页签", manager.activeTab.id == second.id)
        check("新页签默认进入主页", second.model.isHomeView)
        check("新页签标题为主页", second.title == L("view.home", "主页"), second.title)

        // 新页签指向指定目录
        let third = manager.newTab(startDirectory: dirB)
        check("可在指定目录开新页签", manager.count == 3)
        check("指定目录的页签标题为目录名", third.title == "页签B", third.title)

        // 各页签状态互相独立
        let firstTab = manager.tabs[0]
        check("切换页签不影响其它页签的目录",
              firstTab.model.currentDirectory?.path == dirA.path,
              firstTab.model.currentDirectory?.path ?? "无")

        // 选择与切换
        manager.select(firstTab)
        check("可切换活动页签", manager.activeTab.id == firstTab.id)
        check("切换后模型随之更新",
              manager.activeModel.currentDirectory?.path == dirA.path,
              manager.activeModel.currentDirectory?.path ?? "无")
        manager.select(index: 2)
        check("可按序号切换页签", manager.activeTab.id == third.id)

        // 复制页签
        let copy = manager.duplicate(third)
        check("复制页签继承当前目录",
              copy.model.currentDirectory?.path == dirB.path,
              copy.model.currentDirectory?.path ?? "无")
        check("复制后页签数增加", manager.count == 4, "\(manager.count)")

        // 关闭
        manager.close(copy)
        check("可关闭页签", manager.count == 3, "\(manager.count)")
        check("关闭后活动页签有效", manager.tabs.contains { $0.id == manager.activeTab.id })

        manager.closeOthers(keeping: third)
        check("可关闭其它页签", manager.count == 1 && manager.activeTab.id == third.id)

        // 只剩一个时不可关闭，且会自动补位
        check("仅剩一个页签时不可关闭", !manager.canCloseActive)
        manager.closeActive()
        check("关闭最后一个页签无副作用", manager.count == 1)

        let replacement = manager.close(manager.activeTab)
        _ = replacement
        check("关掉最后一个会自动补一个新页签", manager.count == 1, "\(manager.count)")
        check("补位页签可正常使用", manager.activeModel.currentDirectory != nil
              || manager.activeModel.isHomeView)

        // 多页签时逐个关闭
        let manager2 = TabManager(engine: engine, startDirectory: dirA)
        manager2.newTab(startDirectory: dirB)
        manager2.newTab(startDirectory: dirA)
        check("连续新建页签", manager2.count == 3, "\(manager2.count)")
        manager2.closeAll()
        check("关闭全部后保留一个页签", manager2.count == 1, "\(manager2.count)")

        // 页签图标随视图类型变化
        let homeTab = manager2.newTab()
        check("主页页签图标为房子", homeTab.symbol == "house.fill", homeTab.symbol)
        manager2.activeModel.navigate(to: .thisPC)
        check("此电脑页签图标为电脑", manager2.activeTab.symbol == "pc", manager2.activeTab.symbol)
    }

    @MainActor
    static func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    @MainActor
    private static func item(_ url: URL) -> FileItem {
        FileItem(url: url, resourceKeys: FileSystemService.resourceKeys, showHidden: true)!
    }
}
