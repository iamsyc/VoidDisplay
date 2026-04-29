import Foundation
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import SwiftUI
package struct SettingsSupportSectionView: View {
    @Bindable var controller: AppSettingsFeedbackController
    package let onOpenSupportCenter: () -> Void

    package init(
        controller: AppSettingsFeedbackController,
        onOpenSupportCenter: @escaping () -> Void
    ) {
        _controller = Bindable(controller)
        self.onOpenSupportCenter = onOpenSupportCenter
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Support Center"))
                .font(.headline)
                .accessibilityIdentifier("settings_support_section")

            Text(String(localized: "Describe the issue, add diagnostics if needed, then export a support package."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings_support_intro_text")

            Button(String(localized: "Open Support Center"), action: onOpenSupportCenter)
                .appActionButtonStyle(variant: .primary)
                .accessibilityIdentifier("settings_open_support_center_button")

            if let latestRecord = controller.latestExportRecord {
                latestSupportSummary(
                    issueType: String(localized: latestRecord.issueType.presentation.titleKey),
                    summary: latestRecord.displayInfo.summaryText
                )
            } else if let latestBundle = controller.lastBundleDisplayInfo {
                latestSupportSummary(issueType: nil, summary: latestBundle.summaryText)
            }
        }
    }

    private func latestSupportSummary(issueType: String?, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Latest Support Package"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if let issueType, issueType.isEmpty == false {
                Text(issueType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings_support_latest_issue_type")
            }

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("settings_support_latest_bundle_summary")
        }
    }
}
