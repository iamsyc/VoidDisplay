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
    var startingDisplayIDs: Set<CGDirectDisplayID> = []
    var sharingClientCount = 0
    var sharingClientCounts: [CGDirectDisplayID: Int] = [:]
    var isSharing = false
    var isWebServiceRunning = false
    var webServiceLifecycleState: WebServiceLifecycleState = .stopped
    @ObservationIgnored let catalogService: ScreenCaptureCatalogService

    @ObservationIgnored private(set) var webServer: WebServer? = nil
    @ObservationIgnored private let sharingService: any SharingServiceProtocol
    @ObservationIgnored private let portPreferences: any SharingPortPreferencesProtocol
    @ObservationIgnored private var observedStartTokensByDisplayID: [CGDirectDisplayID: Set<UUID>] = [:]
    @ObservationIgnored private var sharingStateSubscription: SharingStateSubscription?

    init(
        sharingService: any SharingServiceProtocol,
        portPreferences: any SharingPortPreferencesProtocol,
        catalogService: ScreenCaptureCatalogService? = nil
    ) {
        self.sharingService = sharingService
        self.portPreferences = portPreferences
        self.catalogService = catalogService ?? ScreenCaptureCatalogService()
        self.sharingService.onWebServiceLifecycleStateChanged = { [weak self] _ in
            self?.syncSharingState()
        }
        self.sharingStateSubscription = self.sharingService.subscribeSharingState { [weak self] _ in
            self?.refreshSharingCountsFromSnapshot()
        }
        syncSharingState()
    }

    var displayCatalogState: ScreenCaptureDisplayCatalogState {
        catalogService.store
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
        clearAllObservedStarts()
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

    func beginSharing(display: SCDisplay) async throws -> DisplayStartOutcome<Void> {
        let displayID = display.displayID
        let startToken = beginObservedStart(displayID: displayID)
        defer {
            endObservedStart(displayID: displayID, token: startToken)
            syncSharingState()
        }

        return try await sharingService.startSharing(display: display)
    }

    func stopSharing(displayID: CGDirectDisplayID) {
        clearObservedStarts(displayID: displayID)
        mutateAndSync {
            sharingService.stopSharing(displayID: displayID)
        }
    }

    func stopAllSharing() {
        clearAllObservedStarts()
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

    func isDisplaySharing(displayID: CGDirectDisplayID) -> Bool {
        activeSharingDisplayIDs.contains(displayID)
    }

    func isSharing(displayID: CGDirectDisplayID) -> Bool {
        sharingService.isSharing(displayID: displayID)
    }

    func isStarting(displayID: CGDirectDisplayID) -> Bool {
        startingDisplayIDs.contains(displayID)
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
        activeSharingDisplayIDs = sharingService.activeSharingDisplayIDs
        isSharing = sharingService.hasAnyActiveSharing
        isWebServiceRunning = sharingService.isWebServiceRunning
        webServiceLifecycleState = sharingService.webServiceLifecycleState
        refreshSharingCountsFromSnapshot()
    }

    private func beginObservedStart(displayID: CGDirectDisplayID) -> UUID {
        let token = UUID()
        var tokens = observedStartTokensByDisplayID[displayID] ?? []
        tokens.insert(token)
        observedStartTokensByDisplayID[displayID] = tokens
        startingDisplayIDs.insert(displayID)
        return token
    }

    private func endObservedStart(displayID: CGDirectDisplayID, token: UUID) {
        guard var tokens = observedStartTokensByDisplayID[displayID] else { return }
        tokens.remove(token)
        if tokens.isEmpty {
            observedStartTokensByDisplayID.removeValue(forKey: displayID)
            startingDisplayIDs.remove(displayID)
        } else {
            observedStartTokensByDisplayID[displayID] = tokens
        }
    }

    private func clearObservedStarts(displayID: CGDirectDisplayID) {
        observedStartTokensByDisplayID.removeValue(forKey: displayID)
        startingDisplayIDs.remove(displayID)
    }

    private func clearAllObservedStarts() {
        observedStartTokensByDisplayID.removeAll()
        startingDisplayIDs.removeAll()
    }

    private func refreshSharingCountsFromSnapshot() {
        let snapshot = sharingService.sharingStateSnapshot
        sharingClientCount = snapshot.streamingPeers
        guard isWebServiceRunning else {
            sharingClientCounts = [:]
            return
        }
        var counts: [CGDirectDisplayID: Int] = [:]
        for displayID in sharingService.activeSharingDisplayIDs {
            if let target = sharingService.shareTarget(for: displayID) {
                counts[displayID] = snapshot.streamingPeersByTarget[target] ?? 0
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
