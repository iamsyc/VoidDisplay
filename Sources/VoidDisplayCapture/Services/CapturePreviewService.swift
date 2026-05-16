import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import CoreGraphics

@MainActor
package protocol CapturePreviewServiceProtocol: AnyObject {
    var currentSessions: [ScreenPreviewSession] { get }
    func previewSession(for id: UUID) -> ScreenPreviewSession?
    func addPreviewSession(_ session: ScreenPreviewSession)
    func updatePreviewSessionState(
        id: UUID,
        state: ScreenPreviewSession.State
    )
    func updatePreviewSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    )
    func removePreviewSession(id: UUID)
    func removePreviewSessions(displayID: CGDirectDisplayID)
}

@MainActor
package final class CapturePreviewService: CapturePreviewServiceProtocol {
    private let sessionStore: CapturePreviewSessionStore

    package init(initialSessions: [ScreenPreviewSession] = []) {
        self.sessionStore = CapturePreviewSessionStore(initialSessions: initialSessions)
    }

    package var currentSessions: [ScreenPreviewSession] {
        sessionStore.currentSessions
    }

    package func previewSession(for id: UUID) -> ScreenPreviewSession? {
        sessionStore.session(for: id)
    }

    package func addPreviewSession(_ session: ScreenPreviewSession) {
        sessionStore.add(session)
    }

    package func updatePreviewSessionState(
        id: UUID,
        state: ScreenPreviewSession.State
    ) {
        sessionStore.updateState(id: id, state: state)
    }

    package func updatePreviewSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) {
        sessionStore.updateCapturesCursor(id: id, capturesCursor: capturesCursor)
    }

    package func removePreviewSession(id: UUID) {
        sessionStore.remove(id: id)
    }

    package func removePreviewSessions(displayID: CGDirectDisplayID) {
        sessionStore.remove(displayID: displayID)
    }
}
