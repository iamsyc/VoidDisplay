import Foundation
import VoidDisplayRuntime
import VoidDisplaySharing

@MainActor
package final class DisplayRuntimeSharingAdapter: DisplayRuntimeSharingProviding, DisplayRuntimeSharingCommanding {
    private weak var controller: SharingController?

    package init(controller: SharingController) {
        self.controller = controller
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

    private func firstRegistrationsByDisplayID(
        _ displays: [DisplayRuntimeShareableDisplayRegistration]
    ) -> [DisplayRuntimeDisplayID: DisplayRuntimeShareableDisplayRegistration] {
        var result: [DisplayRuntimeDisplayID: DisplayRuntimeShareableDisplayRegistration] = [:]
        for display in displays {
            result[display.displayID] = result[display.displayID] ?? display
        }
        return result
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
