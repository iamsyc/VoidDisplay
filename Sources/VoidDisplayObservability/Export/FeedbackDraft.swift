import VoidDisplayFoundation
import Foundation
package nonisolated struct FeedbackDraft: Codable, Equatable, Sendable {
    package var issueType: SupportIssueType
    package var happened: String
    package var reproductionSteps: String
    package var expectedResult: String

    package init(
        issueType: SupportIssueType = .other,
        happened: String = "",
        reproductionSteps: String = "",
        expectedResult: String = ""
    ) {
        self.issueType = issueType
        self.happened = happened
        self.reproductionSteps = reproductionSteps
        self.expectedResult = expectedResult
    }

    package var isEmpty: Bool {
        trimmed(happened).isEmpty &&
            trimmed(reproductionSteps).isEmpty &&
            trimmed(expectedResult).isEmpty
    }

    package func trimmedPayload() -> Self {
        Self(
            issueType: issueType,
            happened: trimmed(happened),
            reproductionSteps: trimmed(reproductionSteps),
            expectedResult: trimmed(expectedResult)
        )
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
