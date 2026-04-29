@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
import AppKit
import AVFoundation
import CoreGraphics
import Testing

@MainActor
@Suite(.serialized)
struct ZeroCopyPreviewRendererTests {
    @Test func submitFrameRendersAndPublishesMetrics() async throws {
        let renderer = ZeroCopyPreviewRenderer()
        let session = try UITestCapturePreviewSession(
            configuration: .init(
                sourcePixelSize: CGSize(width: 640, height: 360),
                targetContentWidth: nil,
                replayImageURL: nil,
                recordDirectoryURL: nil,
                initialScaleMode: nil
            )
        )

        session.attachPreviewSink(renderer)

        let rendered = await waitUntil {
            await MainActor.run {
                renderer.metricsSnapshot().renderedFrameCount == 1
            }
        }

        let metrics = renderer.metricsSnapshot()
        #expect(rendered)
        #expect(renderer.hasReceivedFrame)
        #expect(renderer.framePixelSize == CGSize(width: 640, height: 360))
        #expect(metrics.receivedFrameCount == 1)
        #expect(metrics.droppedFrameCount == 0)
        #expect(metrics.pendingSlotOccupied == false)
    }

    @Test func latestFrameSlotDropsSupersededFrames() async throws {
        let renderer = ZeroCopyPreviewRenderer()
        let session = try UITestCapturePreviewSession(
            configuration: .init(
                sourcePixelSize: CGSize(width: 800, height: 450),
                targetContentWidth: nil,
                replayImageURL: nil,
                recordDirectoryURL: nil,
                initialScaleMode: nil
            )
        )

        session.attachPreviewSink(renderer)
        session.attachPreviewSink(renderer)

        let settled = await waitUntil {
            await MainActor.run {
                let metrics = renderer.metricsSnapshot()
                return metrics.receivedFrameCount == 2 && metrics.renderedFrameCount >= 1
            }
        }

        let metrics = renderer.metricsSnapshot()
        #expect(settled)
        #expect(metrics.droppedFrameCount >= 1)
    }

    @Test func flushDropsFrameDequeuedBeforeEnqueue() async throws {
        let renderer = ZeroCopyPreviewRenderer()
        renderer.willEnqueueFrameForTesting = {
            renderer.willEnqueueFrameForTesting = nil
            renderer.flush()
        }
        let session = try UITestCapturePreviewSession(
            configuration: .init(
                sourcePixelSize: CGSize(width: 1024, height: 576),
                targetContentWidth: nil,
                replayImageURL: nil,
                recordDirectoryURL: nil,
                initialScaleMode: nil
            )
        )

        session.attachPreviewSink(renderer)

        let settled = await waitUntil {
            await MainActor.run {
                let metrics = renderer.metricsSnapshot()
                return metrics.receivedFrameCount == 1 && metrics.pendingSlotOccupied == false
            }
        }

        let metrics = renderer.metricsSnapshot()
        #expect(settled)
        #expect(metrics.renderedFrameCount == 0)
        #expect(renderer.hasReceivedFrame == false)
    }

    @Test func hostViewDoesNotDuplicateHostedLayer() {
        let view = ZeroCopyHostView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let layer = AVSampleBufferDisplayLayer()

        view.hostDisplayLayer(layer)
        view.hostDisplayLayer(layer)

        #expect(view.layer != nil)
        #expect(view.layer?.sublayers?.count == 1)
        #expect(view.layer?.sublayers?.first === layer)
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
}
