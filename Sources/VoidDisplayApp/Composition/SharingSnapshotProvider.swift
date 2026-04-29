import VoidDisplaySharing
import VoidDisplayObservability
import Foundation
package struct SharingSnapshotProvider: ObservabilitySnapshotProvider, @unchecked Sendable {
    package nonisolated struct Snapshot: Codable, Equatable, Sendable {
         package nonisolated struct Lifecycle: Codable, Equatable, Sendable {
            let phase: String
            let requestedPort: UInt16?
            let boundPort: UInt16?
            let failureReason: String?
            let failureMessage: String?
        }

        let activeSharingDisplayIDs: [UInt32]
        let startingDisplayIDs: [UInt32]
        let isSharing: Bool
        let isWebServiceRunning: Bool
        let preferredPort: UInt16
        let sharingClientCount: Int
        let sharingClientCounts: [UInt32: Int]
        let lifecycle: Lifecycle
    }

    package let key = "sharing"
    private weak var controller: SharingController?

    package init(controller: SharingController) {
        self.controller = controller
    }

    @MainActor
    package func makeSnapshot() -> Snapshot {
        guard let controller else {
            return Snapshot(
                activeSharingDisplayIDs: [],
                startingDisplayIDs: [],
                isSharing: false,
                isWebServiceRunning: false,
                preferredPort: 0,
                sharingClientCount: 0,
                sharingClientCounts: [:],
                lifecycle: .init(
                    phase: "unavailable",
                    requestedPort: nil,
                    boundPort: nil,
                    failureReason: nil,
                    failureMessage: nil
                )
            )
        }
        return Snapshot(
            activeSharingDisplayIDs: controller.activeSharingDisplayIDs.sorted(),
            startingDisplayIDs: controller.startingDisplayIDs.sorted(),
            isSharing: controller.isSharing,
            isWebServiceRunning: controller.isWebServiceRunning,
            preferredPort: controller.preferredWebServicePort,
            sharingClientCount: controller.sharingClientCount,
            sharingClientCounts: controller.sharingClientCounts,
            lifecycle: Snapshot.Lifecycle(state: controller.webServiceLifecycleState)
        )
    }
}

private extension SharingSnapshotProvider.Snapshot.Lifecycle {
    init(state: WebServiceLifecycleState) {
        switch state {
        case .stopped:
            self.init(
                phase: "stopped",
                requestedPort: nil,
                boundPort: nil,
                failureReason: nil,
                failureMessage: nil
            )
        case .starting(let requestedPort):
            self.init(
                phase: "starting",
                requestedPort: requestedPort,
                boundPort: nil,
                failureReason: nil,
                failureMessage: nil
            )
        case .running(let binding):
            self.init(
                phase: "running",
                requestedPort: binding.requestedPort,
                boundPort: binding.boundPort,
                failureReason: nil,
                failureMessage: nil
            )
        case .stopping:
            self.init(
                phase: "stopping",
                requestedPort: nil,
                boundPort: nil,
                failureReason: nil,
                failureMessage: nil
            )
        case .failed(let failure):
            let requestedPort: UInt16?
            let reason: String
            switch failure {
            case .invalidPort:
                requestedPort = nil
                reason = "invalid_port"
            case .portInUse(let port):
                requestedPort = port
                reason = "port_in_use"
            case .permissionDenied(let port):
                requestedPort = port
                reason = "permission_denied"
            case .timedOut(let port):
                requestedPort = port
                reason = "timed_out"
            case .listenerFailed(let port, _):
                requestedPort = port
                reason = "listener_failed"
            }
            self.init(
                phase: "failed",
                requestedPort: requestedPort,
                boundPort: nil,
                failureReason: reason,
                failureMessage: failure.userMessage
            )
        }
    }
}
