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

private nonisolated struct ActiveVirtualDisplayTransactionKey: Hashable {
    let kind: DisplayRuntimeTransactionKind
    let configID: UUID
}

private nonisolated struct ActiveVirtualDisplayTransactionContext: Sendable {
    let transactionID: DisplayRuntimeTransactionID
    let kind: DisplayRuntimeTransactionKind
    let configID: UUID
    let source: DisplayRuntimeTransactionSource
}

@MainActor
package final class DisplayRuntime {
    private let catalogProvider: (any DisplayRuntimeCatalogProviding)?
    private let captureProvider: (any DisplayRuntimeCaptureProviding)?
    private let sharingProvider: (any DisplayRuntimeSharingProviding)?
    private let virtualDisplayProvider: (any DisplayRuntimeVirtualDisplayProviding)?
    private let catalogCommander: (any DisplayRuntimeCatalogCommanding)?
    private let sharingCommander: (any DisplayRuntimeSharingCommanding)?
    private let captureCommander: (any DisplayRuntimeCaptureCommanding)?
    private let virtualDisplayCommander: (any DisplayRuntimeVirtualDisplayCommanding)?
    private let observabilityRecorder: (any DisplayRuntimeObservabilityRecording)?
    private let topologyWaitPolicy: DisplayRuntimeTopologyWaitPolicy

    private var topologyRefreshTask: Task<Void, Never>?
    private var hasPendingTopologyChange = false
    private var virtualDisplayTransactionQueueTail: Task<Void, Never>?
    private var activeVirtualDisplayTransactionTasksByKey: [
        ActiveVirtualDisplayTransactionKey: Task<DisplayRuntimeVirtualDisplayRebuildTransactionResult, Error>
    ] = [:]
    private var activeVirtualDisplayTransactionIDsByKey: [
        ActiveVirtualDisplayTransactionKey: DisplayRuntimeTransactionID
    ] = [:]
    private var activeTransactionTracesByID: [DisplayRuntimeTransactionID: DisplayRuntimeTransactionTrace] = [:]
    private var recentTransactionTraces: [DisplayRuntimeTransactionTrace] = []

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

    package func handleCatalogAppear(source: DisplayRuntimeCatalogSource) async {
        await refreshCatalogPermission(source: source)
    }

    package func handleCatalogDisappear(source: DisplayRuntimeCatalogSource) async {
        await cancelRefresh(for: source)
    }

    package func requestCatalogPermission(source: DisplayRuntimeCatalogSource) async {
        guard let catalogCommander else { return }
        let granted = catalogCommander.requestPermission()
        guard granted else {
            let loadErrorMessage = source == .sharingPage
                ? String(localized: "Failed to load displays. Check permission and try again.")
                : nil
            await clearSnapshotForDeniedPermission(loadErrorMessage: loadErrorMessage, source: source)
            await recordPermissionEvent(granted: false, source: source)
            return
        }
        await recordPermissionEvent(granted: true, source: source)
        await refreshAfterPermissionGranted(source: source)
    }

    package func refreshCatalogPermission(source: DisplayRuntimeCatalogSource) async {
        guard let catalogCommander else { return }
        let granted = catalogCommander.refreshPermission()
        guard granted else {
            await clearSnapshotForDeniedPermission(source: source)
            await recordPermissionEvent(granted: false, source: source)
            return
        }
        await recordPermissionEvent(granted: true, source: source)
        await refreshAfterPermissionGranted(source: source)
    }

    package func forceRefreshCatalog(source: DisplayRuntimeCatalogSource) async {
        guard let catalogCommander else { return }
        let granted = catalogCommander.refreshPermission()
        guard granted else {
            await clearSnapshotForDeniedPermission(source: source)
            return
        }

        switch source {
        case .capturePage:
            await refreshAndConverge(intent: .userForcedRefresh, ownerScope: .capture)
        case .sharingPage:
            guard currentSharingSnapshot().isWebServiceRunning else {
                await catalogCommander.cancelRefresh(ownerScope: .sharing)
                return
            }
            await refreshAndConverge(intent: .userForcedRefresh, ownerScope: .sharing)
        }
    }

    package func handleCatalogTopologyChanged() async {
        hasPendingTopologyChange = true
        if let topologyRefreshTask {
            await topologyRefreshTask.value
            return
        }
        let topologyRefreshTask = Task { @MainActor in
            defer { self.topologyRefreshTask = nil }
            await self.drainTopologyRefreshQueue()
        }
        self.topologyRefreshTask = topologyRefreshTask
        await topologyRefreshTask.value
    }

    package func handleSharingServiceStateChanged(isRunning _: Bool) async {
        guard let catalogCommander else { return }
        if currentSharingSnapshot().isWebServiceRunning {
            await refreshSharingCatalogForRunningService()
        } else {
            await catalogCommander.cancelRefresh(ownerScope: .sharing)
        }
    }

    package func makeSnapshot() -> DisplayRuntimeSnapshot {
        let catalog = catalogProvider?.makeCatalogSnapshot() ?? .empty
        let capture = captureProvider?.makeCaptureSnapshot() ?? .empty
        let sharing = sharingProvider?.makeSharingSnapshot() ?? .empty
        let virtualDisplay = virtualDisplayProvider?.makeVirtualDisplaySnapshot() ?? .empty
        return DisplayRuntimeSnapshot(
            surfaces: DisplaySurfaceGraphBuilder.makeSurfaces(
                catalog: catalog,
                capture: capture,
                sharing: sharing,
                virtualDisplay: virtualDisplay
            ),
            catalog: catalog,
            capture: capture,
            sharing: sharing,
            virtualDisplay: virtualDisplay,
            transactions: .init(
                activeTransactions: Array(activeTransactionTracesByID.values),
                recentTransactions: recentTransactionTraces
            )
        )
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

    private func enqueueVirtualDisplayTransaction(
        kind: DisplayRuntimeTransactionKind,
        configID: UUID,
        source: DisplayRuntimeTransactionSource,
        execute: @escaping @MainActor (ActiveVirtualDisplayTransactionContext) async throws -> DisplayRuntimeVirtualDisplayRebuildTransactionResult
    ) async throws -> DisplayRuntimeVirtualDisplayRebuildTransactionResult {
        let key = ActiveVirtualDisplayTransactionKey(kind: kind, configID: configID)
        if let activeTask = activeVirtualDisplayTransactionTasksByKey[key],
           let transactionID = activeVirtualDisplayTransactionIDsByKey[key] {
            incrementCoalescedRequestCount(transactionID: transactionID)
            await observabilityRecorder?.refreshSnapshot(reason: .displayRuntimeTransactionChanged)
            return try await activeTask.value
        }

        let context = ActiveVirtualDisplayTransactionContext(
            transactionID: DisplayRuntimeTransactionID(),
            kind: kind,
            configID: configID,
            source: source
        )
        let previousTail = virtualDisplayTransactionQueueTail
        setActiveTrace(makeInitialTrace(for: context))

        let task = Task { @MainActor in
            defer {
                self.activeVirtualDisplayTransactionTasksByKey[key] = nil
                self.activeVirtualDisplayTransactionIDsByKey[key] = nil
                if self.activeVirtualDisplayTransactionTasksByKey.isEmpty {
                    self.virtualDisplayTransactionQueueTail = nil
                }
            }
            if let previousTail {
                await previousTail.value
            }
            return try await execute(context)
        }
        virtualDisplayTransactionQueueTail = Task { @MainActor in
            _ = try? await task.value
        }
        activeVirtualDisplayTransactionTasksByKey[key] = task
        activeVirtualDisplayTransactionIDsByKey[key] = context.transactionID
        await observabilityRecorder?.refreshSnapshot(reason: .displayRuntimeTransactionChanged)

        return try await task.value
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

    @discardableResult
    private func refreshCatalogTopologyForTransaction() async -> DisplayRuntimeCatalogRefreshResult {
        guard let catalogCommander else { return .failed }
        let result = await catalogCommander.submitRefresh(intent: .topologyChanged, ownerScope: nil)
        await observabilityRecorder?.refreshSnapshot(reason: .screenCatalogStateChanged)
        return result
    }

    private func waitForPostCommandTopology(
        kind: DisplayRuntimeTransactionKind,
        affectedSurfaces: [DisplayRuntimeAffectedSurface]
    ) async -> DisplayRuntimeTopologyStabilityResult {
        var samples: [DisplayRuntimeTopologyStabilitySample] = []
        var previousStableSample: DisplayRuntimeTopologyStabilitySample?
        var stableSampleCount = 0

        for index in 0..<topologyWaitPolicy.maximumSampleCount {
            if index > 0 && topologyWaitPolicy.sampleIntervalNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: topologyWaitPolicy.sampleIntervalNanoseconds)
            }

            let refreshResult = await refreshCatalogTopologyForTransaction()
            let snapshot = makeSnapshot()
            let sample = DisplayRuntimeTopologyStabilitySample(snapshot: snapshot)
            samples.append(sample)

            if catalogPermissionUnavailable(snapshot.catalog) {
                return topologyResult(
                    status: .unprovableDueToPermission,
                    samples: samples,
                    failureReason: "screen_capture_permission_unavailable"
                )
            }
            if refreshResult == .failed {
                return topologyResult(
                    status: .failed,
                    samples: samples,
                    failureReason: "catalog_refresh_failed"
                )
            }

            if affectedSurfacesResolveToVisibleDisplayIDs(
                affectedSurfaces,
                kind: kind,
                snapshot: snapshot
            ) {
                if previousStableSample == sample {
                    stableSampleCount += 1
                } else {
                    previousStableSample = sample
                    stableSampleCount = 1
                }
                if stableSampleCount >= topologyWaitPolicy.requiredStableSampleCount {
                    return topologyResult(status: .stable, samples: samples, failureReason: nil)
                }
            } else {
                previousStableSample = nil
                stableSampleCount = 0
            }
        }

        return topologyResult(
            status: .timedOut,
            samples: samples,
            failureReason: "topology_stability_timed_out"
        )
    }

    private func topologyResult(
        status: DisplayRuntimeTopologyStabilityStatus,
        samples: [DisplayRuntimeTopologyStabilitySample],
        failureReason: String?
    ) -> DisplayRuntimeTopologyStabilityResult {
        DisplayRuntimeTopologyStabilityResult(
            status: status,
            sampleCount: samples.count,
            failureReason: failureReason,
            lastSample: samples.last
        )
    }

    private func catalogPermissionUnavailable(_ catalog: DisplayRuntimeCatalogSnapshot) -> Bool {
        catalog.hasScreenCapturePermission == false || catalog.lastPreflightPermission == false
    }

    private func makeLifecycleSessionRestoreIntents(
        kind: DisplayRuntimeTransactionKind,
        targetConfigID: UUID,
        pauseIntents: [DisplayRuntimeSessionPauseIntent],
        topologyResult: DisplayRuntimeTopologyStabilityResult,
        preSnapshot: DisplayRuntimeSnapshot,
        postSnapshot: DisplayRuntimeSnapshot
    ) -> [DisplayRuntimeSessionRestoreIntent] {
        let targetIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: targetConfigID)
        let intents: [DisplayRuntimeSessionPauseIntent]
        switch kind {
        case .virtualDisplayEnable:
            intents = pauseIntents.filter { $0.surfaceIdentity != targetIdentity }
        case .virtualDisplayDisable, .virtualDisplayRebuild:
            intents = pauseIntents
        }
        return makeSessionRestoreIntents(
            pauseIntents: intents,
            topologyResult: topologyResult,
            preSnapshot: preSnapshot,
            postSnapshot: postSnapshot
        )
    }

    private func affectedSurfacesResolveToVisibleDisplayIDs(
        _ affectedSurfaces: [DisplayRuntimeAffectedSurface],
        kind: DisplayRuntimeTransactionKind,
        snapshot: DisplayRuntimeSnapshot
    ) -> Bool {
        let surfacesToResolve: [DisplayRuntimeAffectedSurface]
        switch kind {
        case .virtualDisplayDisable:
            surfacesToResolve = affectedSurfaces.filter { $0.reason != .requestedConfig }
        case .virtualDisplayRebuild, .virtualDisplayEnable:
            surfacesToResolve = affectedSurfaces
        }
        guard !surfacesToResolve.isEmpty else { return kind == .virtualDisplayDisable }
        let visibleDisplayIDs = Set(snapshot.catalog.loadedDisplays.map(\.displayID))
        return surfacesToResolve.allSatisfy { affectedSurface in
            guard let surface = snapshot.surfaces.first(where: { $0.identity == affectedSurface.identity }),
                  let displayID = surface.currentDisplayID,
                  surface.managedVirtualDisplay?.isRunning != false
            else {
                return false
            }
            return visibleDisplayIDs.contains(displayID)
        }
    }

    private func makeSessionRestoreIntents(
        pauseIntents: [DisplayRuntimeSessionPauseIntent],
        topologyResult: DisplayRuntimeTopologyStabilityResult,
        preSnapshot: DisplayRuntimeSnapshot,
        postSnapshot: DisplayRuntimeSnapshot
    ) -> [DisplayRuntimeSessionRestoreIntent] {
        let visibleDisplayIDs = Set(postSnapshot.catalog.loadedDisplays.map(\.displayID))
        return pauseIntents
            .map { pauseIntent in
                let resolvedDisplayID: DisplayRuntimeDisplayID? = {
                    guard topologyResult.status == .stable,
                          let surface = postSnapshot.surfaces.first(where: { $0.identity == pauseIntent.surfaceIdentity }),
                          let displayID = surface.currentDisplayID,
                          surface.managedVirtualDisplay?.isRunning != false,
                          visibleDisplayIDs.contains(displayID)
                    else {
                        return nil
                    }
                    return displayID
                }()
                let monitoringCapturesCursor = pauseIntent.pauseMonitoring
                    && preSnapshot.capture.sessions.contains {
                        $0.displayID == pauseIntent.displayID && $0.capturesCursor
                    }
                return DisplayRuntimeSessionRestoreIntent(
                    surfaceIdentity: pauseIntent.surfaceIdentity,
                    previousDisplayID: pauseIntent.displayID,
                    resolvedDisplayID: resolvedDisplayID,
                    restoreSharing: pauseIntent.pauseSharing,
                    restoreMonitoring: pauseIntent.pauseMonitoring,
                    monitoringCapturesCursor: monitoringCapturesCursor
                )
            }
    }

    private func restoreSharingSessions(
        _ restoreIntents: [DisplayRuntimeSessionRestoreIntent],
        topologyResult: DisplayRuntimeTopologyStabilityResult,
        postSnapshot: DisplayRuntimeSnapshot,
        disabledTargetIdentity: DisplaySurfaceIdentity?
    ) async -> [DisplayRuntimeSessionRestoreResult] {
        let sharingRestoreIntents = restoreIntents.filter(\.restoreSharing)
        guard !sharingRestoreIntents.isEmpty else { return [] }

        let disabledTargetResults = sharingRestoreIntents
            .filter { $0.surfaceIdentity == disabledTargetIdentity }
            .map {
                makeRestoreResult(
                    kind: .sharing,
                    intent: $0,
                    status: .skipped,
                    failureReason: "target_disabled"
                )
            }
        let peerSharingRestoreIntents = sharingRestoreIntents.filter { $0.surfaceIdentity != disabledTargetIdentity }
        guard !peerSharingRestoreIntents.isEmpty else { return disabledTargetResults }

        guard topologyResult.status == .stable else {
            return disabledTargetResults + peerSharingRestoreIntents.map {
                makeRestoreResult(
                    kind: .sharing,
                    intent: $0,
                    status: .skipped,
                    failureReason: "topology_\(topologyResult.status.rawValue)"
                )
            }
        }

        guard postSnapshot.sharing.isWebServiceRunning else {
            return disabledTargetResults + peerSharingRestoreIntents.map {
                makeRestoreResult(
                    kind: .sharing,
                    intent: $0,
                    status: .skipped,
                    failureReason: "web_service_not_running"
                )
            }
        }

        let visibleDisplayIDs = Set(postSnapshot.catalog.loadedDisplays.map(\.displayID))
        var results: [DisplayRuntimeSessionRestoreResult] = disabledTargetResults
        for intent in peerSharingRestoreIntents {
            guard let resolvedDisplayID = intent.resolvedDisplayID else {
                results.append(
                    makeRestoreResult(
                        kind: .sharing,
                        intent: intent,
                        status: .skipped,
                        failureReason: "resolved_display_unavailable"
                    )
                )
                continue
            }
            guard visibleDisplayIDs.contains(resolvedDisplayID) else {
                results.append(
                    makeRestoreResult(
                        kind: .sharing,
                        intent: intent,
                        status: .skipped,
                        failureReason: "resolved_display_not_visible"
                    )
                )
                continue
            }
            guard let sharingCommander else {
                results.append(
                    makeRestoreResult(
                        kind: .sharing,
                        intent: intent,
                        status: .failed,
                        failureReason: "sharing_commander_unavailable"
                    )
                )
                continue
            }

            let commandResult = await sharingCommander.restoreSharing(displayID: resolvedDisplayID)
            results.append(
                makeRestoreResult(
                    kind: .sharing,
                    intent: intent,
                    status: commandResult.status,
                    failureReason: commandResult.failureReason
                )
            )
        }
        return results
    }

    private func makeDeferredMonitoringRestoreResults(
        _ restoreIntents: [DisplayRuntimeSessionRestoreIntent],
        topologyResult: DisplayRuntimeTopologyStabilityResult,
        disabledTargetIdentity: DisplaySurfaceIdentity?
    ) -> [DisplayRuntimeSessionRestoreResult] {
        let monitoringRestoreIntents = restoreIntents.filter(\.restoreMonitoring)
        guard !monitoringRestoreIntents.isEmpty else { return [] }

        return monitoringRestoreIntents.map { intent in
            let failureReason: String = {
                guard intent.surfaceIdentity != disabledTargetIdentity else {
                    return "target_disabled"
                }
                guard topologyResult.status == .stable else {
                    return "topology_\(topologyResult.status.rawValue)"
                }
                guard intent.resolvedDisplayID != nil else {
                    return "resolved_display_unavailable"
                }
                return "monitoring_restore_deferred_until_consumer_lease"
            }()
            return makeRestoreResult(
                kind: .monitoring,
                intent: intent,
                status: .skipped,
                failureReason: failureReason
            )
        }
    }

    private func makeRestoreResult(
        kind: DisplayRuntimeSessionRestoreKind,
        intent: DisplayRuntimeSessionRestoreIntent,
        status: DisplayRuntimeSessionRestoreStatus,
        failureReason: String?
    ) -> DisplayRuntimeSessionRestoreResult {
        DisplayRuntimeSessionRestoreResult(
            kind: kind,
            status: status,
            previousDisplayID: intent.previousDisplayID,
            resolvedDisplayID: intent.resolvedDisplayID,
            failureReason: failureReason
        )
    }

    private func transactionStatus(
        after topologyResult: DisplayRuntimeTopologyStabilityResult,
        restoreResults: [DisplayRuntimeSessionRestoreResult]
    ) -> DisplayRuntimeTransactionStatus {
        switch topologyResult.status {
        case .stable:
            return restoreResults.allSatisfy { $0.status == .restored || $0.failureReason == "target_disabled" }
                ? .completed
                : .completedWithRecoveryFailures
        case .unprovableDueToPermission, .failed, .timedOut:
            return .completedWithRecoveryFailures
        }
    }

    private func compensationResult(
        after topologyResult: DisplayRuntimeTopologyStabilityResult,
        restoreResults: [DisplayRuntimeSessionRestoreResult],
        restoreIntentCount: Int
    ) -> DisplayRuntimeCompensationResult {
        let restoredSharingCount = restoreResults.filter { $0.kind == .sharing && $0.status == .restored }.count
        let failedRestoreCount = restoreResults.filter {
            $0.status != .restored && $0.failureReason != "target_disabled"
        }.count
        switch topologyResult.status {
        case .stable:
            if restoreIntentCount == 0 {
                return .notRequired
            }
            return .init(
                status: failedRestoreCount == 0 ? .completed : .degraded,
                restoredSharingCount: restoredSharingCount,
                restoredMonitoringCount: 0,
                failedRestoreCount: failedRestoreCount
            )
        case .unprovableDueToPermission, .failed, .timedOut:
            return .init(
                status: .degraded,
                restoredSharingCount: restoredSharingCount,
                restoredMonitoringCount: 0,
                failedRestoreCount: failedRestoreCount
            )
        }
    }

    private func makeLifecycleAffectedScope(
        kind: DisplayRuntimeTransactionKind,
        configID: UUID,
        snapshot: DisplayRuntimeSnapshot,
        enablePreflight: DisplayRuntimeVirtualDisplayEnablePreflight?
    ) -> (surfaces: [DisplayRuntimeAffectedSurface], scopeEscalationReason: DisplayRuntimeScopeEscalationReason?) {
        switch kind {
        case .virtualDisplayRebuild:
            return (makeAffectedSurfaces(configID: configID, snapshot: snapshot), nil)
        case .virtualDisplayEnable:
            return makeEnableAffectedScope(
                configID: configID,
                snapshot: snapshot,
                preflight: enablePreflight
            )
        case .virtualDisplayDisable:
            let surfaces = makeAffectedSurfaces(configID: configID, snapshot: snapshot)
            let hasPeer = surfaces.contains { $0.configID != configID }
            return (surfaces, hasPeer ? .managedMainPolicyRisk : nil)
        }
    }

    private func makeEnableAffectedScope(
        configID: UUID,
        snapshot: DisplayRuntimeSnapshot,
        preflight: DisplayRuntimeVirtualDisplayEnablePreflight?
    ) -> (surfaces: [DisplayRuntimeAffectedSurface], scopeEscalationReason: DisplayRuntimeScopeEscalationReason?) {
        let targetIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        guard let targetSurface = snapshot.surfaces.first(where: { $0.identity == targetIdentity }) else {
            return ([], nil)
        }

        let targetOnlyProven = preflight?.mayPerformFleetRebuild == false
            && preflight?.requiresFleetQuiesce == false
        guard !targetOnlyProven else {
            return ([
                makeAffectedSurface(
                    identity: targetIdentity,
                    configID: configID,
                    surface: targetSurface,
                    snapshot: snapshot,
                    reason: .requestedConfig
                )
            ], nil)
        }

        let runningConfigIDs = Set(snapshot.virtualDisplay.runningConfigIDs)
        let runningManagedDisplays = firstValuesByKey(snapshot.virtualDisplay.managedDisplays, key: \.configID)
            .values
            .filter { runningConfigIDs.contains($0.configID) }
            .sorted { $0.configID.uuidString < $1.configID.uuidString }
        var surfaces: [DisplayRuntimeAffectedSurface] = [
            makeAffectedSurface(
                identity: targetIdentity,
                configID: configID,
                surface: targetSurface,
                snapshot: snapshot,
                reason: .requestedConfig
            )
        ]
        for managed in runningManagedDisplays where managed.configID != configID {
            let identity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: managed.configID)
            let surface = snapshot.surfaces.first { $0.identity == identity }
            surfaces.append(
                makeAffectedSurface(
                    identity: identity,
                    configID: managed.configID,
                    surface: surface,
                    snapshot: snapshot,
                    fallbackManagedDisplay: managed,
                    reason: .enableFleetRiskPeer
                )
            )
        }
        return (surfaces, .scopeEscalatedEnableMayPerformFleetRebuild)
    }

    private func makeAffectedSurfaces(
        configID: UUID,
        snapshot: DisplayRuntimeSnapshot
    ) -> [DisplayRuntimeAffectedSurface] {
        let requestedIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        guard let requestedSurface = snapshot.surfaces.first(where: { $0.identity == requestedIdentity }) else {
            return []
        }

        let managedDisplaysByConfigID = firstValuesByKey(snapshot.virtualDisplay.managedDisplays, key: \.configID)
        let runningConfigIDs = Set(snapshot.virtualDisplay.runningConfigIDs)
        let runningManagedDisplays = managedDisplaysByConfigID.values.filter {
            runningConfigIDs.contains($0.configID)
        }.sorted {
            $0.configID.uuidString < $1.configID.uuidString
        }
        let requestedIsRunning = runningConfigIDs.contains(configID)
        let requestedMainState = requestedSurface.catalog?.isMain
        let shouldEscalateToFleet = runningManagedDisplays.count >= 2
            && requestedIsRunning
            && requestedMainState != false

        if shouldEscalateToFleet {
            return runningManagedDisplays.map { managed in
                let identity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: managed.configID)
                let surface = snapshot.surfaces.first { $0.identity == identity }
                return makeAffectedSurface(
                    identity: identity,
                    configID: managed.configID,
                    surface: surface,
                    snapshot: snapshot,
                    fallbackManagedDisplay: managed,
                    reason: managed.configID == configID ? .requestedConfig : .managedMainFleetPeer
                )
            }
        }

        return [
            makeAffectedSurface(
                identity: requestedIdentity,
                configID: configID,
                surface: requestedSurface,
                snapshot: snapshot,
                fallbackManagedDisplay: managedDisplaysByConfigID[configID],
                reason: .requestedConfig
            )
        ]
    }

    private func makeAffectedSurface(
        identity: DisplaySurfaceIdentity,
        configID: UUID,
        surface: DisplaySurface?,
        snapshot: DisplayRuntimeSnapshot,
        fallbackManagedDisplay: DisplayRuntimeManagedVirtualDisplay? = nil,
        reason: DisplayRuntimeAffectedSurfaceReason
    ) -> DisplayRuntimeAffectedSurface {
        let configsByID = firstValuesByKey(snapshot.virtualDisplay.configs, key: \.id)
        return DisplayRuntimeAffectedSurface(
            identity: identity,
            configID: configID,
            preDisplayID: surface?.currentDisplayID ?? fallbackManagedDisplay?.displayID,
            serialNumber: configsByID[configID]?.serialNumber ?? fallbackManagedDisplay?.serialNumber,
            reason: reason
        )
    }

    private func makePauseIntents(
        affectedSurfaces: [DisplayRuntimeAffectedSurface],
        snapshot: DisplayRuntimeSnapshot
    ) -> [DisplayRuntimeSessionPauseIntent] {
        var intentsByDisplayID: [DisplayRuntimeDisplayID: DisplayRuntimeSessionPauseIntent] = [:]
        for affectedSurface in affectedSurfaces {
            guard let displayID = affectedSurface.preDisplayID,
                  let surface = snapshot.surfaces.first(where: { $0.identity == affectedSurface.identity })
            else {
                continue
            }
            let pauseSharing = surface.sharing?.isActive == true
            let pauseMonitoring = surface.capture?.sessionIDs.isEmpty == false || surface.capture?.isStarting == true
            guard pauseSharing || pauseMonitoring else {
                continue
            }
            if let existing = intentsByDisplayID[displayID] {
                intentsByDisplayID[displayID] = DisplayRuntimeSessionPauseIntent(
                    surfaceIdentity: existing.surfaceIdentity,
                    displayID: displayID,
                    pauseSharing: existing.pauseSharing || pauseSharing,
                    pauseMonitoring: existing.pauseMonitoring || pauseMonitoring
                )
                continue
            }
            intentsByDisplayID[displayID] = DisplayRuntimeSessionPauseIntent(
                surfaceIdentity: affectedSurface.identity,
                displayID: displayID,
                pauseSharing: pauseSharing,
                pauseMonitoring: pauseMonitoring
            )
        }
        return intentsByDisplayID.values.sorted { $0.displayID < $1.displayID }
    }

    private func quiesceSessions(_ pauseIntents: [DisplayRuntimeSessionPauseIntent]) {
        for intent in pauseIntents.sorted(by: { $0.displayID < $1.displayID }) {
            if intent.pauseSharing {
                sharingCommander?.stopSharing(displayID: intent.displayID)
            }
            if intent.pauseMonitoring {
                captureCommander?.removeMonitoringSessions(displayID: intent.displayID)
            }
        }
    }

    private func makeInitialTrace(
        for context: ActiveVirtualDisplayTransactionContext
    ) -> DisplayRuntimeTransactionTrace {
        DisplayRuntimeTransactionTrace(
            id: context.transactionID,
            kind: context.kind,
            source: context.source,
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
            coalescedRequestCount: 0
        )
    }

    private func appendPhase(
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

    private func incrementCoalescedRequestCount(transactionID: DisplayRuntimeTransactionID) {
        updateTrace(transactionID) { trace in
            trace.replacing(
                phases: trace.phases + [.init(phase: .queued, note: "coalesced_duplicate_request")],
                coalescedRequestCount: trace.coalescedRequestCount + 1
            )
        }
    }

    private func finalizeTransaction(
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
        virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome? = nil
    ) -> DisplayRuntimeVirtualDisplayRebuildTransactionResult {
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
                virtualDisplayCommandOutcome: virtualDisplayCommandOutcome
            )
        }
        if let trace = activeTransactionTracesByID.removeValue(forKey: transactionID) {
            recentTransactionTraces.insert(trace, at: 0)
            if recentTransactionTraces.count > 20 {
                recentTransactionTraces = Array(recentTransactionTraces.prefix(20))
            }
        }
        Task {
            await recordTransactionPhaseEvent(phase, transactionID: transactionID)
            await observabilityRecorder?.refreshSnapshot(reason: .displayRuntimeTransactionChanged)
        }
        return DisplayRuntimeVirtualDisplayRebuildTransactionResult(
            transactionID: transactionID,
            kind: kind,
            status: status,
            virtualDisplayCommandSucceeded: virtualDisplayCommandSucceeded,
            hasSessionRecoveryFailures: status == .completedWithRecoveryFailures,
            desiredEnabled: desiredEnabled
        )
    }

    private func setActiveTrace(_ trace: DisplayRuntimeTransactionTrace) {
        activeTransactionTracesByID[trace.id] = trace
    }

    private func updateTrace(
        _ transactionID: DisplayRuntimeTransactionID,
        _ update: (DisplayRuntimeTransactionTrace) -> DisplayRuntimeTransactionTrace
    ) {
        guard let trace = activeTransactionTracesByID[transactionID] else { return }
        activeTransactionTracesByID[transactionID] = update(trace)
    }

    private func transactionFailure(
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

    private func firstValuesByKey<Value, Key: Hashable>(
        _ values: [Value],
        key: (Value) -> Key
    ) -> [Key: Value] {
        var result: [Key: Value] = [:]
        for value in values {
            result[key(value)] = result[key(value)] ?? value
        }
        return result
    }

    private func recordTransactionPhaseEvent(
        _ phase: DisplayRuntimeTransactionPhase,
        transactionID: DisplayRuntimeTransactionID
    ) async {
        let severity: DisplayRuntimeObservabilitySeverity
        switch phase {
        case .failed, .cancelled:
            severity = .warning
        case .queued, .preparing, .persistingConfig, .quiescingSessions, .executingVirtualDisplayCommand,
             .waitingForTopology, .restoringSessions, .completed:
            severity = .info
        }
        await observabilityRecorder?.record(
            DisplayRuntimeObservabilityEvent(
                domain: .displayRuntime,
                severity: severity,
                operation: "Virtual display transaction",
                message: "Virtual display transaction phase changed.",
                metadata: [
                    "transactionID": transactionID.rawValue.uuidString,
                    "phase": phase.rawValue
                ],
                deduplicationKey: nil
            )
        )
    }

    private func refreshAfterPermissionGranted(source: DisplayRuntimeCatalogSource) async {
        guard let catalogCommander else { return }
        switch source {
        case .capturePage:
            await refreshAndConverge(intent: .permissionChanged, ownerScope: .capture)
        case .sharingPage:
            if currentSharingSnapshot().isWebServiceRunning {
                await refreshSharingCatalogForRunningService()
            } else {
                await catalogCommander.cancelRefresh(ownerScope: .sharing)
            }
        }
    }

    private func refreshSharingCatalogForRunningService() async {
        guard let catalogCommander else { return }
        guard catalogCommander.refreshPermission() else {
            await clearSnapshotForDeniedPermission(source: .sharingPage)
            return
        }
        guard currentSharingSnapshot().isWebServiceRunning else {
            await catalogCommander.cancelRefresh(ownerScope: .sharing)
            return
        }
        await refreshAndConverge(intent: .serviceBecameRunning, ownerScope: .sharing)
    }

    private func cancelRefresh(for source: DisplayRuntimeCatalogSource) async {
        guard let catalogCommander else { return }
        switch source {
        case .capturePage:
            await catalogCommander.cancelRefresh(ownerScope: .capture)
        case .sharingPage:
            await catalogCommander.cancelRefresh(ownerScope: .sharing)
        }
    }

    private func clearSnapshotForDeniedPermission(
        loadErrorMessage: String? = nil,
        source: DisplayRuntimeCatalogSource
    ) async {
        await catalogCommander?.clearSnapshotForDeniedPermission(loadErrorMessage: loadErrorMessage)
        convergeToVisibleDisplays([])
        await observabilityRecorder?.record(
            DisplayRuntimeObservabilityEvent(
                severity: .warning,
                operation: "Clear denied screen capture snapshot",
                message: "Cleared visible displays because screen capture permission is unavailable.",
                metadata: ["source": source.observabilitySource],
                deduplicationKey: "screenCatalog.permission.denied"
            )
        )
        await observabilityRecorder?.refreshSnapshot(reason: .screenCatalogStateChanged)
    }

    private func drainTopologyRefreshQueue() async {
        while hasPendingTopologyChange {
            hasPendingTopologyChange = false
            await runTopologyRefreshSequence()
        }
    }

    private func runTopologyRefreshSequence() async {
        guard let catalogCommander else { return }
        guard catalogCommander.refreshPermission() else {
            await clearSnapshotForDeniedPermission(source: .capturePage)
            return
        }

        let result = await catalogCommander.submitRefresh(intent: .topologyChanged, ownerScope: nil)
        await observabilityRecorder?.refreshSnapshot(reason: .screenCatalogStateChanged)
        handleRefreshResultForConvergence(result)
    }

    private func refreshAndConverge(
        intent: DisplayRuntimeCatalogRefreshIntent,
        ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?
    ) async {
        guard let catalogCommander else { return }
        let result = await catalogCommander.submitRefresh(intent: intent, ownerScope: ownerScope)
        await observabilityRecorder?.refreshSnapshot(reason: .screenCatalogStateChanged)
        handleRefreshResultForConvergence(result)
    }

    private func handleRefreshResultForConvergence(_ result: DisplayRuntimeCatalogRefreshResult) {
        switch result {
        case .reloadedSnapshot, .reusedSnapshot:
            convergeToVisibleDisplaysFromCurrentCatalog()
        case .clearedSnapshot:
            convergeToVisibleDisplays([])
        case .failed:
            return
        }
    }

    private func convergeToVisibleDisplaysFromCurrentCatalog() {
        convergeToVisibleDisplays(catalogCommander?.currentVisibleDisplays() ?? [])
    }

    private func convergeToVisibleDisplays(_ visibleDisplays: [DisplayRuntimeVisibleDisplay]) {
        let visibleDisplayIDs = Set(visibleDisplays.map(\.displayID))

        if currentSharingSnapshot().isWebServiceRunning {
            let virtualDisplays = currentVirtualDisplaySnapshot().managedDisplays
            var virtualSerialsByDisplayID: [DisplayRuntimeDisplayID: UInt32] = [:]
            for virtualDisplay in virtualDisplays {
                virtualSerialsByDisplayID[virtualDisplay.displayID] = virtualSerialsByDisplayID[virtualDisplay.displayID]
                    ?? virtualDisplay.serialNumber
            }
            sharingCommander?.registerShareableDisplays(
                visibleDisplays.map {
                    DisplayRuntimeShareableDisplayRegistration(
                        displayID: $0.displayID,
                        virtualSerialNumber: virtualSerialsByDisplayID[$0.displayID]
                    )
                }
            )
        }

        let sharing = currentSharingSnapshot()
        for displayID in sharing.activeSharingDisplayIDs where !visibleDisplayIDs.contains(displayID) {
            sharingCommander?.stopSharing(displayID: displayID)
        }

        let monitoredDisplayIDs = Set(currentCaptureSnapshot().sessions.map(\.displayID))
        for displayID in monitoredDisplayIDs where !visibleDisplayIDs.contains(displayID) {
            captureCommander?.removeMonitoringSessions(displayID: displayID)
        }
    }

    private func recordPermissionEvent(
        granted: Bool,
        source: DisplayRuntimeCatalogSource
    ) async {
        await observabilityRecorder?.record(
            DisplayRuntimeObservabilityEvent(
                severity: granted ? .info : .warning,
                operation: "Screen capture permission check",
                message: granted
                    ? "Screen capture permission available."
                    : "Screen capture permission unavailable.",
                metadata: ["source": source.observabilitySource],
                deduplicationKey: "screenCatalog.permission.\(source.observabilitySource)"
            )
        )
    }

    private func currentCaptureSnapshot() -> DisplayRuntimeCaptureSnapshot {
        captureProvider?.makeCaptureSnapshot() ?? .empty
    }

    private func currentSharingSnapshot() -> DisplayRuntimeSharingSnapshot {
        sharingProvider?.makeSharingSnapshot() ?? .empty
    }

    private func currentVirtualDisplaySnapshot() -> DisplayRuntimeVirtualDisplaySnapshot {
        virtualDisplayProvider?.makeVirtualDisplaySnapshot() ?? .empty
    }
}

private nonisolated extension DisplayRuntimeCatalogSource {
    var observabilitySource: String {
        switch self {
        case .capturePage:
            "capture"
        case .sharingPage:
            "sharing"
        }
    }
}

private nonisolated enum DisplaySurfaceGraphBuilder {
    private struct MutableSurface {
        let identity: DisplaySurfaceIdentity
        let kind: DisplaySurfaceKind
        var currentDisplayID: DisplayRuntimeDisplayID?
        var isAuxiliary: Bool
        var catalog: DisplayRuntimeCatalogSurfaceState?
        var capture: DisplayRuntimeCaptureSurfaceState?
        var sharing: DisplayRuntimeSharingSurfaceState?
        var managedVirtualDisplay: DisplayRuntimeManagedVirtualDisplaySurfaceState?

        func makeSurface() -> DisplaySurface {
            DisplaySurface(
                identity: identity,
                kind: kind,
                currentDisplayID: currentDisplayID,
                isAuxiliary: isAuxiliary,
                catalog: catalog,
                capture: capture,
                sharing: sharing,
                managedVirtualDisplay: managedVirtualDisplay
            )
        }
    }

    static func makeSurfaces(
        catalog: DisplayRuntimeCatalogSnapshot,
        capture: DisplayRuntimeCaptureSnapshot,
        sharing: DisplayRuntimeSharingSnapshot,
        virtualDisplay: DisplayRuntimeVirtualDisplaySnapshot
    ) -> [DisplaySurface] {
        let managedByConfigID = firstValuesByKey(
            virtualDisplay.managedDisplays,
            key: \.configID
        )
        let configsByID = firstValuesByKey(
            virtualDisplay.configs,
            key: \.id
        )
        let runningConfigIDs = Set(virtualDisplay.runningConfigIDs)
        let rebuildingConfigIDs = Set(virtualDisplay.rebuildingConfigIDs)
        let recentlyAppliedConfigIDs = Set(virtualDisplay.recentlyAppliedConfigIDs)
        let rebuildFailureConfigIDs = Set(virtualDisplay.rebuildFailureConfigIDs)
        let restoreFailureConfigIDs = Set(virtualDisplay.restoreFailureConfigIDs)

        var surfaces: [DisplaySurfaceIdentity: MutableSurface] = [:]
        for configID in Set(configsByID.keys).union(managedByConfigID.keys) {
            let identity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
            let config = configsByID[configID]
            let managed = managedByConfigID[configID]
            let maximumPixelDimensions = config.flatMap(maximumPixelDimensions)
            surfaces[identity] = MutableSurface(
                identity: identity,
                kind: .managedVirtualDisplay,
                currentDisplayID: managed?.displayID,
                isAuxiliary: false,
                catalog: nil,
                capture: nil,
                sharing: nil,
                managedVirtualDisplay: .init(
                    configID: configID,
                    serialNumber: config?.serialNumber ?? managed?.serialNumber,
                    desiredEnabled: config?.desiredEnabled,
                    isRunning: runningConfigIDs.contains(configID),
                    isLiveRuntime: managed?.isLiveRuntime ?? false,
                    isRebuilding: rebuildingConfigIDs.contains(configID),
                    hasRecentApplySuccess: recentlyAppliedConfigIDs.contains(configID),
                    hasRebuildFailure: rebuildFailureConfigIDs.contains(configID),
                    hasRestoreFailure: restoreFailureConfigIDs.contains(configID),
                    modeCount: config?.modes.count,
                    maximumPixelWidth: maximumPixelDimensions?.width,
                    maximumPixelHeight: maximumPixelDimensions?.height
                )
            )
        }

        var identityByDisplayID: [DisplayRuntimeDisplayID: DisplaySurfaceIdentity] = [:]
        for managed in virtualDisplay.managedDisplays.sorted(by: managedDisplaySort) {
            identityByDisplayID[managed.displayID] = identityByDisplayID[managed.displayID]
                ?? DisplaySurfaceIdentity.managedVirtualDisplay(configID: managed.configID)
        }

        func ensurePhysicalSurface(displayID: DisplayRuntimeDisplayID) -> DisplaySurfaceIdentity {
            let identity = DisplaySurfaceIdentity.physicalDisplay(displayID: displayID)
            if surfaces[identity] == nil {
                surfaces[identity] = MutableSurface(
                    identity: identity,
                    kind: .physicalDisplay,
                    currentDisplayID: displayID,
                    isAuxiliary: true,
                    catalog: nil,
                    capture: nil,
                    sharing: nil,
                    managedVirtualDisplay: nil
                )
            }
            identityByDisplayID[displayID] = identity
            return identity
        }

        func identity(for displayID: DisplayRuntimeDisplayID) -> DisplaySurfaceIdentity {
            identityByDisplayID[displayID] ?? ensurePhysicalSurface(displayID: displayID)
        }

        let topologyByDisplayID = firstValuesByKey(
            catalog.topologySignature,
            key: \.displayID
        )
        for display in catalog.loadedDisplays {
            let surfaceIdentity = identity(for: display.displayID)
            var surface = surfaces[surfaceIdentity]!
            let topology = topologyByDisplayID[display.displayID]
            surface.catalog = DisplayRuntimeCatalogSurfaceState(
                displayID: display.displayID,
                isVisible: true,
                isMain: topology?.isMain,
                pixelWidth: topology?.pixelWidth ?? display.pixelWidth,
                pixelHeight: topology?.pixelHeight ?? display.pixelHeight,
                refreshRateMilliHertz: topology?.refreshRateMilliHertz,
                mirrorsDisplayID: topology?.mirrorsDisplayID
            )
            if surface.currentDisplayID == nil {
                surface.currentDisplayID = display.displayID
            }
            surfaces[surfaceIdentity] = surface
        }

        for topology in catalog.topologySignature where catalog.loadedDisplays.allSatisfy({ $0.displayID != topology.displayID }) {
            let surfaceIdentity = identity(for: topology.displayID)
            var surface = surfaces[surfaceIdentity]!
            surface.catalog = DisplayRuntimeCatalogSurfaceState(
                displayID: topology.displayID,
                isVisible: true,
                isMain: topology.isMain,
                pixelWidth: topology.pixelWidth,
                pixelHeight: topology.pixelHeight,
                refreshRateMilliHertz: topology.refreshRateMilliHertz,
                mirrorsDisplayID: topology.mirrorsDisplayID
            )
            if surface.currentDisplayID == nil {
                surface.currentDisplayID = topology.displayID
            }
            surfaces[surfaceIdentity] = surface
        }

        let captureSessionsByDisplayID = Dictionary(grouping: capture.sessions, by: \.displayID)
        for displayID in Set(capture.startingDisplayIDs).union(captureSessionsByDisplayID.keys) {
            let surfaceIdentity = identity(for: displayID)
            var surface = surfaces[surfaceIdentity]!
            let sessions = captureSessionsByDisplayID[displayID] ?? []
            surface.capture = DisplayRuntimeCaptureSurfaceState(
                displayID: displayID,
                isStarting: capture.startingDisplayIDs.contains(displayID),
                sessionIDs: sessions.map(\.id),
                capturesCursor: sessions.contains(where: \.capturesCursor),
                receivedFrameCount: sessions.reduce(0) { $0 + $1.metrics.receivedFrameCount }
            )
            if surface.currentDisplayID == nil {
                surface.currentDisplayID = displayID
            }
            surfaces[surfaceIdentity] = surface
        }

        var viewerCounts: [DisplayRuntimeDisplayID: Int] = [:]
        for clientCount in sharing.sharingClientCounts {
            viewerCounts[clientCount.displayID, default: 0] += clientCount.count
        }
        let routeDisplayIDs = Set(sharing.routes.map(\.displayID))
        let sharingDisplayIDs = Set(sharing.activeSharingDisplayIDs)
            .union(sharing.startingDisplayIDs)
            .union(viewerCounts.keys)
            .union(routeDisplayIDs)
        for displayID in sharingDisplayIDs {
            let surfaceIdentity = identity(for: displayID)
            var surface = surfaces[surfaceIdentity]!
            surface.sharing = DisplayRuntimeSharingSurfaceState(
                displayID: displayID,
                isStarting: sharing.startingDisplayIDs.contains(displayID),
                isActive: sharing.activeSharingDisplayIDs.contains(displayID),
                viewerCount: viewerCounts[displayID] ?? 0,
                hasRoute: sharing.routes.contains { $0.displayID == displayID && $0.hasConcreteRoute }
            )
            if surface.currentDisplayID == nil {
                surface.currentDisplayID = displayID
            }
            surfaces[surfaceIdentity] = surface
        }

        return surfaces.values
            .map { $0.makeSurface() }
            .sorted(by: surfaceSort)
    }

    private static func firstValuesByKey<Value, Key: Hashable>(
        _ values: [Value],
        key: (Value) -> Key
    ) -> [Key: Value] {
        var result: [Key: Value] = [:]
        for value in values {
            result[key(value)] = result[key(value)] ?? value
        }
        return result
    }

    private static func managedDisplaySort(
        lhs: DisplayRuntimeManagedVirtualDisplay,
        rhs: DisplayRuntimeManagedVirtualDisplay
    ) -> Bool {
        if lhs.displayID != rhs.displayID { return lhs.displayID < rhs.displayID }
        return lhs.configID.uuidString < rhs.configID.uuidString
    }

    private static func surfaceSort(lhs: DisplaySurface, rhs: DisplaySurface) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.identity.stableID != rhs.identity.stableID {
            return lhs.identity.stableID < rhs.identity.stableID
        }
        return (lhs.currentDisplayID ?? 0) < (rhs.currentDisplayID ?? 0)
    }

    private static func maximumPixelDimensions(
        for config: DisplayRuntimeVirtualDisplayConfig
    ) -> (width: Int, height: Int)? {
        guard let maxMode = config.modes.max(by: { pixelArea($0) < pixelArea($1) }) else {
            return nil
        }
        let scale = config.modes.contains(where: \.enableHiDPI) ? 2 : 1
        let (width, widthOverflow) = maxMode.width.multipliedReportingOverflow(by: scale)
        let (height, heightOverflow) = maxMode.height.multipliedReportingOverflow(by: scale)
        guard !widthOverflow, !heightOverflow else { return nil }
        return (width, height)
    }

    private static func pixelArea(_ mode: DisplayRuntimeVirtualDisplayMode) -> Int {
        let (area, overflow) = mode.width.multipliedReportingOverflow(by: mode.height)
        guard !overflow else { return Int.max }
        return max(0, area)
    }
}
