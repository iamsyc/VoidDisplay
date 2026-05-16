@testable import VoidDisplayRuntime
@testable import VoidDisplayObservability
import Foundation
import Testing

@MainActor
struct ObservabilitySnapshotProviderTests {
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
        let runtime = DisplayRuntime()
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 888)
        let lease = await runtime.attachLANWebViewConsumer(
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
        ).lease
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
