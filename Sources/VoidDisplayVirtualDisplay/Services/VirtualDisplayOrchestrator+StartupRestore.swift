import CoreGraphics
import Foundation
import VoidDisplayObservability

@MainActor
extension VirtualDisplayOrchestrator {
    // MARK: - Load / Restore / Reset

    package func loadPersistedVirtualDisplayConfigsForStartupRestoreCommand() -> VirtualDisplayStartupRestoreConfigLoadResult {
        configManager.loadPersistedConfigsIfNeeded()
    }

    package func loadPersistedConfigs() {
        _ = configManager.loadPersistedConfigs()
    }

    package func restoreVirtualDisplayForStartupCommand(
        _ request: VirtualDisplayStartupRestoreCommandRequest
    ) async -> VirtualDisplayStartupRestoreCommandResult {
        guard case .ready = configManager.configStoreState else {
            AppLog.virtualDisplay.error(
                "Skip startup virtual display restore because config store is in load-failed state."
            )
            return startupRestoreCommandResult(
                request: request,
                preDisplayID: runtimeTracker.runtimeDisplayID(for: request.configID),
                postDisplayID: runtimeTracker.runtimeDisplayID(for: request.configID),
                restoreOutcome: .failed,
                didProduceVerifiableSideEffect: false,
                failureReason: "startup_config_store_unavailable"
            )
        }

        guard let config = configManager.config(id: request.configID) else {
            return startupRestoreCommandResult(
                request: request,
                preDisplayID: runtimeTracker.runtimeDisplayID(for: request.configID),
                postDisplayID: runtimeTracker.runtimeDisplayID(for: request.configID),
                restoreOutcome: .failed,
                didProduceVerifiableSideEffect: false,
                failureReason: "config_not_found"
            )
        }

        guard config.desiredEnabled else {
            return startupRestoreCommandResult(
                request: request,
                preDisplayID: runtimeTracker.runtimeDisplayID(for: request.configID),
                postDisplayID: runtimeTracker.runtimeDisplayID(for: request.configID),
                restoreOutcome: .notAttempted,
                didProduceVerifiableSideEffect: false,
                failureReason: "config_not_desired_enabled"
            )
        }

        let preDisplayID = runtimeTracker.runtimeDisplayID(for: request.configID)
        do {
            let record = try await runtimeTracker.createRuntimeDisplay(from: config)
            return startupRestoreCommandResult(
                request: request,
                preDisplayID: preDisplayID,
                postDisplayID: record.displayID,
                restoreOutcome: .succeeded,
                didProduceVerifiableSideEffect: true,
                failureReason: nil
            )
        } catch {
            let nsError = error as NSError
            AppLog.virtualDisplay.error(
                "Startup virtual display restore failed (config: \(request.configID.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), errorDomain: \(nsError.domain, privacy: .public), errorCode: \(nsError.code, privacy: .public))."
            )
            return startupRestoreCommandResult(
                request: request,
                preDisplayID: preDisplayID,
                postDisplayID: runtimeTracker.runtimeDisplayID(for: request.configID),
                restoreOutcome: .failed,
                didProduceVerifiableSideEffect: false,
                failureReason: "startup_restore_lower_command_failed",
                underlyingDomain: nsError.domain,
                underlyingCode: nsError.code
            )
        }
    }

    package func clearRestoreFailures() {
        configManager.clearRestoreFailures()
    }

    @discardableResult
    package func resetAllVirtualDisplayData() throws -> Int {
        let removedConfigCount = configManager.allConfigs().count
        try configManager.resetAll()
        runtimeTracker.resetAll()
        policyResolver.resetAll()
        return removedConfigCount
    }

    private func startupRestoreCommandResult(
        request: VirtualDisplayStartupRestoreCommandRequest,
        preDisplayID: CGDirectDisplayID?,
        postDisplayID: CGDirectDisplayID?,
        restoreOutcome: VirtualDisplayStartupRestoreCommandOutcome,
        didProduceVerifiableSideEffect: Bool,
        failureReason: String?,
        underlyingDomain: String? = nil,
        underlyingCode: Int? = nil
    ) -> VirtualDisplayStartupRestoreCommandResult {
        VirtualDisplayStartupRestoreCommandResult(
            transactionID: request.transactionID,
            configID: request.configID,
            preDisplayID: preDisplayID,
            postDisplayID: postDisplayID,
            restoreOutcome: restoreOutcome,
            didProduceVerifiableSideEffect: didProduceVerifiableSideEffect,
            failureReason: failureReason,
            underlyingDomain: underlyingDomain,
            underlyingCode: underlyingCode
        )
    }

}
