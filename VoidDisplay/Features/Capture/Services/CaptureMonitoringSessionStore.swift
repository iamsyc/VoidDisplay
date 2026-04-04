import CoreGraphics
import Foundation

@MainActor
final class CaptureMonitoringSessionStore {
    private var sessions: [ScreenMonitoringSession]

    init(initialSessions: [ScreenMonitoringSession] = []) {
        self.sessions = initialSessions
    }

    var currentSessions: [ScreenMonitoringSession] {
        sessions
    }

    func session(for id: UUID) -> ScreenMonitoringSession? {
        sessions.first { $0.id == id }
    }

    func add(_ session: ScreenMonitoringSession) {
        sessions.append(session)
    }

    func updateState(
        id: UUID,
        state: ScreenMonitoringSession.State
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let currentState = sessions[index].state
        guard shouldApplyStateTransition(from: currentState, to: state) else { return }
        sessions[index].state = state
    }

    func updateCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard sessions[index].capturesCursor != capturesCursor else { return }
        sessions[index].capturesCursor = capturesCursor
    }

    func remove(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].previewSubscription.cancel()
        sessions.remove(at: index)
    }

    func remove(displayID: CGDirectDisplayID) {
        let removalIndexes = sessions.indices.filter { sessions[$0].displayID == displayID }
        guard !removalIndexes.isEmpty else { return }

        for index in removalIndexes {
            sessions[index].previewSubscription.cancel()
        }
        sessions.removeAll { $0.displayID == displayID }
    }

    private func shouldApplyStateTransition(
        from currentState: ScreenMonitoringSession.State,
        to nextState: ScreenMonitoringSession.State
    ) -> Bool {
        switch (currentState, nextState) {
        case (.starting, .active):
            true
        case (.starting, .starting), (.active, .active), (.active, .starting):
            false
        }
    }
}
