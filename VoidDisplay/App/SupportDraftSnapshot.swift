import Foundation

nonisolated struct SupportDraftSnapshot: Codable, Equatable, Sendable {
    var issueType: SupportIssueType
    var happened: String
    var reproductionSteps: String
    var expectedResult: String
    var includeUnifiedLogSummary: Bool
    var includeCrashReportExcerpt: Bool
    var includeRelatedConfigSnapshots: Bool

    init(
        issueType: SupportIssueType = .other,
        happened: String = "",
        reproductionSteps: String = "",
        expectedResult: String = "",
        includeUnifiedLogSummary: Bool = false,
        includeCrashReportExcerpt: Bool = false,
        includeRelatedConfigSnapshots: Bool = false
    ) {
        self.issueType = issueType
        self.happened = happened
        self.reproductionSteps = reproductionSteps
        self.expectedResult = expectedResult
        self.includeUnifiedLogSummary = includeUnifiedLogSummary
        self.includeCrashReportExcerpt = includeCrashReportExcerpt
        self.includeRelatedConfigSnapshots = includeRelatedConfigSnapshots
    }

    var feedbackDraft: FeedbackDraft {
        FeedbackDraft(
            issueType: issueType,
            happened: happened,
            reproductionSteps: reproductionSteps,
            expectedResult: expectedResult
        )
    }

    var feedbackConsent: FeedbackConsent {
        FeedbackConsent(
            includeUnifiedLogSummary: includeUnifiedLogSummary,
            includeCrashReportExcerpt: includeCrashReportExcerpt,
            includeRelatedConfigSnapshots: includeRelatedConfigSnapshots
        )
    }

    var isEmpty: Bool {
        feedbackDraft.isEmpty && feedbackConsent.hasEnhancedCollection == false
    }
}
