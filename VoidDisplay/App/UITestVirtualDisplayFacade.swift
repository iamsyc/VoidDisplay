import CoreGraphics
import Foundation

@MainActor
final class UITestVirtualDisplayFacade: VirtualDisplayFacade {
    private var configs: [VirtualDisplayConfig]
    private var runningConfigIds: Set<UUID>
    private var restoreFailures: [VirtualDisplayRestoreFailure] = []
    var configStoreState: VirtualDisplayConfigRepositoryState = .ready(
        diagnostics: .init(
            primaryStoreURL: URL(fileURLWithPath: "/tmp/ui-test-virtual-displays.json"),
            isTestIsolatedPath: true
        )
    )

    var configStorePresentation: VirtualDisplayConfigStorePresentation {
        switch configStoreState {
        case .ready(let diagnostics):
            return .init(
                hasLoadFailure: false,
                loadErrorMessage: nil,
                diagnosticsSummary: diagnostics.summary
            )
        case .loadFailed(let error, let diagnostics):
            return .init(
                hasLoadFailure: true,
                loadErrorMessage: error.userFacingMessage,
                diagnosticsSummary: diagnostics.summary
            )
        }
    }

    private let scenario: UITestScenario

    init(scenario: UITestScenario) {
        self.scenario = scenario
        let fixtureConfigs = UITestFixture.virtualDisplayConfigs()
        self.configs = fixtureConfigs
        self.runningConfigIds = Set(fixtureConfigs.prefix(1).map(\.id))
    }

    func loadPersistedConfigs() {}

    func restoreDesiredVirtualDisplays() {}

    var snapshot: VirtualDisplaySnapshot {
        let runtimeDisplayIDByConfigId = runtimeDisplayIDs()
        let managedDisplays: [ManagedVirtualDisplayRuntimeSnapshot] = configs.compactMap { config in
            guard let displayID = runtimeDisplayIDByConfigId[config.id] else { return nil }
            return ManagedVirtualDisplayRuntimeSnapshot(
                configId: config.id,
                serialNum: config.serialNum,
                displayID: displayID,
                isLiveRuntime: runningConfigIds.contains(config.id)
            )
        }
        return VirtualDisplaySnapshot(
            managedDisplays: managedDisplays,
            configs: configs,
            runningConfigIds: runningConfigIds,
            restoreFailures: restoreFailures,
            configStorePresentation: configStorePresentation,
            runtimeDisplayIDByConfigId: runtimeDisplayIDByConfigId
        )
    }

    func clearRestoreFailures() {
        restoreFailures = []
    }

    @discardableResult
    func resetAllVirtualDisplayData() throws -> Int {
        let removed = configs.count
        configs = []
        runningConfigIds = []
        restoreFailures = []
        return removed
    }

    @discardableResult
    func createDisplay(
        name: String,
        serialNum: UInt32,
        physicalSize: CGSize,
        maxPixels: (width: UInt32, height: UInt32),
        modes: [ResolutionSelection]
    ) throws -> UUID {
        throw VirtualDisplayOperationError.creationFailed
    }

    func disableDisplayByConfig(_ configId: UUID) throws {
        guard configs.contains(where: { $0.id == configId }) else {
            throw VirtualDisplayOperationError.configNotFound
        }
        disableDisplayByConfigIfPresent(configId)
    }

    func enableDisplay(_ configId: UUID) async throws {
        guard let index = configs.firstIndex(where: { $0.id == configId }) else {
            throw VirtualDisplayOperationError.configNotFound
        }
        var updated = configs[index]
        updated.desiredEnabled = true
        configs[index] = updated
        runningConfigIds.insert(configId)
    }

    func destroyDisplay(_ configId: UUID) throws {
        configs.removeAll { $0.id == configId }
        runningConfigIds.remove(configId)
    }

    func updateConfig(_ updated: VirtualDisplayConfig) throws {
        guard let index = configs.firstIndex(where: { $0.id == updated.id }) else { return }
        configs[index] = updated
    }

    func moveConfig(_ configId: UUID, direction: VirtualDisplayReorderDirection) throws -> Bool {
        guard let sourceIndex = configs.firstIndex(where: { $0.id == configId }) else {
            return false
        }

        let destinationIndex: Int
        switch direction {
        case .up:
            destinationIndex = sourceIndex - 1
        case .down:
            destinationIndex = sourceIndex + 1
        }

        guard configs.indices.contains(destinationIndex) else {
            return false
        }

        configs.swapAt(sourceIndex, destinationIndex)
        return true
    }

    @discardableResult
    func moveConfigToFirstEnabledPosition(_ configId: UUID) throws -> Bool {
        guard let sourceIndex = configs.firstIndex(where: { $0.id == configId }) else {
            return false
        }
        guard configs[sourceIndex].desiredEnabled else {
            return false
        }
        guard let firstEnabledIndex = configs.firstIndex(where: \.desiredEnabled) else {
            return false
        }
        guard sourceIndex != firstEnabledIndex else {
            return false
        }
        let config = configs.remove(at: sourceIndex)
        configs.insert(config, at: firstEnabledIndex)
        return true
    }

    func applyModes(configId: UUID, modes: [ResolutionSelection]) {
        guard let index = configs.firstIndex(where: { $0.id == configId }) else { return }
        var config = configs[index]
        config.modes = modes.map {
            .init(
                width: $0.width,
                height: $0.height,
                refreshRate: $0.refreshRate,
                enableHiDPI: $0.enableHiDPI
            )
        }
        configs[index] = config
    }

    func rebuildVirtualDisplay(configId: UUID) async throws {
        guard configs.contains(where: { $0.id == configId }) else {
            throw VirtualDisplayOperationError.configNotFound
        }
        if scenario == .virtualDisplayRebuildFailed {
            throw VirtualDisplayOperationError.topologyRepairFailed
        }
    }

    func reconcileMainDisplayPolicyIfNeeded() async throws {}

    func nextAvailableSerialNumber() -> UInt32 {
        let usedNumbers = Set(configs.map(\.serialNum))
        var next: UInt32 = 1
        while usedNumbers.contains(next) {
            next += 1
        }
        return next
    }

    private func disableDisplayByConfigIfPresent(_ configId: UUID) {
        guard let index = configs.firstIndex(where: { $0.id == configId }) else { return }
        var updated = configs[index]
        updated.desiredEnabled = false
        configs[index] = updated
        runningConfigIds.remove(configId)
    }

    private func runtimeDisplayIDs() -> [UUID: CGDirectDisplayID] {
        let runningIDsInOrder = configs
            .map(\.id)
            .filter { runningConfigIds.contains($0) }
        guard !runningIDsInOrder.isEmpty else { return [:] }

        var map: [UUID: CGDirectDisplayID] = [:]
        for (index, configID) in runningIDsInOrder.enumerated() {
            map[configID] = index == 0 ? CGMainDisplayID() : CGDirectDisplayID(10_000 + index)
        }
        return map
    }
}
