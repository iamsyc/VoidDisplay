import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
package nonisolated struct SupportDraftStore {
    private enum Keys {
        static let issueType = "supportCenter.issueType"
        static let happened = "supportCenter.happened"
        static let reproductionSteps = "supportCenter.reproductionSteps"
        static let expectedResult = "supportCenter.expectedResult"
        static let includeUnifiedLogSummary = "supportCenter.includeUnifiedLogSummary"
        static let includeCrashReportExcerpt = "supportCenter.includeCrashReportExcerpt"
        static let includeRelatedConfigSnapshots = "supportCenter.includeRelatedConfigSnapshots"
    }

    private let defaults: UserDefaults
    private let sanitizer: ObservabilitySanitizer

    package init(
        defaults: UserDefaults,
        sanitizer: ObservabilitySanitizer = ObservabilitySanitizer()
    ) {
        self.defaults = defaults
        self.sanitizer = sanitizer
    }

    package func load() -> SupportDraftSnapshot {
        let rawIssueType = defaults.string(forKey: Keys.issueType)
        return SupportDraftSnapshot(
            issueType: rawIssueType.flatMap(SupportIssueType.init(rawValue:)) ?? .other,
            happened: loadSanitizedValue(forKey: Keys.happened),
            reproductionSteps: loadSanitizedValue(forKey: Keys.reproductionSteps),
            expectedResult: loadSanitizedValue(forKey: Keys.expectedResult),
            includeUnifiedLogSummary: defaults.bool(forKey: Keys.includeUnifiedLogSummary),
            includeCrashReportExcerpt: defaults.bool(forKey: Keys.includeCrashReportExcerpt),
            includeRelatedConfigSnapshots: defaults.bool(forKey: Keys.includeRelatedConfigSnapshots)
        )
    }

    package func save(_ snapshot: SupportDraftSnapshot) {
        defaults.set(snapshot.issueType.rawValue, forKey: Keys.issueType)
        defaults.set(sanitized(snapshot.happened), forKey: Keys.happened)
        defaults.set(sanitized(snapshot.reproductionSteps), forKey: Keys.reproductionSteps)
        defaults.set(sanitized(snapshot.expectedResult), forKey: Keys.expectedResult)
        defaults.set(snapshot.includeUnifiedLogSummary, forKey: Keys.includeUnifiedLogSummary)
        defaults.set(snapshot.includeCrashReportExcerpt, forKey: Keys.includeCrashReportExcerpt)
        defaults.set(snapshot.includeRelatedConfigSnapshots, forKey: Keys.includeRelatedConfigSnapshots)
    }

    package func clear() {
        [
            Keys.issueType,
            Keys.happened,
            Keys.reproductionSteps,
            Keys.expectedResult,
            Keys.includeUnifiedLogSummary,
            Keys.includeCrashReportExcerpt,
            Keys.includeRelatedConfigSnapshots
        ].forEach(defaults.removeObject(forKey:))
    }

    private func sanitized(_ value: String?) -> String {
        sanitizer.sanitize(text: value) ?? ""
    }

    private func loadSanitizedValue(forKey key: String) -> String {
        let storedValue = defaults.string(forKey: key) ?? ""
        let safeValue = sanitized(storedValue)
        if safeValue != storedValue {
            defaults.set(safeValue, forKey: key)
        }
        return safeValue
    }
}
