// 侧边栏管理（多选框形式）
//
// 需求：个人收藏与类型分类支持新增、删减子项目，用多选框呈现，并支持排序。
// 设计：一个面板同时管理两类内容，勾选即显示、取消即隐藏；
//       每一项都可用上下按钮调整顺序。
import SwiftUI
import UniformTypeIdentifiers

struct SidebarManagerSheet: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    @ObservedObject private var preferences = SidebarPreferences.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isChoosingFolder = false
    @State private var folderMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    categorySection
                    Divider()
                    favoriteSection
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 520)
        .sheet(isPresented: $isChoosingFolder) {
            FolderPickerSheet { urls in
                let result = engine.addFolders(urls)
                folderMessage = result.statusMessage
                return result
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "sidebar.left")
                .foregroundStyle(Color.accentColor)
            Text(L("sidebarManager.title", "管理侧边栏"))
                .font(.headline)
            Spacer()
        }
        .padding(14)
    }

    private var footer: some View {
        HStack {
            Button(L("sidebarManager.reset", "恢复默认")) {
                preferences.resetToDefault()
                engine.removeAllAddedFolders()
                engine.seedStandardFavorites()
            }
            Spacer()
            Button(L("button.done", "完成")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    // MARK: - 按类型分类

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L("sidebar.categories", "按类型分类"),
                         hint: L("sidebarManager.categoryHint", "勾选即在侧边栏显示"))

            ForEach(preferences.allCategoriesInOrder) { category in
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { preferences.isVisible(category) },
                        set: { $0 ? preferences.show(category) : preferences.hide(category) }
                    )) {
                        HStack(spacing: 6) {
                            Image(systemName: category.symbol)
                                .foregroundStyle(Color(nsColor: category.tint))
                                .frame(width: 18)
                            Text(category.localizedName)
                        }
                    }
                    .toggleStyle(.checkbox)
                    // 至少保留一个可见，避免侧边栏分类区块变空
                    .disabled(preferences.isVisible(category) && preferences.visibleCategories.count <= 1)

                    Spacer()

                    orderButtons(
                        canUp: preferences.canMove(category, by: -1),
                        canDown: preferences.canMove(category, by: 1),
                        up: { preferences.move(category, by: -1) },
                        down: { preferences.move(category, by: 1) }
                    )
                }
            }
        }
    }

    // MARK: - 个人收藏

    private var favoriteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L("sidebar.favorites", "个人收藏"),
                         hint: L("sidebarManager.favoriteHint", "勾选即在侧边栏显示；可添加任意文件夹"))

            ForEach(Array(engine.authorizedRoots.enumerated()), id: \.element.path) { _, url in
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { true },
                        set: { if !$0 { engine.removeFolder(url) } }
                    )) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 18)
                            Text(url.lastPathComponent)
                            Text((url.path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.checkbox)

                    Spacer()

                    orderButtons(
                        canUp: engine.canMoveFolder(url, by: -1),
                        canDown: engine.canMoveFolder(url, by: 1),
                        up: { engine.moveFolder(url, by: -1) },
                        down: { engine.moveFolder(url, by: 1) }
                    )
                }
            }

            if engine.authorizedRoots.isEmpty {
                Text(L("settings.folders.empty", "尚未添加常用文件夹。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                isChoosingFolder = true
            } label: {
                Label(L("settings.folders.add", "添加文件夹…"), systemImage: "plus")
            }
            .padding(.top, 2)
            if let folderMessage {
                Text(folderMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 组件

    private func sectionTitle(_ title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func orderButtons(canUp: Bool, canDown: Bool,
                              up: @escaping () -> Void, down: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Button(action: up) {
                Image(systemName: "chevron.up").font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(!canUp)
            .help(L("sidebar.moveUp", "上移"))

            Button(action: down) {
                Image(systemName: "chevron.down").font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(!canDown)
            .help(L("sidebar.moveDown", "下移"))
        }
    }
}
