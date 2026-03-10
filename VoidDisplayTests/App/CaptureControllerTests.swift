import CoreGraphics
import ScreenCaptureKit
import Testing
@testable import VoidDisplay

private final class CaptureControllerDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let sessionHub = WebRTCSessionHub()

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func stopSharing() {}

    nonisolated func stop() async {}
}

@Suite(.serialized)
@MainActor
struct CaptureControllerTests {
    @Test func addAndRemoveSessionSyncsControllerState() {
        let service = MockCaptureMonitoringService()
        let controller = CaptureController(captureMonitoringService: service)
        let session = makeSession(id: UUID(), displayID: 77)

        controller.addMonitoringSession(session)
        #expect(controller.screenCaptureSessions.map(\.id) == [session.id])
        #expect(controller.monitoringSession(for: session.id)?.displayID == 77)

        controller.removeMonitoringSession(id: session.id)
        #expect(controller.screenCaptureSessions.isEmpty)
        #expect(service.removeCallCount == 1)
    }

    @Test func markMonitoringSessionActiveRefreshesSnapshot() {
        let service = MockCaptureMonitoringService()
        let session = makeSession(id: UUID(), displayID: 88)
        service.currentSessions = [session]
        let controller = CaptureController(captureMonitoringService: service)

        controller.markMonitoringSessionActive(id: session.id)

        guard let updated = controller.screenCaptureSessions.first else {
            Issue.record("Expected active session.")
            return
        }
        if case .active = updated.state {
        } else {
            Issue.record("Expected controller session to be active.")
        }
        #expect(service.updateStateCallCount == 1)
    }

    @Test func removeMonitoringSessionsFiltersByDisplayID() {
        let service = MockCaptureMonitoringService()
        let first = makeSession(id: UUID(), displayID: 91)
        let second = makeSession(id: UUID(), displayID: 92)
        service.currentSessions = [first, second]
        let controller = CaptureController(captureMonitoringService: service)

        controller.removeMonitoringSessions(displayID: 91)

        #expect(controller.screenCaptureSessions.map(\.displayID) == [92])
        #expect(service.removeByDisplayCallCount == 1)
        #expect(service.removedDisplayIDs == [91])
    }

    @Test func stopDependentStreamsBeforeRebuildStopsSharingAndMonitoring() {
        let service = MockCaptureMonitoringService()
        let session = makeSession(id: UUID(), displayID: 123)
        service.currentSessions = [session]
        let sharingService = MockSharingService()
        sharingService.activeSharingDisplayIDs = [123]
        sharingService.hasAnyActiveSharing = true
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: SharingPortPreferences(defaults: UserDefaults(suiteName: "CaptureControllerTests")!)
        )
        let controller = CaptureController(captureMonitoringService: service)

        controller.stopDependentStreamsBeforeRebuild(
            displayID: 123,
            sharingController: sharingController
        )

        #expect(sharingService.stopSharingCallCount == 1)
        #expect(service.removeByDisplayCallCount == 1)
        #expect(controller.screenCaptureSessions.isEmpty)
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
                session: CaptureControllerDummySession(),
                cancelClosure: {}
            ),
            state: .starting
        )
    }
}
