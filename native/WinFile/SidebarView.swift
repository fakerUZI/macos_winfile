// 侧边栏：个人收藏 / 位置 / 分类
import SwiftUI

struct SidebarView: View {
    @ObservedObject private var localization = Localization.shared
    @State private var showSidebarManager = false
    @State private var showAddFolder = false
    @State private var isDropTargeted = false
    @AppStorage("Sidebar.FavoritesExpanded") private var favoritesExpanded = true
    @AppStorage("Sidebar.CategoriesExpanded") private var categoriesExpanded = true
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel
    /// 分类的显示与顺序（右键菜单与拖拽排序共用）
    @ObservedObject private var preferences = SidebarPreferences.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("sidebar.navigation", "导航")).font(.headline).foregroundStyle(.secondary)
                Spacer()
                Button { showSidebarManager = true } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(L("sidebar.manage", "管理侧边栏…"))
                .accessibilityLabel(L("sidebar.manage", "管理侧边栏…"))
            }.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            navigationList
            sidebarFooter
        }
        .background(InterfaceStyle.chrome)
        .sheet(isPresented: $showSidebarManager) { SidebarManagerSheet(engine: engine) }
        .sheet(isPresented: $showAddFolder) {
            FolderPickerSheet(initialDirectory: model.currentSidebarFolder) { model.addFoldersToSidebar($0) }
        }
        .onDrop(of: [.fileURL], delegate: folderDropDelegate)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private var navigationList: some View {
        List(selection: Binding<SidebarSelection?>(
            get: { model.sidebarSelection },
            set: { newValue in
                guard let newValue else { return }
                model.selectSidebarDestination(newValue)
            }
        )) {
            // Windows 资源管理器顶部两个页面
            Section {
                Label {
                    Text(L("view.home", "主页"))
                } icon: {
                    Image(systemName: "house.fill").foregroundStyle(Color.secondary)
                }
                .tag(SidebarSelection.home)

                Label {
                    Text(L("view.thisPC", "此电脑"))
                } icon: {
                    Image(systemName: "pc").foregroundStyle(Color.secondary)
                }
                .tag(SidebarSelection.thisPC)

            }

            Section {
                if favoritesExpanded {
                    ForEach(Array(engine.authorizedRoots.enumerated()), id: \.element.path) { index, url in
                        favoriteRow(url, index: index)
                    }
                    // 空列表时给出提示，避免看起来像坏了
                    if engine.authorizedRoots.isEmpty {
                        Text(L("sidebar.favorites.empty", "右键可管理收藏"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .onDrop(of: [.fileURL], delegate: folderDropDelegate)
                    }
                }
            } header: {
                sectionHeader(WLocalizedString("sidebar.favorites", comment: "个人收藏"), expanded: $favoritesExpanded)
            }

            Section {
                if categoriesExpanded {
                    ForEach(SidebarPreferences.shared.visibleCategories) { category in
                        Label {
                            HStack {
                                Text(category.localizedName)
                                Spacer()
                                if let count = engine.categoryCounts[category], count > 0 {
                                    Text(count >= FileSystemService.categoryBudget ? "\(count)+" : "\(count)")
                                        .help(L("scan.badgeScope", "初始扫描范围内的计数；可进入分类继续深入扫描。"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.09), in: Capsule())
                                }
                            }
                        } icon: {
                            Image(systemName: category.symbol)
                                .foregroundStyle(Color.secondary)
                        }
                        .tag(SidebarSelection.category(category))
                        .contextMenu {
                            Button(L("sidebar.moveUp", "上移")) { preferences.move(category, by: -1) }
                                .disabled(!preferences.canMove(category, by: -1))
                            Button(L("sidebar.moveDown", "下移")) { preferences.move(category, by: 1) }
                                .disabled(!preferences.canMove(category, by: 1))
                            Divider()
                            Button(L("sidebar.remove", "从侧边栏移除")) { preferences.hide(category) }
                                .disabled(preferences.visibleCategories.count <= 1)
                            Button(L("sidebar.manage", "管理侧边栏…")) { showSidebarManager = true }
                        }
                    }
                    if engine.countingCategories {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(WLocalizedString("sidebar.counting", comment: "正在统计…"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                sectionHeader(WLocalizedString("sidebar.categories", comment: "按类型分类"), expanded: $categoriesExpanded)
            }

            Section(WLocalizedString("sidebar.locations", comment: "位置")) {
                Label {
                    Text(L("place.applications", "应用程序"))
                } icon: {
                    Image(systemName: "square.grid.2x2.fill").foregroundStyle(.secondary)
                }
                .tag(SidebarSelection.applications)

                Label(L("view.appData", "应用数据"), systemImage: "shippingbox")
                    .tag(SidebarSelection.appData)

            }
            AndroidSidebarSection()
        }
        .listStyle(.sidebar)
    }

    private func sectionHeader(_ title: String, expanded: Binding<Bool>) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down").font(.caption2)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded.wrappedValue ? L("sidebar.expanded", "已展开") : L("sidebar.collapsed", "已折叠"))
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { model.selectSidebarDestination(.storageCleanup) } label: {
                Label(L("cleanup.title", "空间清理"), systemImage: "externaldrive.badge.minus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .foregroundStyle(model.sidebarSelection == .storageCleanup ? Color.accentColor : .primary)
                    .background(model.sidebarSelection == .storageCleanup ? Color.accentColor.opacity(0.13) : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(model.sidebarSelection == .storageCleanup ? .isSelected : [])
            Divider().opacity(0.6)
            Button { showAddFolder = true } label: {
                Label(L("action.addFolder", "添加文件夹"), systemImage: "plus")
            }.buttonStyle(.borderless)
            Label(L("sidebar.dropHint", "拖入文件夹以添加到个人收藏"), systemImage: "folder.badge.plus")
                .font(.caption2).foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .onDrop(of: [.fileURL], delegate: folderDropDelegate)
    }

    private var folderDropDelegate: SidebarFolderDropDelegate {
        SidebarFolderDropDelegate(isTargeted: $isDropTargeted) { urls, failed in
            model.addFoldersToSidebar(urls, unresolvedCount: failed)
        }
    }

    @ViewBuilder
    /// 收藏行：支持右键上移/下移/移除
    private func favoriteRow(_ url: URL, index: Int) -> some View {
        Label {
            Text(url.lastPathComponent)
        } icon: {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
        }
        .tag(SidebarSelection.folder(url))
        .help(url.path)
        .contextMenu {
            Button(L("action.open", "打开")) { model.selectFolder(url) }
            Button(WLocalizedString("action.reveal", comment: "在访达中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            Button(L("sidebar.moveUp", "上移")) { engine.moveFolder(url, by: -1) }
                .disabled(!engine.canMoveFolder(url, by: -1))
            Button(L("sidebar.moveDown", "下移")) { engine.moveFolder(url, by: 1) }
                .disabled(!engine.canMoveFolder(url, by: 1))
            Divider()
            Button(L("sidebar.remove", "从侧边栏移除")) { engine.removeFolder(url) }
            Button(L("sidebar.addFolder", "添加文件夹…")) { showAddFolder = true }
        }
        .onDrop(of: [.fileURL], delegate: folderDropDelegate)
    }
}

/// 侧边栏的安卓设备区块
///
/// 独立成视图有两个原因：一是避免侧边栏表达式过于复杂导致编译超时，
/// 二是它自己观察设备注册表，设备插拔后能独立刷新。
struct AndroidSidebarSection: View {
    @ObservedObject private var localization = Localization.shared
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
                            .foregroundStyle(device.isReady ? Color.secondary : Color.orange)
                    }
                    .tag(SidebarSelection.androidDevice(serial: device.serial))
                }
            }
        }
    }

    private func subtitle(for device: AndroidDevice) -> String {
        if !device.isReady {
            return L("android.mtp.waiting", "等待文件传输就绪")
        }
        return "MTP"
    }
}
