@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
import CoreGraphics
import ScreenCaptureKit
import Testing

private final class CaptureMonitoringSessionStoreDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer = TestDisplayShareFrameConsumer()

    nonisolated func attachPreviewSink(_ _: any DisplayPreviewSink) {}

    nonisolated func detachPreviewSink(_ _: any DisplayPreviewSink) {}

    nonisolated func stopSharing() {}

    nonisolated func setDemand(_ _: DisplayCaptureDemandSnapshot) async throws {}

    nonisolated func stop() async {}
}

private final class CaptureMonitoringSessionStoreCancellationCounter: @unchecked Sendable {
    nonisolated(unsafe) var value = 0
}

@Suite(.serialized)
@MainActor
struct CaptureMonitoringSessionStoreTests {
    @Test func addAndLookupSessionTracksCurrentSessions() {
        let store = CaptureMonitoringSessionStore()
        let record = makeSession(id: UUID(), displayID: 801)

        store.add(record.session)

        #expect(store.currentSessions.map(\.id) == [record.session.id])
        #expect(store.session(for: record.session.id)?.displayID == 801)
    }

    @Test func updateStateOnlyAllowsStartingToActive() {
        let starting = makeSession(id: UUID(), displayID: 802).session
        var active = makeSession(id: UUID(), displayID: 803).session
        active.state = .active
        let store = CaptureMonitoringSessionStore(initialSessions: [starting, active])

        store.updateState(id: starting.id, state: .active)
        store.updateState(id: active.id, state: .starting)

        #expect(store.session(for: starting.id)?.state == .active)
        #expect(store.session(for: active.id)?.state == .active)
    }

    @Test func updateCapturesCursorOnlyTouchesMatchingSession() {
        let first = makeSession(id: UUID(), displayID: 804).session
        let second = makeSession(id: UUID(), displayID: 805).session
        let store = CaptureMonitoringSessionStore(initialSessions: [first, second])

        store.updateCapturesCursor(id: second.id, capturesCursor: true)

        #expect(store.session(for: first.id)?.capturesCursor == false)
        #expect(store.session(for: second.id)?.capturesCursor == true)
    }

    @Test func removeByIDCancelsSubscriptionAndDeletesSession() {
        let first = makeSession(id: UUID(), displayID: 806)
        let second = makeSession(id: UUID(), displayID: 807)
        let store = CaptureMonitoringSessionStore(initialSessions: [first.session, second.session])

        store.remove(id: first.session.id)

        #expect(store.currentSessions.map(\.id) == [second.session.id])
        #expect(first.cancelCounter.value == 1)
        #expect(second.cancelCounter.value == 0)
    }

    @Test func removeByDisplayIDCancelsAllMatchingSubscriptionsAndPreservesOthers() {
        let first = makeSession(id: UUID(), displayID: 808)
        let second = makeSession(id: UUID(), displayID: 808)
        let third = makeSession(id: UUID(), displayID: 809)
        let store = CaptureMonitoringSessionStore(initialSessions: [
            first.session,
            second.session,
            third.session
        ])

        store.remove(displayID: 808)

        #expect(store.currentSessions.map(\.displayID) == [809])
        #expect(first.cancelCounter.value == 1)
        #expect(second.cancelCounter.value == 1)
        #expect(third.cancelCounter.value == 0)
    }

    private func makeSession(
        id: UUID,
        displayID: CGDirectDisplayID
    ) -> (
        session: ScreenMonitoringSession,
        cancelCounter: CaptureMonitoringSessionStoreCancellationCounter
    ) {
        let cancelCounter = CaptureMonitoringSessionStoreCancellationCounter()
        let session = ScreenMonitoringSession(
            id: id,
            displayID: displayID,
            displayName: "Display \(displayID)",
            resolutionText: "1920 x 1080",
            isVirtualDisplay: false,
            previewSubscription: DisplayPreviewSubscription(
                displayID: displayID,
                resolutionText: "1920 x 1080",
                session: CaptureMonitoringSessionStoreDummySession(),
                cancelClosure: { cancelCounter.value += 1 }
            ),
            capturesCursor: false,
            state: .starting
        )
        return (session, cancelCounter)
    }
}
