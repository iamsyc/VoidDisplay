@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeConsumerLeaseTests {
    @Test func attachCreatesLeaseSnapshotAndCaptureIntent() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 42)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 42, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )

        let lease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .localUI, redactedLabel: "preview"),
            demand: sourceDemand(capturesCursor: true)
        )

        #expect(lease.surfaceIdentity == surfaceIdentity)
        #expect(lease.surfaceEpoch == .initial)
        #expect(lease.resolvedDisplayID == 42)
        #expect(lease.kind == .preview)
        #expect(lease.state == .attached)
        #expect(lease.createdAt <= lease.updatedAt)
        #expect(runtime.currentConsumerLeaseSnapshot().map(\.id) == [lease.id])
        #expect(captureIntentCommander.intents.count == 1)
        #expect(captureIntentCommander.intents.first?.kind == .capture)
        #expect(captureIntentCommander.intents.first?.reason == .attach)
        #expect(captureIntentCommander.intents.first?.revision.rawValue == 1)
        #expect(captureIntentCommander.intents.first?.aggregateDemand?.capturesCursor == true)
        #expect(captureIntentCommander.returnedResults.first?.outcome == .applied)
        #expect(runtime.captureIntentApplyResult(for: .init(rawValue: 1))?.outcome == .applied)
    }

    @Test func detachRemovesDemandAndEmitsDrainingIntentForLastLease() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 51)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 51, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .localUI),
            demand: sourceDemand(capturesCursor: false)
        )

        let detachResult = await runtime.detachPreviewConsumer(surfaceIdentity: surfaceIdentity)

        #expect(detachResult.releasedLease?.state == .released)
        #expect(detachResult.applyResult?.outcome == .applied)
        #expect(runtime.currentConsumerLeaseSnapshot().first?.state == .released)
        #expect(runtime.currentAggregatedDemandSnapshot().isEmpty)
        #expect(captureIntentCommander.intents.count == 2)
        #expect(captureIntentCommander.intents.last?.kind == .drain)
        #expect(captureIntentCommander.intents.last?.reason == .detach)
        #expect(captureIntentCommander.intents.last?.aggregateDemand == nil)
        #expect(captureIntentCommander.intents.last?.revision.rawValue == 2)
    }

    @Test func lanWebViewCommandBoundaryAppliesOnlyInitialAttachAndDetach() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 78)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 78, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )

        let attachResult = await runtime.attachLANWebViewConsumer(
            surfaceIdentity: surfaceIdentity,
            owner: .init(source: .sharingService, redactedLabel: "lan"),
            demand: sourceDemand(activeViewerCount: 0)
        )
        let repeatedAttach = await runtime.attachLANWebViewConsumer(
            surfaceIdentity: surfaceIdentity,
            owner: .init(source: .sharingService, redactedLabel: "lan"),
            demand: sourceDemand(activeViewerCount: 2)
        )
        let updatedLease = runtime.updateLANWebViewConsumerDemand(
            surfaceIdentity: surfaceIdentity,
            demand: sourceDemand(activeViewerCount: 4)
        )
        let detachResult = await runtime.detachLANWebViewConsumer(surfaceIdentity: surfaceIdentity)

        #expect(attachResult.applyResult?.outcome == .applied)
        #expect(repeatedAttach.lease.id == attachResult.lease.id)
        #expect(repeatedAttach.applyResult == nil)
        #expect(updatedLease?.id == attachResult.lease.id)
        #expect(detachResult.releasedLease?.id == attachResult.lease.id)
        #expect(detachResult.applyResult?.outcome == .applied)
        #expect(captureIntentCommander.intents.map(\.reason) == [.attach, .detach])
        #expect(captureIntentCommander.intents.map(\.revision.rawValue) == [1, 2])
        #expect(runtime.currentConsumerLeaseSnapshot().first?.state == .released)
        #expect(runtime.currentConsumerLeaseSnapshot().first?.demand.activeViewerCount == 4)
    }

    @Test func diagnosticsRecorderDetachDoesNotDrainWhilePreviewLeaseRemains() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 80)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 80, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .localUI),
            demand: sourceDemand()
        )
        let diagnosticsAttach = await runtime.attachDiagnosticsRecorderConsumer(
            surfaceIdentity: surfaceIdentity,
            owner: .init(source: .diagnostics, redactedLabel: "recorder"),
            demand: diagnosticsDemand()
        )

        let diagnosticsDetach = await runtime.detachDiagnosticsRecorderConsumer(
            leaseID: diagnosticsAttach.lease.id
        )
        let previewDetach = await runtime.detachPreviewConsumer(surfaceIdentity: surfaceIdentity)

        #expect(diagnosticsDetach.releasedLease?.state == .released)
        #expect(previewDetach.releasedLease?.state == .released)
        #expect(captureIntentCommander.intents.map(\.kind) == [.capture, .capture, .capture, .drain])
        #expect(captureIntentCommander.intents[2].aggregateDemand?.consumerKinds == [.preview])
        #expect(captureIntentCommander.intents.last?.aggregateDemand == nil)
        #expect(runtime.currentAggregatedDemandSnapshot().isEmpty)
    }

    @Test func surfaceEpochChangeStopsOldLeaseFromDrivingPreviousDisplayID() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 88)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 88, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )
        let lease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
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
        #expect(staleLease?.lastFailureCode == DisplayRuntimeCaptureIntentFailureCode.epochMismatch)
        #expect(runtime.currentAggregatedDemandSnapshot().isEmpty)
        let effectiveIntent = runtime.currentEffectiveCaptureIntentSnapshot().first
        #expect(effectiveIntent?.intent.kind == .drain)
        #expect(effectiveIntent?.intent.surfaceEpoch == nextEpoch)
        #expect(effectiveIntent?.intent.resolvedDisplayID == 89)
        #expect(effectiveIntent?.intent.resolvedDisplayID != lease.resolvedDisplayID)
    }

    @Test func captureIntentCommandPortRecordsAttachDetachRevisionsAndApplyResults() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 90)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 90, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )

        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .localUI),
            demand: sourceDemand()
        )
        let nextEpoch = runtime.advanceSurfaceEpoch(
            surfaceIdentity: surfaceIdentity,
            resolvedDisplayID: 91
        )
        let epochIntent = runtime.currentEffectiveCaptureIntentSnapshot().first
        let detachResult = await runtime.detachPreviewConsumer(surfaceIdentity: surfaceIdentity)

        #expect(epochIntent?.intent.reason == .epochChanged)
        #expect(epochIntent?.intent.surfaceEpoch == nextEpoch)
        #expect(detachResult.applyResult?.outcome == .applied)
        #expect(captureIntentCommander.intents.map(\.reason) == [.attach, .detach])
        #expect(captureIntentCommander.intents.map(\.revision.rawValue) == [1, 3])
        #expect(captureIntentCommander.returnedResults.map(\.outcome) == [.applied, .applied])
        #expect(runtime.captureIntentApplyResult(for: .init(rawValue: 1))?.outcome == .applied)
        #expect(runtime.captureIntentApplyResult(for: .init(rawValue: 3))?.outcome == .applied)
        #expect(runtime.currentLatestCaptureIntentRevision()?.rawValue == 3)
    }

    @Test func stalePortApplyResultIsIgnoredAndDoesNotReplaceEffectiveIntent() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 92)
        var firstRevision: DisplayRuntimeCaptureIntentRevision?
        let captureIntentCommander = FakeCaptureIntentCommander { intent in
            if intent.reason == .detach, let firstRevision {
                return .failed(
                    revision: firstRevision,
                    failureCode: DisplayRuntimeCaptureIntentFailureCode.displayUnavailable
                )
            }
            firstRevision = firstRevision ?? intent.revision
            return .applied(revision: intent.revision)
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 92, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .localUI),
            demand: sourceDemand()
        )
        let attachedRevision = captureIntentCommander.intents[0].revision

        _ = await runtime.detachPreviewConsumer(surfaceIdentity: surfaceIdentity)

        let effectiveIntent = runtime.currentEffectiveCaptureIntentSnapshot().first
        #expect(captureIntentCommander.intents.map(\.reason) == [.attach, .detach])
        #expect(captureIntentCommander.returnedResults.last?.revision == attachedRevision)
        #expect(runtime.captureIntentApplyResult(for: attachedRevision)?.outcome == .ignored)
        #expect(effectiveIntent?.intent.reason == .detach)
        #expect(effectiveIntent?.intent.revision.rawValue == 2)
        #expect(effectiveIntent?.lastApplyResult == nil)
        #expect(effectiveIntent?.lastFailureCode == nil)
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
