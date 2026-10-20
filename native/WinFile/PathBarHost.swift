// 地址栏（面包屑 + 路径补全）
//
// 关键：本视图用 @ObservedObject **直接持有** BrowserModel。
// 这些界面原先挂在 MainView 上、通过计算属性取模型 —— 计算属性不建立观察依赖，
// 于是同一页签内导航后地址栏不会重绘，表现为"路径只有切换页签时才变"。
import AppKit
import SwiftUI

struct PathBarHost: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel
    @Binding var editingPath: Bool
    @Binding var pathText: String
    let suggestions: [PathSuggestion]
    let onCommitPath: () -> Void
    let onTextChange: (String) -> Void
    let onAcceptSuggestion: (PathSuggestion, Bool) -> Void
    let onCancelEdit: () -> Void
    let onBeginEditing: () -> Void

    var body: some View {
        // 登记当前地址栏身份与求值次数：供自动化测试定位"哪一层没有重绘"
        WindowBridge.shared.pathBarEvaluations += 1
        WindowBridge.shared.currentAddressIdentity = addressIdentity

        return addressContent
    }

    /// 当前地址栏应表达的位置（路径或页面名）：用作视图身份，路径变化即强制重建
    var addressIdentity: String {
        if model.isCleanupView { return "page:storageCleanup" }
        if model.isHomeView { return "page:home" }
        if model.isThisPCView { return "page:thispc" }
        if model.isCategoryView { return "page:category:\(model.categoryFilter?.rawValue ?? "")" }
        if let dir = model.currentDirectory { return "path:\(dir.path)" }
        return "page:unknown"
    }

    var addressContent: some View {
        ZStack(alignment: .leading) {
            if editingPath {
                PathField(
                    text: $pathText,
                    suggestions: suggestions,
                    onSubmit: { value in
                        pathText = value
                        onCommitPath()
                    },
                    onCancel: {
                        editingPath = false
                        onCancelEdit()
                    },
                    onTextChange: { value in
                        pathText = value
                        onTextChange(value)
                    },
                    onAcceptSuggestion: { suggestion, descend in
                        onAcceptSuggestion(suggestion, descend)
                    }
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(crumbSegments.enumerated()), id: \.element.url) { index, segment in
                            if index > 0 {
                                Image(systemName: "chevron.compact.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            Button {
                                model.selectFolder(segment.url)
                            } label: {
                                HStack(spacing: 4) {
                                    if index == 0 {
                                        Image(systemName: segment.symbol)
                                    }
                                    Text(segment.title)
                                        .fontWeight(index == crumbSegments.count - 1 ? .semibold : .regular)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                            }
                            .disabled(model.isWeChatCleanupView || model.isStorageCleanupView)
                            .buttonStyle(.borderless)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(index == crumbSegments.count - 1 ? Color.accentColor.opacity(0.12) : .clear)
                            )
                        }
                        Spacer(minLength: 0)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onBeginEditing() }
                .help(WLocalizedString("path.hint", comment: "双击可编辑路径，支持补全"))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24)
        .overlay(alignment: .topLeading) {
            if editingPath && !suggestions.isEmpty {
                PathSuggestionList(suggestions: suggestions) { suggestion in
                    onAcceptSuggestion(suggestion, false)
                }
                .offset(y: 30)
                .zIndex(10)
            }
        }
    }

    struct Crumb { let title: String; let url: URL; let symbol: String }

    var crumbSegments: [Crumb] {
        if model.isHomeView {
            return [Crumb(title: L("view.home", "主页"),
                          url: FileSystemService.realHomeDirectory(), symbol: "house.fill")]
        }
        if model.isThisPCView {
            return [Crumb(title: L("view.thisPC", "此电脑"),
                          url: URL(fileURLWithPath: "/"), symbol: "pc")]
        }
        guard let dir = model.currentDirectory else {
            return [Crumb(title: model.windowSubtitle, url: engine.browsableRoots.first ?? URL(fileURLWithPath: "/"),
                          symbol: "square.grid.2x2")]
        }
        if let (serial, _) = AndroidURL.split(dir) {
            return AndroidURL.ancestors(dir).enumerated().map { index, url in
                Crumb(title: index == 0
                      ? (AndroidDeviceRegistry.shared.device(serial: serial)?.displayName ?? L("view.androidDevice", "安卓设备"))
                      : url.lastPathComponent,
                      url: url, symbol: index == 0 ? "candybarphone" : "folder")
            }
        }
        let components = dir.pathComponents
        var result: [Crumb] = []
        var accumulated = URL(fileURLWithPath: "/")
        for (index, component) in components.enumerated() {
            if index == 0 {
                result.append(Crumb(title: WLocalizedString("place.macintoshHD", comment: "启动磁盘"),
                                    url: accumulated, symbol: "internaldrive"))
                continue
            }
            accumulated.appendPathComponent(component)
            let title: String
            if component == FileSystemService.realHomeDirectory().lastPathComponent {
                title = WLocalizedString("place.home", comment: "个人文件夹")
            } else if component == "var" || component == "private" {
                title = component
            } else {
                title = component
            }
            result.append(Crumb(title: title, url: accumulated, symbol: "folder"))
        }
        return result
    }
}
