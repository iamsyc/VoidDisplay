import Foundation
import ScreenCaptureKit
import OSLog

@MainActor
final class SharingService {
    private var sharingScreenCaptureObject: SCStream? = nil
    private var sharingScreenCaptureStream: Capture? = nil
    private var sharingScreenCaptureDelegate: StreamDelegate? = nil
    private let webServiceController: any WebServiceControlling

    private(set) var isSharing = false

    init(webServiceController: (any WebServiceControlling)? = nil) {
        self.webServiceController = webServiceController ?? WebServiceController()
    }

    var webServicePortValue: UInt16 {
        webServiceController.portValue
    }

    var isWebServiceRunning: Bool {
        webServiceController.isRunning
    }

    var activeStreamClientCount: Int {
        webServiceController.activeStreamClientCount
    }

    var currentStream: SCStream? {
        sharingScreenCaptureObject
    }

    var currentCapture: Capture? {
        sharingScreenCaptureStream
    }

    var currentDelegate: StreamDelegate? {
        sharingScreenCaptureDelegate
    }

    var currentWebServer: WebServer? {
        webServiceController.currentServer
    }

    @discardableResult
    func startWebService() -> Bool {
        let started = webServiceController.start(
            isSharingProvider: { [weak self] in
                self?.isSharing ?? false
            },
            frameProvider: { [weak self] in
                guard let self, self.isSharing else { return nil }
                return self.sharingScreenCaptureStream?.jpgData
            }
        )
        if !started {
            AppLog.sharing.error("Failed to start web sharing service.")
        }
        return started
    }

    func stopWebService() {
        stopSharing()
        webServiceController.stop()
    }

    func beginSharing(stream: SCStream, output: Capture, delegate: StreamDelegate) {
        AppLog.sharing.info("Begin sharing stream.")
        sharingScreenCaptureStream = output
        sharingScreenCaptureObject = stream
        sharingScreenCaptureDelegate = delegate
        isSharing = true
    }

    func stopSharing() {
        if isSharing {
            AppLog.sharing.info("Stop sharing stream.")
        } else {
            AppLog.sharing.debug("Stop sharing requested with no active stream.")
        }
        sharingScreenCaptureObject?.stopCapture()
        sharingScreenCaptureObject = nil
        sharingScreenCaptureDelegate = nil
        sharingScreenCaptureStream?.resetFrameState()
        sharingScreenCaptureStream = nil
        isSharing = false
        webServiceController.disconnectAllStreamClients()
    }
}
