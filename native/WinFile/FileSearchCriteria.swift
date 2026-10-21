import Foundation

struct FileSearchCriteria: Codable, Equatable {
    var minimumBytes: Int64?
    var maximumBytes: Int64?
    var modifiedAfter: Date?
    var modifiedBefore: Date?
    // Optional fields keep sessions written by earlier versions decodable.
    var foldersOnly: Bool?
    var category: FileCategory?
    var extensions: [String]?
    var isActive: Bool {
        minimumBytes != nil || maximumBytes != nil || modifiedAfter != nil || modifiedBefore != nil
            || foldersOnly != nil || category != nil || !(extensions ?? []).isEmpty
    }
    static func parseExtensions(_ text: String) -> [String] {
        Array(Set(text.lowercased().split(whereSeparator: { ",，;； \t\n".contains($0) })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty })).sorted()
    }
    var isValid: Bool {
        (minimumBytes ?? 0) >= 0 && (maximumBytes ?? Int64.max) >= (minimumBytes ?? 0)
            && (modifiedAfter ?? .distantPast) <= (modifiedBefore ?? .distantFuture)
    }
    func matches(_ file: FileItem) -> Bool {
        guard isValid else { return false }
        if let foldersOnly, file.isContainer != foldersOnly { return false }
        if let category, file.category != category { return false }
        if let extensions, !extensions.isEmpty {
            guard !file.isContainer, extensions.contains(file.url.pathExtension.lowercased()) else { return false }
        }
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
