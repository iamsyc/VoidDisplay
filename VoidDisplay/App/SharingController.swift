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
    @ObservationIgnored private let portPreferences: any SharingPortPreferencesProtocol

    init(
        sharingService: any SharingServiceProtocol,
        portPreferences: (any SharingPortPreferencesProtocol)? = nil
    ) {
        self.sharingService = sharingService
        self.portPreferences = portPreferences ?? SharingPortPreferences()
        self.sharingService.onWebServiceRunningStateChanged = { [weak self] _ in
            self?.syncSharingState()
        }
    }

    @discardableResult
    func startWebService(requestedPort: UInt16) async -> WebServiceStartResult {
        await mutateAndSync {
            let result = await sharingService.startWebService(requestedPort: requestedPort)
            if let binding = result.binding {
                portPreferences.savePreferredPort(binding.requestedPort)
            }
            return result
        }
    }

    func stopWebService() {
        mutateAndSync {
            sharingService.stopWebService()
        }
    }

    func registerShareableDisplays(
        _ displays: [SCDisplay],
        virtualSerialResolver: @escaping (CGDirectDisplayID) -> UInt32?
    ) {
        mutateAndSync {
            sharingService.registerShareableDisplays(displays, virtualSerialResolver: virtualSerialResolver)
        }
    }

    func beginSharing(display: SCDisplay) async throws {
        try await mutateAndSync {
            try await sharingService.startSharing(display: display)
        }
    }

    func stopSharing(displayID: CGDirectDisplayID) {
        mutateAndSync {
            sharingService.stopSharing(displayID: displayID)
        }
    }

    func stopAllSharing() {
        mutateAndSync {
            sharingService.stopAllSharing()
        }
    }

    var webServicePortValue: UInt16 {
        sharingService.webServicePortValue
    }

    var preferredWebServicePort: UInt16 {
        portPreferences.preferredPort
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

    private func mutateAndSync(_ mutation: () -> Void) {
        mutation()
        syncSharingState()
    }

    private func mutateAndSync<T>(_ mutation: () async -> T) async -> T {
        defer { syncSharingState() }
        return await mutation()
    }

    private func mutateAndSync<T>(_ mutation: () async throws -> T) async rethrows -> T {
        defer { syncSharingState() }
        return try await mutation()
    }
}
