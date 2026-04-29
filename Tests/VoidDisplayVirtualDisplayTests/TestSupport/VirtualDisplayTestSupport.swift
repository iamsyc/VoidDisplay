@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayFoundation
import CoreGraphics
import Foundation

@MainActor
final class MockCaptureMonitoringService {
    var removeByDisplayCallCount = 0
    var removedDisplayIDs: [CGDirectDisplayID] = []

    func removeMonitoringSessions(displayID: CGDirectDisplayID) {
        removeByDisplayCallCount += 1
        removedDisplayIDs.append(displayID)
    }
}

@MainActor
final class MockSharingService {
    var activeSharingDisplayIDs: Set<CGDirectDisplayID> = []
    var stopSharingCallCount = 0

    func stopSharing(displayID: CGDirectDisplayID) {
        stopSharingCallCount += 1
        activeSharingDisplayIDs.remove(displayID)
    }
}

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
    var restoreDesiredVirtualDisplaysCallCount = 0
    var clearRestoreFailuresCallCount = 0
    var resetAllVirtualDisplayDataCallCount = 0
    var createDisplayResult: Result<UUID, Error> = .failure(
        NSError(domain: "MockVirtualDisplayFacade", code: 1)
    )
    var applyModesCallCount = 0
    var applyModesConfigIds: [UUID] = []
    var rebuildVirtualDisplayCallCount = 0
    var rebuildVirtualDisplayConfigIds: [UUID] = []
    var rebuildVirtualDisplayError: Error?
    var rebuildDelayNanoseconds: UInt64 = 0
    var disableDisplayByConfigCallCount = 0
    var disableDisplayByConfigIDs: [UUID] = []
    var disableDisplayByConfigError: Error?
    var enableDisplayCallCount = 0
    var enableDisplayConfigIDs: [UUID] = []
    var enableDisplayError: Error?
    var destroyDisplayByConfigCallCount = 0
    var destroyedConfigIDs: [UUID] = []
    var destroyDisplayError: Error?
    var updateConfigError: Error?
    var moveConfigError: Error?
    var moveConfigToFirstEnabledPositionError: Error?
    var resetAllVirtualDisplayDataError: Error?
    var reconcileMainDisplayPolicyIfNeededCallCount = 0
    var reconcileMainDisplayPolicyIfNeededError: Error?
    var moveConfigResult = false
    var moveConfigToFirstEnabledPositionCallCount = 0
    var moveConfigToFirstEnabledPositionIDs: [UUID] = []

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

    func loadPersistedConfigs() {
        loadPersistedConfigsCallCount += 1
    }

    func restoreDesiredVirtualDisplays() {
        restoreDesiredVirtualDisplaysCallCount += 1
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
        try createDisplayResult.get()
    }

    func disableDisplayByConfig(_ configId: UUID) throws {
        disableDisplayByConfigCallCount += 1
        disableDisplayByConfigIDs.append(configId)
        if let disableDisplayByConfigError {
            throw disableDisplayByConfigError
        }
    }

    func enableDisplay(_ configId: UUID) async throws {
        enableDisplayCallCount += 1
        enableDisplayConfigIDs.append(configId)
        if let enableDisplayError {
            throw enableDisplayError
        }
    }

    func destroyDisplay(_ configId: UUID) throws {
        destroyDisplayByConfigCallCount += 1
        destroyedConfigIDs.append(configId)
        if let destroyDisplayError {
            throw destroyDisplayError
        }
        currentDisplayConfigs.removeAll { $0.id == configId }
        currentRunningConfigIds.remove(configId)
        runtimeDisplayIDByConfigId[configId] = nil
    }

    func updateConfig(_ updated: VirtualDisplayConfig) throws {
        if let updateConfigError {
            throw updateConfigError
        }
        guard let index = currentDisplayConfigs.firstIndex(where: { $0.id == updated.id }) else { return }
        currentDisplayConfigs[index] = updated
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
        return true
    }

    @discardableResult
    func moveConfigToFirstEnabledPosition(_ configId: UUID) throws -> Bool {
        moveConfigToFirstEnabledPositionCallCount += 1
        moveConfigToFirstEnabledPositionIDs.append(configId)
        if let moveConfigToFirstEnabledPositionError {
            throw moveConfigToFirstEnabledPositionError
        }
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
}

final class FakeVirtualDisplayStore: VirtualDisplayStoring {
    var loadCallCount = 0
    var saveCallCount = 0
    var resetCallCount = 0

    var loadError: Error?
    var saveError: Error?
    var scriptedSaveErrors: [Error?] = []
    var resetError: Error?
    var diagnosticsError: Error?

    // If provided, load() returns this value instead of the last saved snapshot.
    var nextLoadConfigs: [VirtualDisplayConfig]?
    var savedConfigs: [[VirtualDisplayConfig]] = []
    var diagnosticsValue = VirtualDisplayStoreDiagnostics(
        primaryStoreURL: URL(fileURLWithPath: "/tmp/fake-virtual-displays.json"),
        isTestIsolatedPath: true
    )

    func load() throws -> [VirtualDisplayConfig] {
        loadCallCount += 1
        if let loadError {
            throw loadError
        }
        return nextLoadConfigs ?? savedConfigs.last ?? []
    }

    func save(_ configs: [VirtualDisplayConfig]) throws {
        saveCallCount += 1
        if !scriptedSaveErrors.isEmpty {
            let scriptedError = scriptedSaveErrors.removeFirst()
            if let scriptedError {
                throw scriptedError
            }
            savedConfigs.append(configs)
            return
        }
        if let saveError {
            throw saveError
        }
        savedConfigs.append(configs)
    }

    func reset() throws {
        resetCallCount += 1
        if let resetError {
            throw resetError
        }
        savedConfigs.removeAll()
    }

    func diagnostics() throws -> VirtualDisplayStoreDiagnostics {
        if let diagnosticsError {
            throw diagnosticsError
        }
        return diagnosticsValue
    }
}

struct MockScreenCapturePermissionProvider: ScreenCapturePermissionProvider {
    let preflightResult: Bool
    let requestResult: Bool

    nonisolated func preflight() -> Bool {
        preflightResult
    }

    nonisolated func request() -> Bool {
        requestResult
    }
}
