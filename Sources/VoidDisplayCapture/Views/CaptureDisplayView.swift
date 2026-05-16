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
    @State private var window: NSWindow?
    @State private var windowCoordinator = CapturePreviewWindowCoordinator()
    @State private var hasAppliedInitialSize = false
    @State private var scaleMode: CapturePreviewScaleMode = .fit
    @State private var capturesCursor = false
    @State private var isUpdatingCursorCapture = false

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
            if session != nil {
                previewActions.attachPreviewSink(renderer, sessionId)
                previewActions.activatePreviewSession(sessionId)
            } else {
                dismiss()
            }
        }
        .onDisappear {
            Task { await previewActions.closePreviewSession(sessionId) }
            windowCoordinator.tearDown()
            renderer.flush()
        }
        .overlay {
            CapturePreviewWindowSizingHost(
                window: $window,
                hasAppliedInitialSize: $hasAppliedInitialSize,
                coordinator: windowCoordinator,
                scaleMode: scaleMode,
                framePixelSize: renderer.framePixelSize,
                aspect: preferredAspect(),
                targetContentWidth: nil
            )
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Window Sizing

package extension CaptureDisplayView {
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
}
