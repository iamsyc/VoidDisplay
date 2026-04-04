import Foundation
import ScreenCaptureKit
import CoreGraphics

@MainActor
final class CaptureMonitoringLifecycleService: CaptureMonitoringLifecycleServiceProtocol {
    typealias AcquirePreview = @MainActor (
        SCDisplay,
        DisplayStartInvalidationContext
    ) async throws -> DisplayStartOutcome<DisplayPreviewSubscription>

    private let captureMonitoringService: any CaptureMonitoringServiceProtocol
    private let startCoordinator: DisplayStreamStartCoordinator
    private let acquirePreview: AcquirePreview

    init(
        captureMonitoringService: any CaptureMonitoringServiceProtocol,
        startCoordinator: DisplayStreamStartCoordinator = DisplayStreamStartCoordinator(),
        captureRegistry: DisplayCaptureRegistry = .shared,
        acquirePreview: AcquirePreview? = nil
    ) {
        self.captureMonitoringService = captureMonitoringService
        self.startCoordinator = startCoordinator
        self.acquirePreview = acquirePreview ?? { display, invalidationContext in
            try await captureRegistry.acquirePreview(
                display: SendableDisplay(display),
                invalidationContext: invalidationContext
            )
        }
    }

    func isStarting(displayID: CGDirectDisplayID) -> Bool {
        startCoordinator.isStarting(kind: .monitoring, displayID: displayID)
    }

    func startMonitoring(
        display: SCDisplay,
        metadata: CaptureMonitoringDisplayMetadata
    ) async throws -> DisplayStartOutcome<UUID> {
        let displayID = display.displayID
        if let existingSession = existingSession(for: displayID) {
            return .started(existingSession.id)
        }

        return try await startCoordinator.start(
            kind: .monitoring,
            displayID: displayID
        ) { [captureMonitoringService, acquirePreview] invalidationContext in
            if let existingSession = captureMonitoringService.currentSessions.first(
                where: { $0.displayID == displayID }
            ) {
                return .started(existingSession.id)
            }

            switch try await acquirePreview(display, invalidationContext) {
            case .invalidated:
                return .invalidated
            case .started(let previewSubscription):
                if invalidationContext.isInvalidated() {
                    previewSubscription.cancel()
                    return .invalidated
                }
                if let existingSession = captureMonitoringService.currentSessions.first(
                    where: { $0.displayID == displayID }
                ) {
                    previewSubscription.cancel()
                    return .started(existingSession.id)
                }

                let session = ScreenMonitoringSession(
                    id: UUID(),
                    displayID: displayID,
                    displayName: metadata.displayName,
                    resolutionText: metadata.resolutionText,
                    isVirtualDisplay: metadata.isVirtualDisplay,
                    previewSubscription: previewSubscription,
                    capturesCursor: false,
                    state: .starting
                )
                if invalidationContext.isInvalidated() {
                    previewSubscription.cancel()
                    return .invalidated
                }
                captureMonitoringService.addMonitoringSession(session)
                return .started(session.id)
            }
        }
    }

    func activateMonitoringSession(id: UUID) {
        guard captureMonitoringService.monitoringSession(for: id) != nil else { return }
        captureMonitoringService.updateMonitoringSessionState(id: id, state: .active)
    }

    func attachPreviewSink(_ sink: any DisplayPreviewSink, to id: UUID) {
        guard let session = captureMonitoringService.monitoringSession(for: id) else { return }
        session.previewSubscription.attachPreviewSink(sink)
    }

    func setMonitoringSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) async throws {
        guard let session = captureMonitoringService.monitoringSession(for: id) else { return }
        try await session.previewSubscription.setShowsCursor(capturesCursor)
        captureMonitoringService.updateMonitoringSessionCapturesCursor(
            id: id,
            capturesCursor: capturesCursor
        )
    }

    func closeMonitoringSession(id: UUID) {
        guard captureMonitoringService.monitoringSession(for: id) != nil else { return }
        captureMonitoringService.removeMonitoringSession(id: id)
    }

    func removeMonitoringSessions(displayID: CGDirectDisplayID) {
        startCoordinator.invalidate(kind: .monitoring, displayID: displayID)
        captureMonitoringService.removeMonitoringSessions(displayID: displayID)
    }

    private func existingSession(for displayID: CGDirectDisplayID) -> ScreenMonitoringSession? {
        captureMonitoringService.currentSessions.first(where: { $0.displayID == displayID })
    }
}
