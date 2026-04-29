@testable import VoidDisplayApp
@testable import VoidDisplayApp
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayCapture
@testable import VoidDisplaySharing
@testable import VoidDisplayObservability
@testable import VoidDisplaySupport
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing

private final class CaptureSharingIsolationDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let sessionHub = WebRTCSessionHub()
    nonisolated var shareFrameConsumer: any DisplayShareFrameConsumer { sessionHub }

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func stopSharing() {}

    nonisolated func setDemand(_ demand: DisplayCaptureDemandSnapshot) async throws {
        _ = demand
    }

    nonisolated func stop() async {}
}

@MainActor
private final class IsolationPortPreferences: SharingPortPreferencesProtocol {
    var preferredPort: UInt16 = 8081

    func savePreferredPort(_ port: UInt16) {
        preferredPort = port
    }
}

@Suite(.serialized)
@MainActor
struct CaptureSharingIsolationTests {
    @Test func captureMutationsDoNotRewriteSharingSnapshot() async throws {
        let sharingService = MockSharingService()
        let sharedDisplay: CGDirectDisplayID = 901
        sharingService.activeSharingDisplayIDs = [sharedDisplay]
        sharingService.activeStreamClientCount = 3
        sharingService.hasAnyActiveSharing = true
        sharingService.startResult = .started(
            WebServiceBinding(requestedPort: 8081, boundPort: 8081)
        )
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: IsolationPortPreferences()
        )
        _ = await sharingController.startWebService(requestedPort: 8081)

        let captureService = MockCaptureMonitoringService()
        let captureSession = makeSession(id: UUID(), displayID: 777)
        captureService.currentSessions = [captureSession]
        let captureController = CaptureController(captureMonitoringService: captureService)

        captureController.activateMonitoringSession(id: captureSession.id)
        try await captureController.setMonitoringSessionCapturesCursor(
            id: captureSession.id,
            capturesCursor: true
        )

        #expect(sharingController.isWebServiceRunning)
        #expect(sharingController.isSharing)
        #expect(sharingController.sharingClientCount == 3)
        #expect(sharingController.activeSharingDisplayIDs == [sharedDisplay])
        #expect(sharingService.stopSharingCallCount == 0)
        #expect(sharingService.stopAllSharingCallCount == 0)
    }

    @Test func sharingMutationsDoNotRewriteCaptureSessions() async {
        let captureService = MockCaptureMonitoringService()
        let first = makeSession(id: UUID(), displayID: 1001)
        let second = makeSession(id: UUID(), displayID: 1002)
        captureService.currentSessions = [first, second]
        let captureController = CaptureController(captureMonitoringService: captureService)

        let sharingService = MockSharingService()
        sharingService.activeSharingDisplayIDs = [1001]
        sharingService.activeStreamClientCount = 2
        sharingService.hasAnyActiveSharing = true
        sharingService.startResult = .started(
            WebServiceBinding(requestedPort: 8081, boundPort: 8081)
        )
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: IsolationPortPreferences()
        )
        _ = await sharingController.startWebService(requestedPort: 8081)
        sharingController.stopAllSharing()
        sharingController.stopWebService()

        #expect(captureController.screenCaptureSessions.map(\.id) == [first.id, second.id])
        #expect(captureController.monitoringSession(for: first.id)?.displayID == 1001)
        #expect(captureController.monitoringSession(for: second.id)?.displayID == 1002)
        #expect(captureService.removeCallCount == 0)
        #expect(captureService.removeByDisplayCallCount == 0)
    }

    private func makeSession(id: UUID, displayID: CGDirectDisplayID) -> ScreenMonitoringSession {
        ScreenMonitoringSession(
            id: id,
            displayID: displayID,
            displayName: "Display \(displayID)",
            resolutionText: "1920 x 1080",
            isVirtualDisplay: false,
            previewSubscription: DisplayPreviewSubscription(
                displayID: displayID,
                resolutionText: "1920 x 1080",
                session: CaptureSharingIsolationDummySession(),
                cancelClosure: {}
            ),
            capturesCursor: false,
            state: .starting
        )
    }
}
