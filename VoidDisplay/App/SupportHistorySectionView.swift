import SwiftUI

struct SupportHistorySectionView: View {
    let records: [SupportExportRecord]
    let onCopySummary: (UUID) -> Void
    let onRevealBundle: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Previous Support Packages"))
                .font(.headline)
                .accessibilityIdentifier("support_center_history_section")

            if records.isEmpty {
                Text(String(localized: "No recent support records."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(records.prefix(10).enumerated()), id: \.element.id) { index, record in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(record.displayInfo.summaryText)
                            .font(.subheadline.weight(.medium))

                        Text(String(localized: record.issueType.presentation.titleKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if record.draftPreview.isEmpty == false {
                            Text(record.draftPreview)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        HStack(spacing: 10) {
                            Button(String(localized: "Copy Submission Summary")) {
                                onCopySummary(record.id)
                            }
                            .appActionButtonStyle(variant: .default)
                            .accessibilityIdentifier("support_history_copy_summary_button_\(index)")

                            Button(String(localized: "Reveal Bundle")) {
                                onRevealBundle(record.id)
                            }
                            .appActionButtonStyle(variant: .default)
                            .accessibilityIdentifier("support_history_reveal_bundle_button_\(index)")
                        }
                    }

                    if index < min(records.count, 10) - 1 {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appPanelStyle()
    }
}
