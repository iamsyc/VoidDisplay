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
        let lease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .localUI),
            demand: sourceDemand(capturesCursor: false)
        )

        let detachResult = await runtime.detachPreviewConsumer(leaseID: lease.id)

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

    @Test func lanWebViewMetadataUpdatesReuseLeaseWithoutAdvancingIntentRevision() async throws {
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
        let updateResult = await runtime.updateLANWebViewConsumerDemand(
            surfaceIdentity: surfaceIdentity,
            demand: sourceDemand(activeViewerCount: 4)
        )
        let detachResult = await runtime.detachLANWebViewConsumer(surfaceIdentity: surfaceIdentity)

        guard case let .attached(attachedLease, attachApplyResult) = attachResult,
              case let .attached(repeatedLease, repeatedApplyResult) = repeatedAttach
        else {
            Issue.record("Expected LAN attach outcomes")
            return
        }
        #expect(attachApplyResult.outcome == .applied)
        #expect(repeatedLease.id == attachedLease.id)
        #expect(repeatedApplyResult.outcome == .applied)
        #expect(updateResult?.outcome == .applied)
        #expect(detachResult.releasedLease?.id == attachedLease.id)
        #expect(detachResult.applyResult?.outcome == .applied)
        #expect(captureIntentCommander.intents.map(\.reason) == [.attach, .detach])
        #expect(captureIntentCommander.intents.map(\.revision.rawValue) == [1, 2])
        #expect(runtime.currentConsumerLeaseSnapshot().first?.state == .released)
        #expect(runtime.currentConsumerLeaseSnapshot().first?.demand.activeViewerCount == 4)
    }

    @Test func lanWebViewMetadataUpdateDoesNotMaskInFlightCaptureFailure() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 79)
        let failureCode = DisplayRuntimeCaptureIntentFailureCode.applyFailed
        let captureIntentCommander = FakeCaptureIntentCommander { intent in
            intent.reason == .performanceModeChanged
                ? .failed(revision: intent.revision, failureCode: failureCode)
                : .applied(revision: intent.revision)
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 79, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )
        _ = await runtime.attachLANWebViewConsumer(
            surfaceIdentity: surfaceIdentity,
            owner: .init(source: .sharingService, redactedLabel: "lan"),
            demand: sourceDemand(powerProfile: .automatic, activeViewerCount: 0)
        )
        captureIntentCommander.shouldGateApply = true
        let captureUpdate = Task { @MainActor in
            await runtime.updateConsumerPowerProfile(.powerEfficient)
        }
        await captureIntentCommander.waitForApplyCalls(2)

        let metadataResult = await runtime.updateLANWebViewConsumerDemand(
            surfaceIdentity: surfaceIdentity,
            demand: sourceDemand(powerProfile: .powerEfficient, activeViewerCount: 3)
        )
        captureIntentCommander.releaseApply(call: 2)
        await captureUpdate.value

        let effectiveIntent = runtime.currentEffectiveCaptureIntentSnapshot().first
        #expect(metadataResult?.outcome == .applied)
        #expect(captureIntentCommander.intents.map(\.reason) == [.attach, .performanceModeChanged])
        #expect(effectiveIntent?.intent.revision.rawValue == 2)
        #expect(effectiveIntent?.lastApplyResult?.outcome == .failed)
        #expect(effectiveIntent?.lastFailureCode == failureCode)
        #expect(runtime.currentConsumerLeaseSnapshot().first?.demand.activeViewerCount == 3)
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

        let lease = await attachConsumerForTesting(
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
        let detachResult = await runtime.detachPreviewConsumer(leaseID: lease.id)

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
        let lease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .localUI),
            demand: sourceDemand()
        )
        let attachedRevision = captureIntentCommander.intents[0].revision

        _ = await runtime.detachPreviewConsumer(leaseID: lease.id)

        let effectiveIntent = runtime.currentEffectiveCaptureIntentSnapshot().first
        #expect(captureIntentCommander.intents.map(\.reason) == [.attach, .detach])
        #expect(captureIntentCommander.returnedResults.last?.revision == attachedRevision)
        #expect(runtime.captureIntentApplyResult(for: attachedRevision)?.outcome == .ignored)
        #expect(effectiveIntent?.intent.reason == .detach)
        #expect(effectiveIntent?.intent.revision.rawValue == 2)
        #expect(effectiveIntent?.lastApplyResult == nil)
        #expect(effectiveIntent?.lastFailureCode == nil)
    }

    @Test func previewDetachPreservesLANConsumerDemand() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 93)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 93, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )
        let previewLease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .localUI),
            demand: sourceDemand(capturesCursor: true)
        )
        let lanLease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .lanWebView,
            owner: .init(source: .sharingService),
            demand: sourceDemand(activeViewerCount: 1)
        )

        _ = await runtime.detachPreviewConsumer(leaseID: previewLease.id)

        #expect(runtime.consumerLease(leaseID: previewLease.id)?.state == .released)
        #expect(runtime.consumerLease(leaseID: lanLease.id)?.state == .attached)
        #expect(runtime.currentAggregatedDemandSnapshot().first?.consumerKinds == [.lanWebView])
        #expect(captureIntentCommander.intents.last?.kind == .capture)
        #expect(captureIntentCommander.intents.last?.aggregateDemand?.consumerKinds == [.lanWebView])
    }

    @Test func cursorAndPowerProfileUpdatesAdvanceIntentAndLeaseDemand() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 94)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 94, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )
        let lease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .localUI),
            demand: sourceDemand()
        )

        _ = await runtime.updatePreviewConsumerDemand(
            leaseID: lease.id,
            demand: lease.demand.replacing(capturesCursor: true)
        )
        await runtime.updateConsumerPowerProfile(.powerEfficient)

        let updatedLease = runtime.consumerLease(leaseID: lease.id)
        #expect(updatedLease?.demand.capturesCursor == true)
        #expect(updatedLease?.demand.powerProfile == .powerEfficient)
        #expect(runtime.currentAggregatedDemandSnapshot().first?.capturesCursor == true)
        #expect(runtime.currentAggregatedDemandSnapshot().first?.powerProfile == .powerEfficient)
        #expect(captureIntentCommander.intents.map(\.reason) == [
            .attach,
            .attach,
            .performanceModeChanged
        ])
    }

    @Test func failedAttachRemovesInvalidDemandWithCorrectiveDrain() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 95)
        let captureIntentCommander = FakeCaptureIntentCommander { intent in
            if intent.kind == .capture {
                return .failed(
                    revision: intent.revision,
                    failureCode: DisplayRuntimeCaptureIntentFailureCode.applyFailed
                )
            }
            return .applied(revision: intent.revision)
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 95, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )

        let outcome = await runtime.attachPreviewConsumer(
            surfaceIdentity: surfaceIdentity,
            owner: .init(source: .localUI),
            demand: sourceDemand()
        )

        guard case let .attached(lease, applyResult) = outcome else {
            Issue.record("Expected attach outcome with failed apply evidence")
            return
        }
        #expect(applyResult.outcome == .failed)
        #expect(runtime.consumerLease(leaseID: lease.id)?.state == .failed)
        #expect(runtime.currentAggregatedDemandSnapshot().isEmpty)
        #expect(captureIntentCommander.intents.map(\.kind) == [.capture, .drain])
        #expect(captureIntentCommander.intents.last?.reason == .detach)
    }

    @Test func attachRemainsNonterminalUntilIntentApplicationCompletes() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 96)
        let captureIntentCommander = FakeCaptureIntentCommander()
        captureIntentCommander.shouldGateApply = true
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 96, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )

        let attachTask = Task { @MainActor in
            await runtime.attachPreviewConsumer(
                surfaceIdentity: surfaceIdentity,
                owner: .init(source: .localUI),
                demand: sourceDemand()
            )
        }
        await captureIntentCommander.waitForApplyCalls(1)

        let pendingLease = runtime.currentConsumerLeaseSnapshot().first
        let duplicateOutcome = await runtime.attachPreviewConsumer(
            surfaceIdentity: surfaceIdentity,
            owner: .init(source: .localUI),
            demand: sourceDemand(capturesCursor: true)
        )
        #expect(pendingLease?.state == .attaching)
        #expect(
            duplicateOutcome == .rejected(
                failureCode: DisplayRuntimeCaptureIntentFailureCode.consumerLeaseAlreadyExists
            )
        )

        captureIntentCommander.releaseApply(call: 1)
        guard case let .attached(lease, result) = await attachTask.value else {
            Issue.record("Expected attached lease")
            return
        }
        #expect(result.outcome == .applied)
        #expect(lease.state == .attached)
    }

    @Test func currentIgnoredDemandUpdateRollsBackAndReappliesPreviousDemand() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 97)
        let captureIntentCommander = FakeCaptureIntentCommander { intent in
            if intent.revision.rawValue == 2 {
                return DisplayRuntimeCaptureIntentApplyResult(
                    revision: intent.revision,
                    outcome: .ignored
                )
            }
            return .applied(revision: intent.revision)
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 97, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )
        let lease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .localUI),
            demand: sourceDemand(capturesCursor: false)
        )

        let result = await runtime.updatePreviewConsumerDemand(
            leaseID: lease.id,
            demand: lease.demand.replacing(capturesCursor: true)
        )

        #expect(result?.outcome == .ignored)
        #expect(runtime.consumerLease(leaseID: lease.id)?.state == .attached)
        #expect(runtime.consumerLease(leaseID: lease.id)?.demand.capturesCursor == false)
        #expect(captureIntentCommander.intents.map(\.reason) == [.attach, .attach, .attach])
        #expect(captureIntentCommander.returnedResults.map(\.outcome) == [.applied, .ignored, .applied])
    }

    @Test func transitionRestoresLatestPowerProfileAndBecomesTerminalAfterApply() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 98)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 98, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )
        let lease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .localUI),
            demand: sourceDemand(powerProfile: .smooth)
        )
        let transition = await runtime.beginConsumerTransition(
            surfaceIdentities: [surfaceIdentity],
            previousDisplayIDs: [surfaceIdentity: 98]
        )
        await runtime.updateConsumerPowerProfile(.powerEfficient)
        #expect(runtime.consumerLease(leaseID: lease.id)?.state == .restarting)
        #expect(runtime.consumerLease(leaseID: lease.id)?.demand.powerProfile == .powerEfficient)
        captureIntentCommander.shouldGateApply = true

        let completionTask = Task { @MainActor in
            await runtime.completeConsumerTransition(
                transition,
                snapshot: runtime.makeSnapshot(),
                topologyResult: nil
            )
        }
        await captureIntentCommander.waitForApplyCalls(3)

        #expect(runtime.consumerLease(leaseID: lease.id)?.state == .attaching)
        #expect(runtime.consumerLease(leaseID: lease.id)?.demand.powerProfile == .powerEfficient)

        captureIntentCommander.releaseApply(call: 3)
        _ = await completionTask.value
        #expect(runtime.consumerLease(leaseID: lease.id)?.state == .attached)
        #expect(runtime.consumerLease(leaseID: lease.id)?.demand.powerProfile == .powerEfficient)
        #expect(captureIntentCommander.intents.last?.aggregateDemand?.powerProfile == .powerEfficient)
    }

    @Test func catalogClearDuringRestoreKeepsInvalidatedLeaseStopped() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 981)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(
                snapshot: catalogSnapshot(displayID: 981, isMain: true)
            ),
            captureIntentCommander: captureIntentCommander
        )
        let lease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .localUI),
            demand: sourceDemand()
        )
        let transition = await runtime.beginConsumerTransition(
            surfaceIdentities: [surfaceIdentity],
            previousDisplayIDs: [surfaceIdentity: 981]
        )
        captureIntentCommander.shouldGateApply = true
        let completionTask = Task { @MainActor in
            await runtime.completeConsumerTransition(
                transition,
                snapshot: runtime.makeSnapshot(),
                topologyResult: nil
            )
        }
        await captureIntentCommander.waitForApplyCalls(3)

        await runtime.handleRefreshOutcomeForConvergence(
            .init(settlementID: 1, result: .clearedSnapshot, catalog: .empty)
        )
        captureIntentCommander.shouldGateApply = false
        captureIntentCommander.releaseApply(call: 3)
        let results = await completionTask.value

        #expect(results.map(\.status) == [.invalidated])
        #expect(runtime.consumerLease(leaseID: lease.id)?.state == .failed)
        #expect(captureIntentCommander.intents.last?.kind == .drain)
        #expect(runtime.isConsumerTransitionBusy(surfaceIdentity: surfaceIdentity) == false)
    }

    @Test func powerProfileUpdatePreservesFailedLeaseStateAndFailureCode() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 990)
        let failureCode = DisplayRuntimeCaptureIntentFailureCode.applyFailed
        let captureIntentCommander = FakeCaptureIntentCommander { intent in
            intent.kind == .capture
                ? .failed(revision: intent.revision, failureCode: failureCode)
                : .applied(revision: intent.revision)
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 990, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )
        let outcome = await runtime.attachPreviewConsumer(
            surfaceIdentity: surfaceIdentity,
            owner: .init(source: .localUI),
            demand: sourceDemand(powerProfile: .smooth)
        )
        guard case let .attached(lease, _) = outcome else {
            Issue.record("Expected a failed lease result from the attempted attach")
            return
        }
        let intentCountBeforeUpdate = captureIntentCommander.intents.count

        await runtime.updateConsumerPowerProfile(.powerEfficient)

        let updatedLease = runtime.consumerLease(leaseID: lease.id)
        #expect(updatedLease?.state == .failed)
        #expect(updatedLease?.lastFailureCode == failureCode)
        #expect(updatedLease?.demand.powerProfile == .powerEfficient)
        #expect(captureIntentCommander.intents.count == intentCountBeforeUpdate)
    }

    @Test func retryIgnoredResultLeavesLeaseFailedWithInvalidationCode() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 99)
        let captureIntentCommander = FakeCaptureIntentCommander { intent in
            if intent.reason == .retry {
                return DisplayRuntimeCaptureIntentApplyResult(
                    revision: intent.revision,
                    outcome: .ignored
                )
            }
            return .applied(revision: intent.revision)
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 99, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )
        let lease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .localUI),
            demand: sourceDemand()
        )
        _ = runtime.markConsumerLeaseFailed(
            leaseID: lease.id,
            failureCode: DisplayRuntimeCaptureIntentFailureCode.applyFailed
        )

        let retriedLease = await runtime.retryPreviewConsumer(leaseID: lease.id)

        #expect(retriedLease?.state == .failed)
        #expect(retriedLease?.lastFailureCode == DisplayRuntimeCaptureIntentFailureCode.applyInvalidated)
        #expect(runtime.isConsumerTransitionBusy(surfaceIdentity: surfaceIdentity) == false)
        #expect(captureIntentCommander.intents.map(\.reason) == [.attach, .retry, .detach])
    }

    @Test func supersedingDemandUpdateWaitsForPriorApplyAndFinishesWithLatestDemand() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 100)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 100, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )
        let lease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .localUI),
            demand: sourceDemand(capturesCursor: false)
        )
        captureIntentCommander.shouldGateApply = true

        let firstUpdate = Task { @MainActor in
            await runtime.updatePreviewConsumerDemand(
                leaseID: lease.id,
                demand: lease.demand.replacing(capturesCursor: true)
            )
        }
        await captureIntentCommander.waitForApplyCalls(2)
        let secondUpdate = Task { @MainActor in
            await runtime.updatePreviewConsumerDemand(
                leaseID: lease.id,
                demand: lease.demand.replacing(capturesCursor: false)
            )
        }
        await Task.yield()

        #expect(captureIntentCommander.intents.count == 2)
        captureIntentCommander.releaseApply(call: 2)
        await captureIntentCommander.waitForApplyCalls(3)
        captureIntentCommander.releaseApply(call: 3)
        let firstResult = await firstUpdate.value
        let secondResult = await secondUpdate.value

        #expect(firstResult?.outcome == .ignored)
        #expect(secondResult?.outcome == .applied)
        #expect(runtime.consumerLease(leaseID: lease.id)?.demand.capturesCursor == false)
        #expect(captureIntentCommander.intents.map(\.revision.rawValue) == [1, 2, 3])
    }

    @Test func detachDuringAttachCannotResurrectReleasedLease() async throws {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 101)
        let captureIntentCommander = FakeCaptureIntentCommander()
        captureIntentCommander.shouldGateApply = true
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 101, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )

        let attachTask = Task { @MainActor in
            await runtime.attachPreviewConsumer(
                surfaceIdentity: surfaceIdentity,
                owner: .init(source: .localUI),
                demand: sourceDemand()
            )
        }
        await captureIntentCommander.waitForApplyCalls(1)
        let leaseID = try #require(runtime.currentConsumerLeaseSnapshot().first?.id)
        let detachTask = Task { @MainActor in
            await runtime.detachPreviewConsumer(leaseID: leaseID)
        }
        await Task.yield()

        #expect(runtime.consumerLease(leaseID: leaseID)?.state == .released)
        captureIntentCommander.releaseApply(call: 1)
        await captureIntentCommander.waitForApplyCalls(2)
        captureIntentCommander.releaseApply(call: 2)
        _ = await attachTask.value
        _ = await detachTask.value

        #expect(runtime.consumerLease(leaseID: leaseID)?.state == .released)
        #expect(runtime.currentAggregatedDemandSnapshot().isEmpty)
        #expect(captureIntentCommander.intents.map(\.kind) == [.capture, .drain])
    }

    @Test func detachDuringRestoreKeepsLeaseReleasedAndReportsTerminalSkip() async {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 102)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 102, isMain: true)),
            captureIntentCommander: captureIntentCommander
        )
        let lease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .localUI),
            demand: sourceDemand()
        )
        let transition = await runtime.beginConsumerTransition(
            surfaceIdentities: [surfaceIdentity],
            previousDisplayIDs: [surfaceIdentity: 102]
        )
        captureIntentCommander.shouldGateApply = true
        let completionTask = Task { @MainActor in
            await runtime.completeConsumerTransition(
                transition,
                snapshot: runtime.makeSnapshot(),
                topologyResult: nil
            )
        }
        await captureIntentCommander.waitForApplyCalls(3)
        let detachTask = Task { @MainActor in
            await runtime.detachPreviewConsumer(leaseID: lease.id)
        }
        await Task.yield()

        #expect(runtime.consumerLease(leaseID: lease.id)?.state == .released)
        captureIntentCommander.releaseApply(call: 3)
        await captureIntentCommander.waitForApplyCalls(4)
        captureIntentCommander.releaseApply(call: 4)
        let results = await completionTask.value
        _ = await detachTask.value

        #expect(results.first?.status == .skipped)
        #expect(results.first?.failureReason == "consumer_lease_released")
        #expect(runtime.consumerLease(leaseID: lease.id)?.state == .released)
        #expect(runtime.isConsumerTransitionBusy(surfaceIdentity: surfaceIdentity) == false)
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
