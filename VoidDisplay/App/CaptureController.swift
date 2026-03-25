//
//  CaptureController.swift
//  VoidDisplay
//

import Foundation
import CoreGraphics
import ScreenCaptureKit
import Observation

@MainActor
@Observable
final class CaptureController {
    var screenCaptureSessions: [ScreenMonitoringSession] = []
    var startingDisplayIDs: Set<CGDirectDisplayID> = []
    @ObservationIgnored let displayCatalogState = ScreenCaptureDisplayCatalogState()

    @ObservationIgnored private let captureMonitoringService: any CaptureMonitoringServiceProtocol
    @ObservationIgnored private let captureMonitoringLifecycleService: any CaptureMonitoringLifecycleServiceProtocol
    @ObservationIgnored private var observedStartTokensByDisplayID: [CGDirectDisplayID: Set<UUID>] = [:]

    init(
        captureMonitoringService: any CaptureMonitoringServiceProtocol,
        captureMonitoringLifecycleService: (any CaptureMonitoringLifecycleServiceProtocol)? = nil
    ) {
        self.captureMonitoringService = captureMonitoringService
        self.captureMonitoringLifecycleService = captureMonitoringLifecycleService
            ?? CaptureMonitoringLifecycleService(captureMonitoringService: captureMonitoringService)
        self.screenCaptureSessions = captureMonitoringService.currentSessions
    }

    func monitoringSession(for id: UUID) -> ScreenMonitoringSession? {
        captureMonitoringService.monitoringSession(for: id)
    }

    func isStarting(displayID: CGDirectDisplayID) -> Bool {
        startingDisplayIDs.contains(displayID)
    }

    func startMonitoring(
        display: SCDisplay,
        metadata: CaptureMonitoringDisplayMetadata
    ) async throws -> DisplayStartOutcome<UUID> {
        let displayID = display.displayID
        let startToken = beginObservedStart(displayID: displayID)
        defer {
            endObservedStart(displayID: displayID, token: startToken)
            syncCaptureMonitoringState()
        }

        return try await captureMonitoringLifecycleService.startMonitoring(
            display: display,
            metadata: metadata
        )
    }

    func activateMonitoringSession(id: UUID) {
        mutateAndSync {
            captureMonitoringLifecycleService.activateMonitoringSession(id: id)
        }
    }

    func attachPreviewSink(_ sink: any DisplayPreviewSink, to id: UUID) {
        mutateAndSync {
            captureMonitoringLifecycleService.attachPreviewSink(sink, to: id)
        }
    }

    func setMonitoringSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) async throws {
        try await mutateAndSyncAsync {
            try await captureMonitoringLifecycleService.setMonitoringSessionCapturesCursor(
                id: id,
                capturesCursor: capturesCursor
            )
        }
    }

    func closeMonitoringSession(id: UUID) {
        mutateAndSync {
            captureMonitoringLifecycleService.closeMonitoringSession(id: id)
        }
    }

    func removeMonitoringSessions(displayID: CGDirectDisplayID) {
        clearObservedStarts(displayID: displayID)
        mutateAndSync {
            captureMonitoringLifecycleService.removeMonitoringSessions(displayID: displayID)
        }
    }

    func stopDependentStreamsBeforeRebuild(
        displayID: CGDirectDisplayID,
        sharingController: SharingController
    ) {
        if sharingController.isSharing(displayID: displayID) {
            sharingController.stopSharing(displayID: displayID)
        }
        removeMonitoringSessions(displayID: displayID)
    }

    private func syncCaptureMonitoringState() {
        screenCaptureSessions = captureMonitoringService.currentSessions
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

    private func mutateAndSync(_ mutation: () -> Void) {
        mutation()
        syncCaptureMonitoringState()
    }

    private func mutateAndSyncAsync<T>(_ mutation: () async throws -> T) async rethrows -> T {
        defer { syncCaptureMonitoringState() }
        return try await mutation()
    }
}
