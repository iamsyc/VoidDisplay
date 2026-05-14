import Foundation
import Cocoa
import ScreenCaptureKit
import VoidDisplayCapture
import VoidDisplayFoundation
import VoidDisplayRuntime

@MainActor
package final class DisplayRuntimeCaptureAdapter: DisplayRuntimeCaptureProviding, DisplayRuntimeCaptureCommanding, DisplayRuntimeCaptureIntentCommanding {
    private weak var controller: CaptureController?
    private weak var sharingController: SharingController?
    private let isManagedVirtualDisplay: @MainActor (DisplayRuntimeDisplayID) -> Bool

    package init(
        controller: CaptureController,
        sharingController: SharingController? = nil,
        isManagedVirtualDisplay: @escaping @MainActor (DisplayRuntimeDisplayID) -> Bool = { _ in false }
    ) {
        self.controller = controller
        self.sharingController = sharingController
        self.isManagedVirtualDisplay = isManagedVirtualDisplay
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
        guard intent.kind == .drain else {
            return .applied(revision: intent.revision)
        }
        if let resolvedDisplayID = intent.resolvedDisplayID {
            controller.removeMonitoringSessions(displayID: resolvedDisplayID)
        }
        return .applied(revision: intent.revision)
    }

    package func applyMonitorCaptureIntent(
        _ intent: DisplayRuntimeCaptureIntent
    ) async -> DisplayRuntimeCaptureIntentApplyResult {
        guard let controller else {
            return .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.adapterUnavailable
            )
        }
        guard let resolvedDisplayID = intent.resolvedDisplayID else {
            return .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.displayUnavailable
            )
        }

        switch intent.kind {
        case .capture:
            if controller.displayCatalogState.hasScreenCapturePermission == false
                || controller.displayCatalogState.lastPreflightPermission == false {
                return .failed(
                    revision: intent.revision,
                    failureCode: DisplayRuntimeCaptureIntentFailureCode.permissionUnavailable
                )
            }
            guard let display = resolveDisplay(displayID: resolvedDisplayID, in: controller) else {
                return .failed(
                    revision: intent.revision,
                    failureCode: DisplayRuntimeCaptureIntentFailureCode.displayUnavailable
                )
            }
            return await acquireMonitorPreview(
                display: display,
                intent: intent,
                controller: controller
            )
        case .drain:
            controller.removeMonitoringSessions(displayID: resolvedDisplayID)
            return .applied(revision: intent.revision)
        }
    }

    package func applyLANWebViewCaptureIntent(
        _ intent: DisplayRuntimeCaptureIntent
    ) async -> DisplayRuntimeCaptureIntentApplyResult {
        guard let controller,
              let sharingController
        else {
            return .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.adapterUnavailable
            )
        }
        guard let resolvedDisplayID = intent.resolvedDisplayID else {
            return .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.displayUnavailable
            )
        }
        guard intent.kind == .capture,
              intent.aggregateDemand?.consumerKinds.contains(.lanWebView) == true
        else {
            sharingController.stopSharing(displayID: resolvedDisplayID)
            return .applied(revision: intent.revision)
        }
        if controller.displayCatalogState.hasScreenCapturePermission == false
            || controller.displayCatalogState.lastPreflightPermission == false {
            return .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.permissionUnavailable
            )
        }
        guard let display = resolveDisplay(displayID: resolvedDisplayID, in: controller)
        else {
            return .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.displayUnavailable
            )
        }
        return await acquireLANWebViewShare(
            display: display,
            intent: intent,
            sharingController: sharingController
        )
    }

    package func applyDiagnosticsRecorderCaptureIntent(
        _ intent: DisplayRuntimeCaptureIntent
    ) async -> DisplayRuntimeCaptureIntentApplyResult {
        guard let controller else {
            return .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.adapterUnavailable
            )
        }
        guard let resolvedDisplayID = intent.resolvedDisplayID else {
            return .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.displayUnavailable
            )
        }

        guard intent.kind == .capture,
              intent.aggregateDemand?.consumerKinds.contains(.diagnosticsRecorder) == true
        else {
            if intent.kind == .drain {
                controller.removeMonitoringSessions(displayID: resolvedDisplayID)
            }
            return .applied(revision: intent.revision)
        }

        if controller.screenCaptureSessions.contains(where: { $0.displayID == resolvedDisplayID }) {
            return .applied(revision: intent.revision)
        }
        if intent.aggregateDemand?.consumerKinds.contains(.lanWebView) == true {
            return .applied(revision: intent.revision)
        }
        if controller.displayCatalogState.hasScreenCapturePermission == false
            || controller.displayCatalogState.lastPreflightPermission == false {
            return .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.permissionUnavailable
            )
        }
        guard let display = resolveDisplay(displayID: resolvedDisplayID, in: controller)
        else {
            return .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.displayUnavailable
            )
        }
        return await acquireDiagnosticsRecorderPreview(
            display: display,
            intent: intent,
            controller: controller
        )
    }

    private func resolveDisplay(
        displayID: DisplayRuntimeDisplayID,
        in controller: CaptureController
    ) -> SCDisplay? {
        (controller.displayCatalogState.displays ?? []).first {
            $0.displayID == displayID
        }
    }

    private func acquireMonitorPreview(
        display: SCDisplay,
        intent: DisplayRuntimeCaptureIntent,
        controller: CaptureController
    ) async -> DisplayRuntimeCaptureIntentApplyResult {
        do {
            switch try await controller.startMonitoring(
                display: display,
                metadata: monitorMetadata(for: display)
            ) {
            case .started:
                return .applied(revision: intent.revision)
            case .invalidated:
                return .failed(
                    revision: intent.revision,
                    failureCode: DisplayRuntimeCaptureIntentFailureCode.applyInvalidated
                )
            }
        } catch {
            return .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.applyFailed
            )
        }
    }

    private func acquireLANWebViewShare(
        display: SCDisplay,
        intent: DisplayRuntimeCaptureIntent,
        sharingController: SharingController
    ) async -> DisplayRuntimeCaptureIntentApplyResult {
        guard !sharingController.isSharing(displayID: display.displayID) else {
            return .applied(revision: intent.revision)
        }

        do {
            switch try await sharingController.beginSharing(display: display) {
            case .started:
                return .applied(revision: intent.revision)
            case .invalidated:
                return .failed(
                    revision: intent.revision,
                    failureCode: DisplayRuntimeCaptureIntentFailureCode.applyInvalidated
                )
            }
        } catch {
            return .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.applyFailed
            )
        }
    }

    private func acquireDiagnosticsRecorderPreview(
        display: SCDisplay,
        intent: DisplayRuntimeCaptureIntent,
        controller: CaptureController
    ) async -> DisplayRuntimeCaptureIntentApplyResult {
        do {
            switch try await controller.startMonitoring(
                display: display,
                metadata: diagnosticsRecorderMetadata(for: display)
            ) {
            case .started:
                return .applied(revision: intent.revision)
            case .invalidated:
                return .failed(
                    revision: intent.revision,
                    failureCode: DisplayRuntimeCaptureIntentFailureCode.applyInvalidated
                )
            }
        } catch {
            return .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.applyFailed
            )
        }
    }

    private func monitorMetadata(for display: SCDisplay) -> CaptureMonitoringDisplayMetadata {
        CaptureMonitoringDisplayMetadata(
            displayName: NSScreen.screens.first {
                $0.cgDirectDisplayID == display.displayID
            }?.localizedName ?? String(localized: "Monitor"),
            resolutionText: "\(display.width) × \(display.height)",
            isVirtualDisplay: isManagedVirtualDisplay(display.displayID)
        )
    }

    private func diagnosticsRecorderMetadata(for display: SCDisplay) -> CaptureMonitoringDisplayMetadata {
        CaptureMonitoringDisplayMetadata(
            displayName: "Preview Diagnostics",
            resolutionText: "\(display.width) × \(display.height)",
            isVirtualDisplay: isManagedVirtualDisplay(display.displayID)
        )
    }
}
