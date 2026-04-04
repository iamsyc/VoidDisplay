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
    private(set) var startingDisplayIDs: Set<CGDirectDisplayID> = []
    @ObservationIgnored let catalogService: ScreenCaptureCatalogService

    @ObservationIgnored private let captureMonitoringService: any CaptureMonitoringServiceProtocol
    @ObservationIgnored private let captureMonitoringLifecycleService: any CaptureMonitoringLifecycleServiceProtocol
    @ObservationIgnored private let startTracker = DisplayStartTracker()
    @ObservationIgnored private lazy var mutationRunner = SnapshotMutationRunner { [weak self] in
        self?.syncCaptureMonitoringState()
    }

    init(
        captureMonitoringService: any CaptureMonitoringServiceProtocol,
        captureMonitoringLifecycleService: (any CaptureMonitoringLifecycleServiceProtocol)? = nil,
        catalogService: ScreenCaptureCatalogService? = nil
    ) {
        self.captureMonitoringService = captureMonitoringService
        self.captureMonitoringLifecycleService = captureMonitoringLifecycleService
            ?? CaptureMonitoringLifecycleService(captureMonitoringService: captureMonitoringService)
        self.catalogService = catalogService ?? ScreenCaptureCatalogService()
        self.screenCaptureSessions = captureMonitoringService.currentSessions
    }

    var displayCatalogState: ScreenCaptureDisplayCatalogState {
        catalogService.store
    }

    func monitoringSession(for id: UUID) -> ScreenMonitoringSession? {
        captureMonitoringService.monitoringSession(for: id)
    }

    func isStarting(displayID: CGDirectDisplayID) -> Bool {
        startTracker.contains(displayID: displayID)
    }

    func startMonitoring(
        display: SCDisplay,
        metadata: CaptureMonitoringDisplayMetadata
    ) async throws -> DisplayStartOutcome<UUID> {
        let displayID = display.displayID
        let startToken = startTracker.begin(displayID: displayID)
        syncCaptureMonitoringState()
        defer {
            startTracker.end(displayID: displayID, token: startToken)
            syncCaptureMonitoringState()
        }

        return try await captureMonitoringLifecycleService.startMonitoring(
            display: display,
            metadata: metadata
        )
    }

    func activateMonitoringSession(id: UUID) {
        mutationRunner.run {
            captureMonitoringLifecycleService.activateMonitoringSession(id: id)
        }
    }

    func attachPreviewSink(_ sink: any DisplayPreviewSink, to id: UUID) {
        mutationRunner.run {
            captureMonitoringLifecycleService.attachPreviewSink(sink, to: id)
        }
    }

    func setMonitoringSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) async throws {
        try await mutationRunner.run {
            try await captureMonitoringLifecycleService.setMonitoringSessionCapturesCursor(
                id: id,
                capturesCursor: capturesCursor
            )
        }
    }

    func closeMonitoringSession(id: UUID) {
        mutationRunner.run {
            captureMonitoringLifecycleService.closeMonitoringSession(id: id)
        }
    }

    func removeMonitoringSessions(displayID: CGDirectDisplayID) {
        startTracker.clear(displayID: displayID)
        mutationRunner.run {
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
        startingDisplayIDs = startTracker.activeDisplayIDs
    }

#if DEBUG
    func installStartingDisplayIDsForTesting(_ displayIDs: Set<CGDirectDisplayID>) {
        startTracker.clearAll()
        for displayID in displayIDs {
            _ = startTracker.begin(displayID: displayID)
        }
        syncCaptureMonitoringState()
    }
#endif
}
