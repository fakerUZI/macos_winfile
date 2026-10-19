// App-local language selection. Never changes macOS or other apps' preferences.
import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", simplifiedChinese = "zh-Hans"
    var id: String { rawValue }

    static func resolve(_ choice: AppLanguage, preferredLanguages: [String]) -> String {
        if choice != .system { return choice.rawValue }
        for language in preferredLanguages {
            let base = language.replacingOccurrences(of: "_", with: "-").lowercased()
            if base == "zh" || base.hasPrefix("zh-") { return "zh-Hans" }
            if base == "en" || base.hasPrefix("en-") { return "en" }
        }
        return "en"
    }
}

final class Localization: ObservableObject {
    static let shared = Localization()
    static let preferenceKey = "AppLanguage"
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.preferenceKey) }
    }
    @Published private var localeRevision = 0
    private var localeObserver: NSObjectProtocol?

    private init() {
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Self.preferenceKey) ?? "") ?? .system
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.localeRevision += 1 }
    }

    static var languageCode: String {
        let choice = AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .system
        return AppLanguage.resolve(choice, preferredLanguages: Locale.preferredLanguages)
    }
    var locale: Locale { Locale(identifier: Self.languageCode) }

    private static let bundles: [String: Bundle] = {
        var result: [String: Bundle] = [:]
        for code in ["en", "zh-Hans"] {
            if let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) {
                result[code] = bundle
            }
        }
        return result
    }()

    static func string(_ key: String, fallback: String) -> String {
        // Explicit bundle selection also works after changing language at runtime.
        let value = bundles[languageCode]?.localizedString(forKey: key, value: nil, table: nil)
        if let value, value != key { return value }
        let english = bundles["en"]?.localizedString(forKey: key, value: nil, table: nil)
        return english.flatMap { $0 == key ? nil : $0 } ?? fallback
    }
}

func L(_ key: String, _ fallback: String) -> String {
    Localization.string(key, fallback: fallback)
}

func L(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
    String(format: L(key, fallback), locale: Locale(identifier: Localization.languageCode), arguments: arguments)
}

func WLocalizedString(_ key: String, comment: String) -> String {
    L(key, comment)
}
