import Foundation
import ScreenCaptureKit

@MainActor
final class CaptureMonitoringLifecycleService: CaptureMonitoringLifecycleServiceProtocol {
    typealias AcquirePreview = @MainActor (SCDisplay) async throws -> DisplayPreviewSubscription

    private let captureMonitoringService: any CaptureMonitoringServiceProtocol
    private let acquirePreview: AcquirePreview
    private var inFlightStartTasksByDisplayID: [CGDirectDisplayID: Task<UUID, Error>] = [:]

    init(
        captureMonitoringService: any CaptureMonitoringServiceProtocol,
        acquirePreview: @escaping AcquirePreview = { display in
            try await DisplayCaptureRegistry.shared.acquirePreview(display: SendableDisplay(display))
        }
    ) {
        self.captureMonitoringService = captureMonitoringService
        self.acquirePreview = acquirePreview
    }

    func startMonitoring(
        display: SCDisplay,
        metadata: CaptureMonitoringDisplayMetadata
    ) async throws -> UUID {
        if let existingSession = existingSession(for: display.displayID) {
            return existingSession.id
        }
        if let existingTask = inFlightStartTasksByDisplayID[display.displayID] {
            return try await existingTask.value
        }

        let displayID = display.displayID
        let task = Task { @MainActor [captureMonitoringService, acquirePreview] in
            let clearInFlightTask: @MainActor () -> Void = { [weak self] in
                self?.inFlightStartTasksByDisplayID[displayID] = nil
            }
            defer { clearInFlightTask() }

            if let existingSession = captureMonitoringService.currentSessions.first(
                where: { $0.displayID == displayID }
            ) {
                return existingSession.id
            }

            let previewSubscription = try await acquirePreview(display)
            if let existingSession = captureMonitoringService.currentSessions.first(
                where: { $0.displayID == displayID }
            ) {
                previewSubscription.cancel()
                return existingSession.id
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
            captureMonitoringService.addMonitoringSession(session)
            return session.id
        }
        inFlightStartTasksByDisplayID[displayID] = task
        return try await task.value
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

    private func existingSession(for displayID: CGDirectDisplayID) -> ScreenMonitoringSession? {
        captureMonitoringService.currentSessions.first(where: { $0.displayID == displayID })
    }
}
