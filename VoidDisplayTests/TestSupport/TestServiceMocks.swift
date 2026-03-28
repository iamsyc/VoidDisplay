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
    var updateCapturesCursorCallCount = 0

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

    func updateMonitoringSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) {
        updateCapturesCursorCallCount += 1
        guard let index = currentSessions.firstIndex(where: { $0.id == id }) else { return }
        currentSessions[index].capturesCursor = capturesCursor
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
    typealias StartSharingHandler = @MainActor (SCDisplay) async throws -> DisplayStartOutcome<Void>

    var webServicePortValue: UInt16 = 8081
    var onWebServiceRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)?
    var onWebServiceLifecycleStateChanged: (@MainActor @Sendable (WebServiceLifecycleState) -> Void)?
    var webServiceLifecycleState: WebServiceLifecycleState = .stopped
    var isWebServiceRunning = false
    var activeStreamClientCount = 0
    var sharingStateSnapshot: SharingStateSnapshot = .empty
    var currentWebServer: WebServer?
    var hasAnyActiveSharing = false
    var activeSharingDisplayIDs: Set<CGDirectDisplayID> = []
    var startingDisplayIDs: Set<CGDirectDisplayID> = []

    var startResult: WebServiceStartResult = .started(
        WebServiceBinding(requestedPort: 8081, boundPort: 8081)
    )
    var lastStartRequestedPort: UInt16?
    var startWebServiceCallCount = 0
    var stopWebServiceCallCount = 0
    var registerShareableDisplaysCallCount = 0
    var registeredShareableDisplays: [SCDisplay] = []
    var stopSharingCallCount = 0
    var stopAllSharingCallCount = 0
    var streamClientCountsByTarget: [ShareTarget: Int] = [:]
    var shareIDByDisplayID: [CGDirectDisplayID: UInt32] = [:]
    var shareTargetByDisplayID: [CGDirectDisplayID: ShareTarget] = [:]
    var onStopSharing: (@MainActor @Sendable (CGDirectDisplayID) -> Void)?
    var startSharingHandler: StartSharingHandler?
    private var sharingStateObservers: [UUID: @MainActor @Sendable (SharingStateSnapshot) -> Void] = [:]

    func isStarting(displayID: CGDirectDisplayID) -> Bool {
        startingDisplayIDs.contains(displayID)
    }

    func subscribeSharingState(
        _ observer: @escaping @MainActor @Sendable (SharingStateSnapshot) -> Void
    ) -> SharingStateSubscription {
        let id = UUID()
        sharingStateObservers[id] = observer
        observer(sharingStateSnapshot)
        return SharingStateSubscription { [weak self] in
            self?.sharingStateObservers.removeValue(forKey: id)
        }
    }

    @discardableResult
    func startWebService(requestedPort: UInt16) async -> WebServiceStartResult {
        startWebServiceCallCount += 1
        lastStartRequestedPort = requestedPort
        switch startResult {
        case .started(let binding), .alreadyRunning(let binding):
            isWebServiceRunning = true
            webServicePortValue = binding.boundPort
            webServiceLifecycleState = .running(binding)
        case .failed:
            isWebServiceRunning = false
            webServiceLifecycleState = .failed(startResult.failure ?? .listenerFailed(port: requestedPort, message: "mock_failure"))
        }
        if sharingStateSnapshot == .empty && (activeStreamClientCount > 0 || !streamClientCountsByTarget.isEmpty) {
            sharingStateSnapshot = SharingStateSnapshot(
                signalingConnections: activeStreamClientCount,
                streamingPeers: activeStreamClientCount,
                signalingConnectionsByTarget: streamClientCountsByTarget,
                streamingPeersByTarget: streamClientCountsByTarget,
                clientsByTarget: [:],
                lastUpdatedAt: Date()
            )
        }
        onWebServiceRunningStateChanged?(isWebServiceRunning)
        onWebServiceLifecycleStateChanged?(webServiceLifecycleState)
        notifySharingStateObservers()
        return startResult
    }

    func stopWebService() {
        stopWebServiceCallCount += 1
        isWebServiceRunning = false
        webServiceLifecycleState = .stopped
        onWebServiceRunningStateChanged?(false)
        onWebServiceLifecycleStateChanged?(webServiceLifecycleState)
        sharingStateSnapshot = .empty
        notifySharingStateObservers()
    }

    func registerShareableDisplays(
        _ displays: [SCDisplay],
        virtualSerialResolver: (CGDirectDisplayID) -> UInt32?
    ) {
        registerShareableDisplaysCallCount += 1
        registeredShareableDisplays = displays
        _ = virtualSerialResolver(CGDirectDisplayID(0))
    }

    func startSharing(display: SCDisplay) async throws -> DisplayStartOutcome<Void> {
        if let startSharingHandler {
            return try await startSharingHandler(display)
        }
        hasAnyActiveSharing = true
        activeSharingDisplayIDs.insert(display.displayID)
        return .started(())
    }

    func stopSharing(displayID: CGDirectDisplayID) {
        stopSharingCallCount += 1
        activeSharingDisplayIDs.remove(displayID)
        hasAnyActiveSharing = !activeSharingDisplayIDs.isEmpty
        onStopSharing?(displayID)
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

    func updateSharingStateSnapshot(_ snapshot: SharingStateSnapshot) {
        sharingStateSnapshot = snapshot
        activeStreamClientCount = snapshot.streamingPeers
        streamClientCountsByTarget = snapshot.streamingPeersByTarget
        notifySharingStateObservers()
    }

    private func notifySharingStateObservers() {
        for observer in sharingStateObservers.values {
            observer(sharingStateSnapshot)
        }
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
