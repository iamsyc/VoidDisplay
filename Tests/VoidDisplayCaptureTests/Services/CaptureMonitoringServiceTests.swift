@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
import CoreGraphics
import ScreenCaptureKit
import Testing

private final class CaptureMonitoringDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer = TestDisplayShareFrameConsumer()

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

private final class CancellationCounter: @unchecked Sendable {
    nonisolated(unsafe) var value = 0
}

@Suite(.serialized)
@MainActor
struct CaptureMonitoringServiceTests {
    private struct SessionSnapshot: Equatable {
        let id: UUID
        let displayID: CGDirectDisplayID
        let capturesCursor: Bool
        let state: String
    }

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

    @Test func updateMonitoringSessionStateIgnoresUnknownSessionID() {
        let service = CaptureMonitoringService()
        let session = makeSession(id: UUID(), displayID: 15).session
        service.addMonitoringSession(session)

        service.updateMonitoringSessionState(id: UUID(), state: .active)

        #expect(snapshotSignature(service.currentSessions) == [signature(for: session)])
    }

    @Test func updateMonitoringSessionStateDoesNotRevertActiveSessionToStarting() {
        let service = CaptureMonitoringService()
        var activeSession = makeSession(id: UUID(), displayID: 16).session
        activeSession.state = .active
        service.addMonitoringSession(activeSession)

        service.updateMonitoringSessionState(id: activeSession.id, state: .starting)

        #expect(service.currentSessions.first?.state == .active)
    }

    @Test func updateMonitoringSessionCapturesCursorIgnoresUnknownSessionID() {
        let service = CaptureMonitoringService()
        let session = makeSession(id: UUID(), displayID: 17).session
        service.addMonitoringSession(session)

        service.updateMonitoringSessionCapturesCursor(id: UUID(), capturesCursor: true)

        #expect(snapshotSignature(service.currentSessions) == [signature(for: session)])
    }

    @Test func removeMonitoringSessionCancelsSubscription() {
        let service = CaptureMonitoringService()
        let (session, cancelCount) = makeSession(id: UUID(), displayID: 22)
        service.addMonitoringSession(session)

        service.removeMonitoringSession(id: session.id)

        #expect(service.currentSessions.isEmpty)
        #expect(cancelCount.value == 1)
    }

    @Test func removeMonitoringSessionIgnoresUnknownSessionID() {
        let service = CaptureMonitoringService()
        let retained = makeSession(id: UUID(), displayID: 23)
        service.addMonitoringSession(retained.session)

        service.removeMonitoringSession(id: UUID())

        #expect(snapshotSignature(service.currentSessions) == [signature(for: retained.session)])
        #expect(retained.cancelCount.value == 0)
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
        #expect(first.cancelCount.value + second.cancelCount.value == 2)
    }

    @Test func removeMonitoringSessionsIgnoresUnknownDisplayIDAndPreservesOrder() {
        let service = CaptureMonitoringService()
        let first = makeSession(id: UUID(), displayID: 50)
        let second = makeSession(id: UUID(), displayID: 51)
        let third = makeSession(id: UUID(), displayID: 52)
        service.addMonitoringSession(first.session)
        service.addMonitoringSession(second.session)
        service.addMonitoringSession(third.session)

        service.removeMonitoringSessions(displayID: 99)

        #expect(snapshotSignature(service.currentSessions) == [
            signature(for: first.session),
            signature(for: second.session),
            signature(for: third.session)
        ])
        #expect(first.cancelCount.value == 0)
        #expect(second.cancelCount.value == 0)
        #expect(third.cancelCount.value == 0)
    }

    @Test func removeMonitoringSessionsKeepsRemainingOrderAfterCancellingMatches() {
        let service = CaptureMonitoringService()
        let first = makeSession(id: UUID(), displayID: 60)
        let second = makeSession(id: UUID(), displayID: 61)
        let third = makeSession(id: UUID(), displayID: 60)
        let fourth = makeSession(id: UUID(), displayID: 62)
        service.addMonitoringSession(first.session)
        service.addMonitoringSession(second.session)
        service.addMonitoringSession(third.session)
        service.addMonitoringSession(fourth.session)

        service.removeMonitoringSessions(displayID: 60)

        #expect(snapshotSignature(service.currentSessions) == [
            signature(for: second.session),
            signature(for: fourth.session)
        ])
        #expect(first.cancelCount.value == 1)
        #expect(third.cancelCount.value == 1)
        #expect(second.cancelCount.value == 0)
        #expect(fourth.cancelCount.value == 0)
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

    private func snapshotSignature(_ sessions: [ScreenMonitoringSession]) -> [SessionSnapshot] {
        sessions.map(signature(for:))
    }

    private func signature(for session: ScreenMonitoringSession) -> SessionSnapshot {
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
