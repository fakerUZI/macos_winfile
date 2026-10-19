// 设置窗口（原生 Settings 场景，符合 macOS 规范）
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    @ObservedObject private var updater = AppUpdater.shared
    @AppStorage("StartFolderPath") private var startFolderPath: String = ""
    @AppStorage("ShowHiddenFiles") private var showHidden: Bool = false
    @AppStorage("ViewLayout") private var layoutRaw: String = ViewLayout.details.rawValue

    var body: some View {
        TabView {
            general
                .tabItem { Label(WLocalizedString("settings.general", comment: "通用"), systemImage: "gearshape") }
            privacy
                .tabItem { Label(WLocalizedString("settings.privacy", comment: "隐私与授权"), systemImage: "lock.shield") }
            about
                .tabItem { Label(WLocalizedString("settings.about", comment: "关于"), systemImage: "info.circle") }
        }
        .frame(width: 480, height: 320)
    }

    private var general: some View {
        Form {
            Section {
                Picker(L("settings.language", "语言"), selection: $localization.language) {
                    Text(L("settings.language.system", "跟随系统")).tag(AppLanguage.system)
                    Text("简体中文").tag(AppLanguage.simplifiedChinese)
                    Text("English").tag(AppLanguage.english)
                }
                Text(L("settings.language.hint", "切换后立即生效；不支持的系统语言使用英文。"))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(WLocalizedString("settings.layout", comment: "默认视图"), selection: $layoutRaw) {
                    Text(WLocalizedString("layout.details", comment: "详细信息")).tag(ViewLayout.details.rawValue)
                    Text(WLocalizedString("layout.icons", comment: "大图标")).tag(ViewLayout.icons.rawValue)
                }
                Toggle(WLocalizedString("settings.showHidden", comment: "显示隐藏文件"), isOn: $showHidden)
                Toggle(L("update.automatic", "每次启动时检查更新"), isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                ))
                Text(L("update.hint", "发现新版本时提示安装；可以跳过此版本或下次再说。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text(WLocalizedString("settings.startFolder", comment: "启动时打开"))
                    Spacer()
                    Text(startFolderPath.isEmpty
                         ? WLocalizedString("settings.startFolder.default", comment: "上次使用的位置")
                         : (startFolderPath as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(WLocalizedString("settings.choose", comment: "选择…")) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            startFolderPath = url.path
                        }
                    }
                    Button(WLocalizedString("settings.clear", comment: "清除")) { startFolderPath = "" }
                        .disabled(startFolderPath.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            Section {
                Text(L("settings.local.explain",
                       "本应用为本地使用形态，未启用沙盒，可直接访问整个磁盘（包括其它应用的数据目录）。"))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent(L("settings.folders.count", "常用文件夹"),
                               value: "\(engine.authorizedRoots.count)")
                ForEach(engine.authorizedRoots, id: \.path) { url in
                    HStack {
                        Image(systemName: "folder")
                        Text((url.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            engine.removeFolder(url)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(L("settings.folders.remove", "从列表移除"))
                    }
                }
                Button(L("settings.folders.add", "添加文件夹…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = true
                    panel.prompt = L("panel.open", "打开")
                    if panel.runModal() == .OK {
                        engine.addFolders(panel.urls)
                    }
                }
                Button(role: .destructive) {
                    engine.removeAllAddedFolders()
                } label: {
                    Text(L("settings.folders.clear", "清空列表"))
                }
                .disabled(engine.authorizedRoots.isEmpty)
            }

            sidebarSection

            associationsSection

            Section {
                Text(L("settings.diagnostics.explain", "遇到页签点击没反应等问题时，可先复现一次，再把日志发给我定位。"))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("settings.diagnostics.open", "打开诊断日志")) {
                        NSWorkspace.shared.open(TabDiagnostics.liveURL)
                    }
                    Button(L("settings.diagnostics.reveal", "在访达中显示")) {
                        NSWorkspace.shared.activateFileViewerSelecting([TabDiagnostics.liveURL])
                    }
                    Button(L("settings.diagnostics.clear", "清空日志")) {
                        try? FileManager.default.removeItem(at: TabDiagnostics.liveURL)
                        TabDiagnostics.shared.record("diagnostics.cleared")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        VStack(spacing: 10) {
            if let icon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon).resizable().frame(width: 72, height: 72)
            }
            Text(WLocalizedString("app.name", comment: "应用名"))
                .font(.title3).fontWeight(.semibold)
            Text(String(format: WLocalizedString("settings.version", comment: "版本"),
                        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(WLocalizedString("settings.about.description", comment: "应用说明"))
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30)
            Button(L("update.check", "检查更新…")) { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            if updater.waitingForFileOperations {
                Text(L("update.waiting", "文件操作完成后将安装更新并重新启动。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 18)
    }

    // MARK: - 侧边栏管理（分类与常用文件夹）

    @ViewBuilder
    private var sidebarSection: some View {
        SidebarManagementSection(engine: engine)
    }
    // MARK: - 默认打开方式（仅本应用）

    @ViewBuilder
    private var associationsSection: some View {
        AssociationsSection()
    }

}

/// 侧边栏管理：按类型分类与个人收藏的增删
///
/// 需求：支持删除和新增，但**只能从现有条目里选** ——
/// 因此分类管理的是"显示/隐藏"，收藏管理的是"从已有文件夹里挑选"。
struct SidebarManagementSection: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    @ObservedObject private var preferences = SidebarPreferences.shared

    @State private var isChoosingFolder = false

    var body: some View {
        Section {
            // 当前显示的分类
            ForEach(preferences.visibleCategories) { category in
                HStack {
                    Image(systemName: category.symbol)
                        .foregroundStyle(Color(nsColor: category.tint))
                    Text(category.localizedName)
                    Spacer()
                    Button {
                        preferences.hide(category)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L("settings.categories.remove", "从侧边栏移除"))
                    .disabled(preferences.visibleCategories.count <= 1)
                }
            }
            // 已移除的分类：可加回
            if !preferences.hiddenCategoryList.isEmpty {
                Divider()
                ForEach(preferences.hiddenCategoryList) { category in
                    HStack {
                        Image(systemName: category.symbol)
                            .foregroundStyle(.tertiary)
                        Text(category.localizedName)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            preferences.show(category)
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(L("settings.categories.add", "加入到侧边栏"))
                    }
                }
            }
            HStack {
                Button(L("settings.categories.reset", "恢复默认")) {
                    preferences.resetToDefault()
                }
                .disabled(preferences.hiddenCategoryList.isEmpty)
            }
        } header: {
            Text(L("settings.categories.title", "按类型分类"))
        } footer: {
            Text(L("settings.categories.footer",
                   "移除只是不在侧边栏显示，不会删除任何文件。"))
                .font(.caption)
        }

        Section {
            ForEach(engine.authorizedRoots, id: \.path) { url in
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                    Text((url.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        engine.removeFolder(url)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L("settings.folders.remove", "从列表移除"))
                }
            }
            if engine.authorizedRoots.isEmpty {
                Text(L("settings.folders.empty", "尚未添加常用文件夹。"))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(L("settings.folders.add", "添加文件夹…")) { isChoosingFolder = true }
                if !engine.authorizedRoots.isEmpty {
                    Button(role: .destructive) {
                        engine.removeAllAddedFolders()
                    } label: {
                        Text(L("settings.folders.clear", "清空列表"))
                    }
                }
            }
        } header: {
            Text(L("settings.folders.title", "个人收藏"))
        } footer: {
            Text(L("settings.folders.footer",
                   "从已有文件夹中选择；只是快捷入口，不影响可访问范围。"))
                .font(.caption)
        }
        .sheet(isPresented: $isChoosingFolder) {
            FolderPickerSheet { engine.addFolders($0) }
        }
    }

}

/// 管理 WinFile 内的默认打开方式
///
/// 这些设置只存在本应用的 UserDefaults 中，**不会调用系统 API 修改
/// macOS 的文件关联** —— 访达与其它应用仍按系统设置打开。
struct AssociationsSection: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject private var associations = FileAssociations.shared
    @ObservedObject private var defaultApps = DefaultAppService.shared

    var body: some View {
        Section {
            Toggle(L("settings.assoc.showBadge", "在文件图标右下角显示关联应用"),
                   isOn: $defaultApps.showsBadges)
            if associations.entries.isEmpty {
                Text(L("settings.assoc.empty", "尚未设置。可在文件右键菜单中指定。"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(associations.entries, id: \.ext) { entry in
                    HStack {
                        Text(".\(entry.ext)")
                            .monospaced()
                            .frame(width: 60, alignment: .leading)
                        Image(nsImage: NSWorkspace.shared.icon(forFile: entry.app.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(entry.app.deletingPathExtension().lastPathComponent)
                        Spacer()
                        Button {
                            associations.clear(extension: entry.ext)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(L("settings.assoc.remove", "恢复跟随系统"))
                    }
                }
                Button(role: .destructive) {
                    associations.clearAll()
                } label: {
                    Text(L("settings.assoc.clearAll", "全部恢复跟随系统"))
                }
            }
        } header: {
            Text(L("settings.assoc.title", "默认打开方式"))
        } footer: {
            Text(L("settings.assoc.hint", "只影响本应用，不会改动 macOS 的文件关联设置。"))
                .font(.caption)
        }
    }
}
