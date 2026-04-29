import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import CoreGraphics

@MainActor
package protocol CaptureMonitoringServiceProtocol: AnyObject {
    var currentSessions: [ScreenMonitoringSession] { get }
    func monitoringSession(for id: UUID) -> ScreenMonitoringSession?
    func addMonitoringSession(_ session: ScreenMonitoringSession)
    func updateMonitoringSessionState(
        id: UUID,
        state: ScreenMonitoringSession.State
    )
    func updateMonitoringSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    )
    func removeMonitoringSession(id: UUID)
    func removeMonitoringSessions(displayID: CGDirectDisplayID)
}

@MainActor
package final class CaptureMonitoringService: CaptureMonitoringServiceProtocol {
    private let sessionStore: CaptureMonitoringSessionStore

    package init(initialSessions: [ScreenMonitoringSession] = []) {
        self.sessionStore = CaptureMonitoringSessionStore(initialSessions: initialSessions)
    }

    package var currentSessions: [ScreenMonitoringSession] {
        sessionStore.currentSessions
    }

    package func monitoringSession(for id: UUID) -> ScreenMonitoringSession? {
        sessionStore.session(for: id)
    }

    package func addMonitoringSession(_ session: ScreenMonitoringSession) {
        sessionStore.add(session)
    }

    package func updateMonitoringSessionState(
        id: UUID,
        state: ScreenMonitoringSession.State
    ) {
        sessionStore.updateState(id: id, state: state)
    }

    package func updateMonitoringSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) {
        sessionStore.updateCapturesCursor(id: id, capturesCursor: capturesCursor)
    }

    package func removeMonitoringSession(id: UUID) {
        sessionStore.remove(id: id)
    }

    package func removeMonitoringSessions(displayID: CGDirectDisplayID) {
        sessionStore.remove(displayID: displayID)
    }
}
