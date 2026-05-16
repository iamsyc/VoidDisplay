import Foundation
import VoidDisplayObservability
import AppKit
import SwiftUI

// MARK: - Capture Display View
package struct CaptureDisplayView: View {
    package let sessionId: UUID
    private let previewActions: CapturePreviewActions
    private let sharingStatusProvider: CaptureSharingStatusProvider

    @Environment(\.dismiss) private var dismiss

    @State private var renderer = ZeroCopyPreviewRenderer()
    @State private var recordingSink: CapturePreviewRecordingSink?
    @State private var diagnosticsRecorderLeaseToken: UUID?
    @State private var diagnosticsRecorderTask: Task<Void, Never>?
    @State private var window: NSWindow?
    @State private var windowCoordinator = CapturePreviewWindowCoordinator()
    @State private var hasAppliedInitialSize = false
    @State private var scaleMode: CapturePreviewScaleMode = .fit
    @State private var capturesCursor = false
    @State private var isUpdatingCursorCapture = false
    @State private var lastReportedRendererMetrics: ZeroCopyPreviewRenderer.MetricsSnapshot?

    package init(
        sessionId: UUID,
        previewActions: CapturePreviewActions,
        sharingStatusProvider: CaptureSharingStatusProvider
    ) {
        self.sessionId = sessionId
        self.previewActions = previewActions
        self.sharingStatusProvider = sharingStatusProvider
    }

    private var session: ScreenPreviewSession? {
        previewActions.previewSession(sessionId)
    }

    private var isSharingDisplay: Bool {
        guard let displayID = session?.displayID else { return false }
        return sharingStatusProvider.isDisplaySharing(displayID)
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
        CapturePreviewSurface(
            hasSession: session != nil,
            renderer: renderer,
            scaleMode: scaleMode,
            nativeFrameSizeInPoints: nativeFrameSizeInPoints
        )
    }

    package var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            previewContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture_preview_content")
        .toolbar {
            CapturePreviewToolbar(
                scaleMode: $scaleMode,
                cursorCapture: cursorCaptureBinding,
                isUpdatingCursorCapture: isUpdatingCursorCapture,
                isSharingDisplay: isSharingDisplay
            )
        }
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            if let diagnosticsScaleMode = initialPreviewScaleModeOverride {
                scaleMode = diagnosticsScaleMode
            }
            capturesCursor = session?.capturesCursor ?? false
        }
        .onChange(of: previewActions.sessions().map(\.id)) { _, ids in
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
                previewActions.attachPreviewSink(renderer, sessionId)
                if let destinationDirectory = CapturePreviewDiagnosticsRuntime.configuration()?.recordDirectoryURL {
                    let sink = CapturePreviewRecordingSink(
                        destinationDirectory: destinationDirectory,
                        session: session
                    )
                    diagnosticsRecorderTask = Task { @MainActor in
                        let leaseToken = await previewActions.attachDiagnosticsRecorder(sessionId)
                        guard !Task.isCancelled else {
                            if let leaseToken {
                                await previewActions.detachDiagnosticsRecorder(leaseToken)
                            }
                            return
                        }
                        guard let leaseToken else { return }
                        diagnosticsRecorderLeaseToken = leaseToken
                        recordingSink = sink
                        previewActions.attachPreviewSink(sink, sessionId)
                    }
                }
                previewActions.activatePreviewSession(sessionId)
            } else {
                dismiss()
            }
        }
        .onDisappear {
            diagnosticsRecorderTask?.cancel()
            diagnosticsRecorderTask = nil
            if let leaseToken = diagnosticsRecorderLeaseToken {
                diagnosticsRecorderLeaseToken = nil
                Task { @MainActor in
                    await previewActions.detachDiagnosticsRecorder(leaseToken)
                }
            }
            recordingSink = nil
            previewActions.closePreviewSession(sessionId)
            windowCoordinator.tearDown()
            renderer.flush()
            lastReportedRendererMetrics = nil
        }
        .task(id: sessionId) {
            await reportPreviewPerformanceLoop()
        }
        .overlay {
            CapturePreviewWindowSizingHost(
                window: $window,
                hasAppliedInitialSize: $hasAppliedInitialSize,
                coordinator: windowCoordinator,
                scaleMode: scaleMode,
                framePixelSize: renderer.framePixelSize,
                aspect: preferredAspect(),
                targetContentWidth: CapturePreviewDiagnosticsRuntime.configuration()?.targetContentWidth
            )
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Window Sizing

package extension CaptureDisplayView {
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
                        try await previewActions.setPreviewSessionCapturesCursor(sessionId, newValue)
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

    /// Determines the preferred aspect ratio from the session's
    /// resolution text (e.g. "2560 × 1440"), falling back to the
    /// pixel size reported by the renderer's first frame.
    private func preferredAspect() -> CGSize {
        CapturePreviewGeometry.preferredAspect(
            resolutionText: session?.resolutionText,
            framePixelSize: renderer.framePixelSize
        )
    }

    private var initialPreviewScaleModeOverride: CapturePreviewScaleMode? {
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
