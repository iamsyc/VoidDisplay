import AppKit
import AVFoundation
import SwiftUI
import Synchronization

@Observable
final class ZeroCopyPreviewRenderer: @unchecked Sendable, DisplayPreviewSink {
    struct MetricsSnapshot: Sendable {
        var receivedFrameCount: UInt64
        var renderedFrameCount: UInt64
        var droppedFrameCount: UInt64
        var latestRenderLatencyMilliseconds: Double?
        var pendingSlotOccupied: Bool
    }

    private struct PendingFrame {
        let buffer: UncheckedSendableBuffer
        let submittedAtNanoseconds: UInt64
        let generation: UInt64
    }

    private struct State {
        var pendingFrame: PendingFrame?
        var isDraining = false
        var activeDrainToken: UInt64?
        var nextDrainToken: UInt64 = 0
        var generation: UInt64 = 0
        var receivedFrameCount: UInt64 = 0
        var renderedFrameCount: UInt64 = 0
        var droppedFrameCount: UInt64 = 0
        var latestRenderLatencyMilliseconds: Double?
    }

    var framePixelSize: CGSize = .zero
    var hasReceivedFrame = false

    let displayLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.preventsDisplaySleepDuringVideoPlayback = false
        return layer
    }()

    nonisolated private let state = Mutex(State())
    @MainActor var willEnqueueFrameForTesting: (() -> Void)?

    nonisolated func submitFrame(_ sampleBuffer: CMSampleBuffer) {
        let box = UncheckedSendableBuffer(sampleBuffer)
        let drainToken = state.withLock { state -> UInt64? in
            state.receivedFrameCount &+= 1
            if state.pendingFrame != nil {
                state.droppedFrameCount &+= 1
            }
            state.pendingFrame = PendingFrame(
                buffer: box,
                submittedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
                generation: state.generation
            )
            guard !state.isDraining else { return nil }
            state.isDraining = true
            state.nextDrainToken &+= 1
            state.activeDrainToken = state.nextDrainToken
            return state.nextDrainToken
        }
        guard let drainToken else { return }

        Task { @MainActor [weak self] in
            self?.drainLoop(drainToken: drainToken)
        }
    }

    func flush() {
        state.withLock { state in
            state.pendingFrame = nil
            state.generation &+= 1
            state.activeDrainToken = nil
            state.isDraining = false
        }
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
    }

    nonisolated func metricsSnapshot() -> MetricsSnapshot {
        state.withLock { state in
            .init(
                receivedFrameCount: state.receivedFrameCount,
                renderedFrameCount: state.renderedFrameCount,
                droppedFrameCount: state.droppedFrameCount,
                latestRenderLatencyMilliseconds: state.latestRenderLatencyMilliseconds,
                pendingSlotOccupied: state.pendingFrame != nil
            )
        }
    }

    @MainActor
    private func drainLoop(drainToken: UInt64) {
        while true {
            let nextFrame = state.withLock { state -> PendingFrame? in
                guard state.activeDrainToken == drainToken else {
                    return nil
                }
                guard let pendingFrame = state.pendingFrame else {
                    state.activeDrainToken = nil
                    state.isDraining = false
                    return nil
                }
                state.pendingFrame = nil
                return pendingFrame
            }
            guard let nextFrame else { return }

            willEnqueueFrameForTesting?()
            let shouldRender = state.withLock { state in
                state.activeDrainToken == drainToken && state.generation == nextFrame.generation
            }
            guard shouldRender else { continue }

            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
            }
            renderer.enqueue(nextFrame.buffer.buffer)

            if !hasReceivedFrame {
                hasReceivedFrame = true
            }

            if let desc = CMSampleBufferGetFormatDescription(nextFrame.buffer.buffer) {
                let dims = CMVideoFormatDescriptionGetDimensions(desc)
                let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
                if framePixelSize != size {
                    framePixelSize = size
                }
            }

            let latencyMilliseconds = Double(
                DispatchTime.now().uptimeNanoseconds &- nextFrame.submittedAtNanoseconds
            ) / 1_000_000
            state.withLock { state in
                state.renderedFrameCount &+= 1
                state.latestRenderLatencyMilliseconds = latencyMilliseconds
            }
        }
    }
}

struct UncheckedSendableBuffer: @unchecked Sendable {
    nonisolated(unsafe) let buffer: CMSampleBuffer
    nonisolated init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
}

struct ZeroCopyPreviewLayerView: NSViewRepresentable {
    let renderer: ZeroCopyPreviewRenderer

    func makeNSView(context: Context) -> ZeroCopyHostView {
        let view = ZeroCopyHostView()
        view.hostDisplayLayer(renderer.displayLayer)
        return view
    }

    func updateNSView(_: ZeroCopyHostView, context: Context) {}
}

final class ZeroCopyHostView: NSView {
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    func hostDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        displayLayer = layer
        syncLayerScale()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer?.frame = bounds
        CATransaction.commit()
        syncLayerScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncLayerScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncLayerScale()
    }

    private func syncLayerScale() {
        let scale = max(1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        layer?.contentsScale = scale
        displayLayer?.contentsScale = scale
    }
}
