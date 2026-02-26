import Foundation
import CoreGraphics
import OSLog

/// Owns the runtime lifecycle of CGVirtualDisplay instances — creation, tracking, generation management,
/// termination callback handling, and display ID hint bookkeeping.
@MainActor
final class VirtualDisplayRuntimeTracker {
    private var displays: [CGVirtualDisplay] = []
    private var activeDisplaysByConfigId: [UUID: CGVirtualDisplay] = [:]
    private var runtimeDisplayIDHintsByConfigId: [UUID: CGDirectDisplayID] = [:]
    private var runtimeGenerationByConfigId: [UUID: UInt64] = [:]
    private var runningConfigIds: Set<UUID> = []
    private var nextRuntimeGeneration: UInt64 = 1

    private let teardownCoordinator: any DisplayTeardownCoordinating

    init(teardownCoordinator: any DisplayTeardownCoordinating) {
        self.teardownCoordinator = teardownCoordinator
        teardownCoordinator.setRuntimeGenerationProvider { [weak self] configId in
            self?.runtimeGenerationByConfigId[configId]
        }
    }

    // MARK: - Query

    func runtimeDisplays() -> [CGVirtualDisplay] {
        displays
    }

    func runningConfigIDs() -> Set<UUID> {
        runningConfigIds
    }

    func hasRuntimeDisplay(serialNum: UInt32) -> Bool {
        displays.contains(where: { $0.serialNum == serialNum })
    }

    func runtimeDisplay(for configId: UUID) -> CGVirtualDisplay? {
        activeDisplaysByConfigId[configId]
    }

    func hasActiveRuntimeDisplay(configId: UUID) -> Bool {
        activeDisplaysByConfigId[configId] != nil
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

    var runningConfigCount: Int {
        runningConfigIds.count
    }

    func runtimeGeneration(for configId: UUID) -> UInt64? {
        runtimeGenerationByConfigId[configId]
    }

    func runtimeSerialNum(for configId: UUID, fallback: UInt32) -> UInt32 {
        activeDisplaysByConfigId[configId]?.serialNum ?? fallback
    }

    var activeSerialNumbers: Set<UInt32> {
        Set(displays.map(\.serialNum))
    }

    func runtimeDisplayIDForSerial(_ serialNum: UInt32, configs: [VirtualDisplayConfig]) -> CGDirectDisplayID? {
        if let runtime = activeDisplaysByConfigId.values.first(where: { $0.serialNum == serialNum }) {
            return runtime.displayID
        }
        if let configID = configs.first(where: { $0.serialNum == serialNum })?.id {
            return runtimeDisplayID(for: configID)
        }
        return nil
    }

    // MARK: - Create runtime display

    @discardableResult
    func createRuntimeDisplay(
        from config: VirtualDisplayConfig,
        maxPixels: (width: UInt32, height: UInt32)? = nil
    ) throws -> CGVirtualDisplay {
        if let existing = activeDisplaysByConfigId[config.id] {
            AppLog.virtualDisplay.debug(
                "Create runtime display reused existing active instance (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), displayID: \(existing.displayID, privacy: .public), generation: \(String(describing: self.runtimeGenerationByConfigId[config.id]), privacy: .public))."
            )
            runtimeDisplayIDHintsByConfigId[config.id] = existing.displayID
            return existing
        }

        if displays.contains(where: { $0.serialNum == config.serialNum }) {
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
        desc.name = config.displayName
        let max = maxPixels ?? config.maxPixelDimensions
        desc.maxPixelsWide = max.width
        desc.maxPixelsHigh = max.height
        desc.sizeInMillimeters = config.physicalSize
        desc.productID = ManagedVirtualDisplayIdentity.productID
        desc.vendorID = ManagedVirtualDisplayIdentity.vendorID
        desc.serialNum = config.serialNum

        let display = CGVirtualDisplay(descriptor: desc)
        AppLog.virtualDisplay.debug(
            "Create runtime display descriptor instantiated (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), generation: \(generation, privacy: .public), provisionalDisplayID: \(display.displayID, privacy: .public))."
        )

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
                "Create virtual display apply settings failed (displayName: \(config.displayName, privacy: .public), serial: \(config.serialNum, privacy: .public), generation: \(generation, privacy: .public), provisionalDisplayID: \(display.displayID, privacy: .public))."
            )
            throw VirtualDisplayOperationError.creationFailed
        }

        activeDisplaysByConfigId[config.id] = display
        runtimeDisplayIDHintsByConfigId[config.id] = display.displayID
        runtimeGenerationByConfigId[config.id] = generation
        runningConfigIds.insert(config.id)
        displays.removeAll { $0.serialNum == config.serialNum }
        displays.append(display)
        AppLog.virtualDisplay.notice(
            "Create runtime display committed (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), generation: \(generation, privacy: .public), displayID: \(display.displayID, privacy: .public))."
        )
        return display
    }

    @discardableResult
    func createRuntimeDisplayWithRetries(
        from config: VirtualDisplayConfig,
        terminationConfirmed: Bool
    ) async throws -> CGVirtualDisplay {
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

    // MARK: - Runtime tracking cleanup

    func clearRuntimeTracking(
        configId: UUID,
        serialNum: UInt32,
        keepGeneration: Bool
    ) {
        teardownCoordinator.cancelTerminationWaiter(configId: configId)
        activeDisplaysByConfigId[configId] = nil
        runtimeDisplayIDHintsByConfigId[configId] = nil
        if !keepGeneration {
            runtimeGenerationByConfigId[configId] = nil
        }
        runningConfigIds.remove(configId)
        displays.removeAll { $0.serialNum == serialNum }
    }

    func clearRuntimeTrackingForSerialNum(
        _ serialNum: UInt32,
        keepGeneration: Bool
    ) {
        let matchingConfigIDs = activeDisplaysByConfigId.compactMap { configId, activeDisplay in
            activeDisplay.serialNum == serialNum ? configId : nil
        }
        for configID in matchingConfigIDs {
            clearRuntimeTracking(configId: configID, serialNum: serialNum, keepGeneration: keepGeneration)
        }
        displays.removeAll { $0.serialNum == serialNum }
    }

    func rollbackEnableRuntimeState(configId: UUID, serialNum: UInt32) {
        clearRuntimeTracking(configId: configId, serialNum: serialNum, keepGeneration: true)
    }

    func resetAll() {
        teardownCoordinator.cancelAllTerminationWaiters()
        teardownCoordinator.cancelAllOfflineWaiters()
        activeDisplaysByConfigId.removeAll()
        runtimeDisplayIDHintsByConfigId.removeAll()
        runtimeGenerationByConfigId.removeAll()
        runningConfigIds.removeAll()
        displays.removeAll()
    }

    // MARK: - Offline wait

    func waitForManagedDisplayOffline(
        serialNum: UInt32,
        timeout: TimeInterval = 2.5
    ) async -> Bool {
        await teardownCoordinator.waitForManagedDisplayOffline(
            serialNum: serialNum,
            timeout: timeout
        )
    }

    func isManagedDisplayOnline(serialNum: UInt32) -> Bool {
        teardownCoordinator.isManagedDisplayOnline(serialNum: serialNum)
    }

    // MARK: - Sleep utility

    func sleepForRetry(seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(seconds, 0) * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            // Ignore cancellation and let retry loop exit on next check.
        }
    }

    // MARK: - Termination

    private func handleVirtualDisplayTermination(configId: UUID, serialNum: UInt32, generation: UInt64) {
        let currentGeneration = runtimeGenerationByConfigId[configId]
        let currentDisplayID = activeDisplaysByConfigId[configId]?.displayID
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
        activeDisplaysByConfigId[configId] = nil
        runtimeDisplayIDHintsByConfigId[configId] = nil
        runtimeGenerationByConfigId[configId] = nil
        runningConfigIds.remove(configId)
        displays.removeAll { $0.serialNum == serialNum }
        teardownCoordinator.observeTermination(configId: configId, generation: generation)
    }

    private func allocateRuntimeGeneration() -> UInt64 {
        defer { nextRuntimeGeneration &+= 1 }
        return nextRuntimeGeneration
    }

    // MARK: - Runtime bookkeeping

    /// Records running-state bookkeeping when runtime state is established by an external orchestrator.
    func markConfigRunning(
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
