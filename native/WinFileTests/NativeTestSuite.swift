// WinFile 逻辑层测试套件
// 运行方式一（推荐，带完整 bundle 环境）：
//     WinFile.app/Contents/MacOS/WinFile --run-tests
// 运行方式二（命令行，快速迭代）：
//     ./native/run_native_tests.sh
import AppKit
import Combine
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

        // Test-only operations must not replace the user's preferences or clipboard on exit.
        let defaults = UserDefaults.standard
        let preferenceKeys = ["StartFolderPath", "ViewLayout", "ShowHiddenFiles", "SortField", "SortAscending",
                              "AddedFolderPaths", "FavoritesSeeded", "PinnedFolders", "RecentlyOpenedFiles",
                              "SidebarHiddenCategories", "SidebarCategoryOrder", "ShowsDefaultAppBadge"]
        let preferences = Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        let pb = NSPasteboard.general
        let clipboard = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            for key in preferenceKeys {
                if let value = preferences[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            pb.clearContents()
            pb.writeObjects(clipboard.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }

        print("== WinFile 逻辑层测试 ==")
        print("沙盒目录：\(sandbox.path)")

        testCategorization()
        do {
            try testListing(sandbox)
            try testOperations(sandbox)
            try testCategoryView(sandbox)
            try testHomeAndThisPC(sandbox)
            try testSidebarQuickAdd(sandbox)
            try testFolderPickerAndDrop(sandbox)
            try testUpdatePolicy(sandbox)
            testEmptyAreaClassification()
            try testTabManager(sandbox)
            try testSorting(sandbox)
            testAppData()
            testDoubleClickMechanism()
            testMouseEventSafety()
            testTileMarkerLookup()
            try testNewTabUsable()
            testRowAreaRightClick()
            testAndroidParsing()
            testAndroidDevice()
            testAndroidBrowsing()
            testCustomPagesNotReportedEmpty()
            try testArchive()
            try testExpandedArchives(sandbox)
            try testSelectAllConsistency()
            testTileLayoutUniformity()
            try testCategoryViewIntegrity()
            testGridRowPartition()
            testRealCategoryDuplicates()
            try testOpenContainingFolder()
            testThumbnailScope()
            try testFileAssociations()
            try testDefaultAppBadge()
            testSidebarCategories()
            try testLanguageSelection()
            try testStorageCleanup(sandbox)
            try testBaiduDownloads(sandbox)
            try testCleanupSources(sandbox)
            try testGeneralWeChatAttachments(sandbox)
            try testWeChatCleanup(sandbox)
            try testWeChatFileActions(sandbox)
            try testWeChatPagination(sandbox)
            testFileErrorDiagnostics()
            try testSymbolicLinkBrowsing(sandbox)
            try testNativeSearch(sandbox)
            try testFunctionalImprovements(sandbox)
            try testExperienceImprovements(sandbox)
            try testLayoutAndFilterExperience(sandbox)
            try testRemainingImprovements(sandbox)
            try testMemoryAndPickerImprovements(sandbox)
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

    @MainActor
    private static func testFileErrorDiagnostics() {
        print("\n== 文件错误诊断 ==")
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 20,
                                 userInfo: [NSLocalizedDescriptionKey: "Not a directory"])
        let error = NSError(domain: NSCocoaErrorDomain, code: 256,
                            userInfo: [NSLocalizedDescriptionKey: "Cannot open\nOrbStack", NSUnderlyingErrorKey: underlying,
                                       "unrelated": "private-value-must-not-be-logged"])
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("OrbStack")
        let detail = TabDiagnostics.fileErrorDetail(error, operation: "listDirectory", url: url)
        check("文件错误日志保留操作、路径和完整底层错误码", detail.contains("operation=listDirectory") && detail.contains("path=~/OrbStack") && detail.contains("NSCocoaErrorDomain code=256") && detail.contains("NSPOSIXErrorDomain code=20"))
        check("文件错误不会注入额外日志行", !detail.contains("\n") && detail.contains("Cannot open\\nOrbStack"))
        check("文件错误不导出任意 userInfo 数据", !detail.contains("private-value-must-not-be-logged"))
        var nested = underlying
        for _ in 0..<12 { nested = NSError(domain: "nested", code: 1, userInfo: [NSUnderlyingErrorKey: nested]) }
        let bounded = TabDiagnostics.fileErrorDetail(nested, operation: "listDirectory", url: url)
        check("文件错误链有固定深度上限", bounded.contains("error[7]") && !bounded.contains("error[8]"))
    }

    @MainActor
    private static func testSymbolicLinkBrowsing(_ sandbox: URL) throws {
        print("\n== 符号链接导航、条目标识与会话恢复 ==")
        let fm = FileManager.default
        let root = sandbox.resolvingSymlinksInPath().appendingPathComponent("SymlinkBrowsing")
        let target = root.appendingPathComponent("Target")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let sample = target.appendingPathComponent("sample.txt")
        try Data("symlink sample".utf8).write(to: sample)
        let link = root.appendingPathComponent("Directory Link")
        let fileLink = root.appendingPathComponent("File Link")
        let broken = root.appendingPathComponent("Broken Link")
        let relative = root.appendingPathComponent("Relative Link")
        let chained = root.appendingPathComponent("Chained Link")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        try fm.createSymbolicLink(at: fileLink, withDestinationURL: sample)
        try fm.createSymbolicLink(at: broken, withDestinationURL: root.appendingPathComponent("Missing"))
        try fm.createSymbolicLink(atPath: relative.path, withDestinationPath: "Target")
        try fm.createSymbolicLink(at: chained, withDestinationURL: relative)
        let loop = target.appendingPathComponent("loop")
        try fm.createSymbolicLink(at: loop, withDestinationURL: target)
        let cyclic = root.appendingPathComponent("Cyclic")
        try fm.createSymbolicLink(atPath: cyclic.path, withDestinationPath: "Cyclic")
        let app = root.appendingPathComponent("Demo.app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let appLink = root.appendingPathComponent("App Link")
        try fm.createSymbolicLink(at: appLink, withDestinationURL: app)
        let listed = try FileSystemService.list(root, showHidden: true)
        func item(_ name: String) throws -> FileItem {
            guard let result = listed.first(where: { $0.name == name }) else { throw FSError.notFound(root.appendingPathComponent(name)) }
            return result
        }
        let directoryItem = try item("Directory Link")
        let targetItem = try item("Target")
        let fileItem = try item("File Link")
        let brokenItem = try item("Broken Link")
        check("目录链接保留链接元数据且可作为文件夹浏览", directoryItem.isDirectory && directoryItem.isSymlink && directoryItem.category == .folder)
        check("链接与同级目标拥有不同的列表 ID", directoryItem.id != targetItem.id && Set(listed.map(\.id)).count == listed.count)
        check("正常与失效链接均保留原来的条目名称", listed.contains { $0.name == "Directory Link" } && listed.contains { $0.name == "Broken Link" })
        let aliasRoot = root.appendingPathComponent("Parent Alias")
        try fm.createSymbolicLink(at: aliasRoot, withDestinationURL: root)
        check("父目录路径别名不改变普通文件身份", FileItem.canonicalID(for: aliasRoot.appendingPathComponent("Target/sample.txt")) == FileItem.canonicalID(for: sample))
        check("父目录路径别名不改变链接条目身份", FileItem.canonicalID(for: aliasRoot.appendingPathComponent("Directory Link")) == directoryItem.id)
        check("链接自身仍保留为复制和改名的源 URL", directoryItem.url.lastPathComponent == "Directory Link" && fileItem.url.lastPathComponent == "File Link")
        check("文件链接按真实目标解析打开类型", try fileItem.resolvedForOpening().url == sample && !fileItem.isDirectory)
        let appItem = try item("App Link").resolvedForOpening()
        check("应用链接解析后保持应用包而非普通目录", appItem.url.path == app.path && appItem.isBundle && !appItem.isBrowsableFolder)
        for name in ["Broken Link", "Cyclic"] {
            do { _ = try item(name).resolvedForOpening(); check("\(name) 应拒绝打开", false) }
            catch FSError.unavailableSymlink { check("\(name) 给出链接目标不可用错误", true) }
            catch { check("\(name) 错误类型正确", false, error.localizedDescription) }
        }
        for entry in [link, relative, chained] {
            let listing = try FileSystemService.directoryListing(entry, showHidden: true)
            check("目录链接导航成功：\(entry.lastPathComponent)", listing.directory.path == target.path && listing.items.contains { $0.name == "sample.txt" })
        }
        do { _ = try FileSystemService.list(broken, showHidden: true); check("失效目录链接应拒绝列目录", false) }
        catch FSError.unavailableSymlink { check("地址栏失效目录链接给出明确提示", true) }
        let scan = FileSystemService.searchReport(under: link, matching: "sample")
        check("显式链接搜索范围可扫描目标且不沿子链接循环", scan.items.map(\.name) == ["sample.txt"] && scan.visited < 10 && !scan.isPartial)
        let picker = FolderPickerModel(initialDirectory: root)
        func waitUntil(_ done: () -> Bool) {
            let deadline = Date().addingTimeInterval(8)
            while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }
        picker.navigate(to: relative); waitUntil { !picker.isLoading }
        check("应用内目录选择器可进入相对链接并更新真实路径", picker.errorMessage == nil && picker.directory.path == target.path && picker.pathText == target.path)
        picker.cancelLoading()
        let engine = FSEngine(); engine.restrictScopeForTesting([root])
        let model = BrowserModel(engine: engine, startDirectory: link)
        waitUntil { !model.isBusy }
        check("启动目录为符号链接时正常显示内容", model.errorMessage == nil && model.currentDirectory?.path == target.path && model.items.contains { $0.name == "sample.txt" })
        check("地址栏与导航选择同步为真实目标", { if case .folder(let directory) = model.selection { return directory.path == target.path }; return false }())
        let saved = SavedBrowserTab(model: model)
        check("会话保存真实目录路径防止启动重复报错", saved.path == target.path)
        var legacy = saved; legacy.path = chained.path
        let restored = BrowserModel(engine: engine, startDirectory: nil)
        legacy.apply(to: restored); waitUntil { !restored.isBusy }
        check("旧会话中的链接路径也能恢复", restored.errorMessage == nil && restored.currentDirectory?.path == target.path && restored.items.contains { $0.name == "sample.txt" })
        restored.selectFolder(root); waitUntil { !restored.isBusy }
        restored.activate(directoryItem); waitUntil { !restored.isBusy }
        check("双击目录链接在当前 WinFile 模型内进入", restored.errorMessage == nil && restored.currentDirectory?.path == target.path && restored.items.contains { $0.name == "sample.txt" })
        restored.activate(brokenItem)
        check("失效链接提示错误且保留当前浏览目录", restored.errorMessage == FSError.unavailableSymlink(broken).localizedDescription && restored.currentDirectory?.path == target.path && !restored.isBusy)
        restored.selectFolder(relative); waitUntil { !restored.isBusy }
        check("再次成功导航清除旧错误", restored.errorMessage == nil && restored.currentDirectory?.path == target.path)
        restored.beginWatchingDirectory()
        try Data("new".utf8).write(to: target.appendingPathComponent("new.txt"))
        waitUntil { restored.items.contains { $0.name == "new.txt" } }
        check("链接导航后监听真实目录的新增文件", restored.items.contains { $0.name == "new.txt" })
        let manager = TabManager(engine: engine, startDirectory: root)
        waitUntil { !manager.activeModel.isBusy }
        manager.activeModel.openContainingFolder(of: link)
        waitUntil { !manager.activeModel.isBusy }
        check("新页签定位链接时只选中链接本身", manager.activeModel.selectedItems.map(\.name) == ["Directory Link"])
        let output = root.appendingPathComponent("Output")
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        let copied = FileTransferService.transfer([directoryItem], to: output, mode: .copy, token: ScanCancellation(), onProgress: { _ in })
        check("复制目录链接仍保留链接而不复制整个目标", copied.failures.isEmpty && (try? fm.destinationOfSymbolicLink(atPath: output.appendingPathComponent("Directory Link").path)) == target.path)
        let legacyCopy = try FSEngine.transfer([directoryItem], to: target, mode: .copy)
        check("旧复制入口不会把目录链接误判为递归复制", legacyCopy.count == 1 && (try? fm.destinationOfSymbolicLink(atPath: legacyCopy[0].path)) == target.path)
        let renamed = try FSEngine.rename(directoryItem, to: "Renamed Link")
        check("重命名链接不会重命名目标目录", fm.fileExists(atPath: target.path) && (try? fm.destinationOfSymbolicLink(atPath: renamed.path)) == target.path && fm.fileExists(atPath: sample.path))
    }

    @MainActor
    private static func testNativeSearch(_ sandbox: URL) throws {
        print("\n== 原生搜索弹窗与筛选 ==")
        let fm = FileManager.default
        let root = sandbox.appendingPathComponent("NativeSearch")
        let folder = root.appendingPathComponent("FolderAlpha")
        let bundle = root.appendingPathComponent("Demo.app")
        for url in [folder, bundle] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        for path in ["TopAlpha.PDF", "FolderAlpha/DeepAlpha.pdf", "Archive.zip", ".hiddenAlpha.pdf", "Demo.app/privateAlpha.pdf"] {
            try Data("sample".utf8).write(to: root.appendingPathComponent(path))
        }
        try fm.createSymbolicLink(at: root.appendingPathComponent("linkedAlpha.pdf"), withDestinationURL: folder.appendingPathComponent("DeepAlpha.pdf"))
        let pdf = FileSearchCriteria(extensions: ["pdf"])
        let recursive = FileSystemService.searchReport(under: root, matching: "", criteria: pdf)
        check("原生搜索按扩展名忽略大小写且不进入应用包或符号链接", Set(recursive.items.map(\.name)) == ["TopAlpha.PDF", "DeepAlpha.pdf"])
        let shallow = FileSystemService.searchReport(under: root, matching: "", criteria: pdf, recursive: false)
        check("不含子文件夹只搜索当前层且不报深度截断", shallow.items.map(\.name) == ["TopAlpha.PDF"] && !shallow.depthLimited)
        let hidden = FileSystemService.searchReport(under: root, matching: "", showHidden: true, criteria: pdf)
        check("原生搜索隐藏文件开关生效", hidden.items.count == 3 && hidden.items.contains { $0.name == ".hiddenAlpha.pdf" })
        let folders = FileSystemService.searchReport(under: root, matching: "Alpha", criteria: FileSearchCriteria(foldersOnly: true))
        check("原生搜索只查文件夹", folders.items.map(\.name) == ["FolderAlpha"])
        let archives = FileSystemService.searchReport(under: root, matching: "", criteria: FileSearchCriteria(category: .archive))
        check("原生搜索只查压缩包分类", archives.items.map(\.name) == ["Archive.zip"])
        let combined = FileSystemService.searchReport(under: root, matching: "Alpha", criteria: FileSearchCriteria(minimumBytes: 7, extensions: ["pdf"]))
        check("原生搜索名称类型与大小同时生效", combined.items.isEmpty)
        check("扩展名输入支持点前缀中文分隔符且去重", FileSearchCriteria.parseExtensions(".PDF，zip; pdf JPG") == ["jpg", "pdf", "zip"])
        let legacy = try JSONDecoder().decode(FileSearchCriteria.self, from: Data("{\"minimumBytes\":1}".utf8))
        check("旧版搜索会话可解码且保留原条件", legacy.minimumBytes == 1 && legacy.foldersOnly == nil && legacy.extensions == nil)
        let roundTrip = try JSONDecoder().decode(FileSearchCriteria.self, from: JSONEncoder().encode(pdf))
        check("新增搜索条件可随会话往返", roundTrip == pdf)
        var visited = 0
        let progress = FileSystemService.searchReport(under: root, matching: "Alpha", progress: { visited = $0 })
        check("搜索进度最终计数与扫描报告一致", visited == progress.visited && visited > 0)
        var calls = 0
        let stopped = FileSystemService.searchReport(under: root, matching: "Alpha", cancelled: { calls += 1; return calls > 4 })
        check("扫描中途取消有明确标志且停止遍历", stopped.cancelled && stopped.visited < progress.visited)
        check("搜索请求拒绝网络地址与空条件", !FileSearchRequest(root: URL(string: "https://example.com")!, query: "x").isValid && !FileSearchRequest(root: root, query: "  ").isValid)
        let many = root.appendingPathComponent("Many")
        try fm.createDirectory(at: many, withIntermediateDirectories: true)
        for i in 0..<450 { try Data().write(to: many.appendingPathComponent("entry-\(i).pdf")) }
        func wait(_ model: FileSearchModel) {
            let deadline = Date().addingTimeInterval(10)
            while model.isSearching && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }
        let model = FileSearchModel()
        let request = FileSearchRequest(root: many, query: "entry-")
        model.search(request); wait(model)
        check("弹窗搜索初始限制且可扩大扫描", !model.isSearching && model.report.items.count == 400 && model.report.limitReached && model.canExpand)
        model.expand(); wait(model)
        check("扩大扫描保留条件并找全结果", model.request == request && model.report.items.count == 450 && !model.report.isPartial)
        model.search(request)
        model.search(FileSearchRequest(root: root, query: "TopAlpha")); wait(model)
        check("连续搜索丢弃上一轮结果与进度", model.report.items.map(\.name) == ["TopAlpha.PDF"] && model.visited < 500)
        model.search(request); model.stop(); wait(model)
        check("弹窗停止扫描并可重新扫描", model.report.cancelled && !model.isSearching && model.canExpand)
        model.search(FileSearchRequest(root: root.appendingPathComponent("missing"), query: "x")); wait(model)
        check("弹窗显示无法读取的范围提示", model.error != nil && model.report.inaccessibleCount == 1)
        model.search(request); model.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        check("关闭弹窗后扫描不回写结果", !model.isSearching && model.report.items.isEmpty && model.visited == 0)
    }

    @MainActor
    private static func testGeneralWeChatAttachments(_ sandbox: URL) throws {
        print("\n[通用清理：微信附件接入与共享扫描边界]")
        let fm = FileManager.default
        let home = sandbox.resolvingSymlinksInPath().appendingPathComponent("GeneralWeChatHome")
        func write(_ path: String) throws -> URL {
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 65, count: 64).write(to: url)
            return url
        }
        let base = "Library/Containers/com.tencent.xinWeChat/Data/"
        let document = try write(base + "Documents/xwechat_files/wxid_test/msg/file/2026-10/recent.pdf")
        let image = try write(base + "Library/Application Support/com.tencent.xinWeChat/FileStorage/Image/photo.dat")
        let common = try write("Documents/xwechat_files/wxid_other/FileStorage/File/archive.zip")
        let publicDatabase = try write("Documents/xwechat_files/wxid_other/db_storage/File/chat-data.bin")
        let unrelated = try write(base + "misc/unrelated.pdf")
        let database = try write(base + "Documents/xwechat_files/wxid_test/db_storage/File/database.bin")
        let sqlite = try write(base + "Documents/xwechat_files/wxid_test/msg/file/chat.sqlite")
        let hidden = try write(base + "Documents/.private/File/hidden.pdf")
        let partial = try write(base + "Documents/xwechat_files/wxid_test/msg/file/pending.tmp")
        let custom = try write("Relocated WeChat/notes.txt")
        let external = try write("External/files/not-wechat.pdf")
        _ = try write("Library/Caches/com.example.Editor/old.cache")
        let container = home.appendingPathComponent(base)
        try fm.createSymbolicLink(at: container.appendingPathComponent("Music"), withDestinationURL: external.deletingLastPathComponent())
        try fm.createSymbolicLink(at: document.deletingLastPathComponent().appendingPathComponent("link.pdf"), withDestinationURL: external)
        let config = StorageCleanupConfiguration(home: home, minimumLargeBytes: 1)
        let scan = StorageCleanupService.scan(config, running: ["com.tencent.WeChat"])
        let attachments = scan.files.filter { $0.rule.kind == .wechatAttachment }
        check("通用扫描包含微信小文件和刚下载附件", attachments.contains { $0.url == document })
        check("通用微信扫描可进入真实容器 Library 子目录", attachments.contains { $0.url == image })
        check("微信公共目录附件优先分类且去重", scan.files.filter { $0.url == common }.count == 1 && scan.files.first { $0.url == common }?.rule.kind == .wechatAttachment)
        check("微信公共目录数据库不会被大文件规则重新收录", !scan.files.contains { $0.url == publicDatabase })
        check("微信运行时仍可查看附件", attachments.count == 3)
        check("微信扫描不扩大到容器的普通杂项", !attachments.contains { $0.url == unrelated || $0.url == external })
        check("通用微信候选跳过数据库、隐藏和未完成文件", !attachments.contains { [database, sqlite, hidden, partial].contains($0.url) || $0.name == "link.pdf" })
        let discovery = WeChatCleanupService.discoverRoots(home: home)
        let specialized = WeChatCleanupService.scan(roots: discovery.roots)
        check("通用微信候选复用专用附件识别规则", attachments.allSatisfy { file in specialized.files.contains { $0.url == file.url } })
        var limited = config; limited.candidateLimit = 1
        let first = StorageCleanupService.scan(limited, running: [])
        check("缓存和网盘文件不会抢占微信首个扫描名额", first.limited && first.files.count == 1 && first.files.first?.rule.kind == .wechatAttachment)
        var single = config; single.kinds = [.wechatAttachment]
        check("可单独扫描微信附件类别", StorageCleanupService.scan(single, running: []).files.count == 3)
        single.weChatFolders = [custom.deletingLastPathComponent()]
        check("通用清理复用已选择的微信目录", StorageCleanupService.scan(single, running: []).files.contains { $0.url == custom })
        single.ignored = [custom.deletingLastPathComponent()]
        check("忽略规则也约束自选微信目录", !StorageCleanupService.scan(single, running: []).files.contains { $0.url == custom })
        single.ignored = []
        single.weChatFolders = [home.appendingPathComponent("missing")]
        check("失效的自选微信目录明确报告不可读", StorageCleanupService.scan(single, running: []).inaccessible.contains(home.appendingPathComponent("missing").path))
        single.weChatFolders = []; single.entryLimit = 1
        check("微信扫描仍遵守遍历上限", StorageCleanupService.scan(single, running: []).limited)
        check("通用微信扫描可取消", StorageCleanupService.scan(config, running: [], cancelled: { true }).cancelled)
        let candidate = attachments.first { $0.url == document }!
        var moved = false
        let blocked = StorageCleanupService.trash([candidate], config: config, running: { ["com.tencent.WeChat.helper"] }, isOpen: { _ in false }, move: { _ in moved = true; return nil })
        check("清理时识别微信不同 bundle 名和辅助进程", !moved && blocked.removed.isEmpty && blocked.failures.count == 1)
        let occupied = StorageCleanupService.trash([candidate], config: config, running: { [] }, isOpen: { _ in true }, move: { _ in moved = true; return nil })
        check("通用微信清理跳过被占用的文件", !moved && occupied.removed.isEmpty)
        let domain = "WinFile.GeneralWeChatTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set([custom.deletingLastPathComponent().path], forKey: WeChatCleanupService.customRootsPreferenceKey)
        let model = StorageCleanupModel(home: home, defaults: defaults)
        check("通用配置共享微信目录偏好", model.configuration.weChatFolders == [custom.deletingLastPathComponent()])
        model.accept(scan); model.category = StorageCleanupKind.wechatAttachment.rawValue
        check("微信附件支持统一类别筛选且默认不勾选", model.display.filtered.count == 3 && model.selection.isEmpty)
        check("微信来源显示主应用名称", attachments.allSatisfy { model.displayOwner(for: $0) == L("software.wechat", "微信") })
        model.selectAll(); model.requestTrash()
        check("微信附件纳入通用确认清单", model.confirmsTrash && model.pendingFiles.count == 3)
    }

    @MainActor
    private static func testCleanupSources(_ sandbox: URL) throws {
        print("\n[通用清理：应用来源名称与辅助程序归属]")
        let fm = FileManager.default
        let home = sandbox.resolvingSymlinksInPath().appendingPathComponent("CleanupSourceHome")
        func write(_ path: String) throws -> URL {
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 65, count: 64).write(to: url)
            return url
        }
        let main = try write("Library/Caches/com.google.Chrome/main.cache")
        let helper = try write("Library/Caches/com.google.Chrome.helper/child.cache")
        let unknown = try write("Library/Caches/com.winfile-test.unidentified/unknown.cache")
        let unknownHelper = try write("Library/Caches/com.winfile-test.unidentified.LoginHelper/helper.cache")
        let net = try write("Library/Caches/net.winfile-test.unidentified/net.cache")
        let document = try write("Documents/Project/video.mov")
        let scan = StorageCleanupService.scan(StorageCleanupConfiguration(home: home, kinds: [.cache, .largeFile], minimumAgeDays: 0, minimumLargeBytes: 1), running: [])
        let domain = "WinFile.CleanupSourceTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = StorageCleanupModel(home: home, defaults: defaults)
        store.accept(scan)
        check("来源下拉不再展示原始 bundle 标识", !store.owners.map { store.ownerTitle($0) }.contains { AppDataService.looksLikeBundleID($0) })
        check("结果来源列不展示原始 bundle 标识", scan.files.allSatisfy { !AppDataService.looksLikeBundleID(store.displayOwner(for: $0)) })
        check("辅助程序与主应用合并且来源去重", scan.files.filter { $0.url == main || $0.url == helper }.allSatisfy { store.displayOwner(for: $0) == "Google Chrome" } && store.owners.filter { $0 == "Google Chrome" }.count == 1)
        store.owner = "Google Chrome"
        check("主应用筛选包含其辅助程序缓存", Set(store.display.filtered.map(\.url)) == [main, helper])
        store.selectAll(); store.requestTrash()
        store.owner = SoftwareCleanupApp.otherSourceID
        check("切换合并来源仍清空旧选择与确认", store.selection.isEmpty && store.pendingFiles.isEmpty && !store.confirmsTrash)
        check("无法确认归属的来源合并为其他应用", Set(store.display.filtered.map(\.url)) == [unknown, unknownHelper, net])
        check("名称合并不改变真实规则与应用标识", scan.files.first { $0.url == helper }?.rule.bundleID == "com.google.Chrome.helper")
        check("个人目录来源保持原名", scan.files.first { $0.url == document }.map { store.displayOwner(for: $0) } == "Documents")
        let names = ["com.example.Editor": "Editor", "com.example.Editor.helper": "Editor Helper"]
        check("通过已解析的父应用识别辅助程序归属", SoftwareCleanupApp.sourceName(id: "com.example.Editor.helper", fallback: "Editor Helper", resolve: { names[$0] }) == "Editor")
        check("未解析父应用不猜测归属或泄露标识", SoftwareCleanupApp.sourceName(id: "com.example.Missing.helper", fallback: "com.example.Missing.helper", resolve: { _ in nil }) == SoftwareCleanupApp.otherSourceID)
        check("保留已有的可读软件名", SoftwareCleanupApp.sourceName(id: "com.example.Valid", fallback: "Readable App", resolve: { _ in nil }) == "Readable App")
        let originalLanguage = UserDefaults.standard.object(forKey: Localization.preferenceKey)
        defer {
            if let originalLanguage { UserDefaults.standard.set(originalLanguage, forKey: Localization.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: Localization.preferenceKey) }
        }
        UserDefaults.standard.set("en", forKey: Localization.preferenceKey)
        store.rebuild()
        check("切换语言不使其他应用筛选失效", store.display.filtered.count == 3 && store.owner == SoftwareCleanupApp.otherSourceID)
        UserDefaults.standard.set("zh-Hans", forKey: Localization.preferenceKey)
        store.rebuild()
        check("中文来源筛选保持相同文件范围", store.display.filtered.count == 3)
    }

    @MainActor
    private static func testBaiduDownloads(_ sandbox: URL) throws {
        print("\n[百度网盘：下载目录、软件归属与清理保护]")
        let fm = FileManager.default
        let home = sandbox.resolvingSymlinksInPath().appendingPathComponent("BaiduHome")
        func write(_ path: String) throws -> URL {
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 65, count: 64).write(to: url)
            return url
        }
        let document = try write("baidu/Course/Files/notes.pdf")
        let nested = try write("baidu/Course/Downloads/video.mp4")
        let common = try write("Downloads/BaiduNetdisk/资料.zip")
        let cache = try write("Library/Containers/com.baidu.netdisk/Data/Library/Application Support/baidunetdisk/DawnCache/data_0")
        let database = try write("baidu/history.sqlite")
        let partial = try write("baidu/video.mp4.baiduyun.downloading")
        let hidden = try write("baidu/.private/secret.txt")
        let other = try write("Downloads/unrelated.pdf")
        let custom = try write("CustomDownloads/Docs/file.txt")
        try fm.createSymbolicLink(at: home.appendingPathComponent("baidu/redirect"), withDestinationURL: custom.deletingLastPathComponent())
        try fm.linkItem(at: document, to: home.appendingPathComponent("baidu/hard.pdf"))
        // Use another normal file because both paths of a hard link are protected.
        let normal = try write("baidu/Course/recent-small.txt")
        var config = StorageCleanupConfiguration(home: home, kinds: [.download], bundleIDs: [StorageCleanupService.baiduBundleID])
        let scan = StorageCleanupService.scan(config, running: [StorageCleanupService.baiduBundleID])
        check("百度下载不受七天保留和百 MB 阈值限制", scan.files.contains { $0.url == normal && $0.rule.kind == .download })
        check("百度下载中的 Files 与 Downloads 子目录不漏扫", scan.files.contains { $0.url == nested })
        check("识别 Downloads 下的常见网盘目录", scan.files.contains { $0.url == common })
        check("网盘运行中仍能只读预览下载文件", !scan.files.isEmpty && scan.skippedRunning == 0)
        check("不把普通下载或自定义未知目录自动归入网盘", !scan.files.contains { $0.url == other || $0.url == custom })
        check("跳过任务临时文件、数据库、隐藏文件与硬链接", !scan.files.contains { [partial, database, hidden, document].contains($0.url) || $0.name == "hard.pdf" })
        check("网盘下载不跟随目录符号链接", !scan.files.contains { $0.url.path.contains("/redirect/") })
        check("下载扫描有目录占用统计且不重复列出", !scan.folders.isEmpty && Set(scan.files.map(\.id)).count == scan.files.count)
        var cacheConfig = config; cacheConfig.kinds = [.cache]; cacheConfig.minimumAgeDays = 0
        check("识别网盘沙盒内明确的 Electron 缓存", StorageCleanupService.scan(cacheConfig, running: []).files.contains { $0.url == cache })
        check("运行中的网盘缓存仍受保护", StorageCleanupService.scan(cacheConfig, running: [StorageCleanupService.baiduBundleID]).files.isEmpty)
        var general = config; general.kinds = [.largeFile]; general.bundleIDs = nil; general.minimumLargeBytes = 1
        check("通用大文件扫描不再漏掉 Downloads 子目录", StorageCleanupService.scan(general, running: []).files.contains { $0.url == common })
        general.largeFolder = home.appendingPathComponent("baidu")
        check("大文件扫描也跳过未完成下载", !StorageCleanupService.scan(general, running: []).files.contains { $0.url == partial })
        config.downloadFolder = custom.deletingLastPathComponent().deletingLastPathComponent()
        let customScan = StorageCleanupService.scan(config, running: [])
        check("自选下载目录替换默认范围", customScan.files.map(\.url) == [custom])
        config.downloadFolder = home
        check("下载目录拒绝个人根目录", StorageCleanupService.rules(config).isEmpty)
        config.downloadFolder = home.appendingPathComponent("Library")
        check("下载目录拒绝 Library", StorageCleanupService.rules(config).isEmpty)
        config.downloadFolder = nil
        let candidate = scan.files.first { $0.url == normal }!
        var changedScope = config; changedScope.downloadFolder = custom.deletingLastPathComponent()
        let changed = StorageCleanupService.trash([candidate], config: changedScope, running: { [] }, isOpen: { _ in false }, move: { _ in throw CocoaError(.fileWriteUnknown) })
        check("下载范围变化后拒绝执行旧候选", changed.removed.isEmpty && changed.failures.count == 1)
        var isolated = config; isolated.bundleIDs = ["com.google.Chrome"]
        check("网盘下载不混入其他软件范围", StorageCleanupService.scan(isolated, running: []).files.isEmpty)
        var moved = false
        let running = StorageCleanupService.trash([candidate], config: config, running: { [StorageCleanupService.baiduBundleID] }, isOpen: { _ in false }, move: { _ in moved = true; return nil })
        check("下载清理要求先退出网盘且不执行移动", !moved && running.removed.isEmpty && running.failures.count == 1)
        let open = StorageCleanupService.trash([candidate], config: config, running: { [] }, isOpen: { _ in true }, move: { _ in moved = true; return nil })
        check("下载清理跳过占用文件", !moved && open.removed.isEmpty)
        let defaults = UserDefaults(suiteName: "WinFileBaiduTest-" + UUID().uuidString)!
        let store = StorageCleanupModel(home: home, defaults: defaults, softwareMode: true)
        check("百度网盘与微信同级且可选择", store.softwareChoices.contains { $0.id == StorageCleanupService.baiduBundleID } && store.selectSoftware(StorageCleanupService.baiduBundleID))
        check("百度类别包含下载而其他软件不扩大", store.availableKinds == [.download, .cache, .log])
        store.accept(scan)
        check("下载候选默认不勾选", store.selection.isEmpty)
        store.selectAll(); store.requestTrash()
        check("选择下载文件仍需确认", store.confirmsTrash && !store.pendingFiles.isEmpty)
        store.search = "old-filter"; store.category = "cache"; store.scanScope = "cache"
        check("应用内选择下载目录清空旧结果和确认", store.chooseFolder(custom.deletingLastPathComponent()) && store.result.files.isEmpty && store.selection.isEmpty && !store.confirmsTrash && !store.hasScanned)
        check("更换下载目录重置旧类别与搜索条件", store.search.isEmpty && store.category == "all" && store.scanScope == "all")
        let restored = StorageCleanupModel(home: home, defaults: defaults, softwareMode: true)
        check("自选下载位置可持久恢复", restored.downloadFolder == custom.deletingLastPathComponent())
        store.useDefaultDownloadFolders()
        check("恢复常见目录清空持久自选位置", store.downloadFolder == nil && StorageCleanupModel(home: home, defaults: defaults, softwareMode: true).downloadFolder == nil)
    }

    @MainActor
    private static func testStorageCleanup(_ sandbox: URL) throws {
        print("\n[通用空间清理：规则、预览、保护与回归]")
        let fm = FileManager.default
        let home = sandbox.resolvingSymlinksInPath().appendingPathComponent("StorageHome")
        let old = Date().addingTimeInterval(-40 * 86400)
        func write(_ relative: String, size: Int = 64, recent: Bool = false) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 65, count: size).write(to: url)
            try fm.setAttributes([.modificationDate: recent ? Date() : old], ofItemAtPath: url.path)
            return url
        }
        let cache = try write("Library/Caches/com.example.Editor/old.cache")
        let recent = try write("Library/Caches/com.example.Editor/recent.cache", recent: true)
        let database = try write("Library/Caches/com.example.Editor/state.sqlite")
        _ = try write("Library/Caches/com.example.Editor/state.sqlite-wal")
        _ = try write("Library/Caches/com.example.Editor/Cookies")
        _ = try write("Library/Caches/com.spotify.client/offline-music")
        _ = try write("Library/Caches/com.apple.test/system-cache")
        _ = try write("Library/Application Support/Code/Cache/editor.cache")
        _ = try write("Library/Application Support/Code/User/settings.json")
        _ = try write("Library/Application Support/Slack/Cache/slack.cache")
        _ = try write("Library/Application Support/Google/Chrome/Default/Cache/browser.cache")
        _ = try write("Library/Application Support/Google/Chrome/Default/Bookmarks")
        _ = try write("Library/Logs/com.example.Editor/session.log")
        _ = try write("Library/Containers/com.example.Sandbox/Data/Library/Caches/container.cache")
        let installer = try write("Downloads/App.dmg")
        let large = try write("Documents/Project/video.mov", size: 256)
        let hidden = try write("Documents/.secrets/password.bin", size: 256)
        _ = try write("Documents/.env", size: 256)
        let kept = try write("Downloads/keep/file.bin")
        let keeper = try write("Downloads/keeper/file.bin")
        let hard = try write("Documents/hard.bin")
        try fm.linkItem(at: hard, to: home.appendingPathComponent("Documents/hard-copy.bin"))
        let outside = try write("Outside/secret.bin")
        try fm.createSymbolicLink(at: home.appendingPathComponent("Documents/link.bin"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: home.appendingPathComponent("Library/Caches/com.example.Redirect"), withDestinationURL: outside.deletingLastPathComponent())
        var config = StorageCleanupConfiguration(home: home, minimumLargeBytes: 32)
        let scan = StorageCleanupService.scan(config, running: [])
        func has(_ url: URL, _ kind: StorageCleanupKind? = nil) -> Bool {
            scan.files.contains { $0.url == url && (kind == nil || $0.rule.kind == kind) }
        }
        check("清理扫描不修改文件", fm.fileExists(atPath: cache.path) && fm.fileExists(atPath: installer.path))
        check("识别普通应用缓存", has(cache, .cache))
        check("缓存默认保留最近七天", !has(recent))
        check("数据库及 WAL 不列入候选", !has(database) && !scan.files.contains { $0.name.hasSuffix("-wal") })
        check("持久浏览器状态不列入缓存", !scan.files.contains { ["Cookies", "Bookmarks", "settings.json"].contains($0.name) })
        check("保留含个人数据的特殊缓存", !scan.files.contains { $0.rule.owner.contains("spotify") || $0.rule.owner.hasPrefix("com.apple.") })
        check("识别 VS Code 可重建缓存", scan.files.contains { $0.name == "editor.cache" && $0.rule.kind == .cache })
        check("识别 Chrome 配置内缓存", scan.files.contains { $0.name == "browser.cache" && $0.rule.kind == .cache })
        check("识别沙盒应用缓存", scan.files.contains { $0.name == "container.cache" })
        check("识别应用日志", scan.files.contains { $0.rule.kind == .log })
        check("识别安装包并优先分类", has(installer, .installer) && scan.files.filter { $0.url == installer }.count == 1)
        check("大文件支持通用个人目录", has(large, .largeFile))
        check("不跟随符号链接", !scan.files.contains { $0.name == "link.bin" || $0.rule.owner.contains("Redirect") })
        check("硬链接不计作可清理候选", !scan.files.contains { $0.name.hasPrefix("hard") })
        check("隐藏目录和环境凭据受保护", !has(hidden) && !scan.files.contains { $0.name == ".env" })
        check("大文件目录分布包含项目目录", scan.folders.contains { $0.url.lastPathComponent == "Project" && $0.bytes >= 256 })
        check("安装包重叠目录仍有空间分布", scan.folders.contains { $0.url.lastPathComponent == "Downloads" && $0.files > 0 })
        var reduced = scan
        let keeperFile = scan.files.first { $0.url == keeper }!
        let downloadsUsage = scan.folders.first { $0.url == installer.deletingLastPathComponent() }
        reduced.removeTrashedFiles([keeperFile.id])
        check("子目录清理不会重复扣减父级直接文件分布", reduced.folders.first { $0.url == installer.deletingLastPathComponent() }?.bytes == downloadsUsage?.bytes && !reduced.folders.contains { $0.url == keeper.deletingLastPathComponent() })
        check("占用更新按分配空间扣减且重复处理不再扣减", reduced.scannedBytes == scan.scannedBytes - keeperFile.allocated)
        let reducedBytes = reduced.scannedBytes
        reduced.removeTrashedFiles([keeperFile.id])
        check("重复移除结果不会重复扣减占用", reduced.scannedBytes == reducedBytes)
        check("候选按稳定大小顺序排列", zip(scan.files, scan.files.dropFirst()).allSatisfy { $0.size >= $1.size })
        var appScope = config; appScope.kinds = [.cache, .log]; appScope.bundleIDs = ["COM.EXAMPLE.EDITOR"]
        let appScan = StorageCleanupService.scan(appScope, running: [])
        check("软件扫描按标识隔离缓存和日志", appScan.files.count == 2 && appScan.files.allSatisfy { $0.rule.bundleID == "com.example.Editor" })
        appScope.bundleIDs = []
        check("空软件范围不会退回全盘扫描", StorageCleanupService.scan(appScope, running: []).files.isEmpty)
        appScope.bundleIDs = ["com.example.Edit"]
        check("软件标识不按前缀误匹配", StorageCleanupService.scan(appScope, running: []).files.isEmpty)
        let active = StorageCleanupService.scan(config, running: ["com.example.editor.helper"])
        check("运行中的应用缓存及日志跳过", !active.files.contains { $0.rule.bundleID == "com.example.Editor" } && active.skippedRunning >= 2)
        config.ignored = [kept.deletingLastPathComponent()]
        let ignored = StorageCleanupService.scan(config, running: [])
        check("忽略文件夹包含其后代", !ignored.files.contains { $0.url == kept })
        check("忽略匹配使用目录边界", ignored.files.contains { $0.url == keeper })
        config.ignored = []
        var limited = config; limited.entryLimit = 3
        check("扫描条目上限明确标记不完整", StorageCleanupService.scan(limited, running: []).limited)
        limited = config; limited.candidateLimit = 1
        let one = StorageCleanupService.scan(limited, running: [])
        check("候选数量上限生效", one.limited && one.files.count == 1)
        check("取消扫描返回取消状态", StorageCleanupService.scan(config, running: [], cancelled: { true }).cancelled)
        check("拒绝个人目录根目录和 Library", !StorageCleanupService.allowedLargeFolder(home, home: home) && !StorageCleanupService.allowedLargeFolder(home.appendingPathComponent("Library/Caches"), home: home))
        check("拒绝隐藏自选目录和目录外范围", !StorageCleanupService.allowedLargeFolder(hidden.deletingLastPathComponent(), home: home) && !StorageCleanupService.allowedLargeFolder(sandbox, home: home))
        var scoped = config; scoped.kinds = [.largeFile]
        check("支持只扫描大文件", StorageCleanupService.scan(scoped, running: []).files.allSatisfy { $0.rule.kind == .largeFile })
        scoped.largeFolder = large.deletingLastPathComponent()
        check("支持指定个人子目录扫描", StorageCleanupService.scan(scoped, running: []).files.contains { $0.url == large })
        var noAge = config; noAge.minimumAgeDays = 0; noAge.kinds = [.cache]
        check("年龄设置在重新扫描时生效", StorageCleanupService.scan(noAge, running: []).files.contains { $0.url == recent })
        check("只读探测支持超时退出", StorageCleanupService.probe("/bin/sleep", ["1"], timeout: 0.03) == nil)
        check("探测缺失不视为空闲", StorageCleanupService.probe("/nonexistent/winfile-tool", [], timeout: 0.03) == nil)
        // ZIP recognition reads only the listing; ordinary archives remain files.
        let payload = home.appendingPathComponent("ZipPayload")
        _ = try write("ZipPayload/Demo.app/Contents/Info.plist")
        _ = try write("ZipDocs/notes.txt")
        func zipFolder(_ source: URL, _ destination: URL) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-qr", destination.path, "."]; process.currentDirectoryURL = source
            try process.run(); process.waitUntilExit()
            check("ZIP 测试素材构建成功", process.terminationStatus == 0)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: destination.path)
        }
        let appZIP = home.appendingPathComponent("Downloads/Application.zip")
        let docsZIP = home.appendingPathComponent("Downloads/Documents.zip")
        try zipFolder(payload, appZIP); try zipFolder(home.appendingPathComponent("ZipDocs"), docsZIP)
        let zipped = StorageCleanupService.scan(config, running: [])
        check("ZIP 内含应用才识别为安装包", zipped.files.contains { $0.url == appZIP && $0.rule.kind == .installer })
        check("资料 ZIP 不被识别为安装包", !zipped.files.contains { $0.url == docsZIP && $0.rule.kind == .installer })
        // Direct execution checks inject sandbox moves. The model integration
        // below moves one generated installer to Trash and restores it.
        let candidate = scan.files.first { $0.url == cache }!
        var moved = 0
        let deniedApp = StorageCleanupService.trash([candidate], config: appScope, running: { [] }, isOpen: { _ in false }, move: { _ in moved += 1; return nil })
        check("软件执行复查拒绝其它软件候选", moved == 0 && deniedApp.removed.isEmpty && deniedApp.failures.count == 1)
        let runningDelete = StorageCleanupService.trash([candidate], config: config, running: { ["com.example.editor"] }, isOpen: { _ in false }, move: { _ in moved += 1; return nil })
        check("执行前再次检查应用运行状态", moved == 0 && runningDelete.failures.count == 1)
        let openDelete = StorageCleanupService.trash([candidate], config: config, running: { [] }, isOpen: { _ in true }, move: { _ in moved += 1; return nil })
        check("打开文件受到保护", moved == 0 && openDelete.failures.count == 1)
        let unknownDelete = StorageCleanupService.trash([candidate], config: config, running: { [] }, isOpen: { _ in nil }, move: { _ in moved += 1; return nil })
        check("未知占用状态按保留处理", moved == 0 && unknownDelete.failures.count == 1)
        let handle = try FileHandle(forReadingFrom: large)
        check("真实 lsof 能识别打开的文件", StorageCleanupService.fileIsOpen(large) == true)
        try handle.close()
        check("真实 lsof 能确认关闭的文件", StorageCleanupService.fileIsOpen(large) == false)
        var lateConfig = config; lateConfig.ignored = [cache]
        check("扫描后新加忽略仍阻止执行", StorageCleanupService.trash([candidate], config: lateConfig, running: { [] }, isOpen: { _ in false }).removed.isEmpty)
        var cancelled = false
        let cancelledDelete = StorageCleanupService.trash([candidate], config: config, running: { [] }, isOpen: { _ in cancelled = true; return false }, cancelled: { cancelled }, move: { _ in moved += 1; return nil })
        check("执行复查期间取消不再移动", moved == 0 && cancelledDelete.cancelled)
        let backup = cache.appendingPathExtension("saved")
        try fm.moveItem(at: cache, to: backup)
        _ = try write("Library/Caches/com.example.Editor/old.cache")
        let replaced = StorageCleanupService.trash([candidate], config: config, running: { [] }, isOpen: { _ in false }, move: { _ in moved += 1; return nil })
        check("同路径同内容替换仍被拒绝", moved == 0 && replaced.failures.count == 1)
        let fresh = StorageCleanupService.scan(config, running: []).files.first { $0.url == cache }!
        let changedDuringProbe = StorageCleanupService.trash([fresh], config: config, running: { [] }, isOpen: { _ in try? Data([1,2,3]).write(to: cache); return false }, move: { _ in moved += 1; return nil })
        check("占用探测后再次校验文件", moved == 0 && changedDuringProbe.failures.count == 1)
        let big = scan.files.first { $0.url == large }!
        let fakeTrash = home.appendingPathComponent("FakeTrash")
        try fm.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let outcome = StorageCleanupService.trash([big,big], config: config, running: { [] }, isOpen: { _ in false }, move: { original in
            let destination = fakeTrash.appendingPathComponent(original.lastPathComponent)
            try fm.moveItem(at: original, to: destination); return destination
        })
        check("重复选择只移动一次", outcome.removed.count == 1 && outcome.moves.count == 1 && outcome.bytes == big.size)
        let undo = FileOperationHistory.restore(outcome.moves)
        check("清理结果支持已有撤销机制", undo.errors.isEmpty && fm.fileExists(atPath: large.path))
        let restoredBig = StorageCleanupService.scan(config, running: []).files.first { $0.url == large }!
        var attemptedMove = false
        let failure = StorageCleanupService.trash([restoredBig], config: config, running: { [] }, isOpen: { _ in false }, move: { _ in attemptedMove = true; throw CocoaError(.fileWriteNoPermission) })
        check("失败不误记为已清理", attemptedMove && failure.removed.isEmpty && failure.failures.count == 1)
        // Force file-count and sorting regressions beyond one page.
        for index in 0..<410 { _ = try write("Documents/Pagination/file-\(index).bin", size: 40 + index) }
        let many = StorageCleanupService.scan(config, running: [])
        let domain = "WinFile.StorageCleanupTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = StorageCleanupModel(home: home, defaults: defaults)
        store.accept(many)
        check("清理列表最多展示 200 行", store.display.rows.count == 200 && store.display.pages >= 3)
        check("默认没有勾选任何候选", store.selection.isEmpty)
        store.selectAll(); let selected = store.selection
        store.rebuild(page: 1)
        check("全选作用于全部筛选结果且翻页保留", selected.count == many.files.count && store.selection == selected)
        for _ in 0..<100 { store.sort = "name"; store.sort = "date"; store.sort = "size" }
        check("连续切换排序快照稳定且回到首屏", store.display.page == 0 && store.display.rows.count == 200 && store.selection == selected)
        store.search = "Pagination"
        check("更改搜索条件清除旧选择", store.selection.isEmpty)
        store.selectAll()
        check("路径筛选和全选数量一致", store.display.filtered.count == 410 && store.selection.count == 410)
        store.category = StorageCleanupKind.cache.rawValue
        check("分类可与名称过滤组合", store.display.filtered.isEmpty)
        check("空筛选结果不会保留隐藏文件选择", store.selection.isEmpty)
        store.search = ""; store.category = "all"
        store.selectAll(); store.requestTrash()
        store.owner = "missing.example.App"
        check("更改来源清除选择及待确认删除", store.selection.isEmpty && store.pendingFiles.isEmpty && !store.confirmsTrash)
        store.owner = "all"
        store.ignore(kept.deletingLastPathComponent())
        let restored = StorageCleanupModel(home: home, defaults: defaults)
        check("忽略列表只在指定本机配置中持久化", restored.ignored.contains(kept.deletingLastPathComponent()))
        store.chooseFolder(home.appendingPathComponent("Library"))
        check("无效扫描目录给出反馈", store.largeFolder == nil && store.message != nil)
        let engine = FSEngine(); let manager = TabManager(engine: engine, startDirectory: nil)
        let model = manager.activeModel
        model.navigate(to: .storageCleanup)
        check("空间清理独立页面不误报空文件夹", model.isStorageCleanupView && !model.showsFileList && model.currentDirectory == nil)
        check("页签恢复保留清理页类型", SavedBrowserTab(model: model).destination == .storageCleanup)
        check("清理页使用独立图标", manager.activeTab.symbol == "externaldrive.badge.minus")
        let count = manager.count
        model.openContainingFolder(of: large)
        check("清理文件定位在新页签打开", manager.count == count + 1 && manager.activeModel.currentDirectory == large.deletingLastPathComponent())
        check("原清理页保持原位置", model.isStorageCleanupView)
        model.storageCleanup.accept(many); model.selectAll(); model.deleteSelection(permanently: true)
        check("全局删除在空间清理页仍需确认且只走废纸篓", model.storageCleanup.confirmsTrash && model.storageCleanup.pendingFiles.count == many.files.count)
        check("选择与搜索路由到当前清理模型", model.selectedIDs == model.storageCleanup.selection)
        model.search("Pagination")
        check("工具栏搜索路由到清理筛选", model.storageCleanup.search == "Pagination")
        store.owner = "missing.example.App"
        check("已清空来源仍保留可取消的筛选项", store.owners.contains("missing.example.App") && store.display.filtered.isEmpty)
        let integration = StorageCleanupModel(home: home, defaults: defaults)
        integration.scan(); waitFor { integration.hasScanned && !integration.isScanning }
        check("后台扫描发布完整结果", integration.hasScanned && integration.result.files.contains { $0.url == installer })
        integration.selection = [installer.path]; integration.requestTrash()
        let beforeBytes = integration.result.scannedBytes
        let installerAllocated = integration.selectedFiles.reduce(Int64(0)) { $0 + $1.allocated }
        let beforeDownloads = integration.result.folders.first { $0.url == installer.deletingLastPathComponent() }
        let integrationModel = BrowserModel(engine: FSEngine(), startDirectory: nil, storageCleanupModel: integration)
        integrationModel.navigate(to: .storageCleanup)
        waitFor { integration.hasScanned && !integration.isScanning }
        integration.selection = [installer.path]; integration.requestTrash()
        integration.clean()
        check("清理期间阻止应用更新重启", AppUpdatePolicy.hasActiveFileOperations(in: [integrationModel]))
        check("清理执行期间拒绝切换清理子范围", !integrationModel.selectCleanupSection(.software) && integrationModel.selection == .storageCleanup)
        waitFor({ !integration.isCleaning }, timeout: 12)
        check("模型执行仅移动已确认的测试文件", !fm.fileExists(atPath: installer.path) && fm.fileExists(atPath: kept.path))
        check("清理后占用统计扣除实际分配空间", integration.result.scannedBytes == beforeBytes - installerAllocated)
        let afterDownloads = integration.result.folders.first { $0.url == installer.deletingLastPathComponent() }
        check("清理后目录占用与文件数同步更新", beforeDownloads != nil && afterDownloads?.bytes == (beforeDownloads?.bytes ?? 0) - installerAllocated && afterDownloads?.files == (beforeDownloads?.files ?? 0) - 1)
        check("清理摘要持久化且记录实际成功数量", StorageCleanupModel(home: home, defaults: defaults).history.first?.count == 1)
        if FileOperationHistory.shared.steps.last?.moves.first?.original.path == installer.path {
            FileOperationHistory.shared.undo()
            waitFor { !FileOperationHistory.shared.isBusy }
        }
        check("真实废纸篓移动可由全局撤销还原", fm.fileExists(atPath: installer.path))
        waitFor { !integration.isScanning && integration.result.files.contains { $0.url == installer } }
        check("全局撤销后空间清理列表自动刷新", integration.result.files.contains { $0.url == installer })

        let software = StorageCleanupModel(home: home, defaults: defaults, softwareMode: true)
        let softwareIDs = software.softwareChoices.map(\.id)
        check("软件列表保留微信并发现本机缓存来源", softwareIDs.first == "wechat" && softwareIDs.contains("com.tinyspeck.slackmacgap") && softwareIDs.contains("com.google.chrome") && softwareIDs.contains("com.microsoft.vscode"))
        check("软件列表去重且排除系统及受保护来源", Set(softwareIDs).count == softwareIDs.count && !softwareIDs.contains { $0.hasPrefix("com.apple.") || $0.contains("spotify") })
        check("未解析的 bundle 标识不作为软件展示", !softwareIDs.contains("com.example.editor") && !softwareIDs.contains("com.example.sandbox"))
        check("真实软件使用名称展示而不隐藏其 bundle ID", SoftwareCleanupApp.isVisible(id: "com.google.Chrome", name: "Google Chrome"))
        check("原始 com 与其它命名空间标识均隐藏", !SoftwareCleanupApp.isVisible(id: "com.example.raw", name: "com.example.raw") && !SoftwareCleanupApp.isVisible(id: "net.example.raw", name: "net.example.raw"))
        check("已解析名称的辅助子程序仍隐藏", !SoftwareCleanupApp.isVisible(id: "com.example.app.LoginHelper", name: "登录助手") && !SoftwareCleanupApp.isVisible(id: "com.example.app.Updater", name: "Example Update"))
        check("更新与设置辅助程序名称不展示", !SoftwareCleanupApp.isVisible(id: "com.example.tools", name: "Example更新程序") && !SoftwareCleanupApp.isVisible(id: "com.example.tools", name: "DoubaoImeSettings"))
        check("微信附件不借用通用清理范围", software.configuration.bundleIDs == [] && StorageCleanupService.rules(software.configuration).isEmpty)
        let attachment = WeChatFile(url: large, root: home, kind: .video, size: 256, modified: old)
        let wechat = WeChatCleanupModel(initialResult: WeChatScanResult(files: [attachment], roots: [home]), customRoots: [])
        let softwareBrowser = BrowserModel(engine: engine, startDirectory: nil, cleanupModel: wechat, softwareCleanupModel: software)
        softwareBrowser.navigate(to: .weChatCleanup)
        check("旧微信目的地呈现软件清理并默认保留附件", softwareBrowser.isWeChatAttachmentsView && softwareBrowser.windowSubtitle == L("cleanup.title", "空间清理"))
        wechat.selection = [attachment.id]; wechat.requestTrash()
        softwareBrowser.selectCleanupSoftware("wechat")
        check("重复选择当前软件不清空选择或确认", wechat.confirmsTrash && wechat.selection == [attachment.id])
        softwareBrowser.selectCleanupSoftware("com.microsoft.vscode")
        check("离开微信清空附件选择及待确认快照", !wechat.confirmsTrash && wechat.pendingTrashFiles.isEmpty && wechat.selection.isEmpty)
        check("选择软件切换全局操作模型", softwareBrowser.activeStorageCleanup === software && !softwareBrowser.isWeChatAttachmentsView)
        software.scan(); waitFor { software.hasScanned && !software.isScanning }
        check("软件后台扫描只返回所选来源", !software.result.files.isEmpty && software.result.files.allSatisfy { $0.rule.bundleID == "com.microsoft.VSCode" && [.cache, .log].contains($0.rule.kind) })
        softwareBrowser.selectAll(); softwareBrowser.deleteSelection(permanently: true)
        check("软件全选及删除仍需确认且不跨来源", software.confirmsTrash && !software.pendingFiles.isEmpty && softwareBrowser.selectedIDs == software.selection)
        softwareBrowser.search("session")
        check("软件页面搜索路由到当前软件", software.search == "session" && softwareBrowser.weChatCleanup.search.isEmpty)
        let savedSoftware = try JSONDecoder().decode(SavedBrowserTab.self, from: JSONEncoder().encode(SavedBrowserTab(model: softwareBrowser)))
        let sessionSoftware = StorageCleanupModel(home: home, defaults: defaults, softwareMode: true)
        let sessionBrowser = BrowserModel(engine: engine, startDirectory: nil, softwareCleanupModel: sessionSoftware)
        savedSoftware.apply(to: sessionBrowser)
        check("软件页签会话恢复所选软件", sessionBrowser.isWeChatCleanupView && sessionSoftware.selectedSoftwareID == "com.microsoft.vscode")
        check("软件子页按统一空间清理格式保存", savedSoftware.kind == "storageCleanup" && savedSoftware.cleanupSection == .software)
        check("软件子页共享侧边栏高亮与窗口标题", softwareBrowser.sidebarSelection == .storageCleanup && softwareBrowser.windowSubtitle == L("cleanup.title", "空间清理"))
        softwareBrowser.selectCleanupSoftware("com.google.chrome")
        check("切换软件清除旧结果选择及确认快照", software.result.files.isEmpty && software.selection.isEmpty && software.pendingFiles.isEmpty && !software.confirmsTrash && software.search.isEmpty && !software.hasScanned)
        software.scanScope = "installer"
        check("软件范围设置不能扩大到安装包或个人大文件", software.configuration.kinds.isEmpty && software.availableKinds == [.cache, .log])
        check("未知软件选择不改变当前来源", !software.selectSoftware("unknown.invalid") && software.selectedSoftwareID == "com.google.chrome")
        software.scanScope = "all"; software.scan()
        softwareBrowser.selectCleanupSoftware("com.tinyspeck.slackmacgap")
        check("扫描途中切换软件取消旧任务", !software.isScanning && software.result.files.isEmpty && software.selectedSoftwareID == "com.tinyspeck.slackmacgap")
        software.scan(); waitFor { software.hasScanned && !software.isScanning }
        check("旧扫描不会覆盖新软件结果", !software.result.files.isEmpty && software.result.files.allSatisfy { $0.rule.bundleID == "com.tinyspeck.slackmacgap" })
        softwareBrowser.selectCleanupSoftware("wechat")
        check("切回微信恢复附件页面路由", softwareBrowser.isWeChatAttachmentsView && softwareBrowser.activeStorageCleanup == nil)
        var legacy = savedSoftware; legacy.software = nil
        legacy.apply(to: sessionBrowser)
        check("旧版微信会话兼容默认微信附件", sessionBrowser.isWeChatAttachmentsView)
        sessionBrowser.selectCleanupSoftware("com.microsoft.vscode"); legacy.software = "no.longer.available"
        legacy.apply(to: sessionBrowser)
        check("已失效的软件会话回退到微信附件", sessionBrowser.isWeChatAttachmentsView)

        var oldSoftware = savedSoftware; oldSoftware.kind = "wechat"; oldSoftware.cleanupSection = nil
        oldSoftware.apply(to: sessionBrowser)
        check("旧软件页签迁移到空间清理的软件子页", sessionBrowser.isCleanupView && sessionBrowser.cleanupSection == .software && sessionBrowser.sidebarSelection == .storageCleanup)
        wechat.selection = [attachment.id]; wechat.requestTrash()
        softwareBrowser.selectCleanupSection(.general)
        check("切换到通用清理使用正确模型", softwareBrowser.isStorageCleanupView && softwareBrowser.activeStorageCleanup === softwareBrowser.storageCleanup)
        check("离开软件范围清空微信待确认清单", !wechat.confirmsTrash && wechat.pendingTrashFiles.isEmpty && wechat.selection.isEmpty)
        softwareBrowser.storageCleanup.accept(many); softwareBrowser.selectAll(); softwareBrowser.deleteSelection()
        check("通用子范围保存为统一入口及通用范围", SavedBrowserTab(model: softwareBrowser).kind == "storageCleanup" && SavedBrowserTab(model: softwareBrowser).cleanupSection == .general)
        softwareBrowser.selectCleanupSection(.software)
        check("离开通用范围清空待确认清单", !softwareBrowser.storageCleanup.confirmsTrash && softwareBrowser.storageCleanup.pendingFiles.isEmpty && softwareBrowser.storageCleanup.selection.isEmpty)
        check("切回软件范围保留当前软件", softwareBrowser.isWeChatAttachmentsView && softwareBrowser.sidebarSelection == .storageCleanup)
        softwareBrowser.selectSidebarDestination(.storageCleanup)
        check("点击当前侧边栏入口不重置软件子范围", softwareBrowser.cleanupSection == .software)
        softwareBrowser.selectSidebarDestination(.home); softwareBrowser.selectSidebarDestination(.storageCleanup)
        check("从其它页面进入统一入口默认通用清理", softwareBrowser.isStorageCleanupView && softwareBrowser.cleanupSection == .general)

    }

    @MainActor
    private static func testFolderPickerAndDrop(_ sandbox: URL) throws {
        print("\n[应用内目录选择与收藏拖放]")
        let fm = FileManager.default
        let root = sandbox.resolvingSymlinksInPath().appendingPathComponent("Folder Picker")
        let alpha = root.appendingPathComponent("Alpha 中文")
        let beta = root.appendingPathComponent("Beta")
        let hidden = root.appendingPathComponent(".hidden")
        let app = root.appendingPathComponent("Example.APP")
        for folder in [alpha, beta, hidden, app] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("file".utf8).write(to: root.appendingPathComponent("note.txt"))
        let alias = root.appendingPathComponent("App Link")
        try fm.createSymbolicLink(at: alias, withDestinationURL: app)
        let visible = try FolderPickerModel.listFolders(root, showHidden: false)
        check("选择器仅显示可浏览文件夹且按名称排序", visible.map(\.lastPathComponent) == [alpha.lastPathComponent, beta.lastPathComponent])
        check("隐藏文件夹可按需显示", try FolderPickerModel.listFolders(root, showHidden: true).map(\.path).contains(hidden.path))
        check("选择器解析相对路径及中文空格", FolderPickerModel.resolvePath("Alpha 中文", relativeTo: root)?.path == alpha.path)
        check("选择器支持上级路径", FolderPickerModel.resolvePath("../", relativeTo: alpha)?.path == root.path)
        check("选择器支持主目录缩写", FolderPickerModel.resolvePath("~", relativeTo: root)?.path == FileSystemService.realHomeDirectory().path)
        check("选择器解析编码后的文件 URL", FolderPickerModel.resolvePath(alpha.absoluteString, relativeTo: root)?.path == alpha.path)
        check("选择器拒绝空路径及网络协议", FolderPickerModel.resolvePath("", relativeTo: root) == nil && FolderPickerModel.resolvePath("https://example.test", relativeTo: root) == nil)
        let picker = FolderPickerModel(initialDirectory: root)
        func waitUntil(_ done: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }
        picker.navigate(to: root)
        waitUntil { !picker.isLoading }
        check("选择器异步加载目录", !picker.isLoading && picker.folders == visible)
        picker.selectedPaths = [alpha.path, beta.path]
        check("选择器支持同级多选并保持显示顺序", picker.candidates.map(\.path) == [alpha.path, beta.path])
        picker.selectedPaths = []
        check("未选中子目录时添加当前目录", picker.candidates.map(\.path) == [root.path])
        picker.navigate(to: app)
        check("无效目标保留当前目录并显示错误", picker.directory.path == root.path && picker.errorMessage != nil)
        picker.navigate(to: alpha)
        picker.navigate(to: beta)
        waitUntil { !picker.isLoading }
        check("快速切换目录不会被旧加载结果覆盖", picker.directory.path == beta.path && picker.folders.isEmpty)
        picker.pathText = root.path
        picker.openPath()
        waitUntil { !picker.isLoading }
        check("输入路径可返回目录并清空旧选择", picker.directory.path == root.path && picker.selectedPaths.isEmpty)
        let providers = [SidebarFolderDrop.provider(for: beta)!, SidebarFolderDrop.provider(for: alpha)!, NSItemProvider(object: "invalid" as NSString)]
        var resolved: [URL] = []
        var failed = 0
        var finished = false
        SidebarFolderDrop.load(providers) { urls, unresolved in resolved = urls; failed = unresolved; finished = true }
        waitUntil { finished }
        check("拖放异步解析保持原顺序", finished && resolved.map(\.path) == [beta.path, alpha.path])
        check("拖放报告无法解析的条目", finished && failed == 1)
        check("安卓 URL 不伪装成本地拖出文件", SidebarFolderDrop.provider(for: AndroidURL.make(serial: "test", path: "/sdcard")) == nil)
        check("拖放不会移动或删除源文件夹", fm.fileExists(atPath: alpha.path) && fm.fileExists(atPath: beta.path))
        picker.cancelLoading()
    }

    @MainActor
    private static func testUpdatePolicy(_ sandbox: URL) throws {
        print("\n[自动更新配置与重启保护]")
        check("正常启动允许检查更新", AppUpdatePolicy.allowsStartupCheck(arguments: ["WinFile"]))
        for flag in ["--run-tests", "--render-snapshot", "--snapshot-mode", "--dump-view-tree", "--probe-context-menu", "--selftest-tabs"] {
            check("\(flag) 不自动联网更新", !AppUpdatePolicy.allowsStartupCheck(arguments: ["WinFile", flag]))
        }
        let infoURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        let info: [String: Any]
        if let bundled = Bundle.main.infoDictionary, bundled["SUFeedURL"] != nil { info = bundled }
        else { info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any] }
        check("更新源固定为本项目 GitHub Release", info["SUFeedURL"] as? String == AppUpdatePolicy.feedURL && URL(string: AppUpdatePolicy.feedURL)?.scheme == "https")
        check("更新公钥已固定且为 Ed25519 公钥", info["SUPublicEDKey"] as? String == AppUpdatePolicy.publicKey && Data(base64Encoded: AppUpdatePolicy.publicKey)?.count == 32)
        check("默认启动检查且不静默安装", info["SUEnableAutomaticChecks"] as? Bool == true && info["SUAutomaticallyUpdate"] as? Bool == false)
        check("更新清单及压缩包均要求签名校验", info["SURequireSignedFeed"] as? Bool == true && info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        check("签名失败不会到期绕过", info["SUSignedFeedFailureExpirationInterval"] as? Int == 0)
        let engine = FSEngine()
        engine.scopeOverrideForTesting = [sandbox]
        let first = BrowserModel(engine: engine, startDirectory: nil)
        let second = BrowserModel(engine: engine, startDirectory: nil)
        check("空闲窗口允许重启", !AppUpdatePolicy.hasActiveFileOperations(in: [first, second]))
        second.archiveProgress = ArchiveProgress(name: "archive.7z", isCompressing: false)
        check("非活动页签解压时延迟更新重启", AppUpdatePolicy.hasActiveFileOperations(in: [first, second]))
        second.archiveProgress = nil
        second.transferProgress = AndroidTransferProgress(name: "download", direction: .download)
        check("安卓传输时延迟更新重启", AppUpdatePolicy.hasActiveFileOperations(in: [first, second]))
        second.transferProgress = nil
        first.isBusy = true
        check("其他正在处理的文件任务也保护退出", AppUpdatePolicy.hasActiveFileOperations(in: [first, second]))
        first.isBusy = false
        check("任务结束后允许继续更新", !AppUpdatePolicy.hasActiveFileOperations(in: [first, second]))
        let a = TabManager(engine: engine, startDirectory: nil)
        let b = TabManager(engine: engine, startDirectory: nil)
        check("重启保护覆盖多个窗口的模型", TabManager.allModels.contains { $0 === a.activeTab.model } && TabManager.allModels.contains { $0 === b.activeTab.model })
    }

    @MainActor
    private static func testSidebarQuickAdd(_ sandbox: URL) throws {
        print("\n[侧边栏快捷添加与目标解析]")
        let defaults = UserDefaults.standard
        let keys = ["AddedFolderPaths", "FavoritesSeeded", "PinnedFolders"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set([], forKey: "AddedFolderPaths")
        defaults.set(true, forKey: "FavoritesSeeded")
        defaults.set(["/Home-favorite-must-stay-unchanged"], forKey: "PinnedFolders")
        let fm = FileManager.default
        let root = sandbox.resolvingSymlinksInPath().appendingPathComponent("Sidebar Quick Add")
        let alpha = root.appendingPathComponent("收藏 空格")
        let beta = root.appendingPathComponent("Beta")
        let app = root.appendingPathComponent("Example.APP")
        let file = root.appendingPathComponent("readme.txt")
        for directory in [alpha, beta, app] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("keep this file".utf8).write(to: file)
        let engine = FSEngine()
        engine.scopeOverrideForTesting = [root]
        let model = BrowserModel(engine: engine, startDirectory: root)
        let peer = BrowserModel(engine: engine, startDirectory: root)
        let deadline = Date().addingTimeInterval(10)
        while (model.isBusy || peer.isBusy) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let a = item(alpha)
        let b = item(beta)
        let plainFile = item(file)
        model.selectedIDs = [a.id]
        check("图标右键未选中目录时只针对该目录", model.sidebarContextItems(item: b).map(\.id) == [b.id])
        check("表格菜单使用显式目标而非旧选中项", model.sidebarContextItems(item: a, ids: [b.id]).map(\.id) == [b.id])
        check("空菜单目标不回退到旧选中项", model.sidebarContextItems(item: a, ids: []).isEmpty)
        model.selectedIDs = [a.id, b.id, plainFile.id]
        let targets = model.sidebarContextItems(item: b)
        check("右键多选中的目录时保留整组目标", Set(targets.map(\.id)) == model.selectedIDs)
        let directoryBefore = model.currentDirectory
        let selectionBefore = model.selectedIDs
        let navigationBefore = model.selection
        let canGoBackBefore = model.canGoBack
        var publications = 0
        let observation = engine.$authorizedRoots.dropFirst().sink { _ in publications += 1 }
        let result = model.addFoldersToSidebar([alpha, alpha.appendingPathComponent("../收藏 空格"), file, beta])
        check("批量添加按顺序保存且归一化路径去重", result.added.map(\.path) == [alpha.path, beta.path]
              && result.duplicateCount == 1 && result.rejectedCount == 1)
        check("批量添加只发布一次侧边栏变化", publications == 1)
        check("普通文件不能混入侧边栏收藏", !engine.containsFolder(file))
        check("添加后不改变目录、选择或导航历史", model.currentDirectory == directoryBefore
              && model.selectedIDs == selectionBefore && model.selection == navigationBefore && model.canGoBack == canGoBackBefore)
        check("添加结果通过状态栏反馈", model.statusMessage == result.statusMessage && !model.statusMessage.isEmpty)
        check("共享引擎的其他页签同步看到收藏", peer.engine.authorizedRoots.map(\.path) == [alpha.path, beta.path])
        check("添加侧边栏不覆盖主页收藏", defaults.stringArray(forKey: "PinnedFolders") == ["/Home-favorite-must-stay-unchanged"])
        let duplicates = model.addFoldersToSidebar([alpha, beta])
        check("全部重复时不写入或重复发布", duplicates.added.isEmpty && duplicates.duplicateCount == 2 && publications == 1)
        check("当前本地目录可直接添加", model.currentSidebarFolder == root)
        model.addFoldersToSidebar([root])
        check("添加当前目录后仍停留原目录", engine.containsFolder(root) && model.currentDirectory == root)
        let rejected = engine.addFolders([file, app, app.appendingPathComponent("."), root.appendingPathComponent("missing"),
                                          URL(string: "https://example.test/folder")!,
                                          AndroidURL.make(serial: "not-a-real-device", path: root.path)])
        check("拒绝普通文件、应用包、失效目录及非本地 URL", rejected.added.isEmpty && rejected.rejectedCount == 6)
        let unreadable = root.appendingPathComponent("Unreadable")
        try fm.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        let unreadableResult = engine.addFolders([unreadable])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path)
        check("拒绝不可读取目录并报告失败", unreadableResult.rejectedCount == 1 && unreadableResult.added.isEmpty)
        let restored = FSEngine()
        check("重建引擎恢复收藏顺序", restored.authorizedRoots.map(\.path) == [alpha.path, beta.path, root.path])
        check("旧的单目录 API 同样校验输入", !engine.addFolder(file) && !engine.addFolder(alpha))
        engine.removeFolder(alpha)
        check("移除收藏只删除快捷入口", !engine.containsFolder(alpha) && fm.fileExists(atPath: alpha.path))
        let removed = root.appendingPathComponent("Deleted Before Action")
        try fm.createDirectory(at: removed, withIntermediateDirectories: true)
        try fm.removeItem(at: removed)
        check("操作执行时重新检查目录存在性", engine.addFolders([removed]).rejectedCount == 1)
        model.navigate(to: .category(.document))
        check("分类页不把残留浏览目录当作当前收藏目标", model.currentSidebarFolder == nil)
        observation.cancel()
    }

    @MainActor
    private static func testLanguageSelection() throws {
        print("\n[语言选择与资源]")
        check("中文区域自动选择简体中文", AppLanguage.resolve(.system, preferredLanguages: ["zh-CN"]) == "zh-Hans")
        check("繁体系统使用当前支持的中文", AppLanguage.resolve(.system, preferredLanguages: ["zh-Hant-TW"]) == "zh-Hans")
        check("英文区域自动选择英文", AppLanguage.resolve(.system, preferredLanguages: ["en-GB"]) == "en")
        check("其它语言回退英文", AppLanguage.resolve(.system, preferredLanguages: ["fr-FR"]) == "en")
        check("按系统偏好顺序匹配支持语言", AppLanguage.resolve(.system, preferredLanguages: ["fr", "zh-Hans", "en"]) == "zh-Hans")
        check("手动语言优先于系统", AppLanguage.resolve(.english, preferredLanguages: ["zh-Hans"]) == "en")
        check("空系统语言列表有默认值", AppLanguage.resolve(.system, preferredLanguages: []) == "en")
        check("缺失翻译使用兜底文案", L("test.missing.translation", "Fallback") == "Fallback")
        let resources = Bundle.main.url(forResource: "en", withExtension: "lproj")?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        var tables: [[String: String]] = []
        for code in ["en", "zh-Hans"] {
            let data = try Data(contentsOf: resources.appendingPathComponent("\(code).lproj/Localizable.strings"))
            let table = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
            tables.append(table)
        }
        check("中英文资源键完整一致", Set(tables[0].keys) == Set(tables[1].keys))
        check("英文清理标题已翻译", tables[0]["wechat.title"] == "WeChat Cleanup")
        check("文件类型含英文翻译", tables[0]["fileType.pdf"] == "PDF Document")
        for key in tables[0].keys {
            let pattern = "%[0-9.]*[@diuf]"
            func formats(_ value: String) -> [String] {
                let regex = try! NSRegularExpression(pattern: pattern)
                return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { (value as NSString).substring(with: $0.range) }
            }
            if formats(tables[0][key]!) != formats(tables[1][key] ?? "") {
                check("格式参数一致：\(key)", false)
            }
        }
        if Bundle.main.path(forResource: "en", ofType: "lproj") != nil {
            let localization = Localization.shared
            let originalChoice = localization.language
            let originalPreference = UserDefaults.standard.object(forKey: Localization.preferenceKey)
            defer {
                localization.language = originalChoice
                if let originalPreference { UserDefaults.standard.set(originalPreference, forKey: Localization.preferenceKey) }
                else { UserDefaults.standard.removeObject(forKey: Localization.preferenceKey) }
            }
            localization.language = .english
            check("手动选择持久化", UserDefaults.standard.string(forKey: Localization.preferenceKey) == "en")
            check("运行时切到英文", L("wechat.title", "") == "WeChat Cleanup")
            check("旧界面文本走同一语言入口", WLocalizedString("button.cancel", comment: "取消") == "Cancel")
            localization.language = .simplifiedChinese
            check("运行时切回中文", L("wechat.title", "") == "微信文件清理")
            check("已有文件类型即时切换", FileTypeDB.info(name: "sample.pdf", isDirectory: false, isSymlink: false, isBundle: false).description == "PDF 文档")
        }
    }

    @MainActor
    private static func testWeChatCleanup(_ sandbox: URL) throws {
        print("\n[微信附件清理]")
        let fm = FileManager.default
        let home = sandbox.resolvingSymlinksInPath().appendingPathComponent("WeChatHome")
        let root = home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data")
        let attachments = root.appendingPathComponent("Documents/xwechat_files/wxid_test/msg")
        func file(_ relative: String, size: UInt64 = 16, days: Int = 0) throws -> URL {
            let url = attachments.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data())
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: size)
            try handle.close()
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(days) * 86400)], ofItemAtPath: url.path)
            return url
        }
        let document = try file("file/report.pdf", size: 2 * 1024 * 1024, days: 100)
        let image = try file("image/photo.dat", days: 100)
        let video = try file("video/clip.mp4", size: 11 * 1024 * 1024)
        _ = try file("file/chat.db")
        _ = try file("file/chat.db-wal")
        _ = try file("file/settings.plist")
        _ = try file("db_storage/secret.pdf")
        _ = try file("config/options.json")
        _ = try file("misc/unrelated.pdf")
        let outside = sandbox.appendingPathComponent("outside.pdf").resolvingSymlinksInPath()
        try Data("outside".utf8).write(to: outside)
        let link = attachments.appendingPathComponent("file/link.pdf")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let directoryLink = attachments.appendingPathComponent("file/external")
        try fm.createSymbolicLink(at: directoryLink, withDestinationURL: outside.deletingLastPathComponent())
        // Real WeChat containers include top-level shortcuts to the user's folders.
        // Skipping descendants for these non-directory entries can suppress sibling trees.
        let externalDownloads = sandbox.resolvingSymlinksInPath().appendingPathComponent("External Downloads")
        let externalFile = externalDownloads.appendingPathComponent("files/do-not-include.pdf")
        try fm.createDirectory(at: externalFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("external".utf8).write(to: externalFile)
        for name in ["Music", "Pictures", "Desktop", "Movies", "Downloads"] {
            try fm.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: externalDownloads)
        }
        let discovery = WeChatCleanupService.discoverRoots(home: home)
        check("自动发现微信容器", discovery.roots.contains { $0.path == root.path })
        let scanned = WeChatCleanupService.scan(roots: [root, attachments])
        check("重叠目录去重且只发现三项附件", scanned.files.count == 3, "\(scanned.files.map { $0.url.lastPathComponent })")
        check("容器顶部快捷链接不会漏扫后面的真实聊天目录", scanned.files.contains { $0.url == document } && scanned.files.contains { $0.url == video })
        check("容器快捷链接不会扫描到外部下载目录", !scanned.files.contains { $0.url == externalFile || $0.url.path.contains("/Downloads/") })
        check("数据库和辅助文件不列为清理候选", !scanned.files.contains { $0.url.lastPathComponent.contains("chat.db") })
        check("不跟随文件或目录符号链接", !scanned.files.contains { $0.url.path.contains("external") || $0.url == link })
        check("加密图片按存储目录分类", scanned.files.first { $0.url == image }?.kind == .image)
        check("PDF 属于文档附件", scanned.files.first { $0.url == document }?.kind == .document)
        check("默认按大小降序", scanned.files.first?.url == video)
        check("取消后不继续收集附件", WeChatCleanupService.scan(roots: [root], cancelled: { true }).files.isEmpty)
        let missing = WeChatCleanupService.scan(roots: [home.appendingPathComponent("missing")])
        check("无法读取目录有明确报告", !missing.inaccessible.isEmpty)
        let alias = home.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: root)
        check("符号链接扫描根被跳过", WeChatCleanupService.scan(roots: [alias]).files.isEmpty)
        let relocated = home.appendingPathComponent("Custom WeChat Attachments")
        try fm.createDirectory(at: relocated, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: relocated.appendingPathComponent("notes.txt"))
        let explicitScan = WeChatCleanupService.scan(roots: [], explicitRoots: [relocated])
        check("自定义附件目录可扫描", explicitScan.files.count == 1)
        check("根路径边界不接受同名前缀目录", !WeChatCleanupService.contains(home.appendingPathComponent("Custom WeChat Attachments-other/a.pdf"), in: relocated))

        let store = WeChatCleanupModel(initialResult: scanned)
        store.minimumMB = 10
        check("大小筛选", store.visibleFiles.map(\.url) == [video])
        store.minimumMB = 0
        store.olderThanDays = 90
        check("时间筛选", Set(store.visibleFiles.map(\.url)) == Set([document, image]))
        store.kind = "document"
        check("多个筛选条件组合", store.visibleFiles.map(\.url) == [document])
        store.selection = Set(store.visibleFiles.map(\.id))
        check("选中空间统计", store.selectedSize == 2 * 1024 * 1024)
        store.search = "REPORT"
        check("文件名筛选不区分大小写", store.visibleFiles.map(\.url) == [document])
        check("修改筛选清空旧选择", store.selection.isEmpty)
        store.search = "nonexistent"
        check("无匹配结果", store.visibleFiles.isEmpty)

        guard let original = scanned.files.first(where: { $0.url == document }),
              let photo = scanned.files.first(where: { $0.url == image }),
              let clip = scanned.files.first(where: { $0.url == video }) else {
            check("扫描结果包含测试附件", false)
            return
        }
        check("未变化附件可以清理", WeChatCleanupService.isUnchanged(original))
        try Data("new content".utf8).write(to: document)
        check("已修改文件不能按旧扫描清理", !WeChatCleanupService.isUnchanged(original))
        try fm.removeItem(at: image)
        try fm.createSymbolicLink(at: image, withDestinationURL: outside)
        check("扫描后替换为符号链接会跳过", !WeChatCleanupService.isUnchanged(photo))
        var attempted: [URL] = []
        let outcome = WeChatCleanupService.trash(scanned.files) { url in
            attempted.append(url)
            throw NSError(domain: "FixtureTrashFailure", code: 1)
        }
        check("清理只尝试仍未变化的附件", attempted == [video])
        check("部分失败和跳过逐项报告", outcome.failures.count == 3 && outcome.removed.isEmpty)
        check("失败时原文件保留", fm.fileExists(atPath: video.path))
        let fixtureTrash = home.appendingPathComponent("FixtureTrash")
        try fm.createDirectory(at: fixtureTrash, withIntermediateDirectories: true)
        let success = WeChatCleanupService.trash([clip]) { url in
            try fm.moveItem(at: url, to: fixtureTrash.appendingPathComponent(url.lastPathComponent))
        }
        check("清理成功只报告成功项", success.removed == Set([video.path]) && success.failures.isEmpty)
        check("清理操作没有碰到外部链接目标", (try? Data(contentsOf: outside)) == Data("outside".utf8))
        let engine = FSEngine()
        engine.restrictScopeForTesting([home])
        let model = BrowserModel(engine: engine, startDirectory: nil)
        model.navigate(to: .weChatCleanup)
        check("微信清理是独立页面", model.isWeChatCleanupView && !model.showsFileList && model.currentDirectory == nil)
        model.selectFolder(home)
        model.goBack()
        check("微信清理页面支持导航返回", model.isWeChatCleanupView)
        model.weChatCleanup.kind = "document"
        model.weChatCleanup.search = "report"
        model.openContainingFolder(of: document)
        let locateDeadline = Date().addingTimeInterval(8)
        while model.isBusy && Date() < locateDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let targetID = FileItem.canonicalID(for: document)
        check("微信附件可跳转到真实所在目录", model.currentDirectory?.path == document.deletingLastPathComponent().path)
        check("微信附件跳转后加载了目标文件", model.displayedItems.contains { $0.id == targetID })
        check("微信附件异步加载后保持目标选中", model.selectedIDs == Set([targetID]))
        _ = model.consumePendingSelection()
        model.goBack()
        check("从附件目录返回微信清理页", model.isWeChatCleanupView)
        check("返回清理页保留原筛选条件", model.weChatCleanup.kind == "document" && model.weChatCleanup.search == "report")
        let tab = WinFileTab(engine: engine, startDirectory: nil)
        tab.model.navigate(to: .weChatCleanup)
        check("微信清理页签标题正确", tab.title == L("cleanup.title", "空间清理"))
    }

    /// 微信清理分页：排序全局生效、翻页正确、筛选重置页码、选择跨页保留
    @MainActor
    private static func testWeChatPagination(_ sandbox: URL) throws {
        print("\n\n[微信清理分页]")

        let root = sandbox.appendingPathComponent("wechat-pagination")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // 450 项：名称与大小都不同，便于验证排序是否全局生效
        var files: [WeChatFile] = []
        for i in 0..<450 {
            let url = root.appendingPathComponent(String(format: "file-%03d.dat", i))
            files.append(WeChatFile(url: url, root: root, kind: .document,
                                    size: Int64(450 - i), modified: base.addingTimeInterval(Double(i))))
        }
        let scan = WeChatScanResult(files: files, roots: [root], inaccessible: [])
        let store = WeChatCleanupModel(initialResult: scan, homeDirectory: sandbox, customRoots: [])

        check("每页 200 行", WeChatCleanupModel.pageSize == 200, "\(WeChatCleanupModel.pageSize)")
        check("全量筛选数 450", store.matchingCount == 450, "\(store.matchingCount)")
        check("总页数 3", store.pageCount == 3, "\(store.pageCount)")
        check("当前页 200 行", store.pagedFiles.count == 200, "\(store.pagedFiles.count)")
        check("起始页区间 1–200", store.pageRange.first == 1 && store.pageRange.last == 200,
              "\(store.pageRange)")

        // 排序必须全局生效：第 1 页应是最小名称，最后一页应是最大名称
        store.setSort(field: "name", ascending: true)
        check("排序后回到第一页", store.page == 0)
        check("第 1 页首项是全局最小", store.pagedFiles.first?.name == "file-000.dat",
              store.pagedFiles.first?.name ?? "nil")
        store.goToPage(2)
        check("翻到最后一页", store.page == 2)
        check("最后一页 50 行", store.pagedFiles.count == 50, "\(store.pagedFiles.count)")
        check("最后一页区间 401–450", store.pageRange.first == 401 && store.pageRange.last == 450,
              "\(store.pageRange)")
        check("最后一页末项是全局最大", store.pagedFiles.last?.name == "file-449.dat",
              store.pagedFiles.last?.name ?? "nil")

        // 降序：第 1 页首项应是最大名称
        store.setSort(field: "name", ascending: false)
        check("降序后回到第一页且首项最大", store.page == 0 && store.pagedFiles.first?.name == "file-449.dat",
              store.pagedFiles.first?.name ?? "nil")

        // 按大小排序：第 1 页首项应是最大体积
        store.setSort(field: "size", ascending: false)
        check("按大小降序首项最大", store.pagedFiles.first?.size == 450,
              "\(store.pagedFiles.first?.size ?? -1)")

        // 翻页边界
        store.goToPage(99)
        check("超出范围被夹到最后一页", store.page == store.pageCount - 1, "\(store.page)")
        check("不能继续下一页", !store.canGoNext)
        store.goToPage(-5)
        check("负数被夹到第一页", store.page == 0)
        check("不能继续上一页", !store.canGoPrevious)

        // 选择跨页保留
        store.selection = [store.pagedFiles[0].id]
        store.nextPage()
        check("翻页后选择仍保留", store.selectedFiles.count == 1, "\(store.selectedFiles.count)")
        check("选择统计不受当前页影响", store.selectedFiles.first?.size == 450,
              "\(store.selectedFiles.first?.size ?? -1)")
        store.selection = Set(store.visibleFiles.map(\.id))
        check("全选筛选结果仍为 450 项", store.selectedFiles.count == 450, "\(store.selectedFiles.count)")

        // 双击行号对应当前页
        store.goToPage(2)
        check("行号映射到当前页首项", store.itemForActivation(at: 0)?.name == store.pagedFiles[0].name,
              store.itemForActivation(at: 0)?.name ?? "nil")
        check("超出当前页的行号不打开", store.itemForActivation(at: 200) == nil)

        // 筛选变化重置页码并清空选择
        store.search = "file-00"
        check("筛选后回到第一页", store.page == 0, "\(store.page)")
        check("筛选后清空选择", store.selectedFiles.isEmpty)
        check("筛选后统计按全量筛选结果", store.matchingCount == store.visibleFiles.count,
              "\(store.matchingCount)")

        // 排序状态只发布一次（避免一次点击触发多轮全表重算）
        var notifications = 0
        let token = store.objectWillChange.sink { notifications += 1 }
        defer { token.cancel() }
        store.setSort(field: "name", ascending: true)
        check("切换排序只发布一次变更", notifications == 1, "\(notifications) 次")

        // 条件相同则不产生多余通知
        notifications = 0
        store.setSort(field: "name", ascending: true)
        check("排序未变化时不发布", notifications == 0, "\(notifications) 次")
    }

    @MainActor
    private static func testWeChatFileActions(_ sandbox: URL) throws {
        print("\n[微信附件文件操作]")
        let fm = FileManager.default
        let home = sandbox.resolvingSymlinksInPath().appendingPathComponent("WeChatActionsHome")
        let root = home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/msg/file")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("alpha.txt")
        let second = root.appendingPathComponent("beta.txt")
        try Data("alpha".utf8).write(to: first)
        try Data("beta is longer".utf8).write(to: second)
        let scanned = WeChatCleanupService.scan(roots: [root])
        let store = WeChatCleanupModel(initialResult: scanned, homeDirectory: home, customRoots: [])
        let engine = FSEngine()
        engine.restrictScopeForTesting([home])
        let model = BrowserModel(engine: engine, startDirectory: nil, cleanupModel: store)
        model.navigate(to: .weChatCleanup)
        func waitForOperations() {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            } while (store.isScanning || model.isBusy || model.archiveProgress != nil) && Date() < deadline
        }
        model.selectedIDs = [first.path]
        check("微信选择同步到共享文件操作", model.selectedItems.map(\.url) == [first] && store.selection == [first.path])
        let snapshot = model.selectedItems.first!
        check("附件保留文件属性与类型", snapshot.size == 5 && snapshot.category == .document && snapshot.created != nil && snapshot.isReadable)
        store.selection = [second.path]
        check("微信表格选择同步到工具栏", model.selectedIDs == [second.path] && model.selectedCount == 1)
        model.selectAll()
        check("微信全选支持多文件菜单", model.selectedCount == 2)
        store.selectForContextMenu([first.path])
        check("右键已选行保留多选", model.selectedCount == 2)
        model.clearSelection()
        store.selectForContextMenu([first.path])
        check("右键未选行选中正确文件", model.selectedItems.map(\.url) == [first])
        store.selectForContextMenu(["/invalid"])
        check("右键忽略无效结果标识", model.selectedIDs == [first.path])
        store.search = "alpha"
        check("筛选同步清除共享选择", model.selectedCount == 0 && model.selectedIDs.isEmpty)
        model.selectAll()
        check("共享全选仅包含筛选结果", model.selectedItems.map(\.url) == [first])
        store.search = ""
        store.sort = "name"
        let activated = store.itemForActivation(at: 1)
        check("双击按当前名称排序定位", activated?.url == second && model.selectedIDs == [second.path])
        store.sort = "size"
        check("双击按当前大小排序定位", store.itemForActivation(at: 1)?.url == first)
        store.search = "beta"
        check("双击按筛选后的行定位", store.itemForActivation(at: 0)?.url == second)
        check("双击空白行不打开旧选择", store.itemForActivation(at: -1) == nil && store.itemForActivation(at: 1) == nil && model.selectedIDs == [second.path])
        store.search = ""
        model.selectedIDs = [first.path]
        model.copySelectionToClipboard()
        check("微信复制使用真实附件路径", model.clipboard?.urls == [first] && model.clipboard?.mode == .copy)
        model.cutSelectionToClipboard()
        check("微信剪切支持共享剪贴板", model.clipboard?.urls == [first] && model.clipboard?.mode == .cut)
        model.copyNameToClipboard()
        check("微信复制文件名", NSPasteboard.general.string(forType: .string) == "alpha.txt")
        model.copyPathToClipboard()
        check("微信复制完整路径", NSPasteboard.general.string(forType: .string) == first.path)
        model.deleteSelection(permanently: true)
        check("微信右键清理仍要求确认且不会直接删除", store.confirmsTrash && store.pendingTrashFiles.map(\.url) == [first] && fm.fileExists(atPath: first.path))
        store.confirmsTrash = false
        model.rename(snapshot, to: "renamed.txt")
        waitForOperations()
        let renamed = root.appendingPathComponent("renamed.txt")
        check("微信重命名使用共享操作并刷新结果", !fm.fileExists(atPath: first.path) && store.result.files.contains { $0.url == renamed })
        model.selectedIDs = [renamed.path]
        let countBeforeCopy = store.result.files.count
        model.duplicateSelection()
        waitForOperations()
        check("微信制作副本后刷新结果", model.errorMessage == nil && store.result.files.count == countBeforeCopy + 1)
        model.selectedIDs = [renamed.path]
        check("微信页压缩菜单可用", model.canCompress)
        model.compressSelection()
        waitForOperations()
        let archive = store.result.files.first { $0.url.pathExtension == "zip" }
        check("微信压缩输出到附件所在目录并刷新", model.errorMessage == nil && archive?.url.deletingLastPathComponent().path == root.path)
        if let archive {
            try fm.removeItem(at: renamed)
            model.selectedIDs = [archive.id]
            check("微信压缩包显示解压操作", model.canExtract)
            model.extractSelection()
            waitForOperations()
            check("微信解压到压缩包所在目录并刷新", model.errorMessage == nil && fm.fileExists(atPath: renamed.path) && store.result.files.contains { $0.url == renamed })
        }
        model.selectedIDs = [second.path]
        model.openContainingFolder(of: second)
        waitForOperations()
        model.goBack()
        check("跳转目录后返回保留微信选择", model.isWeChatCleanupView && model.selectedIDs == [second.path])
    }

    @MainActor
    private static func testFunctionalImprovements(_ sandbox: URL) throws {
        print("\n[功能一致性与扫描完整性]")
        let fm = FileManager.default
        let root = sandbox.resolvingSymlinksInPath().appendingPathComponent("Improvements")
        let source = root.appendingPathComponent("Source")
        let target = root.appendingPathComponent("Target")
        for dir in [source, target] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let small = source.appendingPathComponent("alpha.pdf")
        let large = source.appendingPathComponent("z-large.pdf")
        try Data("a".utf8).write(to: small)
        try Data(repeating: 0, count: 1000).write(to: large)
        let pb = NSPasteboard(name: NSPasteboard.Name("WinFile-tests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let clipboard = FileClipboard(pasteboard: pb, monitor: false)
        let engine = FSEngine()
        engine.restrictScopeForTesting([source])
        let a = BrowserModel(engine: engine, startDirectory: source, clipboardStore: clipboard)
        let b = BrowserModel(engine: engine, startDirectory: target, clipboardStore: clipboard)
        func wait(_ model: BrowserModel) {
            let deadline = Date().addingTimeInterval(12)
            repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            while (model.isBusy || model.archiveProgress != nil) && Date() < deadline
        }
        wait(a); wait(b)
        let oldField = a.sortField
        let oldAscending = a.sortAscendingFlag
        defer { a.sortField = oldField; a.sortAscendingFlag = oldAscending }
        a.selectedIDs = [FileItem.canonicalID(for: small)]
        a.copySelectionToClipboard()
        check("跨页签共享复制内容", b.clipboard?.urls.map { FileItem.canonicalID(for: $0) } == [FileItem.canonicalID(for: small)] && b.canPaste)
        b.paste(); wait(b)
        check("跨页签粘贴复制到目标目录", fm.fileExists(atPath: target.appendingPathComponent("alpha.pdf").path))
        a.cutSelectionToClipboard()
        check("跨页签共享剪切模式", b.clipboard?.mode == .cut)
        pb.clearContents(); pb.setString("new text", forType: .string)
        check("系统文本剪贴板使旧剪切立即失效", a.clipboard == nil && !b.canPaste)
        clipboard.refresh()
        pb.clearContents(); pb.writeObjects([large as NSURL])
        check("识别外部文件剪贴板且不误认为剪切", b.clipboard?.mode == .copy && b.clipboard?.urls.first?.path == large.path)
        let generation = pb.changeCount
        pb.clearContents(); pb.setString("newer contents", forType: .string)
        clipboard.clear(ifGeneration: generation)
        check("任务结束不清除更新的系统剪贴板", pb.string(forType: .string) == "newer contents")
        a.sortField = .size; a.sortAscendingFlag = false
        check("按大小排序", a.displayedItems.first?.name == "z-large.pdf")
        a.reload(); wait(a)
        check("目录刷新保持排序", a.displayedItems.first?.name == "z-large.pdf")
        a.search("pdf"); wait(a)
        check("搜索结果应用当前排序", a.displayedItems.first?.name == "z-large.pdf")
        a.sortAscendingFlag = true
        check("搜索结果响应排序切换", a.displayedItems.first?.name == "alpha.pdf")
        a.reload(); wait(a)
        check("刷新保留搜索词与搜索结果", a.isSearching && a.searchQuery == "pdf" && a.displayedItems.count == 2)
        a.search("pdf"); a.clearSearch(); wait(a)
        check("清空搜索不会残留忙碌状态", !a.isSearching && !a.isBusy)
        a.search("pdf"); a.search(""); wait(a)
        check("空搜索取消任务并恢复目录", !a.isSearching && !a.isBusy && a.displayedItems.count == 2)
        a.navigate(to: .category(.pdf)); wait(a)
        check("分类结果应用排序", a.displayedItems.first?.name == "alpha.pdf")
        guard let selected = a.displayedItems.first(where: { $0.name == "alpha.pdf" }) else {
            check("分类测试附件存在", false); return
        }
        a.rename(selected, to: "renamed.pdf"); wait(a)
        check("分类改名后刷新不残留旧名称", a.isCategoryView && a.displayedItems.contains { $0.name == "renamed.pdf" } && !a.displayedItems.contains { $0.name == "alpha.pdf" })
        let many = root.appendingPathComponent("Many")
        try fm.createDirectory(at: many, withIntermediateDirectories: true)
        for i in 0..<3001 { fm.createFile(atPath: many.appendingPathComponent("entry-\(i).pdf").path, contents: Data()) }
        let limited = FileSystemService.categoryReport(.pdf, under: [many], budget: 40)
        check("大目录不再整体跳过", limited.items.count == 40 && limited.limitReached)
        let complete = FileSystemService.categoryReport(.pdf, under: [many], budget: 4000)
        check("扩展结果上限可完整扫描大目录", complete.items.count == 3001 && !complete.isPartial)
        check("大目录分类徽标也计数", FileSystemService.categoryCounts(under: [many])[.pdf] == 800)
        let search = FileSystemService.searchReport(under: many, matching: "entry-", limit: 400)
        check("搜索截断提供明确标记", search.items.count == 400 && search.limitReached)
        let budget = FileSystemService.searchReport(under: many, matching: "unmatched", entryLimit: 5)
        check("遍历预算单独报告", budget.visitLimitReached && budget.visited == 5)
        let stopped = FileSystemService.categoryReport(.pdf, under: [many], cancelled: { true })
        check("分类扫描响应取消", stopped.cancelled && stopped.items.isEmpty)
        let stoppedSearch = FileSystemService.searchReport(under: many, matching: "entry", cancelled: { true })
        check("搜索遍历响应取消", stoppedSearch.cancelled && stoppedSearch.items.isEmpty)
        let deep = root.appendingPathComponent("Deep")
        let nested = deep.appendingPathComponent("1/2/3/4/5/6/file.pdf")
        try fm.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: nested)
        let shallow = FileSystemService.categoryReport(.pdf, under: [deep])
        check("浅层扫描提示未扫描的深层目录", shallow.items.isEmpty && shallow.depthLimited)
        let deeper = FileSystemService.categoryReport(.pdf, under: [deep], depth: 12)
        check("深入扫描找到深层文件", deeper.items.count == 1 && !deeper.isPartial)
        let unavailable = FileSystemService.searchReport(under: root.appendingPathComponent("missing"), matching: "x")
        check("无法读取的位置有完整性报告", unavailable.inaccessibleCount == 1 && unavailable.isPartial)
        let model = BrowserModel(engine: engine, startDirectory: many, clipboardStore: clipboard)
        wait(model)
        model.search("entry-"); wait(model)
        check("搜索页提供加载更多入口", model.canExpandScan && model.displayedItems.count == 400)
        model.expandScan(); wait(model)
        check("加载更多扩大结果并保留查询", model.displayedItems.count == 1200 && model.searchQuery == "entry-")
        let other = root.appendingPathComponent("Other")
        let output = root.appendingPathComponent("Output")
        for dir in [other, output] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let first = target.appendingPathComponent("alpha.pdf")
        let second = other.appendingPathComponent("alpha.pdf")
        try Data("second".utf8).write(to: second)
        let archive = try ArchiveService.compress([first, second], to: output, name: "combined")
        let extracted = output.appendingPathComponent("Extracted")
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        _ = try ArchiveService.extract(archive, to: extracted)
        check("跨目录同名附件保留两份且内容正确", (try? Data(contentsOf: extracted.appendingPathComponent("Target/alpha.pdf"))) == Data("a".utf8)
            && (try? Data(contentsOf: extracted.appendingPathComponent("Other/alpha.pdf"))) == Data("second".utf8))
        let sizes = root.appendingPathComponent("Sizes")
        try fm.createDirectory(at: sizes, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1000).write(to: sizes.appendingPathComponent(".hidden"))
        try Data("x".utf8).write(to: sizes.appendingPathComponent("visible"))
        let measured = FileSystemService.directorySize(sizes)
        check("目录统计包含隐藏文件", measured.bytes == 1001 && measured.files == 2 && measured.isComplete)
        let partial = FileSystemService.directorySize(sizes, limit: 1)
        check("目录大小达到上限标注部分统计", !partial.isComplete && partial.files == 1)
        check("目录统计可取消", !FileSystemService.directorySize(sizes, cancelled: { true }).isComplete)
        let malformed = AndroidEntry.parseListOutput("-rw-r--r-- 1 user 1 2026-10-18", parent: "/tmp")
        check("安卓异常列数不会越界崩溃", malformed.isEmpty)
        let short = AndroidEntry.parseListOutput("-rw-r--r-- 1 user 1 2026-10-18 12:00 note.txt", parent: "/tmp")
        check("安卓缺失用户组列仍可解析", short.first?.name == "note.txt")
        check("本地删除菜单准确描述废纸篓", a.deleteActionTitle == L("action.moveToTrash", "移到废纸篓"))
    }

    @MainActor
    private static func testExperienceImprovements(_ sandbox: URL) throws {
        print("\n[扫描体验、任务、恢复与撤销]")
        let fm = FileManager.default
        let root = sandbox.resolvingSymlinksInPath().appendingPathComponent("Experience")
        let source = root.appendingPathComponent("Source")
        let target = root.appendingPathComponent("Target")
        for dir in [source, target] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let first = source.appendingPathComponent("a.txt")
        try Data("first".utf8).write(to: first)
        func item(_ url: URL) -> FileItem { FileItem(url: url, resourceKeys: FileSystemService.resourceKeys, showHidden: true)! }
        func spinUntil(_ finished: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
            while !finished() && Date() < deadline
        }
        var progress: [FileTransferProgress] = []
        let copied = FileTransferService.transfer([item(first)], to: target, mode: .copy, token: ScanCancellation()) { progress.append($0) }
        check("本地传输报告完成项目", copied.completed.count == 1 && copied.failures.isEmpty && !copied.cancelled)
        check("本地复制报告进度且保留源文件", progress.last?.completed == 1 && fm.fileExists(atPath: first.path))
        let cancel = ScanCancellation(); cancel.cancel()
        let cancelled = FileTransferService.transfer([item(first)], to: target, mode: .copy, token: cancel) { _ in }
        check("开始前取消不生成额外文件", cancelled.cancelled && cancelled.completed.isEmpty)
        let directory = source.appendingPathComponent("Folder")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: directory.appendingPathComponent("inside.txt"))
        let duringCopy = ScanCancellation()
        let interrupted = FileTransferService.transfer([item(directory)], to: target, mode: .copy, token: duringCopy) { update in
            if update.currentName == "inside.txt" { duringCopy.cancel() }
        }
        check("取消递归复制不提交不完整目录", interrupted.cancelled && !fm.fileExists(atPath: target.appendingPathComponent("Folder").path))
        let remnants = try fm.contentsOfDirectory(atPath: target.path).filter { $0.hasPrefix(".WinFile-transfer-") }
        check("取消后清除自己的传输暂存目录", remnants.isEmpty)
        let missing = source.appendingPathComponent("missing.txt")
        try Data("gone".utf8).write(to: missing)
        let missingItem = item(missing)
        try fm.removeItem(at: missing)
        let partial = FileTransferService.transfer([item(first), missingItem], to: target, mode: .copy, token: ScanCancellation()) { _ in }
        check("部分传输失败保留成功列表和失败明细", partial.completed.count == 1 && partial.failures.count == 1)
        let moving = source.appendingPathComponent("moving.txt")
        try Data("move".utf8).write(to: moving)
        let moved = FileTransferService.transfer([item(moving)], to: target, mode: .move, token: ScanCancellation()) { _ in }
        check("移动后记录可撤销的真实目标", moved.moves.count == 1 && moved.moves.first?.stillExists == true && !fm.fileExists(atPath: moving.path))
        let history = FileOperationHistory()
        history.record(title: "Move", moves: moved.moves)
        check("移动完成后可撤销", history.canUndo)
        // Occupying the original path must not overwrite a newer file.
        try Data("new original".utf8).write(to: moving)
        history.undo(); spinUntil { !history.isBusy }
        check("撤销冲突保留两端文件并允许重试", history.canUndo && history.errorMessage != nil && (try? Data(contentsOf: moving)) == Data("new original".utf8))
        try fm.removeItem(at: moving)
        history.errorMessage = nil
        history.undo(); spinUntil { !history.isBusy }
        check("移除冲突后撤销恢复原路径", !history.canUndo && (try? Data(contentsOf: moving)) == Data("move".utf8))
        let renamed = source.appendingPathComponent("renamed.txt")
        try fm.moveItem(at: first, to: renamed)
        let record = FileMoveRecord(original: first, current: renamed)!
        history.record(title: "Rename", moves: [record])
        history.undo(); spinUntil { !history.isBusy }
        check("撤销重命名恢复名称", fm.fileExists(atPath: first.path) && !fm.fileExists(atPath: renamed.path))
        let replacement = target.appendingPathComponent("replacement.txt")
        try fm.moveItem(at: first, to: replacement)
        let identity = FileMoveRecord(original: first, current: replacement)!
        try fm.moveItem(at: replacement, to: target.appendingPathComponent("kept-original.txt"))
        try Data("different file".utf8).write(to: replacement)
        let refused = FileOperationHistory.restore([identity])
        check("撤销不移动同路径上替换的新文件", refused.remaining.count == 1 && !fm.fileExists(atPath: first.path) && (try? Data(contentsOf: replacement)) == Data("different file".utf8))
        let engine = FSEngine(); engine.restrictScopeForTesting([source])
        let watching = BrowserModel(engine: engine, startDirectory: target)
        spinUntil { !watching.isBusy }
        watching.beginWatchingDirectory()
        let external = target.appendingPathComponent("external.txt")
        try Data("created outside".utf8).write(to: external)
        spinUntil { watching.displayedItems.contains { $0.id == FileItem.canonicalID(for: external) } }
        check("目录外部新增文件自动刷新", watching.displayedItems.contains { $0.id == FileItem.canonicalID(for: external) })
        let suite = "WinFileSessionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessionStore = BrowserSessionStore(defaults: defaults)
        let manager = TabManager(engine: engine, startDirectory: source, restoreSession: true, sessionStore: sessionStore)
        _ = manager.newTab(startDirectory: target)
        manager.persistNow()
        let loaded = sessionStore.load()
        check("会话保存页签与活动索引", loaded?.tabs.count == 2 && loaded?.activeIndex == 1)
        let restored = TabManager(engine: engine, startDirectory: nil, restoreSession: true, sessionStore: sessionStore)
        check("会话恢复活动目录", restored.count == 2 && restored.activeModel.currentDirectory?.path == target.path)
        spinUntil { !manager.activeModel.isBusy && !restored.activeModel.isBusy }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let nextFolder = root.appendingPathComponent("SessionNext")
        try fm.createDirectory(at: nextFolder, withIntermediateDirectories: true)
        manager.activeModel.selectFolder(nextFolder)
        spinUntil { sessionStore.load()?.tabs[1].path == nextFolder.path }
        check("新活动页签的导航自动保存会话", sessionStore.load()?.tabs[1].path == nextFolder.path)

        var invalid = loaded!
        invalid.tabs[1].path = root.appendingPathComponent("does-not-exist").path
        defaults.set(try JSONEncoder().encode(invalid), forKey: BrowserSessionStore.key)
        let fallback = TabManager(engine: engine, startDirectory: nil, restoreSession: true, sessionStore: sessionStore)
        check("会话中的失效目录回退主页", fallback.activeModel.isHomeView)
        defaults.set(Data("broken".utf8), forKey: BrowserSessionStore.key)
        check("损坏的会话数据安全忽略", sessionStore.load() == nil)
        let attachmentRoot = root.appendingPathComponent("Caches/WeChat")
        let paths = ["xwechat_files/wxid_a/msg/file/2026-09/a.pdf", "xwechat_files/wxid_a/cache/2026-10/thumb.jpg", "xwechat_files/wxid_b/msg/file/2026-10/b.pdf"]
        for name in paths {
            let url = attachmentRoot.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
        }
        var updates: [WeChatScanProgress] = []
        let scanned = WeChatCleanupService.scan(roots: [], explicitRoots: [attachmentRoot], onProgress: { updates.append($0) })
        let cleanup = WeChatCleanupModel(initialResult: scanned, homeDirectory: root, customRoots: [attachmentRoot])
        check("微信扫描进度包含文件数与空间", updates.last?.files == 3 && updates.last?.bytes == 21 && (updates.last?.visited ?? 0) > 0)
        check("微信识别账号与月份", cleanup.accounts == ["wxid_a", "wxid_b"] && cleanup.months == ["2026-10", "2026-09"])
        check("微信总占用统计所有已扫描附件", cleanup.totalSize == 21 && cleanup.matchingSize == 21)
        cleanup.account = "wxid_a"
        check("微信按账号筛选", cleanup.visibleFiles.count == 2)
        check("微信筛选占用不改变全部附件占用", cleanup.matchingSize == 14 && cleanup.totalSize == 21)
        cleanup.source = "cache"
        check("微信区分缓存缩略图与附件", cleanup.visibleFiles.count == 1 && cleanup.visibleFiles[0].isCache)
        cleanup.selection = Set(cleanup.visibleFiles.map(\.id))
        check("微信来源筛选与已选占用正确", cleanup.matchingSize == 7 && cleanup.selectedSize == 7)
        cleanup.source = "attachment"; cleanup.month = "2026-09"
        check("微信账号月份与来源组合筛选", cleanup.visibleFiles.count == 1 && cleanup.visibleFiles[0].url.lastPathComponent == "a.pdf")
        check("微信切换筛选后清除已选占用", cleanup.matchingSize == 7 && cleanup.selectedSize == 0)
        cleanup.month = "1900-01"
        check("微信空筛选占用为零且保留总占用", cleanup.matchingSize == 0 && cleanup.totalSize == 21)
        check("微信附件不受扫描根目录外的缓存路径影响", scanned.files.filter { !$0.isCache }.count == 2)
        let cacheRoot = attachmentRoot.appendingPathComponent("xwechat_files/wxid_a/cache")
        let cacheOnly = WeChatCleanupService.scan(roots: [], explicitRoots: [cacheRoot])
        check("直接扫描缓存文件夹仍识别缓存", cacheOnly.files.count == 1 && cacheOnly.files[0].isCache)
    }

    @MainActor
    private static func testMemoryAndPickerImprovements(_ sandbox: URL) throws {
        print("\n[内存、虚拟网格与内置选择器回归]")
        let root = sandbox.appendingPathComponent("MemoryRegression")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<16 { try Data("test".utf8).write(to: root.appendingPathComponent("file-\(i).txt")) }
        let metrics = IconGridMetrics(count: 16, width: 900)
        check("16 个图标分行后不丢失首尾条目", (0..<metrics.rows).flatMap { Array(metrics.indices(row: $0)) } == Array(0..<16))
        let large = IconGridMetrics(count: 100_000, width: 900)
        check("十万图标只创建可见区附近磁贴", large.visibleRows(offset: 20_000, viewport: 800).count * large.columns < 100)
        check("虚拟网格末行可见且不越界", large.visibleRows(offset: large.height - 800, viewport: 800).upperBound == large.rows && large.indices(row: large.rows - 1).upperBound == large.count)
        check("空网格和窄窗口几何有效", IconGridMetrics(count: 0, width: 0).visibleRows(offset: 0, viewport: 800).isEmpty && IconGridMetrics(count: 16, width: 50).columns == 1)
        let engine = FSEngine(); engine.restrictScopeForTesting([root])
        let model = BrowserModel(engine: engine, startDirectory: root)
        waitFor { !model.isBusy }
        check("普通目录不创建清理模块", model.initializedCleanupCount == 0)
        _ = AppUpdatePolicy.hasActiveFileOperations(in: [model])
        let saved = SavedBrowserTab(model: model)
        let restored = BrowserModel(engine: engine, startDirectory: nil)
        saved.apply(to: restored); waitFor { !restored.isBusy }
        check("会话保存恢复及更新检查不初始化清理模块", model.initializedCleanupCount == 0 && restored.initializedCleanupCount == 0)
        let file = model.items[0]
        model.selectedIDs = [file.id]
        check("闲置目录可回收条目", model.reclaimReadOnlyResults() && model.isSuspended && model.items.isEmpty)
        check("回收保留目录、选择和排序", model.currentDirectory == root && model.selectedIDs == [file.id])
        model.resumeReadOnlyResults(); waitFor { !model.isBusy }
        check("重新激活恢复目录条目和选择", !model.isSuspended && model.items.count == 16 && model.selectedIDs == [file.id])
        model.isBusy = true
        check("进行中的操作不可回收", !model.reclaimReadOnlyResults())
        model.isBusy = false
        _ = model.storageCleanup
        check("仅初始化访问的清理模块", model.initializedCleanupCount == 1)
        model.openPath("does-not-exist")
        waitFor { model.errorMessage != nil }
        check("无效地址显示错误且不跳到父目录", model.currentDirectory == root && model.items.count == 16 && model.errorMessage != nil)
        model.errorMessage = nil
        model.selectedIDs = []
        model.openPath(file.url.absoluteString)
        waitFor { model.selectedIDs == [file.id] && !model.isBusy }
        check("输入文件 URL 可定位所属目录中的文件", model.currentDirectory?.path == root.path && model.selectedIDs == [file.id], "directory=\(model.currentDirectory?.path ?? "nil"), selection=\(model.selectedIDs)")
        let absent = root.appendingPathComponent("removed")
        model.selectFolder(absent); waitFor { !model.isBusy }
        model.errorMessage = nil
        check("关闭错误弹窗后仍保留读取失败状态", model.directoryReadError != nil && model.items.isEmpty)
        try FileManager.default.createDirectory(at: absent, withIntermediateDirectories: true)
        model.reload(); waitFor { !model.isBusy }
        check("重试成功后恢复真正空目录状态", model.directoryReadError == nil && model.items.isEmpty)
        let denied = root.appendingPathComponent("Denied")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        model.selectFolder(denied); waitFor { !model.isBusy }
        check("权限不足目录显示读取错误而非空目录", model.directoryReadError != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
        model.selectFolder(absent); waitFor { !model.isBusy }
        do {
            _ = try FileSystemService.list(URL(fileURLWithPath: "/Volumes/WinFile-Unmounted-\(UUID().uuidString)/folder"), showHidden: false)
            check("未挂载磁盘提示连接后重试", false)
        } catch FSError.volumeUnavailable { check("未挂载磁盘提示连接后重试", true) }
        let picker = FolderPickerModel(initialDirectory: root)
        picker.navigate(to: root); waitFor { !picker.isLoading }
        check("内置选择器使用当前目录且不改变浏览页签", picker.candidates.map(\.path) == [root.path] && model.currentDirectory?.path == absent.path)
        let scan = WeChatCleanupService.scan(roots: [], explicitRoots: [root], candidateLimit: 5)
        check("微信扫描候选上限明确标记部分结果", scan.files.count == 5 && scan.limitReached && scan.isPartial)
        let visited = WeChatCleanupService.scan(roots: [], explicitRoots: [root], entryLimit: 3)
        check("微信扫描遍历上限可控且不误报全部完成", visited.visited == 3 && visited.visitLimitReached)
        let manager = TabManager(engine: engine, startDirectory: root)
        waitFor { !manager.activeModel.isBusy }
        let first = manager.activeTab
        let active = manager.newTab(startDirectory: root)
        waitFor { !active.model.isBusy }
        manager.reclaimInactiveTabs(immediately: true)
        check("内存压力只回收非活动页签", first.model.isSuspended && !active.model.isSuspended && active.model.items.count == 18)
        manager.select(first)
        waitFor { !first.model.isSuspended && !first.model.isBusy }
        check("切回被回收页签自动读取且保留身份", manager.activeTab.id == first.id && first.model.items.count == 18)
        var finished = false
        Task { @MainActor in
            let probe = ThumbnailTestProbe()
            let service = ThumbnailService(byteLimit: 6144, concurrencyLimit: 2, generator: { url, _ in await probe.generate(url) })
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<12 { group.addTask { _ = await service.thumbnail(for: root.appendingPathComponent("\(i)"), size: 44) } }
            }
            let stats = await service.statistics()
            let peak = await probe.peak
            check("缩略图并发不超过设定的两个任务", peak == 2 && stats.running == 0 && stats.queued == 0)
            check("缩略图缓存按字节预算回收", stats.bytes <= 6144 && stats.cached <= 3 && stats.cached > 0)
            let url = root.appendingPathComponent("shared")
            async let a = service.thumbnail(for: url, size: 44)
            async let b = service.thumbnail(for: url, size: 44)
            _ = await (a, b)
            let sharedCount = await probe.count(for: url)
            check("相同缩略图请求合并生成", sharedCount == 1)
            _ = await service.thumbnail(for: url, size: 44)
            let hitCount = await probe.count(for: url)
            check("缓存命中不重复生成", hitCount == 1)
            _ = await service.thumbnail(for: url, size: 44, version: "changed")
            let updatedCount = await probe.count(for: url)
            check("文件版本变化重新生成缩略图", updatedCount == 2)
            let cancelURL = root.appendingPathComponent("cancel")
            let leaving = Task { await service.thumbnail(for: cancelURL, size: 44) }
            let staying = Task { await service.thumbnail(for: cancelURL, size: 44) }
            try? await Task.sleep(nanoseconds: 10_000_000)
            leaving.cancel()
            let cancelledBox = await leaving.value
            let keptBox = await staying.value
            check("单个消费者取消不会中断其他消费者", cancelledBox.image == nil && keptBox.image != nil)
            let lru = ThumbnailService(byteLimit: 4096, concurrencyLimit: 1, generator: { url, _ in await probe.generate(url) })
            let one = root.appendingPathComponent("LRU-1"), two = root.appendingPathComponent("LRU-2"), three = root.appendingPathComponent("LRU-3")
            _ = await lru.thumbnail(for: one, size: 44)
            _ = await lru.thumbnail(for: two, size: 44)
            _ = await lru.thumbnail(for: one, size: 44)
            _ = await lru.thumbnail(for: three, size: 44)
            _ = await lru.thumbnail(for: one, size: 44)
            _ = await lru.thumbnail(for: two, size: 44)
            let oneCount = await probe.count(for: one), twoCount = await probe.count(for: two)
            check("LRU 保留最近访问而非整体清空", oneCount == 1 && twoCount == 2)
            let allCancelled = (0..<8).map { i in Task { await service.thumbnail(for: root.appendingPathComponent("cancel-all-\(i)"), size: 44) } }
            try? await Task.sleep(nanoseconds: 10_000_000)
            for task in allCancelled { task.cancel() }
            for task in allCancelled { _ = await task.value }
            try? await Task.sleep(nanoseconds: 50_000_000)
            let cancelledStats = await service.statistics()
            check("队列和运行请求取消后全部释放", cancelledStats.running == 0 && cancelledStats.queued == 0)
            await service.removeCachedImages()
            let empty = await service.statistics()
            check("内存压力可释放全部缩略图缓存", empty.bytes == 0 && empty.cached == 0)
            finished = true
        }
        waitFor({ finished }, timeout: 10)
        check("缩略图异步回归完整结束", finished)
    }

    @MainActor
    private static func testLayoutAndFilterExperience(_ sandbox: URL) throws {
        print("\n[工具栏、筛选与宽度记忆]")
        func spinUntil(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        let engine = FSEngine()
        engine.restrictScopeForTesting([sandbox])
        let browser = BrowserModel(engine: engine, startDirectory: sandbox)
        spinUntil { !browser.isBusy }
        check("本地目录显示搜索、新建与列表工具", browser.supportsDirectorySearch && browser.supportsDirectoryCreation && browser.showsFileList)
        browser.navigate(to: .weChatCleanup)
        check("微信页隐藏目录搜索、新建与显示模式", !browser.supportsDirectorySearch && !browser.supportsDirectoryCreation && !browser.showsFileList)
        browser.weChatCleanup.cancelScan()
        browser.navigate(to: .home)
        check("主页隐藏目录专属工具", !browser.supportsDirectorySearch && !browser.supportsDirectoryCreation && !browser.showsFileList)
        browser.navigate(to: .category(.document))
        check("分类保留显示排序但隐藏目录搜索与新建", browser.showsFileList && !browser.supportsDirectorySearch && !browser.supportsDirectoryCreation)

        let root = sandbox.appendingPathComponent("FilterFixtures")
        let oldDate = Date().addingTimeInterval(-200 * 86400)
        let a = WeChatFile(url: root.appendingPathComponent("wxid_a/msg/file/2026-09/file2.pdf"), root: root,
                           kind: .document, size: 20 * 1024 * 1024, modified: oldDate)
        let b = WeChatFile(url: root.appendingPathComponent("wxid_b/cache/2026-10/file10.jpg"), root: root,
                           kind: .image, size: 1, modified: Date())
        let cleanup = WeChatCleanupModel(initialResult: WeChatScanResult(files: [b, a], roots: [root]), customRoots: [])
        cleanup.search = "file2"; cleanup.kind = "document"; cleanup.account = "wxid_a"
        cleanup.month = "2026-09"; cleanup.source = "attachment"; cleanup.minimumMB = 10; cleanup.olderThanDays = 90
        check("七项筛选可同时生效且高级条件计数正确", cleanup.activeFilters.count == 7 && cleanup.advancedFilterCount == 5 && cleanup.visibleFiles.map(\.id) == [a.id])
        check("每个启用条件都有可读标签", cleanup.activeFilters.allSatisfy { !cleanup.filterTitle($0).isEmpty })
        cleanup.selection = [a.id]
        cleanup.clearFilter(.account)
        check("单独移除账号保留其他条件并清除选择", cleanup.account == "all" && cleanup.activeFilters.count == 6 && cleanup.search == "file2" && cleanup.selection.isEmpty)
        cleanup.sort = "name"; cleanup.sortAscending = false
        cleanup.resetFilters()
        check("一键清除全部筛选并恢复完整统计", cleanup.activeFilters.isEmpty && cleanup.advancedFilterCount == 0 && cleanup.matchingCount == 2 && cleanup.matchingSize == a.size + b.size)
        check("重置筛选保留排序、扫描位置与扫描结果", cleanup.sort == "name" && !cleanup.sortAscending && cleanup.result.roots == [root] && cleanup.result.files.count == 2)
        for filter in WeChatCleanupModel.Filter.allCases {
            cleanup.search = "file"; cleanup.kind = "document"; cleanup.account = "wxid_a"
            cleanup.month = "2026-09"; cleanup.source = "attachment"; cleanup.minimumMB = 10; cleanup.olderThanDays = 90
            cleanup.clearFilter(filter)
            check("移除单个筛选 \(filter.rawValue)", cleanup.activeFilters.count == 6 && !cleanup.activeFilters.contains(filter))
        }
        cleanup.resetFilters()
        cleanup.sort = "name"; cleanup.sortAscending = true
        check("微信名称表头使用自然顺序", cleanup.visibleFiles.map(\.name) == ["file2.pdf", "file10.jpg"])
        cleanup.selection = [a.id]
        cleanup.sortAscending = false
        check("微信反向排序刷新缓存且保留选择", cleanup.visibleFiles.map(\.id) == [b.id, a.id] && cleanup.selection == [a.id])
        cleanup.sort = "size"
        check("微信大小默认降序", cleanup.visibleFiles.map(\.id) == [a.id, b.id] && !cleanup.sortAscending)
        cleanup.sortAscending = true
        check("微信大小支持升序", cleanup.visibleFiles.map(\.id) == [b.id, a.id])
        cleanup.sort = "date"
        check("微信日期默认从新到旧", cleanup.visibleFiles.map(\.id) == [b.id, a.id])
        cleanup.sortAscending = true
        check("微信日期支持从旧到新", cleanup.visibleFiles.map(\.id) == [a.id, b.id])
        cleanup.sort = "location"
        check("微信目录列支持排序", cleanup.visibleFiles.map(\.id) == [a.id, b.id])
        for field in WeChatSortOrderBridge.fields {
            for ascending in [true, false] {
                let comparator = WeChatSortOrderBridge.comparator(for: field, ascending: ascending)
                check("微信表头字段与方向映射 \(field) \(ascending)", WeChatSortOrderBridge.field(for: comparator) == field && comparator.order == (ascending ? .forward : .reverse))
            }
        }
        for field in SortField.allCases {
            let comparator = SortOrderBridge.comparator(for: field, ascending: false)
            check("文件表头字段反向映射 \(field.rawValue)", SortOrderBridge.field(for: comparator) == field && comparator.order == .reverse)
        }
        check("微信排序后双击使用当前行", cleanup.itemForActivation(at: 0)?.id == a.id)
        let tie = WeChatFile(url: root.appendingPathComponent("wxid_b/msg/file2.pdf"), root: root,
                             kind: .document, size: a.size, modified: a.modified)
        let ties = WeChatCleanupModel(initialResult: WeChatScanResult(files: [tie, a], roots: [root]), customRoots: [])
        ties.sort = "name"
        let stable = ties.visibleFiles.map(\.id)
        ties.sortAscending.toggle()
        check("同名值排序有稳定路径次序", stable == ties.visibleFiles.map(\.id) && stable == [a.id, tie.id])

        let full = PaneLayout.widths(total: 1180, sidebar: 216, inspector: 264, showsInspector: true)
        check("宽窗口保留首选侧栏宽度", full.sidebar == 216 && full.inspector == 264)
        let narrow = PaneLayout.widths(total: 860, sidebar: 360, inspector: 420, showsInspector: true)
        check("窄窗口给内容保留至少四百点", narrow.sidebar >= 160 && narrow.inspector >= 200 && narrow.sidebar + narrow.inspector + 12 <= 460.01)
        let hidden = PaneLayout.widths(total: 860, sidebar: 360, inspector: 420, showsInspector: false)
        check("隐藏检查器释放空间", hidden.sidebar == 360 && hidden.inspector == 0)
        let sidebarHidden = PaneLayout.widths(total: 860, sidebar: 360, inspector: 420, showsInspector: true, showsSidebar: false)
        check("折叠左侧栏释放全部侧栏空间且保留检查器首选宽度", sidebarHidden.sidebar == 0 && sidebarHidden.inspector == 420)
        let allHidden = PaneLayout.widths(total: 860, sidebar: 360, inspector: 420, showsInspector: false, showsSidebar: false)
        check("两侧栏隐藏时无残余栏宽", allHidden.sidebar == 0 && allHidden.inspector == 0)
        let smallSidebarHidden = PaneLayout.widths(total: 560, sidebar: 360, inspector: 420, showsInspector: true, showsSidebar: false)
        check("折叠左侧栏后窄窗口仍为内容保留四百点", smallSidebarHidden.sidebar == 0 && smallSidebarHidden.inspector >= 0 && smallSidebarHidden.inspector + PaneLayout.divider <= 160.01)
        let invalid = PaneLayout.widths(total: 1180, sidebar: .nan, inspector: .infinity, showsInspector: true)
        check("损坏布局偏好回退默认宽度", invalid.sidebar == 216 && invalid.inspector == 264)
        let limited = PaneLayout.widths(total: 2000, sidebar: -5, inspector: 5000, showsInspector: true)
        check("首选宽度限定合理范围", limited.sidebar == 160 && limited.inspector == 420)

        let suite = "WinFileLayoutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func table() -> NSTableView {
            let result = NSTableView()
            for name in ["name", "size"] {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
                column.minWidth = 70; column.maxWidth = 400; column.width = 100
                result.addTableColumn(column)
            }
            return result
        }
        let first = table()
        TableColumnPreferences.install(on: first, kind: "files", defaults: defaults)
        check("列宽记忆安装到指定表格", TableColumnPreferences.isInstalled(on: first, kind: "files"))
        TableColumnPreferences.install(on: first, kind: "wechat", defaults: defaults)
        check("复用底层表格时切换正确的列宽配置", TableColumnPreferences.isInstalled(on: first, kind: "wechat") && !TableColumnPreferences.isInstalled(on: first, kind: "files"))
        let prefs = TableColumnPreferences(table: first, kind: "test", defaults: defaults)
        first.tableColumns[0].width = 245; first.tableColumns[1].width = 130
        prefs.save()
        let recreated = table()
        let restored = TableColumnPreferences(table: recreated, kind: "test", defaults: defaults)
        check("重建表格恢复两列用户宽度", recreated.tableColumns.map(\.width) == [245, 130])
        let separate = table()
        let other = TableColumnPreferences(table: separate, kind: "other", defaults: defaults)
        check("普通文件和微信列表宽度分别保存", separate.tableColumns.map(\.width) == [100, 100])
        defaults.set([10.0, 9999.0], forKey: "Layout.Columns.test.v1")
        let clampedTable = table()
        let clamped = TableColumnPreferences(table: clampedTable, kind: "test", defaults: defaults)
        check("恢复列宽遵守最小最大值", clampedTable.tableColumns.map(\.width) == [70, 400])
        defaults.set([10.0], forKey: "Layout.Columns.test.v1")
        let mismatchTable = table()
        let mismatch = TableColumnPreferences(table: mismatchTable, kind: "test", defaults: defaults)
        check("列定义变化时忽略不匹配宽度", mismatchTable.tableColumns.map(\.width) == [100, 100])
        let nativeTable = table()
        let nativePrefs = TableColumnPreferences(table: nativeTable, kind: "native", defaults: defaults, userResize: { _ in true })
        nativeTable.tableColumns[0].width = 230
        NotificationCenter.default.post(name: NSTableView.columnDidResizeNotification, object: nativeTable)
        check("原生表格列宽通知会保存宽度", defaults.array(forKey: "Layout.Columns.native.v1") as? [Double] == [230, 100])
        let outline = NSOutlineView()
        let outlineColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outlineColumn.width = 280; outline.addTableColumn(outlineColumn)
        let outlinePrefs = TableColumnPreferences(table: outline, kind: "outline", defaults: defaults, userResize: { _ in true })
        NotificationCenter.default.post(name: NSOutlineView.columnDidResizeNotification, object: outline)
        check("SwiftUI 大纲表格使用独立列宽通知", defaults.array(forKey: "Layout.Columns.outline.v1") as? [Double] == [280])
        withExtendedLifetime([nativePrefs, outlinePrefs]) {}
        withExtendedLifetime([prefs, restored, other, clamped, mismatch]) {}
    }

    @MainActor
    private static func testRemainingImprovements(_ sandbox: URL) throws {
        print("\n[导航、会话、页签与整理工具]")
        let fm = FileManager.default
        let root = sandbox.resolvingSymlinksInPath().appendingPathComponent("Remaining")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        func file(_ name: String, _ contents: Data) throws -> URL {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url)
            return url
        }
        let a = try file("Rename/Item-001.txt", Data("first".utf8))
        let b = try file("Rename/Item-002.txt", Data("second".utf8))
        let originalItems = try FileSystemService.list(a.deletingLastPathComponent(), showHidden: true)
        let plain = BatchRenameService.preview(originalItems, rules: BatchRenameRules())
        check("批量重命名无变化时不能提交", !plain.canApply)
        var rules = BatchRenameRules(); rules.prefix = "照片_"; rules.suffix = "_完成"
        let prefixed = BatchRenameService.preview(originalItems, rules: rules)
        check("重命名预览保留扩展名且不修改文件", prefixed.entries[0].target.lastPathComponent == "照片_Item-001_完成.txt" && fm.fileExists(atPath: a.path))
        rules.prefix = "invalid/"
        check("批量重命名拒绝非法路径", !BatchRenameService.preview(originalItems, rules: rules).canApply)
        rules = BatchRenameRules(); rules.numbered = true; rules.baseName = "Item"
        let reverse = BatchRenameService.preview(Array(originalItems.reversed()), rules: rules)
        check("批次允许目标属于同批源文件的名称交换", reverse.canApply)
        let renamed = BatchRenameService.apply(reverse)
        check("两阶段批量改名正确交换内容", renamed.errors.isEmpty && renamed.moves.count == 2 && (try? Data(contentsOf: a)) == Data("second".utf8) && (try? Data(contentsOf: b)) == Data("first".utf8))
        let undone = BatchRenameService.undo(renamed.moves)
        check("批量改名交换可整体撤销", undone.remaining.isEmpty && undone.errors.isEmpty && (try? Data(contentsOf: a)) == Data("first".utf8) && (try? Data(contentsOf: b)) == Data("second".utf8))
        rules = BatchRenameRules(); rules.prefix = "new_"
        let conflictPlan = BatchRenameService.preview(originalItems, rules: rules)
        let occupied = conflictPlan.entries[1].target
        try Data("external".utf8).write(to: occupied)
        let conflicted = BatchRenameService.apply(conflictPlan)
        check("预览后出现目标冲突时回滚整批", !conflicted.errors.isEmpty && conflicted.moves.isEmpty && fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path) && (try? Data(contentsOf: occupied)) == Data("external".utf8))
        check("改名回滚不遗留隐藏暂存项", try fm.contentsOfDirectory(atPath: a.deletingLastPathComponent().path).allSatisfy { !$0.hasPrefix(".WinFile-rename-") })
        try fm.removeItem(at: occupied)
        let replacedPlan = BatchRenameService.preview(originalItems, rules: rules)
        try Data("replacement".utf8).write(to: a, options: .atomic)
        check("预览后源文件被替换时拒绝整批改名", !BatchRenameService.apply(replacedPlan).errors.isEmpty && fm.fileExists(atPath: b.path))
        let duplicateA = try file("Collisions/a.txt", Data())
        _ = try file("Collisions/aa.txt", Data())
        rules = BatchRenameRules(); rules.find = "a"
        check("预览识别批次内目标重名", !BatchRenameService.preview(try FileSystemService.list(duplicateA.deletingLastPathComponent(), showHidden: true), rules: rules).canApply)

        let content = Data(repeating: 0x41, count: 2 * 1024 * 1024)
        let one = try file("Duplicates/a.bin", content)
        _ = try file("Duplicates/sub/b.bin", content)
        _ = try file("Duplicates/c.bin", content)
        _ = try file("Duplicates/other.bin", Data(repeating: 0x42, count: content.count))
        _ = try file("Duplicates/empty1", Data()); _ = try file("Duplicates/empty2", Data())
        try fm.linkItem(at: one, to: one.deletingLastPathComponent().appendingPathComponent("hardlink.bin"))
        try fm.createSymbolicLink(at: one.deletingLastPathComponent().appendingPathComponent("alias.bin"), withDestinationURL: one)
        let duplicates = DuplicateFileService.scan(one.deletingLastPathComponent(), token: ScanCancellation())
        check("重复文件按完整内容而非大小分组", duplicates.groups.count == 2 && duplicates.groups.first?.files.count == 3)
        check("重复统计排除同一文件硬链接", duplicates.groups.reduce(Int64(0)) { $0 + $1.redundantBytes } == Int64(content.count * 2))
        check("重复扫描跳过符号链接", duplicates.groups.flatMap(\.files).allSatisfy { $0.lastPathComponent != "alias.bin" })
        check("空文件可作为重复内容分组", duplicates.groups.contains { $0.size == 0 && $0.files.count == 2 })
        let cancelled = ScanCancellation(); cancelled.cancel()
        check("重复查找预先取消立即停止", DuplicateFileService.scan(root, token: cancelled).cancelled)
        check("重复查找达到遍历上限明确标注", DuplicateFileService.scan(root, limit: 1, token: ScanCancellation()).limited)

        let nestedRoot = root.appendingPathComponent("DuplicateSymlinkSiblings")
        for index in 0..<12 {
            let original = try file("DuplicateSymlinkSiblings/folder-\(index)/copy.bin", Data("sibling duplicate".utf8))
            try fm.createSymbolicLink(at: nestedRoot.appendingPathComponent("alias-\(index)"), withDestinationURL: original)
        }
        let siblingDuplicates = DuplicateFileService.scan(nestedRoot, token: ScanCancellation())
        check("符号链接不会导致相邻真实目录漏扫", siblingDuplicates.groups.count == 1 && siblingDuplicates.groups.first?.files.count == 12)

        let boundaryRoot = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let boundary = BrowserInteractionBoundary.BoundaryView(frame: NSRect(x: 200, y: 400, width: 400, height: 34))
        boundaryRoot.addSubview(boundary)
        check("页签区域不被文件背景右键菜单拦截", EmptyAreaContextMenu.InstallerView.isExcluded(NSPoint(x: 300, y: 415), in: boundaryRoot))
        check("页签排除标记不影响文件区域右键", !EmptyAreaContextMenu.InstallerView.isExcluded(NSPoint(x: 300, y: 300), in: boundaryRoot))

        let engine = FSEngine(); engine.restrictScopeForTesting([root])
        let model = BrowserModel(engine: engine, startDirectory: root)
        wait { !model.isBusy }
        model.loadHome(); model.selectFolder(a.deletingLastPathComponent())
        wait { !model.isBusy }
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        let folders = model.items.filter(\.isContainer).count
        let expectedStatus = String(format: WLocalizedString("status.itemCount", comment: "项目统计"), model.items.count, folders, model.items.count - folders)
        check("离开主页后旧任务不回写忙碌状态或提示", model.currentDirectory?.path == a.deletingLastPathComponent().path && !model.isBusy && !model.isLoadingHome && model.statusMessage == expectedStatus,
              "dir=\(model.currentDirectory?.path ?? "nil") busy=\(model.isBusy) home=\(model.isLoadingHome) status=\(model.statusMessage) expected=\(expectedStatus)")
        var criteria = FileSearchCriteria(minimumBytes: 1024 * 1024, maximumBytes: 3 * 1024 * 1024)
        model.selectFolder(one.deletingLastPathComponent()); wait { !model.isBusy }
        model.searchCriteria = criteria; model.search(""); wait { !model.isBusy }
        check("无需名称即可按文件大小搜索", model.isSearching && model.displayedItems.count == 5 && model.displayedItems.allSatisfy { ($0.size ?? 0) >= 1024 * 1024 })
        criteria.maximumBytes = 10
        check("组合搜索拒绝反向大小范围", !criteria.isValid)
        let listed = try FileSystemService.list(one.deletingLastPathComponent(), showHidden: true)
        guard let sample = listed.first(where: { $0.id == FileItem.canonicalID(for: one) }) else { throw CocoaError(.fileReadNoSuchFile) }
        let future = FileSearchCriteria(modifiedAfter: Date().addingTimeInterval(100))
        check("组合搜索按日期范围过滤", !future.matches(sample))
        let small = FileSystemService.searchReport(under: one.deletingLastPathComponent(), matching: "empty", criteria: FileSearchCriteria(maximumBytes: 0))
        check("名称与大小条件同时满足", small.items.count == 2)

        let suite = "WinFileRemaining-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowserSessionStore(defaults: defaults)
        let manager = TabManager(engine: engine, startDirectory: one.deletingLastPathComponent(), restoreSession: true, sessionStore: store)
        wait { !manager.activeModel.isBusy }
        manager.activeModel.layout = .icons; manager.activeModel.sortField = .size; manager.activeModel.sortAscendingFlag = false
        manager.activeModel.searchCriteria = FileSearchCriteria(minimumBytes: 1024)
        manager.activeModel.search(".bin"); wait { !manager.activeModel.isBusy }
        let first = manager.activeTab
        let second = manager.newTab(startDirectory: a.deletingLastPathComponent())
        second.model.layout = .details; second.model.sortField = .name; second.model.sortAscendingFlag = true
        check("各页签显示设置彼此独立", first.model.layout == .icons && first.model.sortField == .size && !first.model.sortAscendingFlag && second.model.layout == .details)
        manager.togglePin(first)
        check("固定页签排序在前且保留活动页签", manager.tabs.first?.id == first.id && manager.activeID == second.id)
        manager.close(first)
        check("固定页签不能误关闭", manager.count == 2)
        let visible = manager.visibleTabs(width: 260)
        check("溢出布局始终显示当前页签", visible.count == 1 && visible[0].id == second.id)
        manager.close(second)
        check("关闭页签进入恢复栈", manager.closedTabs.count == 1 && manager.activeID == first.id)
        manager.restoreClosedTab()
        check("恢复关闭页签的路径与显示状态", manager.count == 2 && manager.activeModel.currentDirectory == a.deletingLastPathComponent() && manager.activeModel.layout == .details)
        manager.select(first); manager.persistNow()
        let restored = TabManager(engine: engine, startDirectory: nil, restoreSession: true, sessionStore: store)
        wait { !restored.activeModel.isBusy }
        check("重启恢复搜索词及组合条件并重新搜索", restored.activeModel.isSearching && restored.activeModel.searchQuery == ".bin" && restored.activeModel.searchCriteria.minimumBytes == 1024 && !restored.activeModel.displayedItems.isEmpty)
        check("重启恢复固定页签和独立显示设置", restored.activeTab.isPinned && restored.activeModel.layout == .icons && restored.tabs.last?.model.layout == .details)
        restored.activeModel.clearSearch(); wait { !restored.activeModel.isBusy }
        check("恢复搜索后清空可看到真实目录", !restored.activeModel.isSearching && !restored.activeModel.items.isEmpty)
        let wechat = manager.newTab(); wechat.model.navigate(to: .weChatCleanup)
        wechat.model.weChatCleanup.search = "invoice"; wechat.model.weChatCleanup.kind = "document"
        wechat.model.weChatCleanup.month = "2026-10"; wechat.model.weChatCleanup.minimumMB = 10
        wechat.model.weChatCleanup.sort = "name"; wechat.model.weChatCleanup.sortAscending = false
        manager.persistNow()
        let restoreWeChat = TabManager(engine: engine, startDirectory: nil, restoreSession: true, sessionStore: store)
        check("重启恢复微信筛选和方向", restoreWeChat.activeModel.isWeChatCleanupView && restoreWeChat.activeModel.weChatCleanup.filterState == wechat.model.weChatCleanup.filterState)
        let oldJSON = Data("{\"kind\":\"home\",\"sort\":\"name\",\"ascending\":true,\"layout\":\"details\",\"query\":\"\"}".utf8)
        check("新增会话字段兼容旧记录", (try? JSONDecoder().decode(SavedBrowserTab.self, from: oldJSON))?.destination == .home)

        print("\n[实际字节传输与中途取消]")
        let transferSource = try file("Copy/source.bin", Data(repeating: 0x5a, count: 16 * 1024 * 1024))
        let copyItems = try FileSystemService.list(transferSource.deletingLastPathComponent(), showHidden: true)
        let output = root.appendingPathComponent("CopyOutput"); try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let cancelCopy = ScanCancellation()
        var bytesSeen: Int64 = 0
        let interrupted = FileTransferService.transfer(copyItems, to: output, mode: .copy, token: cancelCopy) { update in
            bytesSeen = max(bytesSeen, update.completedBytes)
            if update.completedBytes > 0 && update.completed == 0 { cancelCopy.cancel() }
        }
        check("复制单个大文件可中途取消", interrupted.cancelled && interrupted.completed.isEmpty && bytesSeen > 0)
        check("中止复制不提交残缺目标且可重试", !fm.fileExists(atPath: output.appendingPathComponent("source.bin").path) && interrupted.retryURLs.map { FileItem.canonicalID(for: $0) } == [FileItem.canonicalID(for: transferSource)])
        check("中途取消清除私有暂存目录", try fm.contentsOfDirectory(atPath: output.path).isEmpty)
        var updates: [FileTransferProgress] = []
        let copied = FileTransferService.transfer(copyItems, to: output, mode: .copy, token: ScanCancellation()) { updates.append($0) }
        check("传输完成实际字节数与总数一致", copied.failures.isEmpty && updates.last?.completedBytes == 16 * 1024 * 1024 && updates.last?.totalBytes == 16 * 1024 * 1024)
        check("结果保留目标目录且只重试未完成项", copied.destination == output && copied.retryURLs.isEmpty && !copied.isMoving)
        guard let copiedURL = copied.completed.first else { throw CocoaError(.fileReadNoSuchFile) }
        check("复制后内容字节正确", try Data(contentsOf: copiedURL) == Data(contentsOf: transferSource))
        let link = transferSource.deletingLastPathComponent().appendingPathComponent("link.bin")
        try fm.createSymbolicLink(at: link, withDestinationURL: transferSource)
        let linkItems = try FileSystemService.list(link.deletingLastPathComponent(), showHidden: true).filter { $0.name == link.lastPathComponent }
        let linkResult = FileTransferService.transfer(linkItems, to: output, mode: .copy, token: ScanCancellation()) { _ in }
        check("字节进度复制保留符号链接本身", linkResult.failures.isEmpty && (try? fm.destinationOfSymbolicLink(atPath: output.appendingPathComponent("link.bin").path)) == (try? fm.destinationOfSymbolicLink(atPath: link.path)), "items=\(linkItems.count), errors=\(linkResult.failures)")

        let retryBoard = NSPasteboard(name: NSPasteboard.Name("WinFileRetry-\(UUID().uuidString)"))
        let retryClipboard = FileClipboard(pasteboard: retryBoard, monitor: false)
        let retryDestination = root.appendingPathComponent("RetryOutput")
        try fm.createDirectory(at: retryDestination, withIntermediateDirectories: true)
        let retryModel = BrowserModel(engine: engine, startDirectory: retryDestination, clipboardStore: retryClipboard)
        wait { !retryModel.isBusy }
        let moveOne = try file("RetrySources/one.txt", Data("one".utf8))
        let missingTwo = moveOne.deletingLastPathComponent().appendingPathComponent("two.txt")
        retryClipboard.write(ClipboardPayload(mode: .cut, urls: [moveOne, missingTwo]))
        retryModel.paste(); wait { retryModel.fileTransferProgress == nil && !retryModel.isBusy }
        try Data("two".utf8).write(to: missingTwo)
        retryModel.retryFileTransfer(); wait { retryModel.fileTransferProgress == nil && !retryModel.isBusy }
        check("部分移动重试成功后清理原剪切状态", retryModel.lastTransferOutcome?.failures.isEmpty == true && retryClipboard.localPayload == nil && fm.fileExists(atPath: retryDestination.appendingPathComponent("two.txt").path))
        let missingThree = moveOne.deletingLastPathComponent().appendingPathComponent("three.txt")
        retryClipboard.write(ClipboardPayload(mode: .cut, urls: [missingThree]))
        retryModel.paste(); wait { retryModel.fileTransferProgress == nil && !retryModel.isBusy }
        retryClipboard.write(ClipboardPayload(mode: .copy, urls: [one]))
        try Data("three".utf8).write(to: missingThree)
        retryModel.retryFileTransfer(); wait { retryModel.fileTransferProgress == nil && !retryModel.isBusy }
        check("重试移动不清空后来复制的新剪贴板", retryClipboard.localPayload?.urls == [one] && retryModel.lastTransferOutcome?.failures.isEmpty == true)
        for _ in 0..<31 { _ = manager.newTab(startDirectory: root); manager.activeModel.layout = .details }
        manager.activeModel.layout = .icons; manager.persistNow()
        let capped = store.load()
        check("超过会话上限仍保留活动页签及固定页签", capped?.tabs.count == 30 && capped?.activeIndex == 29 && capped?.tabs.last?.layout == "icons" && capped?.tabs.first?.pinned == true)
        let lastManager = TabManager(engine: engine, startDirectory: root)
        lastManager.close(lastManager.activeTab)
        check("关闭最后页签不会出现空管理器状态", lastManager.count == 1 && lastManager.activeModel.isHomeView && lastManager.closedTabs.count == 1)
        wait { manager.tabs.allSatisfy { !$0.model.isBusy } && !lastManager.activeModel.isBusy }

        let scannedRoot = root.appendingPathComponent("WeChatLocal")
        try fm.createDirectory(at: scannedRoot, withIntermediateDirectories: true)
        try Data("report".utf8).write(to: scannedRoot.appendingPathComponent("report.pdf"))
        let cleanup = WeChatCleanupModel(homeDirectory: root, customRoots: [scannedRoot])
        cleanup.scan(); wait { !cleanup.isScanning }
        check("微信扫描完成记录扫描时间", cleanup.lastScanDate != nil && cleanup.result.files.count == 1)
        check("微信按类型占用分布汇总正确", cleanup.usageBuckets(byMonth: false).first?.bytes == 6 && cleanup.usageBuckets(byMonth: false).first?.id == "document")
        check("微信按月份占用分布汇总正确", cleanup.usageBuckets(byMonth: true).reduce(0) { $0 + $1.count } == cleanup.matchingCount)
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
        let fm = FileManager.default

        let folder = try FSEngine.createFolder(in: sandbox, named: "新建文件夹")
        check("创建文件夹", fm.fileExists(atPath: folder.path))
        let second = try FSEngine.createFolder(in: sandbox, named: "新建文件夹")
        check("重名自动加序号", second.lastPathComponent == "新建文件夹 2", second.lastPathComponent)

        let file = try FSEngine.createTextFile(in: sandbox, named: "笔记.txt", contents: "内容A")
        check("创建文件并写入内容", (try? String(contentsOf: file, encoding: .utf8)) == "内容A")

        let renamed = try FSEngine.rename(item(file), to: "笔记-改.txt")
        check("重命名成功", fm.fileExists(atPath: renamed.path))
        do {
            _ = try FSEngine.rename(item(renamed), to: "非法/名称")
            check("非法名称应被拒绝", false)
        } catch {
            check("非法名称被拒绝", true)
        }
        do {
            _ = try FSEngine.rename(item(renamed), to: "非法:名称")
            check("含冒号的名称应被拒绝", false)
        } catch {
            check("含冒号的名称被拒绝", true)
        }

        let target = try FSEngine.createFolder(in: sandbox, named: "目标")
        let copied = try FSEngine.transfer([item(renamed)], to: target, mode: .copy)
        check("复制到目标目录", copied.count == 1 && fm.fileExists(atPath: copied[0].path))
        check("复制后原文件仍在", fm.fileExists(atPath: renamed.path))

        let moved = try FSEngine.transfer([item(copied[0])], to: sandbox, mode: .move)
        check("移动回上级目录", moved.count == 1 && fm.fileExists(atPath: moved[0].path))
        check("移动后原位置消失", !fm.fileExists(atPath: copied[0].path))

        do {
            _ = try FSEngine.transfer([item(target)], to: target, mode: .copy)
            check("拒绝复制到自身", false)
        } catch {
            check("拒绝把文件夹复制进它自己", true)
        }
        let nested = target.appendingPathComponent("内层")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        do {
            _ = try FSEngine.transfer([item(target)], to: nested, mode: .move)
            check("拒绝移动到子目录", false)
        } catch {
            check("拒绝把文件夹移动进它的子目录", true)
        }

        let duplicated = try FSEngine.duplicate([item(renamed)])
        check("制作副本", duplicated.count == 1 && fm.fileExists(atPath: duplicated[0].path))
        check("副本名称含“副本”", duplicated[0].lastPathComponent.contains("副本"), duplicated[0].lastPathComponent)

        let trashCandidate = try FSEngine.createTextFile(in: sandbox, named: "待删除.txt")
        try FSEngine.moveToTrash([item(trashCandidate)])
        check("移到废纸篓后原位置消失", !fm.fileExists(atPath: trashCandidate.path))

        let size = FileSystemService.directorySize(sandbox)
        check("目录统计包含文件", size.files >= 3, "files=\(size.files)")
        check("目录大小为正", size.bytes > 0, "bytes=\(size.bytes)")

        check("搜索能找到文件", !FileSystemService.search(under: sandbox, matching: "笔记").isEmpty)
        check("搜索无结果返回空", FileSystemService.search(under: sandbox, matching: "绝对不存在的名字").isEmpty)

        // 唯一命名规则
        let plain = FSEngine.uniqueURL(in: sandbox, name: "重复.txt", isDirectory: false)
        try "x".write(to: plain, atomically: true, encoding: .utf8)
        let next = FSEngine.uniqueURL(in: sandbox, name: "重复.txt", isDirectory: false)
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

        let crumbs = AndroidURL.ancestors(AndroidURL.make(serial: "HA2B7QSF", path: "/storage/我的文件"))
        check("安卓面包屑包含根目录和逐层路径", crumbs.compactMap { AndroidURL.split($0)?.path } == ["/", "/storage", "/storage/我的文件"])
        check("安卓面包屑保留设备序列号且不产生本地 URL", crumbs.allSatisfy { !$0.isFileURL && AndroidURL.split($0)?.serial == "HA2B7QSF" })
        check("安卓根路径只生成一个面包屑", AndroidURL.ancestors(AndroidURL.make(serial: "S1", path: "/")).count == 1)
        check("本地路径不生成安卓面包屑", AndroidURL.ancestors(URL(fileURLWithPath: "/tmp")).isEmpty)

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

        guard !CommandLine.arguments.contains("--skip-device-tests") else {
            print("  本次跳过真实设备文件操作（--skip-device-tests）")
            return
        }

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

    // MARK: - 默认打开方式（仅本应用，不改动系统）

    @MainActor
    static func testFileAssociations() throws {
        print("\n[默认打开方式]")

        let fm = FileManager.default
        let store = FileAssociations.shared
        store.clearAll()

        let dir = fm.temporaryDirectory.appendingPathComponent("winfile-assoc-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir); store.clearAll() }

        let pdf = dir.appendingPathComponent("文件.pdf")
        let upper = dir.appendingPathComponent("文件.PDF")
        let noExt = dir.appendingPathComponent("无扩展名")
        let txt = dir.appendingPathComponent("文件.txt")
        for url in [pdf, upper, noExt, txt] {
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }

        // 键的规则：小写扩展名；无扩展名为 nil
        check("扩展名键为小写", FileAssociations.key(for: pdf) == "pdf",
              FileAssociations.key(for: pdf) ?? "nil")
        check("大写扩展名同样归一为小写", FileAssociations.key(for: upper) == "pdf",
              FileAssociations.key(for: upper) ?? "nil")
        check("无扩展名返回 nil", FileAssociations.key(for: noExt) == nil)

        // 未设置时不应有条目（应跟随系统）
        check("初始未设置任何关联", store.entries.isEmpty, "\(store.entries.count) 条")
        check("未设置时查询为 nil", store.application(for: pdf) == nil)

        // 设置一个真实存在的应用
        let appURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        check("测试用应用存在", fm.fileExists(atPath: appURL.path))

        store.setApplication(appURL, forExtension: "pdf")
        check("设置后能查到应用", store.application(for: pdf)?.path == appURL.path,
              store.application(for: pdf)?.path ?? "nil")
        check("大小写扩展名共用同一设置", store.application(for: upper)?.path == appURL.path)
        check("显示名去掉 .app 后缀", store.displayName(forExtension: "pdf") == "TextEdit",
              store.displayName(forExtension: "pdf") ?? "nil")
        check("其它类型不受影响", store.application(for: txt) == nil)

        // 指向不存在的应用时应视为未设置（避免打开时报错）
        store.setApplication(URL(fileURLWithPath: "/tmp/不存在-\(UUID().uuidString).app"),
                             forExtension: "txt")
        check("应用不存在时查询为 nil（视为未设置）", store.application(for: txt) == nil)

        // 清除
        store.clear(extension: "pdf")
        check("清除后回到跟随系统", store.application(for: pdf) == nil)

        // 全部清除
        store.setApplication(appURL, forExtension: "pdf")
        store.setApplication(appURL, forExtension: "txt")
        check("设置了两条", store.entries.count == 2, "\(store.entries.count) 条")
        store.clearAll()
        check("全部清除后为空", store.entries.isEmpty, "\(store.entries.count) 条")

        // 关键约束：本功能不得改动系统关联。
        // 这里只验证我们自己没有调用系统设置接口——通过检查系统关联
        // 在设置前后保持一致来间接确认（系统关联可能为空，故两边一致即可）
        let systemBefore = NSWorkspace.shared.urlForApplication(toOpen: pdf)
        store.setApplication(appURL, forExtension: "pdf")
        let systemAfter = NSWorkspace.shared.urlForApplication(toOpen: pdf)
        check("系统文件关联未被改动",
              systemBefore?.path == systemAfter?.path,
              "前=\(systemBefore?.lastPathComponent ?? "nil") 后=\(systemAfter?.lastPathComponent ?? "nil")")
        store.clearAll()
    }

    // MARK: - 关联应用徽标

    @MainActor
    static func testDefaultAppBadge() throws {
        print("\n[关联应用徽标]")

        let fm = FileManager.default
        let store = FileAssociations.shared
        let service = DefaultAppService.shared
        store.clearAll()
        service.invalidate()

        let dir = fm.temporaryDirectory.appendingPathComponent("winfile-badge-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir); store.clearAll(); service.invalidate() }

        let pdf = dir.appendingPathComponent("文件.pdf")
        try "x".write(to: pdf, atomically: true, encoding: .utf8)

        // 未自定义时应能解析出系统默认应用（通常非空）
        let systemApp = service.defaultApplication(for: pdf)
        print("  系统默认应用: \(systemApp?.lastPathComponent ?? "未解析到（该类型可能无默认应用）")")

        // 自定义后应立刻改用它
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        store.setApplication(textEdit, forExtension: "pdf")
        let custom = service.defaultApplication(for: pdf)
        check("自定义后徽标取的是自定义应用", custom?.path == textEdit.path,
              custom?.path ?? "nil")

        // 图标能取到
        let icon = service.badgeIcon(for: pdf, size: 32)
        check("能取到关联应用图标", icon != nil,
              icon.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil")

        // 关闭开关后不返回图标
        service.showsBadges = false
        check("关闭开关后不返回图标", service.badgeIcon(for: pdf, size: 32) == nil)
        service.showsBadges = true
        check("重新开启后恢复", service.badgeIcon(for: pdf, size: 32) != nil)

        // 文件夹不显示徽标（由视图层判断 isContainer；此处验证服务对无扩展名文件的行为）
        let folder = dir.appendingPathComponent("文件夹")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        check("无扩展名的项目不解析出应用", service.defaultApplication(for: folder) == nil)

        // 缓存失效：改动关联后必须能反映新应用
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        store.setApplication(preview, forExtension: "pdf")
        let after = service.defaultApplication(for: pdf)
        check("改动关联后缓存已失效（取到新应用）", after?.path == preview.path,
              after?.path ?? "nil")

        // 关键：改动设置必须通知观察者，否则界面要等重建才更新
        // （用户实测现象：改了打开方式，切换文件夹后徽标才变）
        var notified = false
        let token = service.objectWillChange.sink { notified = true }
        defer { token.cancel() }
        store.setApplication(textEdit, forExtension: "pdf")
        check("改动关联会通知界面刷新（无需切换目录）", notified,
              notified ? "已通知" : "未通知")

        // 时序验证：objectWillChange 是"将要变化"，此时缓存应已清空，
        // 否则界面在收到通知后重新求值仍会读到旧缓存 → 徽标不更新。
        var iconAtNotificationTime: NSImage?
        var appAtNotificationTime: URL?
        let token2 = service.objectWillChange.sink {
            iconAtNotificationTime = service.badgeIcon(for: pdf, size: 32)
            appAtNotificationTime = service.defaultApplication(for: pdf)
        }
        defer { token2.cancel() }
        store.setApplication(textEdit, forExtension: "pdf")

        check("收到通知时缓存已清空（能解析到新应用）",
              appAtNotificationTime?.path == textEdit.path,
              appAtNotificationTime?.path ?? "nil")
        check("收到通知时图标已可重新获取", iconAtNotificationTime != nil)
    }

    // MARK: - 缩略图适用范围

    @MainActor
    static func testThumbnailScope() {
        print("\n[缩略图适用范围]")

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("winfile-thumb-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // 按扩展名造出各类文件，检查是否应显示缩略图
        let samples: [(String, Bool)] = [
            ("照片.jpg", true), ("照片.png", true), ("照片.heic", true),
            ("影片.mp4", true), ("影片.mov", true), ("影片.m4v", true),
            ("文档.pdf", true), ("文档.PDF", true),
            ("文稿.txt", false), ("音乐.mp3", false),
            ("代码.swift", false), ("压缩包.zip", false)
        ]

        for (name, expected) in samples {
            let url = dir.appendingPathComponent(name)
            try? "x".write(to: url, atomically: true, encoding: .utf8)
            guard let item = FileItem(url: url, resourceKeys: FSEngine.resourceKeys, showHidden: false) else {
                check("构造条目 \(name)", false)
                continue
            }
            check("\(name) 缩略图=\(expected)", item.supportsThumbnail == expected,
                  "实际=\(item.supportsThumbnail) 分类=\(item.category.rawValue)")
        }

        // 文件夹不应有缩略图
        let folder = dir.appendingPathComponent("文件夹")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let item = FileItem(url: folder, resourceKeys: FSEngine.resourceKeys, showHidden: false) {
            check("文件夹不显示缩略图", !item.supportsThumbnail)
        }
    }

    // MARK: - 跳转到文件所在文件夹

    @MainActor
    static func testOpenContainingFolder() throws {
        print("\n[打开所在文件夹]")

        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("winfile-locate-\(UUID().uuidString)")
        let deep = base.appendingPathComponent("层一/层二")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let target = deep.appendingPathComponent("目标文件.pdf")
        try "%PDF".write(to: target, atomically: true, encoding: .utf8)
        try "x".write(to: base.appendingPathComponent("无关文件.txt"), atomically: true, encoding: .utf8)

        let model = BrowserModel(engine: FSEngine(), startDirectory: base)
        let deadline = Date().addingTimeInterval(10)
        while model.isBusy && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        check("起始目录载入完成", !model.displayedItems.isEmpty, "\(model.displayedItems.count) 项")

        // 构造该文件对应的 FileItem（模拟来自分类视图的条目）
        guard let item = FileItem(url: target, resourceKeys: FSEngine.resourceKeys, showHidden: false) else {
            check("构造目标文件条目", false)
            return
        }

        model.openContainingFolder(of: item)

        // 等目录加载完成
        let deadline2 = Date().addingTimeInterval(10)
        while model.isBusy && Date() < deadline2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        check("跳转到文件所在目录",
              model.currentDirectory?.path == deep.path,
              model.currentDirectory?.path ?? "无")
        check("待选中项已记录", model.pendingSelectionID == item.id,
              model.pendingSelectionID ?? "无")
        // 路径规范化：同一文件经由分类扫描与目录枚举应得到同一个 id
        // （/var 是 /private/var 的符号链接，不规范化会不相等）
        if let listed = model.displayedItems.first {
            check("路径规范化后 id 一致（符号链接不影响）",
                  listed.id == item.id,
                  "列表=\(listed.id.prefix(20))… 目标=\(item.id.prefix(20))…")
        }
        check("目标文件确实在该目录中",
              model.displayedItems.contains { $0.id == item.id })
        check("目录异步加载完成后目标保持选中", model.selectedIDs == Set([item.id]))

        // 界面读取后应清空，避免影响后续导航
        let consumed = model.consumePendingSelection()
        check("取出待选中项后清空", consumed == item.id && model.pendingSelectionID == nil,
              "取出=\(consumed ?? "无") 剩余=\(model.pendingSelectionID ?? "无")")

        // 非聚合视图（普通目录浏览）不需要该入口
        check("普通目录浏览不算聚合视图", !model.isAggregatedView)

        // 分类视图算聚合视图
        model.navigate(to: .category(.pdf))
        check("分类视图属于聚合视图", model.isAggregatedView)

        let engine = FSEngine()
        engine.restrictScopeForTesting([base])
        let manager = TabManager(engine: engine, startDirectory: nil)
        let original = manager.activeTab
        original.model.navigate(to: .weChatCleanup)
        original.model.weChatCleanup.search = "目标"
        original.model.weChatCleanup.month = "2026-10"
        original.model.selectedIDs = [item.id]
        original.model.openContainingFolder(of: item)
        let destination = manager.activeTab
        check("打开所在文件夹创建并激活新页签", manager.count == 2 && destination.id != original.id)
        check("新页签跳转保留原微信清理页", original.model.isWeChatCleanupView && original.model.currentDirectory == nil)
        check("新页签跳转保留微信筛选与选择", original.model.weChatCleanup.search == "目标"
              && original.model.weChatCleanup.month == "2026-10" && original.model.selectedIDs == [item.id])
        let tabDeadline = Date().addingTimeInterval(10)
        while destination.model.isBusy && Date() < tabDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        check("新页签加载目标目录并选中文件", destination.model.currentDirectory?.path == deep.path
              && destination.model.displayedItems.contains { $0.id == item.id } && destination.model.selectedIDs == [item.id])
        check("新页签保留滚动定位目标", destination.model.pendingSelectionID == item.id)
        let otherWindow = TabManager(engine: engine, startDirectory: nil)
        destination.model.openContainingFolder(of: target)
        check("新建页签仍归属原窗口且每次新开", manager.count == 3 && otherWindow.count == 1
              && manager.activeTab.id != destination.id)
        let countBeforeInvalid = manager.count
        manager.activeModel.openContainingFolder(of: URL(string: "https://example.com/file")!)
        check("无效文件位置不会新建空页签", manager.count == countBeforeInvalid && manager.activeModel.errorMessage != nil)
    }

    // MARK: - 真实磁盘分类结果是否有重复

    @MainActor
    static func testRealCategoryDuplicates() {
        print("\n[真实磁盘分类重复检查]")

        // 用真实可浏览范围（与界面一致），而非自造目录 ——
        // 自造目录干净无重复，掩盖了用户遇到的"两个磁贴同 id"问题
        let engine = FSEngine()
        let roots = engine.browsableRoots
        print("  扫描范围: \(roots.map(\.path).joined(separator: "、"))")

        // 范围存在包含关系（家目录 ⊂ 根目录），合并结果必须已去重：
        // 单独扫描各范围之和 ≥ 合并结果，且合并后 id 必须唯一
        let homeOnly = FileSystemService.categoryFiles(.pdf, under: [roots[0]])
        let rootOnly = FileSystemService.categoryFiles(.pdf, under: [roots[1]])
        let merged = FileSystemService.categoryFiles(.pdf, under: roots)
        check("合并结果不超过各范围之和",
              merged.count <= homeOnly.count + rootOnly.count,
              "\(merged.count) vs \(homeOnly.count + rootOnly.count)")
        check("范围重叠时合并结果已去重（唯一 id 等于项数）",
              Set(merged.map(\.id)).count == merged.count,
              "唯一 \(Set(merged.map(\.id)).count) / 共 \(merged.count)")

        for category in [FileCategory.pdf, .image] {
            let found = FileSystemService.categoryFiles(category, under: roots)
            let ids = found.map(\.id)
            let uniqueIDs = Set(ids)
            let paths = found.map { $0.url.path }
            let uniquePaths = Set(paths)

            print("  \(category.localizedName): \(found.count) 项，唯一 id \(uniqueIDs.count)，唯一路径 \(uniquePaths.count)")

            // 徽标计数同样不应重复（此前虚高：16 vs 实际 14）
            let counts = FileSystemService.categoryCounts(under: roots)
            print("  \(category.localizedName) 徽标计数: \(counts[category] ?? 0)")

            if uniqueIDs.count != found.count {
                let dups = Dictionary(grouping: found, by: \.id).filter { $0.value.count > 1 }
                print("    ⚠️ 发现 \(dups.count) 组重复 id：")
                for (id, group) in dups.prefix(3) {
                    print("      \(id) → \(group.count) 次，名称 \(group.map(\.name).joined(separator: "/"))")
                }
                check("真实磁盘上 \(category.localizedName) 的分类结果 id 唯一", false,
                      "\(dups.count) 组重复")
            } else {
                check("真实磁盘上 \(category.localizedName) 的分类结果 id 唯一", true)
            }

            // 计数与列表项数必须一致（两者都去重后应相等）
            if let badge = counts[category] {
                // 徽标受 budget 限制，列表也受同样限制，故应相等
                check("\(category.localizedName) 徽标数与列表项数一致",
                      badge == found.count, "徽标 \(badge) vs 列表 \(found.count)")
            }
        }

        // 最近使用列表也不应有重复路径
        let recent = FileSystemService.recentFiles(under: roots)
        let recentPaths = recent.map { $0.url.path }
        check("最近使用列表无重复路径",
              Set(recentPaths).count == recentPaths.count,
              "唯一 \(Set(recentPaths).count) / 共 \(recentPaths.count)")

        // 去重函数本身
        let items = [("/a/x.txt"), ("/b/y.txt"), ("/a/x.txt")].compactMap {
            FileItem(url: URL(fileURLWithPath: $0), resourceKeys: [], showHidden: true)
        }
        let deduped = FileSystemService.deduplicateByPath(items)
        check("去重函数保留首次出现并保持顺序",
              deduped.count == 2 && deduped[0].url.path == "/a/x.txt" && deduped[1].url.path == "/b/y.txt",
              deduped.map(\.url.path).joined(separator: "/"))
    }

    // MARK: - 自建网格的分行逻辑

    @MainActor
    static func testGridRowPartition() {
        print("\n[自建网格分行]")

        // 分行规则：按列数切分，行数 = ceil(总数/列数)，
        // 且所有行拼回来必须等于原序列（不丢项、不重复）
        func partition(_ count: Int, columns: Int) -> [[Int]] {
            guard count > 0, columns > 0 else { return [] }
            var result: [[Int]] = []
            var index = 0
            while index < count {
                let end = min(index + columns, count)
                result.append(Array(index..<end))
                index = end
            }
            return result
        }

        // 用户截图的数量：16 项、6 列 → 3 行（6/6/4）
        let rows16 = partition(16, columns: 6)
        check("16 项 6 列分成 3 行", rows16.count == 3, "\(rows16.count) 行")
        check("每行不超过列数", rows16.allSatisfy { $0.count <= 6 },
              rows16.map(\.count).map(String.init).joined(separator: "/"))
        check("拼接后不丢项不重复",
              rows16.flatMap { $0 } == Array(0..<16),
              rows16.flatMap { $0 }.count.description)

        // 常见边界
        for (count, columns) in [(1, 6), (6, 6), (7, 6), (12, 6), (13, 6), (30, 5), (100, 8)] {
            let rows = partition(count, columns: columns)
            let flat = rows.flatMap { $0 }
            let expectedRows = (count + columns - 1) / columns
            let ok = flat == Array(0..<count) && rows.count == expectedRows
            check("\(count) 项 \(columns) 列 → \(expectedRows) 行且不丢项", ok,
                  "实际 \(rows.count) 行，项数 \(flat.count)")
        }

        // 空列表
        check("空列表不产生行", partition(0, columns: 6).isEmpty)
    }

    // MARK: - 分类视图完整性（是否漏画/重复）

    @MainActor
    static func testCategoryViewIntegrity() throws {
        print("\n[分类视图完整性]")

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("winfile-cat-\(UUID().uuidString)")
        // 造出与用户截图相同的情形：16 个 PDF，含重名文件在不同目录
        let dirA = root.appendingPathComponent("A")
        let dirB = root.appendingPathComponent("B")
        try fm.createDirectory(at: dirA, withIntermediateDirectories: true)
        try fm.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let names = ["lockScreenLiquidDetection.pdf", "ENERGY STAR.pdf",
                     "reader_complimentary_membership_dialog_image.pdf",
                     "ReferenceCardForMac.pdf", "ReferenceCard.pdf", "Doc3.pdf",
                     "Doc2.pdf", "Doc1.pdf"]
        // A、B 两个目录放同名文件（用户截图里就有重名），凑满 16 个
        for name in names {
            try "x".write(to: dirA.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for name in names {
            try "x".write(to: dirB.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let engine = FSEngine()
        engine.restrictScopeForTesting([root])
        let model = BrowserModel(engine: engine, startDirectory: nil)
        model.navigate(to: .category(.pdf))

        let deadline = Date().addingTimeInterval(25)
        while model.isLoadingCategory && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        let items = model.displayedItems
        print("  分类结果: \(items.count) 项")

        check("分类列出了全部 16 个 PDF", items.count == 16, "\(items.count) 项")

        // id 唯一性：重复会导致 LazyVGrid 少画（用户报告 16 计数只显示 14 个）
        let uniqueIDs = Set(items.map(\.id))
        check("id 全部唯一（重复会让网格少画）",
              uniqueIDs.count == items.count,
              "唯一 \(uniqueIDs.count) / 共 \(items.count)")
        if uniqueIDs.count != items.count {
            let grouped = Dictionary(grouping: items, by: \.id).filter { $0.value.count > 1 }
            for (id, dup) in grouped.prefix(3) {
                print("    重复 id: \(id) → \(dup.count) 次: \(dup.map(\.name).joined(separator: "/"))")
            }
        }

        // 路径唯一性
        let uniquePaths = Set(items.map { $0.url.path })
        check("路径全部唯一", uniquePaths.count == items.count,
              "唯一 \(uniquePaths.count) / 共 \(items.count)")

        // 同名文件应来自不同目录（不是同一文件被加两次）
        let namesCount = Dictionary(grouping: items, by: \.name).mapValues(\.count)
        let duplicatedNames = namesCount.filter { $0.value > 1 }
        print("  重名文件 \(duplicatedNames.count) 组（来自不同目录，属正常）")
        for (name, count) in duplicatedNames.prefix(2) {
            let paths = items.filter { $0.name == name }.map { $0.url.deletingLastPathComponent().lastPathComponent }
            print("    \(name) → \(count) 份，目录: \(paths.joined(separator: "/"))")
        }
        check("重名文件确实来自不同目录",
              duplicatedNames.allSatisfy { name, _ in
                  Set(items.filter { $0.name == name }.map { $0.url.path }).count > 1
              })
    }

    // MARK: - 图标网格对齐

    @MainActor
    static func testTileLayoutUniformity() {
        print("\n[图标网格对齐]")

        // 名称区域必须是固定高度：否则同行内一行的短名与两行的长名会让
        // 磁贴高度不同，矮的下方留白（用户实测反馈的"留空"现象）。
        check("磁贴名称区域高度固定且大于零",
              FileItem.tileNameAreaHeight > 0,
              "\(FileItem.tileNameAreaHeight)")

        // 高度应能容纳两行 caption（约 13pt/行），否则第二行会被裁掉
        check("名称区域高度至少容纳两行",
              FileItem.tileNameAreaHeight >= 26,
              "\(FileItem.tileNameAreaHeight)")

        // 用用户截图里的真实文件名验证：这些名字会导致 1~2 行不等的排版，
        // 正是需要固定高度的场景
        let names = ["lockScreenLiquidDetection.pdf", "ENERGY STAR.pdf",
                     "reader_complimentary_membership_dialog_image.pdf",
                     "智能体速成-招生简章.pdf", "Doc1.pdf"]
        let hasMixedLengths = names.contains { $0.count <= 8 } && names.contains { $0.count >= 20 }
        check("测试样本包含长短名称（会形成不同行数）", hasMixedLengths,
              names.map { "\($0.count)" }.joined(separator: "/"))

        // 网格列宽需容得下最长名称的截断（不溢出）
        let longest = names.max(by: { $0.count < $1.count }) ?? ""
        check("存在需要截断的长名称", longest.count > 10, "\(longest.count) 字符")
    }

    // MARK: - 全选一致性

    @MainActor
    static func testSelectAllConsistency() throws {
        print("\n[全选一致性]")

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("winfile-select-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // 造 16 个文件（与用户截图的数量一致）
        for index in 1...16 {
            try "x".write(to: dir.appendingPathComponent("f\(index).pdf"),
                          atomically: true, encoding: .utf8)
        }

        let model = BrowserModel(engine: FSEngine(), startDirectory: dir)
        let deadline = Date().addingTimeInterval(10)
        while model.isBusy && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        check("目录载入 16 项", model.displayedItems.count == 16, "\(model.displayedItems.count) 项")
        check("id 互不重复（重复会导致计数不一致）",
              Set(model.displayedItems.map(\.id)).count == model.displayedItems.count,
              "唯一 id \(Set(model.displayedItems.map(\.id)).count) / 共 \(model.displayedItems.count)")

        model.selectAll()
        check("全选后 selectedIDs 等于项目数",
              model.selectedIDs.count == model.displayedItems.count,
              "selectedIDs=\(model.selectedIDs.count) 项目=\(model.displayedItems.count)")
        check("全选后 selectedItems 等于项目数",
              model.selectedItems.count == model.displayedItems.count,
              "selectedItems=\(model.selectedItems.count)")
        check("两个计数一致（状态栏与检查器由此取数）",
              model.selectedIDs.count == model.selectedItems.count,
              "IDs=\(model.selectedIDs.count) items=\(model.selectedItems.count)")

        // 选择摘要不应为空
        check("多选摘要有内容", !model.selectionSummary.isEmpty, model.selectionSummary)

        // 关键：全选后每个项目的 id 都必须真的在 selectedIDs 里
        let missing = model.displayedItems.filter { !model.selectedIDs.contains($0.id) }
        check("全选后没有任何项目漏选", missing.isEmpty,
              "漏选 \(missing.count) 项：\(missing.prefix(3).map(\.name).joined(separator: "/"))")

        // selectedItems 必须与 displayedItems 完全对应（数量与顺序）
        check("selectedItems 与 displayedItems 数量一致",
              model.selectedItems.count == model.displayedItems.count,
              "\(model.selectedItems.count) vs \(model.displayedItems.count)")

        // 模拟界面读到的两个数字应当一致
        let statusBarCount = model.selectedIDs.count
        let inspectorCount = model.selectedItems.count
        check("状态栏与检查器读到的数字一致", statusBarCount == inspectorCount,
              "状态栏=\(statusBarCount) 检查器=\(inspectorCount)")

        // 逐个取消选择，两者应始终同步
        var mismatch = 0
        for item in model.displayedItems {
            model.selectedIDs.remove(item.id)
            if model.selectedIDs.count != model.selectedItems.count { mismatch += 1 }
        }
        check("逐个取消过程中两个计数始终同步", mismatch == 0, "不一致 \(mismatch) 次")
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
        check("压缩包非空", size > 0, "\(size) 字节")

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

        // 解压冲突：目标已有同名项时不得覆盖，应改解到「<包名> 解压」
        let conflictDir = base.appendingPathComponent("冲突")
        try fm.createDirectory(at: conflictDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: conflictDir.appendingPathComponent("源目录"), withIntermediateDirectories: true)
        try "旧内容（绝不可被覆盖）".write(
            to: conflictDir.appendingPathComponent("源目录/a.txt"),
            atomically: true, encoding: .utf8)
        let conflictCreated = try ArchiveService.extract(archive, to: conflictDir)
        check("冲突解压返回顶层项目", !conflictCreated.isEmpty, "\(conflictCreated.count) 项")
        let sideFolder = conflictDir.appendingPathComponent("test 解压/源目录")
        check("冲突时改解到独立文件夹", fm.fileExists(atPath: sideFolder.path), sideFolder.path)
        check("原有文件未被覆盖",
              (try? String(contentsOf: conflictDir.appendingPathComponent("源目录/a.txt"),
                           encoding: .utf8)) == "旧内容（绝不可被覆盖）")

        // tar 系格式识别与解压（bsdtar 自动识别 gzip）
        let tarSourceDir = base.appendingPathComponent("tar源")
        try fm.createDirectory(at: tarSourceDir, withIntermediateDirectories: true)
        try "tar 内容".write(to: tarSourceDir.appendingPathComponent("a.txt"),
                            atomically: true, encoding: .utf8)
        let tarArchive = base.appendingPathComponent("归档.tar.gz")
        let tarProcess = Process()
        tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tarProcess.arguments = ["-czf", tarArchive.path, "-C", base.path, "tar源"]
        try tarProcess.run()
        tarProcess.waitUntilExit()
        check("tar.gz 被识别为压缩包", ArchiveService.isArchive(tarArchive))
        let tarRestore = base.appendingPathComponent("tar还原")
        try fm.createDirectory(at: tarRestore, withIntermediateDirectories: true)
        try ArchiveService.extract(tarArchive, to: tarRestore)
        check("tar.gz 解压成功",
              (try? String(contentsOf: tarRestore.appendingPathComponent("tar源/a.txt"),
                           encoding: .utf8)) == "tar 内容")
    }

    @MainActor
    static func testExpandedArchives(_ sandbox: URL) throws {
        print("\n[RAR / 7Z 与完整解压流程]")
        let fm = FileManager.default
        let root = sandbox.appendingPathComponent("扩展解压测试")
        let source = root.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        guard let engine = ArchiveService.sevenZipURL else { throw ArchiveError.engineMissing }
        check("应用自带可运行的双架构解压引擎", fm.isExecutableFile(atPath: engine.path))
        func run(_ executable: URL, _ arguments: [String], cwd: URL = source) throws {
            let p = Process(); p.executableURL = executable; p.arguments = arguments; p.currentDirectoryURL = cwd
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 { throw ArchiveError.commandFailed("test fixture creation", p.terminationStatus) }
        }
        func output(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name); try fm.createDirectory(at: url, withIntermediateDirectories: true); return url
        }
        func fixture(_ name: String) -> URL {
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("TestFixtures/" + name)
            if let bundled, fm.fileExists(atPath: bundled.path) { return bundled }
            return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + name)
        }
        func fails(_ name: String, _ action: () throws -> Void, where expected: (Error) -> Bool = { _ in true }) {
            do { try action(); check(name, false) } catch { check(name, expected(error), error.localizedDescription) }
        }
        let nested = source.appendingPathComponent("中文 子目录")
        try fm.createDirectory(at: nested.appendingPathComponent("空目录"), withIntermediateDirectories: true)
        let text = nested.appendingPathComponent("报告.txt")
        try Data("Unicode extraction ✓".utf8).write(to: text)
        let seven = root.appendingPathComponent("资料.7z")
        try run(engine, ["a", "-t7z", seven.path, "中文 子目录"])
        check("识别 RAR 与 7Z 格式且不区分扩展名大小写", ArchiveService.isArchive(URL(fileURLWithPath: "/a.RAR")) && ArchiveService.isArchive(URL(fileURLWithPath: "/a.7Z")))
        let sevenOut = try output("7z还原")
        _ = try ArchiveService.extract(seven, to: sevenOut)
        check("7Z 还原中文名称和完整文件内容", (try? Data(contentsOf: sevenOut.appendingPathComponent("中文 子目录/报告.txt"))) == Data("Unicode extraction ✓".utf8))
        check("7Z 保留空文件夹", fm.fileExists(atPath: sevenOut.appendingPathComponent("中文 子目录/空目录").path))
        let rarOut = try output("rar5还原")
        _ = try ArchiveService.extract(fixture("stored-rar5.rar"), to: rarOut)
        check("真实 RAR5 样本解压内容正确", (try? String(contentsOf: rarOut.appendingPathComponent("helloworld.txt"))) == "hello libarchive test suite!\n")
        let rar4Out = try output("rar4还原")
        _ = try ArchiveService.extract(fixture("legacy-rar4.rar"), to: rar4Out)
        check("真实 RAR4 样本解压内容正确", (try? String(contentsOf: rar4Out.appendingPathComponent("test.txt"))) == "test text document\r\n")
        check("RAR4 内部相对符号链接保持在解压目录", (try? fm.destinationOfSymbolicLink(atPath: rar4Out.appendingPathComponent("testlink").path)) == "test.txt")
        let compressedRarOut = try output("RAR5压缩还原")
        _ = try ArchiveService.extract(fixture("compressed-rar5.rar"), to: compressedRarOut)
        var expectedRarData = Data()
        for k in 1...300 {
            var value = UInt32(max(0, k * k - 3 * k + 1)).littleEndian
            withUnsafeBytes(of: &value) { expectedRarData.append(contentsOf: $0) }
        }
        check("RAR5 压缩算法还原全部原始字节", (try? Data(contentsOf: compressedRarOut.appendingPathComponent("test.bin"))) == expectedRarData)
        let folderOut = try output("独立文件夹")
        let own = try ArchiveService.extract(seven, to: folderOut, createFolder: true)
        let ownAgain = try ArchiveService.extract(seven, to: folderOut, createFolder: true)
        check("独立文件夹模式使用包名且重名保留两者", own.first?.lastPathComponent == "资料" && ownAgain.first?.lastPathComponent == "资料 2")
        check("复合压缩扩展名用于文件夹命名时完整移除", ArchiveService.extractionBaseName(URL(fileURLWithPath: "/项目.tar.gz")) == "项目" && ArchiveService.extractionBaseName(URL(fileURLWithPath: "/项目.part01.rar")) == "项目")
        let password = "Test 密码$ with spaces"
        let protected = root.appendingPathComponent("加密.7z")
        try run(engine, ["a", "-t7z", "-mhe=on", "-p" + password, protected.path, "中文 子目录"])
        let protectedOut = try output("加密还原")
        fails("加密文件头要求输入密码", { _ = try ArchiveService.extract(protected, to: protectedOut) }, where: { if case ArchiveError.passwordRequired = $0 { return true }; return false })
        fails("错误密码返回可重试错误", { _ = try ArchiveService.extract(protected, to: protectedOut, password: "incorrect") }, where: { if case ArchiveError.wrongPassword = $0 { return true }; return false })
        check("密码失败不会提交任何文件", (try? fm.contentsOfDirectory(atPath: protectedOut.path))?.isEmpty == true)
        _ = try ArchiveService.extract(protected, to: protectedOut, password: password)
        check("密码通过标准输入支持中文空格和符号", (try? Data(contentsOf: protectedOut.appendingPathComponent("中文 子目录/报告.txt"))) == Data("Unicode extraction ✓".utf8))
        let aesZip = root.appendingPathComponent("加密.zip")
        try run(engine, ["a", "-tzip", "-mem=AES256", "-pAES-test-password", aesZip.path, "中文 子目录"])
        _ = try ArchiveService.extract(aesZip, to: output("AESZIP还原"), password: "AES-test-password")
        check("支持 AES 加密 ZIP 解压", fm.fileExists(atPath: root.appendingPathComponent("AESZIP还原/中文 子目录/报告.txt").path))
        let plain = source.appendingPathComponent("report.txt")
        try Data("single compressed file".utf8).write(to: plain)
        for (ext, type) in [("gz", "gzip"), ("bz2", "bzip2"), ("xz", "xz")] {
            let compressed = root.appendingPathComponent("report.txt." + ext)
            try run(engine, ["a", "-t" + type, compressed.path, "report.txt"])
            let restored = try output("stream-" + ext)
            _ = try ArchiveService.extract(compressed, to: restored)
            check("独立单文件 \(ext) 正确解压", (try? Data(contentsOf: restored.appendingPathComponent("report.txt"))) == Data("single compressed file".utf8))
        }
        for (suffix, flag) in [("tar.gz", "-czf"), ("tar.bz2", "-cjf"), ("tar.xz", "-cJf")] {
            let archive = root.appendingPathComponent("nested." + suffix)
            try run(URL(fileURLWithPath: "/usr/bin/tar"), [flag, archive.path, "-C", source.path, "中文 子目录"])
            let restored = try output(suffix)
            _ = try ArchiveService.extract(archive, to: restored)
            check("\(suffix) 自动解开压缩流和 TAR 两层", fm.fileExists(atPath: restored.appendingPathComponent("中文 子目录/报告.txt").path))
        }
        let random = source.appendingPathComponent("volume.bin")
        let randomData = Data((0..<30000).map { UInt8($0 % 251) })
        try randomData.write(to: random)
        let split = root.appendingPathComponent("split.7z")
        try run(engine, ["a", "-t7z", "-mx=0", "-v4096b", split.path, "volume.bin"])
        let first = root.appendingPathComponent("split.7z.001"), second = root.appendingPathComponent("split.7z.002")
        check("7Z 分卷被识别为可解压文件", ArchiveService.isArchive(first) && ArchiveService.isArchive(second))
        check("选择后续分卷自动定位首卷", try ArchiveService.firstVolume(for: second).path == first.path)
        let splitOut = try output("分卷还原")
        _ = try ArchiveService.extract(second, to: splitOut)
        check("7Z 多分卷完整还原", (try? Data(contentsOf: splitOut.appendingPathComponent("volume.bin"))) == randomData)
        check("分卷文件归入压缩包分类", FileTypeDB.info(name: "split.7z.002", isDirectory: false, isSymlink: false, isBundle: false).category == .archive)
        let volumeNames = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("split.7z.") }.sorted()
        let lastVolume = root.appendingPathComponent(volumeNames.last!)
        let lastVolumeBytes = try Data(contentsOf: lastVolume)
        try fm.removeItem(at: lastVolume)
        let missingOut = try output("缺失分卷")
        fails("缺失后续分卷时拒绝提交残缺文件", { _ = try ArchiveService.extract(first, to: missingOut) })
        check("缺失分卷的暂存内容已清除", (try? fm.contentsOfDirectory(atPath: missingOut.path))?.isEmpty == true)
        try lastVolumeBytes.write(to: lastVolume)
        let zipVolumeData = Data(repeating: 0x59, count: 160000)
        try zipVolumeData.write(to: random)
        let classicZip = root.appendingPathComponent("classic.zip")
        try run(URL(fileURLWithPath: "/usr/bin/zip"), ["-0", "-s", "64k", classicZip.path, "volume.bin"])
        let classicOut = try output("ZIP传统分卷")
        _ = try ArchiveService.extract(root.appendingPathComponent("classic.z01"), to: classicOut)
        check("传统 ZIP 分卷自动使用多卷引擎", (try? Data(contentsOf: classicOut.appendingPathComponent("volume.bin"))) == zipVolumeData)
        let numberedZip = root.appendingPathComponent("numbered.zip")
        try run(engine, ["a", "-tzip", "-mx=0", "-v32768b", numberedZip.path, "volume.bin"])
        let numberedOut = try output("ZIP数字分卷")
        _ = try ArchiveService.extract(root.appendingPathComponent("numbered.zip.002"), to: numberedOut)
        check("数字 ZIP 分卷完整解压", (try? Data(contentsOf: numberedOut.appendingPathComponent("volume.bin"))) == zipVolumeData)
        let firstUnicode = root.appendingPathComponent("İstanbul.part01.rar")
        try Data().write(to: firstUnicode)
        check("Unicode 文件名的 RAR 分卷定位不改变原始名称", try ArchiveService.firstVolume(for: root.appendingPathComponent("İstanbul.part02.rar")).lastPathComponent == firstUnicode.lastPathComponent)
        check("TAR 压缩别名归入压缩包分类", ["tbz", "tbz2", "txz"].allSatisfy { FileTypeDB.info(name: "sample." + $0, isDirectory: false, isSymlink: false, isBundle: false).category == .archive })
        let absent = root.appendingPathComponent("不存在.part02.rar")
        fails("缺首卷时给出分卷提示", { _ = try ArchiveService.firstVolume(for: absent) }, where: { if case ArchiveError.missingVolume = $0 { return true }; return false })
        let broken = root.appendingPathComponent("damaged.7z")
        try Data("not an archive".utf8).write(to: broken)
        let brokenOut = try output("损坏还原")
        fails("损坏压缩包报错且不提交残缺内容", { _ = try ArchiveService.extract(broken, to: brokenOut) })
        check("损坏解压清除暂存目录", (try? fm.contentsOfDirectory(atPath: brokenOut.path))?.isEmpty == true)
        let cancelledOut = try output("取消还原")
        let stopped = ScanCancellation(); stopped.cancel()
        fails("解压开始前可取消", { _ = try ArchiveService.extract(seven, to: cancelledOut, cancellation: stopped) }, where: { if case ArchiveError.cancelled = $0 { return true }; return false })
        let during = ScanCancellation()
        fails("运行中取消不提交当前压缩包", {
            _ = try ArchiveService.extract(seven, to: cancelledOut, cancellation: during) { value in
                if value == nil { DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) { during.cancel() } }
            }
        }, where: { if case ArchiveError.cancelled = $0 { return true }; return false })
        check("取消解压清除暂存并保留原包", (try? fm.contentsOfDirectory(atPath: cancelledOut.path))?.isEmpty == true && fm.fileExists(atPath: seven.path))
        // Mutate only archive entry names (same byte count), leaving CRC and data intact.
        let placeholder = source.appendingPathComponent("___escape.txt")
        try Data("must not escape".utf8).write(to: placeholder)
        let malicious = root.appendingPathComponent("unsafe.zip")
        try run(engine, ["a", "-tzip", malicious.path, "___escape.txt"])
        var bytes = try Data(contentsOf: malicious)
        let old = Data("___escape.txt".utf8), replacement = Data("../escape.txt".utf8)
        var offset = 0
        while offset < bytes.count, let range = bytes.range(of: old, in: offset..<bytes.count) {
            bytes.replaceSubrange(range, with: replacement); offset = range.upperBound
        }
        try bytes.write(to: malicious)
        let unsafeOut = try output("安全验证")
        fails("拒绝包含目录穿越条目的 ZIP", { _ = try ArchiveService.extract(malicious, to: unsafeOut) }, where: { if case ArchiveError.unsafePath = $0 { return true }; return false })
        check("目录穿越没有写入外部路径", !fm.fileExists(atPath: root.appendingPathComponent("escape.txt").path))
        let outside = root.appendingPathComponent("outside.txt")
        try Data("untouched".utf8).write(to: outside)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("outside-link").path, withDestinationPath: outside.path)
        let linkZip = root.appendingPathComponent("link.zip")
        try run(URL(fileURLWithPath: "/usr/bin/zip"), ["-y", "-q", linkZip.path, "outside-link"])
        fails("拒绝指向解压目录外部的符号链接", { _ = try ArchiveService.extract(linkZip, to: unsafeOut) })
        check("外部链接目标内容保持不变", (try? Data(contentsOf: outside)) == Data("untouched".utf8))
        let danglingOut = try output("断链冲突")
        try fm.createSymbolicLink(atPath: danglingOut.appendingPathComponent("中文 子目录").path, withDestinationPath: "missing-target")
        let conflict = try ArchiveService.extract(seven, to: danglingOut)
        check("断开的符号链接也视为同名冲突并保留", (try? fm.destinationOfSymbolicLink(atPath: danglingOut.appendingPathComponent("中文 子目录").path)) == "missing-target" && conflict.first?.lastPathComponent == "资料 解压")
        let engineModel = FSEngine(); engineModel.restrictScopeForTesting([root])
        let model = BrowserModel(engine: engineModel, startDirectory: root)
        func wait() {
            let until = Date().addingTimeInterval(30)
            while (model.isBusy || model.archiveProgress != nil) && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
        }
        wait()
        model.selectedIDs = [FileItem.canonicalID(for: seven), FileItem.canonicalID(for: broken)]
        let batchOut = try output("批量输出")
        model.extractSelection(to: batchOut)
        wait()
        check("批量解压保留成功结果和失败明细", model.lastTransferOutcome?.completed.count == 1 && model.lastTransferOutcome?.failures.count == 1 && fm.fileExists(atPath: batchOut.appendingPathComponent("中文 子目录/报告.txt").path))
        model.selectedIDs = [FileItem.canonicalID(for: first), FileItem.canonicalID(for: second)]
        model.extractSelection(to: try output("批量分卷"))
        wait()
        check("同时选中多个分卷只解压一次", model.lastTransferOutcome?.completed.count == 1 && model.lastTransferOutcome?.failures.isEmpty == true)
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

        // 排序：上移/下移
        prefs.resetToDefault()
        let ordered = prefs.allCategoriesInOrder
        check("默认顺序与 sidebarOrder 一致",
              ordered.prefix(all.count) == ArraySlice(all),
              ordered.prefix(3).map(\.rawValue).joined(separator: "/"))

        let first = ordered[0]
        let second = ordered[1]
        check("首项不可上移", !prefs.canMove(first, by: -1))
        check("末项不可下移", !prefs.canMove(ordered[ordered.count - 1], by: 1))
        check("中间项可上下移动", prefs.canMove(second, by: -1) && prefs.canMove(second, by: 1))

        prefs.move(second, by: -1)
        check("上移后位置互换",
              prefs.allCategoriesInOrder[0] == second && prefs.allCategoriesInOrder[1] == first,
              prefs.allCategoriesInOrder.prefix(2).map(\.rawValue).joined(separator: "/"))

        prefs.move(second, by: 1)
        check("下移后恢复原位",
              prefs.allCategoriesInOrder[0] == first && prefs.allCategoriesInOrder[1] == second,
              prefs.allCategoriesInOrder.prefix(2).map(\.rawValue).joined(separator: "/"))

        // 排序不影响显示集合，且移动后仍包含全部分类（不丢项）
        check("移动不丢分类", Set(prefs.allCategoriesInOrder) == Set(all),
              "\(prefs.allCategoriesInOrder.count)/\(all.count)")

        // 移除某项后，其余项顺序保持
        prefs.hide(second)
        let visibleAfterHide = prefs.visibleCategories
        check("移除后可见列表不含该项", !visibleAfterHide.contains(second))
        check("移除后其余项顺序不变",
              visibleAfterHide == prefs.allCategoriesInOrder.filter { $0 != second },
              visibleAfterHide.prefix(3).map(\.rawValue).joined(separator: "/"))

        // 恢复默认
        prefs.resetToDefault()
        check("恢复默认后全部显示", prefs.visibleCategories.count == all.count,
              "\(prefs.visibleCategories.count)")
        check("恢复默认后隐藏列表为空", prefs.hiddenCategoryList.isEmpty)
        check("恢复默认后顺序回到默认",
              prefs.allCategoriesInOrder.prefix(all.count) == ArraySlice(all))
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

        guard !CommandLine.arguments.contains("--skip-device-tests") else {
            print("  本次跳过真实设备浏览（--skip-device-tests）")
            return
        }

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
    static func testMouseEventSafety() {
        print("\n[切换应用时的异常鼠标事件与监听器生命周期]")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        window.contentView = root
        let installer = EmptyAreaContextMenu.InstallerView(frame: .zero)
        root.addSubview(installer)
        defer { installer.detachMonitors(); window.orderOut(nil) }
        let marker = FileTileMarkerView(frame: NSRect(x: 40, y: 60, width: 100, height: 80))
        marker.item = item(URL(fileURLWithPath: "/tmp"))
        var activated = 0
        marker.onActivate = { activated += 1 }
        root.addSubview(marker)
        var menuBuilds = 0
        installer.buildMenu = { menuBuilds += 1; return NSMenu() }

        func event(_ point: NSPoint, type: NSEvent.EventType = .leftMouseDown, clicks: Int = 2,
                   windowNumber: Int? = nil) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: windowNumber ?? window.windowNumber, context: nil,
                               eventNumber: 1, clickCount: clicks, pressure: 1)!
        }
        let normal = NSPoint(x: 80, y: 90)
        check("鼠标事件可解析到所属测试窗口", event(normal).window === window)
        check("普通窗口内坐标仍被接受", EmptyAreaContextMenu.InstallerView.mouseLocation(event(normal), in: window) == normal)
        check("挂入窗口时同时安装左右键监听器", installer.activeMonitorCount == 2)
        installer.attachIfNeeded(); installer.attachIfNeeded()
        check("重复更新视图不重复安装监听器", installer.activeMonitorCount == 2)
        let single = event(normal, clicks: 1)
        check("正常单击透传且不触发打开", installer.handleLeftMouseDown(single) === single && activated == 0)
        check("正常图标双击仅触发一次并吞掉事件", installer.handleLeftMouseDown(event(normal)) == nil && activated == 1)

        let clipping = NSScrollView(frame: NSRect(x: 200, y: 0, width: 180, height: 120))
        let scrollingDocument = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 1000))
        clipping.documentView = scrollingDocument; root.addSubview(clipping)
        let overscan = FileTileMarkerView(frame: NSRect(x: 10, y: 500, width: 100, height: 70))
        overscan.item = item(URL(fileURLWithPath: "/tmp")); scrollingDocument.addSubview(overscan)
        clipping.contentView.scroll(to: NSPoint(x: 0, y: 300))
        let offscreen = overscan.convert(NSPoint(x: 50, y: 35), to: nil)
        check("离屏磁贴不会抢占地址栏或工具栏的双击", EmptyAreaContextMenu.InstallerView.tileMarker(at: offscreen, in: root) == nil)
        overscan.setFrameOrigin(NSPoint(x: 10, y: 320))
        let onscreen = overscan.convert(NSPoint(x: 50, y: 35), to: nil)
        check("可见磁贴仍可按坐标识别", EmptyAreaContextMenu.InstallerView.tileMarker(at: onscreen, in: root) === overscan)
        clipping.isHidden = true
        check("隐藏父容器中的磁贴不参与查找", EmptyAreaContextMenu.InstallerView.tileMarker(at: onscreen, in: root) == nil)
        clipping.removeFromSuperview()


        let invalid: [(String, NSPoint)] = [
            ("NaN 横坐标", NSPoint(x: CGFloat.nan, y: 90)),
            ("NaN 纵坐标", NSPoint(x: 80, y: CGFloat.nan)),
            ("正无穷", NSPoint(x: CGFloat.infinity, y: 90)),
            ("负无穷", NSPoint(x: 80, y: -CGFloat.infinity)),
            ("超大有限坐标", NSPoint(x: CGFloat.greatestFiniteMagnitude, y: 90)),
            ("Int 上界舍入溢出", NSPoint(x: CGFloat(Int.max), y: 90)),
            ("窗口外坐标", NSPoint(x: -100, y: -100))
        ]
        for (name, point) in invalid {
            let left = event(point)
            check("\(name)：左键透传且不崩溃", installer.handleLeftMouseDown(left) === left && activated == 1)
            check("\(name)：右键不弹菜单", !installer.handle(event(point, type: .rightMouseDown)))
            check("\(name)：无效坐标不参与磁贴查找", EmptyAreaContextMenu.InstallerView.tileMarker(at: point, in: root) == nil)
        }
        check("无效事件不会构建菜单", menuBuilds == 0)
        for value: CGFloat in [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, CGFloat(Int.max), -42.75] {
            check("诊断安全格式化 \(value)", !TabDiagnostics.coordinate(value).isEmpty)
        }
        check("缺少窗口的激活事件被透传", installer.handleLeftMouseDown(event(normal, windowNumber: 0)) != nil && activated == 1)
        installer.removeFromSuperview()
        check("视图移出窗口立即卸载两个监听器", installer.activeMonitorCount == 0)
        check("已移出窗口的安装器不处理旧窗口事件", installer.handleLeftMouseDown(event(normal)) != nil && activated == 1)
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let secondRoot = NSView(frame: root.bounds)
        second.contentView = secondRoot
        secondRoot.addSubview(installer)
        check("移入另一个窗口后只保留一组监听器", installer.activeMonitorCount == 2)
        check("新窗口安装器不处理原窗口事件", installer.handleLeftMouseDown(event(normal)) != nil && activated == 1)
        installer.detachMonitors(); installer.detachMonitors()
        check("反复卸载监听器安全且完整", installer.activeMonitorCount == 0)
        second.orderOut(nil)
    }

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
            check("微信被识别", wechat.name == L("appData.name.com.tencent.xinWeChat", "微信"), wechat.name)
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

        let reader = ActiveTabReader(manager: manager)
        var refreshes = 0
        let readerProbe = reader.objectWillChange.sink { refreshes += 1 }
        for _ in 0..<100 { _ = reader.model; _ = reader.tab; _ = reader.tabs }
        check("读取当前页签不会发送刷新或修改状态", refreshes == 0 && reader.model === third.model)
        waitFor { manager.tabs.allSatisfy { !$0.model.isBusy } }
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        refreshes = 0
        var forwardedEvents = 0
        let forwardedProbe = manager.objectWillChange.sink { forwardedEvents += 1 }
        third.model.objectWillChange.send()
        third.model.objectWillChange.send()
        third.model.objectWillChange.send()
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        // Independent directory/clipboard completions may legitimately publish
        // later; the three synchronous events must still save two refreshes.
        check("同一轮模型事件合并成一次界面刷新", refreshes >= 1 && forwardedEvents >= 3 && refreshes <= forwardedEvents - 2,
              "刷新 \(refreshes)，源事件 \(forwardedEvents)")
        manager.select(firstTab)
        check("切换后读取器立即返回新模型", reader.model === firstTab.model)
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        refreshes = 0
        third.model.objectWillChange.send()
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        check("非活动页签不会触发当前页签刷新", refreshes == 0)
        firstTab.model.objectWillChange.send()
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        check("切换后仍接收当前模型导航变更", refreshes == 1)
        _ = readerProbe
        _ = forwardedProbe
        manager.select(third)

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

        manager.close(manager.activeTab)
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

private actor ThumbnailTestProbe {
    private var active = 0
    private(set) var peak = 0
    private var counts: [String: Int] = [:]
    func count(for url: URL) -> Int { counts[url.path, default: 0] }
    func generate(_ url: URL) async -> ImageBox {
        active += 1; peak = max(peak, active); counts[url.path, default: 0] += 1
        try? await Task.sleep(nanoseconds: 40_000_000)
        active -= 1
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 64, bitsPerPixel: 32)!
        let image = NSImage(size: NSSize(width: 16, height: 16)); image.addRepresentation(rep)
        return ImageBox(image: image)
    }
}
