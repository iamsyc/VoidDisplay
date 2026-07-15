import Foundation
import CoreGraphics
import ScreenCaptureKit
import VoidDisplayCapture
import VoidDisplayFoundation
import VoidDisplayRuntime
import VoidDisplaySharing

@MainActor
package final class DisplayRuntimeSharingAdapter: DisplayRuntimeSharingProviding, DisplayRuntimeSharingCommanding {
    private weak var controller: SharingController?
    private weak var capturePerformancePreferences: CapturePerformancePreferences?

    package init(
        controller: SharingController,
        capturePerformancePreferences: CapturePerformancePreferences
    ) {
        self.controller = controller
        self.capturePerformancePreferences = capturePerformancePreferences
    }

    package func configureLANWebViewDemandSync(runtime: DisplayRuntime) {
        guard let controller else { return }
        controller.configureRuntimeStateDidChange { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            Task { @MainActor in
                await self.refreshLANWebViewConsumerDemands(runtime: runtime)
            }
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

    package func beginLANWebViewSharing(
        display: SCDisplay,
        runtime: DisplayRuntime
    ) async throws -> DisplayStartOutcome<Void> {
        guard let controller else {
            throw DisplayRuntimeLANWebViewCaptureError(
                failureCode: DisplayRuntimeCaptureIntentFailureCode.adapterUnavailable
            )
        }
        guard let surfaceIdentity = runtime.surfaceIdentityForDisplayID(display.displayID) else {
            throw DisplayRuntimeLANWebViewCaptureError(
                failureCode: DisplayRuntimeCaptureIntentFailureCode.displayUnavailable
            )
        }

        let outcome = await runtime.attachLANWebViewConsumer(
            surfaceIdentity: surfaceIdentity,
            owner: .init(source: .sharingService, redactedLabel: "lan"),
            demand: lanWebViewDemand(
                display: display,
                activeViewerCount: controller.sharingClientCounts[display.displayID] ?? 0
            )
        )

        guard case let .attached(_, applyResult) = outcome else {
            guard case let .rejected(failureCode) = outcome else {
                throw DisplayRuntimeLANWebViewCaptureError(
                    failureCode: DisplayRuntimeCaptureIntentFailureCode.applyFailed
                )
            }
            throw DisplayRuntimeLANWebViewCaptureError(failureCode: failureCode)
        }

        guard applyResult.outcome == .applied else {
            _ = await runtime.detachLANWebViewConsumer(
                surfaceIdentity: surfaceIdentity
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
        guard let surfaceIdentity = runtime.surfaceIdentityForDisplayID(displayID) else {
            return
        }
        _ = await runtime.detachLANWebViewConsumer(
            surfaceIdentity: surfaceIdentity
        )
    }

    package func stopAllLANWebViewSharing(runtime: DisplayRuntime) async {
        let activeSurfaceIdentities = runtime.currentConsumerLeaseSnapshot()
            .filter { $0.kind == .lanWebView && $0.state != .released }
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

    private func refreshLANWebViewConsumerDemands(runtime: DisplayRuntime) async {
        guard let controller else { return }
        let displaysByID = Dictionary(
            uniqueKeysWithValues: (controller.displayCatalogState.displays ?? []).map { display in
                (display.displayID, display)
            }
        )
        for displayID in controller.activeSharingDisplayIDs {
            guard let display = displaysByID[displayID] else { continue }
            guard let surfaceIdentity = runtime.surfaceIdentityForDisplayID(displayID) else { continue }
            _ = await runtime.updateLANWebViewConsumerDemand(
                surfaceIdentity: surfaceIdentity,
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
            powerProfile: capturePerformancePreferences?.mode.runtimeCapturePowerProfile ?? .automatic,
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
