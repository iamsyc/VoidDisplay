import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayObservability

struct DiagnosticsOverviewPanel: View {
    let snapshot: ObservabilityDiagnosticsSnapshot?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        let presentation = DiagnosticsPresentation(snapshot: snapshot)

        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                    healthHeading
                    Spacer(minLength: AppUI.Spacing.medium)
                    refreshButton
                }

                VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
                    healthHeading
                    refreshButton
                }
            }

            DiagnosticsStatusCallout(
                title: presentation.statusTitle,
                detail: presentation.statusRecommendation,
                systemImage: presentation.statusSystemImage,
                tint: presentation.statusTint
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appPanelStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diagnostics_health_summary_panel")
    }

    private var healthHeading: some View {
        Label(String(localized: "App Health"), systemImage: "heart.text.square")
            .font(.headline)
    }

    private var refreshButton: some View {
        Button(String(localized: "Refresh"), systemImage: "arrow.clockwise", action: onRefresh)
            .appActionButtonStyle(variant: .default)
            .disabled(isRefreshing)
            .accessibilityIdentifier("diagnostics_refresh_button")
    }
}
