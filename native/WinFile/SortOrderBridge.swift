// 表头排序与模型排序字段之间的映射
//
// SwiftUI 的 Table 用 KeyPathComparator 表达排序，而模型用自己的 SortField。
// 这里做双向映射，保证"点表头"与"右键 → 排序方式"共用同一份状态。
import Foundation

enum SortOrderBridge {

    /// 模型排序字段 → 表格比较器
    static func comparator(for field: SortField, ascending: Bool) -> KeyPathComparator<FileItem> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch field {
        case .name:
            return KeyPathComparator<FileItem>(\FileItem.name, comparator: .localizedStandard, order: order)
        case .modified:
            return KeyPathComparator<FileItem>(\FileItem.sortableModified, order: order)
        case .type:
            return KeyPathComparator<FileItem>(\FileItem.typeDescription, comparator: .localizedStandard, order: order)
        case .size:
            return KeyPathComparator<FileItem>(\FileItem.sortableSize, order: order)
        }
    }

    /// 表格比较器 → 模型排序字段。
    /// 通过比较器自身与各候选比较器是否相等来识别（KeyPathComparator 可比较）。
    static func field(for comparator: KeyPathComparator<FileItem>) -> SortField? {
        for field in SortField.allCases {
            for ascending in [true, false] {
                if comparator == self.comparator(for: field, ascending: ascending) {
                    return field
                }
            }
        }
        return nil
    }
}

enum WeChatSortOrderBridge {
    static let fields = ["name", "type", "size", "date", "location"]

    static func comparator(for field: String, ascending: Bool) -> KeyPathComparator<WeChatFile> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch field {
        case "name": return KeyPathComparator(\WeChatFile.name, comparator: .localizedStandard, order: order)
        case "type": return KeyPathComparator(\WeChatFile.typeDescription, comparator: .localizedStandard, order: order)
        case "date": return KeyPathComparator(\WeChatFile.modified, order: order)
        case "location": return KeyPathComparator(\WeChatFile.parentPath, comparator: .localizedStandard, order: order)
        default: return KeyPathComparator(\WeChatFile.size, order: order)
        }
    }

    static func field(for comparator: KeyPathComparator<WeChatFile>) -> String? {
        fields.first { field in
            [true, false].contains { comparator == self.comparator(for: field, ascending: $0) }
        }
    }
}
