import CoreGraphics
import Foundation
import ScreenCaptureKit
@testable import VoidDisplay

@MainActor
final class MockCaptureMonitoringService: CaptureMonitoringServiceProtocol {
    var currentSessions: [ScreenMonitoringSession] = []
    var addCallCount = 0
    var removeCallCount = 0
    var removeByDisplayCallCount = 0
    var removedDisplayIDs: [CGDirectDisplayID] = []
    var updateStateCallCount = 0

    func monitoringSession(for id: UUID) -> ScreenMonitoringSession? {
        currentSessions.first(where: { $0.id == id })
    }

    func addMonitoringSession(_ session: ScreenMonitoringSession) {
        addCallCount += 1
        currentSessions.append(session)
    }

    func updateMonitoringSessionState(
        id: UUID,
        state: ScreenMonitoringSession.State
    ) {
        updateStateCallCount += 1
        guard let index = currentSessions.firstIndex(where: { $0.id == id }) else { return }
        currentSessions[index].state = state
    }

    func removeMonitoringSession(id: UUID) {
        removeCallCount += 1
        currentSessions.removeAll { $0.id == id }
    }

    func removeMonitoringSessions(displayID: CGDirectDisplayID) {
        removeByDisplayCallCount += 1
        removedDisplayIDs.append(displayID)
        currentSessions.removeAll { $0.displayID == displayID }
    }
}

@MainActor
final class MockSharingService: SharingServiceProtocol {
    var webServicePortValue: UInt16 = 8081
    var onWebServiceRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)?
    var isWebServiceRunning = false
    var activeStreamClientCount = 0
    var currentWebServer: WebServer?
    var hasAnyActiveSharing = false
    var activeSharingDisplayIDs: Set<CGDirectDisplayID> = []

    var startResult = true
    var startWebServiceCallCount = 0
    var stopWebServiceCallCount = 0
    var registerShareableDisplaysCallCount = 0
    var registeredShareableDisplays: [SCDisplay] = []
    var stopSharingCallCount = 0
    var stopAllSharingCallCount = 0
    var streamClientCountsByTarget: [ShareTarget: Int] = [:]
    var shareIDByDisplayID: [CGDirectDisplayID: UInt32] = [:]
    var shareTargetByDisplayID: [CGDirectDisplayID: ShareTarget] = [:]

    @discardableResult
    func startWebService() async -> Bool {
        startWebServiceCallCount += 1
        isWebServiceRunning = startResult
        onWebServiceRunningStateChanged?(isWebServiceRunning)
        return startResult
    }

    func stopWebService() {
        stopWebServiceCallCount += 1
        isWebServiceRunning = false
        onWebServiceRunningStateChanged?(false)
    }

    func registerShareableDisplays(
        _ displays: [SCDisplay],
        virtualSerialResolver: (CGDirectDisplayID) -> UInt32?
    ) {
        registerShareableDisplaysCallCount += 1
        registeredShareableDisplays = displays
        _ = virtualSerialResolver(CGDirectDisplayID(0))
    }

    func startSharing(
        displayID: CGDirectDisplayID,
        stream: SCStream,
        output: Capture,
        delegate: VoidDisplay.StreamDelegate
    ) {
        hasAnyActiveSharing = true
        activeSharingDisplayIDs.insert(displayID)
    }

    func stopSharing(displayID: CGDirectDisplayID) {
        stopSharingCallCount += 1
        activeSharingDisplayIDs.remove(displayID)
        hasAnyActiveSharing = !activeSharingDisplayIDs.isEmpty
    }

    func stopAllSharing() {
        stopAllSharingCallCount += 1
        activeSharingDisplayIDs.removeAll()
        hasAnyActiveSharing = false
    }

    func isSharing(displayID: CGDirectDisplayID) -> Bool {
        activeSharingDisplayIDs.contains(displayID)
    }

    func shareID(for displayID: CGDirectDisplayID) -> UInt32? {
        shareIDByDisplayID[displayID]
    }

    func shareTarget(for displayID: CGDirectDisplayID) -> ShareTarget? {
        shareTargetByDisplayID[displayID]
    }

    func streamClientCount(for target: ShareTarget) -> Int {
        streamClientCountsByTarget[target] ?? 0
    }
}

@MainActor
final class MockVirtualDisplayService: VirtualDisplayServiceProtocol {
    var currentDisplays: [CGVirtualDisplay] = []
    var currentDisplayConfigs: [VirtualDisplayConfig] = []
    var currentRunningConfigIds: Set<UUID> = []
    var currentRestoreFailures: [VirtualDisplayRestoreFailure] = []
    var runtimeDisplayIDByConfigId: [UUID: CGDirectDisplayID] = [:]
    var configStoreState: VirtualDisplayConfigRepositoryState = .ready(
        diagnostics: .init(
            primaryStoreURL: URL(fileURLWithPath: "/tmp/mock-virtual-displays.json"),
            legacyContainerStoreURL: nil,
            legacyContainerFileExists: false,
            isTestIsolatedPath: true
        )
    )

    var loadPersistedConfigsCallCount = 0
    var restoreDesiredVirtualDisplaysCallCount = 0
    var clearRestoreFailuresCallCount = 0
    var resetAllVirtualDisplayDataCallCount = 0
    var createDisplayResult: Result<CGVirtualDisplay, Error> = .failure(
        NSError(domain: "MockVirtualDisplayService", code: 1)
    )
    var createDisplayFromConfigResult: Result<CGVirtualDisplay, Error> = .failure(
        NSError(domain: "MockVirtualDisplayService", code: 2)
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
    func resetAllVirtualDisplayData() -> Int {
        resetAllVirtualDisplayDataCallCount += 1
        let removed = currentDisplayConfigs.count
        currentDisplayConfigs = []
        currentDisplays = []
        currentRunningConfigIds = []
        currentRestoreFailures = []
        return removed
    }

    func runtimeDisplay(for configId: UUID) -> CGVirtualDisplay? {
        nil
    }

    func runtimeDisplayID(for configId: UUID) -> CGDirectDisplayID? {
        runtimeDisplayIDByConfigId[configId]
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
        try createDisplayResult.get()
    }

    @discardableResult
    func createDisplayFromConfig(_ config: VirtualDisplayConfig) throws -> CGVirtualDisplay {
        try createDisplayFromConfigResult.get()
    }

    func disableDisplay(_ display: CGVirtualDisplay, modes: [ResolutionSelection]) {}

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

    func destroyDisplay(_ configId: UUID) {
        destroyDisplayByConfigCallCount += 1
        destroyedConfigIDs.append(configId)
        currentDisplayConfigs.removeAll { $0.id == configId }
        currentRunningConfigIds.remove(configId)
    }

    func destroyDisplay(_ display: CGVirtualDisplay) {}

    func getConfig(_ configId: UUID) -> VirtualDisplayConfig? {
        currentDisplayConfigs.first(where: { $0.id == configId })
    }

    func updateConfig(_ updated: VirtualDisplayConfig) {
        guard let index = currentDisplayConfigs.firstIndex(where: { $0.id == updated.id }) else { return }
        currentDisplayConfigs[index] = updated
    }

    func moveConfig(_ configId: UUID, direction: VirtualDisplayReorderDirection) -> Bool {
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
    func moveConfigToFirstEnabledPosition(_ configId: UUID) -> Bool {
        moveConfigToFirstEnabledPositionCallCount += 1
        moveConfigToFirstEnabledPositionIDs.append(configId)
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

    func getConfig(for display: CGVirtualDisplay) -> VirtualDisplayConfig? {
        currentDisplayConfigs.first(where: { $0.serialNum == display.serialNum })
    }

    func updateConfig(for display: CGVirtualDisplay, modes: [ResolutionSelection]) {}

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
    var resetError: Error?
    var diagnosticsError: Error?

    // If provided, load() returns this value instead of the last saved snapshot.
    var nextLoadConfigs: [VirtualDisplayConfig]?
    var savedConfigs: [[VirtualDisplayConfig]] = []
    var diagnosticsValue = VirtualDisplayStoreDiagnostics(
        primaryStoreURL: URL(fileURLWithPath: "/tmp/fake-virtual-displays.json"),
        legacyContainerStoreURL: URL(fileURLWithPath: "/tmp/legacy-virtual-displays.json"),
        legacyContainerFileExists: false,
        isTestIsolatedPath: true
    )

    // Backward-compatible aliases used by existing tests.
    var saves: [[VirtualDisplayConfig]] {
        get { savedConfigs }
        set { savedConfigs = newValue }
    }

    var resets: Int {
        get { resetCallCount }
        set { resetCallCount = newValue }
    }

    func load() throws -> [VirtualDisplayConfig] {
        loadCallCount += 1
        if let loadError {
            throw loadError
        }
        return nextLoadConfigs ?? savedConfigs.last ?? []
    }

    func save(_ configs: [VirtualDisplayConfig]) throws {
        saveCallCount += 1
        savedConfigs.append(configs)
        if let saveError {
            throw saveError
        }
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
