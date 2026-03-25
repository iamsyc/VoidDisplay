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
    var activeStreamClientCount: Int { get }
    var currentWebServer: WebServer? { get }
    var hasAnyActiveSharing: Bool { get }
    var activeSharingDisplayIDs: Set<CGDirectDisplayID> { get }
    func isStarting(displayID: CGDirectDisplayID) -> Bool

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

    init(
        webServiceController: (any WebServiceControllerProtocol)? = nil,
        sharingCoordinator: DisplaySharingCoordinator
    ) {
        self.webServiceController = webServiceController ?? WebServiceController()
        self.sharingCoordinator = sharingCoordinator
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

    var activeStreamClientCount: Int {
        webServiceController.activeStreamClientCount
    }

    func streamClientCount(for target: ShareTarget) -> Int {
        webServiceController.streamClientCount(for: target)
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

    @discardableResult
    func startWebService(requestedPort: UInt16) async -> WebServiceStartResult {
        let result = await webServiceController.start(
            requestedPort: requestedPort,
            targetStateProvider: { [weak self] target in
                self?.sharingCoordinator.state(for: target) ?? .unknown
            },
            sessionHubProvider: { [weak self] target in
                self?.sharingCoordinator.sessionHub(for: target)
            }
        )
        if case .failed(let failure) = result {
            AppLog.sharing.error(
                "Failed to start web sharing service (requestedPort: \(requestedPort, privacy: .public), reason: \(String(describing: failure), privacy: .public))."
            )
        }
        return result
    }

    func stopWebService() {
        stopAllSharing()
        webServiceController.stop()
    }

    func registerShareableDisplays(
        _ displays: [SCDisplay],
        virtualSerialResolver: (CGDirectDisplayID) -> UInt32?
    ) {
        sharingCoordinator.registerShareableDisplays(
            displays,
            virtualSerialResolver: virtualSerialResolver
        )
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
}
