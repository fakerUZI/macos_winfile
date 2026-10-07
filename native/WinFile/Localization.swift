// 本地化辅助：缺少翻译时使用调用方提供的兜底文案，
// 避免界面出现 "status.categoryFilter" 这类裸键名
import Foundation

func L(_ key: String, _ fallback: String) -> String {
    let value = NSLocalizedString(key, comment: "")
    return value == key ? fallback : value
}

func L(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
    String(format: L(key, fallback), arguments: arguments)
}
