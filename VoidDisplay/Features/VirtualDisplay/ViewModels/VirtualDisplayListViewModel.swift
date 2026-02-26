import CoreGraphics
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class VirtualDisplayListViewModel {
    struct Dependencies {
        var restoreFailures: @MainActor () -> [VirtualDisplayRestoreFailure]
        var clearRestoreFailures: @MainActor () -> Void
        var destroyDisplay: @MainActor (UUID) -> Void
        var runtimeDisplayID: @MainActor (UUID) -> CGDirectDisplayID?
        var isRebuilding: @MainActor (UUID) -> Bool
        var isVirtualDisplayRunning: @MainActor (UUID) -> Bool
        var disableDisplayByConfig: @MainActor (UUID) throws -> Void
        var enableDisplay: @MainActor (UUID) async throws -> Void

        static func live(controller: VirtualDisplayController) -> Self {
            Self(
                restoreFailures: { controller.restoreFailures },
                clearRestoreFailures: { controller.clearRestoreFailures() },
                destroyDisplay: { controller.destroyDisplay($0) },
                runtimeDisplayID: { controller.runtimeDisplayID(for: $0) },
                isRebuilding: { controller.isRebuilding(configId: $0) },
                isVirtualDisplayRunning: { controller.isVirtualDisplayRunning(configId: $0) },
                disableDisplayByConfig: { try controller.disableDisplayByConfig($0) },
                enableDisplay: { try await controller.enableDisplay($0) }
            )
        }
    }

    var primaryDisplayRefreshTick: UInt64 = 0
    var togglingConfigIds: Set<UUID> = []
    var showDeleteConfirm = false
    var deleteCandidate: VirtualDisplayConfig?
    var showRestoreFailureAlert = false
    var showError = false
    var errorMessage = ""

    @ObservationIgnored private var primaryDisplayMonitor = DebouncingDisplayReconfigurationMonitor()
    @ObservationIgnored private var primaryDisplayFallbackCoordinator = PrimaryDisplayFallbackCoordinator()
    @ObservationIgnored private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    convenience init(controller: VirtualDisplayController) {
        self.init(dependencies: .live(controller: controller))
    }

    func handleAppear() {
        if !dependencies.restoreFailures().isEmpty {
            showRestoreFailureAlert = true
        }
        startPrimaryDisplayMonitoring()
    }

    func handleDisappear() {
        stopPrimaryDisplayMonitoring()
    }

    func handleRestoreFailuresChanged(_ failures: [VirtualDisplayRestoreFailure]) {
        if !failures.isEmpty {
            showRestoreFailureAlert = true
        }
    }

    func acknowledgeRestoreFailures() {
        dependencies.clearRestoreFailures()
    }

    func requestDelete(_ config: VirtualDisplayConfig) {
        deleteCandidate = config
        showDeleteConfirm = true
    }

    func confirmDelete() {
        guard let candidate = deleteCandidate else {
            showDeleteConfirm = false
            deleteCandidate = nil
            return
        }
        dependencies.destroyDisplay(candidate.id)
        deleteCandidate = nil
        showDeleteConfirm = false
    }

    func cancelDelete() {
        deleteCandidate = nil
        showDeleteConfirm = false
    }

    func isToggling(configId: UUID) -> Bool {
        togglingConfigIds.contains(configId)
    }

    func isPrimaryDisplay(configID: UUID) -> Bool {
        // Use the service-provided runtime display ID instead of requiring a live runtime
        // object. Rebuild/teardown flows may temporarily clear the object while the display ID
        // hint is still valid for UI presentation (for example, primary-display badges).
        dependencies.runtimeDisplayID(configID) == CGMainDisplayID()
    }

    func toggleDisplayState(_ config: VirtualDisplayConfig) {
        guard !togglingConfigIds.contains(config.id),
              !dependencies.isRebuilding(config.id) else { return }
        togglingConfigIds.insert(config.id)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.togglingConfigIds.remove(config.id) }

            if dependencies.isVirtualDisplayRunning(config.id) {
                do {
                    try dependencies.disableDisplayByConfig(config.id)
                } catch {
                    AppErrorMapper.logFailure("Disable virtual display", error: error, logger: AppLog.virtualDisplay)
                    self.errorMessage = AppErrorMapper.userMessage(for: error, fallback: String(localized: "Disable failed."))
                    self.showError = true
                }
                return
            }
            do {
                try await dependencies.enableDisplay(config.id)
            } catch {
                AppErrorMapper.logFailure("Enable virtual display", error: error, logger: AppLog.virtualDisplay)
                self.errorMessage = AppErrorMapper.userMessage(for: error, fallback: String(localized: "Enable failed."))
                self.showError = true
            }
        }
    }

    private func startPrimaryDisplayMonitoring() {
        let started = primaryDisplayMonitor.start { [weak self] in
            self?.primaryDisplayRefreshTick &+= 1
        }
        if started {
            primaryDisplayFallbackCoordinator.stop()
            return
        }

        AppLog.virtualDisplay.error(
            "Primary display monitor callback registration failed; enabling polling fallback."
        )
        startPrimaryDisplayFallback()
    }

    private func stopPrimaryDisplayMonitoring() {
        primaryDisplayMonitor.stop()
        primaryDisplayFallbackCoordinator.stop()
    }

    private func startPrimaryDisplayFallback() {
        primaryDisplayFallbackCoordinator.startIfNeeded(
            onTick: { [weak self] in
                self?.primaryDisplayRefreshTick &+= 1
            },
            attemptRecovery: { [weak self] in
                guard let self else { return false }
                return self.primaryDisplayMonitor.start {
                    self.primaryDisplayRefreshTick &+= 1
                }
            },
            onRecovered: {
                AppLog.virtualDisplay.notice(
                    "Primary display monitor callback recovered; disabling polling fallback."
                )
            }
        )
    }
}
