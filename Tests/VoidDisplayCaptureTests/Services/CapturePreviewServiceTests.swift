@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
import CoreGraphics
import ScreenCaptureKit
import Testing

private final class CapturePreviewDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer = TestDisplayShareFrameConsumer()

    nonisolated func attachPreviewSink(_ _: any DisplayPreviewSink) {}

    nonisolated func detachPreviewSink(_ _: any DisplayPreviewSink) {}

    nonisolated func stopSharing() {}

    nonisolated func setDemand(_ _: DisplayCaptureDemandSnapshot) async throws {}

    nonisolated func stop() async {}
}

private final class CancellationCounter: @unchecked Sendable {
    nonisolated(unsafe) var value = 0
}

@Suite(.serialized)
@MainActor
struct CapturePreviewServiceTests {
    private struct SessionSnapshot: Equatable {
        let id: UUID
        let displayID: CGDirectDisplayID
        let capturesCursor: Bool
        let state: String
    }

    @Test func addAndLookupSessionTracksCurrentSessions() {
        let service = CapturePreviewService()
        let session = makeSession(id: UUID(), displayID: 7).session

        service.addPreviewSession(session)

        #expect(service.currentSessions.count == 1)
        #expect(service.previewSession(for: session.id)?.displayID == 7)
    }

    @Test func updatePreviewSessionStateMutatesOnlyMatchingSession() {
        let service = CapturePreviewService()
        let first = makeSession(id: UUID(), displayID: 10).session
        let second = makeSession(id: UUID(), displayID: 11).session
        service.addPreviewSession(first)
        service.addPreviewSession(second)

        service.updatePreviewSessionState(id: second.id, state: .active)

        let states = service.currentSessions.reduce(into: [UUID: ScreenPreviewSession.State]()) {
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

    @Test func updatePreviewSessionCapturesCursorMutatesOnlyMatchingSession() {
        let service = CapturePreviewService()
        let first = makeSession(id: UUID(), displayID: 12).session
        let second = makeSession(id: UUID(), displayID: 13).session
        service.addPreviewSession(first)
        service.addPreviewSession(second)

        service.updatePreviewSessionCapturesCursor(id: second.id, capturesCursor: true)

        let cursorStates = service.currentSessions.reduce(into: [UUID: Bool]()) {
            $0[$1.id] = $1.capturesCursor
        }
        #expect(cursorStates[first.id] == false)
        #expect(cursorStates[second.id] == true)
    }

    @Test func updatePreviewSessionStateIgnoresUnknownSessionID() {
        let service = CapturePreviewService()
        let session = makeSession(id: UUID(), displayID: 15).session
        service.addPreviewSession(session)

        service.updatePreviewSessionState(id: UUID(), state: .active)

        #expect(snapshotSignature(service.currentSessions) == [signature(for: session)])
    }

    @Test func updatePreviewSessionStateDoesNotRevertActiveSessionToStarting() {
        let service = CapturePreviewService()
        var activeSession = makeSession(id: UUID(), displayID: 16).session
        activeSession.state = .active
        service.addPreviewSession(activeSession)

        service.updatePreviewSessionState(id: activeSession.id, state: .starting)

        #expect(service.currentSessions.first?.state == .active)
    }

    @Test func updatePreviewSessionCapturesCursorIgnoresUnknownSessionID() {
        let service = CapturePreviewService()
        let session = makeSession(id: UUID(), displayID: 17).session
        service.addPreviewSession(session)

        service.updatePreviewSessionCapturesCursor(id: UUID(), capturesCursor: true)

        #expect(snapshotSignature(service.currentSessions) == [signature(for: session)])
    }

    @Test func removePreviewSessionCancelsSubscription() {
        let service = CapturePreviewService()
        let (session, cancelCount) = makeSession(id: UUID(), displayID: 22)
        service.addPreviewSession(session)

        service.removePreviewSession(id: session.id)

        #expect(service.currentSessions.isEmpty)
        #expect(cancelCount.value == 1)
    }

    @Test func removePreviewSessionIgnoresUnknownSessionID() {
        let service = CapturePreviewService()
        let retained = makeSession(id: UUID(), displayID: 23)
        service.addPreviewSession(retained.session)

        service.removePreviewSession(id: UUID())

        #expect(snapshotSignature(service.currentSessions) == [signature(for: retained.session)])
        #expect(retained.cancelCount.value == 0)
    }

    @Test func removePreviewSessionsCancelsAllMatchingDisplaySessions() {
        let service = CapturePreviewService()
        let first = makeSession(id: UUID(), displayID: 44)
        let second = makeSession(id: UUID(), displayID: 44)
        let third = makeSession(id: UUID(), displayID: 45)
        service.addPreviewSession(first.session)
        service.addPreviewSession(second.session)
        service.addPreviewSession(third.session)

        service.removePreviewSessions(displayID: 44)

        #expect(service.currentSessions.map(\.displayID) == [45])
        #expect(first.cancelCount.value == 1)
        #expect(second.cancelCount.value == 1)
        #expect(third.cancelCount.value == 0)
        #expect(first.cancelCount.value + second.cancelCount.value == 2)
    }

    @Test func removePreviewSessionsIgnoresUnknownDisplayIDAndPreservesOrder() {
        let service = CapturePreviewService()
        let first = makeSession(id: UUID(), displayID: 50)
        let second = makeSession(id: UUID(), displayID: 51)
        let third = makeSession(id: UUID(), displayID: 52)
        service.addPreviewSession(first.session)
        service.addPreviewSession(second.session)
        service.addPreviewSession(third.session)

        service.removePreviewSessions(displayID: 99)

        #expect(snapshotSignature(service.currentSessions) == [
            signature(for: first.session),
            signature(for: second.session),
            signature(for: third.session)
        ])
        #expect(first.cancelCount.value == 0)
        #expect(second.cancelCount.value == 0)
        #expect(third.cancelCount.value == 0)
    }

    @Test func removePreviewSessionsKeepsRemainingOrderAfterCancellingMatches() {
        let service = CapturePreviewService()
        let first = makeSession(id: UUID(), displayID: 60)
        let second = makeSession(id: UUID(), displayID: 61)
        let third = makeSession(id: UUID(), displayID: 60)
        let fourth = makeSession(id: UUID(), displayID: 62)
        service.addPreviewSession(first.session)
        service.addPreviewSession(second.session)
        service.addPreviewSession(third.session)
        service.addPreviewSession(fourth.session)

        service.removePreviewSessions(displayID: 60)

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
    ) -> (session: ScreenPreviewSession, cancelCount: CancellationCounter) {
        let cancelCount = CancellationCounter()
        let subscription = DisplayPreviewSubscription(
            displayID: displayID,
            resolutionText: "1920 x 1080",
            session: CapturePreviewDummySession(),
            cancelClosure: { cancelCount.value += 1 }
        )
        let session = ScreenPreviewSession(
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

    private func snapshotSignature(_ sessions: [ScreenPreviewSession]) -> [SessionSnapshot] {
        sessions.map(signature(for:))
    }

    private func signature(for session: ScreenPreviewSession) -> SessionSnapshot {
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
