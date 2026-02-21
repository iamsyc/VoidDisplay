import CoreGraphics
import Foundation
import ScreenCaptureKit
@testable import VoidDisplay

@MainActor
final class MockCaptureMonitoringService: CaptureMonitoringServiceProtocol {
    var currentSessions: [AppHelper.ScreenMonitoringSession] = []
    var addCallCount = 0
    var removeCallCount = 0
    var updateStateCallCount = 0

    func monitoringSession(for id: UUID) -> AppHelper.ScreenMonitoringSession? {
        currentSessions.first(where: { $0.id == id })
    }

    func addMonitoringSession(_ session: AppHelper.ScreenMonitoringSession) {
        addCallCount += 1
        currentSessions.append(session)
    }

    func updateMonitoringSessionState(
        id: UUID,
        state: AppHelper.ScreenMonitoringSession.State
    ) {
        updateStateCallCount += 1
        guard let index = currentSessions.firstIndex(where: { $0.id == id }) else { return }
        currentSessions[index].state = state
    }

    func removeMonitoringSession(id: UUID) {
        removeCallCount += 1
        currentSessions.removeAll { $0.id == id }
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

    func disableDisplayByConfig(_ configId: UUID) throws {}

    func enableDisplay(_ configId: UUID) async throws {}

    func destroyDisplay(_ configId: UUID) {}

    func destroyDisplay(_ display: CGVirtualDisplay) {}

    func getConfig(_ configId: UUID) -> VirtualDisplayConfig? {
        currentDisplayConfigs.first(where: { $0.id == configId })
    }

    func updateConfig(_ updated: VirtualDisplayConfig) {
        guard let index = currentDisplayConfigs.firstIndex(where: { $0.id == updated.id }) else { return }
        currentDisplayConfigs[index] = updated
    }

    func moveConfig(_ configId: UUID, direction: VirtualDisplayService.ReorderDirection) -> Bool {
        false
    }

    func applyModes(configId: UUID, modes: [ResolutionSelection]) {}

    func rebuildVirtualDisplay(configId: UUID) async throws {}

    func getConfig(for display: CGVirtualDisplay) -> VirtualDisplayConfig? {
        currentDisplayConfigs.first(where: { $0.serialNum == display.serialNum })
    }

    func updateConfig(for display: CGVirtualDisplay, modes: [ResolutionSelection]) {}

    func nextAvailableSerialNumber() -> UInt32 {
        1
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
