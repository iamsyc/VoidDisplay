import Foundation
import CoreGraphics
import ScreenCaptureKit
import VoidDisplayFoundation
import VoidDisplayRuntime
import VoidDisplaySharing

@MainActor
package final class DisplayRuntimeSharingAdapter: DisplayRuntimeSharingProviding, DisplayRuntimeSharingCommanding {
    private weak var controller: SharingController?

    package init(controller: SharingController) {
        self.controller = controller
    }

    package func configureLANWebViewDemandSync(runtime: DisplayRuntime) {
        guard let controller else { return }
        controller.configureRuntimeStateDidChange { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            self.refreshLANWebViewConsumerDemands(runtime: runtime)
        }
    }

    package func makeSharingSnapshot() -> DisplayRuntimeSharingSnapshot {
        guard let controller else { return .empty }
        let displayIDsWithRouteProbe = Set((controller.displayCatalogState.displays ?? []).map(\.displayID))
            .union(controller.activeSharingDisplayIDs)
            .union(controller.startingDisplayIDs)
            .union(controller.sharingClientCounts.keys)
        return DisplayRuntimeSharingSnapshot(
            activeSharingDisplayIDs: controller.activeSharingDisplayIDs.sorted(),
            startingDisplayIDs: controller.startingDisplayIDs.sorted(),
            isSharing: controller.isSharing,
            isWebServiceRunning: controller.isWebServiceRunning,
            preferredPort: controller.preferredWebServicePort,
            sharingClientCount: controller.sharingClientCount,
            sharingClientCounts: controller.sharingClientCounts.map {
                DisplayRuntimeDisplayClientCount(displayID: $0.key, count: $0.value)
            },
            lifecycle: DisplayRuntimeSharingLifecycle(state: controller.webServiceLifecycleState),
            routes: displayIDsWithRouteProbe.map {
                DisplayRuntimeShareRoute(displayID: $0, hasConcreteRoute: controller.sharePagePath(for: $0) != nil)
            }
        )
    }

    package func registerShareableDisplays(_ displays: [DisplayRuntimeShareableDisplayRegistration]) {
        guard let controller else { return }
        let registrationsByDisplayID = firstRegistrationsByDisplayID(displays)
        let visibleDisplays = (controller.displayCatalogState.displays ?? []).filter {
            registrationsByDisplayID[$0.displayID] != nil
        }
        controller.registerShareableDisplays(visibleDisplays) { displayID in
            registrationsByDisplayID[displayID]?.virtualSerialNumber
        }
    }

    package func stopSharing(displayID: DisplayRuntimeDisplayID) {
        controller?.stopSharing(displayID: displayID)
    }

    package func restoreSharing(displayID: DisplayRuntimeDisplayID) async -> DisplayRuntimeSharingRestoreCommandResult {
        guard let controller else {
            return .failed("sharing_controller_unavailable")
        }
        guard controller.isWebServiceRunning else {
            return .init(status: .skipped, failureReason: "web_service_not_running")
        }
        guard let display = (controller.displayCatalogState.displays ?? []).first(where: { $0.displayID == displayID }) else {
            return .failed("display_not_found")
        }
        guard controller.sharePagePath(for: displayID) != nil else {
            return .failed("shareable_display_not_registered")
        }

        do {
            switch try await controller.beginSharing(display: display) {
            case .started:
                return .restored
            case .invalidated:
                return .invalidated("sharing_start_invalidated")
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    package func beginLANWebViewSharing(
        display: SCDisplay,
        runtime: DisplayRuntime
    ) async throws -> DisplayStartOutcome<Void> {
        guard let controller else {
            throw DisplayRuntimeLANWebViewCaptureError(
                failureCode: DisplayRuntimeCaptureIntentFailureCode.adapterUnavailable
            )
        }

        let result = await runtime.attachLANWebViewConsumer(
            surfaceIdentity: .physicalDisplay(displayID: display.displayID),
            owner: .init(source: .sharingService, redactedLabel: "lan"),
            demand: lanWebViewDemand(
                display: display,
                activeViewerCount: controller.sharingClientCounts[display.displayID] ?? 0
            )
        )

        guard let applyResult = result.applyResult else {
            guard controller.isSharing(displayID: display.displayID) else {
                throw DisplayRuntimeLANWebViewCaptureError(
                    failureCode: DisplayRuntimeCaptureIntentFailureCode.applyFailed
                )
            }
            return .started(())
        }

        guard applyResult.outcome == .applied else {
            _ = await runtime.detachLANWebViewConsumer(
                surfaceIdentity: .physicalDisplay(displayID: display.displayID)
            )
            throw DisplayRuntimeLANWebViewCaptureError(
                failureCode: applyResult.failureCode
                    ?? DisplayRuntimeCaptureIntentFailureCode.applyFailed
            )
        }
        return .started(())
    }

    package func stopLANWebViewSharing(
        displayID: CGDirectDisplayID,
        runtime: DisplayRuntime
    ) async {
        _ = await runtime.detachLANWebViewConsumer(
            surfaceIdentity: .physicalDisplay(displayID: displayID)
        )
    }

    package func stopAllLANWebViewSharing(runtime: DisplayRuntime) async {
        let activeSurfaceIdentities = runtime.currentConsumerLeaseSnapshot()
            .filter { $0.kind == .lanWebView && $0.state.contributesDemand }
            .map(\.surfaceIdentity)
        for surfaceIdentity in activeSurfaceIdentities {
            _ = await runtime.detachLANWebViewConsumer(surfaceIdentity: surfaceIdentity)
        }
    }

    private func firstRegistrationsByDisplayID(
        _ displays: [DisplayRuntimeShareableDisplayRegistration]
    ) -> [DisplayRuntimeDisplayID: DisplayRuntimeShareableDisplayRegistration] {
        var result: [DisplayRuntimeDisplayID: DisplayRuntimeShareableDisplayRegistration] = [:]
        for display in displays {
            result[display.displayID] = result[display.displayID] ?? display
        }
        return result
    }

    private func refreshLANWebViewConsumerDemands(runtime: DisplayRuntime) {
        guard let controller else { return }
        let displaysByID = Dictionary(
            uniqueKeysWithValues: (controller.displayCatalogState.displays ?? []).map { display in
                (display.displayID, display)
            }
        )
        for displayID in controller.activeSharingDisplayIDs {
            guard let display = displaysByID[displayID] else { continue }
            _ = runtime.updateLANWebViewConsumerDemand(
                surfaceIdentity: .physicalDisplay(displayID: displayID),
                demand: lanWebViewDemand(
                    display: display,
                    activeViewerCount: controller.sharingClientCounts[displayID] ?? 0
                )
            )
        }
    }

    private func lanWebViewDemand(
        display: SCDisplay,
        activeViewerCount: Int
    ) -> DisplayRuntimeConsumerDemand {
        DisplayRuntimeConsumerDemand(
            sourcePixelSize: .init(width: display.width, height: display.height),
            preferredPixelSize: nil,
            maximumPixelSize: nil,
            sourceFramesPerSecond: 60,
            preferredFramesPerSecond: nil,
            capturesCursor: false,
            powerProfile: .automatic,
            latencyPreference: .realtime,
            activeViewerCount: activeViewerCount
        )
    }
}

private struct DisplayRuntimeLANWebViewCaptureError: LocalizedError {
    let failureCode: String

    var errorDescription: String? {
        failureCode
    }
}

private extension DisplayRuntimeSharingLifecycle {
    init(state: WebServiceLifecycleState) {
        switch state {
        case .stopped:
            self.init(
                phase: .stopped,
                requestedPort: nil,
                boundPort: nil,
                failureReason: nil,
                hasFailureMessage: false
            )
        case .starting(let requestedPort):
            self.init(
                phase: .starting,
                requestedPort: requestedPort,
                boundPort: nil,
                failureReason: nil,
                hasFailureMessage: false
            )
        case .running(let binding):
            self.init(
                phase: .running,
                requestedPort: binding.requestedPort,
                boundPort: binding.boundPort,
                failureReason: nil,
                hasFailureMessage: false
            )
        case .stopping:
            self.init(
                phase: .stopping,
                requestedPort: nil,
                boundPort: nil,
                failureReason: nil,
                hasFailureMessage: false
            )
        case .failed(let failure):
            self.init(
                phase: .failed,
                requestedPort: failure.requestedPort,
                boundPort: nil,
                failureReason: failure.runtimeFailureReason,
                hasFailureMessage: true
            )
        }
    }
}

private extension WebServiceStartFailure {
    var requestedPort: UInt16? {
        switch self {
        case .invalidPort:
            nil
        case .portInUse(let port), .permissionDenied(let port), .timedOut(let port), .listenerFailed(let port, _):
            port
        }
    }

    var runtimeFailureReason: String {
        switch self {
        case .invalidPort:
            "invalid_port"
        case .portInUse:
            "port_in_use"
        case .permissionDenied:
            "permission_denied"
        case .timedOut:
            "timed_out"
        case .listenerFailed:
            "listener_failed"
        }
    }
}
