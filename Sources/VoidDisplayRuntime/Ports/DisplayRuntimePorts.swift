@MainActor
package protocol DisplayRuntimeCatalogProviding {
    func makeCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot
}

@MainActor
package protocol DisplayRuntimeCaptureProviding {
    func makeCaptureSnapshot() -> DisplayRuntimeCaptureSnapshot
}

@MainActor
package protocol DisplayRuntimeSharingProviding {
    func makeSharingSnapshot() -> DisplayRuntimeSharingSnapshot
}

@MainActor
package protocol DisplayRuntimeVirtualDisplayProviding {
    func makeVirtualDisplaySnapshot() -> DisplayRuntimeVirtualDisplaySnapshot
}

@MainActor
package protocol DisplayRuntimeCatalogCommanding {
    func requestPermission() -> Bool
    func refreshPermission() -> Bool
    func submitRefresh(
        intent: DisplayRuntimeCatalogRefreshIntent,
        ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?
    ) async -> DisplayRuntimeCatalogRefreshResult
    func clearSnapshotForDeniedPermission(loadErrorMessage: String?) async
    func cancelRefresh(ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?) async
    func currentVisibleDisplays() -> [DisplayRuntimeVisibleDisplay]
}

@MainActor
package protocol DisplayRuntimeSharingCommanding {
    func registerShareableDisplays(_ displays: [DisplayRuntimeShareableDisplayRegistration])
    func stopSharing(displayID: DisplayRuntimeDisplayID)
}

@MainActor
package protocol DisplayRuntimeCaptureCommanding {
    func removeMonitoringSessions(displayID: DisplayRuntimeDisplayID)
}

@MainActor
package protocol DisplayRuntimeObservabilityRecording {
    func record(_ event: DisplayRuntimeObservabilityEvent) async
    func refreshSnapshot(reason: DisplayRuntimeObservabilityRefreshReason) async
}
