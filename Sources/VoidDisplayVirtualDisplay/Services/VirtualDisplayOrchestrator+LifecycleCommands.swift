import CoreGraphics
import Foundation
import VoidDisplayFoundation
import VoidDisplayObservability

@MainActor
extension VirtualDisplayOrchestrator {
    // MARK: - Main display policy (delegated)

    package func reconcileMainDisplayPolicyIfNeeded() async throws {
        let snapshot = currentTopologySnapshot()
        try await policyResolver.reconcileMainDisplayPolicyIfNeeded(
            snapshot: snapshot,
            ensureHealthyTopology: { [weak self] preferredMainDisplayID in
                try await self?.rebuildCoordinator.ensureHealthyTopologyAfterEnable(
                    preferredMainDisplayID: preferredMainDisplayID,
                    recoveryMode: .fast
                )
            }
        )
    }

    // MARK: - Create

    @discardableResult
    package func createDisplayCommand(
        name: String,
        serialNum: UInt32,
        physicalSize: CGSize,
        maxPixels: (width: UInt32, height: UInt32),
        modes: [ResolutionSelection]
    ) throws -> VirtualDisplayCreateCommandResult {
        if runtimeTracker.hasRuntimeDisplay(serialNum: serialNum) ||
            configManager.allConfigs().contains(where: { $0.serialNum == serialNum }) {
            throw VirtualDisplayOperationError.duplicateSerialNumber(serialNum)
        }

        guard !modes.isEmpty else {
            throw VirtualDisplayOperationError.invalidConfiguration(String(localized: "At least one resolution mode is required."))
        }

        let config = VirtualDisplayConfig(
            displayName: name,
            serialNum: serialNum,
            physicalWidth: Int(physicalSize.width),
            physicalHeight: Int(physicalSize.height),
            modes: modes.map {
                VirtualDisplayConfig.ModeConfig(
                    width: $0.width,
                    height: $0.height,
                    refreshRate: $0.refreshRate,
                    enableHiDPI: $0.enableHiDPI
                )
            },
            desiredEnabled: true
        )

        do {
            try configManager.appendConfig(config)
        } catch {
            let result = VirtualDisplayCreateCommandResult(
                createdConfigID: nil,
                persistenceOutcome: .failed,
                runtimeCreationOutcome: .notAttempted,
                rollbackOutcome: .notAttempted
            )
            throw VirtualDisplayCreateCommandFailure(
                reason: "config_append_failed",
                result: result,
                underlyingError: error
            )
        }

        do {
            _ = try runtimeTracker.createRuntimeDisplay(from: config, maxPixels: maxPixels)
            return VirtualDisplayCreateCommandResult(
                createdConfigID: config.id,
                persistenceOutcome: .saved,
                runtimeCreationOutcome: .succeeded,
                rollbackOutcome: .notAttempted
            )
        } catch {
            let creationError = error
            AppLog.virtualDisplay.error(
                "Create display failed (displayName: \(name, privacy: .public), serial: \(serialNum, privacy: .public)): \(String(describing: creationError), privacy: .public)"
            )
            do {
                try configManager.rollbackAppendedConfig(config.id)
            } catch let rollbackError {
                AppErrorMapper.logFailure(
                    "Rollback appended virtual display config",
                    error: rollbackError,
                    logger: AppLog.persistence
                )
                let persistenceRecoveryError = VirtualDisplayOperationError.persistenceRecoveryFailed(
                    String(
                        localized: "Create failed and the config rollback could not be saved. Check config file permissions or reset the config file."
                    )
                )
                let result = VirtualDisplayCreateCommandResult(
                    createdConfigID: config.id,
                    persistenceOutcome: .rollbackFailed,
                    runtimeCreationOutcome: .failed,
                    rollbackOutcome: .rollbackFailed
                )
                throw VirtualDisplayCreateCommandFailure(
                    reason: "persistenceRecoveryFailed",
                    result: result,
                    underlyingError: persistenceRecoveryError
                )
            }
            let result = VirtualDisplayCreateCommandResult(
                createdConfigID: config.id,
                persistenceOutcome: .rolledBack,
                runtimeCreationOutcome: .failed,
                rollbackOutcome: .rolledBack
            )
            throw VirtualDisplayCreateCommandFailure(
                reason: "runtime_creation_failed",
                result: result,
                underlyingError: creationError
            )
        }
    }

    // MARK: - Disable

    package func setDesiredEnabled(_ configId: UUID, enabled: Bool) throws {
        try configManager.setDesiredEnabled(configId, enabled: enabled, reason: .userToggledDesiredEnabled)
    }

    package func disableRuntimeDisplayByConfig(_ configId: UUID) throws -> VirtualDisplayLifecycleCommandResult {
        guard let config = configManager.config(id: configId) else {
            throw VirtualDisplayOperationError.configNotFound
        }

        let preDisplayID = runtimeTracker.runtimeDisplayID(for: configId)

        let runtimeSerialNum = runtimeTracker.runtimeSerialNum(
            for: configId,
            fallback: config.serialNum
        )
        let disablingMain = preDisplayID == CGMainDisplayID()
        AppLog.virtualDisplay.notice(
            "Disable-by-config requested (config: \(configId.uuidString, privacy: .public), serial: \(runtimeSerialNum, privacy: .public), runtimeDisplayID: \(String(describing: preDisplayID), privacy: .public), disablingMain: \(disablingMain, privacy: .public))."
        )
        logTopologySnapshot("disableRuntimeDisplayByConfig:pre-clear", snapshot: currentTopologySnapshot())
        if disablingMain {
            policyResolver.markAggressiveRecoveryPending(configId: configId)
        }
        runtimeTracker.clearRuntimeTracking(configId: configId, keepGeneration: true)
        return VirtualDisplayLifecycleCommandResult(
            configID: configId,
            desiredEnabled: false,
            preDisplayID: preDisplayID,
            postDisplayID: runtimeTracker.runtimeDisplayID(for: configId),
            mayPerformFleetRebuild: disablingMain && runtimeTracker.runningConfigCount >= 1,
            requiresFleetQuiesce: disablingMain && runtimeTracker.runningConfigCount >= 1
        )
    }

    // MARK: - Enable

    package func enableDisplayPreflight(_ configId: UUID) -> VirtualDisplayEnablePreflight {
        let recoveryMode: VirtualDisplayTopologyRecoveryMode = policyResolver.isAggressiveRecoveryPending(configId: configId)
            ? .aggressive
            : .fast
        let configIsAlreadyDesired = configManager.config(id: configId)?.desiredEnabled == true
        let desiredManagedEnabledCount = configManager.allConfigs().filter(\.desiredEnabled).count
            + (configIsAlreadyDesired ? 0 : 1)
        let mayPerformFleetRebuild = recoveryMode == .aggressive
            && runtimeTracker.runningConfigCount >= 1
            && desiredManagedEnabledCount >= 2
        return VirtualDisplayEnablePreflight(
            configID: configId,
            targetPreDisplayID: runtimeTracker.runtimeDisplayID(for: configId),
            mayPerformFleetRebuild: mayPerformFleetRebuild,
            requiresFleetQuiesce: mayPerformFleetRebuild,
            scopeEscalationReason: mayPerformFleetRebuild ? .enableMayPerformFleetRebuild : nil
        )
    }

    package func enableRuntimeDisplay(_ configId: UUID) async throws -> VirtualDisplayLifecycleCommandResult {
        let preflight = enableDisplayPreflight(configId)
        return try await enableCoordinator.enableRuntimeDisplay(configId, preflight: preflight)
    }

    // MARK: - Destroy

    package func deleteDisplayCommand(_ configId: UUID) throws -> VirtualDisplayDeleteCommandResult {
        guard configManager.config(id: configId) != nil else {
            let result = VirtualDisplayDeleteCommandResult(
                configID: configId,
                targetWasRunning: false,
                preDisplayID: nil,
                postDisplayID: nil,
                persistenceOutcome: .notAttempted,
                virtualDisplayCommandOutcome: .failed,
                runtimeTrackingClearOutcome: .notAttempted
            )
            throw VirtualDisplayDeleteCommandFailure(
                reason: "config_not_found",
                result: result,
                underlyingError: VirtualDisplayOperationError.configNotFound
            )
        }
        let preDisplayID = runtimeTracker.runtimeDisplayID(for: configId)
        let targetWasRunning = runtimeTracker.isVirtualDisplayRunning(configId: configId)
            || preDisplayID != nil
        do {
            try configManager.removeConfig(configId)
        } catch {
            let result = VirtualDisplayDeleteCommandResult(
                configID: configId,
                targetWasRunning: targetWasRunning,
                preDisplayID: preDisplayID,
                postDisplayID: runtimeTracker.runtimeDisplayID(for: configId),
                persistenceOutcome: .failed,
                virtualDisplayCommandOutcome: .failed,
                runtimeTrackingClearOutcome: .notAttempted
            )
            throw VirtualDisplayDeleteCommandFailure(
                reason: "config_delete_failed",
                result: result,
                underlyingError: error
            )
        }
        policyResolver.clearAggressiveRecoveryPending(configId: configId)
        runtimeTracker.clearRuntimeTracking(configId: configId, keepGeneration: false)
        return VirtualDisplayDeleteCommandResult(
            configID: configId,
            targetWasRunning: targetWasRunning,
            preDisplayID: preDisplayID,
            postDisplayID: runtimeTracker.runtimeDisplayID(for: configId),
            persistenceOutcome: .saved,
            virtualDisplayCommandOutcome: .succeeded,
            runtimeTrackingClearOutcome: .cleared
        )
    }

}
