import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import Foundation

@MainActor
package final class CapturePreviewSessionStore {
    private var sessions: [ScreenPreviewSession]

    package init(initialSessions: [ScreenPreviewSession] = []) {
        self.sessions = initialSessions
    }

    package var currentSessions: [ScreenPreviewSession] {
        sessions
    }

    package func session(for id: UUID) -> ScreenPreviewSession? {
        sessions.first { $0.id == id }
    }

    package func add(_ session: ScreenPreviewSession) {
        sessions.append(session)
    }

    package func updateState(
        id: UUID,
        state: ScreenPreviewSession.State
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let currentState = sessions[index].state
        guard shouldApplyStateTransition(from: currentState, to: state) else { return }
        sessions[index].state = state
    }

    package func updateCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard sessions[index].capturesCursor != capturesCursor else { return }
        sessions[index].capturesCursor = capturesCursor
    }

    package func remove(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].previewSubscription.cancel()
        sessions.remove(at: index)
    }

    package func remove(displayID: CGDirectDisplayID) {
        let removalIndexes = sessions.indices.filter { sessions[$0].displayID == displayID }
        guard !removalIndexes.isEmpty else { return }

        for index in removalIndexes {
            sessions[index].previewSubscription.cancel()
        }
        sessions.removeAll { $0.displayID == displayID }
    }

    private func shouldApplyStateTransition(
        from currentState: ScreenPreviewSession.State,
        to nextState: ScreenPreviewSession.State
    ) -> Bool {
        switch (currentState, nextState) {
        case (.starting, .active):
            true
        case (.starting, .starting), (.active, .active), (.active, .starting):
            false
        }
    }
}
