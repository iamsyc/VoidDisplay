//
//  CaptureController.swift
//  VoidDisplay
//

import Foundation
import CoreGraphics
import Observation

@MainActor
@Observable
final class CaptureController {
    var screenCaptureSessions: [ScreenMonitoringSession] = []
    @ObservationIgnored let displayCatalogState = ScreenCaptureDisplayCatalogState()

    @ObservationIgnored private let captureMonitoringService: any CaptureMonitoringServiceProtocol

    init(captureMonitoringService: any CaptureMonitoringServiceProtocol) {
        self.captureMonitoringService = captureMonitoringService
        self.screenCaptureSessions = captureMonitoringService.currentSessions
    }

    func monitoringSession(for id: UUID) -> ScreenMonitoringSession? {
        captureMonitoringService.monitoringSession(for: id)
    }

    func addMonitoringSession(_ session: ScreenMonitoringSession) {
        mutateAndSync {
            captureMonitoringService.addMonitoringSession(session)
        }
    }

    func markMonitoringSessionActive(id: UUID) {
        mutateAndSync {
            captureMonitoringService.updateMonitoringSessionState(id: id, state: .active)
        }
    }

    func removeMonitoringSession(id: UUID) {
        mutateAndSync {
            captureMonitoringService.removeMonitoringSession(id: id)
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
}
