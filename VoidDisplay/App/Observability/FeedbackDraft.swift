import Foundation

nonisolated struct FeedbackDraft: Codable, Equatable, Sendable {
    var issueType: SupportIssueType
    var happened: String
    var reproductionSteps: String
    var expectedResult: String

    init(
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

    var isEmpty: Bool {
        trimmed(happened).isEmpty &&
            trimmed(reproductionSteps).isEmpty &&
            trimmed(expectedResult).isEmpty
    }

    func trimmedPayload() -> Self {
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
