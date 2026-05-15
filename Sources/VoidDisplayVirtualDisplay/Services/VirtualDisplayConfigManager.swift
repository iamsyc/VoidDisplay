import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import OSLog

/// Owns the virtual display configuration collection — CRUD, reordering, serial allocation, and persistence.
@MainActor
package final class VirtualDisplayConfigManager {
    package let configRepository: VirtualDisplayConfigRepository

    private var configs: [VirtualDisplayConfig] = []
    private var restoreFailures: [VirtualDisplayRestoreFailure] = []

    /// Called to resolve active serial numbers from the runtime tracker for serial allocation.
    private let activeSerialNumbersProvider: () -> Set<UInt32>

    package init(
        configRepository: VirtualDisplayConfigRepository,
        activeSerialNumbersProvider: @escaping () -> Set<UInt32> = { [] }
    ) {
        self.configRepository = configRepository
        self.activeSerialNumbersProvider = activeSerialNumbersProvider
    }

    // MARK: - Store presentation

    package var configStoreState: VirtualDisplayConfigRepositoryState {
        configRepository.state
    }

    package var configStorePresentation: VirtualDisplayConfigStorePresentation {
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

    package func allConfigs() -> [VirtualDisplayConfig] {
        configs
    }

    package func enabledDesiredConfigs() -> [VirtualDisplayConfig] {
        configs.filter(\.desiredEnabled)
    }

    package func restoreFailureList() -> [VirtualDisplayRestoreFailure] {
        restoreFailures
    }

    @discardableResult
    package func loadPersistedConfigs() -> VirtualDisplayStartupRestoreConfigLoadResult {
        switch configRepository.load() {
        case .success(let loaded):
            configs = loaded
            AppLog.virtualDisplay.notice(
                "Virtual display config load succeeded (\(self.configRepository.diagnosticsSummary, privacy: .public), configCount: \(loaded.count, privacy: .public))."
            )
            return .succeeded(configs: loaded.map(VirtualDisplayStartupRestoreConfig.init(config:)))
        case .failure(let error):
            configs = []
            restoreFailures = []
            AppLog.virtualDisplay.error(
                "Virtual display config load failed (\(self.configRepository.diagnosticsSummary, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
            let nsError = error as NSError
            return .failed(
                reason: "startup_persisted_config_load_failed",
                underlyingDomain: nsError.domain,
                underlyingCode: nsError.code
            )
        }
    }

    package func clearRestoreFailures() {
        restoreFailures = []
    }

    package func setRestoreFailures(_ failures: [VirtualDisplayRestoreFailure]) {
        restoreFailures = failures
    }

    package func resetAll() throws {
        try configRepository.reset()
        configs.removeAll()
        restoreFailures.removeAll()
    }

    // MARK: - CRUD

    package func config(id configId: UUID) -> VirtualDisplayConfig? {
        configs.first { $0.id == configId }
    }

    package func appendConfig(_ config: VirtualDisplayConfig) throws {
        try mutateConfigs(reason: .userCreatedConfig) { candidate in
            candidate.append(config)
        }
    }

    package func removeConfig(_ configId: UUID) throws {
        guard configs.contains(where: { $0.id == configId }) else { return }
        try mutateConfigs(reason: .userDeletedConfig) { candidate in
            candidate.removeAll { $0.id == configId }
        }
    }

    /// Removes the config that was just appended on creation failure rollback.
    package func rollbackAppendedConfig(_ configId: UUID) throws {
        try removeConfig(configId)
    }

    package func updateConfig(_ updated: VirtualDisplayConfig) throws {
        guard let index = configs.firstIndex(where: { $0.id == updated.id }) else {
            throw VirtualDisplayOperationError.configNotFound
        }
        try mutateConfigs(reason: .userEditedConfig) { candidate in
            candidate[index] = updated
        }
    }

    // MARK: - Desired enabled state

    package func setDesiredEnabled(
        _ configId: UUID,
        enabled: Bool,
        reason: VirtualDisplayConfigRepository.PersistReason
    ) throws {
        guard let index = configs.firstIndex(where: { $0.id == configId }) else {
            throw VirtualDisplayOperationError.configNotFound
        }
        try mutateConfigs(reason: reason) { candidate in
            var updated = candidate[index]
            updated.desiredEnabled = enabled
            candidate[index] = updated
        }
    }

    package func markDesiredDisabledBySerial(_ serialNum: UInt32) -> Bool {
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
    package func moveConfig(_ configId: UUID, direction: VirtualDisplayReorderDirection) throws -> Bool {
        guard let sourceIndex = configs.firstIndex(where: { $0.id == configId }) else { return false }

        let destinationIndex: Int
        switch direction {
        case .up:
            destinationIndex = sourceIndex - 1
        case .down:
            destinationIndex = sourceIndex + 1
        }

        guard configs.indices.contains(destinationIndex) else { return false }

        try mutateConfigs(reason: .userReorderedConfigs) { candidate in
            candidate.swapAt(sourceIndex, destinationIndex)
        }
        return true
    }

    @discardableResult
    package func moveConfigToFirstEnabledPosition(_ configId: UUID) throws -> Bool {
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

        try mutateConfigs(reason: .userReorderedConfigs) { candidate in
            let config = candidate.remove(at: sourceIndex)
            candidate.insert(config, at: firstEnabledIndex)
        }
        return true
    }

    // MARK: - Serial number

    package func nextAvailableSerialNumber() -> UInt32 {
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

    package func persistConfigs(reason: VirtualDisplayConfigRepository.PersistReason) throws {
        try configRepository.save(configs, reason: reason)
    }

    private func mutateConfigs(
        reason: VirtualDisplayConfigRepository.PersistReason,
        _ mutation: (inout [VirtualDisplayConfig]) throws -> Void
    ) throws {
        var candidate = configs
        try mutation(&candidate)
        try configRepository.save(candidate, reason: reason)
        configs = candidate
    }

}

private extension VirtualDisplayStartupRestoreConfig {
    init(config: VirtualDisplayConfig) {
        self.init(
            id: config.id,
            desiredEnabled: config.desiredEnabled,
            evidence: VirtualDisplayCommandConfigEvidence(config: config)
        )
    }
}

private extension VirtualDisplayCommandConfigEvidence {
    init(config: VirtualDisplayConfig) {
        let maxPixels = config.maxPixelDimensions
        self.init(
            id: config.id,
            serialNumber: config.serialNum,
            desiredEnabled: config.desiredEnabled,
            physicalWidthMillimeters: UInt32(clamping: config.physicalWidth),
            physicalHeightMillimeters: UInt32(clamping: config.physicalHeight),
            modeCount: config.modes.count,
            maximumPixelWidth: maxPixels.width,
            maximumPixelHeight: maxPixels.height
        )
    }
}
