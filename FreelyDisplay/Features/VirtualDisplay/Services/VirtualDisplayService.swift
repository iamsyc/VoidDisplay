import Foundation
import CoreGraphics
import OSLog

@MainActor
final class VirtualDisplayService {
    private static let managedVendorID: UInt32 = 0x3456
    private static let managedProductID: UInt32 = 0x1234

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

    enum ReorderDirection {
        case up
        case down
    }

    enum VirtualDisplayError: LocalizedError {
        case duplicateSerialNumber(UInt32)
        case invalidConfiguration(String)
        case creationFailed
        case configNotFound
        case rebuildMainDisplayWhileRunning
        case teardownTimedOut

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
            case .rebuildMainDisplayWhileRunning:
                return String(localized: "Cannot rebuild while this display is the system main display. Switch main display first and try again.")
            case .teardownTimedOut:
                return String(localized: "Display teardown timed out. Wait a moment and try rebuilding again.")
            }
        }
    }

    private let persistenceService: VirtualDisplayPersistenceService
    private var displays: [CGVirtualDisplay] = []
    private var displayConfigs: [VirtualDisplayConfig] = []
    private var runningConfigIds: Set<UUID> = []
    private var restoreFailures: [VirtualDisplayRestoreFailure] = []
    private var activeDisplaysByConfigId: [UUID: CGVirtualDisplay] = [:]
    private var runtimeGenerationByConfigId: [UUID: UInt64] = [:]
    private var terminationWaitersByConfigId: [UUID: TerminationWaiter] = [:]
    private var offlineWaitersByToken: [UUID: OfflineWaiter] = [:]
    private var nextRuntimeGeneration: UInt64 = 1
    private let displayReconfigurationMonitor: any DisplayReconfigurationMonitoring
    private let managedDisplayOnlineChecker: (UInt32) -> Bool
    private var isReconfigurationMonitorAvailable = false
    private var didLogOfflinePollingFallback = false

    convenience init(persistenceService: VirtualDisplayPersistenceService? = nil) {
        self.init(
            persistenceService: persistenceService,
            displayReconfigurationMonitor: DisplayReconfigurationMonitor(),
            managedDisplayOnlineChecker: { serialNum in
                Self.systemManagedDisplayOnline(serialNum: serialNum)
            }
        )
    }

    init(
        persistenceService: VirtualDisplayPersistenceService? = nil,
        displayReconfigurationMonitor: any DisplayReconfigurationMonitoring,
        managedDisplayOnlineChecker: @escaping (UInt32) -> Bool
    ) {
        self.persistenceService = persistenceService ?? VirtualDisplayPersistenceService()
        self.displayReconfigurationMonitor = displayReconfigurationMonitor
        self.managedDisplayOnlineChecker = managedDisplayOnlineChecker
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
            // Keep generation until termination callback (or timeout) so re-enable can wait safely.
            runningConfigIds.remove(configId)
        }
        persistConfigs()
    }

    func disableDisplayByConfig(_ configId: UUID) {
        guard let index = displayConfigs.firstIndex(where: { $0.id == configId }) else { return }

        var updated = displayConfigs[index]
        updated.desiredEnabled = false
        displayConfigs[index] = updated

        let runtimeSerialNum = activeDisplaysByConfigId[configId]?.serialNum ?? displayConfigs[index].serialNum
        cancelTerminationWaiter(configId: configId)
        activeDisplaysByConfigId[configId] = nil
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
        var terminationConfirmed = true
        if activeDisplaysByConfigId[configId] == nil,
           let pendingGeneration = runtimeGenerationByConfigId[configId] {
            terminationConfirmed = await waitForTermination(
                configId: configId,
                expectedGeneration: pendingGeneration
            )
            if !terminationConfirmed {
                AppLog.virtualDisplay.warning(
                    "Enable did not observe termination callback in time; continue with offline verification (config: \(config.id.uuidString, privacy: .public))."
                )
            }
        }
        if activeDisplaysByConfigId[configId] == nil {
            let offlineConfirmed = await waitForManagedDisplayOffline(serialNum: config.serialNum)
            if !offlineConfirmed {
                AppLog.virtualDisplay.error(
                    "Enable aborted because previous display with same serial is still online (serial: \(config.serialNum, privacy: .public), config: \(config.id.uuidString, privacy: .public))."
                )
                throw VirtualDisplayError.teardownTimedOut
            }
            // After explicit offline confirmation, teardown is considered settled even if callback was missed.
            terminationConfirmed = true
        }

        do {
            _ = try await createRuntimeDisplayWithRetries(
                from: config,
                terminationConfirmed: terminationConfirmed
            )
        } catch {
            AppLog.virtualDisplay.error(
                "Enable display failed (name: \(config.name, privacy: .public), serial: \(config.serialNum, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    func destroyDisplay(_ configId: UUID) {
        guard let config = displayConfigs.first(where: { $0.id == configId }) else { return }

        let runtimeSerialNum = activeDisplaysByConfigId[configId]?.serialNum ?? config.serialNum
        cancelTerminationWaiter(configId: configId)
        activeDisplaysByConfigId[configId] = nil
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

        var generationToWaitFor: UInt64?
        if let running = activeDisplaysByConfigId[configId] {
            if CGDisplayIsMain(running.displayID) != 0 {
                throw VirtualDisplayError.rebuildMainDisplayWhileRunning
            }

            generationToWaitFor = runtimeGenerationByConfigId[configId]
            activeDisplaysByConfigId[configId] = nil
            runningConfigIds.remove(configId)
            displays.removeAll { $0.serialNum == running.serialNum }
        }

        var terminationConfirmed = true
        if let generationToWaitFor,
           !(await waitForTermination(configId: configId, expectedGeneration: generationToWaitFor)) {
            terminationConfirmed = false
            AppLog.virtualDisplay.warning(
                "Virtual display teardown did not complete before timeout (config: \(config.id.uuidString, privacy: .public)). Continue rebuild with extended retries."
            )
        }
        if let generationToWaitFor {
            let offlineConfirmed = await waitForManagedDisplayOffline(serialNum: config.serialNum)
            if !offlineConfirmed {
                AppLog.virtualDisplay.error(
                    "Rebuild aborted because previous display with same serial is still online (serial: \(config.serialNum, privacy: .public), generation: \(generationToWaitFor, privacy: .public), config: \(config.id.uuidString, privacy: .public))."
                )
                throw VirtualDisplayError.teardownTimedOut
            }
            // After explicit offline confirmation, teardown is considered settled even if callback was missed.
            terminationConfirmed = true
        }

        _ = try await createRuntimeDisplayWithRetries(
            from: config,
            terminationConfirmed: terminationConfirmed
        )
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

    private func persistConfigs() {
        persistenceService.saveConfigs(displayConfigs)
    }

    @discardableResult
    private func createRuntimeDisplay(from config: VirtualDisplayConfig, maxPixels: (width: UInt32, height: UInt32)? = nil) throws -> CGVirtualDisplay {
        if let existing = activeDisplaysByConfigId[config.id] {
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

        return await withCheckedContinuation { continuation in
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

        return await withCheckedContinuation { continuation in
            let token = UUID()
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
    }

    private func waitForManagedDisplayOfflineByPolling(
        serialNum: UInt32,
        timeout: TimeInterval,
        interval: TimeInterval = 0.1
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
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

    deinit {
        displayReconfigurationMonitor.stop()
    }

#if DEBUG
    func waitForManagedDisplayOfflineForTesting(
        serialNum: UInt32,
        timeout: TimeInterval
    ) async -> Bool {
        await waitForManagedDisplayOffline(serialNum: serialNum, timeout: timeout)
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
