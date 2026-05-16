import VoidDisplayObservability
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import CoreGraphics
import Foundation

@MainActor
package final class UITestVirtualDisplayFacade: VirtualDisplayFacade {
    private var configs: [VirtualDisplayConfig]
    private var runningConfigIds: Set<UUID>
    private var restoreFailures: [VirtualDisplayRestoreFailure] = []
    package var configStoreState: VirtualDisplayConfigRepositoryState = .ready(
        diagnostics: .init(
            primaryStoreURL: URL(fileURLWithPath: "/tmp/ui-test-virtual-displays.json"),
            isTestIsolatedPath: true
        )
    )

    package var configStorePresentation: VirtualDisplayConfigStorePresentation {
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

    package init(scenario: UITestScenario) {
        self.scenario = scenario
        let fixtureConfigs = UITestFixture.virtualDisplayConfigs()
        self.configs = fixtureConfigs
        self.runningConfigIds = Set(fixtureConfigs.prefix(1).map(\.id))
    }

    package func loadPersistedVirtualDisplayConfigsForStartupRestoreCommand() -> VirtualDisplayStartupRestoreConfigLoadResult {
        .succeeded(configs: configs)
    }

    package func restoreVirtualDisplayForStartupCommand(
        _ request: VirtualDisplayStartupRestoreCommandRequest
    ) -> VirtualDisplayStartupRestoreCommandResult {
        let preDisplayID = runtimeDisplayIDs()[request.configID]
        guard let config = configs.first(where: { $0.id == request.configID }) else {
            return startupRestoreCommandResult(
                request: request,
                preDisplayID: preDisplayID,
                postDisplayID: preDisplayID,
                restoreOutcome: .failed,
                didProduceVerifiableSideEffect: false,
                failureReason: "config_not_found"
            )
        }
        guard config.desiredEnabled else {
            return startupRestoreCommandResult(
                request: request,
                preDisplayID: preDisplayID,
                postDisplayID: preDisplayID,
                restoreOutcome: .notAttempted,
                didProduceVerifiableSideEffect: false,
                failureReason: "config_not_desired_enabled"
            )
        }
        runningConfigIds.insert(config.id)
        return startupRestoreCommandResult(
            request: request,
            preDisplayID: preDisplayID,
            postDisplayID: runtimeDisplayIDs()[request.configID],
            restoreOutcome: .succeeded,
            didProduceVerifiableSideEffect: true,
            failureReason: nil
        )
    }

    package var snapshot: VirtualDisplaySnapshot {
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

    package func clearRestoreFailures() {
        restoreFailures = []
    }

    @discardableResult
    package func resetAllVirtualDisplayData() throws -> Int {
        let removed = configs.count
        configs = []
        runningConfigIds = []
        restoreFailures = []
        return removed
    }

    @discardableResult
    package func createDisplayCommand(
        name: String,
        serialNum: UInt32,
        physicalSize: CGSize,
        maxPixels: (width: UInt32, height: UInt32),
        modes: [ResolutionSelection]
    ) throws -> VirtualDisplayCreateCommandResult {
        let result = VirtualDisplayCreateCommandResult(
            createdConfigID: nil,
            persistenceOutcome: .notAttempted,
            runtimeCreationOutcome: .failed,
            rollbackOutcome: .notAttempted
        )
        throw VirtualDisplayCreateCommandFailure(
            reason: "uitest_create_unavailable",
            result: result,
            underlyingError: VirtualDisplayOperationError.creationFailed
        )
    }

    package func setDesiredEnabled(_ configId: UUID, enabled: Bool) throws {
        guard let index = configs.firstIndex(where: { $0.id == configId }) else {
            throw VirtualDisplayOperationError.configNotFound
        }
        var updated = configs[index]
        updated.desiredEnabled = enabled
        configs[index] = updated
    }

    package func enableDisplayPreflight(_ configId: UUID) -> VirtualDisplayEnablePreflight {
        VirtualDisplayEnablePreflight(
            configID: configId,
            targetPreDisplayID: runtimeDisplayIDs()[configId],
            mayPerformFleetRebuild: false,
            requiresFleetQuiesce: false,
            scopeEscalationReason: nil
        )
    }

    package func enableRuntimeDisplay(_ configId: UUID) async throws -> VirtualDisplayLifecycleCommandResult {
        guard configs.contains(where: { $0.id == configId }) else {
            throw VirtualDisplayOperationError.configNotFound
        }
        runningConfigIds.remove(configId)
        runningConfigIds.insert(configId)
        let displayID = runtimeDisplayIDs()[configId]
        return VirtualDisplayLifecycleCommandResult(
            configID: configId,
            desiredEnabled: true,
            preDisplayID: displayID,
            postDisplayID: displayID,
            mayPerformFleetRebuild: false,
            requiresFleetQuiesce: false
        )
    }

    package func disableRuntimeDisplayByConfig(_ configId: UUID) throws -> VirtualDisplayLifecycleCommandResult {
        guard configs.contains(where: { $0.id == configId }) else {
            throw VirtualDisplayOperationError.configNotFound
        }
        let preDisplayID = runtimeDisplayIDs()[configId]
        runningConfigIds.remove(configId)
        return VirtualDisplayLifecycleCommandResult(
            configID: configId,
            desiredEnabled: false,
            preDisplayID: preDisplayID,
            postDisplayID: nil,
            mayPerformFleetRebuild: false,
            requiresFleetQuiesce: false
        )
    }

    package func deleteDisplayCommand(_ configId: UUID) throws -> VirtualDisplayDeleteCommandResult {
        let preDisplayID = runtimeDisplayIDs()[configId]
        guard configs.contains(where: { $0.id == configId }) else {
            let result = VirtualDisplayDeleteCommandResult(
                configID: configId,
                targetWasRunning: preDisplayID != nil,
            preDisplayID: preDisplayID,
            postDisplayID: preDisplayID,
            persistenceOutcome: .notAttempted,
            virtualDisplayCommandOutcome: .failed,
            runtimeTrackingClearOutcome: .notAttempted
        )
            throw VirtualDisplayDeleteCommandFailure(
                reason: "config_not_found",
                result: result,
                underlyingError: VirtualDisplayOperationError.configNotFound
            )
        }
        configs.removeAll { $0.id == configId }
        runningConfigIds.remove(configId)
        return VirtualDisplayDeleteCommandResult(
            configID: configId,
            targetWasRunning: preDisplayID != nil,
            preDisplayID: preDisplayID,
            postDisplayID: nil,
            persistenceOutcome: .saved,
            virtualDisplayCommandOutcome: .succeeded,
            runtimeTrackingClearOutcome: .cleared
        )
    }

    package func updateConfig(_ updated: VirtualDisplayConfig) throws {
        guard let index = configs.firstIndex(where: { $0.id == updated.id }) else { return }
        configs[index] = updated
    }

    package func configForEditRebuild(_ configId: UUID) -> VirtualDisplayConfig? {
        configs.first { $0.id == configId }
    }

    package func saveConfigForRebuild(_ updated: VirtualDisplayConfig) throws {
        try updateConfig(updated)
    }

    package func restoreConfigAfterFailedEdit(_ previous: VirtualDisplayConfig) throws {
        try updateConfig(previous)
    }

    package func moveConfig(_ configId: UUID, direction: VirtualDisplayReorderDirection) throws -> Bool {
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
        let config = configs.remove(at: sourceIndex)
        configs.insert(config, at: firstEnabledIndex)
        return true
    }

    package func applyModes(configId: UUID, modes: [ResolutionSelection]) {
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

    package func rebuildVirtualDisplay(configId: UUID) async throws {
        guard configs.contains(where: { $0.id == configId }) else {
            throw VirtualDisplayOperationError.configNotFound
        }
    }

    package func reconcileMainDisplayPolicyIfNeeded() async throws {}

    package func nextAvailableSerialNumber() -> UInt32 {
        let usedNumbers = Set(configs.map(\.serialNum))
        var next: UInt32 = 1
        while usedNumbers.contains(next) {
            next += 1
        }
        return next
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

    private func startupRestoreCommandResult(
        request: VirtualDisplayStartupRestoreCommandRequest,
        preDisplayID: CGDirectDisplayID?,
        postDisplayID: CGDirectDisplayID?,
        restoreOutcome: VirtualDisplayStartupRestoreCommandOutcome,
        didProduceVerifiableSideEffect: Bool,
        failureReason: String?
    ) -> VirtualDisplayStartupRestoreCommandResult {
        VirtualDisplayStartupRestoreCommandResult(
            transactionID: request.transactionID,
            configID: request.configID,
            preDisplayID: preDisplayID,
            postDisplayID: postDisplayID,
            restoreOutcome: restoreOutcome,
            didProduceVerifiableSideEffect: didProduceVerifiableSideEffect,
            failureReason: failureReason
        )
    }
}
