import Foundation

@MainActor
extension DisplayRuntime {
    @discardableResult
    package func createVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayCreateRequest,
        source: DisplayRuntimeTransactionSource
    ) async throws -> DisplayRuntimeVirtualDisplayCreateTransactionResult {
        let effectiveRequest = DisplayRuntimeVirtualDisplayCreateRequest(
            transactionID: request.transactionID,
            displayName: request.displayName,
            serialNumber: request.serialNumber,
            physicalWidthMillimeters: request.physicalWidthMillimeters,
            physicalHeightMillimeters: request.physicalHeightMillimeters,
            maximumPixelWidth: request.maximumPixelWidth,
            maximumPixelHeight: request.maximumPixelHeight,
            modes: request.modes,
            source: source
        )
        let context = ActiveVirtualDisplayInventoryTransactionContext(
            transactionID: effectiveRequest.transactionID,
            kind: .virtualDisplayCreate,
            source: source
        )
        return try await enqueueUncoalescedVirtualDisplayTransaction(context: context) {
            try await self.executeVirtualDisplayCreateTransaction(effectiveRequest)
        }
    }

    @discardableResult
    package func deleteVirtualDisplay(
        configID: UUID,
        source: DisplayRuntimeTransactionSource
    ) async throws -> DisplayRuntimeVirtualDisplayDeleteTransactionResult {
        let context = ActiveVirtualDisplayTransactionContext(
            transactionID: DisplayRuntimeTransactionID(),
            kind: .virtualDisplayDelete,
            configID: configID,
            source: source
        )
        return try await enqueueUncoalescedVirtualDisplayTransaction(context: context) {
            try await self.executeVirtualDisplayDeleteTransaction(context)
        }
    }

    private func executeVirtualDisplayCreateTransaction(
        _ request: DisplayRuntimeVirtualDisplayCreateRequest
    ) async throws -> DisplayRuntimeVirtualDisplayCreateTransactionResult {
        do {
            try Task.checkCancellation()
        } catch {
            _ = await finalizeTransaction(
                transactionID: request.transactionID,
                kind: .virtualDisplayCreate,
                status: .cancelled,
                phase: .cancelled,
                failure: .init(
                    phase: .cancelled,
                    reason: "cancelled_before_virtual_display_command",
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                persistenceOutcome: .notAttempted,
                virtualDisplayCommandOutcome: .notAttempted
            )
            throw error
        }

        await appendPhase(.preparing, transactionID: request.transactionID)
        await refreshCatalogTopologyForTransaction()
        let preSnapshot = makeSnapshot()
        updateTrace(request.transactionID) { trace in
            trace.replacing(
                preSnapshotEvidence: DisplayRuntimeTransactionSnapshotEvidence(snapshot: preSnapshot),
                createdConfigEvidence: request.redactedEvidence
            )
        }

        guard isValidCreateRequest(request) else {
            let terminal = await finalizeTransaction(
                transactionID: request.transactionID,
                kind: .virtualDisplayCreate,
                status: .failed,
                phase: .failed,
                failure: .init(
                    phase: .preparing,
                    reason: "invalid_create_request",
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: preSnapshot,
                persistenceOutcome: .notAttempted,
                virtualDisplayCommandOutcome: .notAttempted
            )
            return createTransactionResult(
                request: request,
                terminal: terminal,
                commandResult: nil,
                topologyResult: nil
            )
        }

        await appendPhase(.executingVirtualDisplayCommand, transactionID: request.transactionID)
        guard let virtualDisplayCommander else {
            let terminal = await finalizeTransaction(
                transactionID: request.transactionID,
                kind: .virtualDisplayCreate,
                status: .failed,
                phase: .failed,
                failure: .init(
                    phase: .executingVirtualDisplayCommand,
                    reason: "virtual_display_commander_unavailable",
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: makeSnapshot(),
                persistenceOutcome: .notAttempted,
                virtualDisplayCommandOutcome: .notAttempted
            )
            return createTransactionResult(
                request: request,
                terminal: terminal,
                commandResult: nil,
                topologyResult: nil
            )
        }

        let commandResult: DisplayRuntimeVirtualDisplayCreateCommandResult
        do {
            commandResult = try await virtualDisplayCommander.createVirtualDisplay(request: request)
        } catch let commandError as DisplayRuntimeVirtualDisplayCreateCommandError {
            recordCreateCommandFacts(commandError.result, transactionID: request.transactionID)
            _ = await finalizeTransaction(
                transactionID: request.transactionID,
                kind: .virtualDisplayCreate,
                status: .failed,
                phase: .failed,
                failure: .init(
                    phase: .executingVirtualDisplayCommand,
                    reason: commandError.reason,
                    recoverability: commandError.result.rollbackOutcome == .rollbackFailed ? .degraded : .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: makeSnapshot(),
                persistenceOutcome: commandError.result.persistenceOutcome,
                virtualDisplayCommandOutcome: .failed
            )
            throw commandError
        } catch {
            _ = await finalizeTransaction(
                transactionID: request.transactionID,
                kind: .virtualDisplayCreate,
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
                persistenceOutcome: .failed,
                virtualDisplayCommandOutcome: .failed
            )
            throw error
        }

        recordCreateCommandFacts(commandResult, transactionID: request.transactionID)
        guard let createdConfigID = commandResult.createdConfigID,
              commandResult.persistenceOutcome == .saved,
              commandResult.runtimeCreationOutcome == .succeeded
        else {
            let terminal = await finalizeTransaction(
                transactionID: request.transactionID,
                kind: .virtualDisplayCreate,
                status: .failed,
                phase: .failed,
                failure: .init(
                    phase: .executingVirtualDisplayCommand,
                    reason: "virtual_display_command_failed",
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: makeSnapshot(),
                persistenceOutcome: commandResult.persistenceOutcome,
                virtualDisplayCommandOutcome: .failed
            )
            return createTransactionResult(
                request: request,
                terminal: terminal,
                commandResult: commandResult,
                topologyResult: nil
            )
        }

        let affectedSurfaces = [
            DisplayRuntimeAffectedSurface(
                identity: .managedVirtualDisplay(configID: createdConfigID),
                configID: createdConfigID,
                preDisplayID: nil,
                serialNumber: commandResult.serialNumber,
                reason: .requestedConfig
            )
        ]
        updateTrace(request.transactionID) { trace in
            trace.replacing(affectedSurfaces: affectedSurfaces)
        }

        await appendPhase(.waitingForTopology, transactionID: request.transactionID)
        let topologyResult = await waitForPostCommandTopology(
            kind: .virtualDisplayCreate,
            affectedSurfaces: affectedSurfaces
        )
        let finalStatus = transactionStatus(after: topologyResult, restoreResults: [])
        let terminal = await finalizeTransaction(
            transactionID: request.transactionID,
            kind: .virtualDisplayCreate,
            status: finalStatus,
            phase: .completed,
            failure: nil,
            virtualDisplayCommandSucceeded: true,
            postSnapshot: makeSnapshot(),
            topologyStabilityResult: topologyResult,
            compensation: compensationResult(
                after: topologyResult,
                restoreResults: [],
                restoreIntentCount: 0
            ),
            persistenceOutcome: commandResult.persistenceOutcome,
            virtualDisplayCommandOutcome: .succeeded
        )
        return createTransactionResult(
            request: request,
            terminal: terminal,
            commandResult: commandResult,
            topologyResult: topologyResult
        )
    }

    private func executeVirtualDisplayDeleteTransaction(
        _ context: ActiveVirtualDisplayTransactionContext
    ) async throws -> DisplayRuntimeVirtualDisplayDeleteTransactionResult {
        do {
            try Task.checkCancellation()
        } catch {
            _ = await finalizeTransaction(
                transactionID: context.transactionID,
                kind: .virtualDisplayDelete,
                status: .cancelled,
                phase: .cancelled,
                failure: .init(
                    phase: .cancelled,
                    reason: "cancelled_before_virtual_display_command",
                    recoverability: .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                persistenceOutcome: .notAttempted,
                virtualDisplayCommandOutcome: .notAttempted,
                runtimeTrackingClearOutcome: .notAttempted
            )
            throw error
        }

        await appendPhase(.preparing, transactionID: context.transactionID)
        await refreshCatalogTopologyForTransaction()
        let preSnapshot = makeSnapshot()
        updateTrace(context.transactionID) { trace in
            trace.replacing(preSnapshotEvidence: DisplayRuntimeTransactionSnapshotEvidence(snapshot: preSnapshot))
        }

        guard preSnapshot.virtualDisplay.configs.contains(where: { $0.id == context.configID }) else {
            let terminal = await finalizeTransaction(
                transactionID: context.transactionID,
                kind: .virtualDisplayDelete,
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
                virtualDisplayCommandOutcome: .notAttempted,
                runtimeTrackingClearOutcome: .notAttempted
            )
            return deleteTransactionResult(
                context: context,
                terminal: terminal,
                targetWasRunning: false,
                persistenceOutcome: .notAttempted,
                virtualDisplayCommandOutcome: .notAttempted,
                runtimeTrackingClearOutcome: .notAttempted,
                topologyResult: nil
            )
        }

        let affectedSurfaces = makeAffectedSurfaces(configID: context.configID, snapshot: preSnapshot)
        let targetPreDisplayID = affectedSurfaces.first(where: { $0.configID == context.configID })?.preDisplayID
        let targetWasRunning = preSnapshot.virtualDisplay.runningConfigIDs.contains(context.configID)
            || targetPreDisplayID != nil
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
        let consumerTransition = await beginConsumerTransition(
            affectedSurfaces: affectedSurfaces
        )
        guard !consumerTransition.hasQuiesceFailure else {
            let restoreResults = await compensateConsumerQuiesceFailure(
                consumerTransition,
                transactionID: context.transactionID
            )
            let terminal = await finalizeTransaction(
                transactionID: context.transactionID,
                kind: .virtualDisplayDelete,
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
                ),
                persistenceOutcome: .notAttempted,
                virtualDisplayCommandOutcome: .notAttempted,
                runtimeTrackingClearOutcome: .notAttempted
            )
            return deleteTransactionResult(
                context: context,
                terminal: terminal,
                targetWasRunning: targetWasRunning,
                persistenceOutcome: .notAttempted,
                virtualDisplayCommandOutcome: .notAttempted,
                runtimeTrackingClearOutcome: .notAttempted,
                topologyResult: nil
            )
        }

        await appendPhase(.executingVirtualDisplayCommand, transactionID: context.transactionID)
        guard let virtualDisplayCommander else {
            let restoreResults = await compensateConsumerTransition(consumerTransition)
            updateTrace(context.transactionID) { trace in
                trace.replacing(restoreResults: restoreResults)
            }
            let terminal = await finalizeTransaction(
                transactionID: context.transactionID,
                kind: .virtualDisplayDelete,
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
                ),
                persistenceOutcome: .notAttempted,
                virtualDisplayCommandOutcome: .notAttempted,
                runtimeTrackingClearOutcome: .notAttempted
            )
            return deleteTransactionResult(
                context: context,
                terminal: terminal,
                targetWasRunning: targetWasRunning,
                persistenceOutcome: .notAttempted,
                virtualDisplayCommandOutcome: .notAttempted,
                runtimeTrackingClearOutcome: .notAttempted,
                topologyResult: nil
            )
        }

        let commandRequest = DisplayRuntimeVirtualDisplayDeleteCommandRequest(
            transactionID: context.transactionID,
            configID: context.configID,
            targetPreDisplayID: targetPreDisplayID,
            targetWasRunning: targetWasRunning
        )
        let commandResult: DisplayRuntimeVirtualDisplayDeleteCommandResult
        do {
            commandResult = try await virtualDisplayCommander.deleteVirtualDisplay(request: commandRequest)
        } catch let commandError as DisplayRuntimeVirtualDisplayDeleteCommandError {
            let restoreResults = await compensateConsumerTransition(consumerTransition)
            recordDeleteCommandFacts(commandError.result, transactionID: context.transactionID)
            updateTrace(context.transactionID) { trace in
                trace.replacing(restoreResults: restoreResults)
            }
            _ = await finalizeTransaction(
                transactionID: context.transactionID,
                kind: .virtualDisplayDelete,
                status: .failed,
                phase: .failed,
                failure: .init(
                    phase: .executingVirtualDisplayCommand,
                    reason: commandError.reason,
                    recoverability: commandError.reason == "config_not_found" ? .unrecoverable : .retryable
                ),
                virtualDisplayCommandSucceeded: false,
                postSnapshot: makeSnapshot(),
                compensation: consumerCompensationResult(
                    restoreResults: restoreResults,
                    restoreIntentCount: consumerTransition.restoreIntentCount
                ),
                persistenceOutcome: commandError.result.persistenceOutcome,
                virtualDisplayCommandOutcome: commandError.result.virtualDisplayCommandOutcome,
                runtimeTrackingClearOutcome: commandError.result.runtimeTrackingClearOutcome
            )
            throw commandError
        } catch {
            let restoreResults = await compensateConsumerTransition(consumerTransition)
            updateTrace(context.transactionID) { trace in
                trace.replacing(restoreResults: restoreResults)
            }
            _ = await finalizeTransaction(
                transactionID: context.transactionID,
                kind: .virtualDisplayDelete,
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
                compensation: consumerCompensationResult(
                    restoreResults: restoreResults,
                    restoreIntentCount: consumerTransition.restoreIntentCount
                ),
                persistenceOutcome: .failed,
                virtualDisplayCommandOutcome: .failed,
                runtimeTrackingClearOutcome: .notAttempted
            )
            throw error
        }

        recordDeleteCommandFacts(commandResult, transactionID: context.transactionID)
        let topologyResult: DisplayRuntimeTopologyStabilityResult?
        if commandResult.targetWasRunning {
            await appendPhase(.waitingForTopology, transactionID: context.transactionID)
            let result = await waitForPostCommandTopology(
                kind: .virtualDisplayDelete,
                affectedSurfaces: affectedSurfaces
            )
            topologyResult = result
        } else {
            topologyResult = nil
        }

        let postConvergenceSnapshot = makeSnapshot()
        let restoreIntents: [DisplayRuntimeSessionRestoreIntent]
        if let topologyResult {
            restoreIntents = makeSessionRestoreIntents(
                pauseIntents: pauseIntents,
                topologyResult: topologyResult,
                preSnapshot: preSnapshot,
                postSnapshot: postConvergenceSnapshot
            )
        } else {
            restoreIntents = []
        }
        updateTrace(context.transactionID) { trace in
            trace.replacing(restoreIntents: restoreIntents)
        }
        if !restoreIntents.isEmpty {
            await appendPhase(.restoringSessions, transactionID: context.transactionID)
        }
        let targetIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: context.configID)
        let restoreResults = await completeConsumerTransition(
            consumerTransition,
            snapshot: postConvergenceSnapshot,
            topologyResult: topologyResult,
            releasedSurfaceReasons: [targetIdentity: "target_deleted"]
        )
        updateTrace(context.transactionID) { trace in
            trace.replacing(restoreResults: restoreResults)
        }

        let finalStatus = topologyResult.map {
            transactionStatus(after: $0, restoreResults: restoreResults)
        } ?? .completed
        let terminal = await finalizeTransaction(
            transactionID: context.transactionID,
            kind: .virtualDisplayDelete,
            status: finalStatus,
            phase: .completed,
            failure: nil,
            virtualDisplayCommandSucceeded: true,
            postSnapshot: makeSnapshot(),
            topologyStabilityResult: topologyResult,
            compensation: topologyResult.map {
                compensationResult(
                    after: $0,
                    restoreResults: restoreResults,
                    restoreIntentCount: consumerTransition.restoreIntentCount
                )
            } ?? consumerCompensationResult(
                restoreResults: restoreResults,
                restoreIntentCount: consumerTransition.restoreIntentCount
            ),
            persistenceOutcome: commandResult.persistenceOutcome,
            virtualDisplayCommandOutcome: commandResult.virtualDisplayCommandOutcome,
            runtimeTrackingClearOutcome: commandResult.runtimeTrackingClearOutcome
        )
        return deleteTransactionResult(
            context: context,
            terminal: terminal,
            targetWasRunning: commandResult.targetWasRunning,
            persistenceOutcome: commandResult.persistenceOutcome,
            virtualDisplayCommandOutcome: commandResult.virtualDisplayCommandOutcome,
            runtimeTrackingClearOutcome: commandResult.runtimeTrackingClearOutcome,
            topologyResult: topologyResult
        )
    }

    private func isValidCreateRequest(_ request: DisplayRuntimeVirtualDisplayCreateRequest) -> Bool {
        !request.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && request.serialNumber > 0
            && request.physicalWidthMillimeters > 0
            && request.physicalHeightMillimeters > 0
            && request.maximumPixelWidth > 0
            && request.maximumPixelHeight > 0
            && !request.modes.isEmpty
    }

    private func recordCreateCommandFacts(
        _ result: DisplayRuntimeVirtualDisplayCreateCommandResult,
        transactionID: DisplayRuntimeTransactionID
    ) {
        updateTrace(transactionID) { trace in
            trace.replacing(
                persistenceOutcome: result.persistenceOutcome,
                virtualDisplayCommandOutcome: result.runtimeCreationOutcome == .succeeded ? .succeeded : .failed,
                createdConfigID: result.createdConfigID,
                createdConfigEvidence: result.createdConfigEvidence,
                runtimeCreationOutcome: result.runtimeCreationOutcome,
                rollbackOutcome: result.rollbackOutcome
            )
        }
    }

    private func recordDeleteCommandFacts(
        _ result: DisplayRuntimeVirtualDisplayDeleteCommandResult,
        transactionID: DisplayRuntimeTransactionID
    ) {
        updateTrace(transactionID) { trace in
            trace.replacing(
                persistenceOutcome: result.persistenceOutcome,
                virtualDisplayCommandOutcome: result.virtualDisplayCommandOutcome,
                runtimeTrackingClearOutcome: result.runtimeTrackingClearOutcome
            )
        }
    }

    private func createTransactionResult(
        request: DisplayRuntimeVirtualDisplayCreateRequest,
        terminal: DisplayRuntimeVirtualDisplayRebuildTransactionResult,
        commandResult: DisplayRuntimeVirtualDisplayCreateCommandResult?,
        topologyResult: DisplayRuntimeTopologyStabilityResult?
    ) -> DisplayRuntimeVirtualDisplayCreateTransactionResult {
        DisplayRuntimeVirtualDisplayCreateTransactionResult(
            transactionID: terminal.transactionID,
            status: terminal.status,
            createdConfigID: commandResult?.createdConfigID,
            serialNumber: commandResult?.serialNumber ?? request.serialNumber,
            persistenceOutcome: commandResult?.persistenceOutcome ?? .notAttempted,
            runtimeCreationOutcome: commandResult?.runtimeCreationOutcome ?? .notAttempted,
            rollbackOutcome: commandResult?.rollbackOutcome ?? .notAttempted,
            topologyStabilityResult: topologyResult,
            hasRecoveryFailures: terminal.hasSessionRecoveryFailures
        )
    }

    private func deleteTransactionResult(
        context: ActiveVirtualDisplayTransactionContext,
        terminal: DisplayRuntimeVirtualDisplayRebuildTransactionResult,
        targetWasRunning: Bool,
        persistenceOutcome: DisplayRuntimePersistenceOutcome,
        virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome,
        runtimeTrackingClearOutcome: DisplayRuntimeVirtualDisplayRuntimeTrackingClearOutcome,
        topologyResult: DisplayRuntimeTopologyStabilityResult?
    ) -> DisplayRuntimeVirtualDisplayDeleteTransactionResult {
        DisplayRuntimeVirtualDisplayDeleteTransactionResult(
            transactionID: terminal.transactionID,
            status: terminal.status,
            configID: context.configID,
            targetWasRunning: targetWasRunning,
            persistenceOutcome: persistenceOutcome,
            virtualDisplayCommandOutcome: virtualDisplayCommandOutcome,
            runtimeTrackingClearOutcome: runtimeTrackingClearOutcome,
            topologyStabilityResult: topologyResult,
            hasRecoveryFailures: terminal.hasSessionRecoveryFailures
        )
    }
}
