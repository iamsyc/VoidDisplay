import AppKit
import AVFoundation
import CoreImage
import Metal
import MetalKit
import SwiftUI

struct CaptureDisplayView: View {
    let sessionId: UUID

    @Environment(CaptureController.self) private var capture
    @Environment(\.dismiss) private var dismiss

    @State private var renderer = DisplayPreviewRenderer()
    @State private var window: NSWindow?
    @State private var hasAppliedInitialSize = false

    private var session: ScreenMonitoringSession? {
        capture.monitoringSession(for: sessionId)
    }

    var body: some View {
        ZStack {
            Color.black
            if let session {
                DisplayPreviewView(renderer: renderer)
                    .onAppear {
                        session.previewSubscription.attachPreviewSink(renderer)
                        capture.markMonitoringSessionActive(id: sessionId)
                    }
                    .onDisappear {
                        session.previewSubscription.detachPreviewSink(renderer)
                    }
            } else {
                Text("No Data")
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .clipped()
        .onChange(of: capture.screenCaptureSessions.map(\.id)) { _, ids in
            if !ids.contains(sessionId) {
                dismiss()
            }
        }
        .onDisappear {
            if let session {
                session.previewSubscription.detachPreviewSink(renderer)
            }
            capture.removeMonitoringSession(id: sessionId)
        }
        .overlay {
            WindowAccessor { currentWindow in
                if window !== currentWindow {
                    window = currentWindow
                    applyWindowAspectIfNeeded()
                }
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func applyWindowAspectIfNeeded() {
        let preferredAspect = preferredAspectFromSessionResolution()
        guard
            let window,
            preferredAspect.width > 0,
            preferredAspect.height > 0
        else { return }

        let currentContentRect = window.contentRect(forFrameRect: window.frame)
        guard currentContentRect.width > 0, currentContentRect.height > 0 else { return }
        if hasAppliedInitialSize { return }

        let targetAspectRatio = preferredAspect.width / preferredAspect.height
        window.contentAspectRatio = NSSize(width: preferredAspect.width, height: preferredAspect.height)

        let frameChromeWidth = window.frame.width - currentContentRect.width
        let frameChromeHeight = window.frame.height - currentContentRect.height
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame

        let maxContentWidth = max(320, (visibleFrame?.width ?? currentContentRect.width) - frameChromeWidth - 16)
        let maxContentHeight = max(180, (visibleFrame?.height ?? currentContentRect.height) - frameChromeHeight - 16)

        let idealContentHeight = min(maxContentHeight, (visibleFrame?.height ?? 800) * 0.6)
        var targetContentWidth = idealContentHeight * targetAspectRatio
        var targetContentHeight = idealContentHeight

        if targetContentWidth > maxContentWidth {
            targetContentWidth = maxContentWidth
            targetContentHeight = targetContentWidth / targetAspectRatio
        }

        if targetContentHeight > maxContentHeight {
            targetContentHeight = maxContentHeight
            targetContentWidth = targetContentHeight * targetAspectRatio
        }

        let targetContentSize = NSSize(width: targetContentWidth, height: targetContentHeight)
        let targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContentSize))
        var newFrame = window.frame
        newFrame.origin.x += (newFrame.width - targetFrame.width) / 2
        newFrame.origin.y += (newFrame.height - targetFrame.height) / 2
        newFrame.size = targetFrame.size
        window.setFrame(newFrame, display: true, animate: false)
        hasAppliedInitialSize = true
    }

    private func preferredAspectFromSessionResolution() -> CGSize {
        guard let text = session?.resolutionText else { return .zero }

        let separators = ["×", "x", "X", "*"]
        guard let separator = separators.first(where: { text.contains($0) }) else { return .zero }
        let parts = text.split(separator: Character(separator), maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard
            parts.count == 2,
            let width = Double(parts[0]),
            let height = Double(parts[1]),
            width > 0,
            height > 0
        else {
            return .zero
        }
        return CGSize(width: width, height: height)
    }
}

@MainActor
private struct DisplayPreviewView: NSViewRepresentable {
    let renderer: DisplayPreviewRenderer

    func makeNSView(context: Context) -> DisplayPreviewMetalView {
        let view = DisplayPreviewMetalView(renderer: renderer)
        return view
    }

    func updateNSView(_ nsView: DisplayPreviewMetalView, context: Context) {}
}

final class DisplayPreviewRenderer: NSObject, DisplayPreviewSink, MTKViewDelegate {
    private let lock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var ciContext: CIContext?

    func configure(device: MTLDevice) {
        if ciContext == nil {
            ciContext = CIContext(mtlDevice: device)
        }
    }

    func submitFrame(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        latestPixelBuffer = pixelBuffer
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let ciContext,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return }

        lock.lock()
        let pixelBuffer = latestPixelBuffer
        lock.unlock()
        guard let pixelBuffer else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let bounds = CGRect(origin: .zero, size: view.drawableSize)
        let targetRect = AVMakeRect(aspectRatio: image.extent.size, insideRect: bounds)
        ciContext.render(image, to: drawable.texture, commandBuffer: nil, bounds: targetRect, colorSpace: colorSpace)
        drawable.present()
    }
}

final class DisplayPreviewMetalView: MTKView {
    init(renderer: DisplayPreviewRenderer) {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        guard let device else { return }
        renderer.configure(device: device)
        self.delegate = renderer
        framebufferOnly = false
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 120
        colorPixelFormat = .bgra8Unorm
        wantsLayer = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}
