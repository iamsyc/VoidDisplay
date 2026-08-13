import Foundation

@MainActor
extension DisplayRuntime {
    func makeInitialTrace(
        for context: ActiveVirtualDisplayTransactionContext
    ) -> DisplayRuntimeTransactionTrace {
        makeInitialTrace(
            transactionID: context.transactionID,
            kind: context.kind,
            source: context.source,
            targetConfigID: context.configID
        )
    }

    func makeInitialTrace(
        transactionID: DisplayRuntimeTransactionID,
        kind: DisplayRuntimeTransactionKind,
        source: DisplayRuntimeTransactionSource,
        targetConfigID: UUID? = nil
    ) -> DisplayRuntimeTransactionTrace {
        DisplayRuntimeTransactionTrace(
            id: transactionID,
            kind: kind,
            source: source,
            status: .active,
            phases: [.init(phase: .queued)],
            affectedSurfaces: [],
            preSnapshotEvidence: nil,
            postSnapshotEvidence: nil,
            pauseIntents: [],
            restoreIntents: [],
            restoreResults: [],
            failure: nil,
            compensation: .notRequired,
            coalescedRequestCount: 0,
            targetConfigID: targetConfigID
        )
    }

    func appendPhase(
        _ phase: DisplayRuntimeTransactionPhase,
        transactionID: DisplayRuntimeTransactionID,
        note: String? = nil
    ) async {
        updateTrace(transactionID) { trace in
            trace.replacing(phases: trace.phases + [.init(phase: phase, note: note)])
        }
        await recordTransactionPhaseEvent(phase, transactionID: transactionID)
        await observabilityRecorder?.refreshSnapshot(reason: .displayRuntimeTransactionChanged)
    }

    func incrementCoalescedRequestCount(transactionID: DisplayRuntimeTransactionID) {
        updateTrace(transactionID) { trace in
            trace.replacing(
                phases: trace.phases + [.init(phase: .queued, note: "coalesced_duplicate_request")],
                coalescedRequestCount: trace.coalescedRequestCount + 1
            )
        }
    }

    func finalizeTransaction(
        transactionID: DisplayRuntimeTransactionID,
        kind: DisplayRuntimeTransactionKind = .virtualDisplayRebuild,
        status: DisplayRuntimeTransactionStatus,
        phase: DisplayRuntimeTransactionPhase,
        failure: DisplayRuntimeTransactionFailure?,
        virtualDisplayCommandSucceeded: Bool,
        postSnapshot: DisplayRuntimeSnapshot? = nil,
        topologyStabilityResult: DisplayRuntimeTopologyStabilityResult? = nil,
        compensation: DisplayRuntimeCompensationResult? = nil,
        desiredEnabled: Bool? = nil,
        persistenceOutcome: DisplayRuntimePersistenceOutcome? = nil,
        virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome? = nil,
        runtimeTrackingClearOutcome: DisplayRuntimeVirtualDisplayRuntimeTrackingClearOutcome? = nil
    ) async -> DisplayRuntimeVirtualDisplayRebuildTransactionResult {
        let postEvidence = postSnapshot.map(DisplayRuntimeTransactionSnapshotEvidence.init(snapshot:))
        updateTrace(transactionID) { trace in
            trace.replacing(
                status: status,
                phases: trace.phases + [.init(phase: phase)],
                postSnapshotEvidence: postEvidence ?? trace.postSnapshotEvidence,
                topologyStabilityResult: topologyStabilityResult,
                failure: failure,
                compensation: compensation,
                persistenceOutcome: persistenceOutcome,
                virtualDisplayCommandOutcome: virtualDisplayCommandOutcome,
                runtimeTrackingClearOutcome: runtimeTrackingClearOutcome
            )
        }
        if let trace = activeTransactionTracesByID.removeValue(forKey: transactionID) {
            recentTransactionTraces.insert(trace, at: 0)
            if recentTransactionTraces.count > 20 {
                recentTransactionTraces = Array(recentTransactionTraces.prefix(20))
            }
        }
        await recordTransactionPhaseEvent(phase, transactionID: transactionID)
        await observabilityRecorder?.refreshSnapshot(reason: .displayRuntimeTransactionChanged)
        return DisplayRuntimeVirtualDisplayRebuildTransactionResult(
            transactionID: transactionID,
            kind: kind,
            status: status,
            virtualDisplayCommandSucceeded: virtualDisplayCommandSucceeded,
            hasSessionRecoveryFailures: status == .completedWithRecoveryFailures,
            desiredEnabled: desiredEnabled
        )
    }

    func setActiveTrace(_ trace: DisplayRuntimeTransactionTrace) {
        activeTransactionTracesByID[trace.id] = trace
    }

    func updateTrace(
        _ transactionID: DisplayRuntimeTransactionID,
        _ update: (DisplayRuntimeTransactionTrace) -> DisplayRuntimeTransactionTrace
    ) {
        guard let trace = activeTransactionTracesByID[transactionID] else { return }
        activeTransactionTracesByID[transactionID] = update(trace)
    }

    func transactionFailure(
        phase: DisplayRuntimeTransactionPhase,
        reason: String,
        error: Error,
        recoverability: DisplayRuntimeTransactionRecoverability
    ) -> DisplayRuntimeTransactionFailure {
        let nsError = error as NSError
        return DisplayRuntimeTransactionFailure(
            phase: phase,
            reason: reason,
            underlyingDomain: nsError.domain,
            underlyingCode: nsError.code,
            recoverability: recoverability
        )
    }

    private func recordTransactionPhaseEvent(
        _ phase: DisplayRuntimeTransactionPhase,
        transactionID: DisplayRuntimeTransactionID
    ) async {
        await observabilityRecorder?.record(
            DisplayRuntimeTransactionObservability.event(
                phase: phase,
                transactionID: transactionID
            )
        )
    }
}
