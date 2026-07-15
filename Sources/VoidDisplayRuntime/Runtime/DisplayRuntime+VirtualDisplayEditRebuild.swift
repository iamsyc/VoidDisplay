import Foundation

@MainActor
extension DisplayRuntime {
    package func saveVirtualDisplayConfigAndRebuild(
        request: DisplayRuntimeVirtualDisplayEditRebuildRequest,
        source: DisplayRuntimeTransactionSource
    ) async throws -> DisplayRuntimeVirtualDisplayEditRebuildTransactionHandle {
        let effectiveRequest = DisplayRuntimeVirtualDisplayEditRebuildRequest(
            transactionID: request.transactionID,
            editedConfig: request.editedConfig,
            expectedConfigFingerprint: request.expectedConfigFingerprint,
            source: source
        )
        let context = ActiveVirtualDisplayTransactionContext(
            transactionID: effectiveRequest.transactionID,
            kind: .virtualDisplayEditRebuild,
            configID: effectiveRequest.editedConfig.id,
            source: source
        )
        let saveGate = DisplayRuntimeAsyncGate<DisplayRuntimeVirtualDisplayEditRebuildSaveGateResult>()
        return await enqueueUncoalescedVirtualDisplayEditTransaction(
            context: context,
            saveGate: saveGate,
            execute: {
                await self.executeVirtualDisplayEditRebuildTransaction(
                    effectiveRequest,
                    saveGate: saveGate
                )
            }
        )
    }

    private func executeVirtualDisplayEditRebuildTransaction(
        _ request: DisplayRuntimeVirtualDisplayEditRebuildRequest,
        saveGate: DisplayRuntimeAsyncGate<DisplayRuntimeVirtualDisplayEditRebuildSaveGateResult>
    ) async -> DisplayRuntimeVirtualDisplayRebuildTransactionResult {
        do {
            try Task.checkCancellation()
        } catch {
            saveGate.fail(DisplayRuntimeVirtualDisplayEditRebuildFailure(reason: "cancelled_before_virtual_display_command"))
            return finalizeTransaction(
                transactionID: request.transactionID,
                kind: .virtualDisplayEditRebuild,
                status: .cancelled,
                phase: .cancelled,
                failure: .init(
                    phase: .cancelled,
                    reason: "cancelled_before_virtual_display_command",
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                virtualDisplayCommandOutcome: .notAttempted
            )
        }

        await appendPhase(.preparing, transactionID: request.transactionID)
        await refreshCatalogTopologyForTransaction()
        let preSnapshot = makeSnapshot()
        let preEvidence = DisplayRuntimeTransactionSnapshotEvidence(snapshot: preSnapshot)
        let editedConfigEvidence = DisplayRuntimeVirtualDisplayConfigEvidence(config: request.editedConfig)
        guard let oldSnapshotConfig = preSnapshot.virtualDisplay.configs.first(where: { $0.id == request.editedConfig.id }) else {
            updateTrace(request.transactionID) { trace in
                trace.replacing(
                    preSnapshotEvidence: preEvidence,
                    editedConfigEvidence: editedConfigEvidence
                )
            }
            saveGate.fail(DisplayRuntimeVirtualDisplayEditRebuildFailure(reason: "config_not_found"))
            return finalizeTransaction(
                transactionID: request.transactionID,
                kind: .virtualDisplayEditRebuild,
                status: .failed,
                phase: .failed,
                failure: .init(
                    phase: .preparing,
                    reason: "config_not_found",
                    recoverability: .unrecoverable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: preSnapshot,
                persistenceOutcome: .notAttempted,
                virtualDisplayCommandOutcome: .notAttempted
            )
        }
        let oldConfigEvidence = DisplayRuntimeVirtualDisplayConfigEvidence(snapshotConfig: oldSnapshotConfig)
        updateTrace(request.transactionID) { trace in
            trace.replacing(
                preSnapshotEvidence: preEvidence,
                oldConfigEvidence: oldConfigEvidence,
                editedConfigEvidence: editedConfigEvidence
            )
        }

        await appendPhase(.persistingConfig, transactionID: request.transactionID)
        guard let virtualDisplayCommander else {
            saveGate.fail(DisplayRuntimeVirtualDisplayEditRebuildFailure(reason: "virtual_display_commander_unavailable"))
            return finalizeTransaction(
                transactionID: request.transactionID,
                kind: .virtualDisplayEditRebuild,
                status: .failed,
                phase: .failed,
                failure: .init(
                    phase: .persistingConfig,
                    reason: "virtual_display_commander_unavailable",
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: makeSnapshot(),
                persistenceOutcome: .notAttempted,
                virtualDisplayCommandOutcome: .notAttempted
            )
        }

        let saveResult: DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult
        do {
            saveResult = try await virtualDisplayCommander.saveConfigForRebuild(request: request)
        } catch DisplayRuntimeVirtualDisplayEditRebuildSaveCommandError.editRequestStale {
            saveGate.fail(DisplayRuntimeVirtualDisplayEditRebuildFailure(reason: "edit_request_stale"))
            return finalizeTransaction(
                transactionID: request.transactionID,
                kind: .virtualDisplayEditRebuild,
                status: .failed,
                phase: .failed,
                failure: .init(
                    phase: .persistingConfig,
                    reason: "edit_request_stale",
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: makeSnapshot(),
                persistenceOutcome: .failed,
                virtualDisplayCommandOutcome: .notAttempted
            )
        } catch {
            saveGate.fail(DisplayRuntimeVirtualDisplayEditRebuildFailure(reason: "config_save_failed"))
            return finalizeTransaction(
                transactionID: request.transactionID,
                kind: .virtualDisplayEditRebuild,
                status: .failed,
                phase: .failed,
                failure: transactionFailure(
                    phase: .persistingConfig,
                    reason: "config_save_failed",
                    error: error,
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: makeSnapshot(),
                persistenceOutcome: .failed,
                virtualDisplayCommandOutcome: .notAttempted
            )
        }

        guard saveResult.persistenceOutcome == .saved else {
            saveGate.fail(DisplayRuntimeVirtualDisplayEditRebuildFailure(reason: "config_save_failed"))
            return finalizeTransaction(
                transactionID: request.transactionID,
                kind: .virtualDisplayEditRebuild,
                status: .failed,
                phase: .failed,
                failure: .init(
                    phase: .persistingConfig,
                    reason: "config_save_failed",
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: makeSnapshot(),
                persistenceOutcome: saveResult.persistenceOutcome,
                virtualDisplayCommandOutcome: .notAttempted
            )
        }

        updateTrace(request.transactionID) { trace in
            trace.replacing(
                persistenceOutcome: saveResult.persistenceOutcome,
                savedConfigEvidence: saveResult.savedConfigEvidence
            )
        }
        saveGate.succeed(
            DisplayRuntimeVirtualDisplayEditRebuildSaveGateResult(
                transactionID: request.transactionID,
                configID: request.editedConfig.id,
                persistenceOutcome: saveResult.persistenceOutcome,
                savedConfigEvidence: saveResult.savedConfigEvidence
            )
        )

        let affectedSurfaces = makeAffectedSurfaces(
            configID: request.editedConfig.id,
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
            let persistenceCompensation = await compensateFailedEditRebuild(
                transactionID: request.transactionID,
                previousConfigForCompensation: saveResult.previousConfigForCompensation,
                virtualDisplayCommander: virtualDisplayCommander,
                shouldRebuild: false
            )
            let restoreResults = await compensateConsumerQuiesceFailure(
                consumerTransition,
                transactionID: request.transactionID
            )
            let compensation = mergingCompensation(
                persistenceCompensation,
                with: consumerCompensationResult(
                    restoreResults: restoreResults,
                    restoreIntentCount: consumerTransition.restoreIntentCount
                )
            )
            return finalizeTransaction(
                transactionID: request.transactionID,
                kind: .virtualDisplayEditRebuild,
                status: .failed,
                phase: .failed,
                failure: .init(
                    phase: .quiescingSessions,
                    reason: "consumer_session_quiesce_failed",
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: makeSnapshot(),
                compensation: compensation,
                persistenceOutcome: saveResult.persistenceOutcome,
                virtualDisplayCommandOutcome: .notAttempted
            )
        }

        await appendPhase(.executingVirtualDisplayCommand, transactionID: request.transactionID)
        do {
            _ = try await virtualDisplayCommander.rebuildVirtualDisplay(configID: request.editedConfig.id)
            updateTrace(request.transactionID) { trace in
                trace.replacing(virtualDisplayCommandOutcome: .succeeded)
            }
        } catch {
            let persistenceCompensation = await compensateFailedEditRebuild(
                transactionID: request.transactionID,
                previousConfigForCompensation: saveResult.previousConfigForCompensation,
                virtualDisplayCommander: virtualDisplayCommander
            )
            let restoreResults = await compensateConsumerTransition(consumerTransition)
            updateTrace(request.transactionID) { trace in
                trace.replacing(restoreResults: restoreResults)
            }
            let compensation = mergingCompensation(
                persistenceCompensation,
                with: consumerCompensationResult(
                    restoreResults: restoreResults,
                    restoreIntentCount: consumerTransition.restoreIntentCount
                )
            )
            return finalizeTransaction(
                transactionID: request.transactionID,
                kind: .virtualDisplayEditRebuild,
                status: .failed,
                phase: .failed,
                failure: transactionFailure(
                    phase: .executingVirtualDisplayCommand,
                    reason: "virtual_display_command_failed",
                    error: error,
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: makeSnapshot(),
                compensation: compensation,
                persistenceOutcome: saveResult.persistenceOutcome,
                virtualDisplayCommandOutcome: .failed
            )
        }

        await appendPhase(.waitingForTopology, transactionID: request.transactionID)
        let topologyResult = await waitForPostCommandTopology(
            kind: .virtualDisplayEditRebuild,
            affectedSurfaces: affectedSurfaces
        )
        if topologyResult.status == .stable {
            await convergeToVisibleDisplaysFromCurrentCatalog()
            await observabilityRecorder?.refreshSnapshot(reason: .screenCatalogStateChanged)
        }
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
            kind: .virtualDisplayEditRebuild,
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
            ),
            persistenceOutcome: saveResult.persistenceOutcome,
            virtualDisplayCommandOutcome: .succeeded
        )
    }

    private func compensateFailedEditRebuild(
        transactionID: DisplayRuntimeTransactionID,
        previousConfigForCompensation: DisplayRuntimeVirtualDisplayConfigEditDTO,
        virtualDisplayCommander: any DisplayRuntimeVirtualDisplayCommanding,
        shouldRebuild: Bool = true
    ) async -> DisplayRuntimeCompensationResult {
        await appendPhase(
            .compensatingPersistence,
            transactionID: transactionID,
            note: "restore_old_config_after_failed_edit"
        )

        do {
            let restoreResult = try await virtualDisplayCommander.restoreConfigAfterFailedEdit(
                request: .init(
                    transactionID: transactionID,
                    previousConfigForCompensation: previousConfigForCompensation
                )
            )
            guard restoreResult.persistenceOutcome == .rolledBack || restoreResult.persistenceOutcome == .saved else {
                return .init(
                    status: .degraded,
                    restoredSharingCount: 0,
                    restoredPreviewCount: 0,
                    failedRestoreCount: 1,
                    persistenceOutcome: restoreResult.persistenceOutcome,
                    virtualDisplayCommandOutcome: .notAttempted,
                    failureReason: "persistence_compensation_failed"
                )
            }

            guard shouldRebuild else {
                return .init(
                    status: .completed,
                    restoredSharingCount: 0,
                    restoredPreviewCount: 0,
                    failedRestoreCount: 0,
                    persistenceOutcome: restoreResult.persistenceOutcome,
                    virtualDisplayCommandOutcome: .notAttempted,
                    failureReason: nil
                )
            }

            do {
                _ = try await virtualDisplayCommander.rebuildVirtualDisplay(
                    configID: previousConfigForCompensation.id
                )
                return .init(
                    status: .completed,
                    restoredSharingCount: 0,
                    restoredPreviewCount: 0,
                    failedRestoreCount: 0,
                    persistenceOutcome: restoreResult.persistenceOutcome,
                    virtualDisplayCommandOutcome: .succeeded,
                    failureReason: nil
                )
            } catch {
                return .init(
                    status: .degraded,
                    restoredSharingCount: 0,
                    restoredPreviewCount: 0,
                    failedRestoreCount: 1,
                    persistenceOutcome: restoreResult.persistenceOutcome,
                    virtualDisplayCommandOutcome: .failed,
                    failureReason: "compensation_rebuild_failed"
                )
            }
        } catch {
            return .init(
                status: .degraded,
                restoredSharingCount: 0,
                restoredPreviewCount: 0,
                failedRestoreCount: 1,
                persistenceOutcome: .rollbackFailed,
                virtualDisplayCommandOutcome: .notAttempted,
                failureReason: "persistence_compensation_failed"
            )
        }
    }
}
