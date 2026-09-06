import CoreVideo
import Foundation
import VoidDisplayCapture
import VoidDisplayFoundation

@MainActor
enum MenuBarQuickActionsUITestFixture {
    static func capturePreviewService() -> CapturePreviewService {
        CapturePreviewService(initialSessions: [previewSession()])
    }

    private static func previewSession() -> ScreenPreviewSession {
        let displayID = UITestRuntime.managedVirtualDisplayIDs[0]
        let subscription = DisplayPreviewSubscription(
            displayID: displayID,
            resolutionText: "1920 × 1080",
            session: MenuBarQuickActionsCaptureSession(),
            cancelClosure: {},
            setShowsCursorClosure: { _ in }
        )
        return ScreenPreviewSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000911")!,
            displayID: displayID,
            displayName: "VoidDisplay 1",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: true,
            previewSubscription: subscription,
            capturesCursor: false,
            state: .active
        )
    }
}

private final class MenuBarQuickActionsShareConsumer: DisplayShareFrameConsumer, @unchecked Sendable {
    nonisolated var hasDemand: Bool { false }
    nonisolated func updateSourceVideoSpec(_: SourceVideoSpec) {}
    nonisolated func updatePerformanceMode(_: CapturePerformanceMode) {}
    nonisolated func stopSharing() {}
    nonisolated func submitFrame(pixelBuffer _: CVPixelBuffer, ptsUs _: UInt64) {}
}

private final class MenuBarQuickActionsCaptureSession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer =
        MenuBarQuickActionsShareConsumer()

    nonisolated func attachPreviewSink(_: any DisplayPreviewSink) {}
    nonisolated func detachPreviewSink(_: any DisplayPreviewSink) {}
    nonisolated func stopSharing() {}
    nonisolated func stop() async {}
}
