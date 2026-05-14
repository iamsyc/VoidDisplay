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
        #expect(captureIntentCommander.returnedResults.first?.outcome == .applied)
        #expect(runtime.captureIntentApplyResult(for: .init(rawValue: 1))?.outcome == .applied)
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
        #expect(staleLease?.lastFailureCode == DisplayRuntimeCaptureIntentFailureCode.epochMismatch)
        #expect(runtime.currentAggregatedDemandSnapshot().isEmpty)
        #expect(captureIntentCommander.intents.last?.kind == .drain)
        #expect(captureIntentCommander.intents.last?.surfaceEpoch == nextEpoch)
        #expect(captureIntentCommander.intents.last?.resolvedDisplayID == 89)
        #expect(captureIntentCommander.intents.last?.resolvedDisplayID != lease.resolvedDisplayID)
    }

    @Test func captureIntentCommandPortRecordsAttachDetachEpochChangedRevisionsAndApplyResults() {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 90)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 90, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )

        let lease = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .monitor,
            owner: .init(source: .localUI),
            demand: sourceDemand()
        )
        _ = runtime.advanceSurfaceEpoch(
            surfaceIdentity: surfaceIdentity,
            resolvedDisplayID: 91
        )
        _ = runtime.detachConsumer(leaseID: lease.id)

        #expect(captureIntentCommander.intents.map(\.reason) == [.attach, .epochChanged, .detach])
        #expect(captureIntentCommander.intents.map(\.revision.rawValue) == [1, 2, 3])
        #expect(captureIntentCommander.returnedResults.map(\.outcome) == [.applied, .applied, .applied])
        #expect(runtime.captureIntentApplyResult(for: .init(rawValue: 1))?.outcome == .applied)
        #expect(runtime.captureIntentApplyResult(for: .init(rawValue: 2))?.outcome == .applied)
        #expect(runtime.captureIntentApplyResult(for: .init(rawValue: 3))?.outcome == .applied)
        #expect(runtime.currentLatestCaptureIntentRevision()?.rawValue == 3)
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
                failureCode: DisplayRuntimeCaptureIntentFailureCode.applyFailed
            )
        )
        let staleResult = runtime.recordCaptureIntentApplyResult(
            .init(
                revision: firstRevision,
                outcome: .failed,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.displayUnavailable
            )
        )

        let effectiveIntent = runtime.currentEffectiveCaptureIntentSnapshot().first
        #expect(currentResult.outcome == .failed)
        #expect(staleResult.outcome == .ignored)
        #expect(effectiveIntent?.intent.revision == secondRevision)
        #expect(effectiveIntent?.lastFailureCode == DisplayRuntimeCaptureIntentFailureCode.applyFailed)
        #expect(runtime.captureIntentApplyResult(for: secondRevision)?.outcome == .failed)
        #expect(runtime.captureIntentApplyResult(for: firstRevision)?.outcome == .ignored)
    }

    @Test func stalePortApplyResultIsIgnoredAndDoesNotReplaceEffectiveIntent() {
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
        let lease = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .monitor,
            owner: .init(source: .localUI),
            demand: sourceDemand()
        )
        let attachedRevision = captureIntentCommander.intents[0].revision

        _ = runtime.detachConsumer(leaseID: lease.id)

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
