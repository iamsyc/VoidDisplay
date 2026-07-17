import CoreGraphics
import Foundation
import OSLog
import VoidDisplayObservability

@MainActor
final class VirtualDisplayEnableCoordinator {
    struct Dependencies {
        let configManager: VirtualDisplayConfigManager
        let runtimeTracker: VirtualDisplayRuntimeTracker
        let policyResolver: MainDisplayPolicyResolver
        let teardownCoordinator: any DisplayTeardownCoordinating
        let rebuildCoordinator: DisplayRebuildCoordinator
        let currentTopologySnapshot: () -> DisplayTopologySnapshot?
        let waitForAdaptiveManagedDisplayCooldown: ([UInt32], TimeInterval) async
            -> VirtualDisplayAdaptiveCooldownResult
        let logTopologySnapshot: (String, DisplayTopologySnapshot?) -> Void
    }

    private let dependencies: Dependencies

    private var configManager: VirtualDisplayConfigManager { dependencies.configManager }
    private var runtimeTracker: VirtualDisplayRuntimeTracker { dependencies.runtimeTracker }
    private var policyResolver: MainDisplayPolicyResolver { dependencies.policyResolver }
    private var teardownCoordinator: any DisplayTeardownCoordinating { dependencies.teardownCoordinator }
    private var rebuildCoordinator: DisplayRebuildCoordinator { dependencies.rebuildCoordinator }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func enableRuntimeDisplay(
        _ configId: UUID,
        preflight: VirtualDisplayEnablePreflight
    ) async throws -> VirtualDisplayLifecycleCommandResult {
        guard let config = configManager.config(id: configId) else {
            throw VirtualDisplayOperationError.configNotFound
        }

        let enableStart = DispatchTime.now().uptimeNanoseconds
        let topologyBeforeEnable = dependencies.currentTopologySnapshot()
        let mainPolicyResolution = policyResolver.resolveMainDisplayPolicy(
            snapshot: topologyBeforeEnable
        )
        let preferredMainDisplayID = mainPolicyResolution.preferredMainDisplayID
        let recoveryMode: VirtualDisplayTopologyRecoveryMode = policyResolver
            .isAggressiveRecoveryPending(configId: configId) ? .aggressive : .fast
        AppLog.virtualDisplay.notice(
            "Enable display requested (config: \(configId.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), recoveryMode: \(recoveryMode.logDescription, privacy: .public), preferredMain: \(String(describing: preferredMainDisplayID), privacy: .public), pendingGeneration: \(String(describing: self.runtimeTracker.runtimeGeneration(for: configId)), privacy: .public), isRunning: \(self.runtimeTracker.isVirtualDisplayRunning(configId: configId), privacy: .public))."
        )
        dependencies.logTopologySnapshot("enableRuntimeDisplay:pre-enable", topologyBeforeEnable)

        var terminationConfirmed = true
        var offlineVerified = false
        if !runtimeTracker.hasActiveRuntimeDisplay(configId: configId),
           let pendingGeneration = runtimeTracker.runtimeGeneration(for: configId) {
            let displayStillOnline = runtimeTracker.isManagedDisplayOnline(serialNum: config.serialNum)
            let shouldForceSettlement = recoveryMode == .aggressive
            if displayStillOnline || shouldForceSettlement {
                let settlement = await teardownCoordinator.waitForTeardownSettlement(
                    configId: configId,
                    expectedGeneration: pendingGeneration,
                    serialNum: config.serialNum,
                    terminationTimeout: 0.3,
                    offlineTimeout: 2.5
                )

                if shouldForceSettlement && !displayStillOnline {
                    AppLog.virtualDisplay.debug(
                        "Aggressive enable forced teardown settlement despite offline precheck (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), generation: \(pendingGeneration, privacy: .public))."
                    )
                }
                if !settlement.terminationObserved {
                    AppLog.virtualDisplay.debug(
                        "Enable did not observe termination callback before settling on offline confirmation (config: \(config.id.uuidString, privacy: .public))."
                    )
                }
                AppLog.virtualDisplay.debug(
                    "Enable teardown settlement (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), terminationObserved: \(settlement.terminationObserved, privacy: .public), offlineConfirmed: \(settlement.offlineConfirmed, privacy: .public))."
                )
                guard settlement.offlineConfirmed else {
                    AppLog.virtualDisplay.error(
                        "Enable aborted because previous display with same serial is still online after teardown settlement (serial: \(config.serialNum, privacy: .public), config: \(config.id.uuidString, privacy: .public), generation: \(pendingGeneration, privacy: .public))."
                    )
                    throw VirtualDisplayOperationError.teardownTimedOut
                }
                terminationConfirmed = settlement.terminationObserved
                offlineVerified = true
            }
        }
        if !runtimeTracker.hasActiveRuntimeDisplay(configId: configId), !offlineVerified {
            guard await runtimeTracker.waitForManagedDisplayOffline(serialNum: config.serialNum) else {
                AppLog.virtualDisplay.error(
                    "Enable aborted because previous display with same serial is still online (serial: \(config.serialNum, privacy: .public), config: \(config.id.uuidString, privacy: .public))."
                )
                throw VirtualDisplayOperationError.teardownTimedOut
            }
        }

        do {
            let desiredManagedEnabledCount = configManager.allConfigs().filter(\.desiredEnabled).count
            let shouldPreemptivelyUseFleetRebuild = recoveryMode == .aggressive &&
                !terminationConfirmed &&
                runtimeTracker.runningConfigCount >= 1 &&
                desiredManagedEnabledCount >= 2
            if shouldPreemptivelyUseFleetRebuild {
                AppLog.virtualDisplay.notice(
                    "Aggressive enable preemptively using coordinated fleet rebuild before creating target (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), runningManagedCount: \(self.runtimeTracker.runningConfigCount, privacy: .public), desiredManagedEnabledCount: \(desiredManagedEnabledCount, privacy: .public))."
                )
                try await rebuildCoordinator.rebuildManagedDisplayFleet(
                    prioritizing: configId,
                    fallbackPreferredMainDisplayID: preferredMainDisplayID,
                    teardownStrategy: .fleetOfflineOnly,
                    includePrioritizedConfigIfNotRunning: true
                )
                policyResolver.clearAggressiveRecoveryPending(configId: configId)
                return VirtualDisplayLifecycleCommandResult(
                    configID: configId,
                    desiredEnabled: true,
                    preDisplayID: preflight.targetPreDisplayID,
                    postDisplayID: runtimeTracker.runtimeDisplayID(for: configId),
                    mayPerformFleetRebuild: true,
                    requiresFleetQuiesce: true
                )
            }
            if recoveryMode == .aggressive && !terminationConfirmed {
                let cooldown = await dependencies.waitForAdaptiveManagedDisplayCooldown(
                    [config.serialNum],
                    VirtualDisplayTimingPolicy.aggressiveEnableUnsettledTeardownCooldown
                )
                AppLog.virtualDisplay.notice(
                    "Aggressive enable teardown settle cooldown completed (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), maxCooldownSec: \(VirtualDisplayTimingPolicy.aggressiveEnableUnsettledTeardownCooldown, privacy: .public), waitedMs: \(UInt64(cooldown.waitedSeconds * 1000), privacy: .public), earlyExit: \(cooldown.completedEarly, privacy: .public))."
                )
                dependencies.logTopologySnapshot(
                    "enableRuntimeDisplay:pre-create-post-cooldown",
                    dependencies.currentTopologySnapshot()
                )
            }
            let createdDisplayRecord = try await runtimeTracker.createRuntimeDisplayWithRetries(
                from: config,
                terminationConfirmed: terminationConfirmed
            )
            AppLog.virtualDisplay.notice(
                "Enable created runtime display (config: \(config.id.uuidString, privacy: .public), serial: \(createdDisplayRecord.serialNum, privacy: .public), displayID: \(createdDisplayRecord.displayID, privacy: .public), recoveryMode: \(recoveryMode.logDescription, privacy: .public))."
            )
            dependencies.logTopologySnapshot(
                "enableRuntimeDisplay:post-create-pre-recovery",
                dependencies.currentTopologySnapshot()
            )
            do {
                let postCreatePolicyResolution = policyResolver.resolveMainDisplayPolicy(
                    snapshot: dependencies.currentTopologySnapshot()
                )
                let preferredMainAfterCreate = postCreatePolicyResolution.preferredMainDisplayID ??
                    preferredMainDisplayID
                let shouldEscalateToFleetRebuild = recoveryMode == .aggressive &&
                    !terminationConfirmed &&
                    runtimeTracker.runningConfigCount >= 2
                if shouldEscalateToFleetRebuild {
                    AppLog.virtualDisplay.notice(
                        "Aggressive enable escalating to coordinated fleet rebuild because prior termination callback was not observed (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), runningManagedCount: \(self.runtimeTracker.runningConfigCount, privacy: .public))."
                    )
                    try await rebuildCoordinator.rebuildManagedDisplayFleet(
                        prioritizing: configId,
                        fallbackPreferredMainDisplayID: preferredMainAfterCreate,
                        teardownStrategy: .fleetOfflineOnly
                    )
                } else {
                    try await rebuildCoordinator.ensureHealthyTopologyAfterEnable(
                        preferredMainDisplayID: preferredMainAfterCreate,
                        recoveryMode: recoveryMode
                    )
                }
                policyResolver.clearAggressiveRecoveryPending(configId: configId)
            } catch {
                runtimeTracker.rollbackEnableRuntimeState(configId: configId)
                let offlineConfirmed = await runtimeTracker.waitForManagedDisplayOffline(
                    serialNum: config.serialNum,
                    timeout: VirtualDisplayTimingPolicy.rollbackOfflineWaitTimeout
                )
                if !offlineConfirmed {
                    AppLog.virtualDisplay.warning(
                        "Enable rollback did not observe offline state before timeout (serial: \(config.serialNum, privacy: .public), config: \(config.id.uuidString, privacy: .public), timeoutSec: \(VirtualDisplayTimingPolicy.rollbackOfflineWaitTimeout, privacy: .public))."
                    )
                }
                throw error
            }
        } catch {
            AppLog.virtualDisplay.error(
                "Enable display failed (displayName: \(config.displayName, privacy: .public), serial: \(config.serialNum, privacy: .public), totalElapsedMs: \(self.elapsedMilliseconds(since: enableStart), privacy: .public)): \(String(describing: error), privacy: .public)"
            )
            throw error
        }

        return VirtualDisplayLifecycleCommandResult(
            configID: configId,
            desiredEnabled: true,
            preDisplayID: preflight.targetPreDisplayID,
            postDisplayID: runtimeTracker.runtimeDisplayID(for: configId),
            mayPerformFleetRebuild: preflight.mayPerformFleetRebuild,
            requiresFleetQuiesce: preflight.requiresFleetQuiesce
        )
    }

    private func elapsedMilliseconds(since startNanoseconds: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= startNanoseconds ? (now - startNanoseconds) / 1_000_000 : 0
    }
}
