import CoreGraphics
import CoreMedia
import Testing
import Synchronization
@testable import VoidDisplay

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

    nonisolated func submitFrame(_ sampleBuffer: CMSampleBuffer) {
        _ = sampleBuffer
        submissionCount.withLock { $0 += 1 }
    }

    nonisolated func snapshot() -> Int {
        submissionCount.withLock { $0 }
    }
}

@MainActor
@Suite(.serialized)
struct DisplaySampleFanoutTests {
    @Test func detachPreventsQueuedFrameDelivery() async throws {
        let sampleBuffer = try await makeSampleBuffer()
        let fanout = DisplaySampleFanout()
        let sink = CountingPreviewSink()
        fanout.willStartDrainForTesting = {
            fanout.detachPreviewSink(sink)
        }
        fanout.attachPreviewSink(sink)

        fanout.publishPreviewFrame(sampleBuffer)

        let noLateDelivery = await staysTrue(timeout: .milliseconds(100)) {
            sink.snapshot() == 0
        }
        #expect(noLateDelivery)
    }

    private func makeSampleBuffer() async throws -> CMSampleBuffer {
        let session = try UITestCapturePreviewSession(
            configuration: .init(
                sourcePixelSize: CGSize(width: 64, height: 64),
                targetContentWidth: nil,
                replayImageURL: nil,
                recordDirectoryURL: nil,
                initialScaleMode: nil
            )
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
