import CoreGraphics
import ScreenCaptureKit
import Testing
@testable import VoidDisplay

private final class CaptureMonitoringDummySession: DisplayCaptureSessioning, @unchecked Sendable {
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

private final class CancellationCounter: @unchecked Sendable {
    nonisolated(unsafe) var value = 0
}

@Suite(.serialized)
@MainActor
struct CaptureMonitoringServiceTests {
    @Test func addAndLookupSessionTracksCurrentSessions() {
        let service = CaptureMonitoringService()
        let session = makeSession(id: UUID(), displayID: 7).session

        service.addMonitoringSession(session)

        #expect(service.currentSessions.count == 1)
        #expect(service.monitoringSession(for: session.id)?.displayID == 7)
    }

    @Test func updateMonitoringSessionStateMutatesOnlyMatchingSession() {
        let service = CaptureMonitoringService()
        let first = makeSession(id: UUID(), displayID: 10).session
        let second = makeSession(id: UUID(), displayID: 11).session
        service.addMonitoringSession(first)
        service.addMonitoringSession(second)

        service.updateMonitoringSessionState(id: second.id, state: .active)

        let states = service.currentSessions.reduce(into: [UUID: ScreenMonitoringSession.State]()) {
            $0[$1.id] = $1.state
        }
        if case .starting = states[first.id] {
        } else {
            Issue.record("Expected first session to stay in starting state.")
        }
        if case .active = states[second.id] {
        } else {
            Issue.record("Expected second session to become active.")
        }
    }

    @Test func updateMonitoringSessionCapturesCursorMutatesOnlyMatchingSession() {
        let service = CaptureMonitoringService()
        let first = makeSession(id: UUID(), displayID: 12).session
        let second = makeSession(id: UUID(), displayID: 13).session
        service.addMonitoringSession(first)
        service.addMonitoringSession(second)

        service.updateMonitoringSessionCapturesCursor(id: second.id, capturesCursor: true)

        let cursorStates = service.currentSessions.reduce(into: [UUID: Bool]()) {
            $0[$1.id] = $1.capturesCursor
        }
        #expect(cursorStates[first.id] == false)
        #expect(cursorStates[second.id] == true)
    }

    @Test func removeMonitoringSessionCancelsSubscription() {
        let service = CaptureMonitoringService()
        let (session, cancelCount) = makeSession(id: UUID(), displayID: 22)
        service.addMonitoringSession(session)

        service.removeMonitoringSession(id: session.id)

        #expect(service.currentSessions.isEmpty)
        #expect(cancelCount.value == 1)
    }

    @Test func removeMonitoringSessionsCancelsAllMatchingDisplaySessions() {
        let service = CaptureMonitoringService()
        let first = makeSession(id: UUID(), displayID: 44)
        let second = makeSession(id: UUID(), displayID: 44)
        let third = makeSession(id: UUID(), displayID: 45)
        service.addMonitoringSession(first.session)
        service.addMonitoringSession(second.session)
        service.addMonitoringSession(third.session)

        service.removeMonitoringSessions(displayID: 44)

        #expect(service.currentSessions.map(\.displayID) == [45])
        #expect(first.cancelCount.value == 1)
        #expect(second.cancelCount.value == 1)
        #expect(third.cancelCount.value == 0)
    }

    private func makeSession(
        id: UUID,
        displayID: CGDirectDisplayID
    ) -> (session: ScreenMonitoringSession, cancelCount: CancellationCounter) {
        let cancelCount = CancellationCounter()
        let subscription = DisplayPreviewSubscription(
            displayID: displayID,
            resolutionText: "1920 x 1080",
            session: CaptureMonitoringDummySession(),
            cancelClosure: { cancelCount.value += 1 }
        )
        let session = ScreenMonitoringSession(
            id: id,
            displayID: displayID,
            displayName: "Display \(displayID)",
            resolutionText: "1920 x 1080",
            isVirtualDisplay: false,
            previewSubscription: subscription,
            capturesCursor: false,
            state: .starting
        )
        return (session, cancelCount)
    }
}
