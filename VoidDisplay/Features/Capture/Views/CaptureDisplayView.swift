import AppKit
import AVFoundation
import SwiftUI

// MARK: - Capture Display View

struct CaptureDisplayView: View {
    private enum PreviewScaleMode: Hashable {
        case fit
        case native
    }

    let sessionId: UUID

    @Environment(CaptureController.self) private var capture
    @Environment(SharingController.self) private var sharing
    @Environment(\.dismiss) private var dismiss

    @State private var renderer = ZeroCopyPreviewRenderer()
    @State private var recordingSink: CapturePreviewRecordingSink?
    @State private var window: NSWindow?
    @State private var windowCoordinator = CapturePreviewWindowCoordinator()
    @State private var hasAppliedInitialSize = false
    @State private var scaleMode: PreviewScaleMode = .fit
    @State private var capturesCursor = false
    @State private var isUpdatingCursorCapture = false

    private var session: ScreenMonitoringSession? {
        capture.monitoringSession(for: sessionId)
    }

    private var isSharingDisplay: Bool {
        guard let displayID = session?.displayID else { return false }
        return sharing.isDisplaySharing(displayID: displayID)
    }

    private var effectiveCapturesCursor: Bool {
        capturesCursor || isSharingDisplay
    }

    private var currentScaleFactor: CGFloat {
        max(1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
    }

    private var nativeFrameSizeInPoints: CGSize {
        CapturePreviewGeometry.nativeFrameSizeInPoints(
            framePixelSize: renderer.framePixelSize,
            scaleFactor: currentScaleFactor,
            fallbackAspect: preferredAspect()
        )
    }

    @ViewBuilder
    private var previewContent: some View {
        if session != nil {
            if renderer.hasReceivedFrame {
                if scaleMode == .fit {
                    ZeroCopyPreviewLayerView(renderer: renderer)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        ZeroCopyPreviewLayerView(renderer: renderer)
                            .frame(
                                width: nativeFrameSizeInPoints.width,
                                height: nativeFrameSizeInPoints.height
                            )
                            .background(Color.black)
                    }
                    .background(TransparentScrollViewConfigurator())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("Loading...")
                    .foregroundStyle(.white.opacity(0.85))
            }
        } else {
            Text("No Data")
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            previewContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture_preview_content")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Scale Mode", selection: $scaleMode) {
                    Text("Fit").tag(PreviewScaleMode.fit)
                    Text("1:1").tag(PreviewScaleMode.native)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 150)
                .accessibilityIdentifier("capture_preview_scale_mode_picker")
                .accessibilityValue(Text(scaleMode == .fit ? "fit" : "native"))
            }
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 6) {
                    Text(String(localized: "Cursor"))
                    Toggle("", isOn: cursorCaptureBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(isUpdatingCursorCapture || isSharingDisplay)
                        .accessibilityIdentifier("capture_preview_cursor_toggle")
                }
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            if let diagnosticsScaleMode = initialPreviewScaleModeOverride {
                scaleMode = diagnosticsScaleMode
            }
            windowCoordinator.update(aspect: preferredAspect(), shouldLockAspect: scaleMode == .fit)
            capturesCursor = session?.capturesCursor ?? false
        }
        .onChange(of: scaleMode) { _, newValue in
            windowCoordinator.update(aspect: preferredAspect(), shouldLockAspect: newValue == .fit)
            if let window {
                if newValue == .fit {
                    windowCoordinator.snapWindowToAspect(window)
                }
            }
        }
        .onChange(of: capture.screenCaptureSessions.map(\.id)) { _, ids in
            if !ids.contains(sessionId) {
                dismiss()
            }
        }
        .onChange(of: session?.capturesCursor ?? false) { _, newValue in
            if !isUpdatingCursorCapture {
                capturesCursor = newValue
            }
        }
        .onAppear {
            if let session {
                session.previewSubscription.attachPreviewSink(renderer)
                if let destinationDirectory = CapturePreviewDiagnosticsRuntime.configuration()?.recordDirectoryURL {
                    let sink = CapturePreviewRecordingSink(
                        destinationDirectory: destinationDirectory,
                        session: session
                    )
                    recordingSink = sink
                    session.previewSubscription.attachPreviewSink(sink)
                }
                capture.markMonitoringSessionActive(id: sessionId)
            } else {
                dismiss()
            }
        }
        .onDisappear {
            if let session {
                if let recordingSink {
                    session.previewSubscription.detachPreviewSink(recordingSink)
                }
                session.previewSubscription.detachPreviewSink(renderer)
            }
            windowCoordinator.tearDown()
            renderer.flush()
            capture.removeMonitoringSession(id: sessionId)
        }
        .onChange(of: renderer.framePixelSize) { _, _ in
            windowCoordinator.update(aspect: preferredAspect(), shouldLockAspect: scaleMode == .fit)
            applyInitialWindowSize()
        }
        .overlay {
            WindowAccessor { resolvedWindow in
                if window !== resolvedWindow {
                    window = resolvedWindow
                    windowCoordinator.attach(to: resolvedWindow)
                    windowCoordinator.update(
                        aspect: preferredAspect(),
                        shouldLockAspect: scaleMode == .fit
                    )
                    applyInitialWindowSize()
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Window Sizing

extension CaptureDisplayView {
    private var cursorCaptureBinding: Binding<Bool> {
        Binding(
            get: { effectiveCapturesCursor },
            set: { newValue in
                guard !isSharingDisplay else { return }
                let previousValue = capturesCursor
                capturesCursor = newValue

                guard let session else { return }
                isUpdatingCursorCapture = true
                Task {
                    do {
                        try await session.previewSubscription.setShowsCursor(newValue)
                        await MainActor.run {
                            capture.setMonitoringSessionCapturesCursor(
                                id: sessionId,
                                capturesCursor: newValue
                            )
                            isUpdatingCursorCapture = false
                        }
                    } catch {
                        AppErrorMapper.logFailure(
                            "Update cursor capture",
                            error: error,
                            logger: AppLog.capture
                        )
                        await MainActor.run {
                            capturesCursor = previousValue
                            isUpdatingCursorCapture = false
                        }
                    }
                }
            }
        )
    }

    /// Sets the window's initial size and aspect ratio to match the
    /// captured display.  Called once when both the window reference
    /// and the first frame's pixel dimensions become available.
    private func applyInitialWindowSize() {
        let aspect = preferredAspect()
        guard let window, aspect.width > 0, aspect.height > 0, !hasAppliedInitialSize else { return }

        window.backgroundColor = .windowBackgroundColor
        let contentRect = window.contentRect(forFrameRect: window.frame)
        let layoutRect = window.contentLayoutRect
        let targetContentSize = CapturePreviewGeometry.initialContentSize(
            input: .init(
                aspect: aspect,
                framePixelSize: renderer.framePixelSize,
                targetContentWidth: CapturePreviewDiagnosticsRuntime.configuration()?.targetContentWidth,
                visibleFrameSize: (window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)?.size
                    ?? CGSize(width: 1280, height: 800),
                chromeSize: CGSize(
                    width: max(0, window.frame.width - contentRect.width),
                    height: max(0, window.frame.height - contentRect.height)
                ),
                layoutInsetSize: CGSize(
                    width: max(0, contentRect.width - layoutRect.width),
                    height: max(0, contentRect.height - layoutRect.height)
                ),
                scaleFactor: max(1, window.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
            )
        )
        guard let targetContentSize else { return }

        let targetFrame = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: NSSize(
                width: targetContentSize.width,
                height: targetContentSize.height
            ))
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
        CapturePreviewGeometry.preferredAspect(
            resolutionText: session?.resolutionText,
            framePixelSize: renderer.framePixelSize
        )
    }

    private var initialPreviewScaleModeOverride: PreviewScaleMode? {
        guard let override = CapturePreviewDiagnosticsRuntime.configuration()?.initialScaleMode else {
            return nil
        }
        switch override {
        case .fit:
            return .fit
        case .native:
            return .native
        }
    }
}

// MARK: - Window Coordination

private final class CapturePreviewWindowCoordinator: NSObject {
    private weak var window: NSWindow?
    nonisolated(unsafe) private var forwardedDelegate: (any NSWindowDelegate)?
    private var aspect = CGSize.zero
    private var shouldLockAspect = true

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        restoreWindowDelegate()
        self.window = window
        if let delegate = window.delegate, delegate !== self {
            forwardedDelegate = delegate
        } else {
            forwardedDelegate = nil
        }
        window.delegate = self
    }

    func update(aspect: CGSize, shouldLockAspect: Bool) {
        self.aspect = aspect
        self.shouldLockAspect = shouldLockAspect
    }

    func snapWindowToAspect(_ window: NSWindow) {
        guard shouldLockAspect, aspect.width > 0, aspect.height > 0 else { return }
        let targetSize = aspectLockedFrameSize(for: window, proposedFrameSize: window.frame.size)
        guard abs(targetSize.width - window.frame.width) > 0.5
                || abs(targetSize.height - window.frame.height) > 0.5 else { return }

        var newFrame = window.frame
        newFrame.origin.x += (newFrame.width - targetSize.width) / 2
        newFrame.origin.y += (newFrame.height - targetSize.height) / 2
        newFrame.size = targetSize
        window.setFrame(newFrame, display: true, animate: false)
    }

    func tearDown() {
        restoreWindowDelegate()
        window = nil
        forwardedDelegate = nil
    }

    private func aspectLockedFrameSize(for window: NSWindow, proposedFrameSize: NSSize) -> NSSize {
        guard let targetContentSize = aspectLockedContentSize(
            for: window,
            proposedFrameSize: proposedFrameSize
        ) else {
            return proposedFrameSize
        }

        let targetContentRect = NSRect(origin: .zero, size: targetContentSize)
        return window.frameRect(forContentRect: targetContentRect).size
    }

    private func aspectLockedContentSize(for window: NSWindow, proposedFrameSize: NSSize) -> NSSize? {
        let currentContentRect = window.contentRect(forFrameRect: window.frame)
        let currentLayoutRect = window.contentLayoutRect
        let proposedContentRect = window.contentRect(
            forFrameRect: NSRect(origin: .zero, size: proposedFrameSize)
        )
        let targetContentSize = CapturePreviewGeometry.aspectLockedContentSize(
            aspect: aspect,
            proposedContentSize: proposedContentRect.size,
            layoutInsetSize: CGSize(
                width: max(0, currentContentRect.width - currentLayoutRect.width),
                height: max(0, currentContentRect.height - currentLayoutRect.height)
            ),
            scaleFactor: max(1, window.backingScaleFactor)
        )
        guard let targetContentSize else { return nil }
        return NSSize(width: targetContentSize.width, height: targetContentSize.height)
    }

    private func restoreWindowDelegate() {
        guard let window, window.delegate === self else { return }
        window.delegate = forwardedDelegate
    }
}

extension CapturePreviewWindowCoordinator: NSWindowDelegate {
    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (forwardedDelegate?.responds(to: aSelector) ?? false)
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if forwardedDelegate?.responds(to: aSelector) == true {
            return forwardedDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposedFrameSize = forwardedDelegate?.windowWillResize?(sender, to: frameSize) ?? frameSize
        guard shouldLockAspect, aspect.width > 0, aspect.height > 0 else {
            return proposedFrameSize
        }
        return aspectLockedFrameSize(for: sender, proposedFrameSize: proposedFrameSize)
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let proposedFrame = forwardedDelegate?.windowWillUseStandardFrame?(window, defaultFrame: newFrame)
            ?? newFrame
        guard shouldLockAspect, aspect.width > 0, aspect.height > 0 else {
            return proposedFrame
        }

        let targetSize = aspectLockedFrameSize(for: window, proposedFrameSize: proposedFrame.size)
        var adjustedFrame = proposedFrame
        adjustedFrame.origin.x += (proposedFrame.width - targetSize.width) / 2
        adjustedFrame.origin.y += (proposedFrame.height - targetSize.height) / 2
        adjustedFrame.size = targetSize
        return adjustedFrame
    }

    func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
    ) -> NSApplication.PresentationOptions {
        let forwardedOptions = forwardedDelegate?.window?(
            window,
            willUseFullScreenPresentationOptions: proposedOptions
        ) ?? proposedOptions
        return forwardedOptions.union(.autoHideToolbar)
    }
}

// MARK: - Scroll View Configuration

private struct TransparentScrollViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        Task { @MainActor in
            configure(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in
            configure(from: nsView)
        }
    }

    @MainActor
    private func configure(from view: NSView) {
        guard let scrollView = sequence(first: view.superview, next: { $0?.superview })
            .first(where: { $0 is NSScrollView }) as? NSScrollView
        else { return }

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentView.drawsBackground = false
    }
}

// MARK: - Zero-Copy Preview Renderer

/// Renders captured frames via `AVSampleBufferDisplayLayer` with zero
/// pixel-data copies.  The layer natively accepts `CMSampleBuffer`
/// backed by `IOSurface`, handling YUV→RGB conversion and colour
/// management entirely on the GPU.
@Observable
final class ZeroCopyPreviewRenderer: @unchecked Sendable, DisplayPreviewSink {
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
        Task { @MainActor [weak self] in
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

// MARK: - Window Accessor

/// Invisible helper that resolves the hosting `NSWindow` reference
/// and delivers it via a callback.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        Task { @MainActor in
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in
            if let window = nsView.window { onResolve(window) }
        }
    }
}
