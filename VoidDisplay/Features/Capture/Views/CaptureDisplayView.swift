import AppKit
import SwiftUI

// MARK: - Capture Display View

struct CaptureDisplayView: View {
    private enum PreviewScaleMode: Hashable, CaseIterable {
        case fit
        case native

        var title: LocalizedStringResource {
            switch self {
            case .fit:
                "Fit"
            case .native:
                "1:1"
            }
        }
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
    @State private var lastReportedRendererMetrics: ZeroCopyPreviewRenderer.MetricsSnapshot?

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
                    ForEach(PreviewScaleMode.allCases, id: \.self) { mode in
                        Text(mode.title)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 150)
                .accessibilityIdentifier("capture_preview_scale_mode_picker")
                .accessibilityValue(Text(scaleMode.title))
            }
            ToolbarItem(placement: .automatic) {
                HStack(spacing: AppUI.Spacing.small + 2) {
                    Text(String(localized: "Cursor"))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .fixedSize()
                    Toggle("", isOn: cursorCaptureBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel(String(localized: "Cursor"))
                }
                .padding(.horizontal, AppUI.Spacing.xSmall)
                .disabled(isUpdatingCursorCapture || isSharingDisplay)
                .accessibilityIdentifier("capture_preview_cursor_toggle")
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
                capture.attachPreviewSink(renderer, to: sessionId)
                if let destinationDirectory = CapturePreviewDiagnosticsRuntime.configuration()?.recordDirectoryURL {
                    let sink = CapturePreviewRecordingSink(
                        destinationDirectory: destinationDirectory,
                        session: session
                    )
                    recordingSink = sink
                    capture.attachPreviewSink(sink, to: sessionId)
                }
                capture.activateMonitoringSession(id: sessionId)
            } else {
                dismiss()
            }
        }
        .onDisappear {
            capture.closeMonitoringSession(id: sessionId)
            windowCoordinator.tearDown()
            renderer.flush()
            lastReportedRendererMetrics = nil
        }
        .task(id: sessionId) {
            await reportPreviewPerformanceLoop()
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
    @MainActor
    private func reportPreviewPerformanceLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }

            guard let session else { continue }
            let currentMetrics = renderer.metricsSnapshot()
            let previousMetrics = lastReportedRendererMetrics
            lastReportedRendererMetrics = currentMetrics

            let renderedDelta = currentMetrics.renderedFrameCount &- (previousMetrics?.renderedFrameCount ?? 0)
            let droppedDelta = currentMetrics.droppedFrameCount &- (previousMetrics?.droppedFrameCount ?? 0)
            let sample = DisplayPreviewPerformanceSample(
                renderedFrameCount: renderedDelta,
                droppedFrameCount: droppedDelta,
                latestRenderLatencyMilliseconds: currentMetrics.latestRenderLatencyMilliseconds ?? 0,
                pendingSlotOccupied: currentMetrics.pendingSlotOccupied,
                capturedAt: DispatchTime.now().uptimeNanoseconds
            )
            session.previewSubscription.reportPerformanceSample(sample)
        }
    }

    private var cursorCaptureBinding: Binding<Bool> {
        Binding(
            get: { effectiveCapturesCursor },
            set: { newValue in
                guard !isSharingDisplay else { return }
                let previousValue = capturesCursor
                capturesCursor = newValue

                guard session != nil else { return }
                isUpdatingCursorCapture = true
                Task {
                    do {
                        try await capture.setMonitoringSessionCapturesCursor(
                            id: sessionId,
                            capturesCursor: newValue
                        )
                        await MainActor.run {
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
