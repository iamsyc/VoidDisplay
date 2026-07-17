import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayObservability

struct DiagnosticsTechnicalInformationSection: View {
    @Binding var isExpanded: Bool
    @Binding var isAdvancedSnapshotExpanded: Bool

    let snapshot: ObservabilityDiagnosticsSnapshot?
    let dataDirectoryDisplayPath: String?
    let latestBundleFullPath: String?
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onOpenDataDirectory: () -> Void
    let onExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleExpanded) {
                HStack(spacing: AppUI.Spacing.small) {
                    Label(String(localized: "Technical Information"), systemImage: "stethoscope")
                        .font(.headline)
                    Spacer(minLength: AppUI.Spacing.small)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("diagnostics_technical_disclosure")

            if isExpanded {
                VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
                    DiagnosticsOverviewPanel(
                        snapshot: snapshot,
                        dataDirectoryDisplayPath: dataDirectoryDisplayPath,
                        latestBundleFullPath: latestBundleFullPath,
                        isRefreshing: isRefreshing,
                        onRefresh: onRefresh,
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleExpanded() {
        isExpanded.toggle()
        if isExpanded {
            onExpand()
        }
    }
}
