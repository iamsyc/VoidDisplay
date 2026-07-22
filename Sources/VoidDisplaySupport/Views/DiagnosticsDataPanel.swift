import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayObservability

struct DiagnosticsDataPanel: View {
    let snapshot: ObservabilityDiagnosticsSnapshot?
    let dataDirectoryDisplayPath: String?
    let latestBundleFullPath: String?
    let onOpenDataDirectory: () -> Void

    var body: some View {
        let presentation = DiagnosticsPresentation(snapshot: snapshot)

        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                    heading
                    Spacer(minLength: AppUI.Spacing.medium)
                    openDirectoryButton
                }

                VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
                    heading
                    openDirectoryButton
                }
            }

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
        .accessibilityIdentifier("diagnostics_data_panel")
    }

    private var heading: some View {
        Label(String(localized: "Diagnostic Data"), systemImage: "externaldrive")
            .font(.headline)
    }

    private var openDirectoryButton: some View {
        Button(String(localized: "Open Data Directory"), systemImage: "folder", action: onOpenDataDirectory)
            .appActionButtonStyle(variant: .default)
            .disabled(dataDirectoryDisplayPath == nil)
            .accessibilityIdentifier("diagnostics_open_data_directory_button")
    }
}
