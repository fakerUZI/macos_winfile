// 侧边栏偏好：文件分类的显示管理
//
// 需求：分类与收藏支持「删除」和「新增」，但只能从**现有**条目里选。
// 因此这里管理的是"哪些分类在侧边栏显示"，而不是让用户自建分类。
import Combine
import Foundation

@MainActor
final class SidebarPreferences: ObservableObject {

    static let shared = SidebarPreferences()

    private let hiddenCategoriesKey = "SidebarHiddenCategories"

    /// 被隐藏的分类（存 rawValue，便于持久化）
    @Published private(set) var hiddenCategories: Set<String>

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: hiddenCategoriesKey) ?? []
        hiddenCategories = Set(stored)
    }

    /// 侧边栏应显示的分类。
    /// 即使全部隐藏也至少保留一个，避免分类区块变成空壳。
    var visibleCategories: [FileCategory] {
        let shown = FileCategory.sidebarOrder.filter { !hiddenCategories.contains($0.rawValue) }
        return shown.isEmpty ? [FileCategory.sidebarOrder[0]] : shown
    }

    /// 侧边栏被隐藏的分类（用于设置页展示"可添加"）
    var hiddenCategoryList: [FileCategory] {
        FileCategory.sidebarOrder.filter { hiddenCategories.contains($0.rawValue) }
    }

    func isVisible(_ category: FileCategory) -> Bool {
        !hiddenCategories.contains(category.rawValue)
    }

    /// 从侧边栏移除（不删除文件，只是不在此处显示）
    func hide(_ category: FileCategory) {
        hiddenCategories.insert(category.rawValue)
        persist()
    }

    /// 恢复到侧边栏
    func show(_ category: FileCategory) {
        hiddenCategories.remove(category.rawValue)
        persist()
    }

    /// 全部恢复
    func showAll() {
        hiddenCategories.removeAll()
        persist()
    }

    /// 恢复为默认（全部显示）
    func resetToDefault() {
        showAll()
    }

    private func persist() {
        UserDefaults.standard.set(Array(hiddenCategories), forKey: hiddenCategoriesKey)
    }
}
