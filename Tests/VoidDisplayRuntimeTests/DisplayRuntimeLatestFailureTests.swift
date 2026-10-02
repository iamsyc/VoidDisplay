@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeLatestFailureTests {
    @Test func replacingCaptureIntentReclaimsFailureDeduplicationHistory() {
        let runtime = DisplayRuntime()
        let identity = DisplaySurfaceIdentity.physicalDisplay(displayID: 42)
        for index in 0..<1_000 {
            let intent = runtime.submitCaptureIntent(surfaceIdentity: identity, reason: .retry)
            runtime.recordCaptureIntentApplyResult(.failed(revision: intent.revision, failureCode: "failure_\(index)"))
        }
        #expect(runtime.recordedCaptureFailureCodesBySurface == [identity: ["failure_999"]])
        #expect(runtime.makeSnapshot().latestFailure == .init(code: "failure_999", sequence: 1_000))
        _ = runtime.submitCaptureIntent(surfaceIdentity: identity, reason: .detach)
        #expect(runtime.recordedCaptureFailureCodesBySurface.isEmpty)
    }

    @Test func captureFailuresFollowAcceptanceOrderAndIgnoreRepeatedOrStaleResults() throws {
        let runtime = DisplayRuntime()
        let older = DisplaySurfaceIdentity.physicalDisplay(displayID: 200)
        let newer = DisplaySurfaceIdentity.physicalDisplay(displayID: 100)
        #expect(runtime.makeSnapshot().latestFailure == nil)
        let first = runtime.submitCaptureIntent(surfaceIdentity: older, reason: .attach)
        let firstFailure = DisplayRuntimeCaptureIntentApplyResult.failed(revision: first.revision, failureCode: "first")
        runtime.recordCaptureIntentApplyResult(firstFailure)
        let second = runtime.submitCaptureIntent(surfaceIdentity: newer, reason: .attach)
        let secondFailure = DisplayRuntimeCaptureIntentApplyResult.failed(revision: second.revision, failureCode: "second")
        runtime.recordCaptureIntentApplyResult(secondFailure)
        #expect(runtime.makeSnapshot().latestFailure == .init(code: "second", sequence: 2))

        runtime.recordCaptureIntentApplyResult(firstFailure)
        runtime.recordCaptureIntentApplyResult(secondFailure.ignored())
        runtime.recordCaptureIntentApplyResult(secondFailure)
        #expect(runtime.makeSnapshot().latestFailure == .init(code: "second", sequence: 2))
        runtime.recordCaptureIntentApplyResult(.applied(revision: second.revision))
        runtime.recordCaptureIntentApplyResult(.failed(revision: second.revision, failureCode: "another_consumer"))
        runtime.recordCaptureIntentApplyResult(secondFailure)
        #expect(runtime.makeSnapshot().latestFailure == .init(code: "another_consumer", sequence: 3))
        let replacement = runtime.submitCaptureIntent(surfaceIdentity: newer, reason: .retry)
        #expect(runtime.recordCaptureIntentApplyResult(secondFailure).outcome == .ignored)
        runtime.recordCaptureIntentApplyResult(.applied(revision: replacement.revision))
        #expect(runtime.makeSnapshot().latestFailure == .init(code: "another_consumer", sequence: 3))
        let next = runtime.submitCaptureIntent(surfaceIdentity: newer, reason: .retry)
        runtime.recordCaptureIntentApplyResult(.failed(revision: next.revision, failureCode: "second"))
        #expect(runtime.makeSnapshot().latestFailure == .init(code: "second", sequence: 4))
        let encoded = try JSONEncoder().encode(runtime.makeSnapshot())
        let decoded = try JSONDecoder().decode(DisplayRuntimeSnapshot.self, from: encoded)
        #expect(decoded.schemaVersion == 7)
        #expect(decoded.latestFailure == runtime.makeSnapshot().latestFailure)
    }

    @Test func transactionConsumerAndCaptureFailuresShareOneSequence() async {
        let identity = DisplaySurfaceIdentity.physicalDisplay(displayID: 42)
        let catalog = FakeCatalogCommander(snapshot: catalogSnapshot(displayID: 42, isMain: true))
        let runtime = DisplayRuntime(catalogProvider: catalog, catalogCommander: catalog, captureIntentCommander: FakeCaptureIntentCommander())
        await finishFailure(runtime, code: "transaction_failed")
        #expect(runtime.makeSnapshot().latestFailure == .init(code: "transaction_failed", sequence: 1))
        let preview = await attachConsumerForTesting(
            runtime, surfaceIdentity: identity, kind: .preview,
            owner: .init(source: .localUI), demand: runtimeConsumerDemand()
        )
        _ = await attachConsumerForTesting(
            runtime, surfaceIdentity: identity, kind: .lanWebView,
            owner: .init(source: .sharingService), demand: runtimeConsumerDemand()
        )
        runtime.captureSessionDidTerminate(displayID: 42)
        #expect(runtime.makeSnapshot().latestFailure == .init(code: DisplayRuntimeCaptureIntentFailureCode.streamStopped, sequence: 2))
        runtime.captureSessionDidTerminate(displayID: 42)
        #expect(runtime.makeSnapshot().latestFailure?.sequence == 2)
        #expect(runtime.currentConsumerLeaseSnapshot().map(\.id) == [preview.id])
        catalog.snapshot = .empty
        #expect(await runtime.retryPreviewConsumer(leaseID: preview.id)?.state == .failed)
        #expect(runtime.makeSnapshot().latestFailure == .init(code: DisplayRuntimeCaptureIntentFailureCode.displayUnavailable, sequence: 3))
        await finishFailure(runtime, code: "later_transaction_failed")
        #expect(runtime.makeSnapshot().latestFailure == .init(code: "later_transaction_failed", sequence: 4))
    }

    @Test func transactionCancellationAndRepeatedPropagationDoNotRefreshFailure() async {
        let runtime = DisplayRuntime()
        let identity = DisplaySurfaceIdentity.physicalDisplay(displayID: 42)
        let intent = runtime.submitCaptureIntent(surfaceIdentity: identity, reason: .transactionQuiesce)
        runtime.recordCaptureIntentApplyResult(.failed(revision: intent.revision, failureCode: "drain_failed"))
        await finishFailure(runtime, code: "consumer_session_quiesce_failed", phase: .quiescingSessions)
        await finishFailure(runtime, code: "cancelled_before_virtual_display_command", status: .cancelled, phase: .cancelled)
        await finishFailure(runtime, code: "edit_request_stale")
        #expect(runtime.makeSnapshot().latestFailure == .init(code: "drain_failed", sequence: 1))
        let id = DisplayRuntimeTransactionID()
        await finishFailure(runtime, id: id, code: "command_failed")
        _ = await runtime.finalizeTransaction(
            transactionID: id, status: .failed, phase: .failed,
            failure: .init(phase: .executingVirtualDisplayCommand, reason: "command_failed", recoverability: .retryable),
            virtualDisplayCommandSucceeded: false
        )
        #expect(runtime.makeSnapshot().latestFailure == .init(code: "command_failed", sequence: 2))
        let successfulID = DisplayRuntimeTransactionID()
        runtime.setActiveTrace(runtime.makeInitialTrace(transactionID: successfulID, kind: .virtualDisplayRebuild, source: .diagnostics))
        _ = await runtime.finalizeTransaction(transactionID: successfulID, status: .completed, phase: .completed, failure: nil, virtualDisplayCommandSucceeded: true)
        #expect(runtime.makeSnapshot().latestFailure == .init(code: "command_failed", sequence: 2))
    }

    @Test func compensationFailureIsRecordedOnceAtTransactionCompletion() async {
        let runtime = DisplayRuntime()
        let id = DisplayRuntimeTransactionID()
        runtime.setActiveTrace(runtime.makeInitialTrace(transactionID: id, kind: .virtualDisplayRebuild, source: .diagnostics))
        _ = await runtime.finalizeTransaction(
            transactionID: id, status: .failed, phase: .failed,
            failure: .init(phase: .executingVirtualDisplayCommand, reason: "command_failed", recoverability: .retryable),
            virtualDisplayCommandSucceeded: false,
            compensation: .init(status: .degraded, restoredSharingCount: 0, restoredPreviewCount: 0, failedRestoreCount: 0, failureReason: "compensation_failed")
        )
        #expect(runtime.makeSnapshot().latestFailure == .init(code: "compensation_failed", sequence: 2))
    }

    @Test func removedConsumerLateFailureDoesNotBecomeLatestFailure() async throws {
        let identity = DisplaySurfaceIdentity.physicalDisplay(displayID: 42)
        let commander = FakeCaptureIntentCommander { intent in
            intent.reason == .attach
                ? .failed(revision: intent.revision, failureCode: "late_attach_failure")
                : .applied(revision: intent.revision)
        }
        commander.shouldGateApply = true
        let runtime = DisplayRuntime(captureIntentCommander: commander)
        await finishFailure(runtime, code: "valid_failure")
        let attachment = Task {
            await runtime.attachPreviewConsumer(surfaceIdentity: identity, owner: .init(source: .localUI), demand: runtimeConsumerDemand())
        }
        await commander.waitForApplyCalls(1)
        let leaseID = try #require(runtime.currentConsumerLeaseSnapshot().first?.id)
        let close = Task { await runtime.detachPreviewConsumer(leaseID: leaseID) }
        for _ in 0..<1_000 where runtime.consumerLease(leaseID: leaseID) != nil { await Task.yield() }
        commander.shouldGateApply = false
        commander.releaseApply(call: 1)
        #expect(await attachment.value == .invalidated)
        _ = await close.value
        #expect(runtime.makeSnapshot().latestFailure == .init(code: "valid_failure", sequence: 1))
    }
}

@MainActor
private func finishFailure(
    _ runtime: DisplayRuntime,
    id: DisplayRuntimeTransactionID = .init(),
    code: String,
    status: DisplayRuntimeTransactionStatus = .failed,
    phase: DisplayRuntimeTransactionPhase = .executingVirtualDisplayCommand
) async {
    runtime.setActiveTrace(runtime.makeInitialTrace(transactionID: id, kind: .virtualDisplayRebuild, source: .diagnostics))
    _ = await runtime.finalizeTransaction(
        transactionID: id, status: status, phase: status == .cancelled ? .cancelled : .failed,
        failure: .init(phase: phase, reason: code, recoverability: .retryable),
        virtualDisplayCommandSucceeded: false
    )
}
