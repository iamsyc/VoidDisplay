import VoidDisplayCapture
import VoidDisplayObservability
import VoidDisplayFoundation
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
package final class CaptureController {
    package var screenCaptureSessions: [ScreenMonitoringSession] = []
    private(set) var startingDisplayIDs: Set<CGDirectDisplayID> = []
    @ObservationIgnored let catalogService: ScreenCaptureCatalogService

    @ObservationIgnored private let captureMonitoringService: any CaptureMonitoringServiceProtocol
    @ObservationIgnored private let captureMonitoringLifecycleService: any CaptureMonitoringLifecycleServiceProtocol
    @ObservationIgnored private let startTracker = DisplayStartTracker()
    @ObservationIgnored private weak var observability: ObservabilityCenter?
    @ObservationIgnored private lazy var mutationRunner = SnapshotMutationRunner { [weak self] in
        self?.syncCaptureMonitoringState()
    }

    package init(
        captureMonitoringService: any CaptureMonitoringServiceProtocol,
        captureMonitoringLifecycleService: (any CaptureMonitoringLifecycleServiceProtocol)? = nil,
        catalogService: ScreenCaptureCatalogService? = nil,
        observability: ObservabilityCenter? = nil
    ) {
        self.captureMonitoringService = captureMonitoringService
        self.captureMonitoringLifecycleService = captureMonitoringLifecycleService
            ?? CaptureMonitoringLifecycleService(captureMonitoringService: captureMonitoringService)
        self.catalogService = catalogService ?? ScreenCaptureCatalogService()
        self.observability = observability
        self.screenCaptureSessions = captureMonitoringService.currentSessions
    }

    package var displayCatalogState: ScreenCaptureDisplayCatalogState {
        catalogService.store
    }

    package func monitoringSession(for id: UUID) -> ScreenMonitoringSession? {
        captureMonitoringService.monitoringSession(for: id)
    }

    package func isStarting(displayID: CGDirectDisplayID) -> Bool {
        startTracker.contains(displayID: displayID)
    }

    package func startMonitoring(
        display: SCDisplay,
        metadata: CaptureMonitoringDisplayMetadata
    ) async throws -> DisplayStartOutcome<UUID> {
        let displayID = display.displayID
        let startToken = startTracker.begin(displayID: displayID)
        let correlationID = UUID().uuidString
        syncCaptureMonitoringState()
        defer {
            startTracker.end(displayID: displayID, token: startToken)
            syncCaptureMonitoringState()
        }

        await recordEvent(
            severity: .info,
            operation: "Start monitoring",
            message: "Started monitoring request.",
            metadata: ["displayID": "\(displayID)"],
            correlationID: correlationID
        )

        do {
            let outcome = try await captureMonitoringLifecycleService.startMonitoring(
                display: display,
                metadata: metadata
            )
            await recordEvent(
                severity: .notice,
                operation: "Start monitoring",
                message: "Monitoring request completed.",
                metadata: ["displayID": "\(displayID)"],
                correlationID: correlationID
            )
            return outcome
        } catch {
            await observability?.record(
                error: error,
                subsystem: .capture,
                operation: "Start monitoring",
                context: .init(
                    metadata: ["displayID": "\(displayID)"],
                    correlationID: correlationID,
                    deduplicationKey: "capture.start.\(displayID)"
                )
            )
            throw error
        }
    }

    package func activateMonitoringSession(id: UUID) {
        mutationRunner.run {
            captureMonitoringLifecycleService.activateMonitoringSession(id: id)
        }
    }

    package func attachPreviewSink(_ sink: any DisplayPreviewSink, to id: UUID) {
        mutationRunner.run {
            captureMonitoringLifecycleService.attachPreviewSink(sink, to: id)
        }
    }

    package func setMonitoringSessionCapturesCursor(
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

    package func closeMonitoringSession(id: UUID) {
        if let session = monitoringSession(for: id) {
            Task {
                await recordEvent(
                    severity: .info,
                    operation: "Close monitoring session",
                    message: "Closed monitoring session.",
                    metadata: ["displayID": "\(session.displayID)", "sessionID": session.id.uuidString]
                )
            }
        }
        mutationRunner.run {
            captureMonitoringLifecycleService.closeMonitoringSession(id: id)
        }
    }

    package func removeMonitoringSessions(displayID: CGDirectDisplayID) {
        startTracker.clear(displayID: displayID)
        Task {
            await recordEvent(
                severity: .notice,
                operation: "Remove monitoring sessions",
                message: "Removed monitoring sessions for display.",
                metadata: ["displayID": "\(displayID)"],
                deduplicationKey: "capture.remove.\(displayID)"
            )
        }
        mutationRunner.run {
            captureMonitoringLifecycleService.removeMonitoringSessions(displayID: displayID)
        }
    }

    package func configureObservability(_ observability: ObservabilityCenter?) {
        self.observability = observability
        requestSnapshotRefresh()
    }

    package func stopDependentStreamsBeforeRebuild(
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
        requestSnapshotRefresh()
    }

    private func requestSnapshotRefresh() {
        guard let observability else { return }
        Task {
            await observability.refreshSnapshot(reason: .captureStateChanged)
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
                subsystem: .capture,
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
        syncCaptureMonitoringState()
    }
#endif
}
