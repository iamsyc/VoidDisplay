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
    @State private var isAdvancedSnapshotExpanded = false

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
                    diagnosticsSnapshotPanel
                    displaySystemPanel
                    advancedSnapshotPanel
                    issuesPanel
                    eventsPanel
                }
                .padding(.top, AppUI.Spacing.medium)
            },
            label: {
                VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                    Label(String(localized: "Technical Information"), systemImage: "stethoscope")
                        .font(.headline)
                }
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("diagnostics_technical_disclosure")
    }

    private var diagnosticsSnapshotPanel: some View {
        let runtimeSummary = RuntimeDiagnosticsSummary(state: snapshot?.state)
        return VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            HStack(alignment: .top, spacing: AppUI.Spacing.medium) {
                VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                    Label(String(localized: "Status"), systemImage: "folder.badge.gearshape")
                        .font(.headline)
                        .accessibilityIdentifier("diagnostics_technical_details")
                    Text(statusRecommendation())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: AppUI.Spacing.medium)
                HStack(spacing: AppUI.Spacing.small) {
                    Button {
                        Task { await reload(refresh: true) }
                    } label: {
                        Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
                    }
                    .appActionButtonStyle(variant: .default)
                    .disabled(isRefreshing)
                    .accessibilityIdentifier("diagnostics_refresh_button")

                    Button {
                        Task { await openDataDirectory() }
                    } label: {
                        Label(String(localized: "Open Data Directory"), systemImage: "folder")
                    }
                    .appActionButtonStyle(variant: .default)
                    .disabled(dataDirectoryDisplayPath == nil)
                    .accessibilityIdentifier("diagnostics_open_data_directory_button")
                }
                .labelStyle(.titleAndIcon)
                .fixedSize()
            }

            DiagnosticsStatusCallout(
                title: snapshot.map { currentStatusLabel(for: $0, runtimeSummary: runtimeSummary) } ??
                    String(localized: "Diagnostics"),
                detail: currentStatusDetail(for: snapshot, runtimeSummary: runtimeSummary),
                systemImage: statusSystemImage(for: snapshot, runtimeSummary: runtimeSummary),
                tint: statusTint(for: snapshot, runtimeSummary: runtimeSummary)
            )

            VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                readableRow(
                    title: String(localized: "Runtime Snapshot"),
                    value: snapshot == nil ? "-" : runtimeSummary.statusCode,
                    isMonospaced: snapshot != nil
                )
                readableRow(
                    title: String(localized: "Section Count"),
                    value: collectedAreasLabel
                )
                readableRow(
                    title: String(localized: "Data Directory"),
                    value: dataDirectoryDisplayPath ?? "-",
                    isMonospaced: dataDirectoryDisplayPath != nil
                )
                readableRow(
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
        .accessibilityIdentifier("diagnostics_overview_panel")
    }

    private var displaySystemPanel: some View {
        let runtimeSummary = RuntimeDiagnosticsSummary(state: snapshot?.state)
        return VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                Label(String(localized: "Displays"), systemImage: "display.2")
                    .font(.headline)
            }

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
                    title: String(localized: "Last Failure"),
                    value: runtimeSummary.lastFailureCode ?? "-",
                    systemImage: runtimeSummary.lastFailureCode == nil ? "checkmark.circle" : "exclamationmark.triangle",
                    tint: runtimeSummary.lastFailureCode == nil ? .green : .orange
                )
            }

            if let lastFailureCode = runtimeSummary.lastFailureCode {
                readableRow(
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

    private var advancedSnapshotPanel: some View {
        DisclosureGroup(
            isExpanded: $isAdvancedSnapshotExpanded,
            content: {
                VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                    let runtimeSummary = RuntimeDiagnosticsSummary(state: snapshot?.state)
                    readableRow(title: String(localized: "Runtime Snapshot"), value: runtimeSummary.statusCode, isMonospaced: true)
                    readableRow(title: String(localized: "Schema Version"), value: runtimeSummary.schemaVersion.map(String.init) ?? "-")
                    readableRow(title: String(localized: "Active Viewer Count"), value: "\(runtimeSummary.activeViewerCount)")
                    readableRow(title: String(localized: "Aggregated Demand Count"), value: "\(runtimeSummary.aggregatedDemandCount)")
                    readableRow(title: String(localized: "Refresh Reason"), value: snapshot?.state.refreshReason.rawValue ?? "-", isMonospaced: true)

                    if let system = decodeSection("system", as: SystemSnapshotProvider.Snapshot.self),
                       let persistence = decodeSection("persistence", as: PersistenceSnapshotProvider.Snapshot.self) {
                        Divider()
                        readableRow(title: String(localized: "Locale"), value: system.localeIdentifier)
                        readableRow(title: String(localized: "Time Zone"), value: system.timeZoneIdentifier)
                        readableRow(title: String(localized: "Mode"), value: persistence.mode)
                        readableRow(title: String(localized: "Bundle ID"), value: persistence.bundleIdentifier, isMonospaced: true)
                    }
                }
                .padding(.top, AppUI.Spacing.small)
            },
            label: {
                VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                    Label(String(localized: "Technical Details"), systemImage: "curlybraces")
                        .font(.subheadline.weight(.semibold))
                }
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appPanelStyle()
    }

    private var issuesPanel: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            Label(String(localized: "Recent Issues"), systemImage: "exclamationmark.triangle")
                .font(.headline)

            if let issues = snapshot?.issues, !issues.isEmpty {
                ForEach(Array(issues.prefix(8).enumerated()), id: \.element.id) { index, issue in
                    VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                        Text(issue.message)
                            .font(.footnote)
                            .textSelection(.enabled)
                        HStack(spacing: AppUI.Spacing.small) {
                            DiagnosticsTag(title: issue.subsystem.rawValue)
                            Text(issue.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            if issue.occurrenceCount > 1 {
                                Text(verbatim: "x\(issue.occurrenceCount)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    if index < min(issues.count, 8) - 1 {
                        Divider()
                    }
                }
            } else {
                Label(String(localized: "No recent issues."), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appPanelStyle()
        .accessibilityIdentifier("diagnostics_recent_issues")
    }

    private var eventsPanel: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            Label(String(localized: "Recent Events"), systemImage: "waveform.path.ecg")
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
                            DisclosureGroup(String(localized: "Details")) {
                                Text(
                                    verbatim: event.metadata
                                        .sorted { $0.key < $1.key }
                                        .map { "\($0.key)=\($0.value)" }
                                        .joined(separator: "\n")
                                )
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, AppUI.Spacing.xSmall)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    if index < renderedEvents.count - 1 {
                        Divider()
                    }
                }
            } else {
                Label(String(localized: "No recent events."), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appPanelStyle()
        .accessibilityIdentifier("diagnostics_recent_events")
    }

    private func readableRow(
        title: String,
        value: String,
        detail: String? = nil,
        isMonospaced: Bool = false,
        accessibilityIdentifier: String? = nil
    ) -> some View {
        DiagnosticsReadableRow(
            title: title,
            value: value,
            detail: detail,
            isMonospaced: isMonospaced,
            accessibilityIdentifier: accessibilityIdentifier
        )
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

    private func currentStatusDetail(
        for snapshot: ObservabilityDiagnosticsSnapshot?,
        runtimeSummary: RuntimeDiagnosticsSummary
    ) -> String {
        guard let snapshot else {
            return statusRecommendation()
        }
        guard runtimeSummary.isAvailable else {
            return statusRecommendation()
        }
        if snapshot.health.recentIssueCount > 0 ||
            (snapshot.health.highestSeverity ?? .debug) >= .warning {
            return statusRecommendation()
        }
        return statusRecommendation()
    }

    private func statusSystemImage(
        for snapshot: ObservabilityDiagnosticsSnapshot?,
        runtimeSummary: RuntimeDiagnosticsSummary
    ) -> String {
        guard let snapshot else { return "arrow.triangle.2.circlepath" }
        guard runtimeSummary.isAvailable else { return "exclamationmark.triangle" }
        if snapshot.health.recentIssueCount > 0 ||
            (snapshot.health.highestSeverity ?? .debug) >= .warning {
            return "exclamationmark.triangle"
        }
        return "checkmark.circle"
    }

    private func statusTint(
        for snapshot: ObservabilityDiagnosticsSnapshot?,
        runtimeSummary: RuntimeDiagnosticsSummary
    ) -> Color {
        guard let snapshot else { return .blue }
        guard runtimeSummary.isAvailable else { return .orange }
        if snapshot.health.recentIssueCount > 0 ||
            (snapshot.health.highestSeverity ?? .debug) >= .warning {
            return .orange
        }
        return .green
    }

    private var collectedAreasLabel: String {
        let count = snapshot?.state.sections.count ?? 0
        return "\(count)"
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

private struct DiagnosticsStatusCallout: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: AppUI.Spacing.medium) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(AppUI.Spacing.medium)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: AppUI.Corner.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppUI.Corner.small, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: AppUI.Stroke.subtle)
        )
    }
}

private struct DiagnosticsMetricTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
            HStack(spacing: AppUI.Spacing.small) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(AppUI.Spacing.medium)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: AppUI.Corner.small, style: .continuous))
    }
}

private struct DiagnosticsTag: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, AppUI.Spacing.small - 1)
            .padding(.vertical, AppUI.Spacing.xSmall)
            .background(.quaternary.opacity(0.45), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

private struct DiagnosticsReadableRow: View {
    let title: String
    let value: String
    let detail: String?
    let isMonospaced: Bool
    let accessibilityIdentifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
            HStack(alignment: .firstTextBaseline, spacing: AppUI.Spacing.medium) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: AppUI.Spacing.medium)
                Text(value)
                    .font(isMonospaced ? .footnote.monospaced() : .footnote)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(accessibilityIdentifier ?? "")
            }

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
