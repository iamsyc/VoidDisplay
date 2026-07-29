import Foundation

@MainActor
extension DisplayRuntime {
    package func registerCatalogSurface(
        source: DisplayRuntimeCatalogSource
    ) -> DisplayRuntimeCatalogSurfaceRegistration {
        let registration = DisplayRuntimeCatalogSurfaceRegistration(source: source)
        activeCatalogSurfaceRegistrations[source, default: []].insert(registration)
        return registration
    }

    package func refreshCatalogSurface(
        _ registration: DisplayRuntimeCatalogSurfaceRegistration
    ) async {
        guard activeCatalogSurfaceRegistrations[registration.source]?.contains(registration) == true else {
            return
        }
        await refreshCatalogPermission(source: registration.source)
    }

    package func unregisterCatalogSurface(
        _ registration: DisplayRuntimeCatalogSurfaceRegistration
    ) async {
        guard var registrations = activeCatalogSurfaceRegistrations[registration.source],
              registrations.remove(registration) != nil
        else {
            return
        }
        activeCatalogSurfaceRegistrations[registration.source] = registrations.isEmpty ? nil : registrations
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

    package func forceRefreshCatalog(
        source: DisplayRuntimeCatalogSource
    ) async -> DisplayRuntimeCatalogRefreshOutcome {
        guard let catalogCommander else {
            return DisplayRuntimeCatalogRefreshOutcome(
                settlementID: nil,
                result: .failed,
                catalog: makeSnapshot().catalog
            )
        }
        let granted = catalogCommander.refreshPermission()
        guard granted else {
            return await clearSnapshotForDeniedPermission(source: source)
        }

        switch source {
        case .capturePage:
            return await refreshAndConverge(intent: .userForcedRefresh)
        case .sharingPage:
            guard currentSharingSnapshot().isWebServiceRunning else {
                return DisplayRuntimeCatalogRefreshOutcome(
                    settlementID: nil,
                    result: .failed,
                    catalog: makeSnapshot().catalog
                )
            }
            return await refreshAndConverge(intent: .userForcedRefresh)
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
        if currentSharingSnapshot().isWebServiceRunning {
            await refreshSharingCatalogForRunningService()
        }
    }

    private func refreshAfterPermissionGranted(source: DisplayRuntimeCatalogSource) async {
        switch source {
        case .capturePage:
            _ = await refreshAndConverge(intent: .permissionChanged)
        case .sharingPage:
            if currentSharingSnapshot().isWebServiceRunning {
                await refreshSharingCatalogForRunningService()
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
            return
        }
        _ = await refreshAndConverge(intent: .serviceBecameRunning)
    }

    @discardableResult
    private func clearSnapshotForDeniedPermission(
        loadErrorMessage: String? = nil,
        source: DisplayRuntimeCatalogSource
    ) async -> DisplayRuntimeCatalogRefreshOutcome {
        guard let catalogCommander else {
            return DisplayRuntimeCatalogRefreshOutcome(
                settlementID: nil,
                result: .failed,
                catalog: makeSnapshot().catalog
            )
        }
        let outcome = await catalogCommander.clearSnapshotForDeniedPermission(
            loadErrorMessage: loadErrorMessage
        )
        await handleRefreshOutcomeForConvergence(outcome)
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
        return outcome
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

        let outcome = await catalogCommander.submitRefresh(intent: .topologyChanged)
        await observabilityRecorder?.refreshSnapshot(reason: .screenCatalogStateChanged)
        await handleRefreshOutcomeForConvergence(outcome)
    }

    private func refreshAndConverge(
        intent: DisplayRuntimeCatalogRefreshIntent
    ) async -> DisplayRuntimeCatalogRefreshOutcome {
        guard let catalogCommander else {
            return DisplayRuntimeCatalogRefreshOutcome(
                settlementID: nil,
                result: .failed,
                catalog: makeSnapshot().catalog
            )
        }
        let outcome = await catalogCommander.submitRefresh(intent: intent)
        await observabilityRecorder?.refreshSnapshot(reason: .screenCatalogStateChanged)
        await handleRefreshOutcomeForConvergence(outcome)
        return outcome
    }

    func handleRefreshOutcomeForConvergence(
        _ outcome: DisplayRuntimeCatalogRefreshOutcome
    ) async {
        switch outcome.result {
        case .reloadedSnapshot, .reusedSnapshot:
            await convergeToVisibleDisplays(outcome.catalog.loadedDisplays)
        case .clearedSnapshot:
            await convergeToVisibleDisplays([])
        case .superseded, .failed:
            return
        }
    }

    private func convergeToVisibleDisplays(_ visibleDisplays: [DisplayRuntimeCatalogDisplay]) async {
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
        await reconcileConsumerLeasesAfterCatalogConvergence(visibleDisplays: visibleDisplays)
    }

    private func reconcileConsumerLeasesAfterCatalogConvergence(
        visibleDisplays: [DisplayRuntimeCatalogDisplay]
    ) async {
        let visibleDisplayIDs = Set(visibleDisplays.map(\.displayID))
        let snapshot = makeSnapshot()
        let candidateLeases = consumerLeasesByID.values.filter {
            $0.state == .attached && !consumerTransitionBusySurfaces.contains($0.surfaceIdentity)
        }
        let affectedSurfaceIdentities: Set<DisplaySurfaceIdentity> = Set(candidateLeases.compactMap { lease in
            let resolvedDisplayID = snapshot.surfaces.first {
                $0.identity == lease.surfaceIdentity
            }?.currentDisplayID
            guard lease.resolvedDisplayID != resolvedDisplayID
                    || lease.resolvedDisplayID.map({ !visibleDisplayIDs.contains($0) }) == true
            else {
                return nil
            }
            return lease.surfaceIdentity
        })
        guard !affectedSurfaceIdentities.isEmpty else { return }

        var previousDisplayIDs: [DisplaySurfaceIdentity: DisplayRuntimeDisplayID?] = [:]
        for surfaceIdentity in affectedSurfaceIdentities {
            previousDisplayIDs[surfaceIdentity] = candidateLeases.first {
                $0.surfaceIdentity == surfaceIdentity
            }?.resolvedDisplayID
        }
        let transition = await beginConsumerTransition(
            surfaceIdentities: Array(affectedSurfaceIdentities),
            previousDisplayIDs: previousDisplayIDs
        )
        _ = await completeConsumerTransition(
            transition,
            snapshot: makeSnapshot(),
            topologyResult: nil
        )
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
