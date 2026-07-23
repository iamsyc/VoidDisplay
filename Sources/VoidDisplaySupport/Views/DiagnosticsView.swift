import AppKit
import Foundation
import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability

package struct DiagnosticsView: View {
    private let contentMaxWidth: CGFloat = 840
    private let observability: ObservabilityCenter
    private let feedbackController: AppSettingsFeedbackController?

    @State private var snapshot: ObservabilityDiagnosticsSnapshot?
    @State private var dataDirectoryDisplayPath: String?
    @State private var isRefreshing = false
    @State private var isTechnicalInformationExpanded = false
    @State private var isAdvancedSnapshotExpanded = false
    @State private var isTechnicalScrollPending = false
    @State private var validationFocusRequest = 0

    package init(
        observability: ObservabilityCenter,
        feedbackController: AppSettingsFeedbackController? = nil
    ) {
        self.observability = observability
        self.feedbackController = feedbackController
    }

    package var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: AppUI.Spacing.medium + 2) {
                    Text(String(localized: "Review app health, add diagnostics if needed, then export a support bundle."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("diagnostics_intro_text")

                    DiagnosticsOverviewPanel(
                        snapshot: snapshot,
                        isRefreshing: isRefreshing,
                        onRefresh: { Task { await reload(refresh: true) } }
                    )

                    if let feedbackController {
                        DiagnosticsFeedbackSections(
                            controller: feedbackController,
                            validationFocusRequest: validationFocusRequest,
                            onExport: { Task { await exportSupportBundle() } },
                            onCopySummary: { Task { await copySummary() } },
                            onRevealLatestBundle: { Task { await revealLatestBundle() } },
                            onStartNewFeedback: { Task { await startNewFeedback() } },
                            onCopyHistorySummary: { recordID in
                                Task { await copyHistorySummary(recordID: recordID) }
                            },
                            onRevealHistoryBundle: { recordID in
                                Task { await revealHistoryBundle(recordID: recordID) }
                            }
                        )
                    }

                    DiagnosticsTechnicalInformationSection(
                        isExpanded: Binding(
                            get: { isTechnicalInformationExpanded },
                            set: { expanded in
                                isTechnicalScrollPending = expanded
                                isTechnicalInformationExpanded = expanded
                            }
                        ),
                        isAdvancedSnapshotExpanded: $isAdvancedSnapshotExpanded,
                        snapshot: snapshot,
                        dataDirectoryDisplayPath: dataDirectoryDisplayPath,
                        latestBundleFullPath: latestBundleFullPath,
                        onOpenDataDirectory: { Task { await openDataDirectory() } },
                        onExpandedContentLayout: {
                            guard isTechnicalScrollPending else { return }
                            isTechnicalScrollPending = false
                            proxy.scrollTo("diagnostics_technical_content_anchor", anchor: .top)
                        }
                    )
                    .id("diagnostics_technical_anchor")
                }
                .appListContentInsets(bottom: false)
                .padding(.bottom, AppUI.Spacing.large)
                .frame(maxWidth: contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: validationFocusRequest) { _, request in
                guard request > 0 else { return }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo("support_bundle_validation_anchor", anchor: .center)
                }
            }
            .task {
                await prepare()
            }
        }
    }

    private var latestBundleFullPath: String? {
        feedbackController?.lastBundleDisplayInfo?.sanitizedFullPath ?? snapshot?.lastExportedBundleDisplayPath
    }

    private func prepare() async {
        if let feedbackController {
            await feedbackController.prepare(observability: observability)
            if let fixture = UITestRuntime.feedbackFixture {
                feedbackController.applyFixture(fixture)
            }
            await feedbackController.trackPageOpened()
        }
        if UITestRuntime.isEnabled,
           UITestRuntime.scenario == .diagnosticsRecoveredWarning {
            await observability.record(
                ObservabilityEvent(
                    severity: .warning,
                    subsystem: .capture,
                    operation: "Screen capture permission check",
                    message: "Screen capture permission unavailable."
                )
            )
        }
        dataDirectoryDisplayPath = await observability.dataDirectoryDisplayPath()
        if snapshot == nil {
            await reload(refresh: true)
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
        if feedbackController.validationMessage != nil {
            validationFocusRequest &+= 1
        }
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
}
