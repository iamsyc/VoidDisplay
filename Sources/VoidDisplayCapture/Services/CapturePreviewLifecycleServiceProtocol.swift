import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import ScreenCaptureKit

@MainActor
package protocol CapturePreviewLifecycleServiceProtocol: AnyObject {
    func isStarting(displayID: CGDirectDisplayID) -> Bool
    func startPreview(
        display: SCDisplay,
        metadata: CapturePreviewDisplayMetadata
    ) async throws -> DisplayStartOutcome<UUID>
    func activatePreviewSession(id: UUID)
    func attachPreviewSink(_ sink: any DisplayPreviewSink, to id: UUID)
    func setPreviewSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) async throws
    func closePreviewSession(id: UUID)
    func removePreviewSessions(displayID: CGDirectDisplayID)
}
