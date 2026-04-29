import VoidDisplayFoundation
import Foundation
package nonisolated struct FeedbackConsent: Codable, Equatable, Sendable {
    package var includeUnifiedLogSummary: Bool
    package var includeCrashReportExcerpt: Bool
    package var includeRelatedConfigSnapshots: Bool

    package init(
        includeUnifiedLogSummary: Bool = false,
        includeCrashReportExcerpt: Bool = false,
        includeRelatedConfigSnapshots: Bool = false
    ) {
        self.includeUnifiedLogSummary = includeUnifiedLogSummary
        self.includeCrashReportExcerpt = includeCrashReportExcerpt
        self.includeRelatedConfigSnapshots = includeRelatedConfigSnapshots
    }

    package var hasEnhancedCollection: Bool {
        includeUnifiedLogSummary ||
            includeCrashReportExcerpt ||
            includeRelatedConfigSnapshots
    }
}
