import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayObservability

struct DiagnosticsOverviewPanel: View {
    let snapshot: ObservabilityDiagnosticsSnapshot?
    let dataDirectoryDisplayPath: String?
    let latestBundleFullPath: String?
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onOpenDataDirectory: () -> Void

    var body: some View {
        let presentation = DiagnosticsPresentation(snapshot: snapshot)

        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppUI.Spacing.medium) {
                    DiagnosticsStatusHeading(recommendation: presentation.statusRecommendation)
                    Spacer(minLength: AppUI.Spacing.medium)
                    headerActions
                }

                VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
                    DiagnosticsStatusHeading(recommendation: presentation.statusRecommendation)
                    headerActions
                }
            }

            DiagnosticsStatusCallout(
                title: presentation.statusTitle,
                detail: presentation.statusRecommendation,
                systemImage: presentation.statusSystemImage,
                tint: presentation.statusTint
            )

            VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                DiagnosticsReadableRow(
                    title: String(localized: "Runtime Snapshot"),
                    value: snapshot == nil ? "-" : presentation.runtimeSummary.statusCode,
                    isMonospaced: snapshot != nil
                )
                DiagnosticsReadableRow(
                    title: String(localized: "Section Count"),
                    value: presentation.collectedAreasLabel
                )
                DiagnosticsReadableRow(
                    title: String(localized: "Data Directory"),
                    value: dataDirectoryDisplayPath ?? "-",
                    isMonospaced: dataDirectoryDisplayPath != nil
                )
                DiagnosticsReadableRow(
                    title: String(localized: "Latest Support Package"),
                    value: latestBundleFullPath ?? "-",
                    isMonospaced: latestBundleFullPath != nil,
                    accessibilityIdentifier: latestBundleFullPath == nil ? nil : "support_bundle_latest_full_path"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appPanelStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diagnostics_overview_panel")
    }

    private var headerActions: some View {
        DiagnosticsHeaderActions(
            isRefreshing: isRefreshing,
            canOpenDataDirectory: dataDirectoryDisplayPath != nil,
            onRefresh: onRefresh,
            onOpenDataDirectory: onOpenDataDirectory
        )
    }
}
