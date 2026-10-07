// 内容区（主页 / 此电脑 / 文件列表 / 空状态 / 状态栏）
//
// 关键：本视图用 `@ObservedObject` **直接持有** BrowserModel。
// 内容区原先挂在 MainView 的计算属性上，而 MainView 不随模型变化重绘，
// 于是文件列表一直绑定在旧模型上 —— 表现为"在主页点了文件夹，
// 地址栏变了，但列表还是主页，要切换页签才显示正确内容"。
import AppKit
import SwiftUI

struct TabContentHost: View {
    @ObservedObject var engine: FSEngine
    /// 直接观察 TabManager：切换页签与页签内导航都会触发本视图重新求值。
    /// （此前经由 reader 间接取模型，切页签时 reader 未重新绑定，
    ///  导致内容区一直停留在旧页签的模型上。）
    @ObservedObject var reader: ActiveTabReader
    @Binding var dialog: DialogKind?
    let openFolderPanel: () -> Void

    /// 每次求值都从 reader 解析当前模型，绝不缓存副本
    private var model: BrowserModel { reader.model }

    /// 当前渲染的视图类型（供自动化验证内容区是否真的切换）
    private var renderedKind: String {
        if model.isHomeView { return "home" }
        if model.isThisPCView { return "thisPC" }
        if model.isCategoryView { return "category:\(model.categoryFilter?.rawValue ?? "")" }
        if model.layout == .icons { return "icons:\(model.currentDirectory?.lastPathComponent ?? "-")" }
        return "details:\(model.currentDirectory?.lastPathComponent ?? "-")"
    }

    /// 登记当前渲染的视图类型（供自动化验证内容区是否随导航切换）
    private func logRender() -> Bool {
        WindowBridge.shared.recordContentKind(renderedKind)
        return true
    }

    /// 内容区当前渲染的类型（供诊断输出）
    var currentRenderedKind: String { renderedKind }

    var body: some View {
        let _ = logRender()
        ZStack {
            if model.isHomeView {
                HomeView(engine: engine, manager: reader.manager)
            } else if model.isThisPCView {
                ThisPCView(engine: engine, manager: reader.manager)
            } else if model.isAppDataView {
                AppDataView(engine: engine, model: model)
            } else if case .androidDevice(let serial) = model.selection {
                AndroidDeviceView(engine: engine, model: model, serial: serial)
            } else if model.layout == .details {
                FileTableView(engine: engine, model: model, dialog: $dialog)
            } else {
                FileIconGridView(engine: engine, model: model, dialog: $dialog)
            }
            if model.displayedItems.isEmpty && !model.isBusy
                && !model.isHomeView && !model.isThisPCView {
                EmptyStateView(engine: engine, model: model, openPanel: openFolderPanel)
            }
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .top) {
            if let progress = model.transferProgress {
                AndroidTransferBanner(progress: progress)
            }
        }
        .overlay(alignment: .bottom) {
            StatusBarView(engine: engine, model: model)
        }
    }
}
