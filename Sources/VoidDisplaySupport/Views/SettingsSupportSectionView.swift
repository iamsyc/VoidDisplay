import Foundation
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import SwiftUI
package struct SettingsSupportSectionView: View {
    @Bindable var controller: AppSettingsFeedbackController
    package let onOpenDiagnostics: () -> Void

    package init(
        controller: AppSettingsFeedbackController,
        onOpenDiagnostics: @escaping () -> Void
    ) {
        _controller = Bindable(controller)
        self.onOpenDiagnostics = onOpenDiagnostics
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Diagnostics"))
                .font(.headline)
                .accessibilityIdentifier("settings_diagnostics_section")

            Text(String(localized: "Review app health, add diagnostics if needed, then export a support bundle."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings_diagnostics_intro_text")

            Button(String(localized: "Open Diagnostics"), action: onOpenDiagnostics)
                .appActionButtonStyle(variant: .primary)
                .accessibilityIdentifier("settings_open_diagnostics_button")

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
