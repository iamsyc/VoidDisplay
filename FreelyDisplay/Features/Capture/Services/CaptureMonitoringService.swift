import Foundation
import ScreenCaptureKit

@MainActor
final class CaptureMonitoringService {
    private var sessions: [AppHelper.ScreenMonitoringSession] = []

    var currentSessions: [AppHelper.ScreenMonitoringSession] {
        sessions
    }

    func monitoringSession(for id: UUID) -> AppHelper.ScreenMonitoringSession? {
        sessions.first { $0.id == id }
    }

    func addMonitoringSession(_ session: AppHelper.ScreenMonitoringSession) {
        sessions.append(session)
    }

    func updateMonitoringSessionState(
        id: UUID,
        state: AppHelper.ScreenMonitoringSession.State
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
}
