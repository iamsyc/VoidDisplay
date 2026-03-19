import Foundation
import CoreGraphics

@MainActor
protocol CaptureMonitoringServiceProtocol: AnyObject {
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
final class CaptureMonitoringService: CaptureMonitoringServiceProtocol {
    private let sessionStore: CaptureMonitoringSessionStore

    init(initialSessions: [ScreenMonitoringSession] = []) {
        self.sessionStore = CaptureMonitoringSessionStore(initialSessions: initialSessions)
    }

    var currentSessions: [ScreenMonitoringSession] {
        sessionStore.currentSessions
    }

    func monitoringSession(for id: UUID) -> ScreenMonitoringSession? {
        sessionStore.session(for: id)
    }

    func addMonitoringSession(_ session: ScreenMonitoringSession) {
        sessionStore.add(session)
    }

    func updateMonitoringSessionState(
        id: UUID,
        state: ScreenMonitoringSession.State
    ) {
        sessionStore.updateState(id: id, state: state)
    }

    func updateMonitoringSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) {
        sessionStore.updateCapturesCursor(id: id, capturesCursor: capturesCursor)
    }

    func removeMonitoringSession(id: UUID) {
        sessionStore.remove(id: id)
    }

    func removeMonitoringSessions(displayID: CGDirectDisplayID) {
        sessionStore.remove(displayID: displayID)
    }
}
