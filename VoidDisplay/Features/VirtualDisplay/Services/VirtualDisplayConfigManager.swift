import Foundation
import CoreGraphics
import OSLog

/// Owns the virtual display configuration collection — CRUD, reordering, serial allocation, and persistence.
@MainActor
final class VirtualDisplayConfigManager {
    let configRepository: VirtualDisplayConfigRepository

    private var configs: [VirtualDisplayConfig] = []
    private var restoreFailures: [VirtualDisplayRestoreFailure] = []

    /// Called to resolve active serial numbers from the runtime tracker for serial allocation.
    private let activeSerialNumbersProvider: () -> Set<UInt32>

    init(
        configRepository: VirtualDisplayConfigRepository? = nil,
        activeSerialNumbersProvider: @escaping () -> Set<UInt32> = { [] }
    ) {
        self.configRepository = configRepository ?? VirtualDisplayConfigRepository()
        self.activeSerialNumbersProvider = activeSerialNumbersProvider
    }

    // MARK: - Store presentation

    var configStoreState: VirtualDisplayConfigRepositoryState {
        configRepository.state
    }

    var configStorePresentation: VirtualDisplayConfigStorePresentation {
        .init(
            hasLoadFailure: {
                if case .loadFailed = configStoreState { return true }
                return false
            }(),
            loadErrorMessage: configRepository.loadFailureMessage,
            diagnosticsSummary: configRepository.diagnosticsSummary
        )
    }

    // MARK: - Load / Restore / Reset

    func allConfigs() -> [VirtualDisplayConfig] {
        configs
    }

    func enabledDesiredConfigs() -> [VirtualDisplayConfig] {
        configs.filter(\.desiredEnabled)
    }

    func restoreFailureList() -> [VirtualDisplayRestoreFailure] {
        restoreFailures
    }

    func loadPersistedConfigs() {
        switch configRepository.load() {
        case .success(let loaded):
            configs = loaded
            AppLog.virtualDisplay.notice(
                "Virtual display config load succeeded (\(self.configRepository.diagnosticsSummary, privacy: .public), configCount: \(loaded.count, privacy: .public))."
            )
        case .failure(let error):
            configs = []
            restoreFailures = []
            AppLog.virtualDisplay.error(
                "Virtual display config load failed (\(self.configRepository.diagnosticsSummary, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
        }
    }

    func clearRestoreFailures() {
        restoreFailures = []
    }

    func setRestoreFailures(_ failures: [VirtualDisplayRestoreFailure]) {
        restoreFailures = failures
    }

    func resetAll() {
        configs.removeAll()
        restoreFailures.removeAll()
        _ = configRepository.reset()
    }

    // MARK: - CRUD

    func config(id configId: UUID) -> VirtualDisplayConfig? {
        configs.first { $0.id == configId }
    }

    func config(for display: CGVirtualDisplay) -> VirtualDisplayConfig? {
        configs.first { $0.serialNum == display.serialNum }
    }

    func configIndex(id configId: UUID) -> Int? {
        configs.firstIndex(where: { $0.id == configId })
    }

    func appendConfig(_ config: VirtualDisplayConfig) {
        configs.append(config)
        persistConfigs(reason: .userCreatedConfig)
    }

    func removeConfig(_ configId: UUID) {
        configs.removeAll { $0.id == configId }
        persistConfigs(reason: .userDeletedConfig)
    }

    func removeConfig(serialNum: UInt32) {
        configs.removeAll { $0.serialNum == serialNum }
        persistConfigs(reason: .userDeletedConfig)
    }

    /// Removes the config that was just appended on creation failure rollback.
    func rollbackAppendedConfig(_ configId: UUID) {
        configs.removeAll { $0.id == configId }
        persistConfigs(reason: .userDeletedConfig)
    }

    func updateConfig(_ updated: VirtualDisplayConfig) {
        guard let index = configs.firstIndex(where: { $0.id == updated.id }) else { return }
        configs[index] = updated
        persistConfigs(reason: .userEditedConfig)
    }

    func updateConfig(for display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        guard let index = configs.firstIndex(where: { $0.serialNum == display.serialNum }) else { return }
        var updated = configs[index]
        updated.modes = modes.map {
            VirtualDisplayConfig.ModeConfig(
                width: $0.width,
                height: $0.height,
                refreshRate: $0.refreshRate,
                enableHiDPI: $0.enableHiDPI
            )
        }
        configs[index] = updated
        persistConfigs(reason: .runtimeRebuildRecovery)
    }

    // MARK: - Desired enabled state

    func setDesiredEnabled(
        _ configId: UUID,
        enabled: Bool,
        reason: VirtualDisplayConfigRepository.PersistReason
    ) {
        guard let index = configs.firstIndex(where: { $0.id == configId }) else { return }
        var updated = configs[index]
        updated.desiredEnabled = enabled
        configs[index] = updated
        persistConfigs(reason: reason)
    }

    func markDesiredDisabledBySerial(_ serialNum: UInt32) -> Bool {
        guard let index = configs.firstIndex(where: { $0.serialNum == serialNum }) else {
            return false
        }
        var updated = configs[index]
        updated.desiredEnabled = false
        configs[index] = updated
        return true
    }

    // MARK: - Reorder

    @discardableResult
    func moveConfig(_ configId: UUID, direction: VirtualDisplayReorderDirection) -> Bool {
        guard let sourceIndex = configs.firstIndex(where: { $0.id == configId }) else { return false }

        let destinationIndex: Int
        switch direction {
        case .up:
            destinationIndex = sourceIndex - 1
        case .down:
            destinationIndex = sourceIndex + 1
        }

        guard configs.indices.contains(destinationIndex) else { return false }

        configs.swapAt(sourceIndex, destinationIndex)
        persistConfigs(reason: .userReorderedConfigs)
        return true
    }

    @discardableResult
    func moveConfigToFirstEnabledPosition(_ configId: UUID) -> Bool {
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
        persistConfigs(reason: .userReorderedConfigs)
        return true
    }

    // MARK: - Serial number

    func nextAvailableSerialNumber() -> UInt32 {
        let activeNumbers = activeSerialNumbersProvider()
        let configNumbers = Set(configs.map { $0.serialNum })
        let usedNumbers = activeNumbers.union(configNumbers)

        var next: UInt32 = 1
        while usedNumbers.contains(next) {
            next += 1
        }
        return next
    }

    // MARK: - Persistence

    func persistConfigs(reason: VirtualDisplayConfigRepository.PersistReason) {
        _ = configRepository.save(configs, reason: reason)
    }

}
