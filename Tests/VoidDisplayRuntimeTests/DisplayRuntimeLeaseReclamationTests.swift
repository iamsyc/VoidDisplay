@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeLeaseReclamationTests {
    @Test func thousandPreviewAndSharingCyclesKeepRuntimeStorageBounded() async throws {
        let identity = DisplaySurfaceIdentity.physicalDisplay(displayID: 42)
        let commander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 42, isMain: true)),
            captureIntentCommander: commander
        )
        var firstIdleSnapshotSize = 0
        for cycle in 0..<1_000 {
            let preview = await attachConsumerForTesting(
                runtime, surfaceIdentity: identity, kind: .preview,
                owner: .init(source: .localUI), demand: runtimeConsumerDemand()
            )
            let sharing = await attachConsumerForTesting(
                runtime, surfaceIdentity: identity, kind: .lanWebView,
                owner: .init(source: .sharingService), demand: runtimeConsumerDemand(activeViewerCount: 1)
            )
            _ = await runtime.detachPreviewConsumer(leaseID: preview.id)
            _ = await runtime.detachLANWebViewConsumer(leaseID: sharing.id)
            if cycle == 0 {
                firstIdleSnapshotSize = try JSONEncoder().encode(runtime.makeSnapshot()).count
            }
        }
        let retainedLeaseCount = runtime.consumerLeasesByID.count
        #expect(retainedLeaseCount == 0)
        #expect(runtime.previewLeaseWaiters.isEmpty)
        #expect(runtime.captureIntentApplyTails.isEmpty)
        #expect(runtime.currentAggregatedDemandSnapshot().isEmpty)
        #expect(runtime.currentEffectiveCaptureIntentSnapshot().allSatisfy { $0.intent.kind == .drain })
        let snapshot = runtime.makeSnapshot()
        #expect(snapshot.consumerSummary.totalLeaseCount == 0)
        #expect(try JSONEncoder().encode(snapshot).count < firstIdleSnapshotSize + 128)
    }

    @Test(arguments: [DisplaySurfaceConsumerKind.preview, .lanWebView])
    func closeDuringAttachInvalidatesOldIDAndPreservesNewInstance(kind: DisplaySurfaceConsumerKind) async throws {
        let identity = DisplaySurfaceIdentity.physicalDisplay(displayID: 42)
        let commander = FakeCaptureIntentCommander()
        commander.shouldGateApply = true
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 42, isMain: true)),
            captureIntentCommander: commander
        )
        let oldAttachment = Task { await attach(runtime, kind: kind, identity: identity) }
        await commander.waitForApplyCalls(1)
        let oldLease = try #require(runtime.currentConsumerLeaseSnapshot().first)
        let waiter = kind == .preview
            ? Task { await runtime.waitForPreviewConsumerResolution(leaseID: oldLease.id) }
            : nil
        if waiter != nil {
            for _ in 0..<1_000 where runtime.previewLeaseWaiters[oldLease.id] == nil { await Task.yield() }
        }
        let close = Task { await detach(runtime, lease: oldLease) }
        for _ in 0..<1_000 where runtime.consumerLease(leaseID: oldLease.id) != nil { await Task.yield() }
        #expect(runtime.consumerLease(leaseID: oldLease.id) == nil)
        if let waiter { #expect(await waiter.value?.state == .released) }
        #expect(runtime.previewLeaseWaiters.isEmpty)
        let newAttachment = Task { await attach(runtime, kind: kind, identity: identity) }
        for _ in 0..<1_000 where runtime.currentConsumerLeaseSnapshot().allSatisfy({ $0.id == oldLease.id }) { await Task.yield() }
        commander.shouldGateApply = false
        commander.releaseApply(call: 1)
        let oldResult = await oldAttachment.value
        await close.value
        if case .attached = oldResult { Issue.record("A closed attachment must return invalidated.") }
        guard case let .attached(newLease, result) = await newAttachment.value else {
            Issue.record("Expected a fresh attachment.")
            return
        }
        #expect(result.outcome == .applied)
        #expect(newLease.id != oldLease.id)
        #expect(runtime.consumerLease(leaseID: oldLease.id) == nil)
        #expect(runtime.currentConsumerLeaseSnapshot().map(\.id) == [newLease.id])
        #expect(runtime.currentAggregatedDemandSnapshot().first?.activeLeaseIDs == [newLease.id])
        await detach(runtime, lease: newLease)
    }

    @Test func cancelledWaiterAndRepeatedCloseLeaveNoRetainedState() async throws {
        let identity = DisplaySurfaceIdentity.physicalDisplay(displayID: 42)
        let commander = FakeCaptureIntentCommander()
        commander.shouldGateApply = true
        let runtime = DisplayRuntime(captureIntentCommander: commander)
        let attachment = Task { await attach(runtime, kind: .preview, identity: identity) }
        await commander.waitForApplyCalls(1)
        let lease = try #require(runtime.currentConsumerLeaseSnapshot().first)
        let waiter = Task { await runtime.waitForPreviewConsumerResolution(leaseID: lease.id) }
        for _ in 0..<1_000 where runtime.previewLeaseWaiters[lease.id] == nil { await Task.yield() }
        waiter.cancel()
        _ = await waiter.value
        #expect(runtime.previewLeaseWaiters.isEmpty)
        let close = Task { await runtime.detachPreviewConsumer(leaseID: lease.id) }
        for _ in 0..<1_000 where runtime.consumerLease(leaseID: lease.id) != nil { await Task.yield() }
        let revision = runtime.currentLatestCaptureIntentRevision()
        let repeatedClose = await runtime.detachPreviewConsumer(leaseID: lease.id)
        #expect(repeatedClose.releasedLease == nil)
        #expect(repeatedClose.applyResult == nil)
        #expect(runtime.currentLatestCaptureIntentRevision() == revision)
        #expect(await runtime.waitForPreviewConsumerResolution(leaseID: lease.id) == nil)
        commander.shouldGateApply = false
        commander.releaseApply(call: 1)
        _ = await attachment.value
        #expect(await close.value.releasedLease?.state == .released)
        #expect(runtime.consumerLeasesByID.isEmpty)
        #expect(runtime.captureIntentApplyTails.isEmpty)
    }

    @Test func closeDuringRetryCatalogRefreshCannotRestoreRemovedLease() async {
        let identity = DisplaySurfaceIdentity.physicalDisplay(displayID: 42)
        let catalog = FakeCatalogCommander(snapshot: catalogSnapshot(displayID: 42, isMain: true))
        let commander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(catalogProvider: catalog, catalogCommander: catalog, captureIntentCommander: commander)
        let lease = await attachConsumerForTesting(
            runtime, surfaceIdentity: identity, kind: .preview,
            owner: .init(source: .localUI), demand: runtimeConsumerDemand()
        )
        runtime.captureSessionDidTerminate(displayID: 42)
        catalog.shouldGateSubmitRefresh = true
        let retry = Task { await runtime.retryPreviewConsumer(leaseID: lease.id) }
        await catalog.waitForSubmitCalls(1)
        _ = await runtime.detachPreviewConsumer(leaseID: lease.id)
        let callCount = commander.intents.count
        catalog.releaseSubmitRefresh(call: 1)
        #expect(await retry.value == nil)
        #expect(runtime.consumerLeasesByID.isEmpty)
        #expect(runtime.currentAggregatedDemandSnapshot().isEmpty)
        #expect(runtime.isConsumerTransitionBusy(surfaceIdentity: identity) == false)
        #expect(commander.intents.count == callCount)
    }

    @Test func closeBeforeRebuildCompletionSkipsRemovedLease() async {
        let identity = DisplaySurfaceIdentity.physicalDisplay(displayID: 42)
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 42, isMain: true)),
            captureIntentCommander: FakeCaptureIntentCommander()
        )
        let lease = await attachConsumerForTesting(
            runtime, surfaceIdentity: identity, kind: .preview,
            owner: .init(source: .localUI), demand: runtimeConsumerDemand()
        )
        let batch = await runtime.beginConsumerTransition(surfaceIdentities: [identity], previousDisplayIDs: [identity: 42])
        _ = await runtime.detachPreviewConsumer(leaseID: lease.id)
        let results = await runtime.completeConsumerTransition(batch, snapshot: runtime.makeSnapshot(), topologyResult: nil)
        #expect(results.map(\.status) == [.skipped])
        #expect(results.first?.failureReason == "consumer_lease_released")
        #expect(runtime.consumerLeasesByID.isEmpty)
        #expect(runtime.previewLeaseWaiters.isEmpty)
        #expect(runtime.currentAggregatedDemandSnapshot().isEmpty)
    }

    @Test func stateUpdatesCannotReinsertAReleasedLease() async {
        let identity = DisplaySurfaceIdentity.physicalDisplay(displayID: 42)
        let runtime = DisplayRuntime(captureIntentCommander: FakeCaptureIntentCommander())
        let lease = await attachConsumerForTesting(
            runtime, surfaceIdentity: identity, kind: .preview,
            owner: .init(source: .localUI), demand: runtimeConsumerDemand()
        )
        _ = await runtime.detachPreviewConsumer(leaseID: lease.id)
        let replacement = await attachConsumerForTesting(
            runtime, surfaceIdentity: identity, kind: .preview,
            owner: .init(source: .localUI), demand: runtimeConsumerDemand()
        )
        _ = runtime.replaceLease(lease, state: .attached, demand: lease.demand, lastFailureCode: nil)
        #expect(runtime.consumerLease(leaseID: lease.id) == nil)
        #expect(runtime.currentConsumerLeaseSnapshot().map(\.id) == [replacement.id])
        #expect(runtime.currentAggregatedDemandSnapshot().first?.activeLeaseIDs == [replacement.id])
        _ = await runtime.detachPreviewConsumer(leaseID: replacement.id)
    }
}

@MainActor
private func attach(_ runtime: DisplayRuntime, kind: DisplaySurfaceConsumerKind, identity: DisplaySurfaceIdentity) async -> DisplayRuntimeConsumerAttachOutcome {
    switch kind {
    case .preview:
        return await runtime.attachPreviewConsumer(surfaceIdentity: identity, owner: .init(source: .localUI), demand: runtimeConsumerDemand())
    case .lanWebView:
        return await runtime.attachLANWebViewConsumer(surfaceIdentity: identity, owner: .init(source: .sharingService), demand: runtimeConsumerDemand())
    }
}

@MainActor
private func detach(_ runtime: DisplayRuntime, lease: DisplayRuntimeConsumerLease) async {
    switch lease.kind {
    case .preview: _ = await runtime.detachPreviewConsumer(leaseID: lease.id)
    case .lanWebView: _ = await runtime.detachLANWebViewConsumer(leaseID: lease.id)
    }
}
