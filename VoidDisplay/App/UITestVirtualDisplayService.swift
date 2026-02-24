import CoreGraphics
import Foundation

@MainActor
final class UITestVirtualDisplayService: VirtualDisplayServiceProtocol {
    var currentDisplays: [CGVirtualDisplay] = []
    var currentDisplayConfigs: [VirtualDisplayConfig]
    var currentRunningConfigIds: Set<UUID>
    var currentRestoreFailures: [VirtualDisplayRestoreFailure] = []

    private let scenario: UITestScenario

    init(scenario: UITestScenario) {
        self.scenario = scenario
        let fixtureConfigs = UITestFixture.virtualDisplayConfigs()
        self.currentDisplayConfigs = fixtureConfigs
        self.currentRunningConfigIds = Set(fixtureConfigs.prefix(1).map(\.id))
    }

    func loadPersistedConfigs() {}

    func restoreDesiredVirtualDisplays() {}

    func clearRestoreFailures() {
        currentRestoreFailures = []
    }

    @discardableResult
    func resetAllVirtualDisplayData() -> Int {
        let removed = currentDisplayConfigs.count
        currentDisplays = []
        currentDisplayConfigs = []
        currentRunningConfigIds = []
        currentRestoreFailures = []
        return removed
    }

    func runtimeDisplay(for configId: UUID) -> CGVirtualDisplay? {
        nil
    }

    func runtimeDisplayID(for configId: UUID) -> CGDirectDisplayID? {
        nil
    }

    func isVirtualDisplayRunning(configId: UUID) -> Bool {
        currentRunningConfigIds.contains(configId)
    }

    @discardableResult
    func createDisplay(
        name: String,
        serialNum: UInt32,
        physicalSize: CGSize,
        maxPixels: (width: UInt32, height: UInt32),
        modes: [ResolutionSelection]
    ) throws -> CGVirtualDisplay {
        throw VirtualDisplayService.VirtualDisplayError.creationFailed
    }

    @discardableResult
    func createDisplayFromConfig(_ config: VirtualDisplayConfig) throws -> CGVirtualDisplay {
        throw VirtualDisplayService.VirtualDisplayError.creationFailed
    }

    func disableDisplay(_ display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        guard let config = currentDisplayConfigs.first(where: { $0.serialNum == display.serialNum }) else {
            return
        }
        disableDisplayByConfigIfPresent(config.id)
    }

    func disableDisplayByConfig(_ configId: UUID) throws {
        guard currentDisplayConfigs.contains(where: { $0.id == configId }) else {
            throw VirtualDisplayService.VirtualDisplayError.configNotFound
        }
        disableDisplayByConfigIfPresent(configId)
    }

    func enableDisplay(_ configId: UUID) async throws {
        guard let index = currentDisplayConfigs.firstIndex(where: { $0.id == configId }) else {
            throw VirtualDisplayService.VirtualDisplayError.configNotFound
        }
        var updated = currentDisplayConfigs[index]
        updated.desiredEnabled = true
        currentDisplayConfigs[index] = updated
        currentRunningConfigIds.insert(configId)
    }

    func destroyDisplay(_ configId: UUID) {
        currentDisplayConfigs.removeAll { $0.id == configId }
        currentRunningConfigIds.remove(configId)
    }

    func destroyDisplay(_ display: CGVirtualDisplay) {
        let removedConfigIDs = currentDisplayConfigs
            .filter { $0.serialNum == display.serialNum }
            .map(\.id)
        currentDisplayConfigs.removeAll { $0.serialNum == display.serialNum }
        for configID in removedConfigIDs {
            currentRunningConfigIds.remove(configID)
        }
    }

    func getConfig(_ configId: UUID) -> VirtualDisplayConfig? {
        currentDisplayConfigs.first { $0.id == configId }
    }

    func updateConfig(_ updated: VirtualDisplayConfig) {
        guard let index = currentDisplayConfigs.firstIndex(where: { $0.id == updated.id }) else { return }
        currentDisplayConfigs[index] = updated
    }

    func moveConfig(_ configId: UUID, direction: VirtualDisplayService.ReorderDirection) -> Bool {
        guard let sourceIndex = currentDisplayConfigs.firstIndex(where: { $0.id == configId }) else {
            return false
        }

        let destinationIndex: Int
        switch direction {
        case .up:
            destinationIndex = sourceIndex - 1
        case .down:
            destinationIndex = sourceIndex + 1
        }

        guard currentDisplayConfigs.indices.contains(destinationIndex) else {
            return false
        }

        currentDisplayConfigs.swapAt(sourceIndex, destinationIndex)
        return true
    }

    func applyModes(configId: UUID, modes: [ResolutionSelection]) {
        guard let index = currentDisplayConfigs.firstIndex(where: { $0.id == configId }) else { return }
        var config = currentDisplayConfigs[index]
        config.modes = modes.map {
            .init(
                width: $0.width,
                height: $0.height,
                refreshRate: $0.refreshRate,
                enableHiDPI: $0.enableHiDPI
            )
        }
        currentDisplayConfigs[index] = config
    }

    func rebuildVirtualDisplay(configId: UUID) async throws {
        guard currentDisplayConfigs.contains(where: { $0.id == configId }) else {
            throw VirtualDisplayService.VirtualDisplayError.configNotFound
        }
        if scenario == .virtualDisplayRebuildFailed {
            throw VirtualDisplayService.VirtualDisplayError.topologyRepairFailed
        }
    }

    func getConfig(for display: CGVirtualDisplay) -> VirtualDisplayConfig? {
        currentDisplayConfigs.first { $0.serialNum == display.serialNum }
    }

    func updateConfig(for display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        guard let config = currentDisplayConfigs.first(where: { $0.serialNum == display.serialNum }) else {
            return
        }
        applyModes(configId: config.id, modes: modes)
    }

    func nextAvailableSerialNumber() -> UInt32 {
        let usedNumbers = Set(currentDisplayConfigs.map(\.serialNum))
        var next: UInt32 = 1
        while usedNumbers.contains(next) {
            next += 1
        }
        return next
    }

    private func disableDisplayByConfigIfPresent(_ configId: UUID) {
        guard let index = currentDisplayConfigs.firstIndex(where: { $0.id == configId }) else { return }
        var updated = currentDisplayConfigs[index]
        updated.desiredEnabled = false
        currentDisplayConfigs[index] = updated
        currentRunningConfigIds.remove(configId)
    }
}
