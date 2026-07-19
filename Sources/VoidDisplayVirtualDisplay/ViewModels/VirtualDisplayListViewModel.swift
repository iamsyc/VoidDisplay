import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import Foundation
import Observation
import OSLog

@MainActor
@Observable
package final class VirtualDisplayListViewModel {
    package struct Dependencies {
        var restoreFailures: @MainActor () -> [VirtualDisplayRestoreFailure]
        var clearRestoreFailures: @MainActor () -> Void
        var deleteVirtualDisplay: @MainActor (UUID) async throws -> Void
        var runtimeDisplayID: @MainActor (UUID) -> CGDirectDisplayID?
        var isRebuilding: @MainActor (UUID) -> Bool
        var setVirtualDisplayDesiredEnabled: @MainActor (UUID, Bool) async throws -> Void

        static func live(controller: VirtualDisplayController) -> Self {
            Self(
                restoreFailures: { controller.restoreFailures },
                clearRestoreFailures: { controller.clearRestoreFailures() },
                deleteVirtualDisplay: { try await controller.deleteVirtualDisplay(configId: $0) },
                runtimeDisplayID: { controller.runtimeDisplayID(for: $0) },
                isRebuilding: { controller.isRebuilding(configId: $0) },
                setVirtualDisplayDesiredEnabled: {
                    try await controller.setVirtualDisplayDesiredEnabled(
                        configId: $0,
                        enabled: $1,
                        source: .rowToggle
                    )
                }
            )
        }
    }

    package var togglingConfigIds: Set<UUID> = []
    package var showDeleteConfirm = false
    package var deleteCandidate: VirtualDisplayConfig?
    package var showRestoreFailureAlert = false
    package var userFacingAlert: UserFacingAlertState?

    @ObservationIgnored private let dependencies: Dependencies

    package init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    package convenience init(controller: VirtualDisplayController) {
        self.init(dependencies: .live(controller: controller))
    }

    package func handleAppear() {
        if !dependencies.restoreFailures().isEmpty {
            showRestoreFailureAlert = true
        }
    }

    package func handleRestoreFailuresChanged(_ failures: [VirtualDisplayRestoreFailure]) {
        if !failures.isEmpty {
            showRestoreFailureAlert = true
        }
    }

    package func acknowledgeRestoreFailures() {
        dependencies.clearRestoreFailures()
    }

    package func requestDelete(_ config: VirtualDisplayConfig) {
        deleteCandidate = config
        showDeleteConfirm = true
    }

    package func confirmDelete() {
        guard let candidate = deleteCandidate else {
            showDeleteConfirm = false
            deleteCandidate = nil
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await dependencies.deleteVirtualDisplay(candidate.id)
            } catch {
                AppErrorMapper.logFailure("Delete virtual display", error: error, logger: AppLog.virtualDisplay)
                self.userFacingAlert = UserFacingAlertState(
                    title: String(localized: "Delete Failed"),
                    message: AppErrorMapper.userMessage(for: error, fallback: String(localized: "Delete failed."))
                )
                return
            }
            guard self.deleteCandidate?.id == candidate.id else { return }
            self.deleteCandidate = nil
            self.showDeleteConfirm = false
        }
    }

    package func cancelDelete() {
        deleteCandidate = nil
        showDeleteConfirm = false
    }

    package func isToggling(configId: UUID) -> Bool {
        togglingConfigIds.contains(configId)
    }

    package func isPrimaryDisplay(configID: UUID) -> Bool {
        // Use the service-provided runtime display ID instead of requiring a live runtime
        // object. Rebuild/teardown flows may temporarily clear the object while the display ID
        // hint is still valid for UI presentation (for example, primary-display badges).
        dependencies.runtimeDisplayID(configID) == CGMainDisplayID()
    }

    package func toggleDisplayState(_ config: VirtualDisplayConfig) {
        guard !togglingConfigIds.contains(config.id),
              !dependencies.isRebuilding(config.id) else { return }
        togglingConfigIds.insert(config.id)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.togglingConfigIds.remove(config.id) }

            if config.desiredEnabled {
                do {
                    try await dependencies.setVirtualDisplayDesiredEnabled(config.id, false)
                } catch {
                    AppErrorMapper.logFailure("Disable virtual display", error: error, logger: AppLog.virtualDisplay)
                    self.userFacingAlert = UserFacingAlertState(
                        title: String(localized: "Disable Failed"),
                        message: AppErrorMapper.userMessage(for: error, fallback: String(localized: "Disable failed."))
                    )
                }
                return
            }
            do {
                try await dependencies.setVirtualDisplayDesiredEnabled(config.id, true)
            } catch {
                AppErrorMapper.logFailure("Enable virtual display", error: error, logger: AppLog.virtualDisplay)
                self.userFacingAlert = UserFacingAlertState(
                    title: String(localized: "Enable Failed"),
                    message: AppErrorMapper.userMessage(for: error, fallback: String(localized: "Enable failed."))
                )
            }
        }
    }

    package func dismissAlert() {
        userFacingAlert = nil
    }
}
