import AppKit
import SwiftUI

struct SupportCenterView: View {
    private let observability: ObservabilityCenter
    private let feedbackController: AppSettingsFeedbackController?

    @State private var snapshot: ObservabilityDiagnosticsSnapshot?
    @State private var dataDirectoryDisplayPath: String?
    @State private var isRefreshing = false

    init(
        observability: ObservabilityCenter,
        feedbackController: AppSettingsFeedbackController? = nil
    ) {
        self.observability = observability
        self.feedbackController = feedbackController
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppUI.Spacing.medium + 2) {
                if let feedbackController {
                    SupportBundleDraftSectionView(
                        controller: feedbackController,
                        onExport: { Task { await exportSupportBundle() } },
                        onCopySummary: { Task { await copySummary() } },
                        onReveal: { Task { await revealLatestBundle() } }
                    )
                }
                userSummaryPanel
                technicalDetailsPanel
                technicalSummaryPanels
                issuesPanel
                eventsPanel
            }
            .appListContentInsets()
        }
        .task {
            if let feedbackController {
                await feedbackController.prepare(observability: observability)
            }
            dataDirectoryDisplayPath = await observability.dataDirectoryDisplayPath()
            if snapshot == nil {
                await reload(refresh: true)
            }
        }
    }

    private var userSummaryPanel: some View {
        summaryPanel(
            title: String(localized: "Status"),
            rows: [
                (
                    String(localized: "Current Status"),
                    snapshot.map { currentStatusLabel(for: $0) } ?? String(localized: "Looks Good")
                ),
                (String(localized: "Recent Issue Count"), "\(snapshot?.health.recentIssueCount ?? 0)"),
                (String(localized: "Recent Event Count"), "\(snapshot?.health.recentEventCount ?? 0)")
            ],
            accessibilityIdentifier: "support_center_overview_panel"
        )
    }

    private var technicalDetailsPanel: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            Text(String(localized: "Technical Details"))
                .font(.headline)
                .accessibilityIdentifier("support_center_technical_details")

            HStack(spacing: AppUI.Spacing.medium) {
                Button(String(localized: "Refresh")) {
                    Task { await reload(refresh: true) }
                }
                .appActionButtonStyle(variant: .default)
                .disabled(isRefreshing)
                .accessibilityIdentifier("support_center_refresh_button")

                Button(String(localized: "Open Data Directory")) {
                    Task { await openDataDirectory() }
                }
                .appActionButtonStyle(variant: .default)
                .disabled(dataDirectoryDisplayPath == nil)
                .accessibilityIdentifier("support_center_open_data_directory_button")
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                metadataRow(
                    title: String(localized: "Refresh Reason"),
                    value: snapshot?.state.refreshReason.rawValue ?? "-"
                )
                metadataRow(
                    title: String(localized: "Section Count"),
                    value: "\(snapshot?.state.sections.count ?? 0)"
                )
                metadataRow(
                    title: String(localized: "Data Directory"),
                    value: dataDirectoryDisplayPath ?? "-"
                )
            }
            .font(.footnote)
        }
        .padding()
        .appPanelStyle()
    }

    private var technicalSummaryPanels: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220), spacing: AppUI.Spacing.medium)],
            spacing: AppUI.Spacing.medium
        ) {
            if let capture = decodeSection("capture", as: CaptureSnapshotProvider.Snapshot.self),
               let sharing = decodeSection("sharing", as: SharingSnapshotProvider.Snapshot.self),
               let virtualDisplay = decodeSection("virtualDisplay", as: VirtualDisplaySnapshotProvider.Snapshot.self) {
                summaryPanel(
                    title: String(localized: "Runtime"),
                    rows: [
                        (String(localized: "Capture Sessions"), "\(capture.sessions.count)"),
                        (String(localized: "Shared Displays"), "\(sharing.activeSharingDisplayIDs.count)"),
                        (String(localized: "Configs"), "\(virtualDisplay.configs.count)"),
                        (String(localized: "Running"), "\(virtualDisplay.runningConfigIDs.count)")
                    ]
                )
            }

            if let system = decodeSection("system", as: SystemSnapshotProvider.Snapshot.self),
               let persistence = decodeSection("persistence", as: PersistenceSnapshotProvider.Snapshot.self) {
                summaryPanel(
                    title: String(localized: "Environment"),
                    rows: [
                        (String(localized: "Locale"), system.localeIdentifier),
                        (String(localized: "Time Zone"), system.timeZoneIdentifier),
                        (String(localized: "Mode"), persistence.mode),
                        (String(localized: "Bundle ID"), persistence.bundleIdentifier)
                    ]
                )
            }
        }
    }

    private var issuesPanel: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            Text(String(localized: "Recent Issues"))
                .font(.headline)

            if let issues = snapshot?.issues, !issues.isEmpty {
                ForEach(Array(issues.prefix(8).enumerated()), id: \.element.id) { index, issue in
                    VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                        Text(issue.subsystem.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(issue.message)
                            .font(.footnote)
                            .textSelection(.enabled)
                        Text(issue.lastSeenAt.formatted(date: .abbreviated, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if index < min(issues.count, 8) - 1 {
                        Divider()
                    }
                }
            } else {
                Text(String(localized: "No recent issues."))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .appPanelStyle()
        .accessibilityIdentifier("support_center_recent_issues")
    }

    private var eventsPanel: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            Text(String(localized: "Recent Events"))
                .font(.headline)

            if let events = snapshot?.events, !events.isEmpty {
                let renderedEvents = Array(events.suffix(12).reversed())
                ForEach(Array(renderedEvents.enumerated()), id: \.element.id) { index, event in
                    VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                        HStack(spacing: AppUI.Spacing.small) {
                            Text(event.subsystem.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(color(for: event.severity))
                            Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Text(event.message)
                            .font(.footnote)
                            .textSelection(.enabled)
                        if !event.metadata.isEmpty {
                            Text(
                                verbatim: event.metadata
                                    .sorted { $0.key < $1.key }
                                    .map { "\($0.key)=\($0.value)" }
                                    .joined(separator: "\n")
                            )
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        }
                    }

                    if index < renderedEvents.count - 1 {
                        Divider()
                    }
                }
            } else {
                Text(String(localized: "No recent events."))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .appPanelStyle()
        .accessibilityIdentifier("support_center_recent_events")
    }

    private func summaryPanel(
        title: String,
        rows: [(String, String)],
        accessibilityIdentifier: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
            Text(title)
                .font(.headline)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                metadataRow(title: row.0, value: row.1)
            }
        }
        .padding()
        .appPanelStyle()
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }

    private func metadataRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppUI.Spacing.small) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: AppUI.Spacing.medium)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func currentStatusLabel(for snapshot: ObservabilityDiagnosticsSnapshot) -> String {
        if snapshot.health.recentIssueCount > 0 ||
            (snapshot.health.highestSeverity ?? .debug) >= .warning {
            return String(localized: "Attention Needed")
        }
        return String(localized: "Looks Good")
    }

    private func color(for severity: ObservabilitySeverity) -> Color {
        switch severity {
        case .debug:
            .secondary
        case .info, .notice:
            .blue
        case .warning:
            .orange
        case .error, .critical:
            .red
        }
    }

    private func reload(refresh: Bool) async {
        if refresh {
            isRefreshing = true
            await observability.refreshSnapshot(reason: .manualDiagnosticsRefresh)
            isRefreshing = false
        }
        snapshot = await observability.diagnosticsSnapshot()
        dataDirectoryDisplayPath = await observability.dataDirectoryDisplayPath()
    }

    private func copySummary() async {
        guard let feedbackController else { return }
        await feedbackController.copySummary()
    }

    private func openDataDirectory() async {
        guard let url = await observability.dataDirectoryURL() else { return }
        NSWorkspace.shared.open(url)
    }

    private func exportSupportBundle() async {
        guard let feedbackController else { return }
        await feedbackController.exportSupportBundle()
        snapshot = await observability.diagnosticsSnapshot()
    }

    private func revealLatestBundle() async {
        guard let feedbackController else { return }
        feedbackController.revealLastBundle()
    }

    private func decodeSection<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let section = snapshot?.state.sections[key] else { return nil }
        return try? section.decode(type)
    }
}
