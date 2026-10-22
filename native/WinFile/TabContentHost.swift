// 内容区（主页 / 此电脑 / 文件列表 / 空状态 / 状态栏）
//
// 关键：本视图用 `@ObservedObject` **直接持有** BrowserModel。
// 内容区原先挂在 MainView 的计算属性上，而 MainView 不随模型变化重绘，
// 于是文件列表一直绑定在旧模型上 —— 表现为"在主页点了文件夹，
// 地址栏变了，但列表还是主页，要切换页签才显示正确内容"。
import AppKit
import SwiftUI

struct TabContentHost: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    /// Each cached view is permanently bound to its own tab model.
    @ObservedObject var model: BrowserModel
    @Binding var dialog: DialogKind?
    let openFolderPanel: () -> Void

    /// 当前渲染的视图类型（供自动化验证内容区是否真的切换）
    static func renderedKind(for model: BrowserModel) -> String {
        if model.isStorageCleanupView { return "storageCleanup" }
        if model.isWeChatCleanupView { return "wechatCleanup" }
        if model.isHomeView { return "home" }
        if model.isThisPCView { return "thisPC" }
        if model.isCategoryView { return "category:\(model.categoryFilter?.rawValue ?? "")" }
        if model.layout == .icons { return "icons:\(model.currentDirectory?.lastPathComponent ?? "-")" }
        return "details:\(model.currentDirectory?.lastPathComponent ?? "-")"
    }

    /// 登记当前渲染的视图类型（供自动化验证内容区是否随导航切换）
    private func logRender() -> Bool {
        if model.tabManager?.activeModel === model {
            WindowBridge.shared.recordContentKind(Self.renderedKind(for: model))
        }
        return true
    }

    /// 内容区当前渲染的类型（供诊断输出）
    var currentRenderedKind: String { Self.renderedKind(for: model) }

    private var androidTransferCancellation: (() -> Void)? {
        guard model.transferProgress != nil else { return nil }
        return { model.cancelAndroidTransfer() }
    }

    var body: some View {
        let _ = logRender()
        ZStack {
            if model.isHomeView, let manager = model.tabManager {
                HomeView(engine: engine, manager: manager, tabModel: model)
            } else if model.isThisPCView, let manager = model.tabManager {
                ThisPCView(engine: engine, manager: manager, tabModel: model)
            } else if model.isCleanupView {
                CleanupHubView(model: model, dialog: $dialog)
            } else if model.isAppDataView {
                AppDataView(engine: engine, model: model)
            } else if case .androidDevice(let serial) = model.selection {
                AndroidDeviceView(model: model, serial: serial)
            } else if model.layout == .details {
                FileTableView(engine: engine, model: model, dialog: $dialog)
            } else {
                FileIconGridView(engine: engine, model: model, dialog: $dialog)
            }
            // 仅文件列表视图才显示空状态；自定义页面（主页/此电脑/应用数据/
            // 安卓设备/应用程序）不使用 displayedItems，否则会误报"此文件夹为空"
            if model.showsFileList && !model.isBusy {
                if let error = model.directoryReadError, !model.isSearching, !model.isCategoryView {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.questionmark").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text(L("directory.unavailable", "无法读取此文件夹")).font(.headline)
                        Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button(L("directory.retry", "重新读取")) { model.reload() }
                            Button(L("panel.open", "打开")) { openFolderPanel() }
                        }
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor))
                } else if model.displayedItems.isEmpty {
                    EmptyStateView(engine: engine, model: model, openPanel: openFolderPanel)
                }
            }
            if model.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    if model.isSearching || model.isLoadingCategory {
                        Button(L("button.cancel", "取消")) { model.cancelScan() }
                    }
                }
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .background(FileKeyboardShortcuts(model: model).frame(width: 0, height: 0))
        .onAppear { model.beginWatchingDirectory() }
        .onChange(of: model.currentDirectory) { _ in model.beginWatchingDirectory() }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                if let message = model.scanCompletenessMessage {
                    HStack {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("scan.continue", "继续加载 / 深入扫描")) { model.expandScan() }
                            .disabled(!model.canExpandScan)
                    }.padding(8).background(.regularMaterial)
                }
                if let outcome = model.lastTransferOutcome {
                    FileTransferSummary(outcome: outcome, dismiss: { model.lastTransferOutcome = nil },
                                        openResult: model.openTransferResult, retry: model.retryFileTransfer)
                }
                if let progress = model.fileTransferProgress {
                    FileTransferBanner(progress: progress, cancel: { model.cancelFileTransfer() })
                }
                if let progress = model.transferProgress {
                    AndroidTransferBanner(progress: progress, cancel: androidTransferCancellation)
                }
                if let progress = model.archiveProgress {
                    ArchiveProgressBanner(progress: progress, cancel: model.cancelArchiveExtraction)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !model.isCleanupView { StatusBarView(engine: engine, model: model) }
        }
    }
}
