import Foundation
import ScreenCaptureKit
import VoidDisplayCapture
import VoidDisplayRuntime

@MainActor
package final class DisplayRuntimeCaptureAdapter: DisplayRuntimeCaptureProviding, DisplayRuntimeCaptureCommanding, DisplayRuntimeCaptureIntentCommanding {
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

    package func applyCaptureIntent(
        _ intent: DisplayRuntimeCaptureIntent
    ) -> DisplayRuntimeCaptureIntentApplyResult {
        guard let controller else {
            return .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.adapterUnavailable
            )
        }
        if controller.displayCatalogState.hasScreenCapturePermission == false
            || controller.displayCatalogState.lastPreflightPermission == false {
            return .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.permissionUnavailable
            )
        }
        guard let resolvedDisplayID = intent.resolvedDisplayID,
              resolveDisplay(displayID: resolvedDisplayID, in: controller) != nil
        else {
            return .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.displayUnavailable
            )
        }
        return .applied(revision: intent.revision)
    }

    private func resolveDisplay(
        displayID: DisplayRuntimeDisplayID,
        in controller: CaptureController
    ) -> SCDisplay? {
        (controller.displayCatalogState.displays ?? []).first {
            $0.displayID == displayID
        }
    }
}
