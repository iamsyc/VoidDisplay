import Foundation
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import AppKit
import SwiftUI
package struct DiagnosticsView: View {
    private let contentMaxWidth: CGFloat = 840
    private let observability: ObservabilityCenter
    private let feedbackController: AppSettingsFeedbackController?

    @State private var snapshot: ObservabilityDiagnosticsSnapshot?
    @State private var dataDirectoryDisplayPath: String?
    @State private var isRefreshing = false
    @State private var isTechnicalInformationExpanded = false

    package init(
        observability: ObservabilityCenter,
        feedbackController: AppSettingsFeedbackController? = nil
    ) {
        self.observability = observability
        self.feedbackController = feedbackController
    }

    package var body: some View {
        content(feedbackController: feedbackController)
        .task {
            if let feedbackController {
                await feedbackController.prepare(observability: observability)
                if let fixture = UITestRuntime.feedbackFixture {
                    feedbackController.applyFixture(fixture)
                }
                await feedbackController.trackPageOpened()
            }
            dataDirectoryDisplayPath = await observability.dataDirectoryDisplayPath()
            if snapshot == nil {
                await reload(refresh: true)
            }
        }
    }

    @ViewBuilder
    private func content(feedbackController: AppSettingsFeedbackController?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppUI.Spacing.medium + 2) {
                Text(String(localized: "Review app health, add diagnostics if needed, then export a support bundle."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("diagnostics_intro_text")

                if let feedbackController {
                    if let alert = feedbackController.alert {
                        errorBanner(alert)
                    }

                    SupportBundleDraftSectionView(
                        controller: feedbackController,
                        onExport: { Task { await exportSupportBundle() } }
                    )

                    if let completionRecord = feedbackController.completionRecord {
                        SupportExportCompletionSectionView(
                            record: completionRecord,
                            onCopySummary: { Task { await copySummary() } },
                            onRevealBundle: { Task { await revealLatestBundle() } },
                            onStartNewFeedback: { Task { await startNewFeedback() } }
                        )
                    }

                    if historicalRecords(for: feedbackController).isEmpty == false {
                        SupportHistorySectionView(
                            records: historicalRecords(for: feedbackController),
                            onCopySummary: { recordID in
                                Task { await copyHistorySummary(recordID: recordID) }
                            },
                            onRevealBundle: { recordID in
                                Task { await revealHistoryBundle(recordID: recordID) }
                            }
                        )
                    }
                }

                technicalInformationSection
            }
            .appListContentInsets()
            .frame(maxWidth: contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func errorBanner(_ alert: UserFacingAlertState) -> some View {
        HStack(alignment: .top, spacing: AppUI.Spacing.medium) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(alert.title)
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(alert.title)
                .accessibilityValue(alert.title)
                .accessibilityIdentifier("support_bundle_error_title")

                VStack(alignment: .leading, spacing: 0) {
                    Text(alert.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(alert.message)
                .accessibilityValue(alert.message)
                .accessibilityIdentifier("support_bundle_error_message")
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appPanelStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("support_bundle_error_banner")
    }

    private var technicalInformationSection: some View {
        DisclosureGroup(
            isExpanded: $isTechnicalInformationExpanded,
            content: {
                VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
                    userSummaryPanel
                    technicalDetailsPanel
                    technicalSummaryPanels
                    issuesPanel
                    eventsPanel
                }
                .padding(.top, AppUI.Spacing.medium)
            },
            label: {
                Text(String(localized: "Technical Information"))
                    .font(.headline)
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appPanelStyle()
        .accessibilityIdentifier("diagnostics_technical_disclosure")
    }

    private var userSummaryPanel: some View {
        let runtimeSummary = RuntimeDiagnosticsSummary(state: snapshot?.state)
        return summaryPanel(
            title: String(localized: "Status"),
            rows: [
                (
                    String(localized: "Current Status"),
                    snapshot.map { currentStatusLabel(for: $0, runtimeSummary: runtimeSummary) } ??
                        String(localized: "Looks Good")
                ),
                (String(localized: "Runtime Snapshot"), runtimeSummary.statusCode),
                (String(localized: "Recent Issue Count"), "\(snapshot?.health.recentIssueCount ?? 0)"),
                (String(localized: "Recent Event Count"), "\(snapshot?.health.recentEventCount ?? 0)"),
                (String(localized: "Suggested Action"), statusRecommendation())
            ],
            accessibilityIdentifier: "diagnostics_overview_panel"
        )
    }

    private var technicalDetailsPanel: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            Text(String(localized: "Technical Details"))
                .font(.headline)
                .accessibilityIdentifier("diagnostics_technical_details")

            HStack(spacing: AppUI.Spacing.medium) {
                Button(String(localized: "Refresh")) {
                    Task { await reload(refresh: true) }
                }
                .appActionButtonStyle(variant: .default)
                .disabled(isRefreshing)
                .accessibilityIdentifier("diagnostics_refresh_button")

                Button(String(localized: "Open Data Directory")) {
                    Task { await openDataDirectory() }
                }
                .appActionButtonStyle(variant: .default)
                .disabled(dataDirectoryDisplayPath == nil)
                .accessibilityIdentifier("diagnostics_open_data_directory_button")
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

            if let fullPath = latestBundleFullPath {
                VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                    Text(String(localized: "Support Package Path"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(fullPath)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("support_bundle_latest_full_path")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var technicalSummaryPanels: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220), spacing: AppUI.Spacing.medium)],
            spacing: AppUI.Spacing.medium
        ) {
            let runtimeSummary = RuntimeDiagnosticsSummary(state: snapshot?.state)
            summaryPanel(
                title: String(localized: "Runtime"),
                rows: runtimeSummaryRows(for: runtimeSummary),
                accessibilityIdentifier: "diagnostics_runtime_panel"
            )

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

    private func runtimeSummaryRows(for summary: RuntimeDiagnosticsSummary) -> [(String, String)] {
        [
            (String(localized: "Runtime Snapshot"), summary.statusCode),
            (String(localized: "Schema Version"), summary.schemaVersion.map(String.init) ?? "-"),
            (String(localized: "Surface Count"), "\(summary.surfaceCount)"),
            (String(localized: "Active Consumer Leases"), "\(summary.activeConsumerLeaseCount)"),
            (String(localized: "Total Consumer Leases"), "\(summary.totalConsumerLeaseCount)"),
            (String(localized: "Aggregated Demand Count"), "\(summary.aggregatedDemandCount)"),
            (String(localized: "Active Viewer Count"), "\(summary.activeViewerCount)"),
            (String(localized: "Effective Capture Intents"), "\(summary.effectiveCaptureIntentCount)"),
            (String(localized: "Active Transactions"), "\(summary.activeTransactionCount)"),
            (String(localized: "Recent Transactions"), "\(summary.recentTransactionCount)"),
            (String(localized: "Last Failure"), summary.lastFailureCode ?? "-")
        ]
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("diagnostics_recent_issues")
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("diagnostics_recent_events")
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var latestBundleFullPath: String? {
        feedbackController?.lastBundleDisplayInfo?.sanitizedFullPath ?? snapshot?.lastExportedBundleDisplayPath
    }

    private func historicalRecords(for controller: AppSettingsFeedbackController) -> [SupportExportRecord] {
        Array(controller.exportHistory.dropFirst())
    }

    private func currentStatusLabel(
        for snapshot: ObservabilityDiagnosticsSnapshot,
        runtimeSummary: RuntimeDiagnosticsSummary
    ) -> String {
        guard runtimeSummary.isAvailable else {
            return String(localized: "Attention Needed")
        }
        if snapshot.health.recentIssueCount > 0 ||
            (snapshot.health.highestSeverity ?? .debug) >= .warning {
            return String(localized: "Attention Needed")
        }
        return String(localized: "Looks Good")
    }

    private func statusRecommendation() -> String {
        guard let snapshot else {
            return String(localized: "If the issue happened recently, export a support package now.")
        }
        let runtimeSummary = RuntimeDiagnosticsSummary(state: snapshot.state)
        guard runtimeSummary.isAvailable else {
            return String(localized: "Refresh diagnostics, then export a support package if the runtime snapshot stays unavailable.")
        }

        if snapshot.health.recentIssueCount > 0 ||
            (snapshot.health.highestSeverity ?? .debug) >= .warning {
            return String(localized: "Review the recent issues below, then export another support package if needed.")
        }
        return String(localized: "If the issue happened recently, export a support package now.")
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

    private func copyHistorySummary(recordID: UUID) async {
        guard let feedbackController else { return }
        await feedbackController.copyHistorySummary(recordID: recordID)
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
        await feedbackController.revealLastBundle()
    }

    private func revealHistoryBundle(recordID: UUID) async {
        guard let feedbackController else { return }
        await feedbackController.revealHistoryBundle(recordID: recordID)
    }

    private func startNewFeedback() async {
        guard let feedbackController else { return }
        await feedbackController.startNewFeedback()
    }

    private func decodeSection<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let section = snapshot?.state.sections[key] else { return nil }
        return try? section.decode(type)
    }
}
