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
        var reportedSamples: [DisplayPreviewPerformanceSample] = []
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

    nonisolated func reportPreviewPerformanceSample(_ sample: DisplayPreviewPerformanceSample) {
        state.withLock { $0.reportedSamples.append(sample) }
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

    func reportedSamples() -> [DisplayPreviewPerformanceSample] {
        state.withLock { $0.reportedSamples }
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

    @Test func duplicateAttachDoesNotForwardToSessionTwice() {
        let session = MockDisplayCaptureSession()
        let subscription = DisplayPreviewSubscription(
            displayID: 1,
            resolutionText: "100 × 100",
            session: session,
            cancelClosure: {}
        )
        let sink = TestPreviewSink()

        subscription.attachPreviewSink(sink)
        subscription.attachPreviewSink(sink)

        let snap = session.snapshot()
        #expect(snap.attached == 1)
        #expect(snap.attach == 1)
        #expect(snap.detach == 0)
    }

    @Test func extraDetachDoesNotForwardToSessionAgain() {
        let session = MockDisplayCaptureSession()
        let subscription = DisplayPreviewSubscription(
            displayID: 1,
            resolutionText: "100 × 100",
            session: session,
            cancelClosure: {}
        )
        let sink = TestPreviewSink()

        subscription.attachPreviewSink(sink)
        subscription.detachPreviewSink(sink)
        subscription.detachPreviewSink(sink)

        let snap = session.snapshot()
        #expect(snap.attached == 0)
        #expect(snap.attach == 1)
        #expect(snap.detach == 1)
    }

    @Test func performanceSampleForwardsToSession() {
        let session = MockDisplayCaptureSession()
        let subscription = DisplayPreviewSubscription(
            displayID: 1,
            resolutionText: "100 × 100",
            session: session,
            cancelClosure: {}
        )
        let sample = DisplayPreviewPerformanceSample(
            renderedFrameCount: 120,
            droppedFrameCount: 4,
            latestRenderLatencyMilliseconds: 18,
            pendingSlotOccupied: false,
            capturedAt: 99
        )

        subscription.reportPerformanceSample(sample)

        #expect(session.reportedSamples() == [sample])
    }
}
