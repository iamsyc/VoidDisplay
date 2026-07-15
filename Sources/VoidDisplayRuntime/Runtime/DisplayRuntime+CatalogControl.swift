import Foundation

@MainActor
extension DisplayRuntime {
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

    func convergeToVisibleDisplaysFromCurrentCatalog() async {
        await convergeToVisibleDisplays(catalogCommander?.currentVisibleDisplays() ?? [])
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
        await convergeToVisibleDisplays([])
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
        await handleRefreshResultForConvergence(result)
    }

    private func refreshAndConverge(
        intent: DisplayRuntimeCatalogRefreshIntent,
        ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?
    ) async {
        guard let catalogCommander else { return }
        let result = await catalogCommander.submitRefresh(intent: intent, ownerScope: ownerScope)
        await observabilityRecorder?.refreshSnapshot(reason: .screenCatalogStateChanged)
        await handleRefreshResultForConvergence(result)
    }

    private func handleRefreshResultForConvergence(_ result: DisplayRuntimeCatalogRefreshResult) async {
        switch result {
        case .reloadedSnapshot, .reusedSnapshot:
            await convergeToVisibleDisplaysFromCurrentCatalog()
        case .clearedSnapshot:
            await convergeToVisibleDisplays([])
        case .failed:
            return
        }
    }

    private func convergeToVisibleDisplays(_ visibleDisplays: [DisplayRuntimeVisibleDisplay]) async {
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
        visibleDisplays: [DisplayRuntimeVisibleDisplay]
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
