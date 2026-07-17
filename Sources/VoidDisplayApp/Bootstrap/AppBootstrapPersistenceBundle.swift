import Foundation
import VoidDisplayCapture
import VoidDisplayFoundation
import VoidDisplayObservability
import VoidDisplaySupport

@MainActor
struct AppBootstrapPersistenceBundle {
    let environment: [String: String]
    let context: PersistenceContext
    let capturePerformancePreferences: CapturePerformancePreferences
    let observability: ObservabilityCenter
    let feedbackController: AppSettingsFeedbackController
}

extension AppBootstrap {
    static func makePersistenceBundle(
        configuration: AppBootstrapConfiguration
    ) -> AppBootstrapPersistenceBundle {
        var environment = ProcessInfo.processInfo.environment
        if configuration.preview {
            environment[PersistenceContext.uiTestModeEnvironmentKey] = "1"
        }
        if isRunningInsideTestBundle() {
            environment[PersistenceContext.persistenceModeEnvironmentKey] = PersistenceContext.testIsolatedModeValue
        }

        let context = PersistenceContext.resolve(environment: environment)
        let capturePerformancePreferences = CapturePerformancePreferences(defaults: context.userDefaults)
        let sanitizer = ObservabilitySanitizer()
        let observability = ObservabilityCenter(
            eventStore: EventStore(directoryURL: context.observabilityEventsDirectoryURL),
            issueStore: IssueStore(fileURL: context.observabilityIssuesURL),
            snapshotWriter: AgentSnapshotWriter(
                currentStateURL: context.observabilityCurrentStateURL,
                healthSummaryURL: context.observabilityHealthSummaryURL,
                recentEventsURL: context.observabilityRecentEventsURL
            ),
            exporter: FeedbackBundleExporter(
                exportsDirectoryURL: context.observabilityExportsDirectoryURL,
                virtualDisplayConfigsURL: context.virtualDisplayConfigsURL,
                displayShareMappingsURL: context.displayShareIDMappingsURL,
                sanitizer: sanitizer
            ),
            transport: LocalExportTransport(),
            observabilityDirectoryURL: context.observabilityDirectoryURL,
            sanitizer: sanitizer
        )
        let supportHistoryStore = SupportHistoryStore(
            historyFileURL: context.observabilityDirectoryURL
                .appendingPathComponent("support-history.json", isDirectory: false)
        )
        let feedbackController = makeFeedbackController(
            context: context,
            historyStore: supportHistoryStore
        )

        return AppBootstrapPersistenceBundle(
            environment: environment,
            context: context,
            capturePerformancePreferences: capturePerformancePreferences,
            observability: observability,
            feedbackController: feedbackController
        )
    }

    private static func makeFeedbackController(
        context: PersistenceContext,
        historyStore: SupportHistoryStore
    ) -> AppSettingsFeedbackController {
        guard let failureMessage = UITestRuntime.feedbackExportFailureMessage else {
            return AppSettingsFeedbackController(
                defaults: context.userDefaults,
                historyStore: historyStore
            )
        }
        return AppSettingsFeedbackController(
            defaults: context.userDefaults,
            historyStore: historyStore,
            exportAction: { _, _ in
                throw UITestFeedbackExportFailure(message: failureMessage)
            }
        )
    }

    private static func isRunningInsideTestBundle() -> Bool {
        if Bundle.main.bundleURL.pathExtension == "xctest" {
            return true
        }
        if CommandLine.arguments.contains(where: { $0.contains(".xctest") }) {
            return true
        }
        return Bundle.allBundles.contains { bundle in
            bundle.bundleURL.pathExtension == "xctest"
        }
    }
}
