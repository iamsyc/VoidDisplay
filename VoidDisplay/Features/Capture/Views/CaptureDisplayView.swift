import AppKit
import AVFoundation
import SwiftUI

// MARK: - Capture Display View

struct CaptureDisplayView: View {
    let sessionId: UUID

    @Environment(CaptureController.self) private var capture
    @Environment(\.dismiss) private var dismiss

    @State private var renderer = ZeroCopyPreviewRenderer()
    @State private var window: NSWindow?
    @State private var hasAppliedInitialSize = false

    private var session: ScreenMonitoringSession? {
        capture.monitoringSession(for: sessionId)
    }

    var body: some View {
        ZStack {
            Color.black
            if session != nil {
                if renderer.hasReceivedFrame {
                    ZeroCopyPreviewLayerView(renderer: renderer)
                } else {
                    Text("Loading...")
                        .foregroundStyle(.white.opacity(0.85))
                }
            } else {
                Text("No Data")
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: capture.screenCaptureSessions.map(\.id)) { _, ids in
            if !ids.contains(sessionId) {
                dismiss()
            }
        }
        .onAppear {
            if let session {
                session.previewSubscription.attachPreviewSink(renderer)
                capture.markMonitoringSessionActive(id: sessionId)
            } else {
                dismiss()
            }
        }
        .onDisappear {
            if let session {
                session.previewSubscription.detachPreviewSink(renderer)
            }
            renderer.flush()
            capture.removeMonitoringSession(id: sessionId)
        }
        .onChange(of: renderer.framePixelSize) { _, _ in
            applyInitialWindowSize()
        }
        .overlay {
            WindowAccessor { resolvedWindow in
                if window !== resolvedWindow {
                    window = resolvedWindow
                    applyInitialWindowSize()
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Window Sizing

extension CaptureDisplayView {

    /// Sets the window's initial size and aspect ratio to match the
    /// captured display.  Called once when both the window reference
    /// and the first frame's pixel dimensions become available.
    private func applyInitialWindowSize() {
        let aspect = preferredAspect()
        guard let window, aspect.width > 0, aspect.height > 0, !hasAppliedInitialSize else { return }

        window.backgroundColor = .black
        window.contentAspectRatio = NSSize(width: aspect.width, height: aspect.height)

        let contentRect = window.contentRect(forFrameRect: window.frame)
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let chromeWidth = window.frame.width - contentRect.width
        let chromeHeight = window.frame.height - contentRect.height

        let maxW = max(320, (visibleFrame?.width ?? 1280) - chromeWidth - 16)
        let maxH = max(180, (visibleFrame?.height ?? 800) - chromeHeight - 16)

        let ratio = aspect.width / aspect.height
        let idealH = min(maxH, (visibleFrame?.height ?? 800) * 0.6)
        var w = idealH * ratio
        var h = idealH

        if w > maxW { w = maxW; h = w / ratio }
        if h > maxH { h = maxH; w = h * ratio }

        let targetFrame = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: NSSize(width: w, height: h))
        )
        var newFrame = window.frame
        newFrame.origin.x += (newFrame.width - targetFrame.width) / 2
        newFrame.origin.y += (newFrame.height - targetFrame.height) / 2
        newFrame.size = targetFrame.size
        window.setFrame(newFrame, display: true, animate: false)

        hasAppliedInitialSize = true
    }

    /// Determines the preferred aspect ratio from the session's
    /// resolution text (e.g. "2560 × 1440"), falling back to the
    /// pixel size reported by the renderer's first frame.
    private func preferredAspect() -> CGSize {
        if let text = session?.resolutionText,
           let size = Self.parseResolution(text) {
            return size
        }
        return renderer.framePixelSize
    }

    private static func parseResolution(_ text: String) -> CGSize? {
        let separators: [Character] = ["×", "x", "X", "*"]
        guard let sep = separators.first(where: { text.contains($0) }) else { return nil }
        let parts = text.split(separator: sep, maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2,
              let w = Double(parts[0]), w > 0,
              let h = Double(parts[1]), h > 0
        else { return nil }
        return CGSize(width: w, height: h)
    }
}

// MARK: - Zero-Copy Preview Renderer

/// Renders captured frames via `AVSampleBufferDisplayLayer` with zero
/// pixel-data copies.  The layer natively accepts `CMSampleBuffer`
/// backed by `IOSurface`, handling YUV→RGB conversion and colour
/// management entirely on the GPU.
@Observable
final class ZeroCopyPreviewRenderer: DisplayPreviewSink {
    var framePixelSize: CGSize = .zero
    var hasReceivedFrame = false

    let displayLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.preventsDisplaySleepDuringVideoPlayback = false
        return layer
    }()

    nonisolated func submitFrame(_ sampleBuffer: CMSampleBuffer) {
        let box = UncheckedSendableBuffer(sampleBuffer)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let renderer = self.displayLayer.sampleBufferRenderer

            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(box.buffer)

            if !self.hasReceivedFrame {
                self.hasReceivedFrame = true
            }

            if let desc = CMSampleBufferGetFormatDescription(box.buffer) {
                let dims = CMVideoFormatDescriptionGetDimensions(desc)
                let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
                if self.framePixelSize != size {
                    self.framePixelSize = size
                }
            }
        }
    }

    func flush() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
    }
}

/// Wraps `CMSampleBuffer` for safe cross-isolation transfer.
private struct UncheckedSendableBuffer: @unchecked Sendable {
    nonisolated(unsafe) let buffer: CMSampleBuffer
    nonisolated init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
}

// MARK: - Layer Host View

private struct ZeroCopyPreviewLayerView: NSViewRepresentable {
    let renderer: ZeroCopyPreviewRenderer

    func makeNSView(context: Context) -> ZeroCopyHostView {
        let view = ZeroCopyHostView()
        view.hostDisplayLayer(renderer.displayLayer)
        return view
    }

    func updateNSView(_: ZeroCopyHostView, context: Context) {}
}

private final class ZeroCopyHostView: NSView {
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    func hostDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        wantsLayer = true
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        displayLayer = layer
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer?.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Window Accessor

/// Invisible helper that resolves the hosting `NSWindow` reference
/// and delivers it via a callback.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window { onResolve(window) }
        }
    }
}
