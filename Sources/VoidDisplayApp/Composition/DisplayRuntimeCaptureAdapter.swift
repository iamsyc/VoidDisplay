import Foundation
import VoidDisplayCapture
import VoidDisplayRuntime

@MainActor
package final class DisplayRuntimeCaptureAdapter: DisplayRuntimeCaptureProviding, DisplayRuntimeCaptureCommanding {
    private weak var controller: CaptureController?

    package init(controller: CaptureController) {
        self.controller = controller
    }

    package func makeCaptureSnapshot() -> DisplayRuntimeCaptureSnapshot {
        guard let controller else { return .empty }
        return DisplayRuntimeCaptureSnapshot(
            startingDisplayIDs: controller.startingDisplayIDs.sorted(),
            sessions: controller.screenCaptureSessions.map { session in
                let metrics = session.previewSubscription.captureMetricsSnapshot()
                return DisplayRuntimeCaptureSession(
                    id: session.id,
                    displayID: session.displayID,
                    isVirtualDisplay: session.isVirtualDisplay,
                    capturesCursor: session.capturesCursor,
                    state: session.state == .starting ? .starting : .active,
                    metrics: .init(
                        currentProfile: metrics.currentProfile?.rawValue,
                        currentFrameRateTier: metrics.currentFrameRateTier.map { "\($0.framesPerSecond)fps" },
                        receivedFrameCount: metrics.receivedFrameCount,
                        profileReconfigurationCount: metrics.profileReconfigurationCount,
                        cursorOverrideReconfigurationCount: metrics.cursorOverrideReconfigurationCount
                    )
                )
            }
        )
    }

    package func removeMonitoringSessions(displayID: DisplayRuntimeDisplayID) {
        controller?.removeMonitoringSessions(displayID: displayID)
    }
}
