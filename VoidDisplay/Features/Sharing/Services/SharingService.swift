import Foundation
import ScreenCaptureKit
import OSLog
import CoreGraphics

enum SharingStartError: LocalizedError, Equatable {
    case displayNotRegistered(CGDirectDisplayID)

    var errorDescription: String? {
        switch self {
        case .displayNotRegistered:
            String(localized: "Selected display is no longer available for sharing.")
        }
    }
}

@MainActor
protocol SharingServiceProtocol: AnyObject {
    var webServicePortValue: UInt16 { get }
    var onWebServiceRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)? { get set }
    var onWebServiceLifecycleStateChanged: (@MainActor @Sendable (WebServiceLifecycleState) -> Void)? { get set }
    var webServiceLifecycleState: WebServiceLifecycleState { get }
    var isWebServiceRunning: Bool { get }
    var sharingStateSnapshot: SharingStateSnapshot { get }
    var activeStreamClientCount: Int { get }
    var currentWebServer: WebServer? { get }
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
final class SharingService: SharingServiceProtocol {
    private let sharingCoordinator: DisplaySharingCoordinator
    private let webServiceController: any WebServiceControllerProtocol
    private let sharingStateAggregator: SharingStateAggregator

    init(
        webServiceController: (any WebServiceControllerProtocol)? = nil,
        sharingCoordinator: DisplaySharingCoordinator,
        sharingStateAggregator: SharingStateAggregator = SharingStateAggregator()
    ) {
        self.webServiceController = webServiceController ?? WebServiceController()
        self.sharingCoordinator = sharingCoordinator
        self.sharingStateAggregator = sharingStateAggregator
    }

    var webServicePortValue: UInt16 {
        webServiceController.portValue
    }

    var onWebServiceRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)? {
        get { webServiceController.onRunningStateChanged }
        set { webServiceController.onRunningStateChanged = newValue }
    }

    var onWebServiceLifecycleStateChanged: (@MainActor @Sendable (WebServiceLifecycleState) -> Void)? {
        get { webServiceController.onLifecycleStateChanged }
        set { webServiceController.onLifecycleStateChanged = newValue }
    }

    var webServiceLifecycleState: WebServiceLifecycleState {
        webServiceController.lifecycleState
    }

    var isWebServiceRunning: Bool {
        webServiceController.isRunning
    }

    var sharingStateSnapshot: SharingStateSnapshot {
        sharingStateAggregator.currentSnapshot
    }

    var activeStreamClientCount: Int {
        sharingStateAggregator.currentSnapshot.streamingPeers
    }

    func streamClientCount(for target: ShareTarget) -> Int {
        sharingStateAggregator.currentSnapshot.streamingPeersByTarget[target] ?? 0
    }

    var currentWebServer: WebServer? {
        webServiceController.currentServer
    }

    var hasAnyActiveSharing: Bool {
        sharingCoordinator.hasAnyActiveSharing
    }

    var activeSharingDisplayIDs: Set<CGDirectDisplayID> {
        sharingCoordinator.activeSharingDisplayIDs
    }

    func isStarting(displayID: CGDirectDisplayID) -> Bool {
        sharingCoordinator.isStarting(displayID: displayID)
    }

    func subscribeSharingState(
        _ observer: @escaping @MainActor @Sendable (SharingStateSnapshot) -> Void
    ) -> SharingStateSubscription {
        sharingStateAggregator.subscribe(observer)
    }

    @discardableResult
    func startWebService(requestedPort: UInt16) async -> WebServiceStartResult {
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

    func stopWebService() {
        stopAllSharing()
        webServiceController.stop()
        sharingStateAggregator.reset()
    }

    func registerShareableDisplays(
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

    func startSharing(display: SCDisplay) async throws -> DisplayStartOutcome<Void> {
        AppLog.sharing.info("Begin sharing stream for display \(display.displayID, privacy: .public).")
        return try await sharingCoordinator.startSharing(display: display)
    }

    func stopSharing(displayID: CGDirectDisplayID) {
        sharingCoordinator.stopSharing(displayID: displayID)
    }

    func stopAllSharing() {
        sharingCoordinator.stopAllSharing()
        webServiceController.disconnectAllStreamClients()
    }

    func isSharing(displayID: CGDirectDisplayID) -> Bool {
        sharingCoordinator.isSharing(displayID: displayID)
    }

    func shareID(for displayID: CGDirectDisplayID) -> UInt32? {
        sharingCoordinator.shareID(for: displayID)
    }

    func shareTarget(for displayID: CGDirectDisplayID) -> ShareTarget? {
        sharingCoordinator.target(for: displayID)
    }

    private func recordSharingEvent(_ event: SharingSessionEvent) {
        sharingStateAggregator.record(event)
    }
}
