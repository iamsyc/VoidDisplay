import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import VoidDisplay

private final class TestPreviewSink: @unchecked Sendable, DisplayPreviewSink {
    nonisolated func submitFrame(_ sampleBuffer: CMSampleBuffer) {
        _ = sampleBuffer
    }
}

private final class MockDisplayCaptureSession: @unchecked Sendable, DisplayCaptureSessioning {
    private struct State: Sendable {
        var attachedSinks: Set<ObjectIdentifier> = []
        var attachCallCount = 0
        var detachCallCount = 0
        var stopSharingCallCount = 0
        var stopCallCount = 0
    }

    nonisolated let sessionHub = WebRTCSessionHub()
    private let state = Mutex(State())

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        let key = ObjectIdentifier(sink as AnyObject)
        state.withLock { state in
            state.attachCallCount += 1
            state.attachedSinks.insert(key)
        }
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        let key = ObjectIdentifier(sink as AnyObject)
        state.withLock { state in
            state.detachCallCount += 1
            state.attachedSinks.remove(key)
        }
    }

    nonisolated func stopSharing() {
        state.withLock { $0.stopSharingCallCount += 1 }
    }

    nonisolated func setPreviewShowsCursor(_ showsCursor: Bool) async throws {
        _ = showsCursor
    }

    nonisolated func retainShareCursorOverride() async throws {}

    nonisolated func releaseShareCursorOverride() async throws {}

    nonisolated func stop() async {
        state.withLock { $0.stopCallCount += 1 }
    }

    func snapshot() -> (attached: Int, attach: Int, detach: Int) {
        state.withLock { ($0.attachedSinks.count, $0.attachCallCount, $0.detachCallCount) }
    }
}

struct DisplayPreviewSubscriptionTests {
    @Test func cancel_detachesAttachedSinks() {
        let session = MockDisplayCaptureSession()
        let cancelCalls = Mutex(0)
        let subscription = DisplayPreviewSubscription(
            displayID: 1,
            resolutionText: "100 × 100",
            session: session,
            cancelClosure: { cancelCalls.withLock { $0 += 1 } }
        )
        let sink = TestPreviewSink()
        subscription.attachPreviewSink(sink)

        subscription.cancel()

        let snap = session.snapshot()
        #expect(snap.attached == 0)
        #expect(snap.detach == 1)
        #expect(cancelCalls.withLock { $0 } == 1)
    }

    @Test func cancel_isIdempotent() {
        let session = MockDisplayCaptureSession()
        let cancelCalls = Mutex(0)
        let subscription = DisplayPreviewSubscription(
            displayID: 1,
            resolutionText: "100 × 100",
            session: session,
            cancelClosure: { cancelCalls.withLock { $0 += 1 } }
        )
        let sink = TestPreviewSink()
        subscription.attachPreviewSink(sink)

        subscription.cancel()
        subscription.cancel()

        let snap = session.snapshot()
        #expect(snap.attached == 0)
        #expect(snap.detach == 1)
        #expect(cancelCalls.withLock { $0 } == 1)
    }
}
