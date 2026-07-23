import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayObservability

struct DiagnosticsEventsPanel: View {
    let events: [ObservabilityEvent]?

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            Label(String(localized: "Recent Events"), systemImage: "waveform.path.ecg")
                .font(.headline)
                .accessibilityIdentifier("diagnostics_recent_events")

            if let events, events.isEmpty == false {
                let groups = DiagnosticsEvidencePresentation.eventGroups(from: events)
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    DiagnosticsEventGroupRow(group: group)

                    if index < groups.count - 1 {
                        Divider()
                    }
                }
            } else {
                Label(String(localized: "No recent events."), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appPanelStyle()
    }
}

private struct DiagnosticsEventGroupRow: View {
    let group: DiagnosticsEvidencePresentation.EventGroup

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
            Text(group.title)
                .font(.footnote.weight(.medium))
            HStack(spacing: AppUI.Spacing.small) {
                DiagnosticsSeverityTag(severity: group.severity)
                DiagnosticsTag(title: group.domainTitle)
                Text(DiagnosticsEvidencePresentation.timeText(group.latestTimestamp))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                if group.occurrenceCount > 1 {
                    Text(
                        String(
                            format: String(localized: "%lld events"),
                            locale: .current,
                            group.occurrenceCount
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            }

            Button {
                withAnimation {
                    isExpanded.toggle()
                }
            } label: {
                Label(
                    String(localized: "Details"),
                    systemImage: isExpanded ? "chevron.down" : "chevron.right"
                )
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(
                group.transactionID == nil
                    ? "diagnostics_event_details"
                    : "diagnostics_transaction_details"
            )
            .accessibilityValue(
                isExpanded
                    ? String(localized: "Expanded")
                    : String(localized: "Collapsed")
            )

            if isExpanded {
                if let transactionID = group.transactionID {
                    DiagnosticsTransactionTimeline(
                        transactionID: transactionID,
                        evidence: group.evidence
                    )
                } else {
                    DiagnosticsRawEvidenceDetails(evidence: group.evidence)
                }
            }
        }
    }
}
