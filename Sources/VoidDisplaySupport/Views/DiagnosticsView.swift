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
    @State private var technicalScrollAnchor = DiagnosticsScrollAnchor()

    package init(
        observability: ObservabilityCenter,
        feedbackController: AppSettingsFeedbackController? = nil
    ) {
        self.observability = observability
        self.feedbackController = feedbackController
    }

    package var body: some View {
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

                DiagnosticsScrollAnchorView(anchor: technicalScrollAnchor)
                    .frame(height: 1)
                    .accessibilityHidden(true)

                DiagnosticsTechnicalInformationSection(
                    isExpanded: $isTechnicalInformationExpanded,
                    isAdvancedSnapshotExpanded: $isAdvancedSnapshotExpanded,
                    snapshot: snapshot,
                    dataDirectoryDisplayPath: dataDirectoryDisplayPath,
                    latestBundleFullPath: latestBundleFullPath,
                    onOpenDataDirectory: { Task { await openDataDirectory() } }
                )
            }
            .appListContentInsets(bottom: false)
            .padding(.bottom, AppUI.Spacing.large)
            .frame(maxWidth: contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onChange(of: isTechnicalInformationExpanded) { _, expanded in
            if expanded {
                technicalScrollAnchor.requestScrollToTop()
            } else {
                technicalScrollAnchor.cancelPendingScroll()
            }
        }
        .task {
            await prepare()
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

@MainActor
private final class DiagnosticsScrollAnchor: NSObject {
    weak var view: NSView?
    private weak var observedDocumentView: NSView?
    private var isScrollPending = false

    func attach(_ view: NSView) {
        self.view = view
        observeDocumentFrameIfNeeded()
    }

    func requestScrollToTop() {
        isScrollPending = true
        observeDocumentFrameIfNeeded()
        scrollToTopIfPossible()
    }

    func detach(_ view: NSView) {
        guard self.view === view else { return }
        self.view = nil
        cancelPendingScroll()
    }

    func cancelPendingScroll() {
        isScrollPending = false
        stopObservingDocumentFrame()
    }

    @objc private func documentFrameDidChange(_ notification: Notification) {
        scrollToTopIfPossible()
    }

    private func observeDocumentFrameIfNeeded() {
        guard
            isScrollPending,
            let documentView = view?.enclosingScrollView?.documentView,
            observedDocumentView !== documentView
        else { return }

        if let observedDocumentView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: observedDocumentView
            )
        }
        observedDocumentView = documentView
        documentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(documentFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: documentView
        )
    }

    private func scrollToTopIfPossible() {
        guard isScrollPending else { return }
        guard
            let view,
            let scrollView = view.enclosingScrollView,
            let documentView = scrollView.documentView
        else { return }

        documentView.layoutSubtreeIfNeeded()
        let targetFrame = view.convert(view.bounds, to: documentView)
        let clipView = scrollView.contentView
        var origin = clipView.bounds.origin
        let topMargin = AppUI.Spacing.large * 2
        let targetY = if documentView.isFlipped {
            targetFrame.minY - topMargin
        } else {
            targetFrame.maxY - clipView.bounds.height + topMargin
        }
        let minimumY = documentView.bounds.minY
        let maximumY = max(minimumY, documentView.bounds.maxY - clipView.bounds.height)
        guard targetY <= maximumY + 1 else { return }
        isScrollPending = false
        stopObservingDocumentFrame()
        origin.y = min(max(targetY, minimumY), maximumY)
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func stopObservingDocumentFrame() {
        guard let observedDocumentView else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSView.frameDidChangeNotification,
            object: observedDocumentView
        )
        self.observedDocumentView = nil
    }
}

private struct DiagnosticsScrollAnchorView: NSViewRepresentable {
    let anchor: DiagnosticsScrollAnchor

    func makeNSView(context: Context) -> NSView {
        let view = DiagnosticsScrollAnchorHostView(anchor: anchor)
        anchor.attach(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.attach(nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Void) {
        if let hostView = nsView as? DiagnosticsScrollAnchorHostView {
            hostView.anchor.detach(nsView)
        }
    }
}

@MainActor
private final class DiagnosticsScrollAnchorHostView: NSView {
    let anchor: DiagnosticsScrollAnchor

    init(anchor: DiagnosticsScrollAnchor) {
        self.anchor = anchor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
