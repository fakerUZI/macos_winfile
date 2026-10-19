import AppKit
import Combine
import Sparkle

/// Sparkle owns version comparison, skipped versions, signature verification and installation.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var waitingForFileOperations = false
    private var started = false
    private var awaitingStartupReminder = false
    private var subscriptions = Set<AnyCancellable>()
    private var installationWait: Task<Void, Never>?
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)

    func start(arguments: [String] = CommandLine.arguments) {
        guard !started, AppUpdatePolicy.allowsStartupCheck(arguments: arguments) else { return }
        started = true
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheckForUpdates = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }.store(in: &subscriptions)
        controller.startUpdater()
        // Sparkle explicitly supports this immediately after starting, to check on every launch.
        if updater.automaticallyChecksForUpdates {
            awaitingStartupReminder = true
            updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        guard started, canCheckForUpdates else { return }
        awaitingStartupReminder = false
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard started else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard awaitingStartupReminder, !state.userInitiated else { return }
        awaitingStartupReminder = false
        // Focus only a valid startup offer. Offline/no-update checks stay silent, and
        // Sparkle still filters skipped versions before reaching this callback.
        DispatchQueue.main.async { [weak self] in self?.controller.checkForUpdates(nil) }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor check: SPUUpdateCheck, error: Error?) {
        awaitingStartupReminder = false
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard AppUpdatePolicy.hasActiveFileOperations(in: TabManager.allModels) else { return false }
        waitingForFileOperations = true
        installationWait?.cancel()
        installationWait = Task { [weak self] in
            while AppUpdatePolicy.hasActiveFileOperations(in: TabManager.allModels) {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self?.waitingForFileOperations = false
            installHandler()
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        awaitingStartupReminder = false
        installationWait?.cancel()
        installationWait = nil
        waitingForFileOperations = false
    }
}
