@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeConsumerLeaseTests {
    @Test func attachCreatesLeaseSnapshotAndCaptureIntent() {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 42)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 42, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )

        let lease = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .monitor,
            owner: .init(source: .localUI, redactedLabel: "monitor"),
            demand: sourceDemand(capturesCursor: true)
        )

        #expect(lease.surfaceIdentity == surfaceIdentity)
        #expect(lease.surfaceEpoch == .initial)
        #expect(lease.resolvedDisplayID == 42)
        #expect(lease.kind == .monitor)
        #expect(lease.state == .attached)
        #expect(lease.createdAt <= lease.updatedAt)
        #expect(runtime.currentConsumerLeaseSnapshot().map(\.id) == [lease.id])
        #expect(captureIntentCommander.intents.count == 1)
        #expect(captureIntentCommander.intents.first?.kind == .capture)
        #expect(captureIntentCommander.intents.first?.reason == .attach)
        #expect(captureIntentCommander.intents.first?.revision.rawValue == 1)
        #expect(captureIntentCommander.intents.first?.aggregateDemand?.capturesCursor == true)
    }

    @Test func detachRemovesDemandAndEmitsDrainingIntentForLastLease() {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 51)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 51, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )
        let lease = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .monitor,
            owner: .init(source: .localUI),
            demand: sourceDemand(capturesCursor: false)
        )

        let releasedLease = runtime.detachConsumer(leaseID: lease.id)

        #expect(releasedLease?.state == .released)
        #expect(runtime.currentConsumerLeaseSnapshot().first?.state == .released)
        #expect(runtime.currentAggregatedDemandSnapshot().isEmpty)
        #expect(captureIntentCommander.intents.count == 2)
        #expect(captureIntentCommander.intents.last?.kind == .drain)
        #expect(captureIntentCommander.intents.last?.reason == .detach)
        #expect(captureIntentCommander.intents.last?.aggregateDemand == nil)
        #expect(captureIntentCommander.intents.last?.revision.rawValue == 2)
    }

    @Test func repeatedLanWebViewAttachReturnsExistingLeaseWithoutSecondIntent() {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 77)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 77, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )

        let firstLease = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .lanWebView,
            owner: .init(source: .sharingService, redactedLabel: "lan"),
            demand: sourceDemand(activeViewerCount: 1)
        )
        let secondLease = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .lanWebView,
            owner: .init(source: .sharingService, redactedLabel: "lan"),
            demand: sourceDemand(activeViewerCount: 3)
        )

        #expect(secondLease.id == firstLease.id)
        #expect(secondLease.createdAt == firstLease.createdAt)
        #expect(secondLease.updatedAt > firstLease.updatedAt)
        #expect(runtime.currentConsumerLeaseSnapshot().count == 1)
        #expect(runtime.currentConsumerLeaseSnapshot().first?.demand.activeViewerCount == 3)
        #expect(runtime.currentAggregatedDemandSnapshot().first?.activeLeaseIDs == [firstLease.id])
        #expect(runtime.currentAggregatedDemandSnapshot().first?.activeViewerCount == 3)
        #expect(captureIntentCommander.intents.count == 1)
    }

    @Test func surfaceEpochChangeStopsOldLeaseFromDrivingPreviousDisplayID() {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 88)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 88, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )
        let lease = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .monitor,
            owner: .init(source: .localUI),
            demand: sourceDemand()
        )

        let nextEpoch = runtime.advanceSurfaceEpoch(
            surfaceIdentity: surfaceIdentity,
            resolvedDisplayID: 89
        )

        let staleLease = runtime.currentConsumerLeaseSnapshot().first { $0.id == lease.id }
        #expect(nextEpoch.rawValue == 2)
        #expect(staleLease?.state == .restarting)
        #expect(staleLease?.lastFailureCode == "capture_intent_epoch_mismatch")
        #expect(runtime.currentAggregatedDemandSnapshot().isEmpty)
        #expect(captureIntentCommander.intents.last?.kind == .drain)
        #expect(captureIntentCommander.intents.last?.surfaceEpoch == nextEpoch)
        #expect(captureIntentCommander.intents.last?.resolvedDisplayID == 89)
        #expect(captureIntentCommander.intents.last?.resolvedDisplayID != lease.resolvedDisplayID)
    }

    @Test func staleApplyResultIsIgnoredAndCannotOverwriteNewerFailure() {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 91)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 91, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )
        _ = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .monitor,
            owner: .init(source: .localUI),
            demand: sourceDemand()
        )
        let firstRevision = captureIntentCommander.intents[0].revision
        _ = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .diagnosticsRecorder,
            owner: .init(source: .diagnostics),
            demand: diagnosticsDemand()
        )
        let secondRevision = captureIntentCommander.intents[1].revision

        let currentResult = runtime.recordCaptureIntentApplyResult(
            .init(
                revision: secondRevision,
                outcome: .failed,
                failureCode: "capture_intent_apply_failed"
            )
        )
        let staleResult = runtime.recordCaptureIntentApplyResult(
            .init(
                revision: firstRevision,
                outcome: .failed,
                failureCode: "capture_intent_display_unavailable"
            )
        )

        let effectiveIntent = runtime.currentEffectiveCaptureIntentSnapshot().first
        #expect(currentResult.outcome == .failed)
        #expect(staleResult.outcome == .ignored)
        #expect(effectiveIntent?.intent.revision == secondRevision)
        #expect(effectiveIntent?.lastFailureCode == "capture_intent_apply_failed")
        #expect(runtime.captureIntentApplyResult(for: secondRevision)?.outcome == .failed)
        #expect(runtime.captureIntentApplyResult(for: firstRevision) == nil)
    }
}

private func sourceDemand(
    capturesCursor: Bool = false,
    powerProfile: DisplayRuntimeCapturePowerProfile = .automatic,
    activeViewerCount: Int = 0
) -> DisplayRuntimeConsumerDemand {
    DisplayRuntimeConsumerDemand(
        sourcePixelSize: .init(width: 1920, height: 1080),
        preferredPixelSize: .init(width: 1280, height: 720),
        sourceFramesPerSecond: 60,
        preferredFramesPerSecond: 30,
        capturesCursor: capturesCursor,
        powerProfile: powerProfile,
        latencyPreference: .realtime,
        activeViewerCount: activeViewerCount
    )
}

private func diagnosticsDemand() -> DisplayRuntimeConsumerDemand {
    DisplayRuntimeConsumerDemand(
        sourcePixelSize: .init(width: 1920, height: 1080),
        preferredPixelSize: .init(width: 1280, height: 720),
        sourceFramesPerSecond: 60,
        preferredFramesPerSecond: 15,
        capturesCursor: false,
        powerProfile: .powerEfficient,
        latencyPreference: .recording
    )
}
