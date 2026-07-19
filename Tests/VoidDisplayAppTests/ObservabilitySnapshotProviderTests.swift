@testable import VoidDisplayApp
@testable import VoidDisplayFoundation
@testable import VoidDisplayRuntime
@testable import VoidDisplayObservability
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct ObservabilitySnapshotProviderTests {
    @Test func snapshotProviderUsesRuntimeKeyAndEncodesSnapshot() async throws {
        let runtime = DisplayRuntime(
            catalogProvider: SnapshotCatalogProvider(
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

    @Test func runtimeSnapshotProviderPublishesConsumerStateWithDefaultRedaction() async throws {
        let sensitiveInputs = [
            "share-id-raw-fixture-42",
            "viewer-client-secret-42",
            "https://10.0.0.8:8080/display/secret",
            "10.0.0.8",
            "\(NSHomeDirectory())/Desktop/capture.txt",
            "Confidential Window Caption",
            "typed user search text",
            "visible desktop pixels"
        ]
        let runtime = DisplayRuntime(captureIntentCommander: ApplyingCaptureIntentCommander())
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 888)
        let outcome = await runtime.attachLANWebViewConsumer(
            surfaceIdentity: surfaceIdentity,
            owner: .init(source: .sharingService, redactedLabel: sensitiveInputs.joined(separator: " ")),
            demand: DisplayRuntimeConsumerDemand(
                sourcePixelSize: .init(width: 3840, height: 2160),
                preferredPixelSize: .init(width: 1920, height: 1080),
                sourceFramesPerSecond: 60,
                preferredFramesPerSecond: 30,
                capturesCursor: true,
                powerProfile: .smooth,
                latencyPreference: .realtime,
                activeViewerCount: 2
            )
        )
        guard case let .attached(lease, _) = outcome else {
            Issue.record("Expected consumer lease attach")
            return
        }
        let provider = AnyObservabilitySnapshotProvider(DisplayRuntimeSnapshotProvider(runtime: runtime))

        let section = try await provider.makeSnapshot()
        let snapshot = try section.decode(DisplayRuntimeSnapshot.self)
        let sectionJSON = String(
            decoding: try ObservabilityCodec.encode(section),
            as: UTF8.self
        )

        #expect(provider.key == "runtime")
        #expect(snapshot.consumerLeases.first?.id == lease.id)
        #expect(snapshot.consumerLeases.first?.kind == .lanWebView)
        #expect(snapshot.consumerLeases.first?.ownerSource == .sharingService)
        #expect(snapshot.aggregatedDemands.first?.activeViewerCount == 2)
        #expect(snapshot.aggregatedDemands.first?.capturesCursor == true)
        #expect(snapshot.effectiveCaptureIntents.first?.intent.kind == .capture)
        #expect(snapshot.consumerSummary.leaseCountsByKind == [
            .init(kind: .lanWebView, activeCount: 1, totalCount: 1)
        ])
        #expect(sectionJSON.contains("redactedLabel") == false)
        for sensitiveInput in sensitiveInputs {
            #expect(sectionJSON.contains(sensitiveInput) == false)
        }
    }
}

@MainActor
private final class ApplyingCaptureIntentCommander: DisplayRuntimeCaptureIntentCommanding {
    func applyPreviewCaptureIntent(
        _ intent: DisplayRuntimeCaptureIntent
    ) async -> DisplayRuntimeCaptureIntentApplyResult {
        .applied(revision: intent.revision)
    }

    func applyLANWebViewCaptureIntent(
        _ intent: DisplayRuntimeCaptureIntent
    ) async -> DisplayRuntimeCaptureIntentApplyResult {
        .applied(revision: intent.revision)
    }
}

@MainActor
private struct SnapshotCatalogProvider: DisplayRuntimeCatalogProviding {
    let snapshot: DisplayRuntimeCatalogSnapshot

    func makeCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot {
        snapshot
    }
}
