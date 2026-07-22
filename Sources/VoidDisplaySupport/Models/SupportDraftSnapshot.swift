import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
package nonisolated struct SupportDraftSnapshot: Codable, Equatable, Sendable {
    package var issueType: SupportIssueType
    package var happened: String
    package var reproductionSteps: String
    package var expectedResult: String
    package var includeUnifiedLogSummary: Bool
    package var includeCrashReportExcerpt: Bool
    package var includeRelatedConfigSnapshots: Bool

    package init(
        issueType: SupportIssueType = .other,
        happened: String = "",
        reproductionSteps: String = "",
        expectedResult: String = "",
        includeUnifiedLogSummary: Bool = true,
        includeCrashReportExcerpt: Bool = true,
        includeRelatedConfigSnapshots: Bool = true
    ) {
        self.issueType = issueType
        self.happened = happened
        self.reproductionSteps = reproductionSteps
        self.expectedResult = expectedResult
        self.includeUnifiedLogSummary = includeUnifiedLogSummary
        self.includeCrashReportExcerpt = includeCrashReportExcerpt
        self.includeRelatedConfigSnapshots = includeRelatedConfigSnapshots
    }

    package var feedbackDraft: FeedbackDraft {
        FeedbackDraft(
            issueType: issueType,
            happened: happened,
            reproductionSteps: reproductionSteps,
            expectedResult: expectedResult
        )
    }

    package var feedbackConsent: FeedbackConsent {
        FeedbackConsent(
            includeUnifiedLogSummary: includeUnifiedLogSummary,
            includeCrashReportExcerpt: includeCrashReportExcerpt,
            includeRelatedConfigSnapshots: includeRelatedConfigSnapshots
        )
    }

    package var isEmpty: Bool {
        feedbackDraft.isEmpty && feedbackConsent.hasEnhancedCollection == false
    }
}
