import Foundation

@MainActor
extension DisplayRuntime {
    @discardableResult
    package func restoreStartupVirtualDisplays(
        source: DisplayRuntimeTransactionSource = .startup
    ) async -> DisplayRuntimeStartupRestoreResult {
        if let completedStartupRestoreResult {
            return completedStartupRestoreResult.replacing(duplicateBehavior: .alreadyCompleted)
        }

        if let activeStartupRestoreTask {
            activeStartupRestoreCoalescedRequestCount += 1
            await observabilityRecorder?.refreshSnapshot(reason: .displayRuntimeTransactionChanged)
            let result = await activeStartupRestoreTask.value
            return result.replacing(duplicateBehavior: .coalesced)
        }

        let runID = DisplayRuntimeStartupRestoreRunID()
        activeStartupRestoreCoalescedRequestCount = 0
        let task = Task { @MainActor in
            let result = await self.executeStartupRestoreRun(runID: runID, source: source)
            let finalResult = result.replacing(coalescedRequestCount: self.activeStartupRestoreCoalescedRequestCount)
            self.completedStartupRestoreResult = finalResult
            self.activeStartupRestoreTask = nil
            self.activeStartupRestoreCoalescedRequestCount = 0
            await self.observabilityRecorder?.refreshSnapshot(reason: .displayRuntimeTransactionChanged)
            return finalResult
        }
        activeStartupRestoreTask = task
        await observabilityRecorder?.refreshSnapshot(reason: .displayRuntimeTransactionChanged)
        return await task.value
    }

    private func executeStartupRestoreRun(
        runID: DisplayRuntimeStartupRestoreRunID,
        source: DisplayRuntimeTransactionSource
    ) async -> DisplayRuntimeStartupRestoreResult {
        guard let startupRestoreCommander else {
            let loadTrace = DisplayRuntimeStartupRestoreConfigLoadTrace(
                status: .failed,
                persistedConfigIDs: [],
                desiredEnabledConfigIDs: [],
                desiredDisabledConfigIDs: [],
                failureReason: "virtual_display_commander_unavailable",
                underlyingDomain: nil,
                underlyingCode: nil
            )
            let traceID = await recordStartupRestoreTerminalTrace(
                runID: runID,
                source: source,
                loadTrace: loadTrace,
                status: .failed,
                failure: .init(
                    phase: .preparing,
                    reason: "virtual_display_commander_unavailable",
                    recoverability: .retryable
                )
            )
            return DisplayRuntimeStartupRestoreResult(
                runID: runID,
                status: .failed,
                source: source,
                duplicateBehavior: .started,
                configLoadTrace: loadTrace,
                configResults: [],
                traceIDs: [traceID],
                coalescedRequestCount: activeStartupRestoreCoalescedRequestCount
            )
        }

        let loadResult = await startupRestoreCommander.loadPersistedVirtualDisplayConfigsForStartupRestore()
        let loadTrace = DisplayRuntimeStartupRestoreConfigLoadTrace(loadResult: loadResult)
        guard loadResult.status == .succeeded else {
            let reason = loadResult.failureReason ?? "startup_persisted_config_load_failed"
            let traceID = await recordStartupRestoreTerminalTrace(
                runID: runID,
                source: source,
                loadTrace: loadTrace,
                status: .failed,
                failure: .init(
                    phase: .preparing,
                    reason: reason,
                    underlyingDomain: loadResult.underlyingDomain,
                    underlyingCode: loadResult.underlyingCode,
                    recoverability: .retryable
                )
            )
            return DisplayRuntimeStartupRestoreResult(
                runID: runID,
                status: .failed,
                source: source,
                duplicateBehavior: .started,
                configLoadTrace: loadTrace,
                configResults: [],
                traceIDs: [traceID],
                coalescedRequestCount: activeStartupRestoreCoalescedRequestCount
            )
        }

        let desiredEnabledConfigs = loadResult.configs.filter(\.desiredEnabled)
        guard !desiredEnabledConfigs.isEmpty else {
            let traceID = await recordStartupRestoreTerminalTrace(
                runID: runID,
                source: source,
                loadTrace: loadTrace,
                status: .completed,
                failure: nil
            )
            return DisplayRuntimeStartupRestoreResult(
                runID: runID,
                status: .succeededNoOp,
                source: source,
                duplicateBehavior: .started,
                configLoadTrace: loadTrace,
                configResults: [],
                traceIDs: [traceID],
                coalescedRequestCount: activeStartupRestoreCoalescedRequestCount
            )
        }

        var configResults: [DisplayRuntimeStartupRestoreConfigResult] = []
        for config in desiredEnabledConfigs {
            let result = await restoreStartupConfig(
                runID: runID,
                source: source,
                loadTrace: loadTrace,
                config: config
            )
            configResults.append(result)
        }

        return DisplayRuntimeStartupRestoreResult(
            runID: runID,
            status: startupRestoreStatus(configResults: configResults),
            source: source,
            duplicateBehavior: .started,
            configLoadTrace: loadTrace,
            configResults: configResults,
            traceIDs: configResults.map(\.transactionID),
            coalescedRequestCount: activeStartupRestoreCoalescedRequestCount
        )
    }

    private func recordStartupRestoreTerminalTrace(
        runID: DisplayRuntimeStartupRestoreRunID,
        source: DisplayRuntimeTransactionSource,
        loadTrace: DisplayRuntimeStartupRestoreConfigLoadTrace,
        status: DisplayRuntimeTransactionStatus,
        failure: DisplayRuntimeTransactionFailure?
    ) async -> DisplayRuntimeTransactionID {
        let transactionID = DisplayRuntimeTransactionID()
        let context = ActiveVirtualDisplayInventoryTransactionContext(
            transactionID: transactionID,
            kind: .virtualDisplayStartupRestore,
            source: source
        )
        do {
            return try await enqueueUncoalescedVirtualDisplayTransaction(context: context) {
                await self.appendPhase(.preparing, transactionID: transactionID)
                await self.refreshCatalogTopologyForTransaction()
                let preSnapshot = self.makeSnapshot()
                self.updateTrace(transactionID) { trace in
                    trace.replacing(
                        preSnapshotEvidence: DisplayRuntimeTransactionSnapshotEvidence(snapshot: preSnapshot),
                        startupRestoreRunID: runID,
                        startupConfigLoadResult: loadTrace
                    )
                }
                let postSnapshot = self.makeSnapshot()
                _ = self.finalizeTransaction(
                    transactionID: transactionID,
                    kind: .virtualDisplayStartupRestore,
                    status: status,
                    phase: failure == nil ? .completed : .failed,
                    failure: failure,
                    virtualDisplayCommandSucceeded: false,
                    postSnapshot: postSnapshot,
                    compensation: self.startupRestoreTerminalCompensation(failure: failure)
                )
                return transactionID
            }
        } catch {
            return transactionID
        }
    }

    private func restoreStartupConfig(
        runID: DisplayRuntimeStartupRestoreRunID,
        source: DisplayRuntimeTransactionSource,
        loadTrace: DisplayRuntimeStartupRestoreConfigLoadTrace,
        config: DisplayRuntimeStartupRestoreConfig
    ) async -> DisplayRuntimeStartupRestoreConfigResult {
        let context = ActiveVirtualDisplayTransactionContext(
            transactionID: DisplayRuntimeTransactionID(),
            kind: .virtualDisplayStartupRestore,
            configID: config.id,
            source: source
        )
        do {
            return try await enqueueUncoalescedVirtualDisplayTransaction(context: context) {
                await self.executeStartupRestoreConfigTransaction(
                    context: context,
                    runID: runID,
                    loadTrace: loadTrace,
                    config: config
                )
            }
        } catch {
            return DisplayRuntimeStartupRestoreConfigResult(
                transactionID: context.transactionID,
                configID: context.configID,
                status: .failed,
                restoreOutcome: .failed,
                failureReason: "startup_restore_transaction_failed",
                topologyStabilityResult: nil
            )
        }
    }

    private func executeStartupRestoreConfigTransaction(
        context: ActiveVirtualDisplayTransactionContext,
        runID: DisplayRuntimeStartupRestoreRunID,
        loadTrace: DisplayRuntimeStartupRestoreConfigLoadTrace,
        config: DisplayRuntimeStartupRestoreConfig
    ) async -> DisplayRuntimeStartupRestoreConfigResult {
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
                    reason: "cancelled_before_startup_restore_command",
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false
            )
            return DisplayRuntimeStartupRestoreConfigResult(
                transactionID: context.transactionID,
                configID: context.configID,
                status: .failed,
                restoreOutcome: .notAttempted,
                failureReason: "cancelled_before_startup_restore_command",
                topologyStabilityResult: nil
            )
        }

        await appendPhase(.preparing, transactionID: context.transactionID)
        await refreshCatalogTopologyForTransaction()
        let preSnapshot = makeSnapshot()
        let startupIntent = DisplayRuntimeStartupRestoreIntent(
            runID: runID,
            configID: context.configID,
            configEvidence: config.evidence
        )
        updateTrace(context.transactionID) { trace in
            trace.replacing(
                preSnapshotEvidence: DisplayRuntimeTransactionSnapshotEvidence(snapshot: preSnapshot),
                startupRestoreRunID: runID,
                startupConfigLoadResult: loadTrace,
                startupRestoreIntent: startupIntent
            )
        }

        guard preSnapshot.virtualDisplay.configs.contains(where: { $0.id == context.configID }) else {
            return startupRestoreFailedConfigResult(
                transactionID: context.transactionID,
                configID: context.configID,
                phase: .preparing,
                reason: "config_not_found",
                restoreOutcome: .notAttempted,
                topologyResult: nil,
                postSnapshot: preSnapshot,
                recoverability: .unrecoverable
            )
        }

        let affectedSurfaces = makeAffectedSurfaces(
            configID: context.configID,
            snapshot: preSnapshot
        )
        let pauseIntents = makePauseIntents(
            affectedSurfaces: affectedSurfaces,
            snapshot: preSnapshot
        )
        updateTrace(context.transactionID) { trace in
            trace.replacing(
                affectedSurfaces: affectedSurfaces,
                pauseIntents: pauseIntents
            )
        }

        await appendPhase(.quiescingSessions, transactionID: context.transactionID)
        quiesceSessions(pauseIntents)

        await appendPhase(.executingVirtualDisplayCommand, transactionID: context.transactionID)
        guard let startupRestoreCommander else {
            return startupRestoreFailedConfigResult(
                transactionID: context.transactionID,
                configID: context.configID,
                phase: .executingVirtualDisplayCommand,
                reason: "virtual_display_commander_unavailable",
                restoreOutcome: .notAttempted,
                topologyResult: nil,
                postSnapshot: makeSnapshot(),
                recoverability: .retryable
            )
        }

        let commandResult: DisplayRuntimeStartupRestoreCommandResult
        do {
            commandResult = try await startupRestoreCommander.restoreVirtualDisplayForStartup(
                request: .init(
                    transactionID: context.transactionID,
                    runID: runID,
                    configID: context.configID,
                    configEvidence: config.evidence
                )
            )
        } catch {
            let failure = transactionFailure(
                phase: .executingVirtualDisplayCommand,
                reason: "startup_restore_lower_command_failed",
                error: error,
                recoverability: .retryable
            )
            let postSnapshot = makeSnapshot()
            _ = finalizeTransaction(
                transactionID: context.transactionID,
                kind: context.kind,
                status: .failed,
                phase: .failed,
                failure: failure,
                virtualDisplayCommandSucceeded: false,
                postSnapshot: postSnapshot,
                compensation: startupRestoreCompensationResult(
                    compensationOutcome: .notAttempted,
                    compensationFailureReason: nil
                ),
                virtualDisplayCommandOutcome: .failed
            )
            return DisplayRuntimeStartupRestoreConfigResult(
                transactionID: context.transactionID,
                configID: context.configID,
                status: .failed,
                restoreOutcome: .failed,
                failureReason: failure.reason,
                topologyStabilityResult: nil
            )
        }

        updateTrace(context.transactionID) { trace in
            trace.replacing(
                virtualDisplayCommandOutcome: commandResult.restoreOutcome,
                startupRestoreCommandResult: DisplayRuntimeStartupRestoreCommandTrace(commandResult: commandResult)
            )
        }

        guard commandResult.restoreOutcome == .succeeded || commandResult.restoreOutcome == .partiallySucceeded else {
            let topologyResult: DisplayRuntimeTopologyStabilityResult?
            if commandResult.didProduceVerifiableSideEffect {
                await appendPhase(.waitingForTopology, transactionID: context.transactionID)
                topologyResult = await waitForPostCommandTopology(
                    kind: context.kind,
                    affectedSurfaces: affectedSurfaces
                )
            } else {
                topologyResult = nil
            }
            return startupRestoreFailedConfigResult(
                transactionID: context.transactionID,
                configID: context.configID,
                phase: .executingVirtualDisplayCommand,
                reason: commandResult.failureReason ?? "startup_restore_lower_command_failed",
                restoreOutcome: commandResult.restoreOutcome,
                topologyResult: topologyResult,
                postSnapshot: makeSnapshot(),
                recoverability: .retryable,
                compensation: startupRestoreCompensationResult(
                    compensationOutcome: commandResult.compensationOutcome,
                    compensationFailureReason: commandResult.compensationFailureReason
                )
            )
        }

        await appendPhase(.waitingForTopology, transactionID: context.transactionID)
        let topologyResult = await waitForPostCommandTopology(
            kind: context.kind,
            affectedSurfaces: affectedSurfaces
        )
        if topologyResult.status == .stable {
            convergeToVisibleDisplaysFromCurrentCatalog()
            await observabilityRecorder?.refreshSnapshot(reason: .screenCatalogStateChanged)
        }
        let postConvergenceSnapshot = makeSnapshot()
        let restoreIntents = makeSessionRestoreIntents(
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
        let sharingRestoreResults = await restoreSharingSessions(
            restoreIntents,
            topologyResult: topologyResult,
            postSnapshot: postConvergenceSnapshot,
            disabledTargetIdentity: nil
        )
        let monitoringRestoreResults = makeDeferredMonitoringRestoreResults(
            restoreIntents,
            topologyResult: topologyResult,
            disabledTargetIdentity: nil
        )
        let restoreResults = sharingRestoreResults + monitoringRestoreResults
        updateTrace(context.transactionID) { trace in
            trace.replacing(restoreResults: restoreResults)
        }
        let finalPostSnapshot = makeSnapshot()
        let finalStatus = transactionStatus(after: topologyResult, restoreResults: restoreResults)
        _ = finalizeTransaction(
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
            desiredEnabled: true,
            virtualDisplayCommandOutcome: commandResult.restoreOutcome
        )
        return DisplayRuntimeStartupRestoreConfigResult(
            transactionID: context.transactionID,
            configID: context.configID,
            status: startupRestoreConfigStatus(
                transactionStatus: finalStatus,
                topologyResult: topologyResult,
                restoreOutcome: commandResult.restoreOutcome
            ),
            restoreOutcome: commandResult.restoreOutcome,
            failureReason: startupRestoreConfigFailureReason(topologyResult: topologyResult),
            topologyStabilityResult: topologyResult
        )
    }

    private func startupRestoreFailedConfigResult(
        transactionID: DisplayRuntimeTransactionID,
        configID: UUID,
        phase: DisplayRuntimeTransactionPhase,
        reason: String,
        restoreOutcome: DisplayRuntimeVirtualDisplayCommandOutcome,
        topologyResult: DisplayRuntimeTopologyStabilityResult?,
        postSnapshot: DisplayRuntimeSnapshot,
        recoverability: DisplayRuntimeTransactionRecoverability,
        compensation: DisplayRuntimeCompensationResult? = nil
    ) -> DisplayRuntimeStartupRestoreConfigResult {
        let failure = DisplayRuntimeTransactionFailure(
            phase: phase,
            reason: reason,
            recoverability: recoverability
        )
        _ = finalizeTransaction(
            transactionID: transactionID,
            kind: .virtualDisplayStartupRestore,
            status: .failed,
            phase: .failed,
            failure: failure,
            virtualDisplayCommandSucceeded: false,
            postSnapshot: postSnapshot,
            topologyStabilityResult: topologyResult,
            compensation: compensation ?? .init(
                status: .skipped,
                restoredSharingCount: 0,
                restoredMonitoringCount: 0,
                failedRestoreCount: 0,
                virtualDisplayCommandOutcome: .notAttempted,
                failureReason: reason
            ),
            desiredEnabled: true,
            virtualDisplayCommandOutcome: restoreOutcome
        )
        return DisplayRuntimeStartupRestoreConfigResult(
            transactionID: transactionID,
            configID: configID,
            status: .failed,
            restoreOutcome: restoreOutcome,
            failureReason: reason,
            topologyStabilityResult: topologyResult
        )
    }

    private func startupRestoreCompensationResult(
        compensationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome,
        compensationFailureReason: String?
    ) -> DisplayRuntimeCompensationResult {
        DisplayRuntimeCompensationResult(
            status: compensationOutcome == .notAttempted ? .skipped : .degraded,
            restoredSharingCount: 0,
            restoredMonitoringCount: 0,
            failedRestoreCount: 0,
            virtualDisplayCommandOutcome: compensationOutcome,
            failureReason: compensationFailureReason
        )
    }

    private func startupRestoreTerminalCompensation(
        failure: DisplayRuntimeTransactionFailure?
    ) -> DisplayRuntimeCompensationResult {
        guard let failure else { return .notRequired }
        return DisplayRuntimeCompensationResult(
            status: .skipped,
            restoredSharingCount: 0,
            restoredMonitoringCount: 0,
            failedRestoreCount: 0,
            virtualDisplayCommandOutcome: .notAttempted,
            failureReason: failure.reason
        )
    }

    private func startupRestoreConfigStatus(
        transactionStatus: DisplayRuntimeTransactionStatus,
        topologyResult: DisplayRuntimeTopologyStabilityResult,
        restoreOutcome: DisplayRuntimeVirtualDisplayCommandOutcome
    ) -> DisplayRuntimeStartupRestoreConfigResultStatus {
        if restoreOutcome == .partiallySucceeded {
            return .degraded
        }
        if topologyResult.status != .stable {
            return .degraded
        }
        return transactionStatus == .completed ? .restored : .degraded
    }

    private func startupRestoreConfigFailureReason(
        topologyResult: DisplayRuntimeTopologyStabilityResult
    ) -> String? {
        guard topologyResult.status != .stable else { return nil }
        return "topology_\(topologyResult.status.rawValue)"
    }

    private func startupRestoreStatus(
        configResults: [DisplayRuntimeStartupRestoreConfigResult]
    ) -> DisplayRuntimeStartupRestoreStatus {
        guard !configResults.isEmpty else { return .succeededNoOp }
        return configResults.allSatisfy { $0.status == .restored } ? .succeeded : .completedWithFailures
    }
}
