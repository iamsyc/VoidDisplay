import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppSettingsFeedbackController {
    var happened = ""
    var reproductionSteps = ""
    var expectedResult = ""
    var includeUnifiedLogSummary = false
    var includeCrashReportExcerpt = false
    var includeRelatedConfigSnapshots = false
    var alert: UserFacingAlertState?

    private(set) var isExporting = false
    private(set) var exportCompleted = false

    @ObservationIgnored private var lastBundleURL: URL?
    @ObservationIgnored private var lastBundleDisplayPathStorage: String?
    @ObservationIgnored private var exportAction: ((FeedbackDraft, FeedbackConsent) async throws -> URL)?
    @ObservationIgnored private var revealAction: ((URL) -> Void)?
    @ObservationIgnored private var copyAction: ((String) -> Void)?
    @ObservationIgnored private var summaryAction: ((FeedbackDraft) async -> String)?
    @ObservationIgnored private var errorMessageProvider: ((any Error) -> String)?

    init(
        exportAction: ((FeedbackDraft, FeedbackConsent) async throws -> URL)? = nil,
        revealAction: ((URL) -> Void)? = nil,
        copyAction: ((String) -> Void)? = nil,
        summaryAction: ((FeedbackDraft) async -> String)? = nil,
        errorMessageProvider: ((any Error) -> String)? = nil
    ) {
        self.exportAction = exportAction
        self.revealAction = revealAction
        self.copyAction = copyAction
        self.summaryAction = summaryAction
        self.errorMessageProvider = errorMessageProvider
    }

    var canRevealLastBundle: Bool {
        lastBundleURL != nil
    }

    var canCopySummary: Bool {
        true
    }

    var lastBundleDisplayPath: String? {
        lastBundleDisplayPathStorage
    }

    func prepare(observability: ObservabilityCenter) async {
        configure(observability: observability)
        await restoreLastExportedBundle(from: observability)
    }

    func configure(observability: ObservabilityCenter) {
        exportAction = { draft, consent in
            try await observability.exportBundle(draft: draft, consent: consent)
        }
        revealAction = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        copyAction = { content in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
        }
        summaryAction = { draft in
            await observability.summaryText(for: draft)
        }
        errorMessageProvider = { error in
            AppErrorMapper.userMessage(
                for: error,
                fallback: String(localized: "Failed to export support bundle.")
            )
        }
    }

    func restoreLastExportedBundle(from observability: ObservabilityCenter) async {
        let url = await observability.exportedBundleURL()
        updateLastExportedBundle(url)
    }

    func exportSupportBundle() async {
        guard let exportAction else { return }
        isExporting = true
        exportCompleted = false
        defer { isExporting = false }

        do {
            let url = try await exportAction(currentDraft, currentConsent)
            updateLastExportedBundle(url)
            exportCompleted = true
            alert = nil
        } catch {
            alert = UserFacingAlertState(
                title: String(localized: "Export Failed"),
                message: errorMessageProvider?(error) ?? String(localized: "Failed to export support bundle.")
            )
        }
    }

    func revealLastBundle() {
        guard let url = lastBundleURL else { return }
        revealAction?(url)
    }

    func copySummary() async {
        guard let summaryAction else { return }
        let summary = await summaryAction(currentDraft)
        guard !summary.isEmpty else { return }
        copyAction?(summary)
    }

    func dismissAlert() {
        alert = nil
    }

    func applyFixture(_ fixture: SettingsFeedbackFixture) {
        happened = fixture.draft.happened
        reproductionSteps = fixture.draft.reproductionSteps
        expectedResult = fixture.draft.expectedResult
        includeUnifiedLogSummary = fixture.consent.includeUnifiedLogSummary
        includeCrashReportExcerpt = fixture.consent.includeCrashReportExcerpt
        includeRelatedConfigSnapshots = fixture.consent.includeRelatedConfigSnapshots
    }

    var currentDraft: FeedbackDraft {
        FeedbackDraft(
            happened: happened,
            reproductionSteps: reproductionSteps,
            expectedResult: expectedResult
        )
    }

    var currentConsent: FeedbackConsent {
        FeedbackConsent(
            includeUnifiedLogSummary: includeUnifiedLogSummary,
            includeCrashReportExcerpt: includeCrashReportExcerpt,
            includeRelatedConfigSnapshots: includeRelatedConfigSnapshots
        )
    }

    private func updateLastExportedBundle(_ url: URL?) {
        lastBundleURL = url
        lastBundleDisplayPathStorage = url.map { ObservabilitySanitizer().sanitize(fileURL: $0) }
    }
}
