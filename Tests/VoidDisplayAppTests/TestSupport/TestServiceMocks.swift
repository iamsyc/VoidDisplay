@testable import VoidDisplayApp
@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
@testable import VoidDisplaySharing
@testable import VoidDisplayVirtualDisplay
import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit

@MainActor
func makeTestDisplayTopologySignature(
    _ displayIDs: [CGDirectDisplayID]
) -> ScreenCaptureDisplayTopologySignature {
    displayIDs.map { ScreenCaptureDisplayTopologySignatureEntry(displayID: $0) }
}

@MainActor
func makeTestDisplayTopologySignatureEntry(
    displayID: CGDirectDisplayID,
    isMain: Bool = false,
    pixelWidth: Int = 0,
    pixelHeight: Int = 0,
    refreshRateMilliHertz: Int? = nil,
    mirrorsDisplayID: CGDirectDisplayID? = nil
) -> ScreenCaptureDisplayTopologySignatureEntry {
    .init(
        displayID: displayID,
        isMain: isMain,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        refreshRateMilliHertz: refreshRateMilliHertz,
        mirrorsDisplayID: mirrorsDisplayID
    )
}

final class TestAppDisplayShareFrameConsumer: DisplayShareFrameConsumer {
    nonisolated init() {}

    nonisolated var hasDemand: Bool { false }

    nonisolated func updateSourceVideoSpec(_: SourceVideoSpec) {}

    nonisolated func updatePerformanceMode(_: CapturePerformanceMode) {}

    nonisolated func stopSharing() {}

    nonisolated func submitFrame(pixelBuffer _: CVPixelBuffer, ptsUs _: UInt64) {}
}

final class TestAppDisplayCaptureSession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer = TestAppDisplayShareFrameConsumer()

    nonisolated(unsafe) var attachedSinkCount = 0
    nonisolated(unsafe) var detachedSinkCount = 0
    nonisolated(unsafe) var cursorUpdateCount = 0
    nonisolated(unsafe) var lastShowsCursor: Bool?

    nonisolated init() {}

    nonisolated func attachPreviewSink(_ _: any DisplayPreviewSink) {
        attachedSinkCount += 1
    }

    nonisolated func detachPreviewSink(_ _: any DisplayPreviewSink) {
        detachedSinkCount += 1
    }

    nonisolated func stopSharing() {}

    nonisolated func setDemand(_ demand: DisplayCaptureDemandSnapshot) async throws {
        cursorUpdateCount += 1
        lastShowsCursor = demand.previewShowsCursor
    }

    nonisolated func stop() async {}
}

@MainActor
final class MockCapturePreviewService: CapturePreviewServiceProtocol {
    var currentSessions: [ScreenPreviewSession] = []
    var addCallCount = 0
    var removeCallCount = 0
    var removeByDisplayCallCount = 0
    var removedDisplayIDs: [CGDirectDisplayID] = []
    var updateStateCallCount = 0
    var updateCapturesCursorCallCount = 0

    func previewSession(for id: UUID) -> ScreenPreviewSession? {
        currentSessions.first(where: { $0.id == id })
    }

    func addPreviewSession(_ session: ScreenPreviewSession) {
        addCallCount += 1
        currentSessions.append(session)
    }

    func updatePreviewSessionState(
        id: UUID,
        state: ScreenPreviewSession.State
    ) {
        updateStateCallCount += 1
        guard let index = currentSessions.firstIndex(where: { $0.id == id }) else { return }
        currentSessions[index].state = state
    }

    func updatePreviewSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) {
        updateCapturesCursorCallCount += 1
        guard let index = currentSessions.firstIndex(where: { $0.id == id }) else { return }
        currentSessions[index].capturesCursor = capturesCursor
    }

    func removePreviewSession(id: UUID) {
        removeCallCount += 1
        currentSessions.removeAll { $0.id == id }
    }

    func removePreviewSessions(displayID: CGDirectDisplayID) {
        removeByDisplayCallCount += 1
        removedDisplayIDs.append(displayID)
        currentSessions.removeAll { $0.displayID == displayID }
    }
}

@MainActor
final class MockSharingService: SharingServiceProtocol {
    typealias StartSharingHandler = @MainActor (SCDisplay) async throws -> DisplayStartOutcome<Void>

    var webServicePortValue: UInt16 = 8081
    var onWebServiceLifecycleStateChanged: (@MainActor @Sendable (WebServiceLifecycleState) -> Void)?
    var webServiceLifecycleState: WebServiceLifecycleState = .stopped
    var isWebServiceRunning = false
    var activeStreamClientCount = 0
    var sharingStateSnapshot: SharingStateSnapshot = .empty
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
    var registeredVirtualSerialsByDisplayID: [CGDirectDisplayID: UInt32?] = [:]
    var stopSharingCallCount = 0
    var stopAllSharingCallCount = 0
    var startSharingCallCount = 0
    var startedSharingDisplayIDs: [CGDirectDisplayID] = []
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
        onWebServiceLifecycleStateChanged?(webServiceLifecycleState)
        notifySharingStateObservers()
        return startResult
    }

    func stopWebService() {
        stopWebServiceCallCount += 1
        isWebServiceRunning = false
        webServiceLifecycleState = .stopped
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
        registeredVirtualSerialsByDisplayID = Dictionary(
            uniqueKeysWithValues: displays.map { display in
                (display.displayID, virtualSerialResolver(display.displayID))
            }
        )
    }

    func startSharing(display: SCDisplay) async throws -> DisplayStartOutcome<Void> {
        startSharingCallCount += 1
        startedSharingDisplayIDs.append(display.displayID)
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

final class FakeVirtualDisplayStore: VirtualDisplayStoring {
    var loadCallCount = 0
    var saveCallCount = 0
    var resetCallCount = 0

    var loadError: Error?
    var saveError: Error?
    var scriptedSaveErrors: [Error?] = []
    var resetError: Error?
    var diagnosticsError: Error?

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
