//
//  SharingController.swift
//  VoidDisplay
//

import Foundation
import ScreenCaptureKit
import CoreGraphics
import Observation

@MainActor
@Observable
final class SharingController {
    enum SharePageURLFailure: Error, Equatable {
        case serviceNotRunning
        case lanUnavailable
        case displayUnavailable
    }

    var activeSharingDisplayIDs: Set<CGDirectDisplayID> = []
    var sharingClientCount = 0
    var sharingClientCounts: [CGDirectDisplayID: Int] = [:]
    var isSharing = false
    var isWebServiceRunning = false

    @ObservationIgnored private(set) var webServer: WebServer? = nil
    @ObservationIgnored private let sharingService: any SharingServiceProtocol

    init(sharingService: any SharingServiceProtocol) {
        self.sharingService = sharingService
        self.sharingService.onWebServiceRunningStateChanged = { [weak self] _ in
            self?.syncSharingState()
        }
    }

    @discardableResult
    func startWebService() async -> Bool {
        defer { syncSharingState() }
        return await sharingService.startWebService()
    }

    func stopWebService() {
        defer { syncSharingState() }
        sharingService.stopWebService()
    }

    func registerShareableDisplays(
        _ displays: [SCDisplay],
        virtualSerialResolver: @escaping (CGDirectDisplayID) -> UInt32?
    ) {
        defer { syncSharingState() }
        sharingService.registerShareableDisplays(displays, virtualSerialResolver: virtualSerialResolver)
    }

    func beginSharing(
        displayID: CGDirectDisplayID,
        stream: SCStream,
        output: Capture,
        delegate: StreamDelegate
    ) {
        defer { syncSharingState() }
        sharingService.startSharing(
            displayID: displayID,
            stream: stream,
            output: output,
            delegate: delegate
        )
    }

    func stopSharing(displayID: CGDirectDisplayID) {
        defer { syncSharingState() }
        sharingService.stopSharing(displayID: displayID)
    }

    func stopAllSharing() {
        defer { syncSharingState() }
        sharingService.stopAllSharing()
    }

    var webServicePortValue: UInt16 {
        sharingService.webServicePortValue
    }

    func refreshSharingClientCount() {
        sharingClientCount = sharingService.activeStreamClientCount
        refreshSharingClientCounts()
    }

    func isDisplaySharing(displayID: CGDirectDisplayID) -> Bool {
        activeSharingDisplayIDs.contains(displayID)
    }

    func isSharing(displayID: CGDirectDisplayID) -> Bool {
        sharingService.isSharing(displayID: displayID)
    }

    func sharePagePath(for displayID: CGDirectDisplayID) -> String? {
        guard let shareID = sharingService.shareID(for: displayID) else { return nil }
        return ShareTarget.id(shareID).displayPath
    }

    func sharePageURLResolution(for displayID: CGDirectDisplayID?) -> Result<URL, SharePageURLFailure> {
        guard isWebServiceRunning else { return .failure(.serviceNotRunning) }
        guard let ip = getLANIPv4Address() else { return .failure(.lanUnavailable) }

        let resolvedDisplayID = displayID ?? CGMainDisplayID()
        guard let path = sharePagePath(for: resolvedDisplayID) else {
            return .failure(.displayUnavailable)
        }

        guard let url = URL(string: "http://\(ip):\(webServicePortValue)\(path)") else {
            return .failure(.displayUnavailable)
        }
        return .success(url)
    }

    func sharePageURL(for displayID: CGDirectDisplayID?) -> URL? {
        guard case .success(let url) = sharePageURLResolution(for: displayID) else {
            return nil
        }
        return url
    }

    func sharePageAddress(for displayID: CGDirectDisplayID?) -> String? {
        sharePageURL(for: displayID)?.absoluteString
    }

    private func syncSharingState() {
        webServer = sharingService.currentWebServer
        sharingClientCount = sharingService.activeStreamClientCount
        activeSharingDisplayIDs = sharingService.activeSharingDisplayIDs
        isSharing = sharingService.hasAnyActiveSharing
        isWebServiceRunning = sharingService.isWebServiceRunning
        refreshSharingClientCounts()
    }

    private func refreshSharingClientCounts() {
        guard isWebServiceRunning else {
            sharingClientCounts = [:]
            return
        }
        var counts: [CGDirectDisplayID: Int] = [:]
        for displayID in sharingService.activeSharingDisplayIDs {
            if let target = sharingService.shareTarget(for: displayID) {
                counts[displayID] = sharingService.streamClientCount(for: target)
            }
        }
        sharingClientCounts = counts
    }
}
