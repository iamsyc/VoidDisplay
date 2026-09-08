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

private final class BlockingPreviewSink: @unchecked Sendable, DisplayPreviewSink {
    private let entrySemaphore = DispatchSemaphore(value: 0)
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
            entrySemaphore.signal()
            releaseSemaphore.wait()
        }
        completedSubmissions.withLock { $0 += 1 }
    }

    nonisolated func waitForEntry() -> Bool {
        entrySemaphore.wait(timeout: .now() + .seconds(1)) == .success
    }

    nonisolated func release() {
        releaseSemaphore.signal()
    }

    nonisolated func completedFrameCount() -> Int {
        completedSubmissions.withLock { $0 }
    }
}

@MainActor
@Suite(.serialized)
struct DisplaySampleFanoutTests {
    @Test func slowSinkDoesNotBlockPublishingNewFrame() async throws {
        let first = TestSendableSampleBuffer(value: try await makeSampleBuffer())
        let second = TestSendableSampleBuffer(value: try await makeSampleBuffer())
        let fanout = DisplaySampleFanout()
        let sink = BlockingPreviewSink()
        fanout.attachPreviewSink(sink)

        // The deliberately blocked sink must not depend on cooperative tasks to release it.
        let result: (entered: Bool, published: Bool) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let publisher = DispatchQueue(label: "VoidDisplayTests.FanoutPublisher")
                publisher.async { fanout.publishPreviewFrame(first.value) }
                let entered = sink.waitForEntry()
                let published = DispatchSemaphore(value: 0)
                publisher.async {
                    fanout.publishPreviewFrame(second.value)
                    published.signal()
                }
                let publishedWithoutBlocking = published.wait(timeout: .now() + .milliseconds(150)) == .success
                sink.release()
                continuation.resume(returning: (entered, publishedWithoutBlocking))
            }
        }
        #expect(result.entered)
        #expect(result.published)

        let finishedBothFrames = await waitUntil { sink.completedFrameCount() == 2 }
        #expect(finishedBothFrames)
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
