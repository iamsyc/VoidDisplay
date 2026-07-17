import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayObservability

struct DiagnosticsEventsPanel: View {
    let events: [ObservabilityEvent]?

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            Label(String(localized: "Recent Events"), systemImage: "waveform.path.ecg")
                .font(.headline)

            if let events, events.isEmpty == false {
                let renderedEvents = Array(events.suffix(12).reversed())
                ForEach(Array(renderedEvents.enumerated()), id: \.element.id) { index, event in
                    VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                        HStack(spacing: AppUI.Spacing.small) {
                            Text(event.subsystem.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DiagnosticsPresentation.color(for: event.severity))
                            Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Text(event.message)
                            .font(.footnote)
                            .textSelection(.enabled)
                        if event.metadata.isEmpty == false {
                            DisclosureGroup(String(localized: "Details")) {
                                Text(
                                    verbatim: event.metadata
                                        .sorted { $0.key < $1.key }
                                        .map { "\($0.key)=\($0.value)" }
                                        .joined(separator: "\n")
                                )
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, AppUI.Spacing.xSmall)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    if index < renderedEvents.count - 1 {
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
        .accessibilityIdentifier("diagnostics_recent_events")
    }
}
