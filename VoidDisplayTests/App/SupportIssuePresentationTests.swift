import Foundation
import Testing
@testable import VoidDisplay

struct SupportIssuePresentationTests {
    @Test func issuePresentationProvidesExpectedLocalizedKeys() {
        #expect(SupportIssueType.blackScreen.presentation.titleKey == "Black Screen")
        #expect(SupportIssueType.cannotShare.presentation.titleKey == "Cannot Share")
        #expect(SupportIssueType.virtualDisplayFailure.presentation.titleKey == "Virtual Display Failure")
        #expect(SupportIssueType.performanceIssue.presentation.titleKey == "Performance Issue")
        #expect(SupportIssueType.other.presentation.titleKey == "Other")
        #expect(String(localized: SupportIssueType.blackScreen.presentation.recommendedDiagnosticsKey).isEmpty == false)
        #expect(SupportIssueType.blackScreen.presentation.recommendedConsent.includeUnifiedLogSummary)
        #expect(SupportIssueType.blackScreen.presentation.recommendedConsent.includeCrashReportExcerpt)
        #expect(SupportIssueType.virtualDisplayFailure.presentation.recommendedConsent.includeRelatedConfigSnapshots)
    }

    @Test func historyCopyTextStartsWithIssueTypeAndBundleName() {
        let record = SupportExportRecord(
            exportedAt: Date(timeIntervalSince1970: 1_713_614_400),
            issueType: .performanceIssue,
            bundleFileName: "support-bundle.zip",
            sanitizedBundlePath: "~/Library/Application Support/VoidDisplay/support-bundle.zip",
            draftPreview: "What happened:\nFrames drop"
        )

        #expect(
            record.historyCopyText.contains(
                String(localized: SupportIssueType.performanceIssue.presentation.summaryPrefixKey)
            )
        )
        #expect(
            record.historyCopyText.contains(
                "\(String(localized: "Support Package")): support-bundle.zip"
            )
        )
        #expect(record.historyCopyText.contains("What happened:"))
    }
}
