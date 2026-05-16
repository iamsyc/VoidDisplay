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
    package var screenPreviewSessions: [ScreenPreviewSession] = []
    private(set) var startingDisplayIDs: Set<CGDirectDisplayID> = []
    @ObservationIgnored let catalogService: ScreenCaptureCatalogService

    @ObservationIgnored private let capturePreviewService: any CapturePreviewServiceProtocol
    @ObservationIgnored private let capturePreviewLifecycleService: any CapturePreviewLifecycleServiceProtocol
    @ObservationIgnored private let startTracker = DisplayStartTracker()
    @ObservationIgnored private weak var observability: ObservabilityCenter?
    @ObservationIgnored private lazy var mutationRunner = SnapshotMutationRunner { [weak self] in
        self?.syncCapturePreviewState()
    }

    package init(
        capturePreviewService: any CapturePreviewServiceProtocol,
        capturePreviewLifecycleService: (any CapturePreviewLifecycleServiceProtocol)? = nil,
        catalogService: ScreenCaptureCatalogService? = nil,
        observability: ObservabilityCenter? = nil
    ) {
        self.capturePreviewService = capturePreviewService
        self.capturePreviewLifecycleService = capturePreviewLifecycleService
            ?? CapturePreviewLifecycleService(capturePreviewService: capturePreviewService)
        self.catalogService = catalogService ?? ScreenCaptureCatalogService()
        self.observability = observability
        self.screenPreviewSessions = capturePreviewService.currentSessions
    }

    package var displayCatalogState: ScreenCaptureDisplayCatalogState {
        catalogService.store
    }

    package func previewSession(for id: UUID) -> ScreenPreviewSession? {
        capturePreviewService.previewSession(for: id)
    }

    package func isStarting(displayID: CGDirectDisplayID) -> Bool {
        startTracker.contains(displayID: displayID)
    }

    package func startPreview(
        display: SCDisplay,
        metadata: CapturePreviewDisplayMetadata
    ) async throws -> DisplayStartOutcome<UUID> {
        let displayID = display.displayID
        let startToken = startTracker.begin(displayID: displayID)
        let correlationID = UUID().uuidString
        syncCapturePreviewState()
        defer {
            startTracker.end(displayID: displayID, token: startToken)
            syncCapturePreviewState()
        }

        await recordEvent(
            severity: .info,
            operation: "Start preview",
            message: "Started preview request.",
            metadata: ["displayID": "\(displayID)"],
            correlationID: correlationID
        )

        do {
            let outcome = try await capturePreviewLifecycleService.startPreview(
                display: display,
                metadata: metadata
            )
            await recordEvent(
                severity: .notice,
                operation: "Start preview",
                message: "Preview request completed.",
                metadata: ["displayID": "\(displayID)"],
                correlationID: correlationID
            )
            return outcome
        } catch {
            await observability?.record(
                error: error,
                subsystem: .capture,
                operation: "Start preview",
                context: .init(
                    metadata: ["displayID": "\(displayID)"],
                    correlationID: correlationID,
                    deduplicationKey: "capture.start.\(displayID)"
                )
            )
            throw error
        }
    }

    package func activatePreviewSession(id: UUID) {
        mutationRunner.run {
            capturePreviewLifecycleService.activatePreviewSession(id: id)
        }
    }

    package func attachPreviewSink(_ sink: any DisplayPreviewSink, to id: UUID) {
        mutationRunner.run {
            capturePreviewLifecycleService.attachPreviewSink(sink, to: id)
        }
    }

    package func setPreviewSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) async throws {
        try await mutationRunner.run {
            try await capturePreviewLifecycleService.setPreviewSessionCapturesCursor(
                id: id,
                capturesCursor: capturesCursor
            )
        }
    }

    package func closePreviewSession(id: UUID) {
        if let session = previewSession(for: id) {
            Task {
                await recordEvent(
                    severity: .info,
                    operation: "Close preview session",
                    message: "Closed preview session.",
                    metadata: ["displayID": "\(session.displayID)", "sessionID": session.id.uuidString]
                )
            }
        }
        mutationRunner.run {
            capturePreviewLifecycleService.closePreviewSession(id: id)
        }
    }

    package func removePreviewSessions(displayID: CGDirectDisplayID) {
        startTracker.clear(displayID: displayID)
        Task {
            await recordEvent(
                severity: .notice,
                operation: "Remove preview sessions",
                message: "Removed preview sessions for display.",
                metadata: ["displayID": "\(displayID)"],
                deduplicationKey: "capture.remove.\(displayID)"
            )
        }
        mutationRunner.run {
            capturePreviewLifecycleService.removePreviewSessions(displayID: displayID)
        }
    }

    package func configureObservability(_ observability: ObservabilityCenter?) {
        self.observability = observability
        requestSnapshotRefresh()
    }

    private func syncCapturePreviewState() {
        screenPreviewSessions = capturePreviewService.currentSessions
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
        syncCapturePreviewState()
    }
#endif
}
