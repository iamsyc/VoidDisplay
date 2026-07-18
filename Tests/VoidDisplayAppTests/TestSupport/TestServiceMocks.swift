@testable import VoidDisplayApp
@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
@testable import VoidDisplaySharing
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayTestingSupport
import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit

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
        guard let index = currentSessions.firstIndex(where: { $0.id == id }) else { return }
        currentSessions[index].state = state
    }

    func updatePreviewSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) {
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
    var startWebServiceCallCount = 0
    var stopSharingCallCount = 0
    var stopAllSharingCallCount = 0
    var startSharingCallCount = 0
    var startedSharingDisplayIDs: [CGDirectDisplayID] = []
    var streamClientCountsByTarget: [ShareTarget: Int] = [:]
    var shareIDByDisplayID: [CGDirectDisplayID: UInt32] = [:]
    var sharePagePathByDisplayID: [CGDirectDisplayID: String] = [:]
    var shareTargetByDisplayID: [CGDirectDisplayID: ShareTarget] = [:]
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
        isWebServiceRunning = false
        webServiceLifecycleState = .stopped
        onWebServiceLifecycleStateChanged?(webServiceLifecycleState)
        sharingStateSnapshot = .empty
        notifySharingStateObservers()
    }

    func registerShareableDisplays(
        _: [SCDisplay],
        virtualSerialResolver _: (CGDirectDisplayID) -> UInt32?
    ) {}

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

    func sharePagePath(for displayID: CGDirectDisplayID) -> String? {
        sharePagePathByDisplayID[displayID]
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
