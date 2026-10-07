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
            return KeyPathComparator<FileItem>(\FileItem.name, order: order)
        case .modified:
            return KeyPathComparator<FileItem>(\FileItem.modified, order: order)
        case .type:
            return KeyPathComparator<FileItem>(\FileItem.typeDescription, order: order)
        case .size:
            return KeyPathComparator<FileItem>(\FileItem.size, order: order)
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
