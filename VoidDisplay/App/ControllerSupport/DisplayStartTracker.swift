import CoreGraphics
import Foundation

@MainActor
final class DisplayStartTracker {
    private var tokensByDisplayID: [CGDirectDisplayID: Set<UUID>] = [:]

    var activeDisplayIDs: Set<CGDirectDisplayID> {
        Set(tokensByDisplayID.keys)
    }

    func contains(displayID: CGDirectDisplayID) -> Bool {
        tokensByDisplayID[displayID]?.isEmpty == false
    }

    @discardableResult
    func begin(displayID: CGDirectDisplayID) -> UUID {
        let token = UUID()
        var tokens = tokensByDisplayID[displayID] ?? []
        tokens.insert(token)
        tokensByDisplayID[displayID] = tokens
        return token
    }

    func end(displayID: CGDirectDisplayID, token: UUID) {
        guard var tokens = tokensByDisplayID[displayID] else { return }
        tokens.remove(token)
        if tokens.isEmpty {
            tokensByDisplayID.removeValue(forKey: displayID)
        } else {
            tokensByDisplayID[displayID] = tokens
        }
    }

    func clear(displayID: CGDirectDisplayID) {
        tokensByDisplayID.removeValue(forKey: displayID)
    }

    func clearAll() {
        tokensByDisplayID.removeAll()
    }
}
