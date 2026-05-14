import Foundation

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
package protocol DisplayRuntimeVirtualDisplayCommanding {
    func rebuildVirtualDisplay(configID: UUID) async throws -> DisplayRuntimeVirtualDisplayRebuildCommandResult
    func preflightEnableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayEnablePreflight
    func setVirtualDisplayDesiredEnabled(
        request: DisplayRuntimeVirtualDisplayDesiredEnabledCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayDesiredEnabledCommandResult
    func saveConfigForRebuild(
        request: DisplayRuntimeVirtualDisplayEditRebuildRequest
    ) async throws -> DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult
    func restoreConfigAfterFailedEdit(
        request: DisplayRuntimeVirtualDisplayEditRebuildRestoreCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayPersistenceCommandResult
    func enableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayLifecycleCommandResult
    func disableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayLifecycleCommandResult
    func createVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayCreateRequest
    ) async throws -> DisplayRuntimeVirtualDisplayCreateCommandResult
    func deleteVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayDeleteCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayDeleteCommandResult
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
    func restoreSharing(displayID: DisplayRuntimeDisplayID) async -> DisplayRuntimeSharingRestoreCommandResult
}

@MainActor
package protocol DisplayRuntimeCaptureCommanding {
    func removeMonitoringSessions(displayID: DisplayRuntimeDisplayID)
}

@MainActor
package protocol DisplayRuntimeCaptureIntentCommanding {
    func submitCaptureIntent(_ intent: DisplayRuntimeCaptureIntent)
}

@MainActor
package protocol DisplayRuntimeObservabilityRecording {
    func record(_ event: DisplayRuntimeObservabilityEvent) async
    func refreshSnapshot(reason: DisplayRuntimeObservabilityRefreshReason) async
}
