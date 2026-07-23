import CoreGraphics
import CoreVideo
import Foundation
import Observation
import SwiftUI
import VoidDisplayCapture
import VoidDisplayFoundation

@MainActor
struct PreviewActiveUITestHost<HomeContent: View>: View {
    @State private var state: PreviewActiveUITestState
    private let homeContent: () -> HomeContent

    init(@ViewBuilder homeContent: @escaping () -> HomeContent) {
        _state = State(initialValue: .shared)
        self.homeContent = homeContent
    }

    @ViewBuilder
    var body: some View {
        if state.session == nil {
            homeContent()
        } else {
            CaptureDisplayWindowRoot(
                previewID: state.previewID,
                previewActions: previewActions,
                sharingStatusProvider: CaptureSharingStatusProvider { _ in false }
            )
        }
    }

    private var previewActions: CapturePreviewActions {
        CapturePreviewActions(
            sessions: { state.session.map { [$0] } ?? [] },
            previewSession: { id in id == state.previewID ? state.session : nil },
            previewState: { id in id == state.previewID && state.session != nil ? .active : .released },
            previewIDForDisplayID: { displayID in
                displayID == state.session?.displayID ? state.previewID : nil
            },
            startPreview: { _, _ in .invalidated },
            attachPreviewSink: { _, _ in },
            activatePreviewSession: { _ in },
            waitForPreviewResolution: { id in
                id == state.previewID && state.session != nil ? .active : .released
            },
            retryPreview: { id in
                id == state.previewID && state.session != nil ? .active : .released
            },
            closePreview: { id in
                guard id == state.previewID else { return }
                state.session = nil
            },
            setPreviewCapturesCursor: { id, capturesCursor in
                guard id == state.previewID, var currentSession = state.session else { return }
                currentSession.capturesCursor = capturesCursor
                state.session = currentSession
            }
        )
    }
}

@MainActor
@Observable
private final class PreviewActiveUITestState {
    static let shared = PreviewActiveUITestState()

    let previewID: CapturePreviewID
    var session: ScreenPreviewSession?

    private init() {
        let previewID = CapturePreviewID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
        )
        let subscription = DisplayPreviewSubscription(
            displayID: 901,
            resolutionText: "2560 × 1440",
            session: PreviewActiveCaptureSession(),
            cancelClosure: {},
            setShowsCursorClosure: { _ in }
        )
        self.previewID = previewID
        session = ScreenPreviewSession(
            id: previewID.rawValue,
            displayID: 901,
            displayName: "Studio Display",
            resolutionText: "2560 × 1440",
            isVirtualDisplay: false,
            previewSubscription: subscription,
            capturesCursor: false,
            state: .active
        )
    }
}

private final class PreviewActiveShareConsumer: DisplayShareFrameConsumer, @unchecked Sendable {
    nonisolated var hasDemand: Bool { false }
    nonisolated func updateSourceVideoSpec(_: SourceVideoSpec) {}
    nonisolated func updatePerformanceMode(_: CapturePerformanceMode) {}
    nonisolated func stopSharing() {}
    nonisolated func submitFrame(pixelBuffer _: CVPixelBuffer, ptsUs _: UInt64) {}
}

private final class PreviewActiveCaptureSession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer = PreviewActiveShareConsumer()
    nonisolated func attachPreviewSink(_: any DisplayPreviewSink) {}
    nonisolated func detachPreviewSink(_: any DisplayPreviewSink) {}
    nonisolated func stopSharing() {}
    nonisolated func stop() async {}
}
