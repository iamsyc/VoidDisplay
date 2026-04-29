import VoidDisplaySharing
import VoidDisplayObservability
import VoidDisplayFoundation
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
package final class SharingController {
    package enum SharePageURLFailure: Error, Equatable {
        case serviceNotRunning
        case lanUnavailable
        case displayUnavailable
    }

    package var activeSharingDisplayIDs: Set<CGDirectDisplayID> = []
    private(set) var startingDisplayIDs: Set<CGDirectDisplayID> = []
    package var sharingClientCount = 0
    package var sharingClientCounts: [CGDirectDisplayID: Int] = [:]
    package var isSharing = false
    package var isWebServiceRunning = false
    package var webServiceLifecycleState: WebServiceLifecycleState = .stopped
    @ObservationIgnored let catalogService: ScreenCaptureCatalogService

    @ObservationIgnored private(set) var webServer: WebServer? = nil
    @ObservationIgnored private let sharingService: any SharingServiceProtocol
    @ObservationIgnored private let portPreferences: any SharingPortPreferencesProtocol
    @ObservationIgnored private let startTracker = DisplayStartTracker()
    @ObservationIgnored private weak var observability: ObservabilityCenter?
    @ObservationIgnored private lazy var mutationRunner = SnapshotMutationRunner { [weak self] in
        self?.syncSharingState()
    }
    @ObservationIgnored private var sharingStateSubscription: SharingStateSubscription?

    package init(
        sharingService: any SharingServiceProtocol,
        portPreferences: any SharingPortPreferencesProtocol,
        catalogService: ScreenCaptureCatalogService? = nil,
        observability: ObservabilityCenter? = nil
    ) {
        self.sharingService = sharingService
        self.portPreferences = portPreferences
        self.catalogService = catalogService ?? ScreenCaptureCatalogService()
        self.observability = observability
        self.sharingService.onWebServiceLifecycleStateChanged = { [weak self] _ in
            self?.syncSharingState()
        }
        self.sharingStateSubscription = self.sharingService.subscribeSharingState { [weak self] _ in
            self?.refreshSharingCountsFromSnapshot()
        }
        syncSharingState()
    }

    package var displayCatalogState: ScreenCaptureDisplayCatalogState {
        catalogService.store
    }

    @discardableResult
    package func startWebService(requestedPort: UInt16) async -> WebServiceStartResult {
        await recordEvent(
            severity: .info,
            operation: "Start web service",
            message: "Started web service request.",
            metadata: ["requestedPort": "\(requestedPort)"],
            deduplicationKey: "sharing.web.start.\(requestedPort)"
        )
        let result = await mutationRunner.run {
            let result = await sharingService.startWebService(requestedPort: requestedPort)
            if let binding = result.binding {
                portPreferences.savePreferredPort(binding.requestedPort)
            }
            return result
        }
        switch result {
        case .started(let binding), .alreadyRunning(let binding):
            await recordEvent(
                severity: .notice,
                operation: "Start web service",
                message: "Web service is available.",
                metadata: [
                    "requestedPort": "\(binding.requestedPort)",
                    "boundPort": "\(binding.boundPort)"
                ],
                deduplicationKey: "sharing.web.start.\(binding.requestedPort)"
            )
        case .failed(let failure):
            await observability?.record(
                error: failure,
                subsystem: .sharing,
                operation: "Start web service",
                context: .init(
                    metadata: ["requestedPort": "\(requestedPort)"],
                    deduplicationKey: "sharing.web.start.\(requestedPort)"
                )
            )
        }
        return result
    }

    package func stopWebService() {
        startTracker.clearAll()
        Task {
            await recordEvent(
                severity: .notice,
                operation: "Stop web service",
                message: "Stopped web service.",
                metadata: [:]
            )
        }
        mutationRunner.run {
            sharingService.stopWebService()
        }
    }

    package func registerShareableDisplays(
        _ displays: [SCDisplay],
        virtualSerialResolver: @escaping (CGDirectDisplayID) -> UInt32?
    ) {
        mutationRunner.run {
            sharingService.registerShareableDisplays(displays, virtualSerialResolver: virtualSerialResolver)
        }
    }

    package func beginSharing(display: SCDisplay) async throws -> DisplayStartOutcome<Void> {
        let displayID = display.displayID
        let startToken = startTracker.begin(displayID: displayID)
        let correlationID = UUID().uuidString
        syncSharingState()
        defer {
            startTracker.end(displayID: displayID, token: startToken)
            syncSharingState()
        }

        await recordEvent(
            severity: .info,
            operation: "Start sharing",
            message: "Started sharing request.",
            metadata: ["displayID": "\(displayID)"],
            correlationID: correlationID,
            deduplicationKey: "sharing.start.\(displayID)"
        )
        do {
            let result = try await sharingService.startSharing(display: display)
            await recordEvent(
                severity: .notice,
                operation: "Start sharing",
                message: "Sharing request completed.",
                metadata: ["displayID": "\(displayID)"],
                correlationID: correlationID,
                deduplicationKey: "sharing.start.\(displayID)"
            )
            return result
        } catch {
            await observability?.record(
                error: error,
                subsystem: .sharing,
                operation: "Start sharing",
                context: .init(
                    metadata: ["displayID": "\(displayID)"],
                    correlationID: correlationID,
                    deduplicationKey: "sharing.start.\(displayID)"
                )
            )
            throw error
        }
    }

    package func stopSharing(displayID: CGDirectDisplayID) {
        startTracker.clear(displayID: displayID)
        Task {
            await recordEvent(
                severity: .notice,
                operation: "Stop sharing",
                message: "Stopped sharing display.",
                metadata: ["displayID": "\(displayID)"],
                deduplicationKey: "sharing.stop.\(displayID)"
            )
        }
        mutationRunner.run {
            sharingService.stopSharing(displayID: displayID)
        }
    }

    package func stopAllSharing() {
        startTracker.clearAll()
        Task {
            await recordEvent(
                severity: .notice,
                operation: "Stop all sharing",
                message: "Stopped all active sharing sessions.",
                metadata: [:]
            )
        }
        mutationRunner.run {
            sharingService.stopAllSharing()
        }
    }

    package func configureObservability(_ observability: ObservabilityCenter?) {
        self.observability = observability
        requestSnapshotRefresh()
    }

    package var webServicePortValue: UInt16 {
        sharingService.webServicePortValue
    }

    package var preferredWebServicePort: UInt16 {
        portPreferences.preferredPort
    }

    package func isDisplaySharing(displayID: CGDirectDisplayID) -> Bool {
        activeSharingDisplayIDs.contains(displayID)
    }

    package func isSharing(displayID: CGDirectDisplayID) -> Bool {
        sharingService.isSharing(displayID: displayID)
    }

    package func isStarting(displayID: CGDirectDisplayID) -> Bool {
        startTracker.contains(displayID: displayID)
    }

    package func sharePagePath(for displayID: CGDirectDisplayID) -> String? {
        guard let shareID = sharingService.shareID(for: displayID) else { return nil }
        return ShareTarget.id(shareID).displayPath
    }

    package func sharePageURLResolution(for displayID: CGDirectDisplayID?) -> Result<URL, SharePageURLFailure> {
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

    package func sharePageURL(for displayID: CGDirectDisplayID?) -> URL? {
        guard case .success(let url) = sharePageURLResolution(for: displayID) else {
            return nil
        }
        return url
    }

    package func sharePageAddress(for displayID: CGDirectDisplayID?) -> String? {
        sharePageURL(for: displayID)?.absoluteString
    }

    private func syncSharingState() {
        let previousLifecycle = webServiceLifecycleState
        webServer = sharingService.currentWebServer
        activeSharingDisplayIDs = sharingService.activeSharingDisplayIDs
        isSharing = sharingService.hasAnyActiveSharing
        isWebServiceRunning = sharingService.isWebServiceRunning
        webServiceLifecycleState = sharingService.webServiceLifecycleState
        startingDisplayIDs = startTracker.activeDisplayIDs
        refreshSharingCountsFromSnapshot()
        requestSnapshotRefresh()
        if previousLifecycle != webServiceLifecycleState {
            Task {
                await recordEvent(
                    severity: .info,
                    operation: "Web service lifecycle changed",
                    message: "Updated web service lifecycle state.",
                    metadata: ["phase": lifecyclePhaseDescription(webServiceLifecycleState)]
                )
            }
        }
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

    private func lifecyclePhaseDescription(_ state: WebServiceLifecycleState) -> String {
        switch state {
        case .stopped:
            "stopped"
        case .starting:
            "starting"
        case .running:
            "running"
        case .stopping:
            "stopping"
        case .failed:
            "failed"
        }
    }

    private func requestSnapshotRefresh() {
        guard let observability else { return }
        Task {
            await observability.refreshSnapshot(reason: .sharingStateChanged)
        }
    }

    private func recordEvent(
        severity: ObservabilitySeverity,
        operation: String,
        message: String,
        metadata: [String: String],
        correlationID: String? = nil,
        deduplicationKey: String? = nil
    ) async {
        await observability?.record(
            ObservabilityEvent(
                severity: severity,
                subsystem: .sharing,
                operation: operation,
                message: message,
                metadata: metadata,
                correlationID: correlationID,
                deduplicationKey: deduplicationKey
            )
        )
    }

#if DEBUG
    package func installStartingDisplayIDsForTesting(_ displayIDs: Set<CGDirectDisplayID>) {
        startTracker.clearAll()
        for displayID in displayIDs {
            _ = startTracker.begin(displayID: displayID)
        }
        syncSharingState()
    }
#endif
}
