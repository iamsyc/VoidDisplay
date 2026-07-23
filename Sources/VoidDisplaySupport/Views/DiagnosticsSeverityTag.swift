import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayObservability

struct DiagnosticsSeverityTag: View {
    let severity: ObservabilitySeverity

    var body: some View {
        let tint = DiagnosticsPresentation.color(for: severity)
        Label(
            DiagnosticsPresentation.title(for: severity),
            systemImage: DiagnosticsPresentation.systemImage(for: severity)
        )
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, AppUI.Spacing.small - 1)
        .padding(.vertical, AppUI.Spacing.xSmall)
        .background(tint.opacity(0.12), in: Capsule())
        .foregroundStyle(tint)
        .accessibilityIdentifier("diagnostics_event_severity_\(severity.rawValue)")
    }
}
