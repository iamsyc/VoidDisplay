import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import ScreenCaptureKit
import CoreGraphics

@MainActor
package final class CapturePreviewLifecycleService: CapturePreviewLifecycleServiceProtocol {
    package typealias AcquirePreview = @MainActor (
        SCDisplay,
        DisplayStartInvalidationContext
    ) async throws -> DisplayStartOutcome<DisplayPreviewSubscription>

    private let capturePreviewService: any CapturePreviewServiceProtocol
    private let startCoordinator: DisplayStreamStartCoordinator<UUID>
    private let acquirePreview: AcquirePreview

    package init(
        capturePreviewService: any CapturePreviewServiceProtocol,
        startCoordinator: DisplayStreamStartCoordinator<UUID> = DisplayStreamStartCoordinator<UUID>(),
        captureRegistry: DisplayCaptureRegistry = .shared,
        acquirePreview: AcquirePreview? = nil
    ) {
        self.capturePreviewService = capturePreviewService
        self.startCoordinator = startCoordinator
        self.acquirePreview = acquirePreview ?? { display, invalidationContext in
            try await captureRegistry.acquirePreview(
                display: SendableDisplay(display),
                invalidationContext: invalidationContext
            )
        }
    }

    package func startPreview(
        display: SCDisplay,
        metadata: CapturePreviewDisplayMetadata
    ) async throws -> DisplayStartOutcome<UUID> {
        let displayID = display.displayID
        if let existingSession = existingSession(for: displayID) {
            return .started(existingSession.id)
        }

        return try await startCoordinator.start(
            displayID: displayID
        ) { [capturePreviewService, acquirePreview] invalidationContext in
            if let existingSession = capturePreviewService.currentSessions.first(
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
                if let existingSession = capturePreviewService.currentSessions.first(
                    where: { $0.displayID == displayID }
                ) {
                    previewSubscription.cancel()
                    return .started(existingSession.id)
                }

                let session = ScreenPreviewSession(
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
                capturePreviewService.addPreviewSession(session)
                return .started(session.id)
            }
        }
    }

    package func activatePreviewSession(id: UUID) {
        guard capturePreviewService.previewSession(for: id) != nil else { return }
        capturePreviewService.updatePreviewSessionState(id: id, state: .active)
    }

    package func attachPreviewSink(_ sink: any DisplayPreviewSink, to id: UUID) {
        guard let session = capturePreviewService.previewSession(for: id) else { return }
        session.previewSubscription.attachPreviewSink(sink)
    }

    package func setPreviewSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) async throws {
        guard let session = capturePreviewService.previewSession(for: id) else { return }
        try await session.previewSubscription.setShowsCursor(capturesCursor)
        capturePreviewService.updatePreviewSessionCapturesCursor(
            id: id,
            capturesCursor: capturesCursor
        )
    }

    package func closePreviewSession(id: UUID) {
        guard capturePreviewService.previewSession(for: id) != nil else { return }
        capturePreviewService.removePreviewSession(id: id)
    }

    package func removePreviewSessions(displayID: CGDirectDisplayID) {
        startCoordinator.invalidate(displayID: displayID)
        capturePreviewService.removePreviewSessions(displayID: displayID)
    }

    private func existingSession(for displayID: CGDirectDisplayID) -> ScreenPreviewSession? {
        capturePreviewService.currentSessions.first(where: { $0.displayID == displayID })
    }
}
