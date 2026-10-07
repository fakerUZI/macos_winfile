// WinFileApp: 把本地 winfile 服务包装成原生 macOS 应用（WKWebView 窗口 + Dock 图标）
import AppKit
import WebKit

// MARK: - 配置

let kDefaultPort = 8791
let kMinWidth: CGFloat = 900
let kMinHeight: CGFloat = 600

final class AppConfig {
    static let shared = AppConfig()

    /// 后端代码目录（含 winfile.py 与 winfile 包）
    let backendDir: URL
    let webDir: URL
    let pythonPath: String
    let statusFile: URL
    let iconTool: URL?
    let appsTool: URL?

    private init() {
        // 可执行文件位于 WinFile.app/Contents/MacOS/WinFile
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let contents = exe.deletingLastPathComponent().deletingLastPathComponent()
        let appBundle = contents.deletingLastPathComponent()
        let resources = contents.appendingPathComponent("Resources")
        let sibling = appBundle.deletingLastPathComponent()
        let fm = FileManager.default

        // 项目目录就在 .app 旁边时用项目源码（改代码重启即生效）；
        // 否则使用应用内置副本，保证 .app 可以单独拷贝到任何位置运行。
        let siblingBackend = sibling.appendingPathComponent("winfile.py")
        let bundledBackend = resources.appendingPathComponent("backend")
        if fm.fileExists(atPath: siblingBackend.path),
           fm.fileExists(atPath: sibling.appendingPathComponent("winfile").path) {
            backendDir = sibling
            webDir = sibling.appendingPathComponent("web")
        } else if fm.fileExists(atPath: bundledBackend.appendingPathComponent("winfile.py").path) {
            backendDir = bundledBackend
            webDir = resources.appendingPathComponent("web")
        } else {
            backendDir = sibling
            webDir = sibling.appendingPathComponent("web")
        }

        statusFile = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".winfile-mac/desktop-status.json")
        let tool = resources.appendingPathComponent("winfile-icon")
        iconTool = fm.isExecutableFile(atPath: tool.path) ? tool : nil
        let queryTool = resources.appendingPathComponent("winfile-apps")
        appsTool = fm.isExecutableFile(atPath: queryTool.path) ? queryTool : nil
        pythonPath = AppConfig.findPython()
    }

    /// 依次尝试常见 Python 3 位置
    private static func findPython() -> String {
        let candidates = [
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/bin/env"
    }
}

// MARK: - 后端进程管理

final class Backend {
    private(set) var process: Process?
    private(set) var port: Int = kDefaultPort
    private(set) var token: String = ""
    private var logHandle: FileHandle?

    var baseURL: URL? {
        guard !token.isEmpty else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/?token=\(token)")
    }

    /// 启动 python winfile.py，并等待就绪（读取状态文件）
    func start(completion: @escaping (Result<URL, Error>) -> Void) {
        try? FileManager.default.removeItem(at: AppConfig.shared.statusFile)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: AppConfig.shared.pythonPath)
        task.arguments = [
            AppConfig.shared.backendDir.appendingPathComponent("winfile.py").path,
            "--desktop",
            "--auto-port",
            "--port", String(port),
            "--web", AppConfig.shared.webDir.path,
        ]
        task.currentDirectoryURL = AppConfig.shared.backendDir
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        if let tool = AppConfig.shared.iconTool {
            env["WINFILE_ICON_TOOL"] = tool.path
        }
        if let appsTool = AppConfig.shared.appsTool {
            env["WINFILE_APPS_TOOL"] = appsTool.path
        }
        task.environment = env

        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".winfile-mac/desktop.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            task.standardOutput = handle
            task.standardError = handle
            logHandle = handle
        }

        do {
            try task.run()
        } catch {
            completion(.failure(error))
            return
        }
        process = task

        waitForReady(deadline: Date().addingTimeInterval(40), completion: completion)
    }

    private func waitForReady(deadline: Date, completion: @escaping (Result<URL, Error>) -> Void) {
        if let data = try? Data(contentsOf: AppConfig.shared.statusFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let readyPort = json["port"] as? Int,
           let readyToken = json["token"] as? String,
           !readyToken.isEmpty {
            port = readyPort
            token = readyToken
            if let url = baseURL {
                completion(.success(url))
                return
            }
        }
        if Date() > deadline {
            completion(.failure(NSError(domain: "WinFile", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "后端启动超时，请查看 ~/.winfile-mac/desktop.log",
            ])))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitForReady(deadline: deadline, completion: completion)
        }
    }

    /// 仅用于兜底探测端口是否被占用
    func portIsFree(_ candidate: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return true }
        defer { close(socketFD) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(candidate).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        try? logHandle?.close()
    }
}

// MARK: - 窗口

final class MainWindowController: NSWindowController, WKNavigationDelegate, NSWindowDelegate {
    private let webView: WKWebView
    private let backend = Backend()
    private let statusLabel = NSTextField(labelWithString: "正在启动本地文件服务…")
    private let spinner = NSProgressIndicator()

    init() {
        let frame = NSRect(x: 0, y: 0, width: 1360, height: 860)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "WinFile — 文件管理器"
        window.minSize = NSSize(width: kMinWidth, height: kMinHeight)
        window.titlebarAppearsTransparent = false
        window.center()
        window.setFrameAutosaveName("WinFileMainWindow")

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: frame, configuration: config)
        super.init(window: window)

        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        window.contentView = webView
        window.delegate = self

        showOverlay()
        start()
    }

    required init?(coder: NSCoder) { fatalError("不支持 nib") }

    private func showOverlay() {
        guard let content = window?.contentView else { return }
        statusLabel.frame = NSRect(x: 0, y: content.bounds.midY + 8, width: content.bounds.width, height: 24)
        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.autoresizingMask = [.width]
        spinner.frame = NSRect(x: content.bounds.midX - 12, y: content.bounds.midY - 28, width: 24, height: 24)
        spinner.style = .spinning
        spinner.startAnimation(nil)
        content.addSubview(spinner)
        content.addSubview(statusLabel)
    }

    private func hideOverlay() {
        spinner.stopAnimation(nil)
        spinner.removeFromSuperview()
        statusLabel.removeFromSuperview()
    }

    private func start() {
        // 端口被占用时向后找一个空闲端口
        if !backend.portIsFree(kDefaultPort) {
            for candidate in (kDefaultPort + 1)...(kDefaultPort + 20) where backend.portIsFree(candidate) {
                backend.setPort(candidate)
                break
            }
        }
        backend.start { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    self.hideOverlay()
                    self.webView.load(URLRequest(url: url))
                case .failure(let error):
                    self.statusLabel.stringValue = "启动失败：\(error.localizedDescription)"
                    self.spinner.stopAnimation(nil)
                }
            }
        }
    }

    func shutdown() {
        backend.stop()
    }

    // MARK: NSWindowDelegate

    /// 关闭窗口即退出应用（避免留下无窗口的后台进程）
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        statusLabel.stringValue = "无法连接本地服务：\(error.localizedDescription)"
    }
}

extension Backend {
    func setPort(_ value: Int) { port = value }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let controller = MainWindowController()
        windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.shutdown()
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 WinFile", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 WinFile", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 WinFile", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        viewMenu.addItem(withTitle: "重新载入", action: #selector(MainWindowController.reloadPage(_:)), keyEquivalent: "r")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

extension MainWindowController {
    @objc func reloadPage(_ sender: Any?) {
        webView.reload()
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
