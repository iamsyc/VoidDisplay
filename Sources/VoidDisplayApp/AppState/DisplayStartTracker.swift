import CoreGraphics
import Foundation

@MainActor
package final class DisplayStartTracker {
    private var tokensByDisplayID: [CGDirectDisplayID: Set<UUID>] = [:]

    package var activeDisplayIDs: Set<CGDirectDisplayID> {
        Set(tokensByDisplayID.keys)
    }

    package func contains(displayID: CGDirectDisplayID) -> Bool {
        tokensByDisplayID[displayID]?.isEmpty == false
    }

    @discardableResult
    package func begin(displayID: CGDirectDisplayID) -> UUID {
        let token = UUID()
        var tokens = tokensByDisplayID[displayID] ?? []
        tokens.insert(token)
        tokensByDisplayID[displayID] = tokens
        return token
    }

    package func end(displayID: CGDirectDisplayID, token: UUID) {
        guard var tokens = tokensByDisplayID[displayID] else { return }
        tokens.remove(token)
        if tokens.isEmpty {
            tokensByDisplayID.removeValue(forKey: displayID)
        } else {
            tokensByDisplayID[displayID] = tokens
        }
    }

    package func clear(displayID: CGDirectDisplayID) {
        tokensByDisplayID.removeValue(forKey: displayID)
    }

    package func clearAll() {
        tokensByDisplayID.removeAll()
    }
}
