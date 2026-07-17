import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import CoreGraphics
import OSLog

@MainActor
package final class VirtualDisplayOrchestrator {
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
    private lazy var enableCoordinator = VirtualDisplayEnableCoordinator(
        dependencies: .init(
            configManager: configManager,
            runtimeTracker: runtimeTracker,
            policyResolver: policyResolver,
            teardownCoordinator: teardownCoordinator,
            rebuildCoordinator: rebuildCoordinator,
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

    package convenience init(
        configRepository: VirtualDisplayConfigRepository,
        runtimeDriver: any VirtualDisplayRuntimeDriving
    ) {
        self.init(
            configRepository: configRepository,
            displayReconfigurationMonitor: VirtualDisplayReconfigurationMonitor(),
            managedDisplayOnlineChecker: makeSystemManagedDisplayOnlineChecker(
                managedVendorID: ManagedVirtualDisplayIdentity.vendorID,
                managedProductID: ManagedVirtualDisplayIdentity.productID
            ),
            topologyStabilityTimeout: 3.0,
            topologyStabilityPollInterval: 0.3,
            runtimeDriver: runtimeDriver,
            clock: nil
        )
    }

    package convenience init(
        configRepository: VirtualDisplayConfigRepository,
        displayReconfigurationMonitor: any DisplayReconfigurationMonitoring,
        managedDisplayOnlineChecker: @escaping (UInt32) -> Bool,
        topologyStabilityTimeout: TimeInterval = 3.0,
        topologyStabilityPollInterval: TimeInterval = 0.3,
        runtimeDriver: any VirtualDisplayRuntimeDriving,
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
            runtimeDriver: runtimeDriver,
            clock: clock
        )
    }

    package init(
        configRepository: VirtualDisplayConfigRepository,
        displayReconfigurationMonitor: any DisplayReconfigurationMonitoring,
        topologyInspector: any DisplayTopologyInspecting,
        topologyRepairer: any DisplayTopologyRepairing,
        managedDisplayOnlineChecker: @escaping (UInt32) -> Bool,
        topologyStabilityTimeout: TimeInterval,
        topologyStabilityPollInterval: TimeInterval,
        rebuildRuntimeDisplayHook: (@MainActor (VirtualDisplayConfig, Bool) async throws -> Void)? = nil,
        runtimeDriver: any VirtualDisplayRuntimeDriving,
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
            runtimeDriver: runtimeDriver,
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

    package var snapshot: VirtualDisplaySnapshot {
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

    package func loadPersistedVirtualDisplayConfigsForStartupRestoreCommand() -> VirtualDisplayStartupRestoreConfigLoadResult {
        configManager.loadPersistedConfigsIfNeeded()
    }

    package func loadPersistedConfigs() {
        _ = configManager.loadPersistedConfigs()
    }

    package func restoreVirtualDisplayForStartupCommand(
        _ request: VirtualDisplayStartupRestoreCommandRequest
    ) -> VirtualDisplayStartupRestoreCommandResult {
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
            let record = try runtimeTracker.createRuntimeDisplay(from: config)
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

    // MARK: - Main display policy (delegated)

    private func resolveMainDisplayPolicy(
        snapshot: DisplayTopologySnapshot?,
        emitLog: Bool = true
    ) -> MainDisplayPolicyResolver.PolicyResolution {
        policyResolver.resolveMainDisplayPolicy(snapshot: snapshot, emitLog: emitLog)
    }

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

    // MARK: - Config operations (delegated)

    package func updateConfig(_ updated: VirtualDisplayConfig) throws {
        try configManager.updateConfig(updated)
    }

    package func configForEditRebuild(_ configId: UUID) -> VirtualDisplayConfig? {
        configManager.config(id: configId)
    }

    package func saveConfigForRebuild(_ updated: VirtualDisplayConfig) throws {
        try configManager.updateConfig(updated)
    }

    package func restoreConfigAfterFailedEdit(_ previous: VirtualDisplayConfig) throws {
        try configManager.updateConfig(previous)
    }

    @discardableResult
    package func moveConfig(_ configId: UUID, direction: VirtualDisplayReorderDirection) throws -> Bool {
        try configManager.moveConfig(configId, direction: direction)
    }

    @discardableResult
    package func moveConfigToFirstEnabledPosition(_ configId: UUID) throws -> Bool {
        try configManager.moveConfigToFirstEnabledPosition(configId)
    }

    package func applyModes(configId: UUID, modes: [ResolutionSelection]) {
        runtimeTracker.applyModes(configId: configId, modes: modes)
    }

    package func rebuildVirtualDisplay(configId: UUID) async throws {
        try await rebuildCoordinator.rebuildVirtualDisplay(configId: configId)
    }

    package func nextAvailableSerialNumber() -> UInt32 {
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
            await clock.sleep(for: .seconds(pollInterval))
        }

        let waitedMs = elapsedMilliseconds(since: start)
        return VirtualDisplayAdaptiveCooldownResult(
            waitedSeconds: Double(waitedMs) / 1000,
            completedEarly: false
        )
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

    // MARK: - Lifecycle

    deinit {
        MainActor.assumeIsolated {
            teardownCoordinator.cancelAllTerminationWaiters()
            teardownCoordinator.cancelAllOfflineWaiters()
            _displayReconfigurationMonitor.stop()
        }
    }
}
