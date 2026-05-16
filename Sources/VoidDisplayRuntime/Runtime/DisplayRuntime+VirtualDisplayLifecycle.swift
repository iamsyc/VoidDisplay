import Foundation

@MainActor
extension DisplayRuntime {
    @discardableResult
    package func setVirtualDisplayDesiredEnabled(
        configID: UUID,
        enabled: Bool,
        source: DisplayRuntimeTransactionSource
    ) async throws -> DisplayRuntimeVirtualDisplayRebuildTransactionResult {
        let kind: DisplayRuntimeTransactionKind = enabled ? .virtualDisplayEnable : .virtualDisplayDisable
        return try await enqueueVirtualDisplayTransaction(
            kind: kind,
            configID: configID,
            source: source
        ) { context in
            try await self.executeVirtualDisplayDesiredEnabledTransaction(context, desiredEnabled: enabled)
        }
    }

    private func executeVirtualDisplayDesiredEnabledTransaction(
        _ context: ActiveVirtualDisplayTransactionContext,
        desiredEnabled: Bool
    ) async throws -> DisplayRuntimeVirtualDisplayRebuildTransactionResult {
        do {
            try Task.checkCancellation()
        } catch {
            _ = finalizeTransaction(
                transactionID: context.transactionID,
                kind: context.kind,
                status: .cancelled,
                phase: .cancelled,
                failure: .init(
                    phase: .cancelled,
                    reason: "cancelled_before_virtual_display_command",
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                desiredEnabled: desiredEnabled
            )
            throw error
        }

        await appendPhase(.preparing, transactionID: context.transactionID)
        await refreshCatalogTopologyForTransaction()
        let preSnapshot = makeSnapshot()
        let preEvidence = DisplayRuntimeTransactionSnapshotEvidence(snapshot: preSnapshot)
        updateTrace(context.transactionID) { trace in
            trace.replacing(preSnapshotEvidence: preEvidence)
        }

        guard preSnapshot.virtualDisplay.configs.contains(where: { $0.id == context.configID }) else {
            return finalizeTransaction(
                transactionID: context.transactionID,
                kind: context.kind,
                status: .failed,
                phase: .failed,
                failure: .init(
                    phase: .preparing,
                    reason: "config_not_found",
                    recoverability: .unrecoverable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: preSnapshot,
                desiredEnabled: desiredEnabled
            )
        }

        guard let virtualDisplayCommander else {
            return finalizeTransaction(
                transactionID: context.transactionID,
                kind: context.kind,
                status: .failed,
                phase: .failed,
                failure: .init(
                    phase: .preparing,
                    reason: "virtual_display_commander_unavailable",
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: preSnapshot,
                desiredEnabled: desiredEnabled
            )
        }

        let targetPreDisplayID = preSnapshot.surfaces
            .first(where: { $0.identity == .managedVirtualDisplay(configID: context.configID) })?
            .currentDisplayID
        var enablePreflight: DisplayRuntimeVirtualDisplayEnablePreflight?
        if desiredEnabled {
            do {
                enablePreflight = try await virtualDisplayCommander.preflightEnableVirtualDisplay(
                    request: .init(configID: context.configID, targetPreDisplayID: targetPreDisplayID)
                )
                updateTrace(context.transactionID) { trace in
                    trace.replacing(enablePreflight: enablePreflight)
                }
            } catch {
                _ = finalizeTransaction(
                    transactionID: context.transactionID,
                    kind: context.kind,
                    status: .failed,
                    phase: .failed,
                    failure: transactionFailure(
                        phase: .preparing,
                        reason: "virtual_display_enable_preflight_failed",
                        error: error,
                        recoverability: .retryable
                    ),
                    virtualDisplayCommandSucceeded: false,
                    postSnapshot: makeSnapshot(),
                    desiredEnabled: desiredEnabled
                )
                throw error
            }
        }

        await appendPhase(.persistingConfig, transactionID: context.transactionID)
        do {
            let persistenceResult = try await virtualDisplayCommander.setVirtualDisplayDesiredEnabled(
                request: .init(configID: context.configID, enabled: desiredEnabled)
            )
            updateTrace(context.transactionID) { trace in
                trace.replacing(persistenceOutcome: persistenceResult.persistenceOutcome)
            }
            guard persistenceResult.persistenceOutcome == .saved else {
                return finalizeTransaction(
                    transactionID: context.transactionID,
                    kind: context.kind,
                    status: .failed,
                    phase: .failed,
                    failure: .init(
                        phase: .persistingConfig,
                        reason: "virtual_display_desired_enabled_save_failed",
                        recoverability: .retryable
                    ),
                    virtualDisplayCommandSucceeded: false,
                    postSnapshot: makeSnapshot(),
                    desiredEnabled: desiredEnabled,
                    persistenceOutcome: persistenceResult.persistenceOutcome
                )
            }
        } catch {
            _ = finalizeTransaction(
                transactionID: context.transactionID,
                kind: context.kind,
                status: .failed,
                phase: .failed,
                failure: transactionFailure(
                    phase: .persistingConfig,
                    reason: "virtual_display_desired_enabled_save_failed",
                    error: error,
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: makeSnapshot(),
                desiredEnabled: desiredEnabled,
                persistenceOutcome: .failed
            )
            throw error
        }

        let affectedScope = makeLifecycleAffectedScope(
            kind: context.kind,
            configID: context.configID,
            snapshot: preSnapshot,
            enablePreflight: enablePreflight
        )
        let pauseIntents = makePauseIntents(
            affectedSurfaces: affectedScope.surfaces,
            snapshot: preSnapshot
        )
        updateTrace(context.transactionID) { trace in
            trace.replacing(
                affectedSurfaces: affectedScope.surfaces,
                pauseIntents: pauseIntents,
                scopeEscalationReason: affectedScope.scopeEscalationReason
            )
        }

        await appendPhase(.quiescingSessions, transactionID: context.transactionID)
        quiesceSessions(pauseIntents)

        await appendPhase(.executingVirtualDisplayCommand, transactionID: context.transactionID)
        do {
            let request = DisplayRuntimeVirtualDisplayLifecycleCommandRequest(
                configID: context.configID,
                targetPreDisplayID: targetPreDisplayID
            )
            if desiredEnabled {
                _ = try await virtualDisplayCommander.enableVirtualDisplay(request: request)
            } else {
                _ = try await virtualDisplayCommander.disableVirtualDisplay(request: request)
            }
            updateTrace(context.transactionID) { trace in
                trace.replacing(virtualDisplayCommandOutcome: .succeeded)
            }
        } catch {
            _ = finalizeTransaction(
                transactionID: context.transactionID,
                kind: context.kind,
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
                compensation: .init(
                    status: .degraded,
                    restoredSharingCount: 0,
                    restoredPreviewCount: 0,
                    failedRestoreCount: pauseIntents.count
                ),
                desiredEnabled: desiredEnabled,
                virtualDisplayCommandOutcome: .failed
            )
            throw error
        }

        await appendPhase(.waitingForTopology, transactionID: context.transactionID)
        let topologyResult = await waitForPostCommandTopology(
            kind: context.kind,
            affectedSurfaces: affectedScope.surfaces
        )
        if topologyResult.status == .stable {
            convergeToVisibleDisplaysFromCurrentCatalog()
            await observabilityRecorder?.refreshSnapshot(reason: .screenCatalogStateChanged)
        }
        let postConvergenceSnapshot = makeSnapshot()
        let restoreIntents = makeLifecycleSessionRestoreIntents(
            kind: context.kind,
            targetConfigID: context.configID,
            pauseIntents: pauseIntents,
            topologyResult: topologyResult,
            preSnapshot: preSnapshot,
            postSnapshot: postConvergenceSnapshot
        )
        updateTrace(context.transactionID) { trace in
            trace.replacing(restoreIntents: restoreIntents)
        }
        if !restoreIntents.isEmpty {
            await appendPhase(.restoringSessions, transactionID: context.transactionID)
        }
        let disabledTargetIdentity: DisplaySurfaceIdentity? = desiredEnabled
            ? nil
            : .managedVirtualDisplay(configID: context.configID)
        let sharingRestoreResults = await restoreSharingSessions(
            restoreIntents,
            topologyResult: topologyResult,
            postSnapshot: postConvergenceSnapshot,
            disabledTargetIdentity: disabledTargetIdentity
        )
        let previewRestoreResults = makeDeferredPreviewRestoreResults(
            restoreIntents,
            topologyResult: topologyResult,
            disabledTargetIdentity: disabledTargetIdentity
        )
        let restoreResults = sharingRestoreResults + previewRestoreResults
        updateTrace(context.transactionID) { trace in
            trace.replacing(restoreResults: restoreResults)
        }
        let finalPostSnapshot = makeSnapshot()
        let finalStatus = transactionStatus(
            after: topologyResult,
            restoreResults: restoreResults
        )
        return finalizeTransaction(
            transactionID: context.transactionID,
            kind: context.kind,
            status: finalStatus,
            phase: .completed,
            failure: nil,
            virtualDisplayCommandSucceeded: true,
            postSnapshot: finalPostSnapshot,
            topologyStabilityResult: topologyResult,
            compensation: compensationResult(
                after: topologyResult,
                restoreResults: restoreResults,
                restoreIntentCount: restoreIntents.count
            ),
            desiredEnabled: desiredEnabled
        )
    }
}
