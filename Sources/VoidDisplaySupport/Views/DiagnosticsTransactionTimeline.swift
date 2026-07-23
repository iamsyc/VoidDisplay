import SwiftUI
import VoidDisplayDesignSystem

struct DiagnosticsTransactionTimeline: View {
    let transactionID: String
    let evidence: [DiagnosticsEvidencePresentation.Evidence]

    var body: some View {
        let phases = DiagnosticsEvidencePresentation.transactionPhases(from: evidence)
        VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
            DiagnosticsEvidenceField(
                title: String(localized: "Transaction ID"),
                value: transactionID,
                accessibilityIdentifier: "diagnostics_transaction_id"
            )

            ForEach(Array(phases.enumerated()), id: \.element.id) { index, phase in
                HStack(alignment: .top, spacing: AppUI.Spacing.small) {
                    VStack(spacing: 2) {
                        Circle()
                            .fill(.secondary)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        if index < phases.count - 1 {
                            Rectangle()
                                .fill(.quaternary)
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: 12)

                    VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                        Text(phase.title)
                            .font(.footnote.weight(.medium))
                            .accessibilityIdentifier("diagnostics_transaction_phase")
                        Text(DiagnosticsEvidencePresentation.timestampText(phase.timestamp))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .accessibilityIdentifier("diagnostics_event_timestamp_milliseconds")
                        DiagnosticsEvidenceField(
                            title: String(localized: "Event ID"),
                            value: phase.id.uuidString,
                            accessibilityIdentifier: "diagnostics_event_id"
                        )
                        DiagnosticsEvidenceField(
                            title: String(localized: "Operation"),
                            value: phase.operation,
                            accessibilityIdentifier: "diagnostics_event_operation"
                        )
                        DiagnosticsEvidenceField(
                            title: String(localized: "Message"),
                            value: phase.message,
                            accessibilityIdentifier: "diagnostics_event_message"
                        )
                        if phase.metadata.isEmpty == false {
                            DiagnosticsEvidenceField(
                                title: String(localized: "Metadata"),
                                value: phase.metadata
                                    .sorted { $0.key < $1.key }
                                    .map { "\($0.key)=\($0.value)" }
                                    .joined(separator: "\n"),
                                accessibilityIdentifier: "diagnostics_event_metadata"
                            )
                        }
                    }
                    .padding(.bottom, index < phases.count - 1 ? AppUI.Spacing.small : 0)
                }
            }
        }
        .padding(.top, AppUI.Spacing.xSmall)
    }
}
