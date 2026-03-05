import Foundation
import CoreGraphics
import OSLog

@MainActor
final class VirtualDisplayOrchestrator {
    // MARK: - Sub-components

    private let configManager: VirtualDisplayConfigManager
    private let runtimeTracker: VirtualDisplayRuntimeTracker
    private let policyResolver: MainDisplayPolicyResolver
    private let teardownCoordinator: any DisplayTeardownCoordinating

    // MARK: - Infrastructure

    private let topologyInspector: any DisplayTopologyInspecting
    private let topologyRepairer: any DisplayTopologyRepairing
    private let clock: any VirtualDisplayClocking
    private let topologyStabilityTimeout: TimeInterval
    private let topologyStabilityPollInterval: TimeInterval
    private let rebuildRuntimeDisplayHook: (@MainActor (VirtualDisplayConfig, Bool) async throws -> Void)?
    private lazy var rebuildCoordinator: DisplayRebuildCoordinator = DisplayRebuildCoordinator(
        dependencies: .init(
            configManager: configManager,
            runtimeTracker: runtimeTracker,
            teardownCoordinator: teardownCoordinator,
            policyResolver: policyResolver,
            topologyRepairer: topologyRepairer,
            clock: clock,
            topologyStabilityTimeout: topologyStabilityTimeout,
            topologyStabilityPollInterval: topologyStabilityPollInterval,
            rebuildRuntimeDisplayHook: rebuildRuntimeDisplayHook,
            currentTopologySnapshot: { [weak self] in
                self?.currentTopologySnapshot()
            },
            waitForAdaptiveManagedDisplayCooldown: { [weak self] serialNumbers, maxCooldown in
                guard let self else {
                    return VirtualDisplayAdaptiveCooldownResult(waitedSeconds: 0, completedEarly: true)
                }
                return await self.waitForAdaptiveManagedDisplayCooldown(
                    serialNumbers: serialNumbers,
                    maxCooldown: maxCooldown
                )
            },
            logTopologySnapshot: { [weak self] label, snapshot in
                self?.logTopologySnapshot(label, snapshot: snapshot)
            }
        )
    )

    convenience init(configRepository: VirtualDisplayConfigRepository) {
        self.init(
            configRepository: configRepository,
            displayReconfigurationMonitor: VirtualDisplayReconfigurationMonitor(),
            managedDisplayOnlineChecker: makeSystemManagedDisplayOnlineChecker(
                managedVendorID: ManagedVirtualDisplayIdentity.vendorID,
                managedProductID: ManagedVirtualDisplayIdentity.productID
            ),
            topologyStabilityTimeout: 3.0,
            topologyStabilityPollInterval: 0.3,
            clock: nil
        )
    }

    convenience init(
        configRepository: VirtualDisplayConfigRepository,
        displayReconfigurationMonitor: any DisplayReconfigurationMonitoring,
        managedDisplayOnlineChecker: @escaping (UInt32) -> Bool,
        topologyStabilityTimeout: TimeInterval = 3.0,
        topologyStabilityPollInterval: TimeInterval = 0.3,
        clock: (any VirtualDisplayClocking)? = nil
    ) {
        self.init(
            configRepository: configRepository,
            displayReconfigurationMonitor: displayReconfigurationMonitor,
            topologyInspector: SystemDisplayTopologyInspector(),
            topologyRepairer: SystemDisplayTopologyRepairer(),
            managedDisplayOnlineChecker: managedDisplayOnlineChecker,
            topologyStabilityTimeout: topologyStabilityTimeout,
            topologyStabilityPollInterval: topologyStabilityPollInterval,
            rebuildRuntimeDisplayHook: nil,
            clock: clock
        )
    }

    init(
        configRepository: VirtualDisplayConfigRepository,
        displayReconfigurationMonitor: any DisplayReconfigurationMonitoring,
        topologyInspector: any DisplayTopologyInspecting,
        topologyRepairer: any DisplayTopologyRepairing,
        managedDisplayOnlineChecker: @escaping (UInt32) -> Bool,
        topologyStabilityTimeout: TimeInterval,
        topologyStabilityPollInterval: TimeInterval,
        rebuildRuntimeDisplayHook: (@MainActor (VirtualDisplayConfig, Bool) async throws -> Void)? = nil,
        clock: (any VirtualDisplayClocking)? = nil
    ) {
        let resolvedClock = clock ?? SystemVirtualDisplayClock()
        let teardownCoordinator = DisplayTeardownCoordinator(
            managedDisplayOnlineChecker: managedDisplayOnlineChecker,
            isReconfigurationMonitorAvailable: false,
            clock: resolvedClock
        )

        let tracker = VirtualDisplayRuntimeTracker(
            teardownCoordinator: teardownCoordinator,
            clock: resolvedClock
        )

        let manager = VirtualDisplayConfigManager(
            configRepository: configRepository,
            activeSerialNumbersProvider: { [weak tracker] in
                tracker?.activeSerialNumbers ?? []
            }
        )

        let resolver = MainDisplayPolicyResolver(
            enabledDesiredConfigsProvider: { [weak manager] in
                manager?.enabledDesiredConfigs() ?? []
            },
            runtimeDisplayIDProvider: { [weak tracker] configId in
                tracker?.runtimeDisplayID(for: configId)
            },
            allConfigsProvider: { [weak manager] in
                manager?.allConfigs() ?? []
            }
        )

        self.configManager = manager
        self.runtimeTracker = tracker
        self.policyResolver = resolver
        self.teardownCoordinator = teardownCoordinator
        self.topologyInspector = topologyInspector
        self.topologyRepairer = topologyRepairer
        self.clock = resolvedClock
        self.topologyStabilityTimeout = topologyStabilityTimeout
        self.topologyStabilityPollInterval = topologyStabilityPollInterval
        self.rebuildRuntimeDisplayHook = rebuildRuntimeDisplayHook

        let monitorAvailable = displayReconfigurationMonitor.start { [weak teardownCoordinator] in
            teardownCoordinator?.completeOfflineWaitersIfPossible()
        }
        teardownCoordinator.setReconfigurationMonitorAvailable(monitorAvailable)
        if !monitorAvailable {
            AppLog.virtualDisplay.error(
                "Failed to register display reconfiguration callback. Offline wait will use polling fallback."
            )
        }

        self._displayReconfigurationMonitor = displayReconfigurationMonitor
    }

    /// Retained solely for lifecycle management (stop on deinit).
    private let _displayReconfigurationMonitor: any DisplayReconfigurationMonitoring

    var snapshot: VirtualDisplaySnapshot {
        let configs = configManager.allConfigs()
        let runtimeDisplayIDByConfigId: [UUID: CGDirectDisplayID] = Dictionary(uniqueKeysWithValues: configs.compactMap { config in
            guard let displayID = runtimeTracker.runtimeDisplayID(for: config.id) else {
                return nil
            }
            return (config.id, displayID)
        })
        let managedDisplays: [ManagedVirtualDisplayRuntimeSnapshot] = configs.compactMap { config -> ManagedVirtualDisplayRuntimeSnapshot? in
            guard let displayID = runtimeDisplayIDByConfigId[config.id] else {
                return nil
            }
            return ManagedVirtualDisplayRuntimeSnapshot(
                configId: config.id,
                serialNum: config.serialNum,
                displayID: displayID,
                isLiveRuntime: runtimeTracker.hasActiveRuntimeDisplay(configId: config.id)
            )
        }
        return VirtualDisplaySnapshot(
            managedDisplays: managedDisplays,
            configs: configs,
            runningConfigIds: runtimeTracker.runningConfigIDs(),
            restoreFailures: configManager.restoreFailureList(),
            configStorePresentation: configManager.configStorePresentation,
            runtimeDisplayIDByConfigId: runtimeDisplayIDByConfigId
        )
    }

    // MARK: - Load / Restore / Reset

    func loadPersistedConfigs() {
        configManager.loadPersistedConfigs()
    }

    func restoreDesiredVirtualDisplays() {
        guard case .ready = configManager.configStoreState else {
            AppLog.virtualDisplay.error(
                "Skip restoring desired virtual displays because config store is in load-failed state."
            )
            configManager.clearRestoreFailures()
            return
        }
        configManager.setRestoreFailures(collectRestoreFailures(from: configManager.allConfigs()))
    }

    func clearRestoreFailures() {
        configManager.clearRestoreFailures()
    }

    @discardableResult
    func resetAllVirtualDisplayData() -> Int {
        let removedConfigCount = configManager.allConfigs().count
        runtimeTracker.resetAll()
        policyResolver.resetAll()
        configManager.resetAll()
        return removedConfigCount
    }

    // MARK: - Main display policy (delegated)

    private func resolveMainDisplayPolicy(
        snapshot: DisplayTopologySnapshot?,
        emitLog: Bool = true
    ) -> MainDisplayPolicyResolver.PolicyResolution {
        policyResolver.resolveMainDisplayPolicy(snapshot: snapshot, emitLog: emitLog)
    }

    func reconcileMainDisplayPolicyIfNeeded() async throws {
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
    func createDisplay(
        name: String,
        serialNum: UInt32,
        physicalSize: CGSize,
        maxPixels: (width: UInt32, height: UInt32),
        modes: [ResolutionSelection]
    ) throws -> UUID {
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

        configManager.appendConfig(config)

        do {
            _ = try runtimeTracker.createRuntimeDisplay(from: config, maxPixels: maxPixels)
            return config.id
        } catch {
            configManager.rollbackAppendedConfig(config.id)
            AppLog.virtualDisplay.error(
                "Create display failed (displayName: \(name, privacy: .public), serial: \(serialNum, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - Disable

    func disableDisplayByConfig(_ configId: UUID) throws {
        guard configManager.configIndex(id: configId) != nil else { return }

        configManager.setDesiredEnabled(configId, enabled: false, reason: .userToggledDesiredEnabled)
        guard let config = configManager.config(id: configId) else { return }

        let runtimeSerialNum = runtimeTracker.runtimeSerialNum(
            for: configId,
            fallback: config.serialNum
        )
        let runtimeDisplayID = runtimeTracker.runtimeDisplayID(for: configId)
        let disablingMain = runtimeDisplayID == CGMainDisplayID()
        AppLog.virtualDisplay.notice(
            "Disable-by-config requested (config: \(configId.uuidString, privacy: .public), serial: \(runtimeSerialNum, privacy: .public), runtimeDisplayID: \(String(describing: runtimeDisplayID), privacy: .public), disablingMain: \(disablingMain, privacy: .public))."
        )
        logTopologySnapshot("disableDisplayByConfig:pre-clear", snapshot: currentTopologySnapshot())
        if disablingMain {
            policyResolver.markAggressiveRecoveryPending(configId: configId)
        }
        runtimeTracker.clearRuntimeTracking(configId: configId, keepGeneration: true)
    }

    // MARK: - Enable

    func enableDisplay(_ configId: UUID) async throws {
        guard configManager.configIndex(id: configId) != nil else {
            throw VirtualDisplayOperationError.configNotFound
        }

        configManager.setDesiredEnabled(configId, enabled: true, reason: .userToggledDesiredEnabled)
        guard let config = configManager.config(id: configId) else {
            throw VirtualDisplayOperationError.configNotFound
        }

        let enableStart = DispatchTime.now().uptimeNanoseconds
        let topologyBeforeEnable = currentTopologySnapshot()
        let mainPolicyResolution = policyResolver.resolveMainDisplayPolicy(
            snapshot: topologyBeforeEnable
        )
        let preferredMainDisplayID = mainPolicyResolution.preferredMainDisplayID
        let recoveryMode: VirtualDisplayTopologyRecoveryMode = policyResolver.isAggressiveRecoveryPending(configId: configId)
            ? .aggressive
            : .fast
        AppLog.virtualDisplay.notice(
            "Enable display requested (config: \(configId.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), recoveryMode: \(recoveryMode.logDescription, privacy: .public), preferredMain: \(String(describing: preferredMainDisplayID), privacy: .public), pendingGeneration: \(String(describing: self.runtimeTracker.runtimeGeneration(for: configId)), privacy: .public), isRunning: \(self.runtimeTracker.isVirtualDisplayRunning(configId: configId), privacy: .public))."
        )
        logTopologySnapshot("enableDisplay:pre-enable", snapshot: topologyBeforeEnable)

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
                if !settlement.offlineConfirmed {
                    AppLog.virtualDisplay.error(
                        "Enable aborted because previous display with same serial is still online after teardown settlement (serial: \(config.serialNum, privacy: .public), config: \(config.id.uuidString, privacy: .public), generation: \(pendingGeneration, privacy: .public))."
                    )
                    throw VirtualDisplayOperationError.teardownTimedOut
                }
                terminationConfirmed = settlement.terminationObserved
            }
            offlineVerified = true
        }
        if !runtimeTracker.hasActiveRuntimeDisplay(configId: configId), !offlineVerified {
            let offlineConfirmed = await runtimeTracker.waitForManagedDisplayOffline(serialNum: config.serialNum)
            if !offlineConfirmed {
                AppLog.virtualDisplay.error(
                    "Enable aborted because previous display with same serial is still online (serial: \(config.serialNum, privacy: .public), config: \(config.id.uuidString, privacy: .public))."
                )
                throw VirtualDisplayOperationError.teardownTimedOut
            }
            offlineVerified = true
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
                return
            }
            if recoveryMode == .aggressive && !terminationConfirmed {
                let cooldown = await waitForAdaptiveManagedDisplayCooldown(
                    serialNumbers: [config.serialNum],
                    maxCooldown: VirtualDisplayTimingPolicy.aggressiveEnableUnsettledTeardownCooldown
                )
                AppLog.virtualDisplay.notice(
                    "Aggressive enable teardown settle cooldown completed (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), maxCooldownSec: \(VirtualDisplayTimingPolicy.aggressiveEnableUnsettledTeardownCooldown, privacy: .public), waitedMs: \(UInt64(cooldown.waitedSeconds * 1000), privacy: .public), earlyExit: \(cooldown.completedEarly, privacy: .public))."
                )
                logTopologySnapshot("enableDisplay:pre-create-post-cooldown", snapshot: currentTopologySnapshot())
            }
            let createdDisplayRecord = try await runtimeTracker.createRuntimeDisplayWithRetries(
                from: config,
                terminationConfirmed: terminationConfirmed
            )
            let createdDisplaySerialNum = createdDisplayRecord.serialNum
            let createdDisplayID = createdDisplayRecord.displayID
            AppLog.virtualDisplay.notice(
                "Enable created runtime display (config: \(config.id.uuidString, privacy: .public), serial: \(createdDisplaySerialNum, privacy: .public), displayID: \(createdDisplayID, privacy: .public), recoveryMode: \(recoveryMode.logDescription, privacy: .public))."
            )
            logTopologySnapshot("enableDisplay:post-create-pre-recovery", snapshot: currentTopologySnapshot())
            do {
                let postCreatePolicyResolution = resolveMainDisplayPolicy(
                    snapshot: currentTopologySnapshot()
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
    }

    // MARK: - Destroy

    func destroyDisplay(_ configId: UUID) {
        guard configManager.config(id: configId) != nil else { return }
        policyResolver.clearAggressiveRecoveryPending(configId: configId)
        runtimeTracker.clearRuntimeTracking(configId: configId, keepGeneration: false)
        configManager.removeConfig(configId)
    }

    // MARK: - Config operations (delegated)

    func updateConfig(_ updated: VirtualDisplayConfig) {
        configManager.updateConfig(updated)
    }

    @discardableResult
    func moveConfig(_ configId: UUID, direction: VirtualDisplayReorderDirection) -> Bool {
        configManager.moveConfig(configId, direction: direction)
    }

    @discardableResult
    func moveConfigToFirstEnabledPosition(_ configId: UUID) -> Bool {
        configManager.moveConfigToFirstEnabledPosition(configId)
    }

    func applyModes(configId: UUID, modes: [ResolutionSelection]) {
        runtimeTracker.applyModes(configId: configId, modes: modes)
    }

    func rebuildVirtualDisplay(configId: UUID) async throws {
        try await rebuildCoordinator.rebuildVirtualDisplay(configId: configId)
    }

    func nextAvailableSerialNumber() -> UInt32 {
        configManager.nextAvailableSerialNumber()
    }

    // MARK: - Topology

    private func currentTopologySnapshot() -> DisplayTopologySnapshot? {
        topologyInspector.snapshot(
            trackedManagedSerials: trackedManagedSerials(),
            managedVendorID: ManagedVirtualDisplayIdentity.vendorID,
            managedProductID: ManagedVirtualDisplayIdentity.productID
        )
    }

    private func trackedManagedSerials() -> Set<UInt32> {
        Set(configManager.allConfigs().map(\.serialNum))
            .union(runtimeTracker.activeSerialNumbers)
    }

    // MARK: - Adaptive cooldown

    private func waitForAdaptiveManagedDisplayCooldown(
        serialNumbers: [UInt32],
        maxCooldown: TimeInterval
    ) async -> VirtualDisplayAdaptiveCooldownResult {
        let targetSerials = Set(serialNumbers)
        guard !targetSerials.isEmpty, maxCooldown > 0 else {
            return VirtualDisplayAdaptiveCooldownResult(waitedSeconds: 0, completedEarly: true)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = clock.now() + max(maxCooldown, 0)
        let pollInterval = min(
            VirtualDisplayTimingPolicy.adaptiveCooldownPollIntervalCeiling,
            max(VirtualDisplayTimingPolicy.adaptiveCooldownPollIntervalFloor, topologyStabilityPollInterval / 4)
        )
        var stableAbsenceSamples = 0

        while clock.now() < deadline {
            if let snapshot = currentTopologySnapshot() {
                let managedTargetsVisible = snapshot.displays.contains { display in
                    display.isManagedVirtualDisplay && targetSerials.contains(display.serialNumber)
                }
                if managedTargetsVisible {
                    stableAbsenceSamples = 0
                } else {
                    stableAbsenceSamples += 1
                    if stableAbsenceSamples >= VirtualDisplayTimingPolicy.adaptiveCooldownStableSamplesRequired {
                        let waitedMs = elapsedMilliseconds(since: start)
                        return VirtualDisplayAdaptiveCooldownResult(
                            waitedSeconds: Double(waitedMs) / 1000,
                            completedEarly: true
                        )
                    }
                }
            } else {
                stableAbsenceSamples = 0
            }
            await clock.sleep(seconds: pollInterval)
        }

        let waitedMs = elapsedMilliseconds(since: start)
        return VirtualDisplayAdaptiveCooldownResult(
            waitedSeconds: Double(waitedMs) / 1000,
            completedEarly: false
        )
    }

    // MARK: - Restore helpers

    private func collectRestoreFailures(from configs: [VirtualDisplayConfig]) -> [VirtualDisplayRestoreFailure] {
        var failures: [VirtualDisplayRestoreFailure] = []
        for config in configs where config.desiredEnabled {
            do {
                _ = try runtimeTracker.createRuntimeDisplay(from: config)
            } catch {
                let message = error.localizedDescription
                AppLog.persistence.error(
                    "Restore virtual display failed (serial: \(config.serialNum, privacy: .public), name: \(config.displayName, privacy: .public)): \(message, privacy: .public)"
                )
                failures.append(
                    .init(
                        id: config.id,
                        name: config.displayName,
                        serialNum: config.serialNum,
                        message: message
                    )
                )
            }
        }
        return failures
    }

    // MARK: - Logging

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

    private func elapsedMilliseconds(since startNanoseconds: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= startNanoseconds ? (now - startNanoseconds) / 1_000_000 : 0
    }

    // MARK: - Lifecycle

    deinit {
        MainActor.assumeIsolated {
            teardownCoordinator.cancelAllTerminationWaiters()
            teardownCoordinator.cancelAllOfflineWaiters()
            _displayReconfigurationMonitor.stop()
        }
    }
}
