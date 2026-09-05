import CoreVideo
import Foundation
import SwiftUI
import VoidDisplayCapture
import VoidDisplayFoundation
import VoidDisplayRuntime

/// Seeds a failed or active lease, then opens the same preview scene used by Home.
/// The UI, controller, lifecycle service and runtime remain real; capture acquisition is isolated.
@MainActor
struct PreviewUITestHost<HomeContent: View>: View {
    let capture: CaptureController
    let displayRuntime: DisplayRuntime
    @ViewBuilder let homeContent: () -> HomeContent
    @Environment(\.openWindow) private var openWindow
    @State private var didOpenPreview = false

    var body: some View {
        homeContent()
            .task {
                guard !didOpenPreview else { return }
                didOpenPreview = true
                _ = await capture.catalogService.submitRefresh(intent: .userForcedRefresh)
                let displayID = UITestRuntime.managedVirtualDisplayIDs[0]
                guard let display = capture.displayCatalogState.activeShareableDisplays?.first(where: {
                    $0.displayID == displayID
                }) else { return }
                guard let identity = displayRuntime.surfaceIdentityForDisplayID(displayID) else { return }
                let outcome = await displayRuntime.attachPreviewConsumer(
                    surfaceIdentity: identity,
                    owner: .init(source: .localUI),
                    demand: .init(
                        sourcePixelSize: .init(width: display.width, height: display.height),
                        sourceFramesPerSecond: 60,
                        capturesCursor: false,
                        powerProfile: .automatic,
                        latencyPreference: .realtime
                    )
                )
                if case let .attached(lease, _) = outcome {
                    openWindow(value: CapturePreviewID(rawValue: lease.id.rawValue))
                }
            }
    }
}

private enum PreviewUITestFailure: Error { case unavailable }

@MainActor
enum PreviewUITestFixture {
    static func acquirePreview() -> CapturePreviewLifecycleService.AcquirePreview? {
        guard UITestRuntime.isEnabled else { return nil }
        var shouldFail = UITestRuntime.scenario == .previewRecovery
        return { display, _ in
            if shouldFail {
                shouldFail = false
                throw PreviewUITestFailure.unavailable
            }
            return .started(DisplayPreviewSubscription(
                displayID: display.displayID,
                resolutionText: "\(display.width) × \(display.height)",
                session: UITestPreviewCaptureSession(),
                cancelClosure: {},
                setShowsCursorClosure: { _ in }
            ))
        }
    }
}

private final class UITestPreviewShareConsumer: DisplayShareFrameConsumer, @unchecked Sendable {
    nonisolated var hasDemand: Bool { false }
    nonisolated func updateSourceVideoSpec(_: SourceVideoSpec) {}
    nonisolated func updatePerformanceMode(_: CapturePerformanceMode) {}
    nonisolated func stopSharing() {}
    nonisolated func submitFrame(pixelBuffer _: CVPixelBuffer, ptsUs _: UInt64) {}
}

private final class UITestPreviewCaptureSession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer = UITestPreviewShareConsumer()
    nonisolated func attachPreviewSink(_: any DisplayPreviewSink) {}
    nonisolated func detachPreviewSink(_: any DisplayPreviewSink) {}
    nonisolated func stopSharing() {}
    nonisolated func stop() async {}
}
