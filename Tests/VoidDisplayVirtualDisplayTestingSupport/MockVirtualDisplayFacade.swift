import CoreGraphics
import Foundation
import VoidDisplayFoundation
import VoidDisplayVirtualDisplay

@MainActor
final class MockVirtualDisplayFacade: VirtualDisplayFacade {
    var currentDisplayConfigs: [VirtualDisplayConfig] = []
    var currentRunningConfigIds: Set<UUID> = []
    var currentRestoreFailures: [VirtualDisplayRestoreFailure] = []
    var runtimeDisplayIDByConfigId: [UUID: CGDirectDisplayID] = [:]
    var configStoreState: VirtualDisplayConfigRepositoryState = .ready(
        diagnostics: .init(
            primaryStoreURL: URL(fileURLWithPath: "/tmp/mock-virtual-displays.json"),
            isTestIsolatedPath: true
        )
    )

    var loadPersistedConfigsCallCount = 0
    private var cachedStartupConfigLoadResult: VirtualDisplayStartupRestoreConfigLoadResult?
    var startupRestoreCommandRequests: [VirtualDisplayStartupRestoreCommandRequest] = []
    var startupConfigLoadResult: VirtualDisplayStartupRestoreConfigLoadResult?
    var startupRestoreCommandResultsByConfigID: [UUID: VirtualDisplayStartupRestoreCommandResult] = [:]
    var clearRestoreFailuresCallCount = 0
    var resetAllVirtualDisplayDataCallCount = 0
    var createDisplayResult: Result<UUID, Error> = .failure(
        NSError(domain: "MockVirtualDisplayFacade", code: 1)
    )
    var createDisplayCommandCallCount = 0
    var createDisplayCommandSerialNumbers: [UInt32] = []
    var applyModesCallCount = 0
    var applyModesConfigIds: [UUID] = []
    var rebuildVirtualDisplayCallCount = 0
    var rebuildVirtualDisplayConfigIds: [UUID] = []
    var rebuildVirtualDisplayError: Error?
    var rebuildDelayNanoseconds: UInt64 = 0
    var disableRuntimeDisplayByConfigCallCount = 0
    var disableRuntimeDisplayByConfigIDs: [UUID] = []
    var disableRuntimeDisplayByConfigError: Error?
    var enableRuntimeDisplayCallCount = 0
    var enableRuntimeDisplayConfigIDs: [UUID] = []
    var enableRuntimeDisplayError: Error?
    var setDesiredEnabledCallCount = 0
    var setDesiredEnabledRequests: [(UUID, Bool)] = []
    var setDesiredEnabledError: Error?
    var destroyDisplayByConfigCallCount = 0
    var destroyedConfigIDs: [UUID] = []
    var destroyDisplayError: Error?
    var updateConfigCallCount = 0
    var updateConfigError: Error?
    var saveConfigForRebuildError: Error?
    var restoreConfigAfterFailedEditError: Error?
    var moveConfigError: Error?
    var resetAllVirtualDisplayDataError: Error?
    var reconcileMainDisplayPolicyIfNeededCallCount = 0
    var reconcileMainDisplayPolicyIfNeededError: Error?
    var moveConfigResult = false
    var configForEditRebuildCallCount = 0
    var configForEditRebuildIDs: [UUID] = []
    var saveConfigForRebuildCallCount = 0
    var savedConfigForRebuildIDs: [UUID] = []
    var restoreConfigAfterFailedEditCallCount = 0
    var restoredConfigAfterFailedEditIDs: [UUID] = []

    var configStorePresentation: VirtualDisplayConfigStorePresentation {
        switch configStoreState {
        case .ready(let diagnostics):
            .init(
                hasLoadFailure: false,
                loadErrorMessage: nil,
                diagnosticsSummary: diagnostics.summary
            )
        case .loadFailed(let error, let diagnostics):
            .init(
                hasLoadFailure: true,
                loadErrorMessage: error.userFacingMessage,
                diagnosticsSummary: diagnostics.summary
            )
        }
    }

    var snapshot: VirtualDisplaySnapshot {
        let managedDisplays: [ManagedVirtualDisplayRuntimeSnapshot] = currentDisplayConfigs.compactMap { config in
            guard let displayID = runtimeDisplayIDByConfigId[config.id] else { return nil }
            return ManagedVirtualDisplayRuntimeSnapshot(
                configId: config.id,
                serialNum: config.serialNum,
                displayID: displayID,
                isLiveRuntime: currentRunningConfigIds.contains(config.id)
            )
        }
        return VirtualDisplaySnapshot(
            managedDisplays: managedDisplays,
            configs: currentDisplayConfigs,
            runningConfigIds: currentRunningConfigIds,
            restoreFailures: currentRestoreFailures,
            configStorePresentation: configStorePresentation,
            runtimeDisplayIDByConfigId: runtimeDisplayIDByConfigId
        )
    }

    func loadPersistedVirtualDisplayConfigsForStartupRestoreCommand() -> VirtualDisplayStartupRestoreConfigLoadResult {
        if let cachedStartupConfigLoadResult {
            return cachedStartupConfigLoadResult
        }
        loadPersistedConfigsCallCount += 1
        let result = startupConfigLoadResult ?? .succeeded(configs: currentDisplayConfigs)
        cachedStartupConfigLoadResult = result
        return result
    }

    func restoreVirtualDisplayForStartupCommand(
        _ request: VirtualDisplayStartupRestoreCommandRequest
    ) -> VirtualDisplayStartupRestoreCommandResult {
        startupRestoreCommandRequests.append(request)
        if let result = startupRestoreCommandResultsByConfigID[request.configID] {
            return result
        }
        let preDisplayID = runtimeDisplayIDByConfigId[request.configID]
        guard let config = currentDisplayConfigs.first(where: { $0.id == request.configID }) else {
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
        currentRunningConfigIds.insert(config.id)
        return startupRestoreCommandResult(
            request: request,
            preDisplayID: preDisplayID,
            postDisplayID: runtimeDisplayIDByConfigId[request.configID],
            restoreOutcome: .succeeded,
            didProduceVerifiableSideEffect: true,
            failureReason: nil
        )
    }

    func clearRestoreFailures() {
        clearRestoreFailuresCallCount += 1
        currentRestoreFailures = []
    }

    @discardableResult
    func resetAllVirtualDisplayData() throws -> Int {
        resetAllVirtualDisplayDataCallCount += 1
        if let resetAllVirtualDisplayDataError {
            throw resetAllVirtualDisplayDataError
        }
        let removed = currentDisplayConfigs.count
        currentDisplayConfigs = []
        currentRunningConfigIds = []
        currentRestoreFailures = []
        runtimeDisplayIDByConfigId = [:]
        cachedStartupConfigLoadResult = .succeeded(configs: [])
        return removed
    }

    @discardableResult
    func createDisplayCommand(
        name: String,
        serialNum: UInt32,
        physicalSize: CGSize,
        maxPixels: (width: UInt32, height: UInt32),
        modes: [ResolutionSelection]
    ) throws -> VirtualDisplayCreateCommandResult {
        createDisplayCommandCallCount += 1
        createDisplayCommandSerialNumbers.append(serialNum)
        do {
            let configID = try createDisplayResult.get()
            return VirtualDisplayCreateCommandResult(
                createdConfigID: configID,
                persistenceOutcome: .saved,
                runtimeCreationOutcome: .succeeded,
                rollbackOutcome: .notAttempted
            )
        } catch {
            let result = VirtualDisplayCreateCommandResult(
                createdConfigID: nil,
                persistenceOutcome: .failed,
                runtimeCreationOutcome: .notAttempted,
                rollbackOutcome: .notAttempted
            )
            throw VirtualDisplayCreateCommandFailure(
                reason: "config_append_failed",
                result: result,
                underlyingError: error
            )
        }
    }

    func setDesiredEnabled(_ configId: UUID, enabled: Bool) throws {
        setDesiredEnabledCallCount += 1
        setDesiredEnabledRequests.append((configId, enabled))
        if let setDesiredEnabledError {
            throw setDesiredEnabledError
        }
        guard let index = currentDisplayConfigs.firstIndex(where: { $0.id == configId }) else { return }
        currentDisplayConfigs[index].desiredEnabled = enabled
        refreshCachedStartupConfigLoadResult()
    }

    func enableDisplayPreflight(_ configId: UUID) -> VirtualDisplayEnablePreflight {
        VirtualDisplayEnablePreflight(
            configID: configId,
            targetPreDisplayID: runtimeDisplayIDByConfigId[configId],
            mayPerformFleetRebuild: false,
            requiresFleetQuiesce: false,
            scopeEscalationReason: nil
        )
    }

    func enableRuntimeDisplay(_ configId: UUID) async throws -> VirtualDisplayLifecycleCommandResult {
        enableRuntimeDisplayCallCount += 1
        enableRuntimeDisplayConfigIDs.append(configId)
        if let enableRuntimeDisplayError {
            throw enableRuntimeDisplayError
        }
        currentRunningConfigIds.insert(configId)
        let postDisplayID = runtimeDisplayIDByConfigId[configId]
        return VirtualDisplayLifecycleCommandResult(
            configID: configId,
            desiredEnabled: true,
            preDisplayID: postDisplayID,
            postDisplayID: postDisplayID,
            mayPerformFleetRebuild: false,
            requiresFleetQuiesce: false
        )
    }

    func disableRuntimeDisplayByConfig(_ configId: UUID) throws -> VirtualDisplayLifecycleCommandResult {
        disableRuntimeDisplayByConfigCallCount += 1
        disableRuntimeDisplayByConfigIDs.append(configId)
        if let disableRuntimeDisplayByConfigError {
            throw disableRuntimeDisplayByConfigError
        }
        let preDisplayID = runtimeDisplayIDByConfigId[configId]
        currentRunningConfigIds.remove(configId)
        runtimeDisplayIDByConfigId[configId] = nil
        return VirtualDisplayLifecycleCommandResult(
            configID: configId,
            desiredEnabled: false,
            preDisplayID: preDisplayID,
            postDisplayID: nil,
            mayPerformFleetRebuild: false,
            requiresFleetQuiesce: false
        )
    }

    func deleteDisplayCommand(_ configId: UUID) throws -> VirtualDisplayDeleteCommandResult {
        destroyDisplayByConfigCallCount += 1
        guard currentDisplayConfigs.contains(where: { $0.id == configId }) else {
            let result = VirtualDisplayDeleteCommandResult(
                configID: configId,
                targetWasRunning: currentRunningConfigIds.contains(configId),
                preDisplayID: runtimeDisplayIDByConfigId[configId],
                postDisplayID: runtimeDisplayIDByConfigId[configId],
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
        destroyedConfigIDs.append(configId)
        if let destroyDisplayError {
            let result = VirtualDisplayDeleteCommandResult(
                configID: configId,
                targetWasRunning: currentRunningConfigIds.contains(configId),
                preDisplayID: runtimeDisplayIDByConfigId[configId],
                postDisplayID: runtimeDisplayIDByConfigId[configId],
                persistenceOutcome: .failed,
                virtualDisplayCommandOutcome: .failed,
                runtimeTrackingClearOutcome: .notAttempted
            )
            throw VirtualDisplayDeleteCommandFailure(
                reason: "config_delete_failed",
                result: result,
                underlyingError: destroyDisplayError
            )
        }
        let preDisplayID = runtimeDisplayIDByConfigId[configId]
        let targetWasRunning = currentRunningConfigIds.contains(configId) || preDisplayID != nil
        currentDisplayConfigs.removeAll { $0.id == configId }
        currentRunningConfigIds.remove(configId)
        runtimeDisplayIDByConfigId[configId] = nil
        refreshCachedStartupConfigLoadResult()
        return VirtualDisplayDeleteCommandResult(
            configID: configId,
            targetWasRunning: targetWasRunning,
            preDisplayID: preDisplayID,
            postDisplayID: nil,
            persistenceOutcome: .saved,
            virtualDisplayCommandOutcome: .succeeded,
            runtimeTrackingClearOutcome: .cleared
        )
    }

    func updateConfig(_ updated: VirtualDisplayConfig) throws {
        updateConfigCallCount += 1
        if let updateConfigError {
            throw updateConfigError
        }
        guard let index = currentDisplayConfigs.firstIndex(where: { $0.id == updated.id }) else { return }
        currentDisplayConfigs[index] = updated
        refreshCachedStartupConfigLoadResult()
    }

    func configForEditRebuild(_ configId: UUID) -> VirtualDisplayConfig? {
        configForEditRebuildCallCount += 1
        configForEditRebuildIDs.append(configId)
        return currentDisplayConfigs.first { $0.id == configId }
    }

    func saveConfigForRebuild(_ updated: VirtualDisplayConfig) throws {
        saveConfigForRebuildCallCount += 1
        savedConfigForRebuildIDs.append(updated.id)
        if let saveConfigForRebuildError {
            throw saveConfigForRebuildError
        }
        guard let index = currentDisplayConfigs.firstIndex(where: { $0.id == updated.id }) else { return }
        currentDisplayConfigs[index] = updated
        refreshCachedStartupConfigLoadResult()
    }

    func restoreConfigAfterFailedEdit(_ previous: VirtualDisplayConfig) throws {
        restoreConfigAfterFailedEditCallCount += 1
        restoredConfigAfterFailedEditIDs.append(previous.id)
        if let restoreConfigAfterFailedEditError {
            throw restoreConfigAfterFailedEditError
        }
        guard let index = currentDisplayConfigs.firstIndex(where: { $0.id == previous.id }) else { return }
        currentDisplayConfigs[index] = previous
        refreshCachedStartupConfigLoadResult()
    }

    func moveConfig(_ configId: UUID, direction: VirtualDisplayReorderDirection) throws -> Bool {
        if let moveConfigError {
            throw moveConfigError
        }
        guard moveConfigResult else { return false }
        guard let index = currentDisplayConfigs.firstIndex(where: { $0.id == configId }) else {
            return false
        }
        let destinationIndex: Int
        switch direction {
        case .up:
            destinationIndex = index - 1
        case .down:
            destinationIndex = index + 1
        }
        guard currentDisplayConfigs.indices.contains(destinationIndex) else {
            return false
        }
        currentDisplayConfigs.swapAt(index, destinationIndex)
        refreshCachedStartupConfigLoadResult()
        return true
    }

    @discardableResult
    func moveConfigToFirstEnabledPosition(_ configId: UUID) throws -> Bool {
        guard moveConfigResult else { return false }
        guard let sourceIndex = currentDisplayConfigs.firstIndex(where: { $0.id == configId }) else {
            return false
        }
        guard currentDisplayConfigs[sourceIndex].desiredEnabled else {
            return false
        }
        guard let firstEnabledIndex = currentDisplayConfigs.firstIndex(where: \.desiredEnabled) else {
            return false
        }
        guard sourceIndex != firstEnabledIndex else {
            return false
        }
        let config = currentDisplayConfigs.remove(at: sourceIndex)
        currentDisplayConfigs.insert(config, at: firstEnabledIndex)
        refreshCachedStartupConfigLoadResult()
        return true
    }

    func applyModes(configId: UUID, modes: [ResolutionSelection]) {
        applyModesCallCount += 1
        applyModesConfigIds.append(configId)
    }

    func rebuildVirtualDisplay(configId: UUID) async throws {
        rebuildVirtualDisplayCallCount += 1
        rebuildVirtualDisplayConfigIds.append(configId)
        if rebuildDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: rebuildDelayNanoseconds)
        }
        if let rebuildVirtualDisplayError {
            throw rebuildVirtualDisplayError
        }
    }

    func reconcileMainDisplayPolicyIfNeeded() async throws {
        reconcileMainDisplayPolicyIfNeededCallCount += 1
        if let reconcileMainDisplayPolicyIfNeededError {
            throw reconcileMainDisplayPolicyIfNeededError
        }
    }

    func nextAvailableSerialNumber() -> UInt32 {
        1
    }

    private func refreshCachedStartupConfigLoadResult() {
        guard cachedStartupConfigLoadResult != nil else { return }
        cachedStartupConfigLoadResult = .succeeded(configs: currentDisplayConfigs)
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
