@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
import CoreGraphics
import CoreMedia
import Dispatch
import Testing
import Synchronization

private struct TestSendableSampleBuffer: @unchecked Sendable {
    nonisolated(unsafe) let value: CMSampleBuffer
}

private final class SampleBufferCaptureSink: @unchecked Sendable, DisplayPreviewSink {
    private let latestBuffer = Mutex<TestSendableSampleBuffer?>(nil)

    nonisolated func submitFrame(_ sampleBuffer: CMSampleBuffer) {
        latestBuffer.withLock { $0 = TestSendableSampleBuffer(value: sampleBuffer) }
    }

    nonisolated func snapshot() -> CMSampleBuffer? {
        latestBuffer.withLock { $0?.value }
    }
}

private final class CountingPreviewSink: @unchecked Sendable, DisplayPreviewSink {
    private let submissionCount = Mutex(0)

    nonisolated func submitFrame(_ _: CMSampleBuffer) {
        submissionCount.withLock { $0 += 1 }
    }

    nonisolated func snapshot() -> Int {
        submissionCount.withLock { $0 }
    }
}

private actor BlockingPreviewSinkEntrySignal {
    private var hasEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        guard !hasEntered else { return }
        hasEntered = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    func waitForEntry() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class BlockingPreviewSink: @unchecked Sendable, DisplayPreviewSink {
    private let entrySignal = BlockingPreviewSinkEntrySignal()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let hasEntered = Mutex(false)
    private let completedSubmissions = Mutex(0)

    nonisolated func submitFrame(_ _: CMSampleBuffer) {
        let shouldSignal = hasEntered.withLock { entered -> Bool in
            guard !entered else { return false }
            entered = true
            return true
        }
        if shouldSignal {
            Task {
                await entrySignal.markEntered()
            }
            releaseSemaphore.wait()
        }
        completedSubmissions.withLock { $0 += 1 }
    }

    nonisolated func waitForEntry() async {
        await entrySignal.waitForEntry()
    }

    nonisolated func release() {
        releaseSemaphore.signal()
    }

    nonisolated func completedFrameCount() -> Int {
        completedSubmissions.withLock { $0 }
    }
}

private final class FanoutCompletionFlag: @unchecked Sendable {
    private let isComplete = Mutex(false)

    nonisolated func markComplete() {
        isComplete.withLock { $0 = true }
    }

    nonisolated func snapshot() -> Bool {
        isComplete.withLock { $0 }
    }
}

@MainActor
@Suite(.serialized)
struct DisplaySampleFanoutTests {
    @Test func slowSinkDoesNotBlockPublishingNewFrame() async throws {
        let first = try await makeSampleBuffer()
        let second = try await makeSampleBuffer()
        let fanout = DisplaySampleFanout()
        let sink = BlockingPreviewSink()
        let completionFlag = FanoutCompletionFlag()
        let sendableSecond = TestSendableSampleBuffer(value: second)
        fanout.attachPreviewSink(sink)

        fanout.publishPreviewFrame(first)
        await sink.waitForEntry()

        let publishTask = publishDetachedFrame(
            fanout: fanout,
            sampleBuffer: sendableSecond,
            completionFlag: completionFlag
        )

        let publishedWithoutBlocking = await waitUntil(timeout: .milliseconds(150)) {
            completionFlag.snapshot()
        }
        #expect(publishedWithoutBlocking)

        sink.release()
        await publishTask.value
        let finishedBothFrames = await waitUntil { sink.completedFrameCount() == 2 }
        #expect(finishedBothFrames)
    }

    nonisolated private func publishDetachedFrame(
        fanout: DisplaySampleFanout,
        sampleBuffer: TestSendableSampleBuffer,
        completionFlag: FanoutCompletionFlag
    ) -> Task<Void, Never> {
        Task.detached {
            fanout.publishPreviewFrame(sampleBuffer.value)
            completionFlag.markComplete()
        }
    }

    private func makeSampleBuffer() async throws -> CMSampleBuffer {
        let session = try TestCapturePreviewSession(
            sourcePixelSize: CGSize(width: 64, height: 64)
        )
        let sink = SampleBufferCaptureSink()
        session.attachPreviewSink(sink)
        let captured = await waitUntil { sink.snapshot() != nil }
        #expect(captured)
        return try #require(sink.snapshot())
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return await condition()
    }

    private func staysTrue(
        timeout: Duration,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() == false {
                return false
            }
            await Task.yield()
        }
        return await condition()
    }
}
