import Foundation

@MainActor
extension DisplayRuntime {
    @discardableResult
    package func rebuildVirtualDisplay(
        configID: UUID,
        source: DisplayRuntimeTransactionSource
    ) async throws -> DisplayRuntimeVirtualDisplayRebuildTransactionResult {
        try await enqueueVirtualDisplayTransaction(
            kind: .virtualDisplayRebuild,
            configID: configID,
            source: source
        ) { context in
            let request = DisplayRuntimeVirtualDisplayRebuildRequest(
                transactionID: context.transactionID,
                configID: context.configID,
                source: context.source
            )
            return try await self.executeVirtualDisplayRebuildTransaction(request)
        }
    }

    private func executeVirtualDisplayRebuildTransaction(
        _ request: DisplayRuntimeVirtualDisplayRebuildRequest
    ) async throws -> DisplayRuntimeVirtualDisplayRebuildTransactionResult {
        do {
            try Task.checkCancellation()
        } catch {
            _ = finalizeTransaction(
                transactionID: request.transactionID,
                status: .cancelled,
                phase: .cancelled,
                failure: .init(
                    phase: .cancelled,
                    reason: "cancelled_before_virtual_display_command",
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false
            )
            throw error
        }

        await appendPhase(.preparing, transactionID: request.transactionID)
        await refreshCatalogTopologyForTransaction()
        let preSnapshot = makeSnapshot()
        let preEvidence = DisplayRuntimeTransactionSnapshotEvidence(snapshot: preSnapshot)
        updateTrace(request.transactionID) { trace in
            trace.replacing(preSnapshotEvidence: preEvidence)
        }

        guard preSnapshot.virtualDisplay.configs.contains(where: { $0.id == request.configID }) else {
            return finalizeTransaction(
                transactionID: request.transactionID,
                status: .failed,
                phase: .failed,
                failure: .init(
                    phase: .preparing,
                    reason: "config_not_found",
                    recoverability: .unrecoverable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: preSnapshot
            )
        }

        let affectedSurfaces = makeAffectedSurfaces(
            configID: request.configID,
            snapshot: preSnapshot
        )
        let pauseIntents = makePauseIntents(
            affectedSurfaces: affectedSurfaces,
            snapshot: preSnapshot
        )
        updateTrace(request.transactionID) { trace in
            trace.replacing(
                affectedSurfaces: affectedSurfaces,
                pauseIntents: pauseIntents
            )
        }

        await appendPhase(.quiescingSessions, transactionID: request.transactionID)
        let consumerTransition = await beginConsumerTransition(
            affectedSurfaces: affectedSurfaces
        )
        guard !consumerTransition.hasQuiesceFailure else {
            let restoreResults = await compensateConsumerQuiesceFailure(
                consumerTransition,
                transactionID: request.transactionID
            )
            return finalizeTransaction(
                transactionID: request.transactionID,
                status: .failed,
                phase: .failed,
                failure: .init(
                    phase: .quiescingSessions,
                    reason: "consumer_session_quiesce_failed",
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: makeSnapshot(),
                compensation: consumerCompensationResult(
                    restoreResults: restoreResults,
                    restoreIntentCount: consumerTransition.restoreIntentCount
                )
            )
        }

        await appendPhase(.executingVirtualDisplayCommand, transactionID: request.transactionID)
        guard let virtualDisplayCommander else {
            let restoreResults = await compensateConsumerTransition(consumerTransition)
            updateTrace(request.transactionID) { trace in
                trace.replacing(restoreResults: restoreResults)
            }
            return finalizeTransaction(
                transactionID: request.transactionID,
                status: .failed,
                phase: .failed,
                failure: .init(
                    phase: .executingVirtualDisplayCommand,
                    reason: "virtual_display_commander_unavailable",
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: makeSnapshot(),
                compensation: consumerCompensationResult(
                    restoreResults: restoreResults,
                    restoreIntentCount: consumerTransition.restoreIntentCount
                )
            )
        }

        do {
            _ = try await virtualDisplayCommander.rebuildVirtualDisplay(configID: request.configID)
        } catch {
            let restoreResults = await compensateConsumerTransition(consumerTransition)
            let postSnapshot = makeSnapshot()
            updateTrace(request.transactionID) { trace in
                trace.replacing(restoreResults: restoreResults)
            }
            _ = finalizeTransaction(
                transactionID: request.transactionID,
                status: .failed,
                phase: .failed,
                failure: transactionFailure(
                    phase: .executingVirtualDisplayCommand,
                    reason: "virtual_display_command_failed",
                    error: error,
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: postSnapshot,
                compensation: consumerCompensationResult(
                    restoreResults: restoreResults,
                    restoreIntentCount: consumerTransition.restoreIntentCount
                )
            )
            throw error
        }

        await appendPhase(.waitingForTopology, transactionID: request.transactionID)
        let topologyResult = await waitForPostCommandTopology(
            kind: .virtualDisplayRebuild,
            affectedSurfaces: affectedSurfaces
        )
        let postConvergenceSnapshot = makeSnapshot()
        let restoreIntents = makeSessionRestoreIntents(
            pauseIntents: pauseIntents,
            topologyResult: topologyResult,
            preSnapshot: preSnapshot,
            postSnapshot: postConvergenceSnapshot
        )
        updateTrace(request.transactionID) { trace in
            trace.replacing(restoreIntents: restoreIntents)
        }
        if !restoreIntents.isEmpty {
            await appendPhase(.restoringSessions, transactionID: request.transactionID)
        }
        let restoreResults = await completeConsumerTransition(
            consumerTransition,
            snapshot: postConvergenceSnapshot,
            topologyResult: topologyResult,
            releasedSurfaceReasons: [:]
        )
        updateTrace(request.transactionID) { trace in
            trace.replacing(restoreResults: restoreResults)
        }
        let finalPostSnapshot = makeSnapshot()
        let finalStatus = transactionStatus(
            after: topologyResult,
            restoreResults: restoreResults
        )
        return finalizeTransaction(
            transactionID: request.transactionID,
            status: finalStatus,
            phase: .completed,
            failure: nil,
            virtualDisplayCommandSucceeded: true,
            postSnapshot: finalPostSnapshot,
            topologyStabilityResult: topologyResult,
            compensation: compensationResult(
                after: topologyResult,
                restoreResults: restoreResults,
                restoreIntentCount: consumerTransition.restoreIntentCount
            )
        )
    }
}
