@testable import VoidDisplayObservability
@testable import VoidDisplayTestingSupport
import Foundation

@MainActor
final class ControllerRecordingHook: ObservabilitySnapshotProvider {
    let key = "controller-recording-test"
    var onSnapshot: (Int) -> Void = { _ in }
    private var callCount = 0

    func makeSnapshot() -> [String: Int] {
        callCount += 1
        onSnapshot(callCount)
        return ["callCount": callCount]
    }
}

@MainActor
func makeControllerRecordingFixture() async throws -> (
    center: ObservabilityCenter,
    hook: ControllerRecordingHook,
    directory: URL
) {
    let directory = try makeTemporaryDirectory(prefix: "controller-recording")
    let sanitizer = ObservabilitySanitizer()
    let center = ObservabilityCenter(
        eventStore: EventStore(directoryURL: directory.appendingPathComponent("events")),
        issueStore: IssueStore(fileURL: directory.appendingPathComponent("issues.json")),
        snapshotWriter: AgentSnapshotWriter(
            currentStateURL: directory.appendingPathComponent("state.json"),
            healthSummaryURL: directory.appendingPathComponent("health.json"),
            recentEventsURL: directory.appendingPathComponent("recent.ndjson"),
            debounceDuration: .zero
        ),
        exporter: FeedbackBundleExporter(
            exportsDirectoryURL: directory.appendingPathComponent("exports"),
            virtualDisplayConfigsURL: directory.appendingPathComponent("virtual-displays.json"),
            displayShareMappingsURL: directory.appendingPathComponent("share-mappings.json"),
            sanitizer: sanitizer
        ),
        observabilityDirectoryURL: directory,
        sanitizer: sanitizer
    )
    let hook = ControllerRecordingHook()
    await center.registerSnapshotProvider(AnyObservabilitySnapshotProvider(hook))
    return (center, hook, directory)
}
