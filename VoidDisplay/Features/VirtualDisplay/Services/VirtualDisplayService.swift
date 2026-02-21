import Foundation
import CoreGraphics
import OSLog

struct DisplayTopologySnapshot: Equatable {
    struct DisplayInfo: Equatable {
        let id: CGDirectDisplayID
        let serialNumber: UInt32
        let isManagedVirtualDisplay: Bool
        let isActive: Bool
        let isInMirrorSet: Bool
        let mirrorMasterDisplayID: CGDirectDisplayID?
        let bounds: CGRect
    }

    let mainDisplayID: CGDirectDisplayID
    let displays: [DisplayInfo]

    func display(for id: CGDirectDisplayID) -> DisplayInfo? {
        displays.first(where: { $0.id == id })
    }
}

protocol DisplayTopologyInspecting {
    func snapshot(
        trackedManagedSerials: Set<UInt32>,
        managedVendorID: UInt32,
        managedProductID: UInt32
    ) -> DisplayTopologySnapshot?
}

protocol DisplayTopologyRepairing {
    func repair(
        snapshot: DisplayTopologySnapshot,
        managedDisplayIDs: [CGDirectDisplayID],
        anchorDisplayID: CGDirectDisplayID
    ) -> Bool
}

@MainActor
final class VirtualDisplayService {
    private static let managedVendorID: UInt32 = 0x3456
    private static let managedProductID: UInt32 = 0x1234
    private static let rollbackOfflineWaitTimeout: TimeInterval = 1.2
    private static let rebuildTerminationTimeout: TimeInterval = 2.0
    private static let rebuildOfflineTimeout: TimeInterval = 4.0
    private static let rebuildFinalOfflineConfirmationTimeout: TimeInterval = 0.8
    private static let rebuildFleetCreationCooldown: TimeInterval = 0.6

    private struct TerminationWaiter {
        let expectedGeneration: UInt64
        var continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>
    }

    private struct OfflineWaiter {
        let serialNum: UInt32
        var continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>
    }

    private struct TeardownSettlement {
        let terminationObserved: Bool
        let offlineConfirmed: Bool
    }

    private enum TeardownSettlementEvent {
        case termination(Bool)
        case offline(Bool)
    }

    enum ReorderDirection {
        case up
        case down
    }

    enum VirtualDisplayError: LocalizedError {
        case duplicateSerialNumber(UInt32)
        case invalidConfiguration(String)
        case creationFailed
        case configNotFound
        case teardownTimedOut
        case topologyRepairFailed
        case topologyUnstableAfterEnable

        var errorDescription: String? {
            switch self {
            case .duplicateSerialNumber(let num):
                return String(localized: "Serial number \(num) is already in use.")
            case .invalidConfiguration(let reason):
                return String(localized: "Invalid configuration: \(reason)")
            case .creationFailed:
                return String(localized: "Virtual display creation failed.")
            case .configNotFound:
                return String(localized: "Display configuration not found.")
            case .teardownTimedOut:
                return String(localized: "Display teardown timed out. Wait a moment and try rebuilding again.")
            case .topologyRepairFailed:
                return String(localized: "Display topology repair failed. Open System Display Settings and recheck arrangement.")
            case .topologyUnstableAfterEnable:
                return String(localized: "Display topology did not stabilize after enabling. Please try again.")
            }
        }
    }

    private let persistenceService: VirtualDisplayPersistenceService
    private var displays: [CGVirtualDisplay] = []
    private var displayConfigs: [VirtualDisplayConfig] = []
    private var runningConfigIds: Set<UUID> = []
    private var restoreFailures: [VirtualDisplayRestoreFailure] = []
    private var activeDisplaysByConfigId: [UUID: CGVirtualDisplay] = [:]
    private var runtimeDisplayIDHintsByConfigId: [UUID: CGDirectDisplayID] = [:]
    private var runtimeGenerationByConfigId: [UUID: UInt64] = [:]
    private var terminationWaitersByConfigId: [UUID: TerminationWaiter] = [:]
    private var offlineWaitersByToken: [UUID: OfflineWaiter] = [:]
    private var nextRuntimeGeneration: UInt64 = 1
    private let displayReconfigurationMonitor: any DisplayReconfigurationMonitoring
    private let topologyInspector: any DisplayTopologyInspecting
    private let topologyRepairer: any DisplayTopologyRepairing
    private let managedDisplayOnlineChecker: (UInt32) -> Bool
    private let topologyStabilityTimeout: TimeInterval
    private let topologyStabilityPollInterval: TimeInterval
#if DEBUG
    private let rebuildRuntimeDisplayHook: (@MainActor (VirtualDisplayConfig, Bool) async throws -> Void)?
#endif
    private var isReconfigurationMonitorAvailable = false
    private var didLogOfflinePollingFallback = false

    convenience init(persistenceService: VirtualDisplayPersistenceService? = nil) {
        self.init(
            persistenceService: persistenceService,
            displayReconfigurationMonitor: DisplayReconfigurationMonitor(),
            managedDisplayOnlineChecker: { serialNum in
                Self.systemManagedDisplayOnline(serialNum: serialNum)
            },
            topologyStabilityTimeout: 3.0,
            topologyStabilityPollInterval: 0.3
        )
    }

    convenience init(
        persistenceService: VirtualDisplayPersistenceService? = nil,
        displayReconfigurationMonitor: any DisplayReconfigurationMonitoring,
        managedDisplayOnlineChecker: @escaping (UInt32) -> Bool,
        topologyStabilityTimeout: TimeInterval = 3.0,
        topologyStabilityPollInterval: TimeInterval = 0.3
    ) {
        self.init(
            persistenceService: persistenceService,
            displayReconfigurationMonitor: displayReconfigurationMonitor,
            topologyInspector: SystemDisplayTopologyInspector(),
            topologyRepairer: SystemDisplayTopologyRepairer(),
            managedDisplayOnlineChecker: managedDisplayOnlineChecker,
            topologyStabilityTimeout: topologyStabilityTimeout,
            topologyStabilityPollInterval: topologyStabilityPollInterval,
            rebuildRuntimeDisplayHook: nil
        )
    }

    init(
        persistenceService: VirtualDisplayPersistenceService? = nil,
        displayReconfigurationMonitor: any DisplayReconfigurationMonitoring,
        topologyInspector: any DisplayTopologyInspecting,
        topologyRepairer: any DisplayTopologyRepairing,
        managedDisplayOnlineChecker: @escaping (UInt32) -> Bool,
        topologyStabilityTimeout: TimeInterval,
        topologyStabilityPollInterval: TimeInterval,
        rebuildRuntimeDisplayHook: (@MainActor (VirtualDisplayConfig, Bool) async throws -> Void)? = nil
    ) {
        self.persistenceService = persistenceService ?? VirtualDisplayPersistenceService()
        self.displayReconfigurationMonitor = displayReconfigurationMonitor
        self.topologyInspector = topologyInspector
        self.topologyRepairer = topologyRepairer
        self.managedDisplayOnlineChecker = managedDisplayOnlineChecker
        self.topologyStabilityTimeout = topologyStabilityTimeout
        self.topologyStabilityPollInterval = topologyStabilityPollInterval
#if DEBUG
        self.rebuildRuntimeDisplayHook = rebuildRuntimeDisplayHook
#else
        _ = rebuildRuntimeDisplayHook
#endif
        isReconfigurationMonitorAvailable = displayReconfigurationMonitor.start { [weak self] in
            self?.completeOfflineWaitersIfPossible()
        }
        if !isReconfigurationMonitorAvailable {
            AppLog.virtualDisplay.error(
                "Failed to register display reconfiguration callback. Offline wait will use polling fallback."
            )
        }
    }

    var currentDisplays: [CGVirtualDisplay] {
        displays
    }

    var currentDisplayConfigs: [VirtualDisplayConfig] {
        displayConfigs
    }

    var currentRunningConfigIds: Set<UUID> {
        runningConfigIds
    }

    var currentRestoreFailures: [VirtualDisplayRestoreFailure] {
        restoreFailures
    }

    func loadPersistedConfigs() {
        displayConfigs = persistenceService.loadConfigs()
    }

    func restoreDesiredVirtualDisplays() {
        restoreFailures = persistenceService.restoreDesiredVirtualDisplays(from: displayConfigs) { [weak self] config in
            guard let self else { return }
            _ = try self.createRuntimeDisplay(from: config)
        }
    }

    func clearRestoreFailures() {
        restoreFailures = []
    }

    @discardableResult
    func resetAllVirtualDisplayData() -> Int {
        let removedConfigCount = displayConfigs.count

        cancelAllTerminationWaiters()
        cancelAllOfflineWaiters()
        activeDisplaysByConfigId.removeAll()
        runtimeDisplayIDHintsByConfigId.removeAll()
        runtimeGenerationByConfigId.removeAll()
        runningConfigIds.removeAll()
        displays.removeAll()
        restoreFailures.removeAll()
        displayConfigs.removeAll()
        persistenceService.resetConfigs()

        return removedConfigCount
    }

    func runtimeDisplay(for configId: UUID) -> CGVirtualDisplay? {
        activeDisplaysByConfigId[configId]
    }

    func runtimeDisplayID(for configId: UUID) -> CGDirectDisplayID? {
        if let runtime = activeDisplaysByConfigId[configId] {
            return runtime.displayID
        }
        return runtimeDisplayIDHintsByConfigId[configId]
    }

    func isVirtualDisplayRunning(configId: UUID) -> Bool {
        runningConfigIds.contains(configId)
    }

    @discardableResult
    func createDisplay(
        name: String,
        serialNum: UInt32,
        physicalSize: CGSize,
        maxPixels: (width: UInt32, height: UInt32),
        modes: [ResolutionSelection]
    ) throws -> CGVirtualDisplay {
        if displays.contains(where: { $0.serialNum == serialNum }) ||
            displayConfigs.contains(where: { $0.serialNum == serialNum }) {
            throw VirtualDisplayError.duplicateSerialNumber(serialNum)
        }

        guard !modes.isEmpty else {
            throw VirtualDisplayError.invalidConfiguration(String(localized: "At least one resolution mode is required."))
        }

        let config = VirtualDisplayConfig(
            name: name,
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

        displayConfigs.append(config)
        persistConfigs()

        do {
            let display = try createRuntimeDisplay(from: config, maxPixels: maxPixels)
            return display
        } catch {
            displayConfigs.removeAll { $0.id == config.id }
            persistConfigs()
            AppLog.virtualDisplay.error(
                "Create display failed (name: \(name, privacy: .public), serial: \(serialNum, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    @discardableResult
    func createDisplayFromConfig(_ config: VirtualDisplayConfig) throws -> CGVirtualDisplay {
        try createRuntimeDisplay(from: config)
    }

    func disableDisplay(_ display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        if let index = displayConfigs.firstIndex(where: { $0.serialNum == display.serialNum }) {
            var updated = displayConfigs[index]
            updated.desiredEnabled = false
            displayConfigs[index] = updated
        } else {
            var config = VirtualDisplayConfig(from: display, modes: modes)
            config.desiredEnabled = false
            displayConfigs.append(config)
        }

        displays.removeAll { $0.serialNum == display.serialNum }
        for (configId, activeDisplay) in activeDisplaysByConfigId where activeDisplay.serialNum == display.serialNum {
            cancelTerminationWaiter(configId: configId)
            activeDisplaysByConfigId[configId] = nil
            runtimeDisplayIDHintsByConfigId[configId] = nil
            // Keep generation until termination callback (or timeout) so re-enable can wait safely.
            runningConfigIds.remove(configId)
        }
        persistConfigs()
    }

    func disableDisplayByConfig(_ configId: UUID) throws {
        guard let index = displayConfigs.firstIndex(where: { $0.id == configId }) else { return }

        var updated = displayConfigs[index]
        updated.desiredEnabled = false
        displayConfigs[index] = updated

        let runtimeSerialNum = activeDisplaysByConfigId[configId]?.serialNum ?? displayConfigs[index].serialNum
        cancelTerminationWaiter(configId: configId)
        activeDisplaysByConfigId[configId] = nil
        runtimeDisplayIDHintsByConfigId[configId] = nil
        // Keep generation until termination callback (or timeout) so re-enable can wait safely.
        runningConfigIds.remove(configId)
        displays.removeAll { $0.serialNum == runtimeSerialNum }
        persistConfigs()
    }

    func enableDisplay(_ configId: UUID) async throws {
        guard let index = displayConfigs.firstIndex(where: { $0.id == configId }) else {
            throw VirtualDisplayError.configNotFound
        }

        var updated = displayConfigs[index]
        updated.desiredEnabled = true
        displayConfigs[index] = updated
        persistConfigs()

        let config = displayConfigs[index]
        let enableStart = DispatchTime.now().uptimeNanoseconds
        let preferredMainDisplayID = preferredManagedMainDisplayIDForEnable()

        var terminationConfirmed = true
        var offlineVerified = false
        if activeDisplaysByConfigId[configId] == nil,
           let pendingGeneration = runtimeGenerationByConfigId[configId] {
            let precheckOnline = isManagedDisplayOnline(serialNum: config.serialNum)
            if !precheckOnline {
                terminationConfirmed = true
                offlineVerified = true
            } else {
                let settlement = await waitForTeardownSettlement(
                    configId: configId,
                    expectedGeneration: pendingGeneration,
                    serialNum: config.serialNum,
                    terminationTimeout: 0.3,
                    offlineTimeout: 2.5
                )

                if !settlement.terminationObserved {
                    AppLog.virtualDisplay.debug(
                        "Enable did not observe termination callback before settling on offline confirmation (config: \(config.id.uuidString, privacy: .public))."
                    )
                }
                if !settlement.offlineConfirmed {
                    AppLog.virtualDisplay.error(
                        "Enable aborted because previous display with same serial is still online after teardown settlement (serial: \(config.serialNum, privacy: .public), config: \(config.id.uuidString, privacy: .public), generation: \(pendingGeneration, privacy: .public))."
                    )
                    throw VirtualDisplayError.teardownTimedOut
                }
                terminationConfirmed = true
                offlineVerified = true
            }
        }
        if activeDisplaysByConfigId[configId] == nil, !offlineVerified {
            let offlineConfirmed = await waitForManagedDisplayOffline(serialNum: config.serialNum)
            if !offlineConfirmed {
                AppLog.virtualDisplay.error(
                    "Enable aborted because previous display with same serial is still online (serial: \(config.serialNum, privacy: .public), config: \(config.id.uuidString, privacy: .public))."
                )
                throw VirtualDisplayError.teardownTimedOut
            }
            // After explicit offline confirmation, teardown is considered settled even if callback was missed.
            terminationConfirmed = true
            offlineVerified = true
        }

        do {
            let createdDisplay = try await createRuntimeDisplayWithRetries(
                from: config,
                terminationConfirmed: terminationConfirmed
            )
            do {
                try await ensureHealthyTopologyAfterEnable(preferredMainDisplayID: preferredMainDisplayID)
            } catch {
                rollbackEnableRuntimeState(configId: configId, serialNum: createdDisplay.serialNum)
                let offlineConfirmed = await waitForManagedDisplayOffline(
                    serialNum: config.serialNum,
                    timeout: Self.rollbackOfflineWaitTimeout
                )
                if !offlineConfirmed {
                    AppLog.virtualDisplay.warning(
                        "Enable rollback did not observe offline state before timeout (serial: \(config.serialNum, privacy: .public), config: \(config.id.uuidString, privacy: .public), timeoutSec: \(Self.rollbackOfflineWaitTimeout, privacy: .public))."
                    )
                }
                throw error
            }
        } catch {
            AppLog.virtualDisplay.error(
                "Enable display failed (name: \(config.name, privacy: .public), serial: \(config.serialNum, privacy: .public), totalElapsedMs: \(self.elapsedMilliseconds(since: enableStart), privacy: .public)): \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    func destroyDisplay(_ configId: UUID) {
        guard let config = displayConfigs.first(where: { $0.id == configId }) else { return }

        let runtimeSerialNum = activeDisplaysByConfigId[configId]?.serialNum ?? config.serialNum
        cancelTerminationWaiter(configId: configId)
        activeDisplaysByConfigId[configId] = nil
        runtimeDisplayIDHintsByConfigId[configId] = nil
        runtimeGenerationByConfigId[configId] = nil
        runningConfigIds.remove(configId)
        displays.removeAll { $0.serialNum == runtimeSerialNum }

        displayConfigs.removeAll { $0.id == configId }
        persistConfigs()
    }

    func destroyDisplay(_ display: CGVirtualDisplay) {
        let serialNum = display.serialNum

        displays.removeAll { $0.serialNum == serialNum }
        for (configId, activeDisplay) in activeDisplaysByConfigId where activeDisplay.serialNum == serialNum {
            cancelTerminationWaiter(configId: configId)
            activeDisplaysByConfigId[configId] = nil
            runtimeDisplayIDHintsByConfigId[configId] = nil
            runtimeGenerationByConfigId[configId] = nil
            runningConfigIds.remove(configId)
        }

        displayConfigs.removeAll { $0.serialNum == serialNum }
        persistConfigs()
    }

    func getConfig(_ configId: UUID) -> VirtualDisplayConfig? {
        displayConfigs.first { $0.id == configId }
    }

    func updateConfig(_ updated: VirtualDisplayConfig) {
        guard let index = displayConfigs.firstIndex(where: { $0.id == updated.id }) else { return }
        displayConfigs[index] = updated
        persistConfigs()
    }

    @discardableResult
    func moveConfig(_ configId: UUID, direction: ReorderDirection) -> Bool {
        guard let sourceIndex = displayConfigs.firstIndex(where: { $0.id == configId }) else { return false }

        let destinationIndex: Int
        switch direction {
        case .up:
            destinationIndex = sourceIndex - 1
        case .down:
            destinationIndex = sourceIndex + 1
        }

        guard displayConfigs.indices.contains(destinationIndex) else { return false }

        displayConfigs.swapAt(sourceIndex, destinationIndex)
        persistConfigs()
        return true
    }

    func applyModes(configId: UUID, modes: [ResolutionSelection]) {
        guard let display = activeDisplaysByConfigId[configId] else { return }
        let settings = CGVirtualDisplaySettings()

        let anyHiDPI = modes.contains { $0.enableHiDPI }
        settings.hiDPI = anyHiDPI ? 1 : 0

        var displayModes: [CGVirtualDisplayMode] = []
        for mode in modes {
            if mode.enableHiDPI {
                displayModes.append(mode.hiDPIVersion().toVirtualDisplayMode())
            }
            displayModes.append(mode.toVirtualDisplayMode())
        }
        settings.modes = displayModes
        let applied = display.apply(settings)
        if !applied {
            AppLog.virtualDisplay.error("Apply virtual display modes failed (serial: \(display.serialNum, privacy: .public)).")
        }
    }

    func rebuildVirtualDisplay(configId: UUID) async throws {
        guard let config = displayConfigs.first(where: { $0.id == configId }) else {
            throw VirtualDisplayError.configNotFound
        }
        let snapshotBeforeRebuild = currentTopologySnapshot()
        let preferredMainDisplayID = preferredManagedMainDisplayIDForEnable()
        let targetRuntimeDisplayID = runtimeDisplayID(for: configId)
        let targetWasManagedMain = managedDisplayID(
            for: config.serialNum,
            snapshot: snapshotBeforeRebuild
        ) == snapshotBeforeRebuild?.mainDisplayID || targetRuntimeDisplayID == CGMainDisplayID()
        let useCoordinatedRebuild = shouldUseCoordinatedRebuild(
            configId: configId,
            config: config,
            snapshot: snapshotBeforeRebuild
        )
        AppLog.virtualDisplay.debug(
            "Rebuild strategy resolved (config: \(configId.uuidString, privacy: .public), coordinated: \(useCoordinatedRebuild, privacy: .public), runtimeMainMatch: \(targetRuntimeDisplayID == CGMainDisplayID(), privacy: .public), snapshotAvailable: \(snapshotBeforeRebuild != nil, privacy: .public))."
        )
        if useCoordinatedRebuild {
            try await rebuildManagedDisplayFleet(
                prioritizing: configId,
                fallbackPreferredMainDisplayID: preferredMainDisplayID
            )
            return
        }

        let runtimeSerialNum = activeDisplaysByConfigId[configId]?.serialNum ?? config.serialNum
        let generationToWaitFor = runningConfigIds.contains(configId)
            ? runtimeGenerationByConfigId[configId]
            : nil
        if runningConfigIds.contains(configId) {
            activeDisplaysByConfigId[configId] = nil
            runtimeDisplayIDHintsByConfigId[configId] = nil
            runningConfigIds.remove(configId)
            displays.removeAll { $0.serialNum == runtimeSerialNum }
        }

        let terminationConfirmed = try await settleRebuildTeardown(
            configId: config.id,
            serialNum: config.serialNum,
            generationToWaitFor: generationToWaitFor
        )

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
        try await ensureHealthyTopologyAfterEnable(preferredMainDisplayID: preferredMainAfterRebuild)
    }

    func getConfig(for display: CGVirtualDisplay) -> VirtualDisplayConfig? {
        displayConfigs.first { $0.serialNum == display.serialNum }
    }

    func updateConfig(for display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        guard let index = displayConfigs.firstIndex(where: { $0.serialNum == display.serialNum }) else { return }
        var updated = displayConfigs[index]
        updated.modes = modes.map {
            VirtualDisplayConfig.ModeConfig(
                width: $0.width,
                height: $0.height,
                refreshRate: $0.refreshRate,
                enableHiDPI: $0.enableHiDPI
            )
        }
        displayConfigs[index] = updated
        persistConfigs()
    }

    func nextAvailableSerialNumber() -> UInt32 {
        let activeNumbers = Set(displays.map { $0.serialNum })
        let configNumbers = Set(displayConfigs.map { $0.serialNum })
        let usedNumbers = activeNumbers.union(configNumbers)

        var next: UInt32 = 1
        while usedNumbers.contains(next) {
            next += 1
        }
        return next
    }

    private func shouldUseCoordinatedRebuild(
        configId: UUID,
        config: VirtualDisplayConfig,
        snapshot: DisplayTopologySnapshot?
    ) -> Bool {
        guard runningConfigIds.contains(configId),
              runningConfigIds.count >= 2 else {
            return false
        }
        if let runtimeDisplayID = runtimeDisplayID(for: configId),
           runtimeDisplayID == CGMainDisplayID() {
            return true
        }
        guard let snapshot else {
            return false
        }
        let managedOnlineCount = snapshot.displays.filter(\.isManagedVirtualDisplay).count
        guard managedOnlineCount >= 2,
              let targetDisplayID = managedDisplayID(for: config.serialNum, snapshot: snapshot) else {
            return false
        }
        return snapshot.mainDisplayID == targetDisplayID
    }

    private func orderedRunningConfigIDs(prioritizing configId: UUID) -> [UUID] {
        var ordered = displayConfigs
            .map(\.id)
            .filter { runningConfigIds.contains($0) }
        if let index = ordered.firstIndex(of: configId) {
            ordered.remove(at: index)
            ordered.insert(configId, at: 0)
        } else if runningConfigIds.contains(configId) {
            ordered.insert(configId, at: 0)
        }
        return ordered
    }

    private func rebuildManagedDisplayFleet(
        prioritizing prioritizedConfigID: UUID,
        fallbackPreferredMainDisplayID: CGDirectDisplayID?
    ) async throws {
        let orderedConfigIDs = orderedRunningConfigIDs(prioritizing: prioritizedConfigID)
        guard !orderedConfigIDs.isEmpty else {
            throw VirtualDisplayError.configNotFound
        }

        var terminationConfirmedByConfigID: [UUID: Bool] = [:]
        var rebuiltSerials: [UInt32] = []
        for runningConfigID in orderedConfigIDs {
            guard let runningConfig = displayConfigs.first(where: { $0.id == runningConfigID }) else { continue }
            rebuiltSerials.append(runningConfig.serialNum)

            let runtimeSerialNum = activeDisplaysByConfigId[runningConfigID]?.serialNum ?? runningConfig.serialNum
            let generationToWaitFor = runtimeGenerationByConfigId[runningConfigID]

            activeDisplaysByConfigId[runningConfigID] = nil
            runtimeDisplayIDHintsByConfigId[runningConfigID] = nil
            runningConfigIds.remove(runningConfigID)
            displays.removeAll { $0.serialNum == runtimeSerialNum }

            let terminationConfirmed = try await settleRebuildTeardown(
                configId: runningConfigID,
                serialNum: runningConfig.serialNum,
                generationToWaitFor: generationToWaitFor
            )
            terminationConfirmedByConfigID[runningConfigID] = terminationConfirmed
        }
        let fleetOfflineConfirmed = await waitForManagedDisplaysOffline(
            serialNumbers: rebuiltSerials,
            timeout: Self.rebuildFinalOfflineConfirmationTimeout
        )
        if !fleetOfflineConfirmed {
            AppLog.virtualDisplay.error(
                "Coordinated rebuild aborted because at least one managed display remained online after fleet teardown (configs: \(orderedConfigIDs.map(\.uuidString).joined(separator: ","), privacy: .public))."
            )
            throw VirtualDisplayError.teardownTimedOut
        }
        if Self.rebuildFleetCreationCooldown > 0 {
            await sleepForRetry(seconds: Self.rebuildFleetCreationCooldown)
        }

        var recreatedPreferredMainDisplayID: CGDirectDisplayID?
        for runningConfigID in orderedConfigIDs {
            guard let runningConfig = displayConfigs.first(where: { $0.id == runningConfigID }) else { continue }
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

    private func settleRebuildTeardown(
        configId: UUID,
        serialNum: UInt32,
        generationToWaitFor: UInt64?
    ) async throws -> Bool {
        var terminationConfirmed = true
        if let generationToWaitFor {
            let settlement = await waitForTeardownSettlement(
                configId: configId,
                expectedGeneration: generationToWaitFor,
                serialNum: serialNum,
                terminationTimeout: Self.rebuildTerminationTimeout,
                offlineTimeout: Self.rebuildOfflineTimeout
            )
            if !settlement.terminationObserved {
                AppLog.virtualDisplay.debug(
                    "Virtual display teardown termination callback not observed before timeout (config: \(configId.uuidString, privacy: .public), generation: \(generationToWaitFor, privacy: .public)). Continue rebuild with extended retries after offline confirmation."
                )
            }
            if !settlement.offlineConfirmed {
                AppLog.virtualDisplay.error(
                    "Rebuild aborted because previous display with same serial is still online after teardown settlement (serial: \(serialNum, privacy: .public), generation: \(generationToWaitFor, privacy: .public), config: \(configId.uuidString, privacy: .public))."
                )
                throw VirtualDisplayError.teardownTimedOut
            }
            terminationConfirmed = settlement.terminationObserved
        }

        let finalOfflineConfirmed = await waitForManagedDisplayOffline(
            serialNum: serialNum,
            timeout: Self.rebuildFinalOfflineConfirmationTimeout
        )
        if !finalOfflineConfirmed {
            AppLog.virtualDisplay.error(
                "Rebuild aborted because previous display with same serial is still online during final offline confirmation (serial: \(serialNum, privacy: .public), config: \(configId.uuidString, privacy: .public))."
            )
            throw VirtualDisplayError.teardownTimedOut
        }
        return terminationConfirmed
    }

    private func waitForManagedDisplaysOffline(
        serialNumbers: [UInt32],
        timeout: TimeInterval
    ) async -> Bool {
        for serial in Set(serialNumbers).sorted() {
            let offline = await waitForManagedDisplayOffline(
                serialNum: serial,
                timeout: timeout
            )
            if !offline {
                return false
            }
        }
        return true
    }

    private func recreateRuntimeDisplayForRebuild(
        config: VirtualDisplayConfig,
        terminationConfirmed: Bool
    ) async throws -> CGDirectDisplayID? {
#if DEBUG
        if let rebuildRuntimeDisplayHook {
            try await rebuildRuntimeDisplayHook(config, terminationConfirmed)
            return runtimeDisplayID(for: config.id)
        }
#endif
        let rebuiltDisplay = try await createRuntimeDisplayWithRetries(
            from: config,
            terminationConfirmed: terminationConfirmed
        )
        return rebuiltDisplay.displayID
    }

    private func managedDisplayID(
        for serialNum: UInt32,
        snapshot: DisplayTopologySnapshot?
    ) -> CGDirectDisplayID? {
        guard let snapshot else { return nil }
        if let activeManagedDisplay = snapshot.displays.first(where: {
            $0.isManagedVirtualDisplay &&
                $0.serialNumber == serialNum &&
                $0.isActive &&
                $0.bounds.width > 1 &&
                $0.bounds.height > 1
        }) {
            return activeManagedDisplay.id
        }
        return snapshot.displays.first(where: {
            $0.isManagedVirtualDisplay &&
                $0.serialNumber == serialNum
        })?.id
    }

    private struct TopologyHealthEvaluation {
        enum Issue {
            case managedDisplaysCollapsedIntoSingleMirrorSet
            case managedDisplaysOverlappingInExtendedSpace
            case mainDisplayOutsideManagedSetWithoutPhysicalFallback
        }

        let issue: Issue?
        let managedDisplayIDs: [CGDirectDisplayID]
        let forceNormalization: Bool

        var needsRepair: Bool { issue != nil }
    }

    private func ensureHealthyTopologyAfterEnable(
        preferredMainDisplayID: CGDirectDisplayID? = nil
    ) async throws {
        guard let stableSnapshot = await waitForStableTopology() else {
            throw VirtualDisplayError.topologyUnstableAfterEnable
        }

        let evaluation = evaluateTopologyHealth(stableSnapshot)
        let shouldRepair = evaluation.needsRepair || evaluation.forceNormalization
        guard shouldRepair else { return }
        let repairAnchorDisplayID = selectRepairAnchorDisplayID(
            snapshot: stableSnapshot,
            managedDisplayIDs: evaluation.managedDisplayIDs,
            preferredMainDisplayID: preferredMainDisplayID
        )

        let repaired = topologyRepairer.repair(
            snapshot: stableSnapshot,
            managedDisplayIDs: evaluation.managedDisplayIDs,
            anchorDisplayID: repairAnchorDisplayID
        )
        guard repaired else {
            throw VirtualDisplayError.topologyRepairFailed
        }

        guard let stabilizedAfterRepair = await waitForStableTopology() else {
            throw VirtualDisplayError.topologyUnstableAfterEnable
        }

        let postRepairEvaluation = evaluateTopologyHealth(stabilizedAfterRepair)
        guard !postRepairEvaluation.needsRepair else {
            throw VirtualDisplayError.topologyRepairFailed
        }

        if evaluation.forceNormalization {
            let normalizationAnchorDisplayID = selectRepairAnchorDisplayID(
                snapshot: stabilizedAfterRepair,
                managedDisplayIDs: postRepairEvaluation.managedDisplayIDs,
                preferredMainDisplayID: preferredMainDisplayID
            )
            let normalized = topologyRepairer.repair(
                snapshot: stabilizedAfterRepair,
                managedDisplayIDs: postRepairEvaluation.managedDisplayIDs,
                anchorDisplayID: normalizationAnchorDisplayID
            )
            guard normalized else {
                throw VirtualDisplayError.topologyRepairFailed
            }
            guard let stabilizedAfterNormalization = await waitForStableTopology() else {
                throw VirtualDisplayError.topologyUnstableAfterEnable
            }
            let postNormalizationEvaluation = evaluateTopologyHealth(stabilizedAfterNormalization)
            guard !postNormalizationEvaluation.needsRepair else {
                throw VirtualDisplayError.topologyRepairFailed
            }
            if let continuityMainDisplayID = preferredMainDisplayID,
               shouldEnforceMainContinuity(
                   preferredMainDisplayID: continuityMainDisplayID,
                   snapshot: stabilizedAfterNormalization,
                   managedDisplayIDs: postNormalizationEvaluation.managedDisplayIDs
               ) {
                let continuityRepaired = topologyRepairer.repair(
                    snapshot: stabilizedAfterNormalization,
                    managedDisplayIDs: postNormalizationEvaluation.managedDisplayIDs,
                    anchorDisplayID: continuityMainDisplayID
                )
                guard continuityRepaired else {
                    throw VirtualDisplayError.topologyRepairFailed
                }
                guard let stabilizedAfterContinuity = await waitForStableTopology() else {
                    throw VirtualDisplayError.topologyUnstableAfterEnable
                }
                _ = stabilizedAfterContinuity
            }
            return
        }
    }

    private func waitForStableTopology() async -> DisplayTopologySnapshot? {
        let deadline = Date().addingTimeInterval(topologyStabilityTimeout)
        var previousSnapshot: DisplayTopologySnapshot?
        var stableSampleCount = 0
        let requiredStableSamples = 3

        while Date() < deadline {
            guard let currentSnapshot = currentTopologySnapshot() else {
                stableSampleCount = 0
                await sleepForRetry(seconds: topologyStabilityPollInterval)
                continue
            }

            if previousSnapshot == currentSnapshot {
                stableSampleCount += 1
            } else {
                previousSnapshot = currentSnapshot
                stableSampleCount = 1
            }

            if stableSampleCount >= requiredStableSamples {
                return currentSnapshot
            }
            await sleepForRetry(seconds: topologyStabilityPollInterval)
        }

        return nil
    }

    private func rollbackEnableRuntimeState(configId: UUID, serialNum: UInt32) {
        activeDisplaysByConfigId[configId] = nil
        runtimeDisplayIDHintsByConfigId[configId] = nil
        runningConfigIds.remove(configId)
        displays.removeAll { $0.serialNum == serialNum }
        // Keep runtime generation until termination callback/offline check settles.
    }

    private func evaluateTopologyHealth(_ snapshot: DisplayTopologySnapshot) -> TopologyHealthEvaluation {
        let desiredManagedSerials = Set(displayConfigs.filter(\.desiredEnabled).map(\.serialNum))
        let managedDisplays = snapshot.displays.filter(\.isManagedVirtualDisplay)
        // Repair targets intentionally include all online managed displays so no managed display
        // remains in a stale mirror relationship after topology recovery.
        let managedDisplayIDs = managedDisplays.map(\.id).sorted()
        let desiredManagedDisplays = managedDisplays.filter { desiredManagedSerials.contains($0.serialNumber) }
        let desiredManagedDisplayIDs = desiredManagedDisplays.map(\.id)
        let hasPhysicalDisplay = snapshot.displays.contains {
            !$0.isManagedVirtualDisplay &&
                $0.isActive &&
                $0.bounds.width > 1 &&
                $0.bounds.height > 1
        }
        // In pure virtual-only topology, proactively normalize layout after enable because
        // macOS can occasionally present mirrored content without reliable mirror flags.
        let forceNormalization = !hasPhysicalDisplay &&
            desiredManagedSerials.count >= 2 &&
            desiredManagedDisplayIDs.count >= 2

        if desiredManagedSerials.count >= 2 &&
            desiredManagedDisplayIDs.count >= 2 &&
            areManagedDisplaysCollapsedIntoSingleMirrorSet(
                snapshot: snapshot,
                managedDisplayIDs: desiredManagedDisplayIDs
            ) {
            return TopologyHealthEvaluation(
                issue: .managedDisplaysCollapsedIntoSingleMirrorSet,
                managedDisplayIDs: managedDisplayIDs,
                forceNormalization: forceNormalization
            )
        }

        if desiredManagedSerials.count >= 2 &&
            desiredManagedDisplays.count >= 2 &&
            areManagedDisplaysOverlappingInExtendedSpace(desiredManagedDisplays) {
            return TopologyHealthEvaluation(
                issue: .managedDisplaysOverlappingInExtendedSpace,
                managedDisplayIDs: managedDisplayIDs,
                forceNormalization: forceNormalization
            )
        }

        let mainInManagedSet = managedDisplayIDs.contains(snapshot.mainDisplayID)
        if !hasPhysicalDisplay && !mainInManagedSet {
            return TopologyHealthEvaluation(
                issue: .mainDisplayOutsideManagedSetWithoutPhysicalFallback,
                managedDisplayIDs: managedDisplayIDs,
                forceNormalization: forceNormalization
            )
        }

        return TopologyHealthEvaluation(
            issue: nil,
            managedDisplayIDs: managedDisplayIDs,
            forceNormalization: forceNormalization
        )
    }

    private func areManagedDisplaysCollapsedIntoSingleMirrorSet(
        snapshot: DisplayTopologySnapshot,
        managedDisplayIDs: [CGDirectDisplayID]
    ) -> Bool {
        let uniqueManagedIDs = Array(Set(managedDisplayIDs))
        guard uniqueManagedIDs.count >= 2 else { return false }
        let allInMirrorSet = uniqueManagedIDs.allSatisfy { id in
            snapshot.display(for: id)?.isInMirrorSet == true
        }
        guard allInMirrorSet else { return false }

        let roots = Set(uniqueManagedIDs.map { mirrorRoot(for: $0, snapshot: snapshot) })
        return roots.count == 1
    }

    private func areManagedDisplaysOverlappingInExtendedSpace(
        _ managedDisplays: [DisplayTopologySnapshot.DisplayInfo]
    ) -> Bool {
        guard managedDisplays.count >= 2 else { return false }
        var signatures: Set<String> = []
        for display in managedDisplays {
            let bounds = display.bounds
            let signature = [
                Int(bounds.origin.x.rounded()),
                Int(bounds.origin.y.rounded()),
                Int(bounds.width.rounded()),
                Int(bounds.height.rounded())
            ]
                .map(String.init)
                .joined(separator: ":")
            if !signatures.insert(signature).inserted {
                return true
            }
        }
        return false
    }

    private func mirrorRoot(
        for displayID: CGDirectDisplayID,
        snapshot: DisplayTopologySnapshot
    ) -> CGDirectDisplayID {
        var current = displayID
        var visited: Set<CGDirectDisplayID> = []

        while let display = snapshot.display(for: current),
              let mirrorMaster = display.mirrorMasterDisplayID,
              mirrorMaster != current,
              !visited.contains(current) {
            visited.insert(current)
            current = mirrorMaster
        }

        return current
    }

    private func selectRepairAnchorDisplayID(
        snapshot: DisplayTopologySnapshot,
        managedDisplayIDs: [CGDirectDisplayID],
        preferredMainDisplayID: CGDirectDisplayID? = nil
    ) -> CGDirectDisplayID {
        let uniqueManagedDisplayIDs = Array(Set(managedDisplayIDs)).sorted()
        guard !uniqueManagedDisplayIDs.isEmpty else {
            return snapshot.mainDisplayID
        }
        if let preferredMainDisplayID,
           uniqueManagedDisplayIDs.contains(preferredMainDisplayID),
           let preferredMain = snapshot.display(for: preferredMainDisplayID),
           preferredMain.isActive,
           preferredMain.bounds.width > 1,
           preferredMain.bounds.height > 1 {
            return preferredMainDisplayID
        }
        if uniqueManagedDisplayIDs.contains(snapshot.mainDisplayID),
           let main = snapshot.display(for: snapshot.mainDisplayID),
           main.isActive,
           main.bounds.width > 1,
           main.bounds.height > 1 {
            return snapshot.mainDisplayID
        }

        let orderedCandidates = uniqueManagedDisplayIDs.sorted { lhs, rhs in
            let lhsBounds = snapshot.display(for: lhs)?.bounds ?? .zero
            let rhsBounds = snapshot.display(for: rhs)?.bounds ?? .zero
            if lhsBounds.origin.x != rhsBounds.origin.x {
                return lhsBounds.origin.x < rhsBounds.origin.x
            }
            if lhsBounds.origin.y != rhsBounds.origin.y {
                return lhsBounds.origin.y < rhsBounds.origin.y
            }
            return lhs < rhs
        }
        return orderedCandidates.first ?? uniqueManagedDisplayIDs[0]
    }

    private func preferredManagedMainDisplayIDForEnable() -> CGDirectDisplayID? {
        guard let snapshot = currentTopologySnapshot(),
              let mainDisplay = snapshot.display(for: snapshot.mainDisplayID),
              mainDisplay.isManagedVirtualDisplay,
              mainDisplay.isActive,
              mainDisplay.bounds.width > 1,
              mainDisplay.bounds.height > 1 else {
            return nil
        }
        return snapshot.mainDisplayID
    }

    private func shouldEnforceMainContinuity(
        preferredMainDisplayID: CGDirectDisplayID,
        snapshot: DisplayTopologySnapshot,
        managedDisplayIDs: [CGDirectDisplayID]
    ) -> Bool {
        guard snapshot.mainDisplayID != preferredMainDisplayID else { return false }
        guard managedDisplayIDs.contains(preferredMainDisplayID) else { return false }
        guard let preferredMain = snapshot.display(for: preferredMainDisplayID),
              preferredMain.isActive,
              preferredMain.bounds.width > 1,
              preferredMain.bounds.height > 1 else {
            return false
        }
        let hasPhysicalDisplay = snapshot.displays.contains {
            !$0.isManagedVirtualDisplay &&
                $0.isActive &&
                $0.bounds.width > 1 &&
                $0.bounds.height > 1
        }
        return !hasPhysicalDisplay
    }

    private func currentTopologySnapshot() -> DisplayTopologySnapshot? {
        topologyInspector.snapshot(
            trackedManagedSerials: trackedManagedSerials(),
            managedVendorID: Self.managedVendorID,
            managedProductID: Self.managedProductID
        )
    }

    private func trackedManagedSerials() -> Set<UInt32> {
        Set(displayConfigs.map(\.serialNum))
            .union(Set(activeDisplaysByConfigId.values.map(\.serialNum)))
    }

    private func persistConfigs() {
        persistenceService.saveConfigs(displayConfigs)
    }

    @discardableResult
    private func createRuntimeDisplay(from config: VirtualDisplayConfig, maxPixels: (width: UInt32, height: UInt32)? = nil) throws -> CGVirtualDisplay {
        if let existing = activeDisplaysByConfigId[config.id] {
            runtimeDisplayIDHintsByConfigId[config.id] = existing.displayID
            return existing
        }

        if displays.contains(where: { $0.serialNum == config.serialNum }) {
            throw VirtualDisplayError.duplicateSerialNumber(config.serialNum)
        }

        let modes = config.resolutionModes
        guard !modes.isEmpty else {
            throw VirtualDisplayError.invalidConfiguration(String(localized: "At least one resolution mode is required."))
        }

        let generation = allocateRuntimeGeneration()
        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(DispatchQueue.main)
        desc.terminationHandler = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.handleVirtualDisplayTermination(
                    configId: config.id,
                    serialNum: config.serialNum,
                    generation: generation
                )
            }
        }
        desc.name = config.name
        let max = maxPixels ?? config.maxPixelDimensions
        desc.maxPixelsWide = max.width
        desc.maxPixelsHigh = max.height
        desc.sizeInMillimeters = config.physicalSize
        desc.productID = Self.managedProductID
        desc.vendorID = Self.managedVendorID
        desc.serialNum = config.serialNum

        let display = CGVirtualDisplay(descriptor: desc)

        let settings = CGVirtualDisplaySettings()
        let anyHiDPI = modes.contains { $0.enableHiDPI }
        settings.hiDPI = anyHiDPI ? 1 : 0

        var displayModes: [CGVirtualDisplayMode] = []
        for mode in modes {
            if mode.enableHiDPI {
                displayModes.append(mode.hiDPIVersion().toVirtualDisplayMode())
            }
            displayModes.append(mode.toVirtualDisplayMode())
        }

        settings.modes = displayModes
        let applied = display.apply(settings)
        guard applied else {
            AppLog.virtualDisplay.error(
                "Create virtual display apply settings failed (name: \(config.name, privacy: .public), serial: \(config.serialNum, privacy: .public))."
            )
            throw VirtualDisplayError.creationFailed
        }

        activeDisplaysByConfigId[config.id] = display
        runtimeDisplayIDHintsByConfigId[config.id] = display.displayID
        runtimeGenerationByConfigId[config.id] = generation
        runningConfigIds.insert(config.id)
        displays.removeAll { $0.serialNum == config.serialNum }
        displays.append(display)
        return display
    }

    private func handleVirtualDisplayTermination(configId: UUID, serialNum: UInt32, generation: UInt64) {
        guard runtimeGenerationByConfigId[configId] == generation else {
            AppLog.virtualDisplay.debug(
                "Ignore stale virtual display termination (serial: \(serialNum, privacy: .public), generation: \(generation, privacy: .public))."
            )
            return
        }
        AppLog.virtualDisplay.notice("Virtual display terminated (serial: \(serialNum, privacy: .public)).")
        activeDisplaysByConfigId[configId] = nil
        runtimeDisplayIDHintsByConfigId[configId] = nil
        runtimeGenerationByConfigId[configId] = nil
        runningConfigIds.remove(configId)
        displays.removeAll { $0.serialNum == serialNum }
        completeTerminationWaiter(configId: configId, expectedGeneration: generation, result: true)
    }

    private func allocateRuntimeGeneration() -> UInt64 {
        defer { nextRuntimeGeneration &+= 1 }
        return nextRuntimeGeneration
    }

    private func waitForTermination(
        configId: UUID,
        expectedGeneration: UInt64,
        timeout: TimeInterval = 1.5
    ) async -> Bool {
        if runtimeGenerationByConfigId[configId] != expectedGeneration {
            return true
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if runtimeGenerationByConfigId[configId] != expectedGeneration {
                    continuation.resume(returning: true)
                    return
                }

                cancelTerminationWaiter(configId: configId)

                let timeoutNanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    self?.completeTerminationWaiter(
                        configId: configId,
                        expectedGeneration: expectedGeneration,
                        result: false
                    )
                }

                terminationWaitersByConfigId[configId] = TerminationWaiter(
                    expectedGeneration: expectedGeneration,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelTerminationWaiter(
                    configId: configId,
                    expectedGeneration: expectedGeneration
                )
            }
        }
    }

    private func waitForManagedDisplayOffline(
        serialNum: UInt32,
        timeout: TimeInterval = 2.5
    ) async -> Bool {
        if !isManagedDisplayOnline(serialNum: serialNum) {
            return true
        }

        if !isReconfigurationMonitorAvailable {
            if !didLogOfflinePollingFallback {
                AppLog.virtualDisplay.warning(
                    "Display reconfiguration callback unavailable; waiting for offline state via polling fallback."
                )
                didLogOfflinePollingFallback = true
            }
            return await waitForManagedDisplayOfflineByPolling(
                serialNum: serialNum,
                timeout: timeout
            )
        }

        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeoutNanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    self?.completeOfflineWaiterAfterTimeout(token: token)
                }

                offlineWaitersByToken[token] = OfflineWaiter(
                    serialNum: serialNum,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                completeOfflineWaitersIfPossible()
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelOfflineWaiter(token: token)
            }
        }
    }

    private func waitForManagedDisplayOfflineByPolling(
        serialNum: UInt32,
        timeout: TimeInterval,
        interval: TimeInterval = 0.1
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled {
                return false
            }
            if !isManagedDisplayOnline(serialNum: serialNum) {
                return true
            }
            await sleepForRetry(seconds: interval)
        }
        // Final recheck at timeout boundary to avoid false timeout when state changed but no event arrived.
        return !isManagedDisplayOnline(serialNum: serialNum)
    }

    @discardableResult
    private func createRuntimeDisplayWithRetries(
        from config: VirtualDisplayConfig,
        terminationConfirmed: Bool
    ) async throws -> CGVirtualDisplay {
        let maxAttempts = terminationConfirmed ? 3 : 10
        for attempt in 1...maxAttempts {
            do {
                return try createRuntimeDisplay(from: config)
            } catch {
                let shouldRetry: Bool
                if let virtualDisplayError = error as? VirtualDisplayError,
                   case .creationFailed = virtualDisplayError {
                    shouldRetry = true
                } else {
                    shouldRetry = false
                }

                if shouldRetry && attempt < maxAttempts {
                    let delay: TimeInterval
                    if terminationConfirmed {
                        delay = 0.15
                    } else {
                        delay = min(0.2 * Double(attempt), 1.0)
                    }
                    await sleepForRetry(seconds: delay)
                    continue
                }
                if shouldRetry && !terminationConfirmed {
                    throw VirtualDisplayError.teardownTimedOut
                }
                throw error
            }
        }

        throw VirtualDisplayError.creationFailed
    }

    private func completeTerminationWaiter(configId: UUID, expectedGeneration: UInt64, result: Bool) {
        guard let waiter = terminationWaitersByConfigId[configId] else { return }
        guard waiter.expectedGeneration == expectedGeneration else { return }
        terminationWaitersByConfigId[configId] = nil
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: result)
    }

    private func cancelTerminationWaiter(configId: UUID) {
        guard let waiter = terminationWaitersByConfigId.removeValue(forKey: configId) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: false)
    }

    private func cancelTerminationWaiter(configId: UUID, expectedGeneration: UInt64) {
        guard let waiter = terminationWaitersByConfigId[configId] else { return }
        guard waiter.expectedGeneration == expectedGeneration else { return }
        cancelTerminationWaiter(configId: configId)
    }

    private func cancelAllTerminationWaiters() {
        let keys = terminationWaitersByConfigId.keys
        for key in keys {
            cancelTerminationWaiter(configId: key)
        }
    }

    private func completeOfflineWaitersIfPossible() {
        let tokens = offlineWaitersByToken.keys
        for token in tokens {
            guard let waiter = offlineWaitersByToken[token] else { continue }
            if !isManagedDisplayOnline(serialNum: waiter.serialNum) {
                completeOfflineWaiter(token: token, result: true)
            }
        }
    }

    private func completeOfflineWaiter(token: UUID, result: Bool) {
        guard let waiter = offlineWaitersByToken.removeValue(forKey: token) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: result)
    }

    private func completeOfflineWaiterAfterTimeout(token: UUID) {
        guard let waiter = offlineWaitersByToken[token] else { return }
        let isOffline = !isManagedDisplayOnline(serialNum: waiter.serialNum)
        completeOfflineWaiter(token: token, result: isOffline)
    }

    private func cancelOfflineWaiter(token: UUID) {
        completeOfflineWaiter(token: token, result: false)
    }

    private func cancelAllOfflineWaiters() {
        let tokens = offlineWaitersByToken.keys
        for token in tokens {
            completeOfflineWaiter(token: token, result: false)
        }
    }

    private func isManagedDisplayOnline(serialNum: UInt32) -> Bool {
        managedDisplayOnlineChecker(serialNum)
    }

    private static func systemManagedDisplayOnline(serialNum: UInt32) -> Bool {
        systemOnlineDisplayIDs().contains { displayID in
            CGDisplayVendorNumber(displayID) == Self.managedVendorID &&
            CGDisplayModelNumber(displayID) == Self.managedProductID &&
            CGDisplaySerialNumber(displayID) == serialNum
        }
    }

    private static func systemOnlineDisplayIDs() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        let preflight = CGGetOnlineDisplayList(0, nil, &displayCount)
        guard preflight == .success, displayCount > 0 else {
            return []
        }

        var ids = Array(repeating: CGDirectDisplayID(), count: Int(displayCount))
        var resolvedCount: UInt32 = 0
        let status = CGGetOnlineDisplayList(displayCount, &ids, &resolvedCount)
        guard status == .success else {
            return []
        }
        return Array(ids.prefix(Int(resolvedCount)))
    }

    private func sleepForRetry(seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(seconds, 0) * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            // Ignore cancellation and let retry loop exit on next check.
        }
    }

    private func elapsedMilliseconds(since startNanoseconds: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= startNanoseconds ? (now - startNanoseconds) / 1_000_000 : 0
    }

    private func waitForTeardownSettlement(
        configId: UUID,
        expectedGeneration: UInt64,
        serialNum: UInt32,
        terminationTimeout: TimeInterval,
        offlineTimeout: TimeInterval
    ) async -> TeardownSettlement {
        await withTaskGroup(of: TeardownSettlementEvent.self, returning: TeardownSettlement.self) { group in
            group.addTask { [weak self] in
                guard let self else { return .termination(false) }
                return .termination(
                    await self.waitForTermination(
                        configId: configId,
                        expectedGeneration: expectedGeneration,
                        timeout: terminationTimeout
                    )
                )
            }
            group.addTask { [weak self] in
                guard let self else { return .offline(false) }
                return .offline(
                    await self.waitForManagedDisplayOffline(
                        serialNum: serialNum,
                        timeout: offlineTimeout
                    )
                )
            }

            var terminationObserved: Bool?
            var offlineConfirmed: Bool?

            while let event = await group.next() {
                switch event {
                case .termination(let observed):
                    terminationObserved = observed
                    if observed {
                        group.cancelAll()
                        return TeardownSettlement(
                            terminationObserved: true,
                            offlineConfirmed: true
                        )
                    }

                case .offline(let confirmed):
                    offlineConfirmed = confirmed
                    if confirmed {
                        group.cancelAll()
                        return TeardownSettlement(
                            terminationObserved: terminationObserved ?? false,
                            offlineConfirmed: true
                        )
                    }
                }

                if let terminationObserved, let offlineConfirmed {
                    return TeardownSettlement(
                        terminationObserved: terminationObserved,
                        offlineConfirmed: offlineConfirmed
                    )
                }
            }

            return TeardownSettlement(
                terminationObserved: terminationObserved ?? false,
                offlineConfirmed: offlineConfirmed ?? false
            )
        }
    }

    isolated deinit {
        displayReconfigurationMonitor.stop()
    }

#if DEBUG
    func waitForManagedDisplayOfflineForTesting(
        serialNum: UInt32,
        timeout: TimeInterval
    ) async -> Bool {
        await waitForManagedDisplayOffline(serialNum: serialNum, timeout: timeout)
    }

    func seedRuntimeBookkeepingForTesting(
        configId: UUID,
        generation: UInt64 = 1,
        runtimeDisplayID: CGDirectDisplayID? = nil
    ) {
        runtimeGenerationByConfigId[configId] = generation
        runtimeDisplayIDHintsByConfigId[configId] = runtimeDisplayID
        runningConfigIds.insert(configId)
    }

    func runtimeBookkeepingForTesting(
        configId: UUID
    ) -> (isRunning: Bool, generation: UInt64?) {
        (
            runningConfigIds.contains(configId),
            runtimeGenerationByConfigId[configId]
        )
    }

    func simulateEnablePostTopologyFailureRollbackForTesting(
        configId: UUID,
        serialNum: UInt32,
        offlineTimeout: TimeInterval = 0
    ) async {
        rollbackEnableRuntimeState(configId: configId, serialNum: serialNum)
        _ = await waitForManagedDisplayOffline(serialNum: serialNum, timeout: offlineTimeout)
    }

    func replaceDisplayConfigsForTesting(_ configs: [VirtualDisplayConfig]) {
        displayConfigs = configs
    }

    func ensureHealthyTopologyAfterEnableForTesting(
        preferredMainDisplayID: CGDirectDisplayID? = nil
    ) async throws {
        try await ensureHealthyTopologyAfterEnable(
            preferredMainDisplayID: preferredMainDisplayID
        )
    }
#endif
}

protocol DisplayReconfigurationMonitoring {
    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool
    func stop()
}

private final class DisplayReconfigurationMonitor: DisplayReconfigurationMonitoring {
    private var handler: (@MainActor () -> Void)?
    nonisolated(unsafe) private var isRunning = false

    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool {
        self.handler = handler
        guard !isRunning else { return true }

        let userInfo = Unmanaged.passRetained(self).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback(
            Self.displayReconfigurationCallback,
            userInfo
        )
        guard result == .success else {
            Unmanaged<DisplayReconfigurationMonitor>.fromOpaque(userInfo).release()
            return false
        }
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else {
            handler = nil
            return
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(
            Self.displayReconfigurationCallback,
            userInfo
        )
        isRunning = false
        handler = nil
        Unmanaged<DisplayReconfigurationMonitor>.fromOpaque(userInfo).release()
    }

    deinit {
        assert(!isRunning, "DisplayReconfigurationMonitor must be stopped before deallocation.")
    }

    private nonisolated static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = {
        _,
        _,
        userInfo in
        guard let userInfo else { return }

        let monitor = Unmanaged<DisplayReconfigurationMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        Task { @MainActor in
            monitor.handler?()
        }
    }
}

struct SystemDisplayTopologyInspector: DisplayTopologyInspecting {
    func snapshot(
        trackedManagedSerials: Set<UInt32>,
        managedVendorID: UInt32,
        managedProductID: UInt32
    ) -> DisplayTopologySnapshot? {
        var displayCount: UInt32 = 0
        let preflight = CGGetOnlineDisplayList(0, nil, &displayCount)
        guard preflight == .success else { return nil }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        var resolvedCount: UInt32 = 0
        let listStatus = CGGetOnlineDisplayList(displayCount, &displayIDs, &resolvedCount)
        guard listStatus == .success else { return nil }

        let infos = displayIDs.prefix(Int(resolvedCount)).map { displayID in
            let vendorID = CGDisplayVendorNumber(displayID)
            let productID = CGDisplayModelNumber(displayID)
            let serialNumber = CGDisplaySerialNumber(displayID)
            let mirrorMaster = CGDisplayMirrorsDisplay(displayID)
            return DisplayTopologySnapshot.DisplayInfo(
                id: displayID,
                serialNumber: serialNumber,
                isManagedVirtualDisplay: vendorID == managedVendorID &&
                    productID == managedProductID &&
                    trackedManagedSerials.contains(serialNumber),
                isActive: CGDisplayIsActive(displayID) != 0,
                isInMirrorSet: CGDisplayIsInMirrorSet(displayID) != 0,
                mirrorMasterDisplayID: mirrorMaster == kCGNullDirectDisplay ? nil : mirrorMaster,
                bounds: CGDisplayBounds(displayID)
            )
        }
        .sorted { $0.id < $1.id }

        return DisplayTopologySnapshot(
            mainDisplayID: CGMainDisplayID(),
            displays: infos
        )
    }
}

struct SystemDisplayTopologyRepairer: DisplayTopologyRepairing {
    private let horizontalSpacing: Int32 = 80

    func repair(
        snapshot: DisplayTopologySnapshot,
        managedDisplayIDs: [CGDirectDisplayID],
        anchorDisplayID: CGDirectDisplayID
    ) -> Bool {
        let uniqueManagedDisplayIDs = Array(Set(managedDisplayIDs)).sorted()
        guard !uniqueManagedDisplayIDs.isEmpty else { return false }

        var displayConfig: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&displayConfig) == .success,
              let displayConfig else {
            AppLog.virtualDisplay.error("Topology repair failed: CGBeginDisplayConfiguration failed.")
            return false
        }

        func fail() -> Bool {
            CGCancelDisplayConfiguration(displayConfig)
            AppLog.virtualDisplay.error("Topology repair cancelled due to intermediate failure.")
            return false
        }

        for displayID in uniqueManagedDisplayIDs {
            let status = CGConfigureDisplayMirrorOfDisplay(
                displayConfig,
                displayID,
                kCGNullDirectDisplay
            )
            guard status == .success else {
                AppLog.virtualDisplay.error(
                    "Topology repair failed while clearing mirror (displayID: \(displayID, privacy: .public), status: \(status.rawValue, privacy: .public))."
                )
                return fail()
            }
        }

        let placementAnchorID: CGDirectDisplayID

        if uniqueManagedDisplayIDs.contains(anchorDisplayID) {
            placementAnchorID = anchorDisplayID
        } else if let firstManaged = uniqueManagedDisplayIDs.first {
            placementAnchorID = firstManaged
        } else {
            return fail()
        }
        let placementOrder = orderedDisplayIDs(
            anchorDisplayID: placementAnchorID,
            managedDisplayIDs: uniqueManagedDisplayIDs,
            snapshot: snapshot
        )

        let baselineY: Int32 = 0
        var nextX: Int32 = 0

        for displayID in placementOrder {
            if let currentMode = CGDisplayCopyDisplayMode(displayID) {
                _ = CGConfigureDisplayWithDisplayMode(
                    displayConfig,
                    displayID,
                    currentMode,
                    nil
                )
            }

            let originStatus = CGConfigureDisplayOrigin(
                displayConfig,
                displayID,
                nextX,
                baselineY
            )
            guard originStatus == .success else {
                AppLog.virtualDisplay.error(
                    "Topology repair failed while setting origin (displayID: \(displayID, privacy: .public), x: \(nextX, privacy: .public), y: \(baselineY, privacy: .public), status: \(originStatus.rawValue, privacy: .public))."
                )
                return fail()
            }

            guard let bounds = bounds(for: displayID, snapshot: snapshot) else {
                return fail()
            }
            guard let afterWidth = safeAdd(nextX, toInt32(bounds.width)),
                  let afterSpacing = safeAdd(afterWidth, horizontalSpacing) else {
                return fail()
            }
            nextX = afterSpacing
        }

        let completeStatus = CGCompleteDisplayConfiguration(displayConfig, .forSession)
        if completeStatus != .success {
            AppLog.virtualDisplay.error(
                "Topology repair commit failed (status: \(completeStatus.rawValue, privacy: .public))."
            )
            return false
        }
        return true
    }

    private func orderedDisplayIDs(
        anchorDisplayID: CGDirectDisplayID,
        managedDisplayIDs: [CGDirectDisplayID],
        snapshot: DisplayTopologySnapshot
    ) -> [CGDirectDisplayID] {
        let trailingIDs = managedDisplayIDs
            .filter { $0 != anchorDisplayID }
            .sorted { lhs, rhs in
                let lhsBounds = bounds(for: lhs, snapshot: snapshot) ?? .zero
                let rhsBounds = bounds(for: rhs, snapshot: snapshot) ?? .zero
                if lhsBounds.origin.x != rhsBounds.origin.x {
                    return lhsBounds.origin.x < rhsBounds.origin.x
                }
                if lhsBounds.origin.y != rhsBounds.origin.y {
                    return lhsBounds.origin.y < rhsBounds.origin.y
                }
                return lhs < rhs
            }
        return [anchorDisplayID] + trailingIDs
    }

    private func bounds(
        for displayID: CGDirectDisplayID,
        snapshot: DisplayTopologySnapshot
    ) -> CGRect? {
        if let sampled = snapshot.display(for: displayID) {
            return sampled.bounds
        }
        return nil
    }

    private func toInt32(_ value: CGFloat) -> Int32 {
        let rounded = value.rounded()
        let lowerBound = CGFloat(Int32.min)
        let upperBound = CGFloat(Int32.max)
        return Int32(min(max(rounded, lowerBound), upperBound))
    }

    private func safeAdd(_ lhs: Int32, _ rhs: Int32) -> Int32? {
        lhs.addingReportingOverflow(rhs).overflow ? nil : lhs + rhs
    }
}

@MainActor
protocol VirtualDisplayServiceProtocol: AnyObject {
    var currentDisplays: [CGVirtualDisplay] { get }
    var currentDisplayConfigs: [VirtualDisplayConfig] { get }
    var currentRunningConfigIds: Set<UUID> { get }
    var currentRestoreFailures: [VirtualDisplayRestoreFailure] { get }

    func loadPersistedConfigs()
    func restoreDesiredVirtualDisplays()
    func clearRestoreFailures()

    @discardableResult
    func resetAllVirtualDisplayData() -> Int

    func runtimeDisplay(for configId: UUID) -> CGVirtualDisplay?
    func runtimeDisplayID(for configId: UUID) -> CGDirectDisplayID?
    func isVirtualDisplayRunning(configId: UUID) -> Bool

    @discardableResult
    func createDisplay(
        name: String,
        serialNum: UInt32,
        physicalSize: CGSize,
        maxPixels: (width: UInt32, height: UInt32),
        modes: [ResolutionSelection]
    ) throws -> CGVirtualDisplay

    @discardableResult
    func createDisplayFromConfig(_ config: VirtualDisplayConfig) throws -> CGVirtualDisplay

    func disableDisplay(_ display: CGVirtualDisplay, modes: [ResolutionSelection])
    func disableDisplayByConfig(_ configId: UUID) throws
    func enableDisplay(_ configId: UUID) async throws
    func destroyDisplay(_ configId: UUID)
    func destroyDisplay(_ display: CGVirtualDisplay)
    func getConfig(_ configId: UUID) -> VirtualDisplayConfig?
    func updateConfig(_ updated: VirtualDisplayConfig)
    func moveConfig(_ configId: UUID, direction: VirtualDisplayService.ReorderDirection) -> Bool
    func applyModes(configId: UUID, modes: [ResolutionSelection])
    func rebuildVirtualDisplay(configId: UUID) async throws
    func getConfig(for display: CGVirtualDisplay) -> VirtualDisplayConfig?
    func updateConfig(for display: CGVirtualDisplay, modes: [ResolutionSelection])
    func nextAvailableSerialNumber() -> UInt32
}

extension VirtualDisplayService: VirtualDisplayServiceProtocol {}
