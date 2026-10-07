// 侧边栏：个人收藏 / 位置 / 分类
import SwiftUI

struct SidebarView: View {
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel

    var body: some View {
        // 选中态完全由当前页签的模型驱动：
        // 绑定必须显式读 model.selection，切换页签时才能跟着换行
        List(selection: Binding<SidebarSelection?>(
            get: { model.selection },
            set: { newValue in
                guard let newValue else { return }
                model.navigate(to: newValue)
            }
        )) {
            // Windows 资源管理器顶部两个页面
            Section {
                Label {
                    Text(L("view.home", "主页"))
                } icon: {
                    Image(systemName: "house.fill").foregroundStyle(Color(nsColor: .systemBlue))
                }
                .tag(SidebarSelection.home)

                Label {
                    Text(L("view.thisPC", "此电脑"))
                } icon: {
                    Image(systemName: "pc").foregroundStyle(Color(nsColor: .systemBlue))
                }
                .tag(SidebarSelection.thisPC)
            }

            Section(NSLocalizedString("sidebar.favorites", comment: "个人收藏")) {
                ForEach(engine.places) { place in
                    row(place)
                }
            }

            Section(NSLocalizedString("sidebar.categories", comment: "按类型分类")) {
                ForEach(FileCategory.sidebarOrder) { category in
                    Label {
                        HStack {
                            Text(category.localizedName)
                            Spacer()
                            if let count = engine.categoryCounts[category], count > 0 {
                                Text("\(count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    } icon: {
                        Image(systemName: category.symbol)
                            .foregroundStyle(Color(nsColor: category.tint))
                    }
                    .tag(SidebarSelection.category(category))
                }
                if engine.countingCategories {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(NSLocalizedString("sidebar.counting", comment: "正在统计…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(NSLocalizedString("sidebar.locations", comment: "位置")) {
                Label {
                    Text(NSLocalizedString("view.applications", comment: "应用程序"))
                } icon: {
                    Image(systemName: "square.grid.2x2.fill").foregroundStyle(.blue)
                }
                .tag(SidebarSelection.applications)

                Label(L("view.appData", "应用数据"), systemImage: "shippingbox")
                    .tag(SidebarSelection.appData)

                AndroidSidebarSection()
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                HStack {
                    Button {
                        addFolder()
                    } label: {
                        Label(L("action.addFolder", "添加文件夹"), systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    /// 授权单个文件夹（沙盒下的唯一入口）
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("panel.open", "打开")
        panel.message = L("panel.addFolder.message", "选择要加入常用列表的文件夹")
        panel.directoryURL = FileSystemService.realHomeDirectory()
        if panel.runModal() == .OK {
            for url in panel.urls {
                engine.addFolder(url)
            }
            if let first = panel.urls.first {
                model.selectFolder(first)
            }
        } else if let first = engine.authorizedRoots.first {
            _ = first
        }
    }

    @ViewBuilder
    private func row(_ place: SidebarPlace) -> some View {
        Label {
            Text(place.name)
        } icon: {
            Image(systemName: place.symbol)
                .foregroundStyle(place.kind == .volume ? Color.secondary : Color.accentColor)
        }
        .tag(SidebarSelection.folder(place.url))
        .contextMenu {
            Button(NSLocalizedString("action.reveal", comment: "在访达中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([place.url])
            }
        }
    }
}

/// 侧边栏的安卓设备区块
///
/// 独立成视图有两个原因：一是避免侧边栏表达式过于复杂导致编译超时，
/// 二是它自己观察设备注册表，设备插拔后能独立刷新。
struct AndroidSidebarSection: View {
    @ObservedObject private var registry = AndroidDeviceRegistry.shared

    var body: some View {
        if !registry.devices.isEmpty {
            Section(L("sidebar.android", "安卓设备")) {
                ForEach(registry.devices) { device in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.displayName)
                            Text(subtitle(for: device))
                                .font(.caption2)
                                .foregroundStyle(device.isReady ? Color.secondary : Color.orange)
                        }
                    } icon: {
                        Image(systemName: "candybarphone")
                            .foregroundStyle(device.isReady ? Color.accentColor : Color.orange)
                    }
                    .tag(SidebarSelection.androidDevice(serial: device.serial))
                }
            }
        }
    }

    private func subtitle(for device: AndroidDevice) -> String {
        if !device.isReady {
            return device.isUnauthorized
                ? L("android.state.unauthorized", "待授权")
                : device.state
        }
        return device.androidVersion.isEmpty
            ? device.serial
            : "Android \(device.androidVersion)"
    }
}
