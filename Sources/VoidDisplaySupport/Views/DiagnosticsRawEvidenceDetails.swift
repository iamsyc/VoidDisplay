import SwiftUI
import VoidDisplayDesignSystem

struct DiagnosticsRawEvidenceDetails: View {
    let evidence: [DiagnosticsEvidencePresentation.Evidence]

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
            ForEach(Array(evidence.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                    Text(DiagnosticsEvidencePresentation.timestampText(item.timestamp))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("diagnostics_event_timestamp_milliseconds")

                    DiagnosticsEvidenceField(
                        title: String(localized: "Event ID"),
                        value: item.id.uuidString,
                        accessibilityIdentifier: "diagnostics_event_id"
                    )
                    DiagnosticsEvidenceField(
                        title: String(localized: "Operation"),
                        value: item.operation,
                        accessibilityIdentifier: "diagnostics_event_operation"
                    )
                    DiagnosticsEvidenceField(
                        title: String(localized: "Message"),
                        value: item.message,
                        accessibilityIdentifier: "diagnostics_event_message"
                    )

                    if item.metadata.isEmpty == false {
                        DiagnosticsEvidenceField(
                            title: String(localized: "Metadata"),
                            value: item.metadata
                                .sorted { $0.key < $1.key }
                                .map { "\($0.key)=\($0.value)" }
                                .joined(separator: "\n"),
                            accessibilityIdentifier: "diagnostics_event_metadata"
                        )
                    }
                }

                if index < evidence.count - 1 {
                    Divider()
                }
            }
        }
        .padding(.top, AppUI.Spacing.xSmall)
    }
}
