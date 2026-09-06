import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import CoreGraphics
import OSLog

@MainActor
package final class VirtualDisplayOrchestrator {
    // MARK: - Sub-components

    let configManager: VirtualDisplayConfigManager
    let runtimeTracker: VirtualDisplayRuntimeTracker
    let policyResolver: MainDisplayPolicyResolver
    private let teardownCoordinator: any DisplayTeardownCoordinating

    // MARK: - Infrastructure

    let topologyInspector: any DisplayTopologyInspecting
    private let topologyRepairer: any DisplayTopologyRepairing
    let clock: any VirtualDisplayClocking
    private let topologyStabilityTimeout: TimeInterval
    let topologyStabilityPollInterval: TimeInterval
    private let rebuildRuntimeDisplayHook: (@MainActor (VirtualDisplayConfig, Bool) async throws -> Void)?
    lazy var rebuildCoordinator: DisplayRebuildCoordinator = DisplayRebuildCoordinator(
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
    lazy var enableCoordinator = VirtualDisplayEnableCoordinator(
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

    package func rebuildVirtualDisplay(configId: UUID) async throws {
        try await rebuildCoordinator.rebuildVirtualDisplay(configId: configId)
    }

    package func nextAvailableSerialNumber() -> UInt32 {
        configManager.nextAvailableSerialNumber()
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
