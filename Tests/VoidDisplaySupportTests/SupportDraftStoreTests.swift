@testable import VoidDisplaySupport
@testable import VoidDisplayObservability
@testable import VoidDisplayFoundation
import Foundation
import Testing

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
        let clearedSnapshot = store.load()
        #expect(clearedSnapshot == SupportDraftSnapshot())
        #expect(clearedSnapshot.feedbackDraft.isEmpty)
        #expect(clearedSnapshot.includeUnifiedLogSummary)
        #expect(clearedSnapshot.includeCrashReportExcerpt)
        #expect(clearedSnapshot.includeRelatedConfigSnapshots)
    }

    @Test func explicitlyDisabledEnhancedDiagnosticsRemainDisabled() {
        let suiteName = "support-draft-store-disabled-diagnostics.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SupportDraftStore(defaults: defaults)
        store.save(
            SupportDraftSnapshot(
                includeUnifiedLogSummary: false,
                includeCrashReportExcerpt: false,
                includeRelatedConfigSnapshots: false
            )
        )

        let restoredSnapshot = store.load()
        #expect(restoredSnapshot.includeUnifiedLogSummary == false)
        #expect(restoredSnapshot.includeCrashReportExcerpt == false)
        #expect(restoredSnapshot.includeRelatedConfigSnapshots == false)
    }

    @Test func preexistingDisabledEnhancedDiagnosticsRemainDisabled() {
        let suiteName = "support-draft-store-preexisting-disabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "supportCenter.includeUnifiedLogSummary")
        defaults.set(false, forKey: "supportCenter.includeCrashReportExcerpt")
        defaults.set(false, forKey: "supportCenter.includeRelatedConfigSnapshots")

        let store = SupportDraftStore(defaults: defaults)
        let restoredSnapshot = store.load()
        #expect(restoredSnapshot.includeUnifiedLogSummary == false)
        #expect(restoredSnapshot.includeCrashReportExcerpt == false)
        #expect(restoredSnapshot.includeRelatedConfigSnapshots == false)
    }

    @Test func saveAndLoadRemoveAccessSecretsFromPersistedDraft() {
        let suiteName = "support-draft-store-redaction.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let accessToken = String(repeating: "d", count: 64)
        let sanitizer = ObservabilitySanitizer(homePath: "/Users/tester")
        let store = SupportDraftStore(defaults: defaults, sanitizer: sanitizer)
        defaults.set(
            "Open http://192.168.1.3/display/\(accessToken)",
            forKey: "supportCenter.happened"
        )

        let loaded = store.load()

        #expect(loaded.happened.contains(accessToken) == false)
        #expect(loaded.happened.contains("192.168.1.3") == false)
        #expect(defaults.string(forKey: "supportCenter.happened") == loaded.happened)

        store.save(
            SupportDraftSnapshot(
                happened: "Bearer private-token-123"
            )
        )
        #expect(defaults.string(forKey: "supportCenter.happened")?.contains("private-token-123") == false)
    }
}
