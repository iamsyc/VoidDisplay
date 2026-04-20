import Foundation

nonisolated struct FeedbackConsent: Codable, Equatable, Sendable {
    var includeUnifiedLogSummary: Bool
    var includeCrashReportExcerpt: Bool
    var includeRelatedConfigSnapshots: Bool

    init(
        includeUnifiedLogSummary: Bool = false,
        includeCrashReportExcerpt: Bool = false,
        includeRelatedConfigSnapshots: Bool = false
    ) {
        self.includeUnifiedLogSummary = includeUnifiedLogSummary
        self.includeCrashReportExcerpt = includeCrashReportExcerpt
        self.includeRelatedConfigSnapshots = includeRelatedConfigSnapshots
    }

    var hasEnhancedCollection: Bool {
        includeUnifiedLogSummary ||
            includeCrashReportExcerpt ||
            includeRelatedConfigSnapshots
    }
}
