// 设置窗口（原生 Settings 场景，符合 macOS 规范）
import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: FSEngine
    @AppStorage("StartFolderPath") private var startFolderPath: String = ""
    @AppStorage("ShowHiddenFiles") private var showHidden: Bool = false
    @AppStorage("ViewLayout") private var layoutRaw: String = ViewLayout.details.rawValue

    var body: some View {
        TabView {
            general
                .tabItem { Label(NSLocalizedString("settings.general", comment: "通用"), systemImage: "gearshape") }
            privacy
                .tabItem { Label(NSLocalizedString("settings.privacy", comment: "隐私与授权"), systemImage: "lock.shield") }
            about
                .tabItem { Label(NSLocalizedString("settings.about", comment: "关于"), systemImage: "info.circle") }
        }
        .frame(width: 480, height: 320)
    }

    private var general: some View {
        Form {
            Section {
                Picker(NSLocalizedString("settings.layout", comment: "默认视图"), selection: $layoutRaw) {
                    Text(NSLocalizedString("layout.details", comment: "详细信息")).tag(ViewLayout.details.rawValue)
                    Text(NSLocalizedString("layout.icons", comment: "大图标")).tag(ViewLayout.icons.rawValue)
                }
                Toggle(NSLocalizedString("settings.showHidden", comment: "显示隐藏文件"), isOn: $showHidden)
            }

            Section {
                HStack {
                    Text(NSLocalizedString("settings.startFolder", comment: "启动时打开"))
                    Spacer()
                    Text(startFolderPath.isEmpty
                         ? NSLocalizedString("settings.startFolder.default", comment: "上次使用的位置")
                         : (startFolderPath as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(NSLocalizedString("settings.choose", comment: "选择…")) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            startFolderPath = url.path
                        }
                    }
                    Button(NSLocalizedString("settings.clear", comment: "清除")) { startFolderPath = "" }
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
                        for url in panel.urls { engine.addFolder(url) }
                    }
                }
                Button(role: .destructive) {
                    engine.removeAllAddedFolders()
                } label: {
                    Text(L("settings.folders.clear", "清空列表"))
                }
                .disabled(engine.authorizedRoots.isEmpty)
            }

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
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                 ?? NSLocalizedString("app.name", comment: "应用名"))
                .font(.title3).fontWeight(.semibold)
            Text(String(format: NSLocalizedString("settings.version", comment: "版本"),
                        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("settings.about.description", comment: "应用说明"))
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30)
            Spacer()
        }
        .padding(.top, 18)
    }
}
