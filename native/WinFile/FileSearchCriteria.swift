import Foundation

struct FileSearchCriteria: Codable, Equatable {
    var minimumBytes: Int64?
    var maximumBytes: Int64?
    var modifiedAfter: Date?
    var modifiedBefore: Date?
    var isActive: Bool { minimumBytes != nil || maximumBytes != nil || modifiedAfter != nil || modifiedBefore != nil }
    var isValid: Bool {
        (minimumBytes ?? 0) >= 0 && (maximumBytes ?? Int64.max) >= (minimumBytes ?? 0)
            && (modifiedAfter ?? .distantPast) <= (modifiedBefore ?? .distantFuture)
    }
    func matches(_ file: FileItem) -> Bool {
        guard isValid else { return false }
        if minimumBytes != nil || maximumBytes != nil {
            guard !file.isContainer, let size = file.size, size >= (minimumBytes ?? 0), size <= (maximumBytes ?? Int64.max) else { return false }
        }
        if modifiedAfter != nil || modifiedBefore != nil {
            guard let date = file.modified, date >= (modifiedAfter ?? .distantPast), date <= (modifiedBefore ?? .distantFuture) else { return false }
        }
        return true
    }
}

struct WeChatFilterState: Codable, Equatable {
    var search: String
    var kind: String
    var account: String
    var month: String
    var source: String
    var minimumMB: Int
    var olderThanDays: Int
    var sort: String
    var ascending: Bool
}
