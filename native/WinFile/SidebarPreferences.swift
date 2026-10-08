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
    private let categoryOrderKey = "SidebarCategoryOrder"

    /// 被隐藏的分类（存 rawValue，便于持久化）
    @Published private(set) var hiddenCategories: Set<String>
    /// 用户自定义的分类顺序（存 rawValue；缺失的按默认顺序补在后面）
    @Published private(set) var categoryOrder: [String]

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: hiddenCategoriesKey) ?? []
        hiddenCategories = Set(stored)
        categoryOrder = UserDefaults.standard.stringArray(forKey: categoryOrderKey) ?? []
    }

    /// 全部分类按当前顺序（含未显示的）
    var allCategoriesInOrder: [FileCategory] {
        var ordered: [FileCategory] = categoryOrder.compactMap { FileCategory(rawValue: $0) }
        // 补上尚未记录顺序的分类（新增分类或首次使用）
        for category in FileCategory.sidebarOrder where !ordered.contains(category) {
            ordered.append(category)
        }
        return ordered
    }

    /// 侧边栏应显示的分类（按用户顺序）。
    /// 即使全部隐藏也至少保留一个，避免分类区块变成空壳。
    var visibleCategories: [FileCategory] {
        let shown = allCategoriesInOrder.filter { !hiddenCategories.contains($0.rawValue) }
        return shown.isEmpty ? Array(allCategoriesInOrder.prefix(1)) : shown
    }

    /// 移动分类（用于右键「上移/下移」与拖拽排序）
    func move(_ category: FileCategory, before other: FileCategory) {
        var ordered = allCategoriesInOrder
        guard let from = ordered.firstIndex(of: category),
              let to = ordered.firstIndex(of: other), from != to else { return }
        ordered.remove(at: from)
        ordered.insert(category, at: to > from ? to : to)
        categoryOrder = ordered.map(\.rawValue)
        persist()
    }

    /// 上移/下移一位
    func move(_ category: FileCategory, by offset: Int) {
        var ordered = allCategoriesInOrder
        guard let index = ordered.firstIndex(of: category) else { return }
        let target = index + offset
        guard ordered.indices.contains(target) else { return }
        ordered.swapAt(index, target)
        categoryOrder = ordered.map(\.rawValue)
        persist()
    }

    /// 是否可上移/下移
    func canMove(_ category: FileCategory, by offset: Int) -> Bool {
        let ordered = allCategoriesInOrder
        guard let index = ordered.firstIndex(of: category) else { return false }
        return ordered.indices.contains(index + offset)
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

    /// 恢复为默认（全部显示 + 默认顺序）
    func resetToDefault() {
        hiddenCategories.removeAll()
        categoryOrder = []
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(hiddenCategories), forKey: hiddenCategoriesKey)
        UserDefaults.standard.set(categoryOrder, forKey: categoryOrderKey)
    }
}
