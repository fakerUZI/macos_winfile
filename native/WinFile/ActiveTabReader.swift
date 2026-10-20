// 当前页签读取器：把「TabManager 的当前页签模型」包装成一个可直接观察的对象。
//
// 背景：地址栏等界面原先由 MainView 传模型参数。SwiftUI 在重绘时会保留旧的
// 参数副本，导致界面观察到的 BrowserModel 与真正被导航修改的那个不是同一个实例，
// 表现就是「切换页签时路径才变、普通导航时路径不动」。
//
// 这里改为只暴露一个稳定的观察对象：它订阅 TabManager 的当前模型，
// 当前模型的任何变化都会转发出来，界面因此总能重绘。
import Combine
import Foundation

@MainActor
final class ActiveTabReader: ObservableObject {

    let manager: TabManager
    private var managerCancellable: AnyCancellable?
    private var refreshScheduled = false

    init(manager: TabManager) {
        self.manager = manager
        // 订阅 TabManager 的全部变更（新建/关闭/切换页签都会触发）。
        // 注意：不能只订阅 $activeID —— 新建页签时 tabs 先追加、activeID 后赋值，
        // 若在中间状态重新绑定就会绑到旧模型，表现为"新页签点不动，切换一次才好"。
        managerCancellable = manager.objectWillChange
            .sink { [weak self] _ in
                // 延迟到本轮变更结束后再绑定，确保拿到的是最终的活动页签
                self?.scheduleRefresh()
            }
    }

    /// 当前的浏览模型（始终取自 TabManager，不复制）。
    var model: BrowserModel { manager.activeModel }

    /// 当前页签
    var tab: WinFileTab { manager.activeTab }

    /// 页签列表
    var tabs: [WinFileTab] { manager.tabs }

    /// 每次需要界面重绘时自增：供视图读取以建立观察依赖
    @Published private(set) var refreshToken = 0

    /// TabManager already forwards the active model. Observe it once, coalescing
    /// each run-loop burst; getters must never publish while SwiftUI is rendering.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshToken &+= 1
        }
    }
}
