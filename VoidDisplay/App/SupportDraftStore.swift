import Foundation

nonisolated struct SupportDraftStore {
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

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> SupportDraftSnapshot {
        let rawIssueType = defaults.string(forKey: Keys.issueType)
        return SupportDraftSnapshot(
            issueType: rawIssueType.flatMap(SupportIssueType.init(rawValue:)) ?? .other,
            happened: defaults.string(forKey: Keys.happened) ?? "",
            reproductionSteps: defaults.string(forKey: Keys.reproductionSteps) ?? "",
            expectedResult: defaults.string(forKey: Keys.expectedResult) ?? "",
            includeUnifiedLogSummary: defaults.bool(forKey: Keys.includeUnifiedLogSummary),
            includeCrashReportExcerpt: defaults.bool(forKey: Keys.includeCrashReportExcerpt),
            includeRelatedConfigSnapshots: defaults.bool(forKey: Keys.includeRelatedConfigSnapshots)
        )
    }

    func save(_ snapshot: SupportDraftSnapshot) {
        defaults.set(snapshot.issueType.rawValue, forKey: Keys.issueType)
        defaults.set(snapshot.happened, forKey: Keys.happened)
        defaults.set(snapshot.reproductionSteps, forKey: Keys.reproductionSteps)
        defaults.set(snapshot.expectedResult, forKey: Keys.expectedResult)
        defaults.set(snapshot.includeUnifiedLogSummary, forKey: Keys.includeUnifiedLogSummary)
        defaults.set(snapshot.includeCrashReportExcerpt, forKey: Keys.includeCrashReportExcerpt)
        defaults.set(snapshot.includeRelatedConfigSnapshots, forKey: Keys.includeRelatedConfigSnapshots)
    }

    func clear() {
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
}
