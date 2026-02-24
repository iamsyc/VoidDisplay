import Foundation
import CoreGraphics
import OSLog

extension VirtualDisplayService.TopologyRecoveryMode {
    var logDescription: String {
        switch self {
        case .fast: return "fast"
        case .aggressive: return "aggressive"
        }
    }
}

@MainActor
final class DisplayRebuildCoordinator {
    private unowned let service: VirtualDisplayService

    init(service: VirtualDisplayService) {
        self.service = service
    }

    func rebuildVirtualDisplay(configId: UUID) async throws {
        guard let config = service.displayConfigs.first(where: { $0.id == configId }) else {
            throw VirtualDisplayService.VirtualDisplayError.configNotFound
        }

        let snapshotBeforeRebuild = service.currentTopologySnapshot()
        let preferredMainDisplayID = TopologyHealthEvaluator.preferredManagedMainDisplayID(
            snapshot: service.currentTopologySnapshot()
        )
        let targetRuntimeDisplayID = service.runtimeDisplayID(for: configId)
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

        let targetWasRunning = service.runningConfigIds.contains(configId)
        let runtimeSerialNum = service.activeDisplaysByConfigId[configId]?.serialNum ?? config.serialNum
        let generationToWaitFor = targetWasRunning
            ? service.runtimeGenerationByConfigId[configId]
            : nil
        if targetWasRunning {
            service.activeDisplaysByConfigId[configId] = nil
            service.runtimeDisplayIDHintsByConfigId[configId] = nil
            service.runningConfigIds.remove(configId)
            service.displays.removeAll { $0.serialNum == runtimeSerialNum }
        }

        let terminationConfirmed: Bool
        if targetWasRunning,
           !targetWasManagedMain,
           generationToWaitFor != nil {
            let offlineConfirmedQuick = await service.teardownCoordinator.waitForManagedDisplayOffline(
                serialNum: runtimeSerialNum,
                timeout: VirtualDisplayService.rebuildFleetCreationCooldownFastTeardown
            )
            if offlineConfirmedQuick {
                // Offline is confirmed; proceed without the heavier settlement path.
                terminationConfirmed = false
            } else {
                terminationConfirmed = try await service.teardownCoordinator.settleRebuildTeardown(
                    configId: config.id,
                    serialNum: runtimeSerialNum,
                    generationToWaitFor: generationToWaitFor,
                    rebuildTerminationTimeout: VirtualDisplayService.rebuildTerminationTimeout,
                    rebuildOfflineTimeout: VirtualDisplayService.rebuildOfflineTimeout,
                    rebuildFinalOfflineConfirmationTimeout: VirtualDisplayService.rebuildFinalOfflineConfirmationTimeout
                )
            }
        } else {
            terminationConfirmed = try await service.teardownCoordinator.settleRebuildTeardown(
                configId: config.id,
                serialNum: runtimeSerialNum,
                generationToWaitFor: generationToWaitFor,
                rebuildTerminationTimeout: VirtualDisplayService.rebuildTerminationTimeout,
                rebuildOfflineTimeout: VirtualDisplayService.rebuildOfflineTimeout,
                rebuildFinalOfflineConfirmationTimeout: VirtualDisplayService.rebuildFinalOfflineConfirmationTimeout
            )
        }

        let recreatedTargetDisplayID = try await recreateRuntimeDisplayForRebuild(
            config: config,
            terminationConfirmed: terminationConfirmed
        )
        let preferredMainAfterRebuild: CGDirectDisplayID?
        if targetWasManagedMain {
            preferredMainAfterRebuild = recreatedTargetDisplayID ?? preferredMainDisplayID
        } else {
            preferredMainAfterRebuild = preferredMainDisplayID
        }
        let recoveryModeAfterRebuild: VirtualDisplayService.TopologyRecoveryMode =
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
        guard service.runningConfigIds.contains(configId),
              service.runningConfigIds.count >= 2 else {
            return false
        }
        if let runtimeDisplayID = service.runtimeDisplayID(for: configId),
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
        var ordered = service.displayConfigs
            .map(\.id)
            .filter { service.runningConfigIds.contains($0) }
        if let index = ordered.firstIndex(of: configId) {
            ordered.remove(at: index)
            ordered.insert(configId, at: 0)
        } else if service.runningConfigIds.contains(configId) {
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
           service.displayConfigs.contains(where: { $0.id == prioritizedConfigID }) {
            orderedConfigIDs.insert(prioritizedConfigID, at: 0)
        }
        guard !orderedConfigIDs.isEmpty else {
            throw VirtualDisplayService.VirtualDisplayError.configNotFound
        }

        var terminationConfirmedByConfigID: [UUID: Bool] = [:]
        var rebuiltSerials: [UInt32] = []
        for runningConfigID in orderedConfigIDs {
            guard let runningConfig = service.displayConfigs.first(where: { $0.id == runningConfigID }) else { continue }
            rebuiltSerials.append(runningConfig.serialNum)

            let runtimeSerialNum = service.activeDisplaysByConfigId[runningConfigID]?.serialNum ?? runningConfig.serialNum
            let generationToWaitFor = service.runtimeGenerationByConfigId[runningConfigID]

            service.activeDisplaysByConfigId[runningConfigID] = nil
            service.runtimeDisplayIDHintsByConfigId[runningConfigID] = nil
            service.runningConfigIds.remove(runningConfigID)
            service.displays.removeAll { $0.serialNum == runtimeSerialNum }

            let terminationConfirmed: Bool
            switch teardownStrategy {
            case .perDisplaySettlement:
                terminationConfirmed = try await service.teardownCoordinator.settleRebuildTeardown(
                    configId: runningConfigID,
                    serialNum: runningConfig.serialNum,
                    generationToWaitFor: generationToWaitFor,
                    rebuildTerminationTimeout: VirtualDisplayService.rebuildTerminationTimeout,
                    rebuildOfflineTimeout: VirtualDisplayService.rebuildOfflineTimeout,
                    rebuildFinalOfflineConfirmationTimeout: VirtualDisplayService.rebuildFinalOfflineConfirmationTimeout
                )
            case .fleetOfflineOnly:
                terminationConfirmed = false
                AppLog.virtualDisplay.debug(
                    "Fleet rebuild skipping per-display teardown settlement; relying on fleet offline confirmation (config: \(runningConfigID.uuidString, privacy: .public), serial: \(runningConfig.serialNum, privacy: .public), generation: \(String(describing: generationToWaitFor), privacy: .public))."
                )
            }
            terminationConfirmedByConfigID[runningConfigID] = terminationConfirmed
        }
        let fleetOfflineConfirmed = await service.teardownCoordinator.waitForManagedDisplaysOffline(
            serialNumbers: rebuiltSerials,
            timeout: VirtualDisplayService.rebuildFinalOfflineConfirmationTimeout
        )
        if !fleetOfflineConfirmed {
            AppLog.virtualDisplay.error(
                "Coordinated rebuild aborted because at least one managed display remained online after fleet teardown (configs: \(orderedConfigIDs.map(\.uuidString).joined(separator: ","), privacy: .public))."
            )
            throw VirtualDisplayService.VirtualDisplayError.teardownTimedOut
        }
        let fleetCreationCooldown: TimeInterval
        switch teardownStrategy {
        case .perDisplaySettlement:
            fleetCreationCooldown = VirtualDisplayService.rebuildFleetCreationCooldown
        case .fleetOfflineOnly:
            fleetCreationCooldown = VirtualDisplayService.rebuildFleetCreationCooldownFastTeardown
        }
        if fleetCreationCooldown > 0 {
            let cooldown = await service.waitForAdaptiveManagedDisplayCooldown(
                serialNumbers: rebuiltSerials,
                maxCooldown: fleetCreationCooldown
            )
            AppLog.virtualDisplay.debug(
                "Fleet rebuild creation cooldown (strategy: \(teardownStrategy.logDescription, privacy: .public), maxCooldownSec: \(fleetCreationCooldown, privacy: .public), waitedMs: \(UInt64(cooldown.waitedSeconds * 1000), privacy: .public), earlyExit: \(cooldown.completedEarly, privacy: .public))."
            )
        }

        var recreatedPreferredMainDisplayID: CGDirectDisplayID?
        for runningConfigID in orderedConfigIDs {
            guard let runningConfig = service.displayConfigs.first(where: { $0.id == runningConfigID }) else { continue }
            let terminationConfirmed = terminationConfirmedByConfigID[runningConfigID] ?? true

            let recreatedDisplayID = try await recreateRuntimeDisplayForRebuild(
                config: runningConfig,
                terminationConfirmed: terminationConfirmed
            )
            if runningConfigID == prioritizedConfigID {
                recreatedPreferredMainDisplayID = recreatedDisplayID
            }
        }

        try await ensureHealthyTopologyAfterEnable(
            preferredMainDisplayID: recreatedPreferredMainDisplayID ?? fallbackPreferredMainDisplayID
        )
    }

    private func recreateRuntimeDisplayForRebuild(
        config: VirtualDisplayConfig,
        terminationConfirmed: Bool
    ) async throws -> CGDirectDisplayID? {
        if let hook = service.rebuildRuntimeDisplayHook {
            try await hook(config, terminationConfirmed)
            return service.runtimeDisplayID(for: config.id)
        }
        let rebuiltDisplay = try await service.createRuntimeDisplayWithRetries(
            from: config,
            terminationConfirmed: terminationConfirmed
        )
        return rebuiltDisplay.displayID
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
        recoveryMode: VirtualDisplayService.TopologyRecoveryMode = .aggressive
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
            throw VirtualDisplayService.VirtualDisplayError.topologyUnstableAfterEnable
        }
        logTopologySnapshot("topologyRecovery:initialStable", snapshot: stableSnapshot)

        let desiredManagedSerials = Set(service.displayConfigs.filter(\.desiredEnabled).map(\.serialNum))
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
            VirtualDisplayService.deferredTopologyRecheckMinimumDelay,
            service.topologyStabilityPollInterval * VirtualDisplayService.deferredTopologyRecheckMultiplier
        )
        await service.sleepForRetry(seconds: deferredDelay)

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
            let continuityRepaired = service.topologyRepairer.repair(
                snapshot: snapshot,
                managedDisplayIDs: evaluation.managedDisplayIDs,
                anchorDisplayID: continuityAnchorDisplayID
            )
            guard continuityRepaired else {
                throw VirtualDisplayService.VirtualDisplayError.topologyRepairFailed
            }
            guard let stabilizedAfterContinuity = await waitForStableTopology() else {
                throw VirtualDisplayService.VirtualDisplayError.topologyUnstableAfterEnable
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

        let repaired = service.topologyRepairer.repair(
            snapshot: snapshot,
            managedDisplayIDs: evaluation.managedDisplayIDs,
            anchorDisplayID: repairAnchorDisplayID
        )
        guard repaired else {
            throw VirtualDisplayService.VirtualDisplayError.topologyRepairFailed
        }

        guard let stabilizedAfterRepair = await waitForStableTopology() else {
            throw VirtualDisplayService.VirtualDisplayError.topologyUnstableAfterEnable
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
            throw VirtualDisplayService.VirtualDisplayError.topologyRepairFailed
        }

        if allowForceNormalization && evaluation.forceNormalization {
            let normalizationAnchorDisplayID = TopologyHealthEvaluator.selectRepairAnchorDisplayID(
                snapshot: stabilizedAfterRepair,
                managedDisplayIDs: postRepairEvaluation.managedDisplayIDs,
                preferredMainDisplayID: preferredMainDisplayID
            )
            let normalized = service.topologyRepairer.repair(
                snapshot: stabilizedAfterRepair,
                managedDisplayIDs: postRepairEvaluation.managedDisplayIDs,
                anchorDisplayID: normalizationAnchorDisplayID
            )
            guard normalized else {
                throw VirtualDisplayService.VirtualDisplayError.topologyRepairFailed
            }
            guard let stabilizedAfterNormalization = await waitForStableTopology() else {
                throw VirtualDisplayService.VirtualDisplayError.topologyUnstableAfterEnable
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
                throw VirtualDisplayService.VirtualDisplayError.topologyRepairFailed
            }
            if let continuityMainDisplayID = preferredMainDisplayID,
               TopologyHealthEvaluator.shouldEnforceMainContinuity(
                   preferredMainDisplayID: continuityMainDisplayID,
                   snapshot: stabilizedAfterNormalization,
                   managedDisplayIDs: postNormalizationEvaluation.managedDisplayIDs
               ) {
                let continuityRepaired = service.topologyRepairer.repair(
                    snapshot: stabilizedAfterNormalization,
                    managedDisplayIDs: postNormalizationEvaluation.managedDisplayIDs,
                    anchorDisplayID: continuityMainDisplayID
                )
                guard continuityRepaired else {
                    throw VirtualDisplayService.VirtualDisplayError.topologyRepairFailed
                }
                guard let stabilizedAfterContinuity = await waitForStableTopology() else {
                    throw VirtualDisplayService.VirtualDisplayError.topologyUnstableAfterEnable
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
        let effectiveTimeout = max(service.topologyStabilityTimeout, minimumTimeout)
        let deadline = Date().addingTimeInterval(effectiveTimeout)
        var previousSnapshot: DisplayTopologySnapshot?
        var stableSampleCount = 0
        let targetStableSamples = max(requiredStableSamples, 1)
        let basePollInterval = max(service.topologyStabilityPollInterval, 0.001)
        let fastProbeInterval = min(
            basePollInterval,
            max(VirtualDisplayService.adaptiveCooldownPollIntervalFloor, basePollInterval / VirtualDisplayService.topologyStabilityAdaptiveProbeDivisor)
        )
        var currentPollInterval = fastProbeInterval

        while Date() < deadline {
            guard let currentSnapshot = service.currentTopologySnapshot() else {
                stableSampleCount = 0
                currentPollInterval = min(basePollInterval, max(fastProbeInterval, currentPollInterval))
                await service.sleepForRetry(seconds: currentPollInterval)
                continue
            }

            if previousSnapshot == nil {
                previousSnapshot = currentSnapshot
                stableSampleCount = 1
                // For fast mode (targetStableSamples == 1) return immediately on first valid snapshot
                if targetStableSamples == 1 {
                    return currentSnapshot
                }
                await service.sleepForRetry(seconds: fastProbeInterval)
                continue
            }

            if previousSnapshot == currentSnapshot {
                stableSampleCount += 1
                currentPollInterval = min(
                    basePollInterval,
                    max(
                        fastProbeInterval,
                        currentPollInterval * VirtualDisplayService.topologyStabilityAdaptiveBackoffMultiplier
                    )
                )
            } else {
                previousSnapshot = currentSnapshot
                stableSampleCount = 1
                currentPollInterval = fastProbeInterval
                // For fast mode (targetStableSamples == 1) return as soon as we observe a snapshot
                if targetStableSamples == 1 {
                    return currentSnapshot
                }
            }

            if stableSampleCount >= targetStableSamples {
                return currentSnapshot
            }
            await service.sleepForRetry(seconds: currentPollInterval)
        }

        return nil
    }

    private func logTopologySnapshot(
        _ label: String,
        snapshot: DisplayTopologySnapshot?
    ) {
        guard let snapshot else {
            AppLog.virtualDisplay.debug("\(label, privacy: .public): snapshot=nil")
            return
        }
        AppLog.virtualDisplay.debug(
            "\(label, privacy: .public): \(self.describe(snapshot: snapshot), privacy: .public)"
        )
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
