import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayObservability

struct DiagnosticsAdvancedSnapshotDetails: View {
    let snapshot: ObservabilityDiagnosticsSnapshot?

    var body: some View {
        let runtimeSummary = DiagnosticsPresentation(snapshot: snapshot).runtimeSummary
        let system = decodeSection("system", as: SystemSnapshotProvider.Snapshot.self)
        let persistence = decodeSection("persistence", as: PersistenceSnapshotProvider.Snapshot.self)

        VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
            DiagnosticsReadableRow(
                title: String(localized: "Runtime Snapshot"),
                value: runtimeSummary.statusCode,
                isMonospaced: true
            )
            DiagnosticsReadableRow(
                title: String(localized: "Schema Version"),
                value: runtimeSummary.schemaVersion.map(String.init) ?? "-"
            )
            DiagnosticsReadableRow(
                title: String(localized: "Active Viewer Count"),
                value: "\(runtimeSummary.activeViewerCount)"
            )
            DiagnosticsReadableRow(
                title: String(localized: "Aggregated Demand Count"),
                value: "\(runtimeSummary.aggregatedDemandCount)"
            )
            DiagnosticsReadableRow(
                title: String(localized: "Refresh Reason"),
                value: snapshot?.state.refreshReason.rawValue ?? "-",
                isMonospaced: true
            )

            if let system, let persistence {
                Divider()
                DiagnosticsReadableRow(title: String(localized: "Locale"), value: system.localeIdentifier)
                DiagnosticsReadableRow(title: String(localized: "Time Zone"), value: system.timeZoneIdentifier)
                DiagnosticsReadableRow(title: String(localized: "Mode"), value: persistence.mode)
                DiagnosticsReadableRow(
                    title: String(localized: "Bundle ID"),
                    value: persistence.bundleIdentifier,
                    isMonospaced: true
                )
            }
        }
    }

    private func decodeSection<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let section = snapshot?.state.sections[key] else { return nil }
        return try? section.decode(type)
    }
}
