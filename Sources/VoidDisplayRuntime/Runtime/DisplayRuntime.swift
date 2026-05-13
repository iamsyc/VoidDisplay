import Foundation

package nonisolated struct DisplayRuntimeTopologyWaitPolicy: Equatable, Sendable {
    package let requiredStableSampleCount: Int
    package let maximumSampleCount: Int
    package let sampleIntervalNanoseconds: UInt64

    package init(
        requiredStableSampleCount: Int = 2,
        maximumSampleCount: Int = 10,
        sampleIntervalNanoseconds: UInt64 = 100_000_000
    ) {
        self.requiredStableSampleCount = max(1, requiredStableSampleCount)
        self.maximumSampleCount = max(1, maximumSampleCount)
        self.sampleIntervalNanoseconds = sampleIntervalNanoseconds
    }

    package static let `default` = Self()
}

@MainActor
package final class DisplayRuntime {
    let catalogProvider: (any DisplayRuntimeCatalogProviding)?
    let captureProvider: (any DisplayRuntimeCaptureProviding)?
    let sharingProvider: (any DisplayRuntimeSharingProviding)?
    let virtualDisplayProvider: (any DisplayRuntimeVirtualDisplayProviding)?
    let catalogCommander: (any DisplayRuntimeCatalogCommanding)?
    let sharingCommander: (any DisplayRuntimeSharingCommanding)?
    let captureCommander: (any DisplayRuntimeCaptureCommanding)?
    private let virtualDisplayCommander: (any DisplayRuntimeVirtualDisplayCommanding)?
    let observabilityRecorder: (any DisplayRuntimeObservabilityRecording)?
    let topologyWaitPolicy: DisplayRuntimeTopologyWaitPolicy

    var topologyRefreshTask: Task<Void, Never>?
    var hasPendingTopologyChange = false
    var virtualDisplayTransactionQueueTail: Task<Void, Never>?
    var activeVirtualDisplayTransactionTasksByKey: [
        ActiveVirtualDisplayTransactionKey: Task<DisplayRuntimeVirtualDisplayRebuildTransactionResult, Error>
    ] = [:]
    var activeVirtualDisplayTransactionIDsByKey: [
        ActiveVirtualDisplayTransactionKey: DisplayRuntimeTransactionID
    ] = [:]
    var activeTransactionTracesByID: [DisplayRuntimeTransactionID: DisplayRuntimeTransactionTrace] = [:]
    var recentTransactionTraces: [DisplayRuntimeTransactionTrace] = []

    package init(
        catalogProvider: (any DisplayRuntimeCatalogProviding)? = nil,
        captureProvider: (any DisplayRuntimeCaptureProviding)? = nil,
        sharingProvider: (any DisplayRuntimeSharingProviding)? = nil,
        virtualDisplayProvider: (any DisplayRuntimeVirtualDisplayProviding)? = nil,
        catalogCommander: (any DisplayRuntimeCatalogCommanding)? = nil,
        sharingCommander: (any DisplayRuntimeSharingCommanding)? = nil,
        captureCommander: (any DisplayRuntimeCaptureCommanding)? = nil,
        virtualDisplayCommander: (any DisplayRuntimeVirtualDisplayCommanding)? = nil,
        observabilityRecorder: (any DisplayRuntimeObservabilityRecording)? = nil,
        topologyWaitPolicy: DisplayRuntimeTopologyWaitPolicy = .default
    ) {
        self.catalogProvider = catalogProvider
        self.captureProvider = captureProvider
        self.sharingProvider = sharingProvider
        self.virtualDisplayProvider = virtualDisplayProvider
        self.catalogCommander = catalogCommander
        self.sharingCommander = sharingCommander
        self.captureCommander = captureCommander
        self.virtualDisplayCommander = virtualDisplayCommander
        self.observabilityRecorder = observabilityRecorder
        self.topologyWaitPolicy = topologyWaitPolicy
    }

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
        quiesceSessions(pauseIntents)

        await appendPhase(.executingVirtualDisplayCommand, transactionID: request.transactionID)
        guard let virtualDisplayCommander else {
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
                postSnapshot: makeSnapshot()
            )
        }

        do {
            _ = try await virtualDisplayCommander.rebuildVirtualDisplay(configID: request.configID)
        } catch {
            let postSnapshot = makeSnapshot()
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
                postSnapshot: postSnapshot
            )
            throw error
        }

        await appendPhase(.waitingForTopology, transactionID: request.transactionID)
        let topologyResult = await waitForPostCommandTopology(
            kind: .virtualDisplayRebuild,
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
        updateTrace(request.transactionID) { trace in
            trace.replacing(restoreIntents: restoreIntents)
        }
        if !restoreIntents.isEmpty {
            await appendPhase(.restoringSessions, transactionID: request.transactionID)
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
                restoreIntentCount: restoreIntents.count
            )
        )
    }

    private func executeVirtualDisplayCreateTransaction(
        _ request: DisplayRuntimeVirtualDisplayCreateRequest
    ) async throws -> DisplayRuntimeVirtualDisplayCreateTransactionResult {
        do {
            try Task.checkCancellation()
        } catch {
            _ = finalizeTransaction(
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
            let terminal = finalizeTransaction(
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
            let terminal = finalizeTransaction(
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
            _ = finalizeTransaction(
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
            _ = finalizeTransaction(
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
            let terminal = finalizeTransaction(
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
        if topologyResult.status == .stable {
            convergeToVisibleDisplaysFromCurrentCatalog()
            await observabilityRecorder?.refreshSnapshot(reason: .screenCatalogStateChanged)
        }
        let finalStatus = transactionStatus(after: topologyResult, restoreResults: [])
        let terminal = finalizeTransaction(
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
            _ = finalizeTransaction(
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
            let terminal = finalizeTransaction(
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
        quiesceSessions(pauseIntents)

        await appendPhase(.executingVirtualDisplayCommand, transactionID: context.transactionID)
        guard let virtualDisplayCommander else {
            let terminal = finalizeTransaction(
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
            recordDeleteCommandFacts(commandError.result, transactionID: context.transactionID)
            _ = finalizeTransaction(
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
                persistenceOutcome: commandError.result.persistenceOutcome,
                virtualDisplayCommandOutcome: commandError.result.virtualDisplayCommandOutcome,
                runtimeTrackingClearOutcome: commandError.result.runtimeTrackingClearOutcome
            )
            throw commandError
        } catch {
            _ = finalizeTransaction(
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
            if result.status == .stable {
                convergeToVisibleDisplaysFromCurrentCatalog()
                await observabilityRecorder?.refreshSnapshot(reason: .screenCatalogStateChanged)
            }
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
        let restoreResults: [DisplayRuntimeSessionRestoreResult]
        if let topologyResult {
            let sharingRestoreResults = await restoreSharingSessions(
                restoreIntents,
                topologyResult: topologyResult,
                postSnapshot: postConvergenceSnapshot,
                disabledTargetIdentity: targetIdentity,
                targetSkipReason: "target_deleted"
            )
            let monitoringRestoreResults = makeDeferredMonitoringRestoreResults(
                restoreIntents,
                topologyResult: topologyResult,
                disabledTargetIdentity: targetIdentity,
                targetSkipReason: "target_deleted"
            )
            restoreResults = sharingRestoreResults + monitoringRestoreResults
        } else {
            restoreResults = []
        }
        updateTrace(context.transactionID) { trace in
            trace.replacing(restoreResults: restoreResults)
        }

        let finalStatus = topologyResult.map {
            transactionStatus(after: $0, restoreResults: restoreResults)
        } ?? .completed
        let terminal = finalizeTransaction(
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
                    restoreIntentCount: restoreIntents.count
                )
            } ?? .notRequired,
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
        quiesceSessions(pauseIntents)

        await appendPhase(.executingVirtualDisplayCommand, transactionID: request.transactionID)
        do {
            _ = try await virtualDisplayCommander.rebuildVirtualDisplay(configID: request.editedConfig.id)
            updateTrace(request.transactionID) { trace in
                trace.replacing(virtualDisplayCommandOutcome: .succeeded)
            }
        } catch {
            let compensation = await compensateFailedEditRebuild(
                transactionID: request.transactionID,
                previousConfigForCompensation: saveResult.previousConfigForCompensation,
                virtualDisplayCommander: virtualDisplayCommander
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
        updateTrace(request.transactionID) { trace in
            trace.replacing(restoreIntents: restoreIntents)
        }
        if !restoreIntents.isEmpty {
            await appendPhase(.restoringSessions, transactionID: request.transactionID)
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
                restoreIntentCount: restoreIntents.count
            ),
            persistenceOutcome: saveResult.persistenceOutcome,
            virtualDisplayCommandOutcome: .succeeded
        )
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
                    restoredMonitoringCount: 0,
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
        let monitoringRestoreResults = makeDeferredMonitoringRestoreResults(
            restoreIntents,
            topologyResult: topologyResult,
            disabledTargetIdentity: disabledTargetIdentity
        )
        let restoreResults = sharingRestoreResults + monitoringRestoreResults
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

    private func compensateFailedEditRebuild(
        transactionID: DisplayRuntimeTransactionID,
        previousConfigForCompensation: DisplayRuntimeVirtualDisplayConfigEditDTO,
        virtualDisplayCommander: any DisplayRuntimeVirtualDisplayCommanding
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
                    restoredMonitoringCount: 0,
                    failedRestoreCount: 1,
                    persistenceOutcome: restoreResult.persistenceOutcome,
                    virtualDisplayCommandOutcome: .notAttempted,
                    failureReason: "persistence_compensation_failed"
                )
            }

            do {
                _ = try await virtualDisplayCommander.rebuildVirtualDisplay(
                    configID: previousConfigForCompensation.id
                )
                return .init(
                    status: .completed,
                    restoredSharingCount: 0,
                    restoredMonitoringCount: 0,
                    failedRestoreCount: 0,
                    persistenceOutcome: restoreResult.persistenceOutcome,
                    virtualDisplayCommandOutcome: .succeeded,
                    failureReason: nil
                )
            } catch {
                return .init(
                    status: .degraded,
                    restoredSharingCount: 0,
                    restoredMonitoringCount: 0,
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
                restoredMonitoringCount: 0,
                failedRestoreCount: 1,
                persistenceOutcome: .rollbackFailed,
                virtualDisplayCommandOutcome: .notAttempted,
                failureReason: "persistence_compensation_failed"
            )
        }
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
