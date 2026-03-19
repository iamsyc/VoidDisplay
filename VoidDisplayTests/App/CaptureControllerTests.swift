import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import Testing
@testable import VoidDisplay

private final class CaptureControllerDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let sessionHub = WebRTCSessionHub()

    nonisolated(unsafe) var attachedSinkCount = 0
    nonisolated(unsafe) var detachedSinkCount = 0
    nonisolated(unsafe) var cursorUpdateCount = 0
    nonisolated(unsafe) var lastShowsCursor: Bool?

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
        attachedSinkCount += 1
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
        detachedSinkCount += 1
    }

    nonisolated func stopSharing() {}

    nonisolated func setPreviewShowsCursor(_ showsCursor: Bool) async throws {
        cursorUpdateCount += 1
        lastShowsCursor = showsCursor
    }

    nonisolated func retainShareCursorOverride() async throws {}

    nonisolated func releaseShareCursorOverride() async throws {}

    nonisolated func stop() async {}
}

private final class CaptureControllerPreviewSink: DisplayPreviewSink, @unchecked Sendable {
    nonisolated func submitFrame(_ sampleBuffer: CMSampleBuffer) {
        _ = sampleBuffer
    }
}

private final class CaptureControllerMockSCDisplayBox: NSObject {
    @objc let displayID: CGDirectDisplayID
    @objc let width: Int
    @objc let height: Int
    @objc let frame: CGRect

    init(displayID: CGDirectDisplayID, width: Int, height: Int) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.frame = CGRect(x: 0, y: 0, width: width, height: height)
        super.init()
    }
}

private enum CaptureControllerMockSCDisplay {
    static func make(displayID: CGDirectDisplayID, width: Int, height: Int) -> SCDisplay {
        let box = CaptureControllerMockSCDisplayBox(
            displayID: displayID,
            width: width,
            height: height
        )
        return unsafeBitCast(box, to: SCDisplay.self)
    }
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
        let existingSession = makeSession(id: UUID(), displayID: 66).session
        service.currentSessions = [existingSession]

        let controller = CaptureController(captureMonitoringService: service)

        #expect(controller.screenCaptureSessions.map(\.id) == [existingSession.id])
    }

    @Test func startMonitoringRefreshesSnapshotFromLifecycleService() async throws {
        let service = MockCaptureMonitoringService()
        let subscriptionSession = CaptureControllerDummySession()
        let subscription = DisplayPreviewSubscription(
            displayID: 77,
            resolutionText: "2560 × 1440",
            session: subscriptionSession,
            cancelClosure: {}
        )
        let lifecycleService = CaptureMonitoringLifecycleService(
            captureMonitoringService: service,
            acquirePreview: { _ in subscription }
        )
        let controller = CaptureController(
            captureMonitoringService: service,
            captureMonitoringLifecycleService: lifecycleService
        )
        let display = CaptureControllerMockSCDisplay.make(displayID: 77, width: 2560, height: 1440)
        let metadata = CaptureMonitoringDisplayMetadata(
            displayName: "Display 77",
            resolutionText: "2560 × 1440",
            isVirtualDisplay: false
        )

        let sessionID = try await controller.startMonitoring(display: display, metadata: metadata)

        #expect(service.addCallCount == 1)
        #expect(controller.monitoringSession(for: sessionID)?.displayName == "Display 77")
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func activateMonitoringSessionRefreshesSnapshot() {
        let service = MockCaptureMonitoringService()
        let session = makeSession(id: UUID(), displayID: 88).session
        service.currentSessions = [session]
        let controller = CaptureController(captureMonitoringService: service)

        controller.activateMonitoringSession(id: session.id)

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

    @Test func attachPreviewSinkTargetsRequestedSessionAndKeepsSnapshotAligned() {
        let service = MockCaptureMonitoringService()
        let first = makeSession(id: UUID(), displayID: 89)
        let second = makeSession(id: UUID(), displayID: 90)
        service.currentSessions = [first.session, second.session]
        let controller = CaptureController(captureMonitoringService: service)
        let sink = CaptureControllerPreviewSink()

        controller.attachPreviewSink(sink, to: second.session.id)

        #expect(first.captureSession.attachedSinkCount == 0)
        #expect(second.captureSession.attachedSinkCount == 1)
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func setMonitoringSessionCapturesCursorRefreshesSnapshot() async throws {
        let service = MockCaptureMonitoringService()
        let sessionRecord = makeSession(id: UUID(), displayID: 91)
        service.currentSessions = [sessionRecord.session]
        let controller = CaptureController(captureMonitoringService: service)

        try await controller.setMonitoringSessionCapturesCursor(
            id: sessionRecord.session.id,
            capturesCursor: true
        )

        #expect(controller.screenCaptureSessions.first?.capturesCursor == true)
        #expect(service.updateCapturesCursorCallCount == 1)
        #expect(sessionRecord.captureSession.cursorUpdateCount == 1)
        #expect(sessionRecord.captureSession.lastShowsCursor == true)
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func closeMonitoringSessionRefreshesSnapshot() {
        let service = MockCaptureMonitoringService()
        let session = makeSession(id: UUID(), displayID: 92).session
        service.currentSessions = [session]
        let controller = CaptureController(captureMonitoringService: service)

        controller.closeMonitoringSession(id: session.id)

        #expect(controller.screenCaptureSessions.isEmpty)
        #expect(service.removeCallCount == 1)
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func removeMonitoringSessionsFiltersByDisplayID() {
        let service = MockCaptureMonitoringService()
        let first = makeSession(id: UUID(), displayID: 93).session
        let second = makeSession(id: UUID(), displayID: 94).session
        service.currentSessions = [first, second]
        let controller = CaptureController(captureMonitoringService: service)

        controller.removeMonitoringSessions(displayID: 93)

        #expect(controller.screenCaptureSessions.map(\.displayID) == [94])
        #expect(service.removeByDisplayCallCount == 1)
        #expect(service.removedDisplayIDs == [93])
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func unknownLifecycleMutationRequestsKeepControllerSnapshotStable() async throws {
        let service = MockCaptureMonitoringService()
        let first = makeSession(id: UUID(), displayID: 101)
        let second = makeSession(id: UUID(), displayID: 102)
        service.currentSessions = [first.session, second.session]
        let controller = CaptureController(captureMonitoringService: service)
        let initialSignature = snapshotSignature(controller.screenCaptureSessions)
        let sink = CaptureControllerPreviewSink()

        controller.activateMonitoringSession(id: UUID())
        #expect(snapshotSignature(controller.screenCaptureSessions) == initialSignature)
        #expect(service.updateStateCallCount == 0)
        assertSnapshotMatchesService(controller: controller, service: service)

        controller.attachPreviewSink(sink, to: UUID())
        #expect(snapshotSignature(controller.screenCaptureSessions) == initialSignature)
        #expect(first.captureSession.attachedSinkCount == 0)
        #expect(second.captureSession.attachedSinkCount == 0)
        assertSnapshotMatchesService(controller: controller, service: service)

        try await controller.setMonitoringSessionCapturesCursor(id: UUID(), capturesCursor: true)
        #expect(snapshotSignature(controller.screenCaptureSessions) == initialSignature)
        #expect(service.updateCapturesCursorCallCount == 0)
        assertSnapshotMatchesService(controller: controller, service: service)

        controller.closeMonitoringSession(id: UUID())
        #expect(snapshotSignature(controller.screenCaptureSessions) == initialSignature)
        #expect(service.removeCallCount == 0)
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func stopDependentStreamsBeforeRebuildStopsSharingAndMonitoring() {
        let service = MockCaptureMonitoringService()
        let session = makeSession(id: UUID(), displayID: 123).session
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
        let session = makeSession(id: UUID(), displayID: 124).session
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

    private func makeSession(
        id: UUID,
        displayID: CGDirectDisplayID
    ) -> (session: ScreenMonitoringSession, captureSession: CaptureControllerDummySession) {
        let captureSession = CaptureControllerDummySession()
        let session = ScreenMonitoringSession(
            id: id,
            displayID: displayID,
            displayName: "Display \(displayID)",
            resolutionText: "1920 x 1080",
            isVirtualDisplay: false,
            previewSubscription: DisplayPreviewSubscription(
                displayID: displayID,
                resolutionText: "1920 x 1080",
                session: captureSession,
                cancelClosure: {}
            ),
            capturesCursor: false,
            state: .starting
        )
        return (session, captureSession)
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
