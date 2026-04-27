import Foundation

nonisolated struct SupportIssuePresentation: Equatable, Sendable {
    let titleKey: LocalizedStringResource
    let descriptionKey: LocalizedStringResource
    let summaryPrefixKey: LocalizedStringResource
    let recommendedDiagnosticsKey: LocalizedStringResource
    let symbolName: String
    let recommendedConsent: FeedbackConsent
}

extension SupportIssueType {
    nonisolated var presentation: SupportIssuePresentation {
        switch self {
        case .blackScreen:
            .init(
                titleKey: "Black Screen",
                descriptionKey: "The app opens or starts sharing, but the content stays black.",
                summaryPrefixKey: "Issue Type: Black Screen",
                recommendedDiagnosticsKey: "Recommended when the screen stays black or the image never appears.",
                symbolName: "display.slash",
                recommendedConsent: FeedbackConsent(
                    includeUnifiedLogSummary: true,
                    includeCrashReportExcerpt: true
                )
            )
        case .cannotShare:
            .init(
                titleKey: "Cannot Share",
                descriptionKey: "Sharing cannot start, disconnects quickly, or the remote side cannot connect.",
                summaryPrefixKey: "Issue Type: Cannot Share",
                recommendedDiagnosticsKey: "Recommended when screen sharing fails to start, stops quickly, or the remote side cannot connect.",
                symbolName: "antenna.radiowaves.left.and.right.slash",
                recommendedConsent: FeedbackConsent(
                    includeUnifiedLogSummary: true,
                    includeRelatedConfigSnapshots: true
                )
            )
        case .virtualDisplayFailure:
            .init(
                titleKey: "Virtual Display Failure",
                descriptionKey: "Virtual displays cannot be created, restored, enabled, or kept in sync.",
                summaryPrefixKey: "Issue Type: Virtual Display Failure",
                recommendedDiagnosticsKey: "Recommended when virtual displays fail to create, restore, or stay available.",
                symbolName: "display.2.slash",
                recommendedConsent: FeedbackConsent(
                    includeUnifiedLogSummary: true,
                    includeRelatedConfigSnapshots: true
                )
            )
        case .performanceIssue:
            .init(
                titleKey: "Performance Issue",
                descriptionKey: "The app is slow, drops frames, uses too many resources, or responds late.",
                summaryPrefixKey: "Issue Type: Performance Issue",
                recommendedDiagnosticsKey: "Recommended when the app stutters, drops frames, or uses too many resources.",
                symbolName: "speedometer",
                recommendedConsent: FeedbackConsent(includeUnifiedLogSummary: true)
            )
        case .other:
            .init(
                titleKey: "Other",
                descriptionKey: "Use this when the issue does not fit the common categories above.",
                summaryPrefixKey: "Issue Type: Other",
                recommendedDiagnosticsKey: "Recommended when the issue is hard to classify and needs more context.",
                symbolName: "questionmark.circle",
                recommendedConsent: FeedbackConsent(includeUnifiedLogSummary: true)
            )
        }
    }
}
