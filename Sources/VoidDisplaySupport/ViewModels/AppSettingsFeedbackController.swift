import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import AppKit
import Foundation
import Observation

@MainActor
@Observable
package final class AppSettingsFeedbackController {
    package var issueType: SupportIssueType = .other {
        didSet {
            handleIssueTypeChange(from: oldValue)
        }
    }

    package var happened = "" {
        didSet { handleDraftMutation() }
    }

    package var reproductionSteps = "" {
        didSet { handleDraftMutation() }
    }

    package var expectedResult = "" {
        didSet { handleDraftMutation() }
    }

    package var includeUnifiedLogSummary = false {
        didSet { handleDraftMutation() }
    }

    package var includeCrashReportExcerpt = false {
        didSet { handleDraftMutation() }
    }

    package var includeRelatedConfigSnapshots = false {
        didSet { handleDraftMutation() }
    }

    package var alert: UserFacingAlertState?
    package var validationMessage: String?

    private(set) var isExporting = false
    private(set) var exportCompleted = false
    private(set) var exportHistory: [SupportExportRecord] = []
    private(set) var completionRecord: SupportExportRecord?

    @ObservationIgnored private var hasPrepared = false
    @ObservationIgnored private var isRestoringState = false
    @ObservationIgnored private var lastBundleURL: URL?
    @ObservationIgnored private var lastBundleDisplayInfoStorage: SupportBundleDisplayInfo?
    @ObservationIgnored private var latestExportDraft: FeedbackDraft?
    @ObservationIgnored private var exportAction: ((FeedbackDraft, FeedbackConsent) async throws -> URL)?
    @ObservationIgnored private var revealAction: ((URL) -> Void)?
    @ObservationIgnored private var copyAction: ((String) -> Void)?
    @ObservationIgnored private var summaryAction: ((FeedbackDraft) async -> String)?
    @ObservationIgnored private var eventRecorder: ((ObservabilityEvent) async -> Void)?
    @ObservationIgnored private var errorMessageProvider: ((any Error) -> String)?
    @ObservationIgnored private let draftStore: SupportDraftStore
    @ObservationIgnored private let historyStore: SupportHistoryStore?
    @ObservationIgnored private let dateProvider: () -> Date
    @ObservationIgnored private let sanitizer: ObservabilitySanitizer

    package init(
        defaults: UserDefaults = .standard,
        historyStore: SupportHistoryStore? = nil,
        eventRecorder: ((ObservabilityEvent) async -> Void)? = nil,
        exportAction: ((FeedbackDraft, FeedbackConsent) async throws -> URL)? = nil,
        revealAction: ((URL) -> Void)? = nil,
        copyAction: ((String) -> Void)? = nil,
        summaryAction: ((FeedbackDraft) async -> String)? = nil,
        errorMessageProvider: ((any Error) -> String)? = nil,
        dateProvider: @escaping () -> Date = Date.init,
        sanitizer: ObservabilitySanitizer = ObservabilitySanitizer()
    ) {
        draftStore = SupportDraftStore(defaults: defaults, sanitizer: sanitizer)
        self.historyStore = historyStore
        self.eventRecorder = eventRecorder
        self.exportAction = exportAction
        self.revealAction = revealAction
        self.copyAction = copyAction
        self.summaryAction = summaryAction
        self.errorMessageProvider = errorMessageProvider
        self.dateProvider = dateProvider
        self.sanitizer = sanitizer
    }

    package var canRevealLastBundle: Bool {
        completionRecord != nil || lastBundleURL != nil
    }

    package var canCopySummary: Bool {
        completionRecord != nil
    }

    package var hasExportHistory: Bool {
        exportHistory.isEmpty == false
    }

    package var latestExportRecord: SupportExportRecord? {
        exportHistory.first
    }

    package var lastBundleDisplayInfo: SupportBundleDisplayInfo? {
        lastBundleDisplayInfoStorage
    }

    package var lastBundleDisplayPath: String? {
        lastBundleDisplayInfoStorage?.sanitizedFullPath
    }

    package var currentIssuePresentation: SupportIssuePresentation {
        issueType.presentation
    }

    package var currentDraft: FeedbackDraft {
        FeedbackDraft(
            issueType: issueType,
            happened: happened,
            reproductionSteps: reproductionSteps,
            expectedResult: expectedResult
        )
    }

    package var currentConsent: FeedbackConsent {
        FeedbackConsent(
            includeUnifiedLogSummary: includeUnifiedLogSummary,
            includeCrashReportExcerpt: includeCrashReportExcerpt,
            includeRelatedConfigSnapshots: includeRelatedConfigSnapshots
        )
    }

    package var recommendedConsent: FeedbackConsent {
        currentIssuePresentation.recommendedConsent
    }

    package var usesRecommendedDiagnostics: Bool {
        currentConsent == recommendedConsent
    }

    package func prepare(observability: ObservabilityCenter) async {
        configure(observability: observability)
        guard hasPrepared == false else { return }

        isRestoringState = true
        apply(snapshot: draftStore.load(), persistDraft: false)
        exportHistory = historyStore?.loadRecords() ?? []
        completionRecord = exportHistory.first
        exportCompleted = completionRecord != nil
        if let latestRecord = exportHistory.first {
            updateLastExportedBundle(record: latestRecord)
        } else {
            await restoreLastExportedBundle(from: observability)
        }
        isRestoringState = false
        hasPrepared = true
    }

    package func configure(observability: ObservabilityCenter) {
        if exportAction == nil {
            exportAction = { draft, consent in
                try await observability.exportBundle(draft: draft, consent: consent)
            }
        }
        if revealAction == nil {
            revealAction = { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        if copyAction == nil {
            copyAction = { content in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
            }
        }
        if summaryAction == nil {
            summaryAction = { draft in
                await observability.summaryText(
                    for: draft,
                    issueTypeLine: String(localized: draft.issueType.presentation.summaryPrefixKey)
                )
            }
        }
        if eventRecorder == nil {
            eventRecorder = { event in
                await observability.record(event)
            }
        }
        if errorMessageProvider == nil {
            errorMessageProvider = { error in
                AppErrorMapper.userMessage(
                    for: error,
                    fallback: String(localized: "Failed to export support bundle.")
                )
            }
        }
    }

    package func restoreLastExportedBundle(from observability: ObservabilityCenter) async {
        let url = await observability.exportedBundleURL()
        updateLastExportedBundle(url)
        exportCompleted = completionRecord != nil
    }

    package func trackPageOpened() async {
        await recordEvent(.pageOpened)
    }

    package func exportSupportBundle() async {
        guard isExporting == false, let exportAction else { return }

        let trimmedDraft = currentDraft.trimmedPayload()
        guard trimmedDraft.isEmpty == false else {
            validationMessage = String(localized: "Please fill in at least one problem field.")
            await recordEvent(.validationFailed, severity: .warning)
            return
        }

        validationMessage = nil
        isExporting = true
        exportCompleted = false
        defer { isExporting = false }

        await recordEvent(.exportStarted)

        do {
            let exportedAt = dateProvider()
            let url = try await exportAction(trimmedDraft, currentConsent)
            let record = makeExportRecord(url: url, draft: trimmedDraft, exportedAt: exportedAt)
            updateLastExportedBundle(url)
            latestExportDraft = sanitizer.sanitize(trimmedDraft)
            exportHistory = appendExportRecord(record)
            completionRecord = record
            exportCompleted = true
            alert = nil
            await recordEvent(
                .exportSucceeded,
                extraMetadata: ["bundleFileName": record.bundleFileName]
            )
        } catch {
            let message = errorMessageProvider?(error) ?? String(localized: "Failed to export support bundle.")
            alert = UserFacingAlertState(
                title: String(localized: "Export Failed"),
                message: message
            )
            await recordEvent(
                .exportFailed,
                severity: .error,
                extraMetadata: ["errorMessage": message]
            )
        }
    }

    package func revealLastBundle() async {
        guard let completionRecord else { return }
        revealBundle(for: completionRecord, action: .bundleRevealed)
        await recordEvent(
            .bundleRevealed,
            extraMetadata: ["bundleFileName": completionRecord.bundleFileName]
        )
    }

    package func revealHistoryBundle(recordID: UUID) async {
        guard let record = exportHistory.first(where: { $0.id == recordID }) else { return }
        revealBundle(for: record, action: .historyBundleRevealed)
        await recordEvent(
            .historyBundleRevealed,
            extraMetadata: ["bundleFileName": record.bundleFileName]
        )
    }

    package func copySummary() async {
        guard let activeRecord = completionRecord else { return }
        if let latestExportDraft,
           let summaryAction {
            let summary = await summaryAction(latestExportDraft)
            guard summary.isEmpty == false else { return }
            copyAction?(summary)
        } else {
            copyAction?(activeRecord.historyCopyText)
        }
        exportHistory = markSummaryCopiedPersisting(recordID: activeRecord.id, at: dateProvider())
        completionRecord = exportHistory.first(where: { $0.id == activeRecord.id }) ?? activeRecord
        await recordEvent(
            .summaryCopied,
            extraMetadata: ["bundleFileName": activeRecord.bundleFileName]
        )
    }

    package func copyHistorySummary(recordID: UUID) async {
        guard let record = exportHistory.first(where: { $0.id == recordID }) else { return }
        copyAction?(record.historyCopyText)
        exportHistory = markSummaryCopiedPersisting(recordID: recordID, at: dateProvider())
        await recordEvent(
            .historySummaryCopied,
            extraMetadata: ["bundleFileName": record.bundleFileName]
        )
    }

    package func applyRecommendedDiagnostics() {
        apply(consent: recommendedConsent)
    }

    package func startNewFeedback() async {
        isRestoringState = true
        issueType = .other
        happened = ""
        reproductionSteps = ""
        expectedResult = ""
        includeUnifiedLogSummary = false
        includeCrashReportExcerpt = false
        includeRelatedConfigSnapshots = false
        validationMessage = nil
        exportCompleted = false
        completionRecord = nil
        latestExportDraft = nil
        alert = nil
        isRestoringState = false
        draftStore.clear()
        await recordEvent(.newFeedback)
    }

    package func dismissAlert() {
        alert = nil
    }

    package func applyFixture(_ fixture: SettingsFeedbackFixture) {
        apply(
            snapshot: SupportDraftSnapshot(
                issueType: fixture.draft.issueType,
                happened: fixture.draft.happened,
                reproductionSteps: fixture.draft.reproductionSteps,
                expectedResult: fixture.draft.expectedResult,
                includeUnifiedLogSummary: fixture.consent.includeUnifiedLogSummary,
                includeCrashReportExcerpt: fixture.consent.includeCrashReportExcerpt,
                includeRelatedConfigSnapshots: fixture.consent.includeRelatedConfigSnapshots
            ),
            persistDraft: hasPrepared
        )
    }

    private func apply(consent: FeedbackConsent) {
        let previousState = isRestoringState
        isRestoringState = true
        includeUnifiedLogSummary = consent.includeUnifiedLogSummary
        includeCrashReportExcerpt = consent.includeCrashReportExcerpt
        includeRelatedConfigSnapshots = consent.includeRelatedConfigSnapshots
        validationMessage = nil
        isRestoringState = previousState

        if hasPrepared {
            draftStore.save(currentDraftSnapshot)
        }
    }

    private func apply(snapshot: SupportDraftSnapshot, persistDraft: Bool) {
        let previousState = isRestoringState
        isRestoringState = true
        issueType = snapshot.issueType
        happened = snapshot.happened
        reproductionSteps = snapshot.reproductionSteps
        expectedResult = snapshot.expectedResult
        includeUnifiedLogSummary = snapshot.includeUnifiedLogSummary
        includeCrashReportExcerpt = snapshot.includeCrashReportExcerpt
        includeRelatedConfigSnapshots = snapshot.includeRelatedConfigSnapshots
        validationMessage = nil
        isRestoringState = previousState

        if persistDraft {
            draftStore.save(snapshot)
        }
    }

    private func handleIssueTypeChange(from previousValue: SupportIssueType) {
        guard previousValue != issueType else { return }
        handleDraftMutation()
        guard hasPrepared, isRestoringState == false else { return }
        Task {
            await recordEvent(
                .issueTypeChanged,
                extraMetadata: ["previousIssueType": previousValue.rawValue]
            )
        }
    }

    private func handleDraftMutation() {
        guard isRestoringState == false else { return }
        validationMessage = nil
        alert = nil
        if hasPrepared {
            draftStore.save(currentDraftSnapshot)
        }
    }

    private var currentDraftSnapshot: SupportDraftSnapshot {
        SupportDraftSnapshot(
            issueType: issueType,
            happened: happened,
            reproductionSteps: reproductionSteps,
            expectedResult: expectedResult,
            includeUnifiedLogSummary: includeUnifiedLogSummary,
            includeCrashReportExcerpt: includeCrashReportExcerpt,
            includeRelatedConfigSnapshots: includeRelatedConfigSnapshots
        )
    }

    private var filledFieldCount: Int {
        [
            currentDraft.trimmedPayload().happened,
            currentDraft.trimmedPayload().reproductionSteps,
            currentDraft.trimmedPayload().expectedResult
        ]
        .filter { $0.isEmpty == false }
        .count
    }

    private func appendExportRecord(_ record: SupportExportRecord) -> [SupportExportRecord] {
        persistHistory(
            operation: { try historyStore?.appendRecord(record) },
            fallback: {
                var records = exportHistory
                records.removeAll { $0.bundleFileName == record.bundleFileName }
                records.insert(record, at: 0)
                return Array(records.prefix(10))
            }
        )
    }

    private func markSummaryCopiedPersisting(recordID: UUID, at date: Date) -> [SupportExportRecord] {
        persistHistory(
            operation: { try historyStore?.markSummaryCopied(recordID: recordID, at: date) },
            fallback: { markSummaryCopied(recordID: recordID, at: date) }
        )
    }

    private func markRevealedPersisting(recordID: UUID, at date: Date) -> [SupportExportRecord] {
        persistHistory(
            operation: { try historyStore?.markRevealed(recordID: recordID, at: date) },
            fallback: { markRevealed(recordID: recordID, at: date) }
        )
    }

    private func markSummaryCopied(recordID: UUID, at date: Date) -> [SupportExportRecord] {
        var records = exportHistory
        guard let index = records.firstIndex(where: { $0.id == recordID }) else {
            return records
        }
        records[index].summaryCopiedAt = date
        return records
    }

    private func markRevealed(recordID: UUID, at date: Date) -> [SupportExportRecord] {
        var records = exportHistory
        guard let index = records.firstIndex(where: { $0.id == recordID }) else {
            return records
        }
        records[index].revealedAt = date
        return records
    }

    private func recordHistoryPersistenceFailure(_ error: Error) {
        AppErrorMapper.logFailure(
            "Persist support export history",
            error: error,
            logger: AppLog.support,
            subsystem: .support,
            deduplicationKey: "support.history.persist"
        )
    }

    private func persistHistory(
        operation: () throws -> [SupportExportRecord]?,
        fallback: () -> [SupportExportRecord]
    ) -> [SupportExportRecord] {
        do {
            if let records = try operation() {
                return records
            }
        } catch {
            recordHistoryPersistenceFailure(error)
        }
        return fallback()
    }

    private func makeExportRecord(
        url: URL,
        draft: FeedbackDraft,
        exportedAt: Date
    ) -> SupportExportRecord {
        let displayInfo = SupportBundleDisplayInfo(url: url) ?? SupportBundleDisplayInfo(
            displayName: url.lastPathComponent,
            displayTimestamp: exportedAt.formatted(date: .abbreviated, time: .shortened),
            sanitizedFullPath: sanitizer.sanitize(fileURL: url)
        )

        return SupportExportRecord(
            exportedAt: exportedAt,
            issueType: draft.issueType,
            bundleFileName: displayInfo.displayName,
            sanitizedBundlePath: displayInfo.sanitizedFullPath,
            draftPreview: makeDraftPreview(from: draft)
        )
    }

    private func makeDraftPreview(from draft: FeedbackDraft) -> String {
        let trimmedDraft = sanitizer.sanitize(draft.trimmedPayload())
        var lines: [String] = []
        if trimmedDraft.happened.isEmpty == false {
            lines.append(String(localized: "What happened:"))
            lines.append(trimmedDraft.happened)
        }
        if trimmedDraft.reproductionSteps.isEmpty == false {
            lines.append(String(localized: "Reproduction steps:"))
            lines.append(trimmedDraft.reproductionSteps)
        }
        if trimmedDraft.expectedResult.isEmpty == false {
            lines.append(String(localized: "Expected result:"))
            lines.append(trimmedDraft.expectedResult)
        }
        return lines.joined(separator: "\n")
    }

    private func updateLastExportedBundle(_ url: URL?) {
        lastBundleURL = url
        lastBundleDisplayInfoStorage = url.flatMap { SupportBundleDisplayInfo(url: $0) }
    }

    private func updateLastExportedBundle(record: SupportExportRecord) {
        lastBundleURL = record.resolvedBundleURL
        lastBundleDisplayInfoStorage = record.displayInfo
    }

    private func revealBundle(
        for record: SupportExportRecord,
        action: SupportWorkflowEventAction
    ) {
        let url = record.resolvedBundleURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        revealAction?(url)
        exportHistory = markRevealedPersisting(recordID: record.id, at: dateProvider())
        if completionRecord?.id == record.id {
            completionRecord = exportHistory.first(where: { $0.id == record.id }) ?? completionRecord
        }
        if action == .bundleRevealed {
            lastBundleURL = url
            lastBundleDisplayInfoStorage = record.displayInfo
        }
    }

    private func recordEvent(
        _ action: SupportWorkflowEventAction,
        severity: ObservabilitySeverity = .info,
        extraMetadata: [String: String] = [:]
    ) async {
        guard let eventRecorder else { return }
        var metadata = [
            "source": "diagnostics",
            "issueType": issueType.rawValue,
            "hasEnhancedDiagnostics": currentConsent.hasEnhancedCollection ? "true" : "false",
            "filledFieldCount": String(filledFieldCount)
        ]
        extraMetadata.forEach { metadata[$0.key] = $0.value }
        let event = ObservabilityEvent(
            severity: severity,
            subsystem: .support,
            operation: action.operation,
            message: action.message,
            metadata: metadata
        )
        await eventRecorder(event)
    }
}
