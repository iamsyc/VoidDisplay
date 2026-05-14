@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeDemandAggregationTests {
    @Test func monitorAndLanWebViewAggregateToMixedRealtimeSourceQuality() throws {
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 101, isMain: true)),
            captureIntentCommander: FakeCaptureIntentCommander()
        )
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 101)

        _ = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .monitor,
            owner: .init(source: .localUI),
            demand: aggregateDemand(width: 2560, height: 1440, capturesCursor: false, activeViewerCount: 0)
        )
        _ = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .lanWebView,
            owner: .init(source: .sharingService),
            demand: aggregateDemand(
                width: 3840,
                height: 2160,
                capturesCursor: true,
                powerProfile: .smooth,
                activeViewerCount: 2
            )
        )

        let aggregate = try #require(runtime.currentAggregatedDemandSnapshot().first)
        #expect(aggregate.qualityProfile == .mixed)
        #expect(aggregate.powerProfile == .smooth)
        #expect(aggregate.latencyPreference == .realtime)
        #expect(aggregate.effectivePixelSize == .init(width: 3840, height: 2160))
        #expect(aggregate.effectiveFramesPerSecond == 60)
        #expect(aggregate.capturesCursor == true)
        #expect(aggregate.activeViewerCount == 2)
        #expect(aggregate.permitsExplicitDowngrade == false)
    }

    @Test func automaticAndSmoothPreserveSourceResolutionAndFrameRate() throws {
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 102, isMain: true)),
            captureIntentCommander: FakeCaptureIntentCommander()
        )
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 102)

        _ = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .lanWebView,
            owner: .init(source: .sharingService),
            demand: aggregateDemand(
                width: 3840,
                height: 2160,
                preferredWidth: 1280,
                preferredHeight: 720,
                preferredFramesPerSecond: 24,
                powerProfile: .smooth,
                activeViewerCount: 1
            )
        )

        let aggregate = try #require(runtime.currentAggregatedDemandSnapshot().first)
        #expect(aggregate.effectivePixelSize == .init(width: 3840, height: 2160))
        #expect(aggregate.effectiveFramesPerSecond == 60)
        #expect(aggregate.permitsExplicitDowngrade == false)
    }

    @Test func powerEfficientAllowsExplicitDowngrade() throws {
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 103, isMain: true)),
            captureIntentCommander: FakeCaptureIntentCommander()
        )
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 103)

        _ = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .lanWebView,
            owner: .init(source: .sharingService),
            demand: aggregateDemand(
                width: 3840,
                height: 2160,
                preferredWidth: 1280,
                preferredHeight: 720,
                preferredFramesPerSecond: 30,
                powerProfile: .powerEfficient,
                activeViewerCount: 1
            )
        )

        let aggregate = try #require(runtime.currentAggregatedDemandSnapshot().first)
        #expect(aggregate.powerProfile == .powerEfficient)
        #expect(aggregate.effectivePixelSize == .init(width: 1280, height: 720))
        #expect(aggregate.effectiveFramesPerSecond == 30)
        #expect(aggregate.permitsExplicitDowngrade == true)
    }

    @Test func diagnosticsRecorderCannotDowngradeActiveLanWebViewQuality() throws {
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 104, isMain: true)),
            captureIntentCommander: FakeCaptureIntentCommander()
        )
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 104)

        _ = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .lanWebView,
            owner: .init(source: .sharingService),
            demand: aggregateDemand(
                width: 3840,
                height: 2160,
                preferredWidth: 3840,
                preferredHeight: 2160,
                preferredFramesPerSecond: 60,
                powerProfile: .automatic,
                activeViewerCount: 1
            )
        )
        _ = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .diagnosticsRecorder,
            owner: .init(source: .diagnostics),
            demand: aggregateDemand(
                width: 3840,
                height: 2160,
                preferredWidth: 1280,
                preferredHeight: 720,
                preferredFramesPerSecond: 15,
                capturesCursor: true,
                powerProfile: .powerEfficient,
                latencyPreference: .recording
            )
        )

        let aggregate = try #require(runtime.currentAggregatedDemandSnapshot().first)
        #expect(aggregate.qualityProfile == .mixed)
        #expect(aggregate.powerProfile == .automatic)
        #expect(aggregate.latencyPreference == .realtime)
        #expect(aggregate.effectivePixelSize == .init(width: 3840, height: 2160))
        #expect(aggregate.effectiveFramesPerSecond == 60)
        #expect(aggregate.capturesCursor == true)
        #expect(aggregate.permitsExplicitDowngrade == false)
    }

    @Test func diagnosticsRecorderAndMonitorPreserveRealtimeSourceQualityAndCursorDemand() throws {
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 106, isMain: true)),
            captureIntentCommander: FakeCaptureIntentCommander()
        )
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 106)

        _ = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .monitor,
            owner: .init(source: .localUI),
            demand: aggregateDemand(
                width: 2560,
                height: 1440,
                capturesCursor: false,
                powerProfile: .automatic,
                latencyPreference: .realtime
            )
        )
        _ = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .diagnosticsRecorder,
            owner: .init(source: .diagnostics),
            demand: aggregateDemand(
                width: 2560,
                height: 1440,
                preferredWidth: 1280,
                preferredHeight: 720,
                preferredFramesPerSecond: 15,
                capturesCursor: true,
                powerProfile: .powerEfficient,
                latencyPreference: .recording
            )
        )

        let aggregate = try #require(runtime.currentAggregatedDemandSnapshot().first)
        #expect(aggregate.qualityProfile == .mixed)
        #expect(aggregate.powerProfile == .automatic)
        #expect(aggregate.latencyPreference == .realtime)
        #expect(aggregate.effectivePixelSize == .init(width: 2560, height: 1440))
        #expect(aggregate.effectiveFramesPerSecond == 60)
        #expect(aggregate.capturesCursor == true)
        #expect(aggregate.permitsExplicitDowngrade == false)
    }

    @Test func cursorDemandUsesOrSemantics() throws {
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 105, isMain: true)),
            captureIntentCommander: FakeCaptureIntentCommander()
        )
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 105)

        _ = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .monitor,
            owner: .init(source: .localUI),
            demand: aggregateDemand(width: 1920, height: 1080, capturesCursor: false)
        )
        _ = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .diagnosticsRecorder,
            owner: .init(source: .diagnostics),
            demand: aggregateDemand(
                width: 1920,
                height: 1080,
                capturesCursor: true,
                powerProfile: .automatic,
                latencyPreference: .recording
            )
        )

        let aggregate = try #require(runtime.currentAggregatedDemandSnapshot().first)
        #expect(aggregate.capturesCursor == true)
    }
}

private func aggregateDemand(
    width: Int,
    height: Int,
    preferredWidth: Int? = nil,
    preferredHeight: Int? = nil,
    sourceFramesPerSecond: Int = 60,
    preferredFramesPerSecond: Int? = nil,
    capturesCursor: Bool = false,
    powerProfile: DisplayRuntimeCapturePowerProfile = .automatic,
    latencyPreference: DisplayRuntimeConsumerLatencyPreference = .realtime,
    activeViewerCount: Int = 0
) -> DisplayRuntimeConsumerDemand {
    let preferredPixelSize: DisplayRuntimePixelSize?
    if let preferredWidth, let preferredHeight {
        preferredPixelSize = .init(width: preferredWidth, height: preferredHeight)
    } else {
        preferredPixelSize = nil
    }

    return DisplayRuntimeConsumerDemand(
        sourcePixelSize: .init(width: width, height: height),
        preferredPixelSize: preferredPixelSize,
        sourceFramesPerSecond: sourceFramesPerSecond,
        preferredFramesPerSecond: preferredFramesPerSecond,
        capturesCursor: capturesCursor,
        powerProfile: powerProfile,
        latencyPreference: latencyPreference,
        activeViewerCount: activeViewerCount
    )
}
