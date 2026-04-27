import Foundation
import Testing
@testable import VoidDisplay

@Suite(.serialized)
struct SupportDraftStoreTests {
    @Test func saveLoadAndClearSnapshot() {
        let suiteName = "support-draft-store.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SupportDraftStore(defaults: defaults)
        let snapshot = SupportDraftSnapshot(
            issueType: .cannotShare,
            happened: "Sharing disconnects",
            reproductionSteps: "Open app and start sharing",
            expectedResult: "Connection stays active",
            includeUnifiedLogSummary: true,
            includeRelatedConfigSnapshots: true
        )

        store.save(snapshot)
        #expect(store.load() == snapshot)

        store.clear()
        #expect(store.load() == SupportDraftSnapshot())
    }
}
