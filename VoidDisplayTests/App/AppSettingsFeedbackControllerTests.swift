import Foundation
import Testing
@testable import VoidDisplay

@MainActor
struct AppSettingsFeedbackControllerTests {
    @Test func exportSupportBundleMarksCompletionAndTracksLatestPath() async {
        let expectedURL = URL(fileURLWithPath: "/tmp/support-bundle.zip")
        let controller = AppSettingsFeedbackController(
            exportAction: { draft, consent in
                #expect(draft.happened == "Black screen after launch")
                #expect(consent.includeRelatedConfigSnapshots)
                return expectedURL
            },
            summaryAction: { _ in "summary" }
        )
        controller.happened = "Black screen after launch"
        controller.includeRelatedConfigSnapshots = true

        await controller.exportSupportBundle()

        #expect(controller.exportCompleted)
        #expect(controller.canRevealLastBundle)
        #expect(controller.lastBundleDisplayPath == ObservabilitySanitizer().sanitize(fileURL: expectedURL))
    }

    @Test func exportSupportBundleFailurePresentsAlert() async {
        let controller = AppSettingsFeedbackController(
            exportAction: { _, _ in
                throw NSError(domain: "test", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "Disk full."
                ])
            },
            errorMessageProvider: { _ in "Disk full." }
        )

        await controller.exportSupportBundle()

        #expect(controller.exportCompleted == false)
        #expect(controller.alert?.message == "Disk full.")
    }

    @Test func revealAndCopyRemainSafeWithoutExportedBundle() async {
        var revealCount = 0
        var copiedSummary: String?
        let controller = AppSettingsFeedbackController(
            revealAction: { _ in revealCount += 1 },
            copyAction: { copiedSummary = $0 },
            summaryAction: { _ in "Feedback summary" }
        )

        controller.revealLastBundle()
        await controller.copySummary()

        #expect(revealCount == 0)
        #expect(copiedSummary == "Feedback summary")
        #expect(controller.canRevealLastBundle == false)
    }

    @Test func applyFixturePopulatesDraftAndConsent() {
        let controller = AppSettingsFeedbackController()
        let fixture = SettingsFeedbackFixture(
            draft: FeedbackDraft(
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

        #expect(controller.happened == "black screen")
        #expect(controller.reproductionSteps == "open settings")
        #expect(controller.expectedResult == "content appears")
        #expect(controller.includeUnifiedLogSummary)
        #expect(controller.includeCrashReportExcerpt == false)
        #expect(controller.includeRelatedConfigSnapshots)
    }

    @Test func restoreLastExportedBundleLoadsExistingArchivePath() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "feedback-controller-restore")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let exportsURL = tempURL.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsURL, withIntermediateDirectories: true)
        let bundleURL = exportsURL.appendingPathComponent("support-bundle-20260419-120000.zip")
        try Data("bundle".utf8).write(to: bundleURL)

        let observability = makeFeedbackControllerObservability(
            rootURL: tempURL,
            exportsDirectoryURL: exportsURL
        )
        let controller = AppSettingsFeedbackController()

        await controller.restoreLastExportedBundle(from: observability)

        #expect(controller.canRevealLastBundle)
        #expect(controller.lastBundleDisplayPath == ObservabilitySanitizer().sanitize(fileURL: bundleURL))
    }
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
            appSupportRootURL: rootURL,
            virtualDisplayConfigsURL: rootURL.appendingPathComponent("virtual-displays.json"),
            displayShareMappingsURL: rootURL.appendingPathComponent("display-share-id-mappings.json"),
            sanitizer: sanitizer
        ),
        transport: LocalExportTransport(),
        observabilityDirectoryURL: rootURL,
        sanitizer: sanitizer
    )
}
