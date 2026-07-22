import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayObservability

struct DiagnosticsDisplaySystemPanel: View {
    let snapshot: ObservabilityDiagnosticsSnapshot?

    var body: some View {
        let runtimeSummary = DiagnosticsPresentation(snapshot: snapshot).runtimeSummary

        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            Label(String(localized: "Displays"), systemImage: "display.2")
                .font(.headline)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: AppUI.Spacing.small)],
                alignment: .leading,
                spacing: AppUI.Spacing.small
            ) {
                DiagnosticsMetricTile(
                    title: String(localized: "Virtual Displays"),
                    value: "\(runtimeSummary.virtualDisplayCount)",
                    systemImage: "display.2",
                    tint: .blue
                )
                DiagnosticsMetricTile(
                    title: String(localized: "Running Virtual Displays"),
                    value: "\(runtimeSummary.runningVirtualDisplayCount)",
                    systemImage: "checkmark.rectangle.stack",
                    tint: runtimeSummary.runningVirtualDisplayCount > 0 ? .green : .secondary
                )
                DiagnosticsMetricTile(
                    title: String(localized: "Physical Displays"),
                    value: "\(runtimeSummary.physicalDisplayCount)",
                    systemImage: "display",
                    tint: .cyan
                )
                DiagnosticsMetricTile(
                    title: String(localized: "Active Viewers"),
                    value: "\(runtimeSummary.activeViewerCount)",
                    systemImage: "person.2",
                    tint: .green
                )
                DiagnosticsMetricTile(
                    title: String(localized: "Capture States"),
                    value: "\(runtimeSummary.effectiveCaptureIntentCount)",
                    systemImage: "rectangle.on.rectangle",
                    tint: .purple
                )
                DiagnosticsMetricTile(
                    title: String(localized: "Active Transactions"),
                    value: "\(runtimeSummary.activeTransactionCount)",
                    systemImage: "clock",
                    tint: runtimeSummary.activeTransactionCount > 0 ? .orange : .secondary
                )
                DiagnosticsMetricTile(
                    title: String(localized: "Recent Failures"),
                    value: "\(runtimeSummary.recentFailureCount)",
                    systemImage: runtimeSummary.recentFailureCount == 0 ? "checkmark.circle" : "exclamationmark.triangle",
                    tint: runtimeSummary.recentFailureCount == 0 ? .green : .orange
                )
                DiagnosticsMetricTile(
                    title: String(localized: "Latest Failure Code"),
                    value: runtimeSummary.lastFailureCode ?? "-",
                    systemImage: runtimeSummary.lastFailureCode == nil ? "checkmark.circle" : "exclamationmark.triangle",
                    tint: runtimeSummary.lastFailureCode == nil ? .green : .orange
                )
            }

            if let lastFailureCode = runtimeSummary.lastFailureCode {
                DiagnosticsReadableRow(
                    title: String(localized: "Diagnostic Code"),
                    value: lastFailureCode,
                    isMonospaced: true
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appPanelStyle()
        .accessibilityIdentifier("diagnostics_runtime_panel")
    }
}
