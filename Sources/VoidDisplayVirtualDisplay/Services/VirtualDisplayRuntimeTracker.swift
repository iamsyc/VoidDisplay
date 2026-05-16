import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import Foundation
import OSLog

/// Owns runtime lifecycle bookkeeping, generation management, termination callback handling,
/// and runtime display ID hint tracking.
@MainActor
package final class VirtualDisplayRuntimeTracker {
    private var activeRuntimeHandlesByConfigId: [UUID: any VirtualDisplayRuntimeHandling] = [:]
    private var runtimeDisplayIDHintsByConfigId: [UUID: CGDirectDisplayID] = [:]
    private var runtimeGenerationByConfigId: [UUID: UInt64] = [:]
    private var runningConfigIds: Set<UUID> = []
    private var nextRuntimeGeneration: UInt64 = 1

    private let teardownCoordinator: any DisplayTeardownCoordinating
    private let runtimeDriver: any VirtualDisplayRuntimeDriving
    private let clock: any VirtualDisplayClocking

    package init(
        teardownCoordinator: any DisplayTeardownCoordinating,
        runtimeDriver: any VirtualDisplayRuntimeDriving,
        clock: (any VirtualDisplayClocking)? = nil
    ) {
        self.teardownCoordinator = teardownCoordinator
        self.runtimeDriver = runtimeDriver
        self.clock = clock ?? SystemVirtualDisplayClock()
        teardownCoordinator.setRuntimeGenerationProvider { [weak self] configId in
            self?.runtimeGenerationByConfigId[configId]
        }
    }

    // MARK: - Query

    package func runningConfigIDs() -> Set<UUID> {
        runningConfigIds
    }

    package func hasRuntimeDisplay(serialNum: UInt32) -> Bool {
        activeRuntimeHandlesByConfigId.values.contains(where: { $0.serialNum == serialNum })
    }

    package func hasActiveRuntimeDisplay(configId: UUID) -> Bool {
        activeRuntimeHandlesByConfigId[configId] != nil
    }

    package func runtimeDisplayID(for configId: UUID) -> CGDirectDisplayID? {
        if let runtimeHandle = activeRuntimeHandlesByConfigId[configId] {
            return runtimeHandle.displayID
        }
        return runtimeDisplayIDHintsByConfigId[configId]
    }

    package func isVirtualDisplayRunning(configId: UUID) -> Bool {
        runningConfigIds.contains(configId)
    }

    package var runningConfigCount: Int {
        runningConfigIds.count
    }

    package func runtimeGeneration(for configId: UUID) -> UInt64? {
        runtimeGenerationByConfigId[configId]
    }

    package func runtimeSerialNum(for configId: UUID, fallback: UInt32) -> UInt32 {
        activeRuntimeHandlesByConfigId[configId]?.serialNum ?? fallback
    }

    package var activeSerialNumbers: Set<UInt32> {
        Set(activeRuntimeHandlesByConfigId.values.map(\.serialNum))
    }

    package func runtimeDisplayIDForSerial(_ serialNum: UInt32, configs: [VirtualDisplayConfig]) -> CGDirectDisplayID? {
        if let runtimeHandle = activeRuntimeHandlesByConfigId.values.first(where: { $0.serialNum == serialNum }) {
            return runtimeHandle.displayID
        }
        if let configID = configs.first(where: { $0.serialNum == serialNum })?.id {
            return runtimeDisplayID(for: configID)
        }
        return nil
    }

    // MARK: - Create runtime display

    @discardableResult
    package func createRuntimeDisplay(
        from config: VirtualDisplayConfig,
        maxPixels: (width: UInt32, height: UInt32)? = nil
    ) throws -> RuntimeDisplayRecord {
        if let existing = activeRuntimeHandlesByConfigId[config.id] {
            let generation = runtimeGenerationByConfigId[config.id] ?? allocateRuntimeGeneration()
            runtimeGenerationByConfigId[config.id] = generation
            runningConfigIds.insert(config.id)
            runtimeDisplayIDHintsByConfigId[config.id] = existing.displayID
            AppLog.virtualDisplay.debug(
                "Create runtime display reused existing active instance (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), displayID: \(existing.displayID, privacy: .public), generation: \(generation, privacy: .public))."
            )
            return RuntimeDisplayRecord(
                configId: config.id,
                serialNum: existing.serialNum,
                displayID: existing.displayID,
                generation: generation
            )
        }

        if activeRuntimeHandlesByConfigId.values.contains(where: { $0.serialNum == config.serialNum }) {
            throw VirtualDisplayOperationError.duplicateSerialNumber(config.serialNum)
        }

        let modes = config.resolutionModes
        guard !modes.isEmpty else {
            throw VirtualDisplayOperationError.invalidConfiguration(String(localized: "At least one resolution mode is required."))
        }

        let generation = allocateRuntimeGeneration()
        AppLog.virtualDisplay.debug(
            "Create runtime display begin (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), generation: \(generation, privacy: .public), pendingGenerationBeforeCreate: \(String(describing: self.runtimeGenerationByConfigId[config.id]), privacy: .public))."
        )
        let runtimeHandle = try runtimeDriver.createRuntimeDisplay(
            from: config,
            maxPixels: maxPixels,
            onTermination: { [weak self] in
                self?.handleVirtualDisplayTermination(
                    configId: config.id,
                    serialNum: config.serialNum,
                    generation: generation
                )
            }
        )
        AppLog.virtualDisplay.debug(
            "Create runtime display descriptor instantiated (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), generation: \(generation, privacy: .public), provisionalDisplayID: \(runtimeHandle.displayID, privacy: .public))."
        )

        activeRuntimeHandlesByConfigId[config.id] = runtimeHandle
        runtimeDisplayIDHintsByConfigId[config.id] = runtimeHandle.displayID
        runtimeGenerationByConfigId[config.id] = generation
        runningConfigIds.insert(config.id)
        AppLog.virtualDisplay.notice(
            "Create runtime display committed (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), generation: \(generation, privacy: .public), displayID: \(runtimeHandle.displayID, privacy: .public))."
        )
        return RuntimeDisplayRecord(
            configId: config.id,
            serialNum: runtimeHandle.serialNum,
            displayID: runtimeHandle.displayID,
            generation: generation
        )
    }

    @discardableResult
    package func createRuntimeDisplayWithRetries(
        from config: VirtualDisplayConfig,
        terminationConfirmed: Bool
    ) async throws -> RuntimeDisplayRecord {
        let maxAttempts = terminationConfirmed ? 3 : 10
        for attempt in 1...maxAttempts {
            do {
                return try createRuntimeDisplay(from: config)
            } catch {
                let shouldRetry: Bool
                if let virtualDisplayError = error as? VirtualDisplayOperationError,
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
                    throw VirtualDisplayOperationError.teardownTimedOut
                }
                throw error
            }
        }

        throw VirtualDisplayOperationError.creationFailed
    }

    // MARK: - Apply modes

    package func applyModes(configId: UUID, modes: [ResolutionSelection]) {
        guard let runtimeHandle = activeRuntimeHandlesByConfigId[configId] else { return }
        let applied = runtimeHandle.applyModes(modes)
        if !applied {
            AppLog.virtualDisplay.error("Apply virtual display modes failed (serial: \(runtimeHandle.serialNum, privacy: .public)).")
        }
    }

    // MARK: - Runtime tracking cleanup

    package func clearRuntimeTracking(
        configId: UUID,
        keepGeneration: Bool
    ) {
        teardownCoordinator.cancelTerminationWaiter(configId: configId)
        activeRuntimeHandlesByConfigId[configId] = nil
        runtimeDisplayIDHintsByConfigId[configId] = nil
        if !keepGeneration {
            runtimeGenerationByConfigId[configId] = nil
        }
        runningConfigIds.remove(configId)
    }

    package func rollbackEnableRuntimeState(configId: UUID) {
        clearRuntimeTracking(configId: configId, keepGeneration: true)
    }

    package func resetAll() {
        teardownCoordinator.cancelAllTerminationWaiters()
        teardownCoordinator.cancelAllOfflineWaiters()
        activeRuntimeHandlesByConfigId.removeAll()
        runtimeDisplayIDHintsByConfigId.removeAll()
        runtimeGenerationByConfigId.removeAll()
        runningConfigIds.removeAll()
    }

    // MARK: - Offline wait

    package func waitForManagedDisplayOffline(
        serialNum: UInt32,
        timeout: TimeInterval = 2.5
    ) async -> Bool {
        await teardownCoordinator.waitForManagedDisplayOffline(
            serialNum: serialNum,
            timeout: timeout
        )
    }

    package func isManagedDisplayOnline(serialNum: UInt32) -> Bool {
        teardownCoordinator.isManagedDisplayOnline(serialNum: serialNum)
    }

    // MARK: - Sleep utility

    package func sleepForRetry(seconds: TimeInterval) async {
        await clock.sleep(for: .seconds(seconds))
    }

    // MARK: - Termination

    private func handleVirtualDisplayTermination(configId: UUID, serialNum: UInt32, generation: UInt64) {
        let currentGeneration = runtimeGenerationByConfigId[configId]
        let currentDisplayID = activeRuntimeHandlesByConfigId[configId]?.displayID
        AppLog.virtualDisplay.debug(
            "Virtual display termination callback received (config: \(configId.uuidString, privacy: .public), serial: \(serialNum, privacy: .public), callbackGeneration: \(generation, privacy: .public), currentGeneration: \(String(describing: currentGeneration), privacy: .public), currentDisplayID: \(String(describing: currentDisplayID), privacy: .public))."
        )
        guard currentGeneration == generation else {
            AppLog.virtualDisplay.debug(
                "Ignore stale virtual display termination (config: \(configId.uuidString, privacy: .public), serial: \(serialNum, privacy: .public), callbackGeneration: \(generation, privacy: .public), currentGeneration: \(String(describing: currentGeneration), privacy: .public))."
            )
            return
        }
        AppLog.virtualDisplay.notice(
            "Virtual display terminated (config: \(configId.uuidString, privacy: .public), serial: \(serialNum, privacy: .public), generation: \(generation, privacy: .public), displayID: \(String(describing: currentDisplayID), privacy: .public))."
        )
        activeRuntimeHandlesByConfigId[configId] = nil
        runtimeDisplayIDHintsByConfigId[configId] = nil
        runtimeGenerationByConfigId[configId] = nil
        runningConfigIds.remove(configId)
        teardownCoordinator.observeTermination(configId: configId, generation: generation)
    }

    private func allocateRuntimeGeneration() -> UInt64 {
        defer { nextRuntimeGeneration &+= 1 }
        return nextRuntimeGeneration
    }

    // MARK: - Runtime bookkeeping

    /// Records running-state bookkeeping when runtime state is established by an external orchestrator.
    package func markConfigRunning(
        configId: UUID,
        generation: UInt64,
        runtimeDisplayID: CGDirectDisplayID? = nil
    ) {
        runtimeGenerationByConfigId[configId] = generation
        runtimeDisplayIDHintsByConfigId[configId] = runtimeDisplayID
        runningConfigIds.insert(configId)
        if generation >= nextRuntimeGeneration {
            nextRuntimeGeneration = generation &+ 1
        }
    }
}
