@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeObservabilityTests {
    @Test func snapshotProviderUsesRuntimeKeyAndEncodesSnapshot() async throws {
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(
                snapshot: .init(
                    hasScreenCapturePermission: false,
                    lastPreflightPermission: false,
                    lastRequestPermission: false,
                    isLoadingDisplays: false,
                    hasLoadError: true,
                    lastLoadError: .init(
                        domain: "ScreenCapture",
                        code: 1,
                        hasDescription: true,
                        hasFailureReason: false,
                        hasRecoverySuggestion: false
                    ),
                    loadedDisplays: [],
                    topologySignature: []
                )
            )
        )
        let provider = DisplayRuntimeSnapshotProvider(runtime: runtime)
        let erased = AnyObservabilitySnapshotProvider(provider)

        let json = try await erased.makeSnapshot()
        let snapshot = try json.decode(DisplayRuntimeSnapshot.self)

        #expect(erased.key == "runtime")
        #expect(snapshot.catalog.hasScreenCapturePermission == false)
        #expect(snapshot.catalog.lastLoadError?.domain == "ScreenCapture")
    }
    @Test func observabilityCenterIncludesRuntimeSection() async throws {
        let isolationID = "display-runtime-\(UUID().uuidString)"
        let environment = [
            PersistenceContext.persistenceModeEnvironmentKey: PersistenceContext.testIsolatedModeValue,
            PersistenceContext.testIsolationIDEnvironmentKey: isolationID,
            PersistenceContext.xCTestConfigurationEnvironmentKey: "tests.xctest"
        ]
        let persistenceContext = PersistenceContext.resolve(environment: environment)
        defer { try? FileManager.default.removeItem(at: persistenceContext.appSupportRootURL) }

        let sanitizer = ObservabilitySanitizer()
        let observability = ObservabilityCenter(
            eventStore: EventStore(directoryURL: persistenceContext.observabilityEventsDirectoryURL),
            issueStore: IssueStore(fileURL: persistenceContext.observabilityIssuesURL),
            snapshotWriter: AgentSnapshotWriter(
                currentStateURL: persistenceContext.observabilityCurrentStateURL,
                healthSummaryURL: persistenceContext.observabilityHealthSummaryURL,
                recentEventsURL: persistenceContext.observabilityRecentEventsURL,
                debounceDuration: .zero
            ),
            exporter: FeedbackBundleExporter(
                exportsDirectoryURL: persistenceContext.observabilityExportsDirectoryURL,
                virtualDisplayConfigsURL: persistenceContext.virtualDisplayConfigsURL,
                displayShareMappingsURL: persistenceContext.displayShareIDMappingsURL,
                sanitizer: sanitizer
            ),
            transport: LocalExportTransport(),
            observabilityDirectoryURL: persistenceContext.observabilityDirectoryURL,
            sanitizer: sanitizer
        )
        let runtime = DisplayRuntime()

        await observability.registerSnapshotProvider(
            AnyObservabilitySnapshotProvider(DisplayRuntimeSnapshotProvider(runtime: runtime))
        )
        await observability.refreshSnapshot(reason: .manualDiagnosticsRefresh)
        let diagnostics = await observability.diagnosticsSnapshot()

        let runtimeSection = try #require(diagnostics.state.sections["runtime"])
        let snapshot = try runtimeSection.decode(DisplayRuntimeSnapshot.self)
        #expect(snapshot == .empty)
    }
}
