import Foundation
import CoreGraphics
import OSLog

@MainActor
final class DisplayRebuildCoordinator {
    struct Dependencies {
        let configManager: VirtualDisplayConfigManager
        let runtimeTracker: VirtualDisplayRuntimeTracker
        let teardownCoordinator: any DisplayTeardownCoordinating
        let policyResolver: MainDisplayPolicyResolver
        let topologyRepairer: any DisplayTopologyRepairing
        let clock: any VirtualDisplayClocking
        let topologyStabilityTimeout: TimeInterval
        let topologyStabilityPollInterval: TimeInterval
        let rebuildRuntimeDisplayHook: (@MainActor (VirtualDisplayConfig, Bool) async throws -> Void)?
        let currentTopologySnapshot: () -> DisplayTopologySnapshot?
        let waitForAdaptiveManagedDisplayCooldown: ([UInt32], TimeInterval) async -> VirtualDisplayAdaptiveCooldownResult
        let logTopologySnapshot: (String, DisplayTopologySnapshot?) -> Void
    }

    private let dependencies: Dependencies

    private var configManager: VirtualDisplayConfigManager { dependencies.configManager }
    private var runtimeTracker: VirtualDisplayRuntimeTracker { dependencies.runtimeTracker }
    private var teardownCoordinator: any DisplayTeardownCoordinating { dependencies.teardownCoordinator }
    private var policyResolver: MainDisplayPolicyResolver { dependencies.policyResolver }
    private var clock: any VirtualDisplayClocking { dependencies.clock }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func rebuildVirtualDisplay(configId: UUID) async throws {
        guard let config = configManager.allConfigs().first(where: { $0.id == configId }) else {
            throw VirtualDisplayOperationError.configNotFound
        }

        let snapshotBeforeRebuild = dependencies.currentTopologySnapshot()
        let mainPolicyBeforeRebuild = policyResolver.resolveMainDisplayPolicy(
            snapshot: snapshotBeforeRebuild
        )
        let preferredMainDisplayID = mainPolicyBeforeRebuild.preferredMainDisplayID
        let targetRuntimeDisplayID = runtimeTracker.runtimeDisplayID(for: configId)
        let targetWasManagedMain = TopologyHealthEvaluator.managedDisplayID(
            for: config.serialNum,
            snapshot: snapshotBeforeRebuild
        ) == snapshotBeforeRebuild?.mainDisplayID || targetRuntimeDisplayID == CGMainDisplayID()
        let useCoordinatedRebuild = shouldUseCoordinatedRebuild(
            configId: configId,
            config: config,
            snapshot: snapshotBeforeRebuild
        )
        let coordinatedRebuildTeardownStrategy: FleetRebuildTeardownStrategy =
            (targetWasManagedMain || targetRuntimeDisplayID == CGMainDisplayID())
            ? .fleetOfflineOnly
            : .perDisplaySettlement
        AppLog.virtualDisplay.debug(
            "Rebuild strategy resolved (config: \(configId.uuidString, privacy: .public), coordinated: \(useCoordinatedRebuild, privacy: .public), runtimeMainMatch: \(targetRuntimeDisplayID == CGMainDisplayID(), privacy: .public), snapshotAvailable: \(snapshotBeforeRebuild != nil, privacy: .public), teardownStrategy: \(coordinatedRebuildTeardownStrategy.logDescription, privacy: .public))."
        )
        if useCoordinatedRebuild {
            try await rebuildManagedDisplayFleet(
                prioritizing: configId,
                fallbackPreferredMainDisplayID: preferredMainDisplayID,
                teardownStrategy: coordinatedRebuildTeardownStrategy
            )
            return
        }

        let targetWasRunning = runtimeTracker.isVirtualDisplayRunning(configId: configId)
        let runtimeSerialNum = runtimeTracker.runtimeSerialNum(for: configId, fallback: config.serialNum)
        let generationToWaitFor = targetWasRunning
            ? runtimeTracker.runtimeGeneration(for: configId)
            : nil
        if targetWasRunning {
            runtimeTracker.clearRuntimeTracking(configId: configId, keepGeneration: true)
        }

        let terminationConfirmed: Bool
        if targetWasRunning,
           !targetWasManagedMain,
           generationToWaitFor != nil {
            let offlineConfirmedQuick = await teardownCoordinator.waitForManagedDisplayOffline(
                serialNum: runtimeSerialNum,
                timeout: VirtualDisplayTimingPolicy.rebuildFleetCreationCooldownFastTeardown
            )
            if offlineConfirmedQuick {
                terminationConfirmed = false
            } else {
                terminationConfirmed = try await teardownCoordinator.settleRebuildTeardown(
                    configId: config.id,
                    serialNum: runtimeSerialNum,
                    generationToWaitFor: generationToWaitFor,
                    rebuildTerminationTimeout: VirtualDisplayTimingPolicy.rebuildTerminationTimeout,
                    rebuildOfflineTimeout: VirtualDisplayTimingPolicy.rebuildOfflineTimeout,
                    rebuildFinalOfflineConfirmationTimeout: VirtualDisplayTimingPolicy.rebuildFinalOfflineConfirmationTimeout
                )
            }
        } else {
            terminationConfirmed = try await teardownCoordinator.settleRebuildTeardown(
                configId: config.id,
                serialNum: runtimeSerialNum,
                generationToWaitFor: generationToWaitFor,
                rebuildTerminationTimeout: VirtualDisplayTimingPolicy.rebuildTerminationTimeout,
                rebuildOfflineTimeout: VirtualDisplayTimingPolicy.rebuildOfflineTimeout,
                rebuildFinalOfflineConfirmationTimeout: VirtualDisplayTimingPolicy.rebuildFinalOfflineConfirmationTimeout
            )
        }

        let recreatedTargetDisplayID = try await recreateRuntimeDisplayForRebuild(
            config: config,
            terminationConfirmed: terminationConfirmed
        )
        let policyPreferredDisplayIDAfterRebuild = mainPolicyBeforeRebuild.targetConfigID.flatMap {
            runtimeTracker.runtimeDisplayID(for: $0)
        }
        let preferredMainAfterRebuild: CGDirectDisplayID?
        if mainPolicyBeforeRebuild.applies {
            preferredMainAfterRebuild = policyPreferredDisplayIDAfterRebuild ??
                (targetWasManagedMain ? recreatedTargetDisplayID : preferredMainDisplayID)
        } else if targetWasManagedMain {
            preferredMainAfterRebuild = recreatedTargetDisplayID ?? preferredMainDisplayID
        } else {
            preferredMainAfterRebuild = preferredMainDisplayID
        }
        let recoveryModeAfterRebuild: VirtualDisplayTopologyRecoveryMode =
            targetWasManagedMain ? .aggressive : .fast
        try await ensureHealthyTopologyAfterEnable(
            preferredMainDisplayID: preferredMainAfterRebuild,
            recoveryMode: recoveryModeAfterRebuild
        )
    }

    private func shouldUseCoordinatedRebuild(
        configId: UUID,
        config: VirtualDisplayConfig,
        snapshot: DisplayTopologySnapshot?
    ) -> Bool {
        guard runtimeTracker.isVirtualDisplayRunning(configId: configId),
              runtimeTracker.runningConfigCount >= 2 else {
            return false
        }
        if let runtimeDisplayID = runtimeTracker.runtimeDisplayID(for: configId),
           runtimeDisplayID == CGMainDisplayID() {
            return true
        }
        guard let snapshot else {
            return false
        }
        let managedOnlineCount = snapshot.displays.filter(\.isManagedVirtualDisplay).count
        guard managedOnlineCount >= 2,
              let targetDisplayID = TopologyHealthEvaluator.managedDisplayID(
                for: config.serialNum,
                snapshot: snapshot
              ) else {
            return false
        }
        return snapshot.mainDisplayID == targetDisplayID
    }

    private func orderedRunningConfigIDs(prioritizing configId: UUID) -> [UUID] {
        var ordered = configManager.allConfigs()
            .map(\.id)
            .filter { runtimeTracker.isVirtualDisplayRunning(configId: $0) }
        if let index = ordered.firstIndex(of: configId) {
            ordered.remove(at: index)
            ordered.insert(configId, at: 0)
        } else if runtimeTracker.isVirtualDisplayRunning(configId: configId) {
            ordered.insert(configId, at: 0)
        }
        return ordered
    }

    func rebuildManagedDisplayFleet(
        prioritizing prioritizedConfigID: UUID,
        fallbackPreferredMainDisplayID: CGDirectDisplayID?,
        teardownStrategy: FleetRebuildTeardownStrategy = .perDisplaySettlement,
        includePrioritizedConfigIfNotRunning: Bool = false
    ) async throws {
        var orderedConfigIDs = orderedRunningConfigIDs(prioritizing: prioritizedConfigID)
        if includePrioritizedConfigIfNotRunning,
           !orderedConfigIDs.contains(prioritizedConfigID),
           configManager.allConfigs().contains(where: { $0.id == prioritizedConfigID }) {
            orderedConfigIDs.insert(prioritizedConfigID, at: 0)
        }
        guard !orderedConfigIDs.isEmpty else {
            throw VirtualDisplayOperationError.configNotFound
        }
        let mainPolicyBeforeRebuild = policyResolver.resolveMainDisplayPolicy(
            snapshot: dependencies.currentTopologySnapshot()
        )
        let continuityPreferredConfigID = fallbackPreferredMainDisplayID.flatMap { previousPreferredMainDisplayID in
            orderedConfigIDs.first { configID in
                runtimeTracker.runtimeDisplayID(for: configID) == previousPreferredMainDisplayID
            }
        }
        let preferPrioritizedAsContinuityMain =
            policyResolver.isAggressiveRecoveryPending(configId: prioritizedConfigID)

        var terminationConfirmedByConfigID: [UUID: Bool] = [:]
        var rebuiltSerials: [UInt32] = []
        for runningConfigID in orderedConfigIDs {
            guard let runningConfig = configManager.allConfigs().first(where: { $0.id == runningConfigID }) else { continue }
            let runtimeSerialNum = runtimeTracker.runtimeSerialNum(for: runningConfigID, fallback: runningConfig.serialNum)
            rebuiltSerials.append(runtimeSerialNum)
            let generationToWaitFor = runtimeTracker.runtimeGeneration(for: runningConfigID)

            runtimeTracker.clearRuntimeTracking(configId: runningConfigID, keepGeneration: true)

            let terminationConfirmed: Bool
            switch teardownStrategy {
            case .perDisplaySettlement:
                terminationConfirmed = try await teardownCoordinator.settleRebuildTeardown(
                    configId: runningConfigID,
                    serialNum: runtimeSerialNum,
                    generationToWaitFor: generationToWaitFor,
                    rebuildTerminationTimeout: VirtualDisplayTimingPolicy.rebuildTerminationTimeout,
                    rebuildOfflineTimeout: VirtualDisplayTimingPolicy.rebuildOfflineTimeout,
                    rebuildFinalOfflineConfirmationTimeout: VirtualDisplayTimingPolicy.rebuildFinalOfflineConfirmationTimeout
                )
            case .fleetOfflineOnly:
                terminationConfirmed = false
                AppLog.virtualDisplay.debug(
                    "Fleet rebuild skipping per-display teardown settlement; relying on fleet offline confirmation (config: \(runningConfigID.uuidString, privacy: .public), serial: \(runtimeSerialNum, privacy: .public), generation: \(String(describing: generationToWaitFor), privacy: .public))."
                )
            }
            terminationConfirmedByConfigID[runningConfigID] = terminationConfirmed
        }
        let fleetOfflineConfirmed = await teardownCoordinator.waitForManagedDisplaysOffline(
            serialNumbers: rebuiltSerials,
            timeout: VirtualDisplayTimingPolicy.rebuildFinalOfflineConfirmationTimeout
        )
        if !fleetOfflineConfirmed {
            AppLog.virtualDisplay.error(
                "Coordinated rebuild aborted because at least one managed display remained online after fleet teardown (configs: \(orderedConfigIDs.map(\.uuidString).joined(separator: ","), privacy: .public))."
            )
            throw VirtualDisplayOperationError.teardownTimedOut
        }
        let fleetCreationCooldown: TimeInterval
        switch teardownStrategy {
        case .perDisplaySettlement:
            fleetCreationCooldown = VirtualDisplayTimingPolicy.rebuildFleetCreationCooldown
        case .fleetOfflineOnly:
            fleetCreationCooldown = VirtualDisplayTimingPolicy.rebuildFleetCreationCooldownFastTeardown
        }
        if fleetCreationCooldown > 0 {
            let cooldown = await dependencies.waitForAdaptiveManagedDisplayCooldown(
                rebuiltSerials,
                fleetCreationCooldown
            )
            AppLog.virtualDisplay.debug(
                "Fleet rebuild creation cooldown (strategy: \(teardownStrategy.logDescription, privacy: .public), maxCooldownSec: \(fleetCreationCooldown, privacy: .public), waitedMs: \(UInt64(cooldown.waitedSeconds * 1000), privacy: .public), earlyExit: \(cooldown.completedEarly, privacy: .public))."
            )
        }

        var recreatedPrioritizedDisplayID: CGDirectDisplayID?
        var recreatedContinuityPreferredDisplayID: CGDirectDisplayID?
        for runningConfigID in orderedConfigIDs {
            guard let runningConfig = configManager.allConfigs().first(where: { $0.id == runningConfigID }) else { continue }
            let terminationConfirmed = terminationConfirmedByConfigID[runningConfigID] ?? true

            let recreatedDisplayID = try await recreateRuntimeDisplayForRebuild(
                config: runningConfig,
                terminationConfirmed: terminationConfirmed
            )
            if runningConfigID == prioritizedConfigID {
                recreatedPrioritizedDisplayID = recreatedDisplayID
            }
            if runningConfigID == continuityPreferredConfigID {
                recreatedContinuityPreferredDisplayID = recreatedDisplayID
            }
        }

        try await ensureHealthyTopologyAfterEnable(
            preferredMainDisplayID: (
                mainPolicyBeforeRebuild.applies
                    ? (mainPolicyBeforeRebuild.targetConfigID.flatMap { runtimeTracker.runtimeDisplayID(for: $0) })
                    : nil
            ) ?? (
                preferPrioritizedAsContinuityMain
                    ? (recreatedPrioritizedDisplayID ??
                        recreatedContinuityPreferredDisplayID ??
                        fallbackPreferredMainDisplayID)
                    : (recreatedContinuityPreferredDisplayID ??
                        recreatedPrioritizedDisplayID ??
                        fallbackPreferredMainDisplayID)
            )
        )
    }

    private func recreateRuntimeDisplayForRebuild(
        config: VirtualDisplayConfig,
        terminationConfirmed: Bool
    ) async throws -> CGDirectDisplayID? {
        if let hook = dependencies.rebuildRuntimeDisplayHook {
            try await hook(config, terminationConfirmed)
            return runtimeTracker.runtimeDisplayID(for: config.id)
        }
        let rebuiltRecord = try await runtimeTracker.createRuntimeDisplayWithRetries(
            from: config,
            terminationConfirmed: terminationConfirmed
        )
        return rebuiltRecord.displayID
    }

    enum FleetRebuildTeardownStrategy {
        case perDisplaySettlement
        case fleetOfflineOnly

        var logDescription: String {
            switch self {
            case .perDisplaySettlement:
                return "perDisplaySettlement"
            case .fleetOfflineOnly:
                return "fleetOfflineOnly"
            }
        }
    }

    func ensureHealthyTopologyAfterEnable(
        preferredMainDisplayID: CGDirectDisplayID? = nil,
        recoveryMode: VirtualDisplayTopologyRecoveryMode = .aggressive
    ) async throws {
        AppLog.virtualDisplay.debug(
            "Topology recovery start (mode: \(recoveryMode.logDescription, privacy: .public), preferredMain: \(String(describing: preferredMainDisplayID), privacy: .public))."
        )
        let initialRequiredStableSamples = recoveryMode == .fast ? 1 : 3
        let initialMinimumTimeout = recoveryMode == .fast ? 0.0 : 0.35
        guard let stableSnapshot = await waitForStableTopology(
            requiredStableSamples: initialRequiredStableSamples,
            minimumTimeout: initialMinimumTimeout
        ) else {
            AppLog.virtualDisplay.error(
                "Topology recovery failed to obtain initial stable snapshot (mode: \(recoveryMode.logDescription, privacy: .public))."
            )
            throw VirtualDisplayOperationError.topologyUnstableAfterEnable
        }
        logTopologySnapshot("topologyRecovery:initialStable", snapshot: stableSnapshot)

        let desiredManagedSerials = Set(configManager.allConfigs().filter(\.desiredEnabled).map(\.serialNum))
        let initialVisibleDesiredManagedCount = stableSnapshot.displays.filter {
            $0.isManagedVirtualDisplay && desiredManagedSerials.contains($0.serialNumber)
        }.count
        let repairedOnInitialPass = try await repairTopologyIfNeeded(
            snapshot: stableSnapshot,
            desiredManagedSerials: desiredManagedSerials,
            preferredMainDisplayID: preferredMainDisplayID,
            allowForceNormalization: recoveryMode == .aggressive
        )

        let initialSnapshotIncompleteForDesiredManagedSet =
            initialVisibleDesiredManagedCount < desiredManagedSerials.count
        let shouldRunDeferredVerification =
            recoveryMode == .aggressive ||
            repairedOnInitialPass ||
            initialSnapshotIncompleteForDesiredManagedSet
        guard shouldRunDeferredVerification, desiredManagedSerials.count >= 2 else {
            AppLog.virtualDisplay.debug(
                "Topology recovery deferred verification skipped (mode: \(recoveryMode.logDescription, privacy: .public), repairedInitial: \(repairedOnInitialPass, privacy: .public), initialVisibleDesiredManagedCount: \(initialVisibleDesiredManagedCount, privacy: .public), desiredCount: \(desiredManagedSerials.count, privacy: .public))."
            )
            return
        }
        let deferredDelay = max(
            VirtualDisplayTimingPolicy.deferredTopologyRecheckMinimumDelay,
            dependencies.topologyStabilityPollInterval * VirtualDisplayTimingPolicy.deferredTopologyRecheckMultiplier
        )
        await clock.sleep(for: .seconds(deferredDelay))

        guard let deferredSnapshot = await waitForStableTopology() else {
            AppLog.virtualDisplay.warning(
                "Topology recovery deferred verification skipped due to unstable snapshot (mode: \(recoveryMode.logDescription, privacy: .public))."
            )
            return
        }
        logTopologySnapshot("topologyRecovery:deferredStable", snapshot: deferredSnapshot)
        _ = try await repairTopologyIfNeeded(
            snapshot: deferredSnapshot,
            desiredManagedSerials: desiredManagedSerials,
            preferredMainDisplayID: preferredMainDisplayID,
            allowForceNormalization: false
        )
    }

    private func repairTopologyIfNeeded(
        snapshot: DisplayTopologySnapshot,
        desiredManagedSerials: Set<UInt32>,
        preferredMainDisplayID: CGDirectDisplayID?,
        allowForceNormalization: Bool
    ) async throws -> Bool {
        let evaluation = TopologyHealthEvaluator.evaluate(
            snapshot: snapshot,
            desiredManagedSerials: desiredManagedSerials
        )
        AppLog.virtualDisplay.debug(
            "Topology evaluation (allowForceNormalization: \(allowForceNormalization), issue: \(self.describe(issue: evaluation.issue)), needsRepair: \(evaluation.needsRepair), forceNormalization: \(evaluation.forceNormalization), managedIDs: \(evaluation.managedDisplayIDs.map(String.init).joined(separator: ","))."
        )
        logTopologySnapshot("topologyRecovery:evaluationSnapshot", snapshot: snapshot)
        let continuityAnchorDisplayID = preferredMainDisplayID.flatMap { preferredMain in
            TopologyHealthEvaluator.shouldEnforceMainContinuity(
                preferredMainDisplayID: preferredMain,
                snapshot: snapshot,
                managedDisplayIDs: evaluation.managedDisplayIDs
            ) ? preferredMain : nil
        }
        let shouldRepairForForceNormalization = allowForceNormalization &&
            evaluation.forceNormalization &&
            evaluation.issue != nil
        let shouldRepair = evaluation.needsRepair || shouldRepairForForceNormalization
        let shouldRepairForContinuity = continuityAnchorDisplayID != nil
        if allowForceNormalization,
           evaluation.forceNormalization,
           evaluation.issue == nil,
           continuityAnchorDisplayID == nil {
            AppLog.virtualDisplay.debug(
                "Topology force normalization skipped because topology is already stable and no continuity repair is needed."
            )
        }
        guard shouldRepair || shouldRepairForContinuity else {
            AppLog.virtualDisplay.debug("Topology evaluation decided no repair.")
            return false
        }
        if !shouldRepair, let continuityAnchorDisplayID {
            AppLog.virtualDisplay.notice(
                "Topology continuity repair requested (anchor: \(continuityAnchorDisplayID), preferredMain: \(String(describing: preferredMainDisplayID)))."
            )
            let continuityRepaired = dependencies.topologyRepairer.repair(
                snapshot: snapshot,
                managedDisplayIDs: evaluation.managedDisplayIDs,
                anchorDisplayID: continuityAnchorDisplayID
            )
            guard continuityRepaired else {
                throw VirtualDisplayOperationError.topologyRepairFailed
            }
            guard let stabilizedAfterContinuity = await waitForStableTopology() else {
                throw VirtualDisplayOperationError.topologyUnstableAfterEnable
            }
            logTopologySnapshot("topologyRecovery:postContinuityStable", snapshot: stabilizedAfterContinuity)
            return true
        }
        let repairAnchorDisplayID = TopologyHealthEvaluator.selectRepairAnchorDisplayID(
            snapshot: snapshot,
            managedDisplayIDs: evaluation.managedDisplayIDs,
            preferredMainDisplayID: preferredMainDisplayID
        )
        AppLog.virtualDisplay.notice(
            "Topology repair requested (anchor: \(repairAnchorDisplayID), preferredMain: \(String(describing: preferredMainDisplayID)), issue: \(self.describe(issue: evaluation.issue)), forceNormalization: \(evaluation.forceNormalization))."
        )

        let repaired = dependencies.topologyRepairer.repair(
            snapshot: snapshot,
            managedDisplayIDs: evaluation.managedDisplayIDs,
            anchorDisplayID: repairAnchorDisplayID
        )
        guard repaired else {
            throw VirtualDisplayOperationError.topologyRepairFailed
        }

        guard let stabilizedAfterRepair = await waitForStableTopology() else {
            throw VirtualDisplayOperationError.topologyUnstableAfterEnable
        }
        logTopologySnapshot("topologyRecovery:postRepairStable", snapshot: stabilizedAfterRepair)

        let postRepairEvaluation = TopologyHealthEvaluator.evaluate(
            snapshot: stabilizedAfterRepair,
            desiredManagedSerials: desiredManagedSerials
        )
        guard !postRepairEvaluation.needsRepair else {
            AppLog.virtualDisplay.error(
                "Topology repair did not clear primary issue (issue: \(self.describe(issue: postRepairEvaluation.issue)))."
            )
            throw VirtualDisplayOperationError.topologyRepairFailed
        }

        if allowForceNormalization && evaluation.forceNormalization {
            let normalizationAnchorDisplayID = TopologyHealthEvaluator.selectRepairAnchorDisplayID(
                snapshot: stabilizedAfterRepair,
                managedDisplayIDs: postRepairEvaluation.managedDisplayIDs,
                preferredMainDisplayID: preferredMainDisplayID
            )
            let normalized = dependencies.topologyRepairer.repair(
                snapshot: stabilizedAfterRepair,
                managedDisplayIDs: postRepairEvaluation.managedDisplayIDs,
                anchorDisplayID: normalizationAnchorDisplayID
            )
            guard normalized else {
                throw VirtualDisplayOperationError.topologyRepairFailed
            }
            guard let stabilizedAfterNormalization = await waitForStableTopology() else {
                throw VirtualDisplayOperationError.topologyUnstableAfterEnable
            }
            logTopologySnapshot("topologyRecovery:postNormalizationStable", snapshot: stabilizedAfterNormalization)
            let postNormalizationEvaluation = TopologyHealthEvaluator.evaluate(
                snapshot: stabilizedAfterNormalization,
                desiredManagedSerials: desiredManagedSerials
            )
            guard !postNormalizationEvaluation.needsRepair else {
                AppLog.virtualDisplay.error(
                    "Topology normalization did not clear issue (issue: \(self.describe(issue: postNormalizationEvaluation.issue)))."
                )
                throw VirtualDisplayOperationError.topologyRepairFailed
            }
            if let continuityMainDisplayID = preferredMainDisplayID,
               TopologyHealthEvaluator.shouldEnforceMainContinuity(
                   preferredMainDisplayID: continuityMainDisplayID,
                   snapshot: stabilizedAfterNormalization,
                   managedDisplayIDs: postNormalizationEvaluation.managedDisplayIDs
               ) {
                let continuityRepaired = dependencies.topologyRepairer.repair(
                    snapshot: stabilizedAfterNormalization,
                    managedDisplayIDs: postNormalizationEvaluation.managedDisplayIDs,
                    anchorDisplayID: continuityMainDisplayID
                )
                guard continuityRepaired else {
                    throw VirtualDisplayOperationError.topologyRepairFailed
                }
                guard let stabilizedAfterContinuity = await waitForStableTopology() else {
                    throw VirtualDisplayOperationError.topologyUnstableAfterEnable
                }
                logTopologySnapshot("topologyRecovery:postContinuityStable", snapshot: stabilizedAfterContinuity)
            }
            return true
        }
        return true
    }

    private func waitForStableTopology(
        requiredStableSamples: Int = 3,
        minimumTimeout: TimeInterval = 0.35
    ) async -> DisplayTopologySnapshot? {
        let effectiveTimeout = max(dependencies.topologyStabilityTimeout, minimumTimeout)
        let deadline = clock.now() + effectiveTimeout
        var previousSnapshot: DisplayTopologySnapshot?
        var stableSampleCount = 0
        let targetStableSamples = max(requiredStableSamples, 1)
        let basePollInterval = max(dependencies.topologyStabilityPollInterval, 0.001)
        let fastProbeInterval = min(
            basePollInterval,
            max(VirtualDisplayTimingPolicy.adaptiveCooldownPollIntervalFloor, basePollInterval / VirtualDisplayTimingPolicy.topologyStabilityAdaptiveProbeDivisor)
        )
        var currentPollInterval = fastProbeInterval

        while clock.now() < deadline {
            guard let currentSnapshot = dependencies.currentTopologySnapshot() else {
                stableSampleCount = 0
                currentPollInterval = min(basePollInterval, max(fastProbeInterval, currentPollInterval))
                await clock.sleep(for: .seconds(currentPollInterval))
                continue
            }

            if previousSnapshot == nil {
                previousSnapshot = currentSnapshot
                stableSampleCount = 1
                if targetStableSamples == 1 {
                    return currentSnapshot
                }
                await clock.sleep(for: .seconds(fastProbeInterval))
                continue
            }

            if previousSnapshot == currentSnapshot {
                stableSampleCount += 1
                currentPollInterval = min(
                    basePollInterval,
                    max(
                        fastProbeInterval,
                        currentPollInterval * VirtualDisplayTimingPolicy.topologyStabilityAdaptiveBackoffMultiplier
                    )
                )
            } else {
                previousSnapshot = currentSnapshot
                stableSampleCount = 1
                currentPollInterval = fastProbeInterval
                if targetStableSamples == 1 {
                    return currentSnapshot
                }
            }

            if stableSampleCount >= targetStableSamples {
                return currentSnapshot
            }
            await clock.sleep(for: .seconds(currentPollInterval))
        }

        return nil
    }

    private func logTopologySnapshot(
        _ label: String,
        snapshot: DisplayTopologySnapshot?
    ) {
        dependencies.logTopologySnapshot(label, snapshot)
    }

    private func describe(snapshot: DisplayTopologySnapshot) -> String {
        let displaysDescription = snapshot.displays.map { display in
            let mainMarker = display.id == snapshot.mainDisplayID ? "*" : ""
            let mirrorMaster = display.mirrorMasterDisplayID.map(String.init) ?? "-"
            let bounds = display.bounds
            let roundedBounds = "\(Int(bounds.origin.x.rounded())):\(Int(bounds.origin.y.rounded())):\(Int(bounds.width.rounded()))x\(Int(bounds.height.rounded()))"
            return [
                "\(mainMarker)\(display.id)",
                "s\(display.serialNumber)",
                display.isManagedVirtualDisplay ? "M" : "P",
                display.isActive ? "A" : "I",
                display.isInMirrorSet ? "mir" : "nomir",
                "master:\(mirrorMaster)",
                "b:\(roundedBounds)"
            ].joined(separator: "/")
        }
        return "main=\(snapshot.mainDisplayID) displays=[\(displaysDescription.joined(separator: ", "))]"
    }

    private func describe(issue: TopologyHealthEvaluation.Issue?) -> String {
        guard let issue else { return "none" }
        switch issue {
        case .managedDisplaysCollapsedIntoSingleMirrorSet:
            return "managedDisplaysCollapsedIntoSingleMirrorSet"
        case .managedDisplaysOverlappingInExtendedSpace:
            return "managedDisplaysOverlappingInExtendedSpace"
        case .mainDisplayOutsideManagedSetWithoutPhysicalFallback:
            return "mainDisplayOutsideManagedSetWithoutPhysicalFallback"
        }
    }
}
