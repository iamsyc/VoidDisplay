import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import ScreenCaptureKit
import OSLog
import CoreGraphics
package enum SharingStartError: LocalizedError, Equatable {
    case displayNotRegistered(CGDirectDisplayID)

    package var errorDescription: String? {
        switch self {
        case .displayNotRegistered:
            String(localized: "Selected display is no longer available for sharing.")
        }
    }
}

@MainActor
package protocol SharingServiceProtocol: AnyObject {
    var webServicePortValue: UInt16 { get }
    var onWebServiceLifecycleStateChanged: (@MainActor @Sendable (WebServiceLifecycleState) -> Void)? { get set }
    var webServiceLifecycleState: WebServiceLifecycleState { get }
    var isWebServiceRunning: Bool { get }
    var sharingStateSnapshot: SharingStateSnapshot { get }
    var activeStreamClientCount: Int { get }
    var hasAnyActiveSharing: Bool { get }
    var activeSharingDisplayIDs: Set<CGDirectDisplayID> { get }
    func isStarting(displayID: CGDirectDisplayID) -> Bool
    func subscribeSharingState(
        _ observer: @escaping @MainActor @Sendable (SharingStateSnapshot) -> Void
    ) -> SharingStateSubscription

    @discardableResult
    func startWebService(requestedPort: UInt16) async -> WebServiceStartResult
    func stopWebService()
    func registerShareableDisplays(
        _ displays: [SCDisplay],
        virtualSerialResolver: (CGDirectDisplayID) -> UInt32?
    )
    func startSharing(display: SCDisplay) async throws -> DisplayStartOutcome<Void>
    func stopSharing(displayID: CGDirectDisplayID)
    func stopAllSharing()
    func isSharing(displayID: CGDirectDisplayID) -> Bool
    func shareID(for displayID: CGDirectDisplayID) -> UInt32?
    func shareTarget(for displayID: CGDirectDisplayID) -> ShareTarget?
    func streamClientCount(for target: ShareTarget) -> Int
}

@MainActor
package final class SharingService: SharingServiceProtocol {
    private let sharingCoordinator: DisplaySharingCoordinator
    private let webServiceController: any WebServiceControllerProtocol
    private let sharingStateAggregator: SharingStateAggregator

    package init(
        webServiceController: (any WebServiceControllerProtocol)? = nil,
        sharingCoordinator: DisplaySharingCoordinator,
        sharingStateAggregator: SharingStateAggregator = SharingStateAggregator()
    ) {
        self.webServiceController = webServiceController ?? WebServiceController()
        self.sharingCoordinator = sharingCoordinator
        self.sharingStateAggregator = sharingStateAggregator
    }

    package var webServicePortValue: UInt16 {
        webServiceController.portValue
    }

    package var onWebServiceLifecycleStateChanged: (@MainActor @Sendable (WebServiceLifecycleState) -> Void)? {
        get { webServiceController.onLifecycleStateChanged }
        set { webServiceController.onLifecycleStateChanged = newValue }
    }

    package var webServiceLifecycleState: WebServiceLifecycleState {
        webServiceController.lifecycleState
    }

    package var isWebServiceRunning: Bool {
        webServiceController.isRunning
    }

    package var sharingStateSnapshot: SharingStateSnapshot {
        sharingStateAggregator.currentSnapshot
    }

    package var activeStreamClientCount: Int {
        sharingStateAggregator.currentSnapshot.streamingPeers
    }

    package func streamClientCount(for target: ShareTarget) -> Int {
        sharingStateAggregator.currentSnapshot.streamingPeersByTarget[target] ?? 0
    }

    package var hasAnyActiveSharing: Bool {
        sharingCoordinator.hasAnyActiveSharing
    }

    package var activeSharingDisplayIDs: Set<CGDirectDisplayID> {
        sharingCoordinator.activeSharingDisplayIDs
    }

    package func isStarting(displayID: CGDirectDisplayID) -> Bool {
        sharingCoordinator.isStarting(displayID: displayID)
    }

    package func subscribeSharingState(
        _ observer: @escaping @MainActor @Sendable (SharingStateSnapshot) -> Void
    ) -> SharingStateSubscription {
        sharingStateAggregator.subscribe(observer)
    }

    @discardableResult
    package func startWebService(requestedPort: UInt16) async -> WebServiceStartResult {
        let shouldResetBeforeStart = !webServiceController.isRunning
        if shouldResetBeforeStart {
            sharingStateAggregator.reset()
        }
        let result = await webServiceController.start(
            requestedPort: requestedPort,
            targetStateProvider: { [weak self] target in
                self?.sharingCoordinator.state(for: target) ?? .unknown
            },
            concreteTargetResolver: { [weak self] target in
                self?.sharingCoordinator.resolveConcreteTarget(for: target)
            },
            sessionHubProvider: { [weak self] target in
                self?.sharingCoordinator.sessionHub(for: target)
            },
            sharingEventSink: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.recordSharingEvent(event)
                }
            }
        )
        if case .failed(let failure) = result {
            AppLog.sharing.error(
                "Failed to start web sharing service (requestedPort: \(requestedPort, privacy: .public), reason: \(String(describing: failure), privacy: .public))."
            )
            sharingStateAggregator.reset()
        }
        return result
    }

    package func stopWebService() {
        stopAllSharing()
        webServiceController.stop()
        sharingStateAggregator.reset()
    }

    package func registerShareableDisplays(
        _ displays: [SCDisplay],
        virtualSerialResolver: (CGDirectDisplayID) -> UInt32?
    ) {
        let invalidatedTargets = sharingCoordinator.registerShareableDisplays(
            displays,
            virtualSerialResolver: virtualSerialResolver
        )
        guard !invalidatedTargets.isEmpty else { return }
        webServiceController.disconnectStreamClients(for: invalidatedTargets)
    }

    package func startSharing(display: SCDisplay) async throws -> DisplayStartOutcome<Void> {
        AppLog.sharing.info("Begin sharing stream for display \(display.displayID, privacy: .public).")
        return try await sharingCoordinator.startSharing(display: display)
    }

    package func stopSharing(displayID: CGDirectDisplayID) {
        sharingCoordinator.stopSharing(displayID: displayID)
    }

    package func stopAllSharing() {
        sharingCoordinator.stopAllSharing()
        webServiceController.disconnectAllStreamClients()
    }

    package func isSharing(displayID: CGDirectDisplayID) -> Bool {
        sharingCoordinator.isSharing(displayID: displayID)
    }

    package func shareID(for displayID: CGDirectDisplayID) -> UInt32? {
        sharingCoordinator.shareID(for: displayID)
    }

    package func shareTarget(for displayID: CGDirectDisplayID) -> ShareTarget? {
        sharingCoordinator.target(for: displayID)
    }

    private func recordSharingEvent(_ event: SharingSessionEvent) {
        sharingStateAggregator.record(event)
    }
}
