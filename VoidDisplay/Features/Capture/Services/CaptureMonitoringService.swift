import Foundation
import ScreenCaptureKit
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
    func removeMonitoringSession(id: UUID)
    func removeMonitoringSessions(displayID: CGDirectDisplayID)
}

@MainActor
final class CaptureMonitoringService: CaptureMonitoringServiceProtocol {
    private var sessions: [ScreenMonitoringSession] = []

    var currentSessions: [ScreenMonitoringSession] {
        sessions
    }

    func monitoringSession(for id: UUID) -> ScreenMonitoringSession? {
        sessions.first { $0.id == id }
    }

    func addMonitoringSession(_ session: ScreenMonitoringSession) {
        sessions.append(session)
    }

    func updateMonitoringSessionState(
        id: UUID,
        state: ScreenMonitoringSession.State
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].state = state
    }

    func removeMonitoringSession(id: UUID) {
        if let session = sessions.first(where: { $0.id == id }) {
            session.stream.stopCapture()
        }
        sessions.removeAll { $0.id == id }
    }

    func removeMonitoringSessions(displayID: CGDirectDisplayID) {
        let targetSessionIDs = sessions
            .filter { $0.displayID == displayID }
            .map(\.id)
        for sessionID in targetSessionIDs {
            removeMonitoringSession(id: sessionID)
        }
    }
}
