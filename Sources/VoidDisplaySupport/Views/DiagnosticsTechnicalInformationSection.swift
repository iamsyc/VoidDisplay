import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayObservability

struct DiagnosticsTechnicalInformationSection: View {
    @Binding var isExpanded: Bool
    @Binding var isAdvancedSnapshotExpanded: Bool

    let snapshot: ObservabilityDiagnosticsSnapshot?
    let dataDirectoryDisplayPath: String?
    let latestBundleFullPath: String?
    let onOpenDataDirectory: () -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
                DiagnosticsDataPanel(
                    snapshot: snapshot,
                    dataDirectoryDisplayPath: dataDirectoryDisplayPath,
                    latestBundleFullPath: latestBundleFullPath,
                    onOpenDataDirectory: onOpenDataDirectory
                )
                DiagnosticsDisplaySystemPanel(snapshot: snapshot)
                DiagnosticsAdvancedSnapshotPanel(
                    isExpanded: $isAdvancedSnapshotExpanded,
                    snapshot: snapshot
                )
                DiagnosticsIssuesPanel(issues: snapshot?.issues)
                DiagnosticsEventsPanel(events: snapshot?.events)
            }
            .padding(.top, AppUI.Spacing.medium)
        } label: {
            Label(String(localized: "Technical Information"), systemImage: "stethoscope")
                .font(.headline)
                .accessibilityIdentifier("diagnostics_technical_disclosure")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}
