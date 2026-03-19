import Foundation
import ScreenCaptureKit

@MainActor
protocol CaptureMonitoringLifecycleServiceProtocol: AnyObject {
    func startMonitoring(
        display: SCDisplay,
        metadata: CaptureMonitoringDisplayMetadata
    ) async throws -> UUID
    func activateMonitoringSession(id: UUID)
    func attachPreviewSink(_ sink: any DisplayPreviewSink, to id: UUID)
    func setMonitoringSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) async throws
    func closeMonitoringSession(id: UUID)
}
