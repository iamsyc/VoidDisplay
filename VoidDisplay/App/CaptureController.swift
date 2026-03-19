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
    @ObservationIgnored let displayCatalogState = ScreenCaptureDisplayCatalogState()

    @ObservationIgnored private let captureMonitoringService: any CaptureMonitoringServiceProtocol
    @ObservationIgnored private let captureMonitoringLifecycleService: any CaptureMonitoringLifecycleServiceProtocol

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

    func startMonitoring(
        display: SCDisplay,
        metadata: CaptureMonitoringDisplayMetadata
    ) async throws -> UUID {
        try await mutateAndSyncAsync {
            try await captureMonitoringLifecycleService.startMonitoring(
                display: display,
                metadata: metadata
            )
        }
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
        mutateAndSync {
            captureMonitoringService.removeMonitoringSessions(displayID: displayID)
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

    private func mutateAndSync(_ mutation: () -> Void) {
        mutation()
        syncCaptureMonitoringState()
    }

    private func mutateAndSyncAsync<T>(_ mutation: () async throws -> T) async rethrows -> T {
        defer { syncCaptureMonitoringState() }
        return try await mutation()
    }
}
