import Foundation
import VoidDisplayObservability
import AppKit
import SwiftUI

// MARK: - Capture Display View
package struct CaptureDisplayView: View {
    package let previewID: CapturePreviewID
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
    @State private var previewState: CapturePreviewState
    @State private var isRetrying = false

    package init(
        previewID: CapturePreviewID,
        previewActions: CapturePreviewActions,
        sharingStatusProvider: CaptureSharingStatusProvider
    ) {
        self.previewID = previewID
        self.previewActions = previewActions
        self.sharingStatusProvider = sharingStatusProvider
        _previewState = State(initialValue: previewActions.previewState(previewID))
    }

    private var session: ScreenPreviewSession? {
        previewActions.previewSession(previewID)
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

    package var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            switch previewState {
            case .active:
                CapturePreviewSurface(
                    hasSession: session != nil,
                    renderer: renderer,
                    scaleMode: scaleMode,
                    nativeFrameSizeInPoints: nativeFrameSizeInPoints
                )
            case .restarting, .failed:
                CapturePreviewRecoveryView(
                    state: previewState,
                    isRetrying: isRetrying,
                    retry: retryPreview,
                    close: closePreview
                )
            case .released:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(window?.title ?? String(localized: "Preview")))
        .accessibilityIdentifier("capture_preview_content")
        .navigationTitle(windowTitle)
        .toolbar {
            if previewState == .active {
                CapturePreviewToolbar(
                    scaleMode: $scaleMode,
                    cursorCapture: cursorCaptureBinding,
                    isUpdatingCursorCapture: isUpdatingCursorCapture,
                    isSharingDisplay: isSharingDisplay
                )
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            capturesCursor = session?.capturesCursor ?? false
        }
        .onChange(of: previewActions.sessions().map(\.id)) { _, _ in
            previewState = previewActions.previewState(previewID)
        }
        .onChange(of: previewActions.previewState(previewID)) { _, newState in
            previewState = newState
        }
        .onChange(of: session?.capturesCursor ?? false) { _, newValue in
            if !isUpdatingCursorCapture {
                capturesCursor = newValue
            }
        }
        .task(id: session?.id) {
            guard session != nil else { return }
            renderer.flush()
            previewActions.attachPreviewSink(renderer, previewID)
            previewActions.activatePreviewSession(previewID)
        }
        .task(id: previewState) {
            switch previewState {
            case .restarting:
                previewState = await previewActions.waitForPreviewResolution(previewID)
            case .released:
                dismiss()
            case .active, .failed:
                break
            }
        }
        .onDisappear {
            Task { await previewActions.closePreview(previewID) }
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
                        try await previewActions.setPreviewCapturesCursor(previewID, newValue)
                        isUpdatingCursorCapture = false
                    } catch {
                        AppErrorMapper.logFailure(
                            "Update cursor capture",
                            error: error,
                            logger: AppLog.capture
                        )
                        capturesCursor = previousValue
                        isUpdatingCursorCapture = false
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

    private func retryPreview() {
        guard !isRetrying else { return }
        isRetrying = true
        previewState = .restarting
        Task {
            let state = await previewActions.retryPreview(previewID)
            previewState = state
            isRetrying = false
        }
    }

    private func closePreview() {
        Task {
            await previewActions.closePreview(previewID)
            previewState = .released
        }
    }

    private var windowTitle: String {
        guard let session else {
            return String(localized: "Preview")
        }
        return String(
            format: String(localized: "Preview: %@ · %@"),
            locale: .current,
            session.displayName,
            session.resolutionText
        )
    }
}
