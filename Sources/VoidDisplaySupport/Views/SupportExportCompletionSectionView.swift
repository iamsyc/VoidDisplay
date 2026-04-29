import Foundation
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import SwiftUI
package struct SupportExportCompletionSectionView: View {
    package let record: SupportExportRecord
    package let onCopySummary: () -> Void
    package let onRevealBundle: () -> Void
    package let onStartNewFeedback: () -> Void

    package var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Latest Support Package"))
                .font(.headline)
                .accessibilityIdentifier("support_center_completion_section")

            metadataRow(
                title: String(localized: "Issue Type"),
                value: String(localized: record.issueType.presentation.titleKey)
            )
            metadataRow(
                title: String(localized: "Support Package"),
                value: record.displayInfo.summaryText
            )

            Text(String(localized: "Copy the submission summary and send it together with the support package."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("support_center_completion_next_step")

            if record.draftPreview.isEmpty == false {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Summary Preview"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(record.draftPreview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("support_center_completion_summary")
                }
            }

            HStack(spacing: 10) {
                Button(String(localized: "Copy Submission Summary"), action: onCopySummary)
                    .appActionButtonStyle(variant: .default)
                    .accessibilityIdentifier("support_center_copy_summary_button")

                Button(String(localized: "Reveal Bundle"), action: onRevealBundle)
                    .appActionButtonStyle(variant: .default)
                    .accessibilityIdentifier("support_center_reveal_bundle_button")

                Button(String(localized: "New Feedback"), action: onStartNewFeedback)
                    .appActionButtonStyle(variant: .default)
                    .accessibilityIdentifier("support_center_new_feedback_button")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appPanelStyle()
    }

    private func metadataRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote)
                .textSelection(.enabled)
        }
    }
}
