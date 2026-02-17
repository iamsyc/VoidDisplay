import Foundation
import CoreGraphics
import OSLog

@MainActor
final class VirtualDisplayService {
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
    private var nextRuntimeGeneration: UInt64 = 1

    init(persistenceService: VirtualDisplayPersistenceService? = nil) {
        self.persistenceService = persistenceService ?? VirtualDisplayPersistenceService()
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
            activeDisplaysByConfigId[configId] = nil
            runtimeGenerationByConfigId[configId] = nil
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
        activeDisplaysByConfigId[configId] = nil
        runtimeGenerationByConfigId[configId] = nil
        runningConfigIds.remove(configId)
        displays.removeAll { $0.serialNum == runtimeSerialNum }
        persistConfigs()
    }

    func enableDisplay(_ configId: UUID) throws {
        guard let index = displayConfigs.firstIndex(where: { $0.id == configId }) else {
            throw VirtualDisplayError.configNotFound
        }

        var updated = displayConfigs[index]
        updated.desiredEnabled = true
        displayConfigs[index] = updated
        persistConfigs()

        let config = displayConfigs[index]
        do {
            _ = try createRuntimeDisplay(from: config)
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

    func rebuildVirtualDisplay(configId: UUID) throws {
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

        if let generationToWaitFor,
           !waitForTermination(configId: configId, expectedGeneration: generationToWaitFor) {
            runtimeGenerationByConfigId[configId] = nil
            throw VirtualDisplayError.teardownTimedOut
        }

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                _ = try createRuntimeDisplay(from: config)
                return
            } catch {
                let shouldRetry: Bool
                if let virtualDisplayError = error as? VirtualDisplayError,
                   case .creationFailed = virtualDisplayError {
                    shouldRetry = true
                } else {
                    shouldRetry = false
                }
                if shouldRetry && attempt < maxAttempts {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                    continue
                }
                throw error
            }
        }
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
        desc.productID = 0x1234
        desc.vendorID = 0x3456
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
    }

    private func allocateRuntimeGeneration() -> UInt64 {
        defer { nextRuntimeGeneration &+= 1 }
        return nextRuntimeGeneration
    }

    private func waitForTermination(
        configId: UUID,
        expectedGeneration: UInt64,
        timeout: TimeInterval = 1.5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runtimeGenerationByConfigId[configId] != expectedGeneration {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return runtimeGenerationByConfigId[configId] != expectedGeneration
    }
}
