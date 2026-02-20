import Foundation
import ScreenCaptureKit
import OSLog
import CoreGraphics

@MainActor
protocol SharingServiceProtocol: AnyObject {
    var webServicePortValue: UInt16 { get }
    var onWebServiceRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)? { get set }
    var isWebServiceRunning: Bool { get }
    var activeStreamClientCount: Int { get }
    var currentWebServer: WebServer? { get }
    var hasAnyActiveSharing: Bool { get }
    var activeSharingDisplayIDs: Set<CGDirectDisplayID> { get }

    @discardableResult
    func startWebService() async -> Bool
    func stopWebService()
    func registerShareableDisplays(
        _ displays: [SCDisplay],
        virtualSerialResolver: (CGDirectDisplayID) -> UInt32?
    )
    func startSharing(
        displayID: CGDirectDisplayID,
        stream: SCStream,
        output: Capture,
        delegate: StreamDelegate
    )
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
        sharingCoordinator: DisplaySharingCoordinator? = nil
    ) {
        self.webServiceController = webServiceController ?? WebServiceController()
        self.sharingCoordinator = sharingCoordinator ?? DisplaySharingCoordinator()
    }

    var webServicePortValue: UInt16 {
        webServiceController.portValue
    }

    var onWebServiceRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)? {
        get { webServiceController.onRunningStateChanged }
        set { webServiceController.onRunningStateChanged = newValue }
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

    @discardableResult
    func startWebService() async -> Bool {
        let started = await webServiceController.start(
            targetStateProvider: { [weak self] target in
                self?.sharingCoordinator.state(for: target) ?? .unknown
            },
            frameProvider: { [weak self] target in
                self?.sharingCoordinator.frame(for: target)
            }
        )
        if !started {
            AppLog.sharing.error("Failed to start web sharing service.")
        }
        return started
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

    func startSharing(
        displayID: CGDirectDisplayID,
        stream: SCStream,
        output: Capture,
        delegate: StreamDelegate
    ) {
        AppLog.sharing.info("Begin sharing stream for display \(displayID, privacy: .public).")
        sharingCoordinator.startSharing(
            displayID: displayID,
            stream: stream,
            capture: output,
            delegate: delegate
        )
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
