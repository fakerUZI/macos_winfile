import Foundation

enum AppUpdatePolicy {
    static let feedURL = "https://github.com/fakerUZI/macos_winfile/releases/latest/download/appcast.xml"
    static let signingAccount = "local.winfile.mac"
    static let publicKey = "3AbK+TOpDBmTgWNtsch3Xs0w0YgzzOiYtMdIv800Za8="

    /// Test, screenshot and diagnostic launches must never contact the update server.
    static func allowsStartupCheck(arguments: [String]) -> Bool {
        let diagnostics = ["--run-tests", "--render-snapshot", "--snapshot-mode", "--dump-view-tree", "--probe-context-menu"]
        return !arguments.contains { diagnostics.contains($0) || $0.hasPrefix("--selftest-") }
    }

    @MainActor
    static func hasActiveFileOperations(in models: [BrowserModel]) -> Bool {
        FileOperationHistory.shared.isBusy || models.contains {
            $0.isBusy || $0.fileTransferProgress != nil || $0.transferProgress != nil || $0.archiveProgress != nil || $0.cleanupIsCleaning
        }
    }
}
