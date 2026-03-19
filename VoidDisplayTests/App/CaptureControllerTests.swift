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

    nonisolated func setPreviewShowsCursor(_ showsCursor: Bool) async throws {
        _ = showsCursor
    }

    nonisolated func retainShareCursorOverride() async throws {}

    nonisolated func releaseShareCursorOverride() async throws {}

    nonisolated func stop() async {}
}

@Suite(.serialized)
@MainActor
struct CaptureControllerTests {
    private struct SessionSnapshot: Equatable {
        let id: UUID
        let displayID: CGDirectDisplayID
        let capturesCursor: Bool
        let state: String
    }

    @Test func initSynchronizesExistingSessionsFromService() {
        let service = MockCaptureMonitoringService()
        let existingSession = makeSession(id: UUID(), displayID: 66)
        service.currentSessions = [existingSession]

        let controller = CaptureController(captureMonitoringService: service)

        #expect(controller.screenCaptureSessions.map(\.id) == [existingSession.id])
    }

    @Test func addAndRemoveSessionSyncsControllerState() {
        let service = MockCaptureMonitoringService()
        let controller = CaptureController(captureMonitoringService: service)
        let session = makeSession(id: UUID(), displayID: 77)

        controller.addMonitoringSession(session)
        assertSnapshotMatchesService(controller: controller, service: service)
        #expect(controller.monitoringSession(for: session.id)?.displayID == 77)

        controller.removeMonitoringSession(id: session.id)
        #expect(controller.screenCaptureSessions.isEmpty)
        #expect(service.removeCallCount == 1)
        assertSnapshotMatchesService(controller: controller, service: service)
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
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func setMonitoringSessionCapturesCursorRefreshesSnapshot() {
        let service = MockCaptureMonitoringService()
        let session = makeSession(id: UUID(), displayID: 89)
        service.currentSessions = [session]
        let controller = CaptureController(captureMonitoringService: service)

        controller.setMonitoringSessionCapturesCursor(id: session.id, capturesCursor: true)

        #expect(controller.screenCaptureSessions.first?.capturesCursor == true)
        #expect(service.updateCapturesCursorCallCount == 1)
        assertSnapshotMatchesService(controller: controller, service: service)
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
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func unknownMutationRequestsKeepControllerSnapshotStable() {
        let service = MockCaptureMonitoringService()
        let first = makeSession(id: UUID(), displayID: 101)
        let second = makeSession(id: UUID(), displayID: 102)
        service.currentSessions = [first, second]
        let controller = CaptureController(captureMonitoringService: service)
        let initialSignature = snapshotSignature(controller.screenCaptureSessions)

        controller.markMonitoringSessionActive(id: UUID())
        #expect(snapshotSignature(controller.screenCaptureSessions) == initialSignature)
        assertSnapshotMatchesService(controller: controller, service: service)

        controller.setMonitoringSessionCapturesCursor(id: UUID(), capturesCursor: true)
        #expect(snapshotSignature(controller.screenCaptureSessions) == initialSignature)
        assertSnapshotMatchesService(controller: controller, service: service)

        controller.removeMonitoringSession(id: UUID())
        #expect(snapshotSignature(controller.screenCaptureSessions) == initialSignature)
        assertSnapshotMatchesService(controller: controller, service: service)
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
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func stopDependentStreamsBeforeRebuildDoesNotStopSharingWhenDisplayIsNotShared() {
        let service = MockCaptureMonitoringService()
        let session = makeSession(id: UUID(), displayID: 124)
        service.currentSessions = [session]
        let sharingService = MockSharingService()
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: SharingPortPreferences(defaults: UserDefaults(suiteName: "CaptureControllerTestsNoShare")!)
        )
        let controller = CaptureController(captureMonitoringService: service)

        controller.stopDependentStreamsBeforeRebuild(
            displayID: 124,
            sharingController: sharingController
        )

        #expect(sharingService.stopSharingCallCount == 0)
        #expect(service.removeByDisplayCallCount == 1)
        #expect(controller.screenCaptureSessions.isEmpty)
        assertSnapshotMatchesService(controller: controller, service: service)
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
            capturesCursor: false,
            state: .starting
        )
    }

    private func assertSnapshotMatchesService(
        controller: CaptureController,
        service: MockCaptureMonitoringService
    ) {
        #expect(snapshotSignature(controller.screenCaptureSessions) == snapshotSignature(service.currentSessions))
    }

    private func snapshotSignature(_ sessions: [ScreenMonitoringSession]) -> [SessionSnapshot] {
        sessions.map { session in
            let stateLabel: String
            switch session.state {
            case .starting:
                stateLabel = "starting"
            case .active:
                stateLabel = "active"
            }
            return SessionSnapshot(
                id: session.id,
                displayID: session.displayID,
                capturesCursor: session.capturesCursor,
                state: stateLabel
            )
        }
    }
}
