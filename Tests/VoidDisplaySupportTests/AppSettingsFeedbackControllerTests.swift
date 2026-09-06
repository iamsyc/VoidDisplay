@testable import VoidDisplaySupport
@testable import VoidDisplayObservability
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct AppSettingsFeedbackControllerTests {
    @Test func enhancedDiagnosticsDefaultToEnabled() {
        let controller = AppSettingsFeedbackController()

        #expect(controller.includeUnifiedLogSummary)
        #expect(controller.includeCrashReportExcerpt)
        #expect(controller.includeRelatedConfigSnapshots)
    }

    @Test func exportSupportBundleRejectsEmptyDraft() async {
        let recorder = EventRecorder()
        let controller = AppSettingsFeedbackController(
            eventRecorder: { recorder.record($0) },
            exportAction: { _, _ in
                Issue.record("exportAction should not run for an empty draft")
                return URL(fileURLWithPath: "/tmp/unexpected.zip")
            }
        )

        await controller.exportSupportBundle()

        #expect(controller.completionRecord == nil)
        #expect(controller.validationMessage == String(localized: "Please fill in at least one problem field."))
        let event = recorder.events.last
        #expect(event?.subsystem == .support)
        #expect(event?.severity == .info)
        #expect(event?.operation == SupportWorkflowEventAction.validationFailed.operation)
        #expect(event?.metadata["filledFieldCount"] == "0")
    }

    @Test func unchangedDraftWritePreservesValidationUntilActualEdit() async {
        let controller = AppSettingsFeedbackController(
            exportAction: { _, _ in
                Issue.record("exportAction should not run for an empty draft")
                return URL(fileURLWithPath: "/tmp/unexpected.zip")
            }
        )

        await controller.exportSupportBundle()
        let validationMessage = controller.validationMessage
        #expect(validationMessage != nil)

        controller.happened = ""

        #expect(controller.validationMessage == validationMessage)

        controller.happened = "Preview stopped unexpectedly."

        #expect(controller.validationMessage == nil)
    }

    @Test func applyRecommendedDiagnosticsUsesCurrentIssueTypePresentation() {
        let controller = AppSettingsFeedbackController()
        controller.issueType = .virtualDisplayFailure

        controller.applyRecommendedDiagnostics()

        #expect(controller.includeUnifiedLogSummary)
        #expect(controller.includeCrashReportExcerpt == false)
        #expect(controller.includeRelatedConfigSnapshots)
        #expect(controller.usesRecommendedDiagnostics)
    }

    @Test func exportSupportBundleAcceptsAnyProblemField() async {
        var exportedDraft: FeedbackDraft?
        let controller = AppSettingsFeedbackController(
            exportAction: { draft, _ in
                exportedDraft = draft
                return URL(fileURLWithPath: "/tmp/support-bundle-optional-field.zip")
            }
        )
        controller.reproductionSteps = "1. Launch the app. 2. Start sharing."

        await controller.exportSupportBundle()

        #expect(exportedDraft?.happened.isEmpty == true)
        #expect(exportedDraft?.reproductionSteps == "1. Launch the app. 2. Start sharing.")
        #expect(controller.completionRecord != nil)
    }

    @Test func exportSupportBundleMarksCompletionAndPersistsHistory() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "feedback-controller-export")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let exportsURL = tempURL.appendingPathComponent("exports", isDirectory: true)
        let historyStore = SupportHistoryStore(
            historyFileURL: tempURL.appendingPathComponent("support-history.json")
        )
        let expectedURL = exportsURL.appendingPathComponent("support-bundle-20260420-120000.zip")
        let controller = AppSettingsFeedbackController(
            historyStore: historyStore,
            exportAction: { draft, consent in
                #expect(draft.issueType == .blackScreen)
                #expect(draft.happened == "Black screen after launch")
                #expect(consent.includeRelatedConfigSnapshots)
                try FileManager.default.createDirectory(
                    at: exportsURL,
                    withIntermediateDirectories: true
                )
                try Data("bundle".utf8).write(to: expectedURL)
                return expectedURL
            },
            summaryAction: { _ in "summary" }
        )
        controller.issueType = .blackScreen
        controller.happened = "Black screen after launch"
        controller.includeRelatedConfigSnapshots = true

        await controller.exportSupportBundle()

        #expect(controller.completionRecord?.issueType == .blackScreen)
        #expect(controller.latestExportRecord?.bundleFileName == "support-bundle-20260420-120000.zip")
        #expect(controller.lastBundleDisplayPath == ObservabilitySanitizer().sanitize(fileURL: expectedURL))
        #expect(controller.exportHistory.count == 1)
        #expect(controller.exportHistory.first?.draftPreview.contains(String(localized: "What happened:")) == true)

        let persisted = historyStore.loadRecords()
        #expect(persisted.count == 1)
        #expect(persisted.first?.bundleFileName == "support-bundle-20260420-120000.zip")
    }

    @Test func exportSupportBundleFailureSetsAlertState() async {
        let controller = AppSettingsFeedbackController(
            exportAction: { _, _ in
                throw NSError(
                    domain: "VoidDisplayTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Injected export failure"]
                )
            },
            errorMessageProvider: { ($0 as NSError).localizedDescription }
        )
        controller.happened = "Sharing failed immediately"

        await controller.exportSupportBundle()

        #expect(controller.completionRecord == nil)
        #expect(controller.alert?.title == String(localized: "Export Failed"))
        #expect(controller.alert?.message == "Injected export failure")
    }

    @Test func concurrentExportRequestsCollapseIntoSingleExport() async {
        var invocationCount = 0
        let controller = AppSettingsFeedbackController(
            exportAction: { _, _ in
                invocationCount += 1
                try await Task.sleep(for: .milliseconds(50))
                return URL(fileURLWithPath: "/tmp/support-bundle-single-flight.zip")
            }
        )
        controller.happened = "Sharing failed"

        async let first: Void = controller.exportSupportBundle()
        async let second: Void = controller.exportSupportBundle()
        _ = await (first, second)

        #expect(invocationCount == 1)
        #expect(controller.isExporting == false)
    }

    @Test func copyAndRevealUpdateHistoryTimestamps() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "feedback-controller-history-actions")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let exportsURL = tempURL.appendingPathComponent("exports", isDirectory: true)
        let historyStore = SupportHistoryStore(
            historyFileURL: tempURL.appendingPathComponent("support-history.json")
        )
        let bundleURL = exportsURL.appendingPathComponent("support-bundle-20260420-121500.zip")
        var copiedSummary: String?
        var revealedURLs: [URL] = []
        let controller = AppSettingsFeedbackController(
            historyStore: historyStore,
            exportAction: { _, _ in
                try FileManager.default.createDirectory(
                    at: exportsURL,
                    withIntermediateDirectories: true
                )
                try Data("bundle".utf8).write(to: bundleURL)
                return bundleURL
            },
            revealAction: { revealedURLs.append($0) },
            copyAction: { copiedSummary = $0 },
            summaryAction: { _ in "submission summary" }
        )
        controller.issueType = .performanceIssue
        controller.happened = "Frames drop while sharing"

        await controller.exportSupportBundle()
        await controller.copySummary()
        await controller.revealLastBundle()

        #expect(copiedSummary == "submission summary")
        #expect(revealedURLs == [bundleURL])
        #expect(controller.exportHistory.first?.summaryCopiedAt != nil)
        #expect(controller.exportHistory.first?.revealedAt != nil)
    }

    @Test func startNewFeedbackClearsDraftAndKeepsHistory() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "feedback-controller-new-feedback")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let isolatedDefaults = makeIsolatedDefaults(prefix: "feedback-controller-new-feedback")
        defer { isolatedDefaults.defaults.removePersistentDomain(forName: isolatedDefaults.suiteName) }

        let exportsURL = tempURL.appendingPathComponent("exports", isDirectory: true)
        let historyStore = SupportHistoryStore(
            historyFileURL: tempURL.appendingPathComponent("support-history.json")
        )
        let bundleURL = exportsURL.appendingPathComponent("support-bundle-20260420-123000.zip")
        let controller = AppSettingsFeedbackController(
            defaults: isolatedDefaults.defaults,
            historyStore: historyStore,
            exportAction: { _, _ in
                try FileManager.default.createDirectory(
                    at: exportsURL,
                    withIntermediateDirectories: true
                )
                try Data("bundle".utf8).write(to: bundleURL)
                return bundleURL
            }
        )
        controller.issueType = .cannotShare
        controller.happened = "Sharing disconnects"

        await controller.exportSupportBundle()
        await controller.startNewFeedback()

        #expect(controller.issueType == .other)
        #expect(controller.happened.isEmpty)
        #expect(controller.reproductionSteps.isEmpty)
        #expect(controller.expectedResult.isEmpty)
        #expect(controller.includeUnifiedLogSummary)
        #expect(controller.includeCrashReportExcerpt)
        #expect(controller.includeRelatedConfigSnapshots)
        #expect(controller.completionRecord == nil)
        #expect(controller.exportHistory.count == 1)
        let storedSnapshot = SupportDraftStore(defaults: isolatedDefaults.defaults).load()
        #expect(storedSnapshot.feedbackDraft.isEmpty)
        #expect(storedSnapshot.includeUnifiedLogSummary)
        #expect(storedSnapshot.includeCrashReportExcerpt)
        #expect(storedSnapshot.includeRelatedConfigSnapshots)
    }

    @Test func applyFixturePopulatesDraftConsentAndIssueType() {
        let controller = AppSettingsFeedbackController()
        let fixture = SettingsFeedbackFixture(
            draft: FeedbackDraft(
                issueType: .virtualDisplayFailure,
                happened: "black screen",
                reproductionSteps: "open settings",
                expectedResult: "content appears"
            ),
            consent: FeedbackConsent(
                includeUnifiedLogSummary: true,
                includeCrashReportExcerpt: false,
                includeRelatedConfigSnapshots: true
            )
        )

        controller.applyFixture(fixture)

        #expect(controller.issueType == .virtualDisplayFailure)
        #expect(controller.happened == "black screen")
        #expect(controller.reproductionSteps == "open settings")
        #expect(controller.expectedResult == "content appears")
        #expect(controller.includeUnifiedLogSummary)
        #expect(controller.includeCrashReportExcerpt == false)
        #expect(controller.includeRelatedConfigSnapshots)
    }

    @Test func prepareRestoresDraftAndHistoryState() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "feedback-controller-prepare")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let isolatedDefaults = makeIsolatedDefaults(prefix: "feedback-controller-prepare")
        defer { isolatedDefaults.defaults.removePersistentDomain(forName: isolatedDefaults.suiteName) }

        let exportsURL = tempURL.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsURL, withIntermediateDirectories: true)
        let bundleURL = exportsURL.appendingPathComponent("support-bundle-20260420-124500.zip")
        try Data("bundle".utf8).write(to: bundleURL)

        SupportDraftStore(defaults: isolatedDefaults.defaults).save(
            SupportDraftSnapshot(
                issueType: .performanceIssue,
                happened: "App is slow",
                reproductionSteps: "Start sharing",
                expectedResult: "Smooth frame rate",
                includeUnifiedLogSummary: true
            )
        )

        let historyStore = SupportHistoryStore(
            historyFileURL: tempURL.appendingPathComponent("support-history.json")
        )
        try historyStore.saveRecords([
            SupportExportRecord(
                exportedAt: Date(timeIntervalSince1970: 1_713_613_500),
                issueType: .performanceIssue,
                bundleFileName: bundleURL.lastPathComponent,
                sanitizedBundlePath: ObservabilitySanitizer().sanitize(fileURL: bundleURL),
                draftPreview: "What happened:\nApp is slow"
            )
        ])

        let controller = AppSettingsFeedbackController(
            defaults: isolatedDefaults.defaults,
            historyStore: historyStore
        )
        let observability = makeFeedbackControllerObservability(
            rootURL: tempURL,
            exportsDirectoryURL: exportsURL
        )

        await controller.prepare(observability: observability)

        #expect(controller.issueType == .performanceIssue)
        #expect(controller.happened == "App is slow")
        #expect(controller.includeUnifiedLogSummary)
        #expect(controller.latestExportRecord?.bundleFileName == bundleURL.lastPathComponent)
        #expect(controller.completionRecord?.bundleFileName == bundleURL.lastPathComponent)
        #expect(controller.completionRecord != nil)
    }

    @Test func exportHistoryWriteFailureKeepsInMemoryCompletionState() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "feedback-controller-history-write-failure")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let exportsURL = tempURL.appendingPathComponent("exports", isDirectory: true)
        let historyFileURL = tempURL.appendingPathComponent("support-history.json")
        try FileManager.default.createDirectory(at: historyFileURL, withIntermediateDirectories: false)
        let bundleURL = exportsURL.appendingPathComponent("support-bundle-history-write-failure.zip")
        let controller = AppSettingsFeedbackController(
            historyStore: SupportHistoryStore(
                historyFileURL: historyFileURL
            ),
            exportAction: { _, _ in
                try FileManager.default.createDirectory(
                    at: exportsURL,
                    withIntermediateDirectories: true
                )
                try Data("bundle".utf8).write(to: bundleURL)
                return bundleURL
            }
        )
        controller.happened = "History write fails"

        await controller.exportSupportBundle()

        #expect(controller.completionRecord?.bundleFileName == bundleURL.lastPathComponent)
        #expect(controller.exportHistory.map(\.bundleFileName) == [bundleURL.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: historyFileURL.path))
    }

    @Test func exportRespectsOptedOutDiagnosticsAndKeepsFailedDraftForRetry() async throws {
        var attemptCount = 0
        var receivedConsents: [FeedbackConsent] = []
        let bundleURL = URL(fileURLWithPath: "/tmp/support-consent-retry.zip")
        let controller = AppSettingsFeedbackController(
            exportAction: { draft, consent in
                attemptCount += 1
                receivedConsents.append(consent)
                #expect(draft.happened == "Sharing stopped")
                if attemptCount == 1 {
                    throw NSError(domain: "support-tests", code: 1)
                }
                return bundleURL
            }
        )
        controller.happened = "  Sharing stopped  "
        controller.includeUnifiedLogSummary = false
        controller.includeCrashReportExcerpt = false
        controller.includeRelatedConfigSnapshots = false

        await controller.exportSupportBundle()

        #expect(controller.alert != nil)
        #expect(controller.isExporting == false)
        #expect(controller.exportHistory.isEmpty)
        #expect(controller.happened == "  Sharing stopped  ")
        await controller.exportSupportBundle()

        let optedOut = FeedbackConsent(
            includeUnifiedLogSummary: false,
            includeCrashReportExcerpt: false,
            includeRelatedConfigSnapshots: false
        )
        #expect(receivedConsents == [optedOut, optedOut])
        #expect(controller.alert == nil)
        #expect(controller.isExporting == false)
        #expect(controller.exportHistory.count == 1)
        #expect(controller.completionRecord?.bundleFileName == bundleURL.lastPathComponent)
    }

    @Test func restoredHistoryCopiesSavedSummaryAndRevealsOnlyExistingBundle() async throws {
        let root = try makeTemporaryDirectory(prefix: "support-history-actions")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = makeIsolatedDefaults(prefix: "support-history-actions")
        defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
        let bundleURL = root.appendingPathComponent("support-bundle.zip")
        try Data("bundle".utf8).write(to: bundleURL)
        let record = SupportExportRecord(
            exportedAt: Date(timeIntervalSince1970: 100), issueType: .other,
            bundleFileName: bundleURL.lastPathComponent,
            sanitizedBundlePath: ObservabilitySanitizer().sanitize(fileURL: bundleURL),
            draftPreview: "Saved problem"
        )
        let historyStore = SupportHistoryStore(historyFileURL: root.appendingPathComponent("history.json"))
        try historyStore.saveRecords([record])
        var copied: [String] = []
        var revealed: [URL] = []
        let actionDate = Date(timeIntervalSince1970: 200)
        let controller = AppSettingsFeedbackController(
            defaults: defaults.defaults, historyStore: historyStore,
            revealAction: { revealed.append($0) }, copyAction: { copied.append($0) },
            summaryAction: { _ in Issue.record("Restored history must use the saved summary"); return "unexpected" },
            dateProvider: { actionDate }
        )
        await controller.prepare(observability: makeFeedbackControllerObservability(rootURL: root, exportsDirectoryURL: root))
        controller.happened = "A new unexported draft"

        await controller.copySummary()
        await controller.revealHistoryBundle(recordID: record.id)

        #expect(copied == [record.historyCopyText])
        #expect(revealed == [bundleURL])
        let saved = try #require(historyStore.loadRecords().first)
        #expect(saved.summaryCopiedAt == actionDate)
        #expect(saved.revealedAt == actionDate)
        try FileManager.default.removeItem(at: bundleURL)
        await controller.revealHistoryBundle(recordID: record.id)
        await controller.copyHistorySummary(recordID: UUID())
        #expect(revealed.count == 1)
        #expect(copied.count == 1)
    }

    @Test func emptyGeneratedSummaryDoesNotReportCopySuccess() async {
        var copied: [String] = []
        let recorder = EventRecorder()
        let controller = AppSettingsFeedbackController(
            eventRecorder: { recorder.record($0) },
            exportAction: { _, _ in URL(fileURLWithPath: "/tmp/support-empty-summary.zip") },
            copyAction: { copied.append($0) }, summaryAction: { _ in "" }
        )
        controller.happened = "Sharing stopped"
        await controller.exportSupportBundle()
        #expect(controller.completionRecord != nil)

        await controller.copySummary()

        #expect(copied.isEmpty)
        #expect(controller.completionRecord?.summaryCopiedAt == nil)
        #expect(recorder.events.contains { $0.operation == SupportWorkflowEventAction.summaryCopied.operation } == false)
    }

    @Test func supportEventsUseSupportDomainAndMetadata() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "feedback-controller-events")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let recorder = EventRecorder()
        let bundleURL = tempURL.appendingPathComponent("support-bundle-20260420-130000.zip")
        let controller = AppSettingsFeedbackController(
            eventRecorder: { recorder.record($0) },
            exportAction: { _, _ in
                try Data("bundle".utf8).write(to: bundleURL)
                return bundleURL
            }
        )
        controller.issueType = .performanceIssue
        controller.happened = "Frames drop"
        controller.includeUnifiedLogSummary = true

        await controller.trackPageOpened()
        await controller.exportSupportBundle()

        let events = recorder.events
        #expect(events.count == 3)
        #expect(events[0].subsystem == .support)
        #expect(events[0].metadata["source"] == "diagnostics")
        #expect(events[0].metadata["issueType"] == SupportIssueType.performanceIssue.rawValue)
        #expect(events[0].metadata["hasEnhancedDiagnostics"] == "true")
        #expect(events[0].metadata["filledFieldCount"] == "1")
        #expect(events[2].metadata["bundleFileName"] == "support-bundle-20260420-130000.zip")
    }
}

@MainActor
private final class EventRecorder {
    private(set) var events: [ObservabilityEvent] = []

    func record(_ event: ObservabilityEvent) {
        events.append(event)
    }
}

private struct IsolatedDefaults {
    let suiteName: String
    let defaults: UserDefaults
}

private func makeIsolatedDefaults(prefix: String) -> IsolatedDefaults {
    let suiteName = "\(prefix).\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fatalError("Failed to create UserDefaults suite")
    }
    return IsolatedDefaults(suiteName: suiteName, defaults: defaults)
}

private func makeFeedbackControllerObservability(
    rootURL: URL,
    exportsDirectoryURL: URL
) -> ObservabilityCenter {
    let sanitizer = ObservabilitySanitizer()
    return ObservabilityCenter(
        eventStore: EventStore(directoryURL: rootURL.appendingPathComponent("events", isDirectory: true)),
        issueStore: IssueStore(fileURL: rootURL.appendingPathComponent("recent-issues.json")),
        snapshotWriter: AgentSnapshotWriter(
            currentStateURL: rootURL.appendingPathComponent("current-state.json"),
            healthSummaryURL: rootURL.appendingPathComponent("health-summary.json"),
            recentEventsURL: rootURL.appendingPathComponent("recent-events.ndjson")
        ),
        exporter: FeedbackBundleExporter(
            exportsDirectoryURL: exportsDirectoryURL,
            virtualDisplayConfigsURL: rootURL.appendingPathComponent("virtual-displays.json"),
            displayShareMappingsURL: rootURL.appendingPathComponent("display-share-id-mappings.json"),
            sanitizer: sanitizer
        ),
        observabilityDirectoryURL: rootURL,
        sanitizer: sanitizer
    )
}
