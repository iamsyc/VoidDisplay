import Foundation

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

    private var topologyRefreshTask: Task<Void, Never>?
    private var hasPendingTopologyChange = false
    private var rebuildQueueTail: Task<DisplayRuntimeVirtualDisplayRebuildTransactionResult, Error>?
    private var activeRebuildTasksByConfigID: [UUID: Task<DisplayRuntimeVirtualDisplayRebuildTransactionResult, Error>] = [:]
    private var activeRebuildTransactionIDsByConfigID: [UUID: DisplayRuntimeTransactionID] = [:]
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
        observabilityRecorder: (any DisplayRuntimeObservabilityRecording)? = nil
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
        if let activeTask = activeRebuildTasksByConfigID[configID],
           let transactionID = activeRebuildTransactionIDsByConfigID[configID] {
            incrementCoalescedRequestCount(transactionID: transactionID)
            await observabilityRecorder?.refreshSnapshot(reason: .displayRuntimeTransactionChanged)
            return try await activeTask.value
        }

        let request = DisplayRuntimeVirtualDisplayRebuildRequest(configID: configID, source: source)
        let previousTail = rebuildQueueTail
        setActiveTrace(makeInitialTrace(for: request))

        let task = Task { @MainActor in
            defer {
                self.activeRebuildTasksByConfigID[configID] = nil
                self.activeRebuildTransactionIDsByConfigID[configID] = nil
            }
            if let previousTail {
                _ = try? await previousTail.value
            }
            return try await self.executeVirtualDisplayRebuildTransaction(request)
        }
        rebuildQueueTail = task
        activeRebuildTasksByConfigID[configID] = task
        activeRebuildTransactionIDsByConfigID[configID] = request.transactionID
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

        return finalizeTransaction(
            transactionID: request.transactionID,
            status: .completed,
            phase: .completed,
            failure: nil,
            virtualDisplayCommandSucceeded: true,
            postSnapshot: makeSnapshot()
        )
    }

    private func refreshCatalogTopologyForTransaction() async {
        guard let catalogCommander else { return }
        _ = await catalogCommander.submitRefresh(intent: .topologyChanged, ownerScope: nil)
        await observabilityRecorder?.refreshSnapshot(reason: .screenCatalogStateChanged)
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
        let configsByID = firstValuesByKey(snapshot.virtualDisplay.configs, key: \.id)
        let runningManagedDisplays = snapshot.virtualDisplay.managedDisplays.filter {
            snapshot.virtualDisplay.runningConfigIDs.contains($0.configID)
        }
        let requestedIsRunning = snapshot.virtualDisplay.runningConfigIDs.contains(configID)
        let requestedMainState = requestedSurface.catalog?.isMain
        let shouldEscalateToFleet = runningManagedDisplays.count >= 2
            && requestedIsRunning
            && requestedMainState != false

        if shouldEscalateToFleet {
            return runningManagedDisplays.map { managed in
                let identity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: managed.configID)
                let surface = snapshot.surfaces.first { $0.identity == identity }
                return DisplayRuntimeAffectedSurface(
                    identity: identity,
                    configID: managed.configID,
                    preDisplayID: surface?.currentDisplayID ?? managed.displayID,
                    serialNumber: configsByID[managed.configID]?.serialNumber ?? managed.serialNumber,
                    reason: managed.configID == configID ? .requestedConfig : .managedMainFleetPeer
                )
            }
        }

        return [
            DisplayRuntimeAffectedSurface(
                identity: requestedIdentity,
                configID: configID,
                preDisplayID: requestedSurface.currentDisplayID ?? managedDisplaysByConfigID[configID]?.displayID,
                serialNumber: configsByID[configID]?.serialNumber ?? managedDisplaysByConfigID[configID]?.serialNumber,
                reason: .requestedConfig
            )
        ]
    }

    private func makePauseIntents(
        affectedSurfaces: [DisplayRuntimeAffectedSurface],
        snapshot: DisplayRuntimeSnapshot
    ) -> [DisplayRuntimeSessionPauseIntent] {
        affectedSurfaces.compactMap { affectedSurface in
            guard let displayID = affectedSurface.preDisplayID,
                  let surface = snapshot.surfaces.first(where: { $0.identity == affectedSurface.identity })
            else {
                return nil
            }
            return DisplayRuntimeSessionPauseIntent(
                surfaceIdentity: affectedSurface.identity,
                displayID: displayID,
                pauseSharing: surface.sharing?.isActive == true,
                pauseMonitoring: surface.capture?.sessionIDs.isEmpty == false || surface.capture?.isStarting == true
            )
        }
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
        for request: DisplayRuntimeVirtualDisplayRebuildRequest
    ) -> DisplayRuntimeTransactionTrace {
        DisplayRuntimeTransactionTrace(
            id: request.transactionID,
            kind: .virtualDisplayRebuild,
            source: request.source,
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
        status: DisplayRuntimeTransactionStatus,
        phase: DisplayRuntimeTransactionPhase,
        failure: DisplayRuntimeTransactionFailure?,
        virtualDisplayCommandSucceeded: Bool,
        postSnapshot: DisplayRuntimeSnapshot? = nil
    ) -> DisplayRuntimeVirtualDisplayRebuildTransactionResult {
        let postEvidence = postSnapshot.map(DisplayRuntimeTransactionSnapshotEvidence.init(snapshot:))
        updateTrace(transactionID) { trace in
            trace.replacing(
                status: status,
                phases: trace.phases + [.init(phase: phase)],
                postSnapshotEvidence: postEvidence ?? trace.postSnapshotEvidence,
                failure: failure
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
            status: status,
            virtualDisplayCommandSucceeded: virtualDisplayCommandSucceeded,
            hasSessionRecoveryFailures: false
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
        case .queued, .preparing, .quiescingSessions, .executingVirtualDisplayCommand,
             .waitingForTopology, .restoringSessions, .completed:
            severity = .info
        }
        await observabilityRecorder?.record(
            DisplayRuntimeObservabilityEvent(
                domain: .displayRuntime,
                severity: severity,
                operation: "Virtual display rebuild transaction",
                message: "Rebuild transaction phase changed.",
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
